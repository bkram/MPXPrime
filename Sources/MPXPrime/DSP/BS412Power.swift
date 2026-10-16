#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

// ITU-R BS.412-9 multiplex power.
//
// Section 2.5.1, verbatim (`standards/R-REC-BS.412-9-199812-I!!PDF-E.pdf`):
// "it is assumed that the power of the complete multiplex signal (including
// pilot-tone and additional signals) integrated over any interval of 60 s is
// not higher than the power of a multiplex signal containing a single
// sinusoidal tone which causes a peak deviation of +/- 19 kHz." The same
// paragraph assumes peak deviation does not exceed +/- 75 kHz, which is the
// normalisation the modulation domain uses here.
//
// Read "any interval of 60 s" carefully: it is not "the settled average".
// A controller that converges eventually still breaks the Recommendation if
// the first completed minute, or a minute spanning a programme transition,
// sits above the ceiling. That is what the 0.65 rebuild missed and this
// file now separates into three concerns:
//
//  1. `BS412MultiplexPowerMeter` -- what was actually emitted. Reporting
//     only. It never controls anything, it runs whether or not the limiter
//     is enabled, and it runs during Test Tone, because a transmitted tone
//     is still part of the complete multiplex.
//  2. `BS412Rider` -- the transparent, slow audio gain ride that owns the
//     audible behaviour. FEED-FORWARD from pre-control audio, so it is not a
//     loop closed around a lagging 60-second measurement and cannot hunt.
//  3. `BS412ComplianceGuard` -- an energy-accounting invariant, not another
//     smoother. It is what actually proves the limit. In normal operation
//     the rider keeps it idle.
//
// Pilot and RDS amplitudes are fixed throughout. Only the reducible audio
// composite is ever attenuated; an impossible budget is REPORTED, never met
// by quietly squashing the subcarriers.

/// Everything the operator and the API need to know about this stage.
struct BS412Status: Equatable, Sendable {
    /// Complete-multiplex power over the rolling window, dBr.
    var powerDBr: Float = 0.0
    /// A full 60 seconds has been observed. Until then `powerDBr` is a
    /// provisional average of everything seen so far and must not be
    /// presented as a compliance figure.
    var powerValid: Bool = false
    var secondsObserved: Float = 0.0
    var gainReductionDB: Float = 0.0
    var overCeiling: Bool = false
    /// Pilot and RDS alone exceed the ceiling: no audio gain can fix it.
    var unachievable: Bool = false
    /// The hard guard had to intervene. Normal programme should never see
    /// this -- it means the rider was too slow for what arrived.
    var guardActive: Bool = false
    /// Control is suspended (Test Tone). Measurement continues; compliance
    /// must not be claimed.
    var controlSuspended: Bool = false
}

/// Constants shared by the three parts, so the reference and the block
/// granularity cannot drift between them.
enum BS412 {
    /// The Recommendation's integration time. Not operator-settable: a 30-
    /// or 90-second window is not BS.412, whatever it is labelled.
    static let windowSeconds: Float = 60.0

    /// 0 dBr = a sine causing +/- 19 kHz peak deviation. The composite is
    /// normalised so |x| = 1.0 is 75 kHz (`deviationScale` scales the whole
    /// composite, subcarriers included, which is what holds pilot injection
    /// at 9 % of full deviation at any `mpx_deviation_khz`), so that sine has
    /// amplitude 19/75 and mean square (19/75)^2 / 2 = 0.0320889.
    static let referenceMeanSquare: Float = ((19.0 / 75.0) * (19.0 / 75.0)) / 2.0

    /// Accounting granularity. 64 samples is 0.33 ms at 192 kHz and 1.33 ms
    /// at 48 kHz. The guard proves its bound on block-aligned windows; the
    /// internal ceiling margin below covers windows that start mid-block.
    static let decimation = 64

    static func meanSquare(forDBr dBr: Float) -> Float {
        referenceMeanSquare * powf(10.0, dBr / 10.0)
    }

    static func dBr(forMeanSquare meanSquare: Float) -> Float {
        10.0 * log10f(max(1e-12, meanSquare) / referenceMeanSquare)
    }
}

// MARK: - Reporting meter

/// A uniform sliding 60-second window over the COMPLETE multiplex, exactly as
/// emitted. Reporting only.
struct BS412MultiplexPowerMeter {
    private var ring: [Float] = [0.0]
    private var index = 0
    private var filled = 0
    private var sum: Double = 0.0
    private var blockEnergy: Float = 0.0
    private var blockCount = 0
    private var blocksPerWindow = 1
    private var blocksPerSecond: Float = 1.0

    /// A complete 60 seconds has been observed.
    var windowValid: Bool { filled >= blocksPerWindow }

    var secondsObserved: Float {
        min(BS412.windowSeconds, Float(filled) / max(1e-6, blocksPerSecond))
    }

    var meanSquare: Float {
        let samples = max(1, filled * BS412.decimation)
        return Float(sum / Double(samples))
    }

    var powerDBr: Float { BS412.dBr(forMeanSquare: meanSquare) }

    mutating func configure(sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        let blocks = max(1, Int((sr * BS412.windowSeconds).rounded()) / BS412.decimation)
        blocksPerSecond = sr / Float(BS412.decimation)
        guard blocks != blocksPerWindow else { return }
        blocksPerWindow = blocks
        ring = [Float](repeating: 0.0, count: blocks)
        reset()
    }

    mutating func reset() {
        index = 0
        filled = 0
        sum = 0.0
        blockEnergy = 0.0
        blockCount = 0
        for i in 0..<ring.count { ring[i] = 0.0 }
    }

    /// One emitted sample, in the modulation domain. Returns true when this
    /// sample completed a block, i.e. when the reading actually changed.
    @discardableResult
    @inline(__always)
    mutating func process(_ x: Float) -> Bool {
        let value = x.isFinite ? x : 0.0
        blockEnergy += value * value
        blockCount += 1
        guard blockCount >= BS412.decimation else { return false }
        let energy = zapDenorm(blockEnergy)
        blockEnergy = 0.0
        blockCount = 0
        if filled >= blocksPerWindow {
            sum -= Double(ring[index])
        } else {
            filled += 1
        }
        ring[index] = energy
        sum += Double(energy)
        index += 1
        if index >= blocksPerWindow { index = 0 }
        return true
    }
}

// MARK: - Primary rider

/// The transparent gain ride. FEED-FORWARD: it predicts from the audio as it
/// arrives, BEFORE its own gain, so it is not a loop closed around a lagging
/// 60-second average.
///
/// The pre-0.65-fix controller was exactly that loop, and it could not hold
/// the Recommendation's "any interval of 60 s": from unity, a steady
/// +6.02 dBr input still averaged about +2.35 dBr across its first completed
/// minute. Feed-forward fixes the lag; the guard behind it fixes the proof.
///
/// Holding every prediction window at or under the ceiling is a stronger
/// condition than the Recommendation requires -- it forgoes the loudness an
/// ideal processor could win by averaging a hot passage against a quiet one.
/// That is deliberate: it is what keeps the hard guard idle, and the slow
/// release still recovers across a minute.
struct BS412Rider {
    /// Prediction window. Short enough to react before a hot passage can
    /// spend the minute, long enough not to pump.
    static let predictionSeconds: Float = 1.0
    static let attackSeconds: Float = 0.1
    static let releaseSeconds: Float = 50.0
    /// Headroom the rider keeps below the operator's ceiling, so block
    /// granularity and float error do not hand work to the guard.
    static let internalMarginDB: Float = 0.05

    private(set) var gain: Float = 1.0
    private(set) var unachievable = false

    private var audioRing: [Float] = [0.0]
    private var subcarrierRing: [Float] = [0.0]
    private var index = 0
    private var filled = 0
    private var audioSum: Double = 0.0
    private var subcarrierSum: Double = 0.0
    private var blockAudio: Float = 0.0
    private var blockSubcarrier: Float = 0.0
    private var blockCount = 0
    private var blocksPerWindow = 1
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0

    var gainReductionDB: Float { -20.0 * log10f(max(1e-6, gain)) }

    /// How much of the prediction window holds real history (0 ... 1 s).
    /// Read by the generator-level wiring tests: the rider must observe
    /// whether or not the stage is enforcing, or enabling it starts cold.
    var observedSeconds: Float {
        Float(filled) / Float(max(1, blocksPerWindow)) * Self.predictionSeconds
    }

    mutating func configure(sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        let blocks = max(1, Int((sr * Self.predictionSeconds).rounded()) / BS412.decimation)
        // Per BLOCK, not per sample: the prediction only changes once per
        // block, and at long time constants a per-sample step underflows
        // Float32 and stalls the gain short of its target.
        let blocksPerSecond = sr / Float(BS412.decimation)
        attackCoeff = expf(-1.0 / (Self.attackSeconds * blocksPerSecond))
        releaseCoeff = expf(-1.0 / (Self.releaseSeconds * blocksPerSecond))
        guard blocks != blocksPerWindow else { return }
        blocksPerWindow = blocks
        audioRing = [Float](repeating: 0.0, count: blocks)
        subcarrierRing = [Float](repeating: 0.0, count: blocks)
        resetWindow()
    }

    mutating func reset() {
        gain = 1.0
        unachievable = false
        resetWindow()
    }

    private mutating func resetWindow() {
        index = 0
        filled = 0
        audioSum = 0.0
        subcarrierSum = 0.0
        blockAudio = 0.0
        blockSubcarrier = 0.0
        blockCount = 0
        for i in 0..<audioRing.count {
            audioRing[i] = 0.0
            subcarrierRing[i] = 0.0
        }
    }

    /// One sample of PRE-control audio and the subcarriers that will be added
    /// to it. Returns true on a block boundary, when `gain` has been stepped.
    @discardableResult
    @inline(__always)
    mutating func observe(audio: Float, subcarriers: Float, ceilingDBr: Float) -> Bool {
        let a = audio.isFinite ? audio : 0.0
        let s = subcarriers.isFinite ? subcarriers : 0.0
        blockAudio += a * a
        blockSubcarrier += s * s
        blockCount += 1
        guard blockCount >= BS412.decimation else { return false }
        let audioEnergy = zapDenorm(blockAudio)
        let subEnergy = zapDenorm(blockSubcarrier)
        blockAudio = 0.0
        blockSubcarrier = 0.0
        blockCount = 0
        if filled >= blocksPerWindow {
            audioSum -= Double(audioRing[index])
            subcarrierSum -= Double(subcarrierRing[index])
        } else {
            filled += 1
        }
        audioRing[index] = audioEnergy
        subcarrierRing[index] = subEnergy
        audioSum += Double(audioEnergy)
        subcarrierSum += Double(subEnergy)
        index += 1
        if index >= blocksPerWindow { index = 0 }
        step(ceilingDBr: ceilingDBr)
        return true
    }

    private mutating func step(ceilingDBr: Float) {
        let samples = Double(max(1, filled * BS412.decimation))
        let audioMeanSquare = Float(audioSum / samples)
        let subcarrierMeanSquare = Float(subcarrierSum / samples)
        let ceiling = BS412.meanSquare(forDBr: ceilingDBr - Self.internalMarginDB)

        var target: Float = 1.0
        if subcarrierMeanSquare >= ceiling {
            // Nothing the audio path can do. Say so; do not touch the
            // subcarriers.
            unachievable = true
            target = 0.0
        } else {
            unachievable = false
            let headroom = ceiling - subcarrierMeanSquare
            if audioMeanSquare > headroom, audioMeanSquare > 1e-12 {
                // Pre-control energy, so this is a direct solve and not the
                // half-step a measurement of the CONTROLLED signal gives.
                target = sqrtf(headroom / audioMeanSquare)
            }
        }
        target = min(1.0, max(0.0, target))
        let coeff = target < gain ? attackCoeff : releaseCoeff
        gain = zapDenorm((coeff * gain) + ((1.0 - coeff) * target))
    }
}

// MARK: - Compliance guard

/// The invariant that actually proves the Recommendation: after every block,
/// the total energy in the rolling 60-second window is at or below
/// `ceiling * windowSampleCount`. Not a smoother -- an energy budget.
///
/// It runs after all audio-only peak control and the budget governor, and
/// BEFORE pilot and RDS are summed, so it can attenuate the reducible part
/// alone. In normal operation the rider keeps it idle and it is bit-
/// transparent.
struct BS412ComplianceGuard {
    /// Extra headroom under the operator ceiling. The bound below is proved
    /// for block-aligned windows; a window starting mid-block can differ by
    /// at most one block's energy, and with the emitted composite bounded to
    /// 1.0 that is `decimation / windowSamples` of the budget -- under
    /// 0.0002 dB at every supported rate. This margin is far larger, and is
    /// also what absorbs float error in the rolling sum.
    static let internalMarginDB: Float = 0.01

    /// How long an intervention stays visible in telemetry. Telemetry is
    /// sampled per render block, and on ALSA only every fourth period, so a
    /// few-sample flag is invisible: an isolated guard event has to still be
    /// set at the next publication point or it may as well not be reported.
    static let activeHoldSeconds: Float = 0.5

    private(set) var unachievable = false
    private(set) var active = false

    /// Real emitted block energies only. Slots never written stay 0 and are
    /// accounted through `reservePerBlock` instead, so changing the reserve
    /// is O(1) and never discards measured history.
    private var ring: [Float] = [0.0]
    private var index = 0
    private var observedBlocks = 0
    private var sum: Double = 0.0
    private var blocksPerWindow = 1
    private var windowSamples: Float = 1.0
    /// Energy charged to slots that have not been emitted yet. Pilot and RDS
    /// are NOT reducible, so pretending unobserved history is silent would
    /// let an early hot passage spend a minute's budget that later
    /// pilot-only samples then cannot fit into at any audio gain.
    private var reservePerBlock: Float = 0.0
    private var remainingBlockEnergy: Float = 0.0
    private var remainingSamples = 0
    private var blockEnergy: Float = 0.0
    private var blockSubcarrierEnergy: Float = 0.0
    private var impossibleRun = 0
    private var activeHoldSamples = 1
    private var activeHold = 0
    private var wasEnforcing = false
    private var enforcedCeilingDBr: Float = 0.0
    private(set) var historyForgivenCount = 0

    mutating func configure(sampleRate: Float, subcarrierReserveMeanSquare: Float) {
        let sr = max(8_000.0, sampleRate)
        let blocks = max(1, Int((sr * BS412.windowSeconds).rounded()) / BS412.decimation)
        windowSamples = Float(blocks * BS412.decimation)
        activeHoldSamples = max(1, Int((sr * Self.activeHoldSeconds).rounded()))
        setSubcarrierReserve(subcarrierReserveMeanSquare)
        guard blocks != blocksPerWindow else { return }
        blocksPerWindow = blocks
        ring = [Float](repeating: 0.0, count: blocks)
        reset()
    }

    /// Update the unavoidable future subcarrier energy. Pilot level and the
    /// deviation scale are live-apply, so this MUST be called when they
    /// change: a stale reserve under-charges the unobserved slots and lets a
    /// completed window run over (measured at +0.47 dBr against a 0 dBr
    /// ceiling after a live pilot increase during warm-up).
    ///
    /// O(1) and history-preserving by construction, because the reserve is
    /// not stored in the ring.
    mutating func setSubcarrierReserve(_ meanSquare: Float) {
        reservePerBlock = max(0.0, meanSquare) * Float(BS412.decimation)
    }

    /// The reserve currently charged to unobserved slots, as a mean square.
    /// Read by the generator-level wiring test that proves a live pilot or
    /// deviation edit reaches this stage.
    var subcarrierReserveMeanSquare: Float { reservePerBlock / Float(BS412.decimation) }

    /// How much of the 60 s window holds real emitted history.
    var observedSeconds: Float {
        Float(observedBlocks) / Float(max(1, blocksPerWindow)) * BS412.windowSeconds
    }

    mutating func reset() {
        index = 0
        observedBlocks = 0
        sum = 0.0
        for i in 0..<ring.count { ring[i] = 0.0 }
        remainingSamples = 0
        blockEnergy = 0.0
        blockSubcarrierEnergy = 0.0
        impossibleRun = 0
        unachievable = false
        active = false
        activeHold = 0
        wasEnforcing = false
    }

    /// Pass one sample through the budget. `audio` is the reducible
    /// component, `subcarriers` the fixed one, both in the modulation domain.
    ///
    /// `enforcing` false still ACCOUNTS the sample and advances the window --
    /// that is what lets the operator switch the stage on and have it act on
    /// real history instead of starting a fresh 60-second blind period -- but
    /// never attenuates.
    @inline(__always)
    mutating func process(
        audio: Float, subcarriers: Float, ceilingDBr: Float, enforcing: Bool
    ) -> Float {
        let a = audio.isFinite ? audio : 0.0
        let s = subcarriers.isFinite ? subcarriers : 0.0

        if remainingSamples <= 0 {
            beginBlock(ceilingDBr: ceilingDBr)
        }
        if enforcing && (!wasEnforcing || ceilingDBr < enforcedCeilingDBr) {
            forgiveUncontrolledHistory(ceilingDBr: ceilingDBr)
        }
        wasEnforcing = enforcing
        enforcedCeilingDBr = ceilingDBr

        var emitted = a + s
        if enforcing {
            let allowance = remainingBlockEnergy / Float(remainingSamples)
            let limit = sqrtf(max(0.0, allowance))
            if fabsf(emitted) > limit {
                emitted = (a * solveGain(audio: a, subcarriers: s, limit: limit)) + s
                activeHold = activeHoldSamples
            }
        }
        if activeHold > 0 { activeHold -= 1 }
        active = enforcing && activeHold > 0

        let energy = emitted * emitted
        remainingBlockEnergy = max(0.0, remainingBlockEnergy - energy)
        remainingSamples -= 1
        blockEnergy += energy
        blockSubcarrierEnergy += s * s
        if remainingSamples <= 0 { endBlock(ceilingDBr: ceilingDBr) }
        return emitted
    }

    /// Largest `h` in [0, 1] with `abs(h * audio + subcarriers) <= limit`.
    /// Solved as an interval, never iterated.
    @inline(__always)
    private func solveGain(audio: Float, subcarriers: Float, limit: Float) -> Float {
        guard audio != 0.0 else {
            // No audio gain can change this sample. Whether that is a fault
            // is decided per BLOCK, below -- a sinusoid routinely exceeds a
            // single sample's flat share of the block budget near its peak,
            // and latching on that would call every feasible configuration
            // impossible.
            return 1.0
        }
        let r0 = (-limit - subcarriers) / audio
        let r1 = (limit - subcarriers) / audio
        let low = max(0.0, min(r0, r1))
        let high = min(1.0, max(r0, r1))
        if high < low {
            // Empty interval: no gain in [0, 1] fits this sample. Take the
            // value that minimises the absolute total. Again, not a verdict
            // on the configuration -- see the per-block test below.
            return min(1.0, max(0.0, -subcarriers / audio))
        }
        return high
    }

    private func windowLimit(ceilingDBr: Float) -> Double {
        Double(BS412.meanSquare(forDBr: ceilingDBr - Self.internalMarginDB)) * Double(windowSamples)
    }

    /// The window after the current block, less the block itself: every real
    /// slot except the one about to be replaced, plus a reserve for each slot
    /// that still holds nothing.
    private var pastEnergy: Double {
        let observedAfter = min(blocksPerWindow, observedBlocks + (observedBlocks < blocksPerWindow ? 1 : 0))
        let unobservedAfter = max(0, blocksPerWindow - observedAfter)
        return (sum - Double(ring[index]))
            + (Double(reservePerBlock) * Double(unobservedAfter))
    }

    private mutating func beginBlock(ceilingDBr: Float) {
        remainingBlockEnergy = Float(max(0.0, windowLimit(ceilingDBr: ceilingDBr) - pastEnergy))
        remainingSamples = BS412.decimation
        blockEnergy = 0.0
    }

    /// Called when enforcement starts, or the ceiling is lowered while it
    /// runs. History the guard did not control (the stage was off, or held a
    /// higher ceiling) may already have spent more than the window allows.
    /// Paying that debt back is only possible by muting the audio until the
    /// over-budget minute has aged out -- up to 60 s of silence on dense
    /// programme, which is what happened when BS.412 was switched on behind
    /// Advanced Dynamics. Already-transmitted audio cannot be un-transmitted,
    /// so a window straddling the switch is over the ceiling whatever the
    /// guard does; muting buys nothing. The guard therefore forgives such
    /// history: it restarts from the cold-start state (unobserved slots
    /// charged with the subcarrier reserve), in which every window lying
    /// wholly after the switch is still proved. History that fits the new
    /// budget is kept, so control stays informed when it can.
    private mutating func forgiveUncontrolledHistory(ceilingDBr: Float) {
        let limit = windowLimit(ceilingDBr: ceilingDBr)
        let blockShare = limit / Double(max(1, blocksPerWindow))
        guard pastEnergy + Double(blockEnergy) > limit - blockShare else { return }
        observedBlocks = 0
        sum = 0.0
        for i in 0..<ring.count { ring[i] = 0.0 }
        historyForgivenCount += 1
        if remainingSamples > 0 {
            remainingBlockEnergy = Float(max(0.0, limit - pastEnergy - Double(blockEnergy)))
        }
    }

    private mutating func endBlock(ceilingDBr: Float) {
        // The honest test for "no audio gain can meet this ceiling": the
        // FIXED part alone, over a whole block, already spends more than the
        // block's share of the budget. A run of them means it is the
        // configuration, not a transient.
        let ceiling = BS412.meanSquare(forDBr: ceilingDBr)
        let blockShare = ceiling * Float(BS412.decimation)
        if blockSubcarrierEnergy > blockShare {
            impossibleRun = min(impossibleRun + 1, 64)
        } else if impossibleRun > 0 {
            impossibleRun -= 1
        }
        unachievable = impossibleRun >= 8
        blockSubcarrierEnergy = 0.0

        let energy = zapDenorm(blockEnergy)
        if observedBlocks < blocksPerWindow { observedBlocks += 1 }
        sum -= Double(ring[index])
        ring[index] = energy
        sum += Double(energy)
        index += 1
        if index >= blocksPerWindow { index = 0 }
        blockEnergy = 0.0
        remainingSamples = 0
    }

    /// Energy currently accounted in the window, for tests.
    var windowEnergy: Double { sum }
    var windowSampleCount: Float { windowSamples }
}
