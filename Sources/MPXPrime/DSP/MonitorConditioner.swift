#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

/// Turns the feed a mode produces into something an operator can LISTEN to on
/// the monitor device, and applies the monitor level.
///
/// The monitor is a listening aid, never the on-air signal, so each mode is
/// conditioned to sound like what the receiving end will hear:
///
/// | Mode | Feed on the wire | What the monitor plays |
/// | --- | --- | --- |
/// | `mpx` | FM composite | the composite demodulated like a receiver (done in `MPXGenerator`; nothing to do here) |
/// | `fm` | processed L/R, pre-emphasised if the operator chose to apply it | the same, with pre-emphasis REMOVED -- a coder feeds a transmitter whose receivers de-emphasise |
/// | `hd` | flat, full-bandwidth L/R | the same; nothing to undo |
/// | `am` | mono, NRSC-1 pre-emphasised | the same, with the NRSC-1 curve removed (its exact inverse, not the FM one) |
///
/// `DeemphasisFilter` is the exact algebraic inverse of the encoder's
/// pre-emphasis network (`PreemphasisDesign`), so the un-emphasis is correct
/// rather than approximate, and it self-disables at 0 us.
///
/// Real-time safe: biquads and vDSP over caller-owned buffers, no allocation.
struct MonitorConditioner {

    /// What has to be undone for this mode, decided once at configure time.
    enum Shape: Equatable {
        /// The generator already produced decoded audio (MPX Output).
        case decodedComposite
        /// Remove whichever pre-emphasis curve the encoder applied. AM is
        /// `.nrsc`, not `.fm(tauUS: 75)` -- the two differ by 3.6 dB at
        /// 10 kHz, so the wrong inverse leaves the monitor bright.
        case deemphasised(PreemphasisCurve)
        /// Pass through unchanged.
        case flat
    }

    private(set) var shape: Shape = .flat

    // Monitor level. These belong to ONE thread -- whichever thread calls
    // `process` -- and a level change reaches them through an atomic owned by
    // the player, never by writing into this struct from the control side
    // (0.60 audit, P0-5: the render thread mutates this struct every block,
    // so a concurrent write from the main actor was a data race on a
    // multi-field value, not just an unsynchronised Float).
    private var currentGain: Float = 1.0
    private var targetGain: Float = 1.0
    private var rampRemaining: Int = 0
    private var rampStep: Float = 0.0
    /// About 10 ms, so a level move is inaudible rather than a step.
    private var rampLength: Int = 480

    /// The level the monitor is heading for. Test and diagnostic read.
    var gainLinear: Float { targetGain }

    /// What the player must seed its pending-gain atomic with straight after
    /// `configure`, so the FIRST block adopts the level it was configured
    /// with instead of ramping away from it. The atomics default to unity,
    /// so without this a monitor configured at, say, -12 dB faded to 0 dB
    /// over the first 10 ms and stayed there until the next control change.
    var publishedGainBitPattern: UInt32 { targetGain.bitPattern }

    private var deemphL = DeemphasisFilter()
    private var deemphR = DeemphasisFilter()

    /// The shape a mode needs. `hd` is flat by construction (the digital
    /// target forces pre-emphasis off), so it stays flat whatever
    /// `preemphasis_us` still says in the INI.
    static func shape(for mode: AppConfig.OperatingMode, config: AppConfig) -> Shape {
        switch mode {
        case .mpx: return .decodedComposite
        case .fm: return config.preemphasisUS > 0 ? .deemphasised(.fm(tauUS: config.preemphasisUS)) : .flat
        case .hd: return .flat
        case .am: return config.amPreemphasisUS > 0 ? .deemphasised(.nrsc) : .flat
        }
    }

    mutating func configure(shape: Shape, sampleRate: Float, gainDB: Double) {
        self.shape = shape
        let gain = powf(10.0, Float(gainDB) / 20.0)
        currentGain = gain
        targetGain = gain
        rampRemaining = 0
        rampStep = 0.0
        rampLength = max(1, Int((sampleRate * 0.010).rounded()))
        switch shape {
        case .deemphasised(let curve):
            deemphL.configure(curve: curve, sampleRate: sampleRate)
            deemphR.configure(curve: curve, sampleRate: sampleRate)
        case .decodedComposite, .flat:
            deemphL.configure(curve: .none, sampleRate: sampleRate)
            deemphR.configure(curve: .none, sampleRate: sampleRate)
        }
    }

    mutating func reset() {
        deemphL.reset()
        deemphR.reset()
    }

    /// Aim at a new level. MUST be called from the thread that calls
    /// `process` -- the player reads the control side's atomic at the top of
    /// its block and passes the value in here.
    mutating func setTargetGain(_ gain: Float) {
        let wanted = gain.isFinite ? max(0.0, gain) : 1.0
        guard wanted != targetGain else { return }
        targetGain = wanted
        rampRemaining = rampLength
        rampStep = (wanted - currentGain) / Float(rampLength)
    }

    /// A boosted monitor must not hand the converter something it will fold
    /// over; clamp here where it is deterministic.
    private func clampIfBoosted(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var lo: Float = -1.0
        var hi: Float = 1.0
        vDSP_vclip(left, 1, &lo, &hi, left, 1, vDSP_Length(frameCount))
        vDSP_vclip(right, 1, &lo, &hi, right, 1, vDSP_Length(frameCount))
    }

    /// Condition one block in place.
    mutating func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        if case .deemphasised = shape {
            for i in 0..<frameCount {
                left[i] = deemphL.process(left[i])
                right[i] = deemphR.process(right[i])
            }
        }
        var start = 0
        if rampRemaining > 0 {
            // Sample-by-sample only while a level move is in flight.
            let n = min(rampRemaining, frameCount)
            for i in 0..<n {
                currentGain += rampStep
                left[i] *= currentGain
                right[i] *= currentGain
            }
            rampRemaining -= n
            if rampRemaining == 0 { currentGain = targetGain }
            start = n
            if start >= frameCount {
                clampIfBoosted(left: left, right: right, frameCount: frameCount)
                return
            }
        }
        let remaining = frameCount - start
        guard currentGain != 1.0 else {
            if start > 0 { clampIfBoosted(left: left, right: right, frameCount: frameCount) }
            return
        }
        var g = currentGain
        vDSP_vsmul(left + start, 1, &g, left + start, 1, vDSP_Length(remaining))
        vDSP_vsmul(right + start, 1, &g, right + start, 1, vDSP_Length(remaining))
        if g > 1.0 || start > 0 {
            clampIfBoosted(left: left, right: right, frameCount: frameCount)
        }
    }
}
