import Foundation

/// Allocation-free helper for spreading a clipping discontinuity over a
/// short, band-limited correction window.
///
/// Phase A primitive for the anti-aliased clipping work. It does not clip by
/// itself; callers detect a clipping-edge event, compute the discontinuity
/// amplitude they need to apply, and schedule that amplitude here at the
/// fractional crossing position. `process(_:)` then emits the precomputed
/// correction over subsequent samples.
struct BandLimitedStep {
    private var correction: [Float]
    private var writeIndex: Int = 0
    let windowSamples: Int
    let cutoffFraction: Float

    init(windowSamples requestedWindowSamples: Int = 16, cutoffFraction requestedCutoff: Float = 0.45) {
        let clampedWindow = max(4, min(64, requestedWindowSamples))
        self.windowSamples = clampedWindow
        self.cutoffFraction = min(0.49, max(0.05, requestedCutoff))
        self.correction = [Float](repeating: 0.0, count: clampedWindow)
    }

    mutating func reset() {
        for i in 0..<correction.count {
            correction[i] = 0.0
        }
        writeIndex = 0
    }

    /// Returns the fractional position where `previous -> current` crosses
    /// `threshold`, or nil when the segment does not cross. A result of 1.0
    /// means the crossing lands exactly on `current`; 0.0 is deliberately
    /// excluded so threshold-grazing at the previous sample does not double
    /// trigger across adjacent segments.
    static func crossingFraction(previous: Float, current: Float, threshold: Float) -> Float? {
        let delta = current - previous
        guard fabsf(delta) > 1e-12 else { return nil }
        let lo = min(previous, current)
        let hi = max(previous, current)
        guard threshold > lo && threshold <= hi else { return nil }
        let t = (threshold - previous) / delta
        guard t > 0.0 && t <= 1.0 else { return nil }
        return t
    }

    /// Schedule an area-normalized correction kernel. This is useful for
    /// finite correction residuals where the caller has already accounted
    /// for the steady-state signal value.
    mutating func schedule(stepAmplitude: Float, fractionalOffset: Float) {
        scheduleKernel(amplitude: stepAmplitude, fractionalOffset: fractionalOffset, shape: .impulse)
    }

    /// Schedule a finite BLEP-style correction for a value discontinuity.
    /// The correction starts and ends near zero; callers apply the naive
    /// step separately and use this to remove the broadband edge.
    mutating func scheduleStepCorrection(stepAmplitude: Float, fractionalOffset: Float) {
        scheduleKernel(amplitude: stepAmplitude, fractionalOffset: fractionalOffset, shape: .step)
    }

    /// Schedule a finite BLAMP-style correction for a slope discontinuity.
    /// This is the shape expected for soft-knee clipping, where the value
    /// is continuous but the derivative changes at the knee.
    mutating func scheduleRampCorrection(slopeDelta: Float, fractionalOffset: Float) {
        scheduleKernel(amplitude: slopeDelta, fractionalOffset: fractionalOffset, shape: .ramp)
    }

    private enum Shape {
        case impulse
        case step
        case ramp
    }

    private mutating func scheduleKernel(amplitude: Float, fractionalOffset: Float, shape: Shape) {
        guard fabsf(amplitude) > 1e-12 else { return }
        let frac = min(1.0, max(0.0, fractionalOffset))

        var impulseSum: Float = 0.0
        for n in 0..<windowSamples {
            impulseSum += Self.kernelTap(
                index: n,
                windowSamples: windowSamples,
                fractionalOffset: frac,
                cutoffFraction: cutoffFraction
            )
        }
        guard fabsf(impulseSum) > 1e-12 else { return }
        let impulseScale = 1.0 / impulseSum

        switch shape {
        case .impulse:
            for n in 0..<windowSamples {
                let idx = (writeIndex + n) % windowSamples
                correction[idx] += Self.kernelTap(
                    index: n,
                    windowSamples: windowSamples,
                    fractionalOffset: frac,
                    cutoffFraction: cutoffFraction
                ) * impulseScale * amplitude
            }

        case .step:
            let crossing = Self.crossingSample(windowSamples: windowSamples, fractionalOffset: frac)
            var stepAccum: Float = 0.0
            for n in 0..<windowSamples {
                let idx = (writeIndex + n) % windowSamples
                stepAccum += Self.kernelTap(
                    index: n,
                    windowSamples: windowSamples,
                    fractionalOffset: frac,
                    cutoffFraction: cutoffFraction
                ) * impulseScale
                let naive: Float = Float(n) >= crossing ? 1.0 : 0.0
                correction[idx] += (stepAccum - naive) * amplitude
            }

        case .ramp:
            let crossing = Self.crossingSample(windowSamples: windowSamples, fractionalOffset: frac)
            var stepAccum: Float = 0.0
            var rampAccum: Float = 0.0
            var mean: Float = 0.0
            for n in 0..<windowSamples {
                stepAccum += Self.kernelTap(
                    index: n,
                    windowSamples: windowSamples,
                    fractionalOffset: frac,
                    cutoffFraction: cutoffFraction
                ) * impulseScale
                let naive: Float = Float(n) >= crossing ? 1.0 : 0.0
                rampAccum += stepAccum - naive
                mean += rampAccum
            }
            mean /= Float(windowSamples)
            let rampScale = 1.0 / Float(windowSamples)

            stepAccum = 0.0
            rampAccum = 0.0
            for n in 0..<windowSamples {
                let idx = (writeIndex + n) % windowSamples
                stepAccum += Self.kernelTap(
                    index: n,
                    windowSamples: windowSamples,
                    fractionalOffset: frac,
                    cutoffFraction: cutoffFraction
                ) * impulseScale
                let naive: Float = Float(n) >= crossing ? 1.0 : 0.0
                rampAccum += stepAccum - naive
                correction[idx] += (rampAccum - mean) * rampScale * amplitude
            }
        }
    }

    mutating func process(_ input: Float) -> Float {
        let y = input + correction[writeIndex]
        correction[writeIndex] = 0.0
        writeIndex += 1
        if writeIndex >= windowSamples { writeIndex = 0 }
        return y
    }

    static func kernelTaps(
        windowSamples requestedWindowSamples: Int,
        fractionalOffset: Float,
        cutoffFraction requestedCutoff: Float = 0.45
    ) -> [Float] {
        normalizedImpulseTaps(
            windowSamples: requestedWindowSamples,
            fractionalOffset: fractionalOffset,
            cutoffFraction: requestedCutoff
        )
    }

    static func stepCorrectionTaps(
        windowSamples requestedWindowSamples: Int,
        fractionalOffset: Float,
        cutoffFraction requestedCutoff: Float = 0.45
    ) -> [Float] {
        let length = max(4, min(64, requestedWindowSamples))
        let cutoff = min(0.49, max(0.05, requestedCutoff))
        let frac = min(1.0, max(0.0, fractionalOffset))
        return correctionTaps(
            windowSamples: length,
            fractionalOffset: frac,
            cutoffFraction: cutoff,
            shape: .step
        )
    }

    static func rampCorrectionTaps(
        windowSamples requestedWindowSamples: Int,
        fractionalOffset: Float,
        cutoffFraction requestedCutoff: Float = 0.45
    ) -> [Float] {
        let length = max(4, min(64, requestedWindowSamples))
        let cutoff = min(0.49, max(0.05, requestedCutoff))
        let frac = min(1.0, max(0.0, fractionalOffset))
        return correctionTaps(
            windowSamples: length,
            fractionalOffset: frac,
            cutoffFraction: cutoff,
            shape: .ramp
        )
    }

    private static func normalizedImpulseTaps(
        windowSamples requestedWindowSamples: Int,
        fractionalOffset: Float,
        cutoffFraction requestedCutoff: Float
    ) -> [Float] {
        let length = max(4, min(64, requestedWindowSamples))
        let cutoff = min(0.49, max(0.05, requestedCutoff))
        let frac = min(1.0, max(0.0, fractionalOffset))
        var taps = [Float](repeating: 0.0, count: length)
        var sum: Float = 0.0
        for n in 0..<length {
            let tap = kernelTap(
                index: n,
                windowSamples: length,
                fractionalOffset: frac,
                cutoffFraction: cutoff
            )
            taps[n] = tap
            sum += tap
        }
        if fabsf(sum) > 1e-12 {
            let scale = 1.0 / sum
            for n in 0..<length {
                taps[n] *= scale
            }
        }
        return taps
    }

    private static func correctionTaps(
        windowSamples: Int,
        fractionalOffset: Float,
        cutoffFraction: Float,
        shape: Shape
    ) -> [Float] {
        let impulse = normalizedImpulseTaps(
            windowSamples: windowSamples,
            fractionalOffset: fractionalOffset,
            cutoffFraction: cutoffFraction
        )
        switch shape {
        case .impulse:
            return impulse
        case .step:
            return stepCorrection(fromNormalizedImpulse: impulse, fractionalOffset: fractionalOffset)
        case .ramp:
            let step = stepCorrection(fromNormalizedImpulse: impulse, fractionalOffset: fractionalOffset)
            var ramp = [Float](repeating: 0.0, count: step.count)
            var accum: Float = 0.0
            for i in 0..<step.count {
                accum += step[i]
                ramp[i] = accum
            }
            let mean = ramp.reduce(Float(0.0), +) / Float(max(1, ramp.count))
            let rampScale = 1.0 / Float(max(1, ramp.count))
            for i in 0..<ramp.count {
                ramp[i] = (ramp[i] - mean) * rampScale
            }
            return ramp
        }
    }

    private static func stepCorrection(
        fromNormalizedImpulse impulse: [Float],
        fractionalOffset: Float
    ) -> [Float] {
        let count = impulse.count
        let crossing = crossingSample(windowSamples: count, fractionalOffset: fractionalOffset)
        var out = [Float](repeating: 0.0, count: count)
        var accum: Float = 0.0
        for i in 0..<count {
            accum += impulse[i]
            let naive: Float = Float(i) >= crossing ? 1.0 : 0.0
            out[i] = accum - naive
        }
        return out
    }

    private static func crossingSample(windowSamples: Int, fractionalOffset: Float) -> Float {
        let center = (Float(windowSamples) - 1.0) * 0.5
        return center + (fractionalOffset - 0.5)
    }

    private static func kernelTap(
        index: Int,
        windowSamples: Int,
        fractionalOffset: Float,
        cutoffFraction: Float
    ) -> Float {
        let n = Float(index)
        let center = (Float(windowSamples) - 1.0) * 0.5
        let x = n - center - (fractionalOffset - 0.5)
        let sincArg = 2.0 * cutoffFraction * x
        let sincValue: Float
        if fabsf(sincArg) < 1e-6 {
            sincValue = 1.0
        } else {
            sincValue = sinf(.pi * sincArg) / (.pi * sincArg)
        }
        let window: Float
        if windowSamples <= 1 {
            window = 1.0
        } else {
            let phase = 2.0 * Float.pi * n / Float(windowSamples - 1)
            window = 0.5 - (0.5 * cosf(phase))
        }
        return 2.0 * cutoffFraction * sincValue * window
    }
}
