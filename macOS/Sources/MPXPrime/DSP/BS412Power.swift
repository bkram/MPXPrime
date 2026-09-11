#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

// ITU-R BS.412-9 multiplex power, measured the way the Recommendation
// actually defines it.
//
// Three things in section 2.5.1 are load-bearing and the pre-0.60 stage got
// all three wrong (0.60 audit, P0-6):
//
//  1. The quantity is the power of the COMPLETE multiplex signal, pilot and
//     additional signals INCLUDED. The old stage observed the audio composite
//     before pilot / RDS injection, so it could not see roughly a tenth of
//     the power it was supposed to be limiting.
//  2. The reference is dBr, where 0 dBr is the power of a sine causing
//     +/- 19 kHz deviation. The old stage treated its threshold as dB
//     relative to normalised FULL-SCALE power, which is a different scale
//     entirely: the shipped default of "-10 dB" was about +4.9 dBr, i.e.
//     five dB ABOVE the compliance ceiling it claimed to enforce.
//  3. The integration is over ANY 60-second interval. The old stage let the
//     operator pick 30 to 90 seconds while the UI still said BS.412.
//
// The measurement therefore runs on the finished composite, in the
// modulation domain, and the CONTROLLER rides the audio path alone --
// subcarriers keep their amplitude, which is the whole reason they are
// injected last. Because the controller cannot touch the subcarriers, it
// solves for the audio gain that puts the TOTAL at the ceiling, and reports
// an unachievable configuration rather than quietly squashing the pilot.

/// A uniform sliding 60-second power window over the complete multiplex,
/// plus the subcarrier-only power inside the same window so the controller
/// knows how much of the budget it cannot reach.
struct BS412MultiplexPowerMeter {
    /// The Recommendation's integration time. Not operator-settable: a
    /// 30- or 90-second window is not BS.412, whatever it is labelled.
    static let windowSeconds: Float = 60.0

    /// 0 dBr = a sine at +/- 19 kHz deviation. The composite is normalised so
    /// that |x| = 1.0 is 75 kHz (`deviationScale` scales the whole composite,
    /// subcarriers included, which is what keeps pilot injection at 9 % of
    /// the system's full deviation at any `mpx_deviation_khz`), so that sine
    /// has amplitude 19/75 and mean square (19/75)^2 / 2 = 0.0320889.
    static let referenceMeanSquare: Float = ((19.0 / 75.0) * (19.0 / 75.0)) / 2.0

    /// Block size for the ring. The window is uniform; this only sets its
    /// granularity (one third of a millisecond at 192 kHz). The controller
    /// steps at the same rate, which is also the only rate at which the
    /// measurement can change.
    static let decimation = 64

    private var totalRing: [Float] = [0.0]
    private var subcarrierRing: [Float] = [0.0]
    private var index = 0
    private var filled = 0
    private var totalSum: Double = 0.0
    private var subcarrierSum: Double = 0.0
    private var blockTotal: Float = 0.0
    private var blockSubcarrier: Float = 0.0
    private var blockCount = 0
    private var blocksPerWindow = 1
    private var blocksPerSecond: Float = 1.0

    /// Whether a full 60 seconds has been observed. The reading before that
    /// is the true average of everything since the engine started, which is
    /// a legitimate thing to limit on, but it is not yet the statistic the
    /// Recommendation asks for.
    var primed: Bool { filled >= blocksPerWindow }

    var secondsObserved: Float { Float(filled) / max(1e-6, blocksPerSecond) }

    /// Mean square of the complete multiplex over the window.
    var meanSquare: Float {
        let n = max(1, filled)
        return Float(totalSum / Double(n))
    }

    /// Mean square of pilot + RDS alone over the same window.
    var subcarrierMeanSquare: Float {
        let n = max(1, filled)
        return Float(subcarrierSum / Double(n))
    }

    /// Complete-multiplex power in dBr.
    var powerDBr: Float {
        10.0 * log10f(max(1e-12, meanSquare) / Self.referenceMeanSquare)
    }

    mutating func configure(sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        let blocks = max(1, Int((sr * Self.windowSeconds).rounded()) / Self.decimation)
        blocksPerSecond = sr / Float(Self.decimation)
        guard blocks != blocksPerWindow else { return }
        blocksPerWindow = blocks
        totalRing = [Float](repeating: 0.0, count: blocks)
        subcarrierRing = [Float](repeating: 0.0, count: blocks)
        reset()
    }

    mutating func reset() {
        index = 0
        filled = 0
        totalSum = 0.0
        subcarrierSum = 0.0
        blockTotal = 0.0
        blockSubcarrier = 0.0
        blockCount = 0
        for i in 0..<totalRing.count {
            totalRing[i] = 0.0
            subcarrierRing[i] = 0.0
        }
    }

    /// One sample of the finished composite, in the modulation domain, with
    /// the subcarrier content of that same sample. Returns true when this
    /// sample completed a block, i.e. when the reading actually changed.
    @discardableResult
    @inline(__always)
    mutating func process(total: Float, subcarriers: Float) -> Bool {
        blockTotal += total * total
        blockSubcarrier += subcarriers * subcarriers
        blockCount += 1
        guard blockCount >= Self.decimation else { return false }
        let inv = 1.0 / Float(Self.decimation)
        let totalMean = zapDenorm(blockTotal * inv)
        let subMean = zapDenorm(blockSubcarrier * inv)
        blockTotal = 0.0
        blockSubcarrier = 0.0
        blockCount = 0
        if filled >= blocksPerWindow {
            totalSum -= Double(totalRing[index])
            subcarrierSum -= Double(subcarrierRing[index])
        } else {
            filled += 1
        }
        totalRing[index] = totalMean
        subcarrierRing[index] = subMean
        totalSum += Double(totalMean)
        subcarrierSum += Double(subMean)
        index += 1
        if index >= blocksPerWindow { index = 0 }
        return true
    }
}

/// The slow gain ride. Separate from the meter on purpose: the measurement is
/// a compliance statistic that must keep running whether or not anything is
/// acting on it, and the actuator touches the audio path only.
struct BS412GainController {
    /// Below this the configuration cannot be met by reducing audio at all,
    /// because pilot and RDS alone exceed the ceiling.
    private(set) var unachievable = false
    private(set) var currentGain: Float = 1.0

    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    /// Never ride the audio further than this; past it the configuration is
    /// wrong and the operator needs to know, not be quietly faded out.
    private static let minGain: Float = 0.05

    var gainReductionDB: Float {
        -20.0 * log10f(max(1e-6, currentGain))
    }

    /// The loop has to be slow COMPARED WITH the 60-second window it reads,
    /// or it chases a measurement that has not caught up yet: at a 1 s time
    /// constant the gain swung between 0.05 and 0.96 forever while the
    /// average sat near the ceiling (measured). These are long on purpose --
    /// an average-power limit cannot be corrected faster than the average is
    /// measured, and real BS.412 controllers ride over tens of seconds.
    private static let attackSeconds: Float = 25.0
    private static let releaseSeconds: Float = 50.0

    mutating func configure(sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        // Per BLOCK, not per sample. Two reasons, and the second one is not
        // cosmetic: the reading only changes once per block, and at these
        // time constants a per-sample step underflows Float32 -- the
        // increment (1 - coeff) * (target - current) fell below one ULP of
        // the gain and the smoother STALLED, parking 0.84 dB past the
        // ceiling and staying there forever (measured).
        let blocksPerSecond = sr / Float(BS412MultiplexPowerMeter.decimation)
        attackCoeff = expf(-1.0 / (Self.attackSeconds * blocksPerSecond))
        releaseCoeff = expf(-1.0 / (Self.releaseSeconds * blocksPerSecond))
    }

    mutating func reset() {
        currentGain = 1.0
        unachievable = false
    }

    /// Step the gain once, at a block boundary. Returns the gain to apply to
    /// the AUDIO composite.
    @inline(__always)
    mutating func update(meter: BS412MultiplexPowerMeter, ceilingDBr: Float) -> Float {
        let ceilingMeanSquare =
            BS412MultiplexPowerMeter.referenceMeanSquare * powf(10.0, ceilingDBr / 10.0)
        let subcarrier = meter.subcarrierMeanSquare
        let audio = max(0.0, meter.meanSquare - subcarrier)
        var target: Float = 1.0
        if subcarrier >= ceilingMeanSquare {
            // Pilot and RDS alone are over budget. Reducing audio cannot fix
            // that and attenuating THEM would break stereo and RDS decoding,
            // so hold and report it.
            unachievable = true
            target = Self.minGain
        } else {
            unachievable = false
            let headroom = ceilingMeanSquare - subcarrier
            if audio > 1e-12 {
                // The measured audio power ALREADY has the current gain in
                // it, so the correction is multiplicative. Solving
                // `sqrt(headroom / measured)` directly would only ever apply
                // half the required reduction in dB, because it treats a
                // measurement of the controlled signal as if it were the
                // uncontrolled one. Never boosts: the ceiling is a limit, not
                // a target.
                target = min(1.0, max(Self.minGain, currentGain * sqrtf(headroom / audio)))
            }
        }
        let coeff = target < currentGain ? attackCoeff : releaseCoeff
        currentGain = (coeff * currentGain) + ((1.0 - coeff) * target)
        currentGain = zapDenorm(currentGain)
        return currentGain
    }
}
