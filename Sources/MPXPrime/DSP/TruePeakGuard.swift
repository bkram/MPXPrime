#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation

/// Gain-riding true-peak guard for the processed-audio DIGITAL delivery target.
///
/// Why it exists: the pre-encode limiter bounds peaks at its ceiling in its 4x
/// oversampled domain and then decimates; the decimation FIR rings on a hard
/// transient it just clipped, so the limiter's OUTPUT can sit well above the
/// ceiling (a click program measured +1.4 dB, straight into the render clamp).
/// On the FM paths the composite clipper and the final look-ahead limiter
/// follow and catch it; on the digital target nothing did. This stage is what
/// makes `processed_audio_ceiling_dbtp` a true-peak claim rather than a
/// sample-peak one.
///
/// Topology: no clipping anywhere (clipping is what created the ringing). Both
/// channels are 4x interpolated with a Kaiser-sinc FIR, the largest of the
/// eight interpolated magnitudes per sample is the detector value, a sliding
/// window over the look-ahead delay finds the peak about to leave, and one
/// shared gain (stereo-linked) rides both channels through a
/// `LookaheadGainRamp`: a smooth ramp that reaches the required gain exactly
/// when the peak leaves, so the sample leaving the line never exceeds the
/// ceiling on the interpolated estimate and the gain never steps. Same design
/// as the final MPX `LookaheadLimiter`, applied to L/R with a
/// reconstruction-aware detector. (Until 2026-10 both wrote a hard floor
/// `gain = min(gain, target)` back into the smoother state, which stepped the
/// gain to each new target in one sample -- peak-control review F6.)
///
/// Real-time safe: every buffer is allocated in `configure`.
///
/// The ceilings are SEPARATE per polarity so the same stage serves the AM
/// Output mode, where 47 CFR 73.1570 allows positive peaks to 125 % while
/// negative peaks must stay at 100 % -- there the negative ceiling sits
/// 100/125 of full scale and the positive one at full scale, and asymmetric
/// program (speech, most music with a dominant polarity) uses the extra
/// positive room instead of being pulled down to the symmetric bound.
struct StereoTruePeakGuard {
    private(set) var enabled: Bool = false
    /// Linear ceiling the interpolated POSITIVE peak is held to.
    var ceiling: Float = 0.891_25 {
        didSet { if symmetric { ceilingNegative = ceiling } }
    }
    /// Linear ceiling for the NEGATIVE peak. Equal to `ceiling` unless the
    /// caller configured an asymmetric pair.
    private(set) var ceilingNegative: Float = 0.891_25
    private var symmetric: Bool = true

    private var interpL = LinearPhaseFIRInterpolator()
    private var interpR = LinearPhaseFIRInterpolator()
    private var osL = [Float](repeating: 0, count: 4)
    private var osR = [Float](repeating: 0, count: 4)
    private var windowMaxNegative = SlidingWindowMax()
    private var delayL: [Float] = []
    private var delayR: [Float] = []
    private var writeIndex: Int = 0
    private var lookaheadSamples: Int = 0
    private var windowMax = SlidingWindowMax()
    private var ramp = LookaheadGainRamp()
    private var gain: Float { ramp.gain }

    /// Host-rate samples of delay this stage adds to L/R.
    var latencySamples: Int { lookaheadSamples }

    var gainReductionDB: Float {
        max(0.0, -20.0 * log10f(max(1e-6, gain)))
    }

    /// - Parameters:
    ///   - lookaheadMS: how far ahead the detector looks. It is raised to at
    ///     least the interpolator's own group delay plus one sample, because
    ///     the estimate for a sample enters the window that late and must
    ///     still be inside it when the sample leaves the delay line.
    ///   - ceilingNegativeLinear: ceiling for the negative half. Defaults to
    ///     the positive one (a true-peak ceiling is symmetric); AM Output
    ///     passes a lower value to buy positive-peak headroom.
    mutating func configure(sampleRate: Float, ceilingLinear: Float,
                            ceilingNegativeLinear: Float? = nil,
                            lookaheadMS: Float = 2.0, enabled: Bool) {
        self.enabled = enabled
        self.symmetric = ceilingNegativeLinear == nil
        self.ceiling = clampf(ceilingLinear, 0.05, 1.0)
        self.ceilingNegative = clampf(ceilingNegativeLinear ?? ceilingLinear, 0.05, 1.0)
        let sr = max(8_000.0, sampleRate)
        // 4x reconstruction detector: passband to 0.45 fs, 60 dB stopband,
        // transition 0.1 fs -- short enough (tens of taps per phase) that the
        // group delay stays well inside a 2 ms look-ahead at every audio rate.
        interpL.configure(cutoffHz: 0.45 * sr, sampleRateOS: 4.0 * sr, interpolateFactor: 4,
                          stopBandDB: 60.0, transitionHz: 0.1 * sr)
        interpR.configure(cutoffHz: 0.45 * sr, sampleRateOS: 4.0 * sr, interpolateFactor: 4,
                          stopBandDB: 60.0, transitionHz: 0.1 * sr)
        let detectorDelay = interpL.groupDelayInputSamples
        let requested = max(0, Int((sr * clampf(lookaheadMS, 0.0, 20.0) * 0.001).rounded()))
        let samples = max(requested, detectorDelay + 1)
        if samples != lookaheadSamples || delayL.count != samples {
            lookaheadSamples = samples
            delayL = Array(repeating: 0.0, count: samples)
            delayR = Array(repeating: 0.0, count: samples)
            writeIndex = 0
        }
        windowMax.configure(windowLength: lookaheadSamples + 1)
        windowMaxNegative.configure(windowLength: lookaheadSamples + 1)
        // The estimates for the sample leaving the line arrive up to the
        // detector delay (plus one sample) after it entered, so a target
        // averaged over more than `lookahead - detectorDelay - 1` samples
        // could include windows that no longer hold those estimates. That is
        // the longest ramp that is still a bound (see `LookaheadGainRamp`).
        let rampSamples = max(0, lookaheadSamples - detectorDelay - 2)
        ramp.configure(rampSamples: rampSamples,
                       holdSamples: Int((0.004 * sr).rounded()),
                       releaseCoeff: expf(-1.0 / (0.1 * sr)))
    }

    mutating func reset() {
        for i in 0..<delayL.count { delayL[i] = 0; delayR[i] = 0 }
        writeIndex = 0
        windowMax.reset()
        windowMaxNegative.reset()
        ramp.reset()
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        guard enabled, lookaheadSamples > 0 else { return (left, right) }

        // Reconstruction-aware detector: the largest interpolated magnitude
        // on either channel for the sample just pushed.
        var peakPositive: Float = 0
        var peakNegative: Float = 0
        osL.withUnsafeMutableBufferPointer { o in
            // swiftlint:disable:next force_unwrapping
            interpL.push(left, into: o.baseAddress!)
            for i in 0..<4 {
                peakPositive = max(peakPositive, o[i])
                peakNegative = max(peakNegative, -o[i])
            }
        }
        osR.withUnsafeMutableBufferPointer { o in
            // swiftlint:disable:next force_unwrapping
            interpR.push(right, into: o.baseAddress!)
            for i in 0..<4 {
                peakPositive = max(peakPositive, o[i])
                peakNegative = max(peakNegative, -o[i])
            }
        }
        let positiveAhead = windowMax.push(peakPositive)
        let negativeAhead = windowMaxNegative.push(peakNegative)

        let delayedL = delayL[writeIndex]
        let delayedR = delayR[writeIndex]
        delayL[writeIndex] = left
        delayR[writeIndex] = right
        writeIndex += 1
        if writeIndex >= lookaheadSamples { writeIndex = 0 }

        var target: Float = 1.0
        if positiveAhead > ceiling {
            target = ceiling / max(1e-9, positiveAhead)
        }
        if negativeAhead > ceilingNegative {
            target = min(target, ceilingNegative / max(1e-9, negativeAhead))
        }
        let g = ramp.push(target)
        // Output floor on the SAMPLE value for Float rounding only; it never
        // feeds back into the gain state.
        var outL = delayedL * g
        var outR = delayedR * g
        outL = min(ceiling, max(-ceilingNegative, outL))
        outR = min(ceiling, max(-ceilingNegative, outR))
        return (outL, outR)
    }
}
