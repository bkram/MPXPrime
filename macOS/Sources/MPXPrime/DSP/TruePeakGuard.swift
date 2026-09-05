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
/// shared gain (stereo-linked) rides both channels with attack = window / 4
/// and a hard floor `gain = min(gain, target)`, so whatever the smoother's lag,
/// the sample leaving the line never exceeds the ceiling on the interpolated
/// estimate. Same detector-floor design as the final MPX `LookaheadLimiter`
/// (chain review A1b), applied to L/R with a reconstruction-aware detector.
///
/// Real-time safe: every buffer is allocated in `configure`.
struct StereoTruePeakGuard {
    private(set) var enabled: Bool = false
    /// Linear ceiling the interpolated peak is held to.
    var ceiling: Float = 0.891_25

    private var interpL = LinearPhaseFIRInterpolator()
    private var interpR = LinearPhaseFIRInterpolator()
    private var osL = [Float](repeating: 0, count: 4)
    private var osR = [Float](repeating: 0, count: 4)
    private var delayL: [Float] = []
    private var delayR: [Float] = []
    private var writeIndex: Int = 0
    private var lookaheadSamples: Int = 0
    private var windowMax = SlidingWindowMax()
    private var gain: Float = 1.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0

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
    mutating func configure(sampleRate: Float, ceilingLinear: Float, lookaheadMS: Float = 2.0, enabled: Bool) {
        self.enabled = enabled
        self.ceiling = clampf(ceilingLinear, 0.05, 1.0)
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
        let attackS = Float(lookaheadSamples) / (4.0 * sr)
        attackCoeff = expf(-1.0 / (max(1e-5, attackS) * sr))
        releaseCoeff = expf(-1.0 / (0.1 * sr))
        holdSamples = Int((0.004 * sr).rounded())
        holdCounter = 0
        if !enabled { gain = 1.0 }
    }

    mutating func reset() {
        for i in 0..<delayL.count { delayL[i] = 0; delayR[i] = 0 }
        writeIndex = 0
        windowMax.reset()
        gain = 1.0
        holdCounter = 0
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        guard enabled, lookaheadSamples > 0 else { return (left, right) }

        // Reconstruction-aware detector: the largest interpolated magnitude
        // on either channel for the sample just pushed.
        var peak: Float = 0
        osL.withUnsafeMutableBufferPointer { o in
            // swiftlint:disable:next force_unwrapping
            interpL.push(left, into: o.baseAddress!)
            for i in 0..<4 { peak = max(peak, fabsf(o[i])) }
        }
        osR.withUnsafeMutableBufferPointer { o in
            // swiftlint:disable:next force_unwrapping
            interpR.push(right, into: o.baseAddress!)
            for i in 0..<4 { peak = max(peak, fabsf(o[i])) }
        }
        let peakAhead = windowMax.push(peak)

        let delayedL = delayL[writeIndex]
        let delayedR = delayR[writeIndex]
        delayL[writeIndex] = left
        delayR[writeIndex] = right
        writeIndex += 1
        if writeIndex >= lookaheadSamples { writeIndex = 0 }

        var target: Float = 1.0
        if peakAhead > ceiling {
            target = ceiling / max(1e-9, peakAhead)
        }
        if target < gain {
            gain = (attackCoeff * gain) + ((1.0 - attackCoeff) * target)
            holdCounter = holdSamples
        } else if holdCounter > 0 {
            holdCounter -= 1
        } else {
            gain = (releaseCoeff * gain) + ((1.0 - releaseCoeff) * target)
        }
        // Floor: the exiting sample never exceeds the ceiling on the estimate,
        // whatever the smoother's residual lag.
        gain = min(gain, target)
        return (delayedL * gain, delayedR * gain)
    }
}
