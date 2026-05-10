import Accelerate
import Atomics
import Darwin
import Foundation
import os

private let twoPi = Float.pi * 2.0
private let pilotFreq = Float(19_000.0)
private let subcarrierFreq = Float(38_000.0)

@inline(__always)
private func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
    return max(lo, min(hi, x))
}

@inline(__always)
private func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float {
    return a + ((b - a) * t)
}

@inline(__always)
private func zapDenorm(_ x: Float) -> Float {
    return (fabsf(x) < 1e-20) ? 0.0 : x
}

struct SineCosOsc {
    var s: Float = 0.0
    var c: Float = 1.0
    var phase: Float = 0.0
    private var sinInc: Float = 0.0
    private var cosInc: Float = 1.0
    private var stepPhase: Float = 0.0
    private var renormCounter: Int = 0

    init() {}

    mutating func configure(freq: Float, sampleRate: Float) {
        let w = twoPi * freq / sampleRate
        stepPhase = w
        sinInc = sinf(w)
        cosInc = cosf(w)
        s = 0.0
        c = 1.0
        phase = 0.0
        renormCounter = 0
    }

    @inline(__always) mutating func step() {
        let ns = s * cosInc + c * sinInc
        let nc = c * cosInc - s * sinInc
        s = ns
        c = nc

        phase += stepPhase
        if phase >= twoPi { phase -= twoPi }

        renormCounter &+= 1
        if (renormCounter & 1023) == 0 {
            let mag2 = s * s + c * c
            if mag2 > 0 {
                let invMag = 1.0 / sqrtf(mag2)
                s *= invMag
                c *= invMag
            }
        }
    }

    @inline(__always) mutating func sin2x() -> Float {
        return 2.0 * s * c
    }
}

struct DCBlocker1p {
    private var r: Float = 0.995
    private var x1: Float = 0.0
    private var y1: Float = 0.0

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        let fc = max(1.0, min(50.0, cutoffHz))
        r = expf(-twoPi * fc / sr)
        x1 = 0.0
        y1 = 0.0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = x - x1 + r * y1
        x1 = x
        y1 = zapDenorm(y)
        return y
    }
}

/// Single-channel oversampled true-peak limiter. Used by `PreEncodeAudioLimiter`
/// per L/R channel before stereo encoding — operating on independent audio
/// channels (no multiplexed subcarrier), the trailing tanh ceiling here is a
/// normal soft-knee limiter behavior. **Never use this on the FM composite
/// signal** — the memoryless tanh on a (M + S·cos38k) waveform creates
/// intermod that demodulates as stereo-image collapse. Composite-domain
/// peak control belongs in `CompositeClipper` (distortion-cancelled).
struct OversampledPeakLimiter {
    var threshold: Float = 0.94
    var releaseMS: Float = 35.0
    var ceiling: Float = 0.985

    private var gain: Float = 1.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0
    private var prevPrevPrevIn: Float = 0.0
    private var prevPrevIn: Float = 0.0
    private var prevIn: Float = 0.0
    private var decimationLP = BiquadCascade6()
    private var initialized: Bool = false

    mutating func configure(sampleRate: Float, threshold: Float, releaseMS: Float = 35.0) {
        let sr = max(8_000.0, sampleRate * 4.0)
        self.threshold = clampf(threshold, 0.75, 0.995)
        self.releaseMS = max(8.0, releaseMS)
        let ceilingMargin = max(0.012, (1.0 - self.threshold) * 0.65)
        ceiling = min(0.999, self.threshold + ceilingMargin)

        let attackS = 0.00025 as Float
        let relS = max(0.008, Double(self.releaseMS) * 0.001)
        attackCoeff = expf(-1.0 / (attackS * sr))
        releaseCoeff = expf(-1.0 / Float(relS * Double(sr)))
        holdSamples = max(1, Int((0.004 * sr).rounded()))
        holdCounter = 0
        gain = 1.0
        prevPrevPrevIn = 0.0
        prevPrevIn = 0.0
        prevIn = 0.0
        let cutoff = min(sampleRate * 0.30, (sr * 0.5) - 1_000.0)
        decimationLP.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: sr)
        initialized = false
    }

    mutating func process(_ x: Float) -> Float {
        if !initialized {
            initialized = true
            prevPrevPrevIn = x
            prevPrevIn = x
            prevIn = x
            let q = processStep(x)
            return decimate(q1: q, q2: q, q3: q, q4: q)
        }

        let q1 = processStep(interpolateLagrange4(t: 0.25, current: x))
        let q2 = processStep(interpolateLagrange4(t: 0.50, current: x))
        let q3 = processStep(interpolateLagrange4(t: 0.75, current: x))
        let q4 = processStep(x)
        let output = decimate(q1: q1, q2: q2, q3: q3, q4: q4)

        prevPrevPrevIn = prevPrevIn
        prevPrevIn = prevIn
        prevIn = x
        return output
    }

    var gainReductionDB: Float {
        let safeGain = max(1e-6, gain)
        return max(0.0, -20.0 * log10f(safeGain))
    }

    @inline(__always)
    private mutating func processStep(_ x: Float) -> Float {
        let peak = fabsf(x)

        var targetGain: Float = 1.0
        if peak > threshold {
            targetGain = threshold / max(1e-9, peak)
        }
        targetGain = clampf(targetGain, 0.0, 1.0)

        if targetGain < gain {
            gain = (attackCoeff * gain) + ((1.0 - attackCoeff) * targetGain)
            holdCounter = holdSamples
        } else if holdCounter > 0 {
            holdCounter -= 1
        } else {
            gain = (releaseCoeff * gain) + ((1.0 - releaseCoeff) * targetGain)
        }

        let y = x * gain
        return clipToCeiling(y)
    }

    @inline(__always)
    private func interpolateLagrange4(t: Float, current: Float) -> Float {
        // Causal 4-point reconstruction between prevIn and current using
        // two prior samples for better curvature tracking.
        let l0 = -((t + 1.0) * t * (t - 1.0)) / 6.0
        let l1 = ((t + 2.0) * t * (t - 1.0)) * 0.5
        let l2 = -((t + 2.0) * (t + 1.0) * (t - 1.0)) * 0.5
        let l3 = ((t + 2.0) * (t + 1.0) * t) / 6.0
        return (prevPrevPrevIn * l0) + (prevPrevIn * l1) + (prevIn * l2) + (current * l3)
    }

    @inline(__always)
    private mutating func decimate(q1: Float, q2: Float, q3: Float, q4: Float) -> Float {
        _ = decimationLP.process(q1)
        _ = decimationLP.process(q2)
        _ = decimationLP.process(q3)
        return decimationLP.process(q4)
    }

    @inline(__always)
    private func clipToCeiling(_ x: Float) -> Float {
        let ax = fabsf(x)
        if ax <= threshold { return x }

        let knee = max(1e-4, ceiling - threshold)
        let clipped = threshold + ((ceiling - threshold) * tanhf((ax - threshold) / knee))
        return copysignf(min(clipped, ceiling), x)
    }
}

struct PreEncodeAudioLimiter {
    private var limiterL = OversampledPeakLimiter()
    private var limiterR = OversampledPeakLimiter()
    private var gainReduction: Float = 0.0

    mutating func configure(sampleRate: Float, threshold: Float, releaseMS: Float = 50.0) {
        limiterL.configure(sampleRate: sampleRate, threshold: threshold, releaseMS: releaseMS)
        limiterR.configure(sampleRate: sampleRate, threshold: threshold, releaseMS: releaseMS)
        gainReduction = 0.0
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        let outL = limiterL.process(left)
        let outR = limiterR.process(right)
        gainReduction = max(limiterL.gainReductionDB, limiterR.gainReductionDB)
        return (outL, outR)
    }

    var gainReductionDB: Float { gainReduction }
}

struct OnePoleLP {
    var alpha: Float = 1.0
    var state: Float = 0.0

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        let fc = max(8.0, min(45_000.0, cutoffHz))
        let sr = max(8_000.0, sampleRate)
        let pole = expf(-twoPi * fc / sr)
        alpha = clampf(1.0 - pole, 0.0, 1.0)
    }

    mutating func process(_ x: Float) -> Float {
        state += alpha * (x - state)
        state = zapDenorm(state)
        return state
    }
}

struct Biquad {
    var b0: Float = 1.0
    var b1: Float = 0.0
    var b2: Float = 0.0
    var a1: Float = 0.0
    var a2: Float = 0.0
    var z1: Float = 0.0
    var z2: Float = 0.0

    mutating func reset() {
        z1 = 0.0
        z2 = 0.0
    }

    mutating func configureIdentity() {
        b0 = 1.0
        b1 = 0.0
        b2 = 0.0
        a1 = 0.0
        a2 = 0.0
        reset()
    }

    mutating func configureLowpass(cutoffHz: Float, sampleRate: Float, q: Float = 0.7071068) {
        let sr = max(8_000.0, sampleRate)
        let nyquist = (sr * 0.5) - 10.0
        let fc = clampf(cutoffHz, 8.0, max(16.0, nyquist))
        let w0 = twoPi * fc / sr
        let c = cosf(w0)
        let s = sinf(w0)
        let alpha = s / (2.0 * max(0.1, q))

        let pb0 = (1.0 - c) * 0.5
        let pb1 = 1.0 - c
        let pb2 = (1.0 - c) * 0.5
        let pa0 = 1.0 + alpha
        let pa1 = -2.0 * c
        let pa2 = 1.0 - alpha
        setNormalized(pb0, pb1, pb2, pa0, pa1, pa2)
    }

    mutating func configureHighpass(cutoffHz: Float, sampleRate: Float, q: Float = 0.7071068) {
        let sr = max(8_000.0, sampleRate)
        let nyquist = (sr * 0.5) - 10.0
        let fc = clampf(cutoffHz, 8.0, max(16.0, nyquist))
        let w0 = twoPi * fc / sr
        let c = cosf(w0)
        let s = sinf(w0)
        let alpha = s / (2.0 * max(0.1, q))

        let pb0 = (1.0 + c) * 0.5
        let pb1 = -(1.0 + c)
        let pb2 = (1.0 + c) * 0.5
        let pa0 = 1.0 + alpha
        let pa1 = -2.0 * c
        let pa2 = 1.0 - alpha
        setNormalized(pb0, pb1, pb2, pa0, pa1, pa2)
    }

    mutating func configureNotch(freqHz: Float, sampleRate: Float, q: Float = 12.0) {
        let sr = max(8_000.0, sampleRate)
        let nyquist = (sr * 0.5) - 10.0
        let f0 = clampf(freqHz, 8.0, max(16.0, nyquist))
        let w0 = twoPi * f0 / sr
        let c = cosf(w0)
        let s = sinf(w0)
        let alpha = s / (2.0 * max(0.1, q))

        let pb0: Float = 1.0
        let pb1: Float = -2.0 * c
        let pb2: Float = 1.0
        let pa0: Float = 1.0 + alpha
        let pa1: Float = -2.0 * c
        let pa2: Float = 1.0 - alpha
        setNormalized(pb0, pb1, pb2, pa0, pa1, pa2)
    }

    mutating func configureBandpass(freqHz: Float, sampleRate: Float, q: Float = 4.0) {
        let sr = max(8_000.0, sampleRate)
        let nyquist = (sr * 0.5) - 10.0
        let f0 = clampf(freqHz, 8.0, max(16.0, nyquist))
        let w0 = twoPi * f0 / sr
        let c = cosf(w0)
        let s = sinf(w0)
        let alpha = s / (2.0 * max(0.1, q))

        let pb0: Float = alpha
        let pb1: Float = 0.0
        let pb2: Float = -alpha
        let pa0: Float = 1.0 + alpha
        let pa1: Float = -2.0 * c
        let pa2: Float = 1.0 - alpha
        setNormalized(pb0, pb1, pb2, pa0, pa1, pa2)
    }

    mutating func configureAllpass(freqHz: Float, sampleRate: Float, q: Float = 0.7071068) {
        let sr = max(8_000.0, sampleRate)
        let nyquist = (sr * 0.5) - 10.0
        let f0 = clampf(freqHz, 8.0, max(16.0, nyquist))
        let w0 = twoPi * f0 / sr
        let c = cosf(w0)
        let s = sinf(w0)
        let alpha = s / (2.0 * max(0.1, q))

        let pb0 = 1.0 - alpha
        let pb1 = -2.0 * c
        let pb2 = 1.0 + alpha
        let pa0 = 1.0 + alpha
        let pa1 = -2.0 * c
        let pa2 = 1.0 - alpha
        setNormalized(pb0, pb1, pb2, pa0, pa1, pa2)
    }

    mutating func configurePeakingEQ(freqHz: Float, gainDB: Float, sampleRate: Float, q: Float = 1.0) {
        if fabsf(gainDB) < 0.01 {
            configureIdentity()
            return
        }
        let sr = max(8_000.0, sampleRate)
        let nyquist = (sr * 0.5) - 10.0
        let f0 = clampf(freqHz, 8.0, max(16.0, nyquist))
        let w0 = twoPi * f0 / sr
        let c = cosf(w0)
        let s = sinf(w0)
        let A = powf(10.0, gainDB / 40.0)
        let alpha = s / (2.0 * max(0.1, q))

        let pb0 = 1.0 + (alpha * A)
        let pb1 = -2.0 * c
        let pb2 = 1.0 - (alpha * A)
        let pa0 = 1.0 + (alpha / A)
        let pa1 = -2.0 * c
        let pa2 = 1.0 - (alpha / A)
        setNormalized(pb0, pb1, pb2, pa0, pa1, pa2)
    }

    mutating func configureLowShelf(
        gainDB: Float, cutoffHz: Float, sampleRate: Float, slope: Float = 1.0
    ) {
        if fabsf(gainDB) < 0.01 {
            configureIdentity()
            return
        }
        let sr = max(8_000.0, sampleRate)
        let nyquist = (sr * 0.5) - 200.0
        let fc = clampf(cutoffHz, 20.0, max(40.0, nyquist))
        let w0 = twoPi * fc / sr
        let c = cosf(w0)
        let s = sinf(w0)
        let A = powf(10.0, gainDB / 40.0)
        let invA = 1.0 / max(1e-6, A)
        let slopeSafe = max(0.1, slope)
        let alphaTerm = max(0.0, ((A + invA) * ((1.0 / slopeSafe) - 1.0)) + 2.0)
        let alpha = (s * 0.5) * sqrtf(alphaTerm)
        let sqrtA = sqrtf(max(1e-6, A))

        let pb0 = A * ((A + 1.0) - ((A - 1.0) * c) + (2.0 * sqrtA * alpha))
        let pb1 = 2.0 * A * ((A - 1.0) - ((A + 1.0) * c))
        let pb2 = A * ((A + 1.0) - ((A - 1.0) * c) - (2.0 * sqrtA * alpha))
        let pa0 = (A + 1.0) + ((A - 1.0) * c) + (2.0 * sqrtA * alpha)
        let pa1 = -2.0 * ((A - 1.0) + ((A + 1.0) * c))
        let pa2 = (A + 1.0) + ((A - 1.0) * c) - (2.0 * sqrtA * alpha)
        setNormalized(pb0, pb1, pb2, pa0, pa1, pa2)
    }

    mutating func configureHighShelf(
        gainDB: Float, cutoffHz: Float, sampleRate: Float, slope: Float = 1.0
    ) {
        if fabsf(gainDB) < 0.01 {
            configureIdentity()
            return
        }
        let sr = max(8_000.0, sampleRate)
        let nyquist = (sr * 0.5) - 200.0
        let fc = clampf(cutoffHz, 500.0, max(520.0, nyquist))
        let w0 = twoPi * fc / sr
        let c = cosf(w0)
        let s = sinf(w0)
        let A = powf(10.0, gainDB / 40.0)
        let invA = 1.0 / max(1e-6, A)
        let slopeSafe = max(0.1, slope)
        let alphaTerm = max(0.0, ((A + invA) * ((1.0 / slopeSafe) - 1.0)) + 2.0)
        let alpha = (s * 0.5) * sqrtf(alphaTerm)
        let sqrtA = sqrtf(max(1e-6, A))

        let pb0 = A * ((A + 1.0) + ((A - 1.0) * c) + (2.0 * sqrtA * alpha))
        let pb1 = -2.0 * A * ((A - 1.0) + ((A + 1.0) * c))
        let pb2 = A * ((A + 1.0) + ((A - 1.0) * c) - (2.0 * sqrtA * alpha))
        let pa0 = (A + 1.0) - ((A - 1.0) * c) + (2.0 * sqrtA * alpha)
        let pa1 = 2.0 * ((A - 1.0) - ((A + 1.0) * c))
        let pa2 = (A + 1.0) - ((A - 1.0) * c) - (2.0 * sqrtA * alpha)
        setNormalized(pb0, pb1, pb2, pa0, pa1, pa2)
    }

    mutating func process(_ x: Float) -> Float {
        let y = (b0 * x) + z1
        z1 = (b1 * x) - (a1 * y) + z2
        z2 = (b2 * x) - (a2 * y)
        z1 = zapDenorm(z1)
        z2 = zapDenorm(z2)
        return y
    }

    private mutating func setNormalized(
        _ pb0: Float,
        _ pb1: Float,
        _ pb2: Float,
        _ pa0: Float,
        _ pa1: Float,
        _ pa2: Float
    ) {
        let a0 = fabsf(pa0) < 1e-8 ? 1.0 : pa0
        b0 = pb0 / a0
        b1 = pb1 / a0
        b2 = pb2 / a0
        a1 = pa1 / a0
        a2 = pa2 / a0
        reset()
    }
}

struct StereoBiquad {
    var left = Biquad()
    var right = Biquad()

    mutating func configureHighpass(cutoffHz: Float, sampleRate: Float) {
        left.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func configureHighShelf(gainDB: Float, cutoffHz: Float, sampleRate: Float) {
        left.configureHighShelf(gainDB: gainDB, cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configureHighShelf(gainDB: gainDB, cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func configureLowShelf(gainDB: Float, cutoffHz: Float, sampleRate: Float) {
        left.configureLowShelf(gainDB: gainDB, cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configureLowShelf(gainDB: gainDB, cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func configurePeakingEQ(freqHz: Float, gainDB: Float, sampleRate: Float, q: Float = 1.0) {
        left.configurePeakingEQ(freqHz: freqHz, gainDB: gainDB, sampleRate: sampleRate, q: q)
        right.configurePeakingEQ(freqHz: freqHz, gainDB: gainDB, sampleRate: sampleRate, q: q)
    }

    mutating func configureAllpass(freqHz: Float, sampleRate: Float, q: Float = 0.7071068) {
        left.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
        right.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        return (self.left.process(left), self.right.process(right))
    }
}

// MARK: - Phase Rotator (4-pole allpass chain)
// Reduces waveform asymmetry (especially male voice) by ~3-4 dB,
// yielding free headroom for downstream AGC, compressors, and limiters.
// Standard in Orban Optimod, Stereotool, BreakawayOne.
struct PhaseRotator {
    private var ap1 = Biquad()
    private var ap2 = Biquad()
    private var ap3 = Biquad()
    private var ap4 = Biquad()

    mutating func configure(freqHz: Float, sampleRate: Float) {
        let q: Float = 0.7071068
        ap1.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
        ap2.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
        ap3.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
        ap4.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        ap4.process(ap3.process(ap2.process(ap1.process(x))))
    }
}

struct StereoPhaseRotator {
    var left = PhaseRotator()
    var right = PhaseRotator()

    mutating func configure(freqHz: Float, sampleRate: Float) {
        left.configure(freqHz: freqHz, sampleRate: sampleRate)
        right.configure(freqHz: freqHz, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(left l: Float, right r: Float) -> (Float, Float) {
        (self.left.process(l), self.right.process(r))
    }
}

// MARK: - Parametric EQ (4-band: low shelf + 2 peaking + high shelf)
struct ParametricEQ4Band {
    private var band1 = StereoBiquad()  // low shelf
    private var band2 = StereoBiquad()  // peaking
    private var band3 = StereoBiquad()  // peaking
    private var band4 = StereoBiquad()  // high shelf

    // Shelf bands (1 and 4) use the RBJ default slope=1.0 (Butterworth
    // shelf); they expose no Q control since the shelf biquad is slope-
    // parameterized, not Q-parameterized. Only the peaking bands (2 and 3)
    // take a Q.
    mutating func configure(
        sampleRate: Float,
        b1FreqHz: Float, b1GainDB: Float,
        b2FreqHz: Float, b2GainDB: Float, b2Q: Float,
        b3FreqHz: Float, b3GainDB: Float, b3Q: Float,
        b4FreqHz: Float, b4GainDB: Float
    ) {
        band1.configureLowShelf(gainDB: b1GainDB, cutoffHz: b1FreqHz, sampleRate: sampleRate)
        band2.configurePeakingEQ(freqHz: b2FreqHz, gainDB: b2GainDB, sampleRate: sampleRate, q: b2Q)
        band3.configurePeakingEQ(freqHz: b3FreqHz, gainDB: b3GainDB, sampleRate: sampleRate, q: b3Q)
        band4.configureHighShelf(gainDB: b4GainDB, cutoffHz: b4FreqHz, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(left l: Float, right r: Float) -> (Float, Float) {
        var out = band1.process(left: l, right: r)
        out = band2.process(left: out.0, right: out.1)
        out = band3.process(left: out.0, right: out.1)
        out = band4.process(left: out.0, right: out.1)
        return out
    }
}

// MARK: - Per-Band Fast Peak Limiter
// Fast-attack, high-ratio brick-wall limiter for per-band transient control.
// Operates after multiband compressor, before band summation.
struct BandLimiter {
    private var thresholdLin: Float = 1.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    // Stereo-linked envelope: both channels are limited together based on the
    // max(|L|, |R|) peak, so a single envelope is sufficient.
    private var env: Float = 0.0

    mutating func configure(sampleRate: Float, thresholdDB: Float, attackMS: Float, releaseMS: Float) {
        thresholdLin = powf(10.0, min(0.0, thresholdDB) / 20.0)
        let sr = max(8_000.0, sampleRate)
        attackCoeff = expf(-1.0 / (max(0.01, attackMS) * 0.001 * sr))
        releaseCoeff = expf(-1.0 / (max(1.0, releaseMS) * 0.001 * sr))
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        let peak = max(fabsf(left), fabsf(right))
        let coeff = peak > env ? attackCoeff : releaseCoeff
        env = (coeff * env) + ((1.0 - coeff) * peak)
        if env > thresholdLin {
            let gain = thresholdLin / env
            return (left * gain, right * gain)
        }
        return (left, right)
    }
}

// MARK: - Shared oversampling helper
struct Lagrange4Interp {
    private var h3: Float = 0
    private var h2: Float = 0
    private var h1: Float = 0
    private var initialized: Bool = false

    mutating func prime(_ x: Float) {
        h3 = x; h2 = x; h1 = x; initialized = true
    }

    @inline(__always)
    func interpolate(t: Float, cur: Float) -> Float {
        let l0 = -((t + 1.0) * t * (t - 1.0)) / 6.0
        let l1 = ((t + 2.0) * t * (t - 1.0)) * 0.5
        let l2 = -((t + 2.0) * (t + 1.0) * (t - 1.0)) * 0.5
        let l3 = ((t + 2.0) * (t + 1.0) * t) / 6.0
        return (h3 * l0) + (h2 * l1) + (h1 * l2) + (cur * l3)
    }

    @inline(__always)
    mutating func advance(_ cur: Float) {
        h3 = h2; h2 = h1; h1 = cur
    }

    var isPrimed: Bool { initialized }
}

// MARK: - Bass Clipper (4x oversampled)
struct BassClipper {
    private var splitL = LinkwitzRiley4()
    private var splitR = LinkwitzRiley4()
    private var thresholdLin: Float = 0.8
    private var drive: Float = 1.0
    private var lagL = Lagrange4Interp()
    private var lagR = Lagrange4Interp()
    private var decimL = BiquadCascade6()
    private var decimR = BiquadCascade6()
    private static let factor: Int = 4
    // Stack-allocated batch buffers for vvtanhf-accelerated clipBass.
    // 8 elements = 4 oversample steps × L+R LP-band samples. At 8 elements
    // vvtanhf is ~5× faster than scalar tanhf per TanhBatchSizeBench.
    private var lowBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var highBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipDrivenBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipTanhBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipResultBatch: [Float] = Array(repeating: 0.0, count: factor * 2)

    mutating func configure(sampleRate: Float, crossoverHz: Float, thresholdDB: Float, drive drv: Float) {
        let osRate = sampleRate * Float(Self.factor)
        splitL.configure(cutoffHz: crossoverHz, sampleRate: osRate)
        splitR.configure(cutoffHz: crossoverHz, sampleRate: osRate)
        thresholdLin = powf(10.0, min(0.0, thresholdDB) / 20.0)
        drive = max(0.1, drv)
        let cutoff = min(sampleRate * 0.45, (osRate * 0.5) - 1_000.0)
        decimL.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
        decimR.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        if !lagL.isPrimed { lagL.prime(left); lagR.prime(right) }
        let f = Self.factor
        let step = 1.0 / Float(f)

        // Phase 1: per-OS-step interpolate + LR4 split. State advances
        // here. Save .low and .high so the clip and decimate phases
        // can run as separate loops.
        for i in 0..<f {
            let t = step * Float(i + 1)
            let upL = (i == f - 1) ? left : lagL.interpolate(t: t, cur: left)
            let upR = (i == f - 1) ? right : lagR.interpolate(t: t, cur: right)
            let sL = splitL.process(upL)
            let sR = splitR.process(upR)
            lowBatch[i] = sL.low
            lowBatch[i + f] = sR.low
            highBatch[i] = sL.high
            highBatch[i + f] = sR.high
        }

        // Phase 2: batched clipBass via vvtanhf on 8 elements (4 L-low +
        // 4 R-low). ~5× faster than 8 scalar tanhf calls.
        let thr = thresholdLin
        let drv = drive
        let invDrv = 1.0 / drv
        for i in 0..<(f * 2) {
            clipDrivenBatch[i] = (lowBatch[i] * drv) / thr
        }
        var n = Int32(f * 2)
        clipDrivenBatch.withUnsafeMutableBufferPointer { dPtr in
            clipTanhBatch.withUnsafeMutableBufferPointer { tPtr in
                vvtanhf(tPtr.baseAddress!, dPtr.baseAddress!, &n)
            }
        }
        for i in 0..<(f * 2) {
            let driven = lowBatch[i] * drv
            let ax = fabsf(driven)
            if ax <= thr {
                clipResultBatch[i] = lowBatch[i]
            } else {
                clipResultBatch[i] = (thr * clipTanhBatch[i]) * invDrv
            }
        }

        // Phase 3: per-OS-step decimation. State advances here.
        var outL: Float = 0
        var outR: Float = 0
        for i in 0..<f {
            outL = decimL.process(clipResultBatch[i] + highBatch[i])
            outR = decimR.process(clipResultBatch[i + f] + highBatch[i + f])
        }
        lagL.advance(left)
        lagR.advance(right)
        return (outL, outR)
    }
}

// MARK: - Distortion-Cancelled Clipper (L/R domain, 8x oversampled)
struct DistortionCancelledClipper {
    private var ceiling: Float = 0.95
    private var errorLPL = Biquad()
    private var errorLPR = Biquad()
    private var errorLP2L = Biquad()
    private var errorLP2R = Biquad()
    private var lagL = Lagrange4Interp()
    private var lagR = Lagrange4Interp()
    private var decimL = BiquadCascade6()
    private var decimR = BiquadCascade6()
    private static let factor: Int = 8
    // Stack-allocated batch buffers for vvtanhf-accelerated hardClip.
    // 16 elements = 8 oversample steps × L+R. At 16 elements vvtanhf is
    // ~9× faster than scalar tanhf per the TanhBatchSizeBench.
    private var upBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipExcessBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipTanhBatch: [Float] = Array(repeating: 0.0, count: factor * 2)

    mutating func configure(sampleRate: Float, ceilingDB: Float, cancelFreqHz: Float) {
        ceiling = powf(10.0, min(0.0, ceilingDB) / 20.0)
        let osRate = sampleRate * Float(Self.factor)
        let q: Float = 0.7071068
        errorLPL.configureLowpass(cutoffHz: cancelFreqHz, sampleRate: osRate, q: q)
        errorLPR.configureLowpass(cutoffHz: cancelFreqHz, sampleRate: osRate, q: q)
        errorLP2L.configureLowpass(cutoffHz: cancelFreqHz, sampleRate: osRate, q: q)
        errorLP2R.configureLowpass(cutoffHz: cancelFreqHz, sampleRate: osRate, q: q)
        let cutoff = min(sampleRate * 0.45, (osRate * 0.5) - 1_000.0)
        decimL.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
        decimR.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        if !lagL.isPrimed { lagL.prime(left); lagR.prime(right) }
        let f = Self.factor
        let step = 1.0 / Float(f)

        // Phase 1: pre-compute 8 OS upL + 8 OS upR (no filter state advances
        // here — Lagrange interp reads from h-state but doesn't write).
        for i in 0..<f {
            let t = step * Float(i + 1)
            upBatch[i] = (i == f - 1) ? left : lagL.interpolate(t: t, cur: left)
            upBatch[i + f] = (i == f - 1) ? right : lagR.interpolate(t: t, cur: right)
        }

        // Phase 2: batched hardClip via vvtanhf on 16 elements (~9× faster
        // than 16 scalar tanhf calls on Apple Silicon).
        let cl = ceiling
        let kn = max(0.01, ceiling * 0.15)
        let amplitude = ceiling * 0.05
        for i in 0..<(f * 2) {
            clipExcessBatch[i] = (fabsf(upBatch[i]) - cl) / kn
        }
        var n = Int32(f * 2)
        clipExcessBatch.withUnsafeMutableBufferPointer { exPtr in
            clipTanhBatch.withUnsafeMutableBufferPointer { thPtr in
                vvtanhf(thPtr.baseAddress!, exPtr.baseAddress!, &n)
            }
        }
        for i in 0..<(f * 2) {
            let up = upBatch[i]
            let ax = fabsf(up)
            if ax <= cl {
                clipBatch[i] = up
            } else {
                clipBatch[i] = copysignf(cl + amplitude * clipTanhBatch[i], up)
            }
        }

        // Phase 3: per-OS-step error-cancel filtering and decimation.
        var outL: Float = 0
        var outR: Float = 0
        for i in 0..<f {
            let upL = upBatch[i]
            let upR = upBatch[i + f]
            let clL = clipBatch[i]
            let clR = clipBatch[i + f]
            let fErrL = errorLP2L.process(errorLPL.process(clL - upL))
            let fErrR = errorLP2R.process(errorLPR.process(clR - upR))
            outL = decimL.process(clL - fErrL)
            outR = decimR.process(clR - fErrR)
        }
        lagL.advance(left)
        lagR.advance(right)
        return (outL, outR)
    }
}

// MARK: - Composite Clipper (audio composite, 8x oversampled)
// 8x oversampled tanh soft-clipper on the audio composite with per-band
// distortion cancellation via signal substitution (Orban US 4,460,871 /
// 5,737,434, expired).
//
// Algorithm:
//   At the oversampled rate, soft-clip the composite. Apply *single*
//   LR4 splits at 15 kHz (audio crossover) and 53 kHz (stereo upper
//   crossover) to BOTH clipped and original (`up`). Use the LR4
//   sum-to-flat property to reconstruct:
//     output = audio_chosen + stereo_chosen + above_53kHz_of_clipped
//   where:
//     audio_chosen   = LR4_LP_15(up)         if cancelAudio
//                    = LR4_LP_15(clipped)    otherwise
//     stereo_chosen  = HP_22(LR4_LP_53(up))  if cancelStereo
//                    = HP_22(LR4_LP_53(clipped)) otherwise
//     above_53kHz    = LR4_HP_53(clipped) (i.e. clipped - LR4_LP_53(clipped))
//
// At the 53 kHz crossover, LR4_LP_53 + LR4_HP_53 sum to a magnitude-flat
// allpass — so audio_chosen + stereo_chosen + above_53kHz reconstructs
// either the full clipped (no cancellation) or a hybrid where the
// audio/stereo subcarrier bands carry the original instead. Single-LR4
// (4th-order, –6 dB at corner) replaces the original implementation's
// cascaded-LR4 (8th-order, –12 dB at corner) to halve the band-edge
// attenuation that was collapsing HF stereo image.
//
// Stereo HP corner at 22 kHz (just below the 23 kHz subcarrier lower
// edge) keeps the (L-R) lower sideband full amplitude. Stereo LP corner
// at 53 kHz sits exactly on the upper subcarrier edge, so HF (L-R)
// content modulating to ~52 kHz is at most –3 dB attenuated rather
// than the previous –9 dB.
//
// Pilot guard (17–21 kHz) and RDS guard (55–59 kHz) cancellations are
// served by the audio crossover at 15 kHz and the stereo crossover at
// 53 kHz: the gap zones 15–22 kHz and 53 kHz+ are taken from clipped
// (where they're filled by clipping IM that the post-stage pilot/RDS
// injection then has to ride against). This is acceptable because
// pilot/RDS guard cancellation only becomes meaningful at heavy clip
// drives; the stereo-image fix is the load-bearing change here. Pilot
// and RDS cancel flags are accepted for API stability but are no-ops
// in the substitution-based design — the subcarrier injection happens
// post-clipper anyway.
//
// Pilot (19 kHz) and RDS (57 kHz) are injected post-clipper, so their
// amplitude is unaffected by anything this stage does.
struct CompositeClipper {
    private var thresholdLin: Float = 0.708
    private var ceilingLin: Float = 0.944
    private var knee: Float = 0.236
    private var lag = Lagrange4Interp()
    /// Decimation filter for the OS-rate clipping residual. Replaced
    /// the prior `BiquadCascade6` (12th-order Butterworth) with a
    /// linear-phase Kaiser-windowed FIR — see `LinearPhaseFIRDecimator`
    /// header for the rationale. Used in the differential-clipper
    /// topology: only the *residual* (up − clipped) goes through
    /// decimation; the wanted signal rides a 1× delay-matched bypass.
    /// Inspired by Orban US 6,337,999 (expired 2022).
    private var decimLP = LinearPhaseFIRDecimator()
    private static let factor: Int = 8

    /// Host-rate bypass delay line. Holds the wanted (clean) input
    /// delayed by the FIR's group delay so it aligns with the
    /// decimated residual at output time. In the differential
    /// topology the output is `bypassed − decimated(residual)`; the
    /// decimator's stopband leakage and phase non-flatness only colour
    /// the residual subtracted, not the wanted signal — fundamental
    /// architectural improvement vs the prior "upsample → clip →
    /// decimate" path where the wanted signal saw the decimator's
    /// full phase response.
    private var bypassDelay: [Float] = [0.0]
    private var bypassWriteIdx: Int = 0

    // Audio + stereo bands use LR4 splits (sum-to-flat property at the
    // shared crossover means substitution is phase-coherent across the
    // wide passbands these bands need).
    private var clipped15 = LinkwitzRiley4()
    private var orig15 = LinkwitzRiley4()
    private var clipped53 = LinkwitzRiley4()
    private var orig53 = LinkwitzRiley4()
    private var clippedStereoHP = LinkwitzRiley4()
    private var origStereoHP = LinkwitzRiley4()
    // Pilot (19 kHz) and RDS (57 kHz) guards use RBJ bandpass biquads
    // tuned to the subcarrier centre frequency. RBJ BPF has 0 dB peak
    // and zero phase shift at fc, so subtracting BP(clipped) from the
    // unfiltered clipped signal cleanly cancels clipper IM at the
    // protected centre frequency. Wider LR4-style splits don't work
    // here — the 17–21 kHz / 55–59 kHz windows are too narrow to give
    // the LR4 bandpass any flat passband, so the band-edge attenuation
    // bounds achievable cancellation depth to a few dB.
    private var clippedPilotBP = Biquad()
    private var origPilotBP = Biquad()
    private var clippedRDSBP = Biquad()
    private var origRDSBP = Biquad()

    private var cancelAudio: Bool = false
    private var cancelStereo: Bool = true
    // Pilot (19 kHz) and RDS (57 kHz) subcarriers are injected
    // post-clipper. Even so, clipper IM in the 17–21 kHz pilot guard
    // and 55–59 kHz RDS guard bands vector-sums with the cleanly-
    // injected subcarriers at the receiver, corrupting pilot PLL lock
    // and RDS BER. Cancellation here subtracts the bandpass-isolated
    // clipper IM from the output before pilot/RDS injection.
    private var cancelPilot: Bool = true
    private var cancelRDS: Bool = true

    // Peak-attenuation telemetry for the UI meter (envelope-following ratio).
    private var peakInEnv: Float = 0.0
    private var peakOutEnv: Float = 0.0
    private var peakDecayCoeff: Float = 0.0

    // Stack-allocated batch buffers for vvtanhf-accelerated soft-clipping.
    // 8 elements = `Self.factor` oversample steps. Pre-allocated at
    // configure time so the audio thread never allocates.
    private var upBatch: [Float] = Array(repeating: 0.0, count: factor)
    private var clipBatch: [Float] = Array(repeating: 0.0, count: factor)
    private var clipExcessBatch: [Float] = Array(repeating: 0.0, count: factor)
    private var clipTanhBatch: [Float] = Array(repeating: 0.0, count: factor)

    mutating func configure(sampleRate: Float, thresholdDB: Float, ceilingDB: Float,
                            cancelAudio: Bool = false, cancelStereo: Bool = true,
                            cancelPilot: Bool = true, cancelRDS: Bool = true) {
        thresholdLin = clampf(powf(10.0, min(0.0, thresholdDB) / 20.0), 0.1, 0.995)
        let cMin: Float = thresholdLin + 0.02
        ceilingLin = clampf(powf(10.0, min(0.0, ceilingDB) / 20.0), cMin, 0.999)
        knee = max(1e-4, ceilingLin - thresholdLin)
        let osRate = sampleRate * Float(Self.factor)
        // FIR decimator passband must contain the entire audio
        // composite (0–53 kHz: M, S subcarrier sidebands at 38±15
        // kHz). Cutoff at 53 kHz with a wide transition band — at OS
        // rate 1.536 MHz (8× × 192 kHz) the available stopband region
        // is so wide that even a moderate transition gives ≥90 dB
        // rejection at the first IM target (64 kHz). Kaiser-sinc
        // designs to the stopBand target; tap count auto-sizes.
        let firPassband = clampf(53_000.0, 20_000.0, osRate * 0.45)
        let firTransition: Float = 60_000.0
        decimLP.configure(
            cutoffHz: firPassband,
            sampleRateOS: osRate,
            decimateFactor: Self.factor,
            stopBandDB: 90.0,
            transitionHz: firTransition
        )
        // Bypass ring buffer length tracks the FIR's host-rate group
        // delay so `bypassed - decimated(residual)` aligns sample-
        // accurate. Length must be at least 1 to handle the (FIR-
        // disabled) zero-delay case cleanly.
        let bypassLen = max(1, decimLP.groupDelayHostSamples)
        bypassDelay = [Float](repeating: 0.0, count: bypassLen)
        bypassWriteIdx = 0

        clipped15.configure(cutoffHz: 15_000.0, sampleRate: osRate)
        orig15.configure(cutoffHz: 15_000.0, sampleRate: osRate)
        clipped53.configure(cutoffHz: 53_000.0, sampleRate: osRate)
        orig53.configure(cutoffHz: 53_000.0, sampleRate: osRate)
        clippedStereoHP.configure(cutoffHz: 22_000.0, sampleRate: osRate)
        origStereoHP.configure(cutoffHz: 22_000.0, sampleRate: osRate)
        // Pilot guard: BPF centred at 19 kHz, Q=4 → ~4.75 kHz half-power
        // bandwidth (17–21 kHz). RDS guard: BPF centred at 57 kHz, Q=14
        // → ~4 kHz bandwidth (55–59 kHz). Q values keep the bandpasses
        // from bleeding into the adjacent audio (≤15 kHz) and stereo
        // (23–53 kHz) bands respectively.
        clippedPilotBP.configureBandpass(freqHz: 19_000.0, sampleRate: osRate, q: 4.0)
        origPilotBP.configureBandpass(freqHz: 19_000.0, sampleRate: osRate, q: 4.0)
        clippedRDSBP.configureBandpass(freqHz: 57_000.0, sampleRate: osRate, q: 14.0)
        origRDSBP.configureBandpass(freqHz: 57_000.0, sampleRate: osRate, q: 14.0)

        self.cancelAudio = cancelAudio
        self.cancelStereo = cancelStereo
        self.cancelPilot = cancelPilot
        self.cancelRDS = cancelRDS

        let sr = max(8_000.0, sampleRate)
        peakDecayCoeff = expf(-1.0 / (0.050 * sr))
        peakInEnv = 0.0
        peakOutEnv = 0.0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        if !lag.isPrimed { lag.prime(x) }
        let f = Self.factor
        let step = 1.0 / Float(f)

        // Phase 1: pre-compute all 8 oversampled inputs via Lagrange interp.
        // Lagrange state advances only at lag.advance(x) below, so this
        // is safe to do as a batch up front.
        for i in 0..<f {
            let t = step * Float(i + 1)
            upBatch[i] = (i == f - 1) ? x : lag.interpolate(t: t, cur: x)
        }

        // Phase 2: batched soft-clip via vvtanhf. Replaces 8 scalar tanhf
        // calls with one vvtanhf call on an 8-element vector — reduces
        // libm tanhf overhead and uses Apple Silicon's vector exp/log
        // pipeline. Below-threshold samples bypass the tanh result entirely
        // (the tanh is still computed in the batch but its result is
        // discarded for those samples — the cost of the wasted compute is
        // smaller than the cost of a per-element branch on the SIMD path).
        let thr = thresholdLin
        let kn = knee
        for i in 0..<f {
            clipExcessBatch[i] = (fabsf(upBatch[i]) - thr) / kn
        }
        var n = Int32(f)
        clipExcessBatch.withUnsafeMutableBufferPointer { excessPtr in
            clipTanhBatch.withUnsafeMutableBufferPointer { tanhPtr in
                vvtanhf(tanhPtr.baseAddress!, excessPtr.baseAddress!, &n)
            }
        }
        for i in 0..<f {
            let up = upBatch[i]
            let ax = fabsf(up)
            if ax <= thr {
                clipBatch[i] = up
            } else {
                clipBatch[i] = copysignf(thr + kn * clipTanhBatch[i], up)
            }
        }

        // Phase 3: per-OS-step band processing in differential-clipper
        // topology (Orban US 6,337,999, expired 2022). Conventional
        // upsample → clip → decimate places the wanted signal directly
        // through the decimator, so the decimator's stopband leakage
        // and phase non-flatness colour the output. Differential
        // topology routes only the *clipping residual* through the
        // decimator and a 1× delay-matched bypass carries the wanted
        // signal:
        //
        //     residual_OS = up − clipped
        //     output_HOST = bypass_delayed − decimate(residual_OS)
        //
        // For un-cancelled bands the residual passes through; for
        // cancelled bands (pilot/stereo/RDS guards) we subtract that
        // band's component from the residual *before* decimation so
        // the clipper IM in those bands isn't reflected back to the
        // output. Math identity:
        //
        //     classical = clipped + Σ band_delta(up, clipped)
        //     differential = bypass − decimate(residual − Σ band_delta)
        //
        // Both reduce to `decimate(clipped + Σ band_delta)` when the
        // FIR is unity-gain in passband, but differential keeps the
        // decimator off the wanted-signal path entirely.
        var residualDecimated: Float = 0.0
        for i in 0..<f {
            let up = upBatch[i]
            let clipped = clipBatch[i]

            // Run all filter instances every oversample step to keep
            // state advancing in lockstep — required even when their
            // outputs are gated by the cancel flags so the parallel
            // chains stay phase-aligned for cancellation in subsequent
            // samples.
            let cAudio = clipped15.process(clipped).low
            let oAudio = orig15.process(up).low

            let cPilot = clippedPilotBP.process(clipped)
            let oPilot = origPilotBP.process(up)

            let split53C = clipped53.process(clipped)
            let split53O = orig53.process(up)
            let cStereo = clippedStereoHP.process(split53C.low).high
            let oStereo = origStereoHP.process(split53O.low).high
            _ = split53O.high   // keep state consistent; not needed for output

            let cRDS = clippedRDSBP.process(clipped)
            let oRDS = origRDSBP.process(up)

            // Build the residual-to-decimate. Start with the naked
            // residual (up − clipped) and subtract the band-extracted
            // residual for each cancelled band so those bands don't
            // contribute to the residual that reaches the output.
            // (oBand − cBand) = bandpass(up) − bandpass(clipped) =
            // bandpass(up − clipped) by linearity, so this exactly
            // matches the classical "add band delta to clipped" form
            // when the decimator is ideal.
            var residual = up - clipped
            if cancelAudio {
                residual -= (oAudio - cAudio)
            }
            if cancelPilot {
                residual -= (oPilot - cPilot)
            }
            if cancelStereo {
                residual -= (oStereo - cStereo)
            }
            if cancelRDS {
                residual -= (oRDS - cRDS)
            }

            // Push residual into FIR decimator. Returns the most-
            // recent emitted decimated value; the value updates only
            // on the 8th push of each host sample, so the value read
            // after the loop is the freshly-decimated residual.
            residualDecimated = decimLP.push(residual)
        }
        lag.advance(x)

        // Bypass: read host-rate input from `groupDelayHostSamples`
        // ago. With a length-N ring buffer (N = group delay), we read
        // the slot we're about to overwrite — that value was written
        // N samples ago. The N=1 special case (FIR group delay rounds
        // to 0 host samples, e.g. on extremely short FIRs) gives
        // zero-delay bypass, which is the correct degenerate
        // behaviour.
        let bypassLen = bypassDelay.count
        let bypassed = bypassLen > 1 ? bypassDelay[bypassWriteIdx] : x
        bypassDelay[bypassWriteIdx] = x
        bypassWriteIdx += 1
        if bypassWriteIdx >= bypassLen { bypassWriteIdx = 0 }

        let out = bypassed - residualDecimated

        let inAbs = fabsf(x)
        let outAbs = fabsf(out)
        peakInEnv = max(inAbs, peakInEnv * peakDecayCoeff)
        peakOutEnv = max(outAbs, peakOutEnv * peakDecayCoeff)
        return out
    }

    /// Headroom reduction in dB (positive = clipper is shaving peaks).
    /// Computed from envelope-tracked peaks of input and output, decayed
    /// at ~50 ms; meant for the UI meter, not for sample-accurate analysis.
    var gainReductionDB: Float {
        let pi = max(1e-6, peakInEnv)
        let po = max(1e-6, peakOutEnv)
        return max(0.0, 20.0 * log10f(pi / po))
    }
}

// MARK: - BS.412 MPX Power Limiter
// Rolling 60-second average power measurement with slow gain reduction.
// ITU-R BS.412 requires average MPX power to not exceed a threshold
// (typically -10 dBr relative to unmodulated carrier deviation).
struct BS412PowerLimiter {
    private var powerAccumulator: Double = 0.0
    private var sampleCount: Int = 0
    private var windowSamples: Int = 0
    private var ringBuffer: [Float] = []
    private var ringIndex: Int = 0
    private var ringFull: Bool = false
    private var currentGain: Float = 1.0
    private var targetGain: Float = 1.0
    private var thresholdPower: Float = 0.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    // Decimated power tracking: measure every N samples to reduce overhead
    private var decimationCounter: Int = 0
    private let decimationFactor: Int = 64
    private var decimationAccumulator: Float = 0.0

    mutating func configure(sampleRate: Float, thresholdDB: Float, windowSeconds: Float = 60.0) {
        let sr = max(8_000.0, sampleRate)
        // Ring buffer stores decimated power values
        let totalSamples = Int(sr * max(1.0, windowSeconds))
        windowSamples = totalSamples / decimationFactor
        if ringBuffer.count != windowSamples {
            ringBuffer = [Float](repeating: 0.0, count: max(1, windowSamples))
            ringIndex = 0
            ringFull = false
            powerAccumulator = 0.0
        }
        // Threshold: power level in linear (squared amplitude)
        thresholdPower = powf(10.0, thresholdDB / 10.0)
        // Slow attack (1s), moderate release (5s)
        attackCoeff = expf(-1.0 / (1.0 * sr))
        releaseCoeff = expf(-1.0 / (5.0 * sr))
        decimationCounter = 0
        decimationAccumulator = 0.0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let sample2 = x * x
        decimationAccumulator += sample2

        decimationCounter += 1
        if decimationCounter >= decimationFactor {
            let avgPower = decimationAccumulator / Float(decimationFactor)
            // Update ring buffer
            if ringFull {
                powerAccumulator -= Double(ringBuffer[ringIndex])
            }
            ringBuffer[ringIndex] = avgPower
            powerAccumulator += Double(avgPower)
            ringIndex += 1
            if ringIndex >= windowSamples {
                ringIndex = 0
                ringFull = true
            }
            // Compute average power
            let count = ringFull ? windowSamples : ringIndex
            if count > 0 {
                let avgWindowPower = Float(powerAccumulator / Double(count))
                if avgWindowPower > thresholdPower && avgWindowPower > 1e-10 {
                    targetGain = sqrtf(thresholdPower / avgWindowPower)
                } else {
                    targetGain = 1.0
                }
            }
            decimationCounter = 0
            decimationAccumulator = 0.0
        }

        // Smooth gain transitions
        let coeff = targetGain < currentGain ? attackCoeff : releaseCoeff
        currentGain = (coeff * currentGain) + ((1.0 - coeff) * targetGain)
        return x * currentGain
    }

    var gainReductionDB: Float {
        20.0 * log10f(max(1e-6, currentGain))
    }
}

// MARK: - Downward Expander (per-band)
// Reduces gain on quiet bands to prevent AGC from lifting noise floor.
struct DownwardExpander {
    private var thresholdLin: Float = 0.001
    private var ratio: Float = 2.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    // Stereo-linked detector: both channels share one envelope driven by
    // max(|L|, |R|), so a single gain value is applied to the band.
    private var env: Float = 0.0

    mutating func configure(sampleRate: Float, thresholdDB: Float, ratio r: Float,
                            attackMS: Float, releaseMS: Float) {
        thresholdLin = powf(10.0, thresholdDB / 20.0)
        ratio = max(1.0, r)
        let sr = max(8_000.0, sampleRate)
        attackCoeff = expf(-1.0 / (max(0.1, attackMS) * 0.001 * sr))
        releaseCoeff = expf(-1.0 / (max(1.0, releaseMS) * 0.001 * sr))
    }

    @inline(__always)
    mutating func expanderGain(left: Float, right: Float) -> Float {
        let peak = max(fabsf(left), fabsf(right))
        let coeff = peak > env ? attackCoeff : releaseCoeff
        env = (coeff * env) + ((1.0 - coeff) * peak)
        if env < thresholdLin && env > 1e-10 {
            // Below threshold: reduce gain by expansion ratio
            let belowDB = 20.0 * log10f(env / thresholdLin)
            let expandedDB = belowDB * ratio
            return powf(10.0, expandedDB / 20.0)
        }
        return 1.0
    }
}

struct LinkwitzRiley4 {
    private var lp1 = Biquad()
    private var lp2 = Biquad()
    private var hp1 = Biquad()
    private var hp2 = Biquad()

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        lp1.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        lp2.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        hp1.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        hp2.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func process(_ x: Float) -> (low: Float, high: Float) {
        let low = lp2.process(lp1.process(x))
        let high = hp2.process(hp1.process(x))
        return (low, high)
    }
}

struct StereoLinkwitzRiley4 {
    private var left = LinkwitzRiley4()
    private var right = LinkwitzRiley4()

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        left.configure(cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configure(cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func process(left: Float, right: Float) -> ((Float, Float), (Float, Float)) {
        (self.left.process(left), self.right.process(right))
    }
}

struct BiquadCascade6 {
    private static let butterworthQ: (Float, Float, Float) = (0.5176381, 0.7071068, 1.9318517)
    var s1 = Biquad()
    var s2 = Biquad()
    var s3 = Biquad()

    mutating func configureIdentity() {
        s1.configureIdentity()
        s2.configureIdentity()
        s3.configureIdentity()
    }

    mutating func configureLowpass(cutoffHz: Float, sampleRate: Float) {
        let q = Self.butterworthQ
        s1.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.0)
        s2.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.1)
        s3.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.2)
    }

    mutating func configureHighpass(cutoffHz: Float, sampleRate: Float) {
        let q = Self.butterworthQ
        s1.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.0)
        s2.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.1)
        s3.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.2)
    }

    mutating func process(_ x: Float) -> Float {
        return s3.process(s2.process(s1.process(x)))
    }
}

struct ProgramLowpass {
    var left = BiquadCascade6()
    var right = BiquadCascade6()

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        left.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        let l = self.left.process(left)
        let r = self.right.process(right)
        return (l, r)
    }
}

/// Linear-phase FIR lowpass for the transmit-path encoder bandwidth guard.
/// Kaiser-windowed sinc with a configurable cutoff and transition band,
/// sized at configure() time to meet a stop-band attenuation target. Used
/// in place of the Butterworth `ProgramLowpass` on the TX path so later
/// nonlinear stages (DC clipper, composite clipper) see a much steeper
/// audio-spectrum roll-off — brings stop-band suppression from ~40 dB
/// (Butterworth) to >=80 dB. Coefficients computed once, hot path is a
/// circular-buffer dot product.
///
/// Trade-off: the filter introduces (N-1)/2 samples of group delay. At
/// 192 kHz with ~1.5 kHz transition band this is ~320 samples / 1.67 ms —
/// tolerable on the transmit path, unacceptable on a live-monitor path.
/// The Butterworth `ProgramLowpass` continues to be used when the engine
/// runs in monitor mode.
/// Modified Bessel function of the first kind, order 0. Series expansion
/// converges rapidly for the Kaiser beta range we care about (<15).
@inline(__always)
private func kaiserI0(_ x: Float) -> Float {
    var sum: Float = 1.0
    var term: Float = 1.0
    let halfX = x * 0.5
    let halfXSq = halfX * halfX
    for k in 1...50 {
        term *= halfXSq / Float(k * k)
        sum += term
        if term < 1e-9 * sum { break }
    }
    return sum
}

/// Designs a Kaiser-windowed sinc lowpass FIR. Returns an odd-length
/// coefficient array normalised to unity DC gain. Length is auto-sized
/// from `stopBandDB` and `transitionHz` per the standard Kaiser order
/// estimate, clamped to a sane range. Reused by `LinearPhaseFIRLowpass`
/// (encoder bandwidth guard) and `LinearPhaseFIRSplitter` (multiband
/// crossovers).
private func kaiserSincLowpassCoefficients(
    cutoffHz: Float,
    sampleRate: Float,
    stopBandDB: Float,
    transitionHz: Float
) -> [Float] {
    let sr = max(8_000.0 as Float, sampleRate)
    let nyq = sr * 0.5
    // 30 Hz minimum cutoff — supports multiband sub-band crossovers (e.g.
    // 90 Hz). Encoder bandwidth guard clamps via its own contract.
    let fc = clampf(cutoffHz, 30.0, nyq - 500.0)
    let transition = max(40.0, min(transitionHz, nyq - fc - 50.0))
    let attenuation = max(21.0, stopBandDB)

    // Kaiser order estimate: N ≈ (A - 8) / (2.285 · 2π · Δf / fs).
    let normalizedTransition = transition / sr
    let rawN = Int(ceilf((attenuation - 8.0) / (2.285 * 2.0 * .pi * normalizedTransition)))
    // Odd length gives a sample-centred symmetric kernel (exact linear phase).
    let N = max(63, min(2_049, rawN | 1))

    let beta: Float
    if attenuation > 50 {
        beta = 0.1102 * (attenuation - 8.7)
    } else {
        beta = 0.5842 * powf(attenuation - 21.0, 0.4) + 0.07886 * (attenuation - 21.0)
    }
    let i0beta = kaiserI0(beta)

    // Design around the midpoint of the transition band so the -6 dB
    // point sits roughly at fc + transition/2. Standard Kaiser convention.
    let fcNorm = (fc + transition * 0.5) / sr
    let M = Float(N - 1)
    var coeffs = [Float](repeating: 0.0, count: N)
    var accumulation: Float = 0
    for n in 0..<N {
        let nn = Float(n) - M * 0.5
        let sinc: Float
        if abs(nn) < 1e-6 {
            sinc = 2.0 * fcNorm
        } else {
            sinc = sinf(2.0 * .pi * fcNorm * nn) / (.pi * nn)
        }
        let u = 2.0 * nn / M
        let arg = beta * sqrtf(max(0.0, 1.0 - u * u))
        let w = kaiserI0(arg) / i0beta
        let tap = sinc * w
        coeffs[n] = tap
        accumulation += tap
    }
    // Normalise to exact unity DC gain.
    if accumulation > 1e-6 {
        let scale = 1.0 / accumulation
        for i in 0..<N {
            coeffs[i] *= scale
        }
    }
    return coeffs
}

struct LinearPhaseFIRLowpass {
    private var coeffs: [Float] = []
    // Double-buffered delay lines (size = 2 × lengthTaps). Each input
    // sample is written to two positions: `writeIdx` and `writeIdx +
    // lengthTaps`. The convolution then pulls a contiguous lengthTaps-
    // length window starting at `writeIdx + 1` and hands it to vDSP_dotpr,
    // which uses Apple Silicon's SIMD/AMX paths for ~5-10× speedup vs
    // a pure-Swift loop. Critical for affordable multiband FIR — the per-
    // sample 2049-tap dot product is the chain's hot loop.
    private var delayL: [Float] = []
    private var delayR: [Float] = []
    private var writeIdx: Int = 0
    private var lengthTaps: Int = 0
    private var halfLength: Int = 0

    var tapCount: Int { lengthTaps }
    var groupDelaySamples: Int { halfLength }
    var enabled: Bool { lengthTaps > 0 }

    mutating func configure(
        cutoffHz: Float,
        sampleRate: Float,
        stopBandDB: Float = 82.0,
        transitionHz: Float = 1_500.0
    ) {
        coeffs = kaiserSincLowpassCoefficients(
            cutoffHz: cutoffHz,
            sampleRate: sampleRate,
            stopBandDB: stopBandDB,
            transitionHz: transitionHz
        )
        lengthTaps = coeffs.count
        halfLength = (lengthTaps - 1) / 2
        delayL = [Float](repeating: 0.0, count: lengthTaps * 2)
        delayR = [Float](repeating: 0.0, count: lengthTaps * 2)
        writeIdx = 0
    }

    mutating func reset() {
        guard lengthTaps > 0 else { return }
        for i in 0..<delayL.count {
            delayL[i] = 0
            delayR[i] = 0
        }
        writeIdx = 0
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        guard lengthTaps > 0 else { return (left, right) }
        // Write to both halves of the double buffer so the read window
        // is always contiguous regardless of writeIdx wrap.
        delayL[writeIdx] = left
        delayL[writeIdx + lengthTaps] = left
        delayR[writeIdx] = right
        delayR[writeIdx + lengthTaps] = right

        // The chronologically-ordered window (oldest → newest) sits at
        // [writeIdx + 1, writeIdx + lengthTaps]. Symmetric Kaiser-sinc
        // coefficients mean indexing direction is moot: we can hand
        // the contiguous slice to vDSP_dotpr directly.
        let startIdx = writeIdx + 1
        var outL: Float = 0
        var outR: Float = 0
        let n = vDSP_Length(lengthTaps)
        coeffs.withUnsafeBufferPointer { coeffPtr in
            delayL.withUnsafeBufferPointer { delayPtr in
                vDSP_dotpr(
                    coeffPtr.baseAddress!, 1,
                    delayPtr.baseAddress!.advanced(by: startIdx), 1,
                    &outL,
                    n
                )
            }
            delayR.withUnsafeBufferPointer { delayPtr in
                vDSP_dotpr(
                    coeffPtr.baseAddress!, 1,
                    delayPtr.baseAddress!.advanced(by: startIdx), 1,
                    &outR,
                    n
                )
            }
        }

        writeIdx += 1
        if writeIdx >= lengthTaps { writeIdx = 0 }
        return (outL, outR)
    }
}

/// Linear-phase complementary FIR splitter — splits an input into a low
/// band (FIR lowpass) and a high band (delayed input minus FIR lowpass).
/// By construction `low + high = delay(groupDelaySamples)(input)` exactly,
/// so the bands are time-aligned and sum to flat. Used by
/// `LinearPhaseMultibandSplitter5` / `3` to build phase-coherent multiband
/// crossovers — replaces the IIR `LinkwitzRiley4` chain in TX mode.
/// Linear-phase FIR decimator for the composite clipper's oversampling
/// chain. Replaces the prior 12th-order Butterworth biquad cascade
/// (`BiquadCascade6`), which had two failure modes the verifier flagged:
///
/// 1. **Stopband leakage** at 0.5×Nyquist of the OS rate. The
///    Butterworth's ~70-80 dB rejection lets the tanh nonlinearity's
///    2×38±12 = 64 / 88 kHz IM products fold back through the
///    decimator into the audio composite. Manifests on the
///    `hf_edge_12k` scenario as `>67k/in` energy 17 dB above spec.
/// 2. **Non-flat group delay** above ~30 kHz. The Butterworth phase
///    rolls off to ~150° at the upper subcarrier edge (37 kHz),
///    phase-twisting the (L−R) sidebands centred on 38±12 kHz
///    relative to the cleanly-injected 38 kHz carrier. Manifests as
///    correlation-delta drift and side-retention loss on hf_edge_12k.
///
/// Algorithm: Kaiser-windowed-sinc FIR designed at the OS rate to a
/// configurable passband / transition / stopband target. Uses the same
/// `kaiserSincLowpassCoefficients` kernel + `vDSP_dotpr` polyphase
/// pattern as `LinearPhaseFIRLowpass`. Decimation factor is set at
/// configure() time; the struct emits one output every `decimateFactor`
/// pushes.
///
/// Reference: Kahles, Esqueda, Valimaki, "Oversampling for Nonlinear
/// Waveshaping: Choosing the Right Filters" (JAES 2019). Quantitatively
/// shows length-matched FIR has ~20 dB more stopband rejection than a
/// 12th-order Butterworth at 0.5×Nyquist.
struct LinearPhaseFIRDecimator {
    private var coeffs: [Float] = []
    /// Double-buffered delay line at OS rate. Same trick as
    /// `LinearPhaseFIRLowpass` — write each input to two positions so
    /// the read window for `vDSP_dotpr` is always contiguous.
    private var delay: [Float] = []
    private var writeIdx: Int = 0
    private var lengthTaps: Int = 0
    private var halfLength: Int = 0
    private var decimateFactor: Int = 1
    private var pushSinceLastEmit: Int = 0
    private var lastOutput: Float = 0.0

    var tapCount: Int { lengthTaps }
    /// Group delay measured in OS-rate samples (kernel midpoint).
    var groupDelayOSSamples: Int { halfLength }
    /// Group delay measured in host-rate (post-decimation) samples,
    /// rounded to the nearest integer. The nearest-integer rounding
    /// yields a ±0.5 OS-sample residual phase offset, which at typical
    /// 8× rates is sub-microsecond — negligible at audio frequencies.
    var groupDelayHostSamples: Int {
        guard decimateFactor > 0 else { return 0 }
        return (halfLength + decimateFactor / 2) / decimateFactor
    }
    var enabled: Bool { lengthTaps > 0 }

    mutating func configure(
        cutoffHz: Float,
        sampleRateOS: Float,
        decimateFactor: Int,
        stopBandDB: Float = 90.0,
        transitionHz: Float = 60_000.0
    ) {
        coeffs = kaiserSincLowpassCoefficients(
            cutoffHz: cutoffHz,
            sampleRate: sampleRateOS,
            stopBandDB: stopBandDB,
            transitionHz: transitionHz
        )
        lengthTaps = coeffs.count
        halfLength = (lengthTaps - 1) / 2
        delay = [Float](repeating: 0.0, count: lengthTaps * 2)
        writeIdx = 0
        self.decimateFactor = max(1, decimateFactor)
        pushSinceLastEmit = 0
        lastOutput = 0.0
    }

    mutating func reset() {
        guard lengthTaps > 0 else { return }
        for i in 0..<delay.count { delay[i] = 0 }
        writeIdx = 0
        pushSinceLastEmit = 0
        lastOutput = 0.0
    }

    /// Push one OS-rate sample. Returns the most-recent decimated
    /// output. The output value updates only on every Nth push (where
    /// N = `decimateFactor`); intermediate calls return the previously
    /// emitted value (so callers can read `lastOutput` once per host
    /// sample without tracking decimation phase).
    @inline(__always)
    mutating func push(_ x: Float) -> Float {
        guard lengthTaps > 0 else { return x }
        delay[writeIdx] = x
        delay[writeIdx + lengthTaps] = x
        writeIdx += 1
        if writeIdx >= lengthTaps { writeIdx = 0 }
        pushSinceLastEmit += 1
        if pushSinceLastEmit >= decimateFactor {
            pushSinceLastEmit = 0
            // Read the contiguous lengthTaps-length window starting at
            // writeIdx and dot it against the symmetric Kaiser-sinc
            // coefficients via vDSP_dotpr.
            var out: Float = 0
            let n = vDSP_Length(lengthTaps)
            coeffs.withUnsafeBufferPointer { c in
                delay.withUnsafeBufferPointer { d in
                    vDSP_dotpr(
                        c.baseAddress!, 1,
                        d.baseAddress!.advanced(by: writeIdx), 1,
                        &out,
                        n
                    )
                }
            }
            lastOutput = out
        }
        return lastOutput
    }
}

struct LinearPhaseFIRSplitter {
    private var coeffs: [Float] = []
    private var delayL: [Float] = []
    private var delayR: [Float] = []
    private var writeIdx: Int = 0
    private var lengthTaps: Int = 0
    private var halfLength: Int = 0

    var tapCount: Int { lengthTaps }
    var groupDelaySamples: Int { halfLength }
    var enabled: Bool { lengthTaps > 0 }

    mutating func configure(
        cutoffHz: Float,
        sampleRate: Float,
        stopBandDB: Float = 60.0,
        transitionHz: Float = 1_000.0
    ) {
        coeffs = kaiserSincLowpassCoefficients(
            cutoffHz: cutoffHz,
            sampleRate: sampleRate,
            stopBandDB: stopBandDB,
            transitionHz: transitionHz
        )
        lengthTaps = coeffs.count
        halfLength = (lengthTaps - 1) / 2
        delayL = [Float](repeating: 0.0, count: lengthTaps)
        delayR = [Float](repeating: 0.0, count: lengthTaps)
        writeIdx = 0
    }

    mutating func reset() {
        guard lengthTaps > 0 else { return }
        for i in 0..<lengthTaps {
            delayL[i] = 0
            delayR[i] = 0
        }
        writeIdx = 0
    }

    /// Returns `(low_l, low_r, high_l, high_r)` with both outputs delayed
    /// by `groupDelaySamples` relative to the unfiltered input.
    mutating func process(left: Float, right: Float)
        -> (lowL: Float, lowR: Float, highL: Float, highR: Float)
    {
        guard lengthTaps > 0 else { return (left, right, 0, 0) }
        delayL[writeIdx] = left
        delayR[writeIdx] = right
        var lowL: Float = 0
        var lowR: Float = 0
        var idx = writeIdx
        let n = lengthTaps
        for i in 0..<n {
            lowL += coeffs[i] * delayL[idx]
            lowR += coeffs[i] * delayR[idx]
            idx -= 1
            if idx < 0 { idx = n - 1 }
        }
        // Read the centre tap of the delay line — that's input(t - halfLength).
        var centerIdx = writeIdx - halfLength
        if centerIdx < 0 { centerIdx += n }
        let centerL = delayL[centerIdx]
        let centerR = delayR[centerIdx]

        writeIdx += 1
        if writeIdx >= n { writeIdx = 0 }
        return (lowL, lowR, centerL - lowL, centerR - lowR)
    }
}

/// Linear-phase 5-band splitter using parallel-cumulative-LP topology.
/// Each band is the difference of two cumulative lowpasses; all bands
/// share identical group delay (`groupDelaySamples`), so summing them
/// reconstructs `delay(groupDelaySamples)(input)` exactly. Solves the
/// IIR-LR4 inter-band phase mismatch that smears transients.
struct LinearPhaseMultibandSplitter5 {
    // Cumulative lowpasses at each of the 4 crossover frequencies. The
    // 5 output bands are formed by differencing adjacent LPs:
    //   B1 = LP(x1)
    //   B2 = LP(x2) - LP(x1)
    //   B3 = LP(x3) - LP(x2)
    //   B4 = LP(x4) - LP(x3)
    //   B5 = delay(centre)(input) - LP(x4)
    // All four LPs are designed with the same tap count, so all bands
    // share group delay = (N-1)/2.
    private var lp1 = LinearPhaseFIRLowpass()
    private var lp2 = LinearPhaseFIRLowpass()
    private var lp3 = LinearPhaseFIRLowpass()
    private var lp4 = LinearPhaseFIRLowpass()
    // Delay line for the unfiltered input so we can form B5 = delayed - LP(x4).
    private var delayL: [Float] = []
    private var delayR: [Float] = []
    private var writeIdx: Int = 0
    private var halfLength: Int = 0

    var groupDelaySamples: Int { halfLength }
    var enabled: Bool { halfLength > 0 }

    mutating func configure(
        x1Hz: Float, x2Hz: Float, x3Hz: Float, x4Hz: Float,
        sampleRate: Float,
        stopBandDB: Float = 50.0,
        transitionHz: Float = 0.0  // ignored; kept for API symmetry
    ) {
        _ = transitionHz
        // All 4 LPs MUST share the same tap count so band reconstruction
        // is time-aligned. The transition band is the binding parameter:
        // a tighter transition needs more taps. We size the transition
        // for the LOWEST cutoff (the binding constraint) and apply it
        // uniformly to all LPs. Higher-frequency LPs end up with wider-
        // than-needed stop-bands, which is fine for band separation.
        //
        // Per-cutoff: transition ≈ fc × 0.4, floor 60 Hz. For x1=90 Hz
        // that's 60 Hz transition. At 192 kHz with stopBandDB=50, Kaiser
        // estimate yields ~1340 taps, clamped to 2049 max → group delay
        // 1024 samples = 5.3 ms.
        let lowest = max(30.0, min(x1Hz, min(x2Hz, min(x3Hz, x4Hz))))
        let sharedTransition = max(60.0, lowest * 0.4)
        lp1.configure(cutoffHz: x1Hz, sampleRate: sampleRate,
                      stopBandDB: stopBandDB, transitionHz: sharedTransition)
        lp2.configure(cutoffHz: x2Hz, sampleRate: sampleRate,
                      stopBandDB: stopBandDB, transitionHz: sharedTransition)
        lp3.configure(cutoffHz: x3Hz, sampleRate: sampleRate,
                      stopBandDB: stopBandDB, transitionHz: sharedTransition)
        lp4.configure(cutoffHz: x4Hz, sampleRate: sampleRate,
                      stopBandDB: stopBandDB, transitionHz: sharedTransition)
        // Sanity: assert all 4 share the same tap count. Should always
        // hold since they share transition + stop-band + sample rate.
        precondition(lp1.tapCount == lp2.tapCount,
                     "Multiband FIR LPs out of sync (lp1=\(lp1.tapCount), lp2=\(lp2.tapCount))")
        precondition(lp1.tapCount == lp3.tapCount)
        precondition(lp1.tapCount == lp4.tapCount)
        halfLength = lp1.groupDelaySamples
        let bufLen = max(1, halfLength + 1)
        delayL = [Float](repeating: 0.0, count: bufLen)
        delayR = [Float](repeating: 0.0, count: bufLen)
        writeIdx = 0
    }

    mutating func reset() {
        lp1.reset(); lp2.reset(); lp3.reset(); lp4.reset()
        for i in 0..<delayL.count { delayL[i] = 0; delayR[i] = 0 }
        writeIdx = 0
    }

    /// Returns 5 stereo bands `(b1L, b1R) ... (b5L, b5R)`, all delayed by
    /// `groupDelaySamples` relative to the input.
    mutating func process(left: Float, right: Float)
        -> ((Float, Float), (Float, Float), (Float, Float), (Float, Float), (Float, Float))
    {
        let n = delayL.count
        guard n > 0 else {
            return ((0, 0), (0, 0), (left, right), (0, 0), (0, 0))
        }
        let (l1L, l1R) = lp1.process(left: left, right: right)
        let (l2L, l2R) = lp2.process(left: left, right: right)
        let (l3L, l3R) = lp3.process(left: left, right: right)
        let (l4L, l4R) = lp4.process(left: left, right: right)
        // Delay line for the input itself, length = halfLength + 1 so we
        // can read the sample that's `halfLength` old.
        delayL[writeIdx] = left
        delayR[writeIdx] = right
        var readIdx = writeIdx - halfLength
        if readIdx < 0 { readIdx += n }
        let dlyL = delayL[readIdx]
        let dlyR = delayR[readIdx]
        writeIdx += 1
        if writeIdx >= n { writeIdx = 0 }

        let b1 = (l1L, l1R)
        let b2 = (l2L - l1L, l2R - l1R)
        let b3 = (l3L - l2L, l3R - l2R)
        let b4 = (l4L - l3L, l4R - l3R)
        let b5 = (dlyL - l4L, dlyR - l4R)
        return (b1, b2, b3, b4, b5)
    }
}

/// Linear-phase 3-band splitter — same construction as the 5-band but
/// with 2 cumulative lowpasses.
struct LinearPhaseMultibandSplitter3 {
    private var lp1 = LinearPhaseFIRLowpass()
    private var lp2 = LinearPhaseFIRLowpass()
    private var delayL: [Float] = []
    private var delayR: [Float] = []
    private var writeIdx: Int = 0
    private var halfLength: Int = 0

    var groupDelaySamples: Int { halfLength }
    var enabled: Bool { halfLength > 0 }

    mutating func configure(
        lowHz: Float, highHz: Float,
        sampleRate: Float,
        stopBandDB: Float = 50.0,
        transitionHz: Float = 0.0  // ignored; kept for API symmetry
    ) {
        _ = transitionHz
        // Same approach as the 5-band variant: shared transition sized
        // from the lower cutoff, uniform across both LPs so they share
        // tap count and group delay.
        let lowest = max(30.0, min(lowHz, highHz))
        let sharedTransition = max(60.0, lowest * 0.4)
        lp1.configure(cutoffHz: lowHz, sampleRate: sampleRate,
                      stopBandDB: stopBandDB, transitionHz: sharedTransition)
        lp2.configure(cutoffHz: highHz, sampleRate: sampleRate,
                      stopBandDB: stopBandDB, transitionHz: sharedTransition)
        precondition(lp1.tapCount == lp2.tapCount)
        halfLength = lp1.groupDelaySamples
        let bufLen = max(1, halfLength + 1)
        delayL = [Float](repeating: 0.0, count: bufLen)
        delayR = [Float](repeating: 0.0, count: bufLen)
        writeIdx = 0
    }

    mutating func reset() {
        lp1.reset(); lp2.reset()
        for i in 0..<delayL.count { delayL[i] = 0; delayR[i] = 0 }
        writeIdx = 0
    }

    /// Returns 3 stereo bands `(low, mid, high)`, all delayed by
    /// `groupDelaySamples` relative to the input.
    mutating func process(left: Float, right: Float)
        -> ((Float, Float), (Float, Float), (Float, Float))
    {
        let n = delayL.count
        guard n > 0 else { return ((0, 0), (left, right), (0, 0)) }
        let (l1L, l1R) = lp1.process(left: left, right: right)
        let (l2L, l2R) = lp2.process(left: left, right: right)
        delayL[writeIdx] = left
        delayR[writeIdx] = right
        var readIdx = writeIdx - halfLength
        if readIdx < 0 { readIdx += n }
        let dlyL = delayL[readIdx]
        let dlyR = delayR[readIdx]
        writeIdx += 1
        if writeIdx >= n { writeIdx = 0 }

        let low = (l1L, l1R)
        let mid = (l2L - l1L, l2R - l1R)
        let high = (dlyL - l2L, dlyR - l2R)
        return (low, mid, high)
    }
}

@inline(__always)
private func effectiveProgramLowpassHz(configured: Float, preemphasisUS: Int) -> Float {
    guard preemphasisUS > 0 else { return configured }
    let complianceCap: Float = preemphasisUS <= 50 ? 15_300.0 : 15_000.0
    return min(configured, complianceCap)
}

@inline(__always)
private func effectiveEncoderLowpassHz(configured: Float, preemphasisUS: Int) -> Float {
    guard preemphasisUS > 0 else { return configured }
    let encoderCap: Float = preemphasisUS <= 50 ? 14_900.0 : 14_600.0
    return min(configured, encoderCap)
}

struct PreemphasisFilter {
    var enabled: Bool = false
    private var a: Float = 0.0
    private var invOneMinusA: Float = 1.0
    private var x1: Float = 0.0

    mutating func configure(tauUS: Int, sampleRate: Float) {
        guard tauUS > 0 else {
            enabled = false
            a = 0.0
            invOneMinusA = 1.0
            x1 = 0.0
            return
        }
        enabled = true
        let sr = max(8_000.0 as Float, sampleRate)
        let tau = Float(tauUS) * 1e-6
        a = expf(-1.0 / (tau * sr))
        invOneMinusA = 1.0 / max(1e-9, (1.0 - a))
        x1 = 0.0
    }

    mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let y = (x - a * x1) * invOneMinusA
        x1 = zapDenorm(x)
        return y
    }

    mutating func reset() { x1 = 0.0 }
}

struct DeemphasisFilter {
    var enabled: Bool = false
    private var a: Float = 0.0
    private var y1: Float = 0.0

    mutating func configure(tauUS: Int, sampleRate: Float) {
        guard tauUS > 0 else {
            enabled = false
            a = 0.0
            y1 = 0.0
            return
        }
        enabled = true
        let sr = max(8_000.0 as Float, sampleRate)
        let tau = Float(tauUS) * 1e-6
        a = expf(-1.0 / (tau * sr))
        y1 = 0.0
    }

    mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let y = (1.0 - a) * x + a * y1
        y1 = zapDenorm(y)
        return y
    }

    mutating func reset() { y1 = 0.0 }
}

struct EnvelopeFollower {
    var attackCoeff: Float = 0.0
    var releaseCoeff: Float = 0.0
    var value: Float = 0.0

    mutating func configure(sampleRate: Float, attackMS: Float, releaseMS: Float) {
        let sr = max(8_000.0, sampleRate)
        let a = max(0.1, attackMS) * 0.001
        let r = max(1.0, releaseMS) * 0.001
        attackCoeff = expf(-1.0 / (a * sr))
        releaseCoeff = expf(-1.0 / (r * sr))
    }

    mutating func processAbs(_ x: Float) -> Float {
        let ax = fabsf(x)
        if ax > value {
            value = (attackCoeff * value) + ((1.0 - attackCoeff) * ax)
        } else {
            value = (releaseCoeff * value) + ((1.0 - releaseCoeff) * ax)
        }
        value = zapDenorm(value)
        return value
    }
}

/// Approximate ITU-R BS.1770-4 K-weighting pre-filter used as the
/// sidechain feed for perceptual power detection. Two cascaded RBJ
/// biquads (high-pass + high-shelf) approximate the BS.1770 curve:
/// low-frequency rumble is rolled off so it doesn't dominate the
/// detector; mid/upper frequencies get a gentle shelf boost so their
/// perceptually loud content (vocals, sibilance, cymbals) reads hot.
///
/// This doesn't need to be bit-identical to BS.1770 — the goal is
/// simply a rate-flexible, perceptually-weighted detector that sees
/// what humans hear, not what a flat RMS calculation sees. The
/// audio-path signal is untouched; these filters only feed the AGC's
/// power follower.
struct KWeightingFilter {
    private var hpf = Biquad()
    private var shelf = Biquad()

    mutating func configure(sampleRate: Float) {
        // RLB high-pass — roll off below ~38 Hz so sub-audible rumble
        // doesn't bias the detector.
        hpf.configureHighpass(cutoffHz: 38.0, sampleRate: sampleRate, q: 0.5)
        // Head-simulator shelf — +4 dB above ~1.5 kHz lifts the
        // perceptually loud register into the detector's view.
        shelf.configureHighShelf(gainDB: 4.0, cutoffHz: 1_500.0, sampleRate: sampleRate)
    }

    mutating func process(_ x: Float) -> Float {
        shelf.process(hpf.process(x))
    }

    mutating func reset() {
        hpf.reset()
        shelf.reset()
    }
}

struct WidebandAGCRider {
    private var detectorAttackCoeff: Float = 0.0
    private var detectorReleaseCoeff: Float = 0.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    private var fastMakeupCoeff: Float = 0.0
    private var gateReleaseCoeff: Float = 0.0
    private var densityCoeff: Float = 0.0
    private var fastEnvCoeff: Float = 0.0
    private var slowEnvCoeff: Float = 0.0
    private var sampleRate: Float = 48_000.0
    private var configuredReleaseS: Double = 0.250

    private var targetDB: Float = -20.0
    private var minGainDB: Float = -12.0
    private var maxGainDB: Float = 12.0
    private var windowDB: Float = 1.5
    private var gateThresholdDB: Float = -42.0
    private var makeupThresholdDB: Float = -30.0

    private var kWeightingEnabled: Bool = true
    private var programDependentRelease: Bool = true
    private var kWeightL = KWeightingFilter()
    private var kWeightR = KWeightingFilter()

    private var power: Float = 0.0
    private var gainDB: Float = 0.0
    private var gateActive: Bool = false
    /// Two envelope followers at different time constants. Their log-
    /// ratio is the "program density" signal: if fast and slow
    /// envelopes agree, program is flat; if they diverge (transients,
    /// syllables, rhythmic modulation) program is busy. More reliable
    /// than |ΔlevelDB| on a heavily-smoothed detector, which barely
    /// wobbles between adjacent samples.
    private var fastEnv: Float = 0.0
    private var slowEnv: Float = 0.0
    /// Smoothed density value in dB. ~0 dB on flat program, several
    /// dB on busy program.
    private var density: Float = 0.0

    mutating func configure(
        sampleRate: Float,
        targetDB: Float,
        attackMS: Float,
        releaseMS: Float,
        minGainDB: Float,
        maxGainDB: Float,
        kWeightingEnabled: Bool = true,
        programDependentRelease: Bool = true
    ) {
        let sr = max(8_000.0, sampleRate)
        self.sampleRate = sr
        let detectorAttackS = max(0.005, min(Double(attackMS) * 0.001 * 0.35, 0.050))
        let detectorReleaseS = max(0.120, Double(releaseMS) * 0.001 * 0.60)
        detectorAttackCoeff = expf(-1.0 / Float(detectorAttackS * Double(sr)))
        detectorReleaseCoeff = expf(-1.0 / Float(detectorReleaseS * Double(sr)))

        let attackS = max(0.010, Double(attackMS) * 0.001)
        let releaseS = max(0.250, Double(releaseMS) * 0.001)
        let fastMakeupS = max(0.120, min(releaseS * 0.35, 0.450))
        configuredReleaseS = releaseS
        attackCoeff = expf(-1.0 / Float(attackS * Double(sr)))
        releaseCoeff = expf(-1.0 / Float(releaseS * Double(sr)))
        fastMakeupCoeff = expf(-1.0 / Float(fastMakeupS * Double(sr)))
        gateReleaseCoeff = expf(-1.0 / Float(1.6 * Double(sr)))
        // Density tracker: fast envelope (~50 ms) tracks syllable /
        // transient wobble; slow envelope (~1 s) tracks program
        // platform. Their log-ratio gauges program busy-ness.
        // Smoothed over ~0.5 s so the density value itself is stable.
        fastEnvCoeff = expf(-1.0 / Float(0.050 * Double(sr)))
        slowEnvCoeff = expf(-1.0 / Float(1.000 * Double(sr)))
        densityCoeff = expf(-1.0 / Float(0.500 * Double(sr)))

        self.targetDB = targetDB
        self.minGainDB = minGainDB
        self.maxGainDB = maxGainDB
        self.windowDB = 3.0
        self.gateThresholdDB = targetDB - maxGainDB - 10.0
        self.makeupThresholdDB = targetDB - maxGainDB + 2.0

        self.kWeightingEnabled = kWeightingEnabled
        self.programDependentRelease = programDependentRelease
        kWeightL.configure(sampleRate: sr)
        kWeightR.configure(sampleRate: sr)
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        // Sidechain feed — audio path stays pristine, only the
        // detector sees the K-weighted signal.
        let sideL: Float
        let sideR: Float
        if kWeightingEnabled {
            sideL = kWeightL.process(left)
            sideR = kWeightR.process(right)
        } else {
            sideL = left
            sideR = right
        }

        let monoPower = max(1e-12, 0.5 * ((sideL * sideL) + (sideR * sideR)))
        let detectorCoeff = monoPower > power ? detectorAttackCoeff : detectorReleaseCoeff
        power = (detectorCoeff * power) + ((1.0 - detectorCoeff) * monoPower)
        power = zapDenorm(power)

        let levelDB = 10.0 * log10f(max(power, 1e-12))

        // Program-density estimate via fast-vs-slow envelope
        // divergence. Run raw power through two first-order smoothers
        // at ~50 ms and ~1 s; their log-ratio is how far the short-
        // term envelope is from the platform. Busy program (syllables,
        // transients, rhythmic modulation) makes |ratio_dB| large;
        // flat program keeps fast ≈ slow → ratio ≈ 0 dB.
        fastEnv = (fastEnvCoeff * fastEnv) + ((1.0 - fastEnvCoeff) * monoPower)
        slowEnv = (slowEnvCoeff * slowEnv) + ((1.0 - slowEnvCoeff) * monoPower)
        fastEnv = zapDenorm(fastEnv)
        slowEnv = zapDenorm(slowEnv)
        let envRatio = max(fastEnv, slowEnv) / max(1e-12, min(fastEnv, slowEnv))
        let instantDensity = 10.0 * log10f(max(1.0, envRatio))
        density = (densityCoeff * density) + ((1.0 - densityCoeff) * instantDensity)

        let desiredGainDB = clampf(targetDB - levelDB, minGainDB, maxGainDB)

        // Scale effective release coefficient by program density when
        // enabled. Density 0 → configured release; density ≥4 dB → 3x
        // slower release. Linear mapping in between; saturates at 3x
        // so very busy program can't stall the AGC completely.
        let effectiveReleaseCoeff: Float
        let effectiveFastMakeupCoeff: Float
        if programDependentRelease {
            let densityClamped = max(0.0, min(4.0, Double(density)))
            let densityScale = 1.0 + densityClamped * 0.5   // 1x…3x
            let scaledReleaseS = configuredReleaseS * densityScale
            let scaledFastS = max(0.120, min(scaledReleaseS * 0.35, 0.450))
            effectiveReleaseCoeff = expf(-1.0 / Float(scaledReleaseS * Double(sampleRate)))
            effectiveFastMakeupCoeff = expf(-1.0 / Float(scaledFastS * Double(sampleRate)))
        } else {
            effectiveReleaseCoeff = releaseCoeff
            effectiveFastMakeupCoeff = fastMakeupCoeff
        }

        let targetGainDB: Float
        let coeff: Float
        if levelDB < gateThresholdDB {
            // Do not lift room noise or codec hash; drift back toward unity instead.
            targetGainDB = 0.0
            coeff = gateReleaseCoeff
            gateActive = true
        } else if fabsf(desiredGainDB - gainDB) <= windowDB {
            targetGainDB = gainDB
            coeff = 1.0
            gateActive = false
        } else if desiredGainDB < gainDB {
            targetGainDB = desiredGainDB
            coeff = attackCoeff
            gateActive = false
        } else {
            targetGainDB = desiredGainDB
            coeff = levelDB < makeupThresholdDB ? effectiveFastMakeupCoeff : effectiveReleaseCoeff
            gateActive = false
        }

        gainDB = (coeff * gainDB) + ((1.0 - coeff) * targetGainDB)
        gainDB = clampf(gainDB, minGainDB, maxGainDB)

        let gain = powf(10.0, gainDB / 20.0)
        return (left * gain, right * gain)
    }

    mutating func reset() {
        power = 0.0
        gainDB = 0.0
        gateActive = false
        density = 0.0
        fastEnv = 0.0
        slowEnv = 0.0
        kWeightL.reset()
        kWeightR.reset()
    }

    var telemetry: (detectorDB: Float, gainDB: Float, gateActive: Bool) {
        let detectorDB = 10.0 * log10f(max(power, 1e-12))
        return (detectorDB, gainDB, gateActive)
    }

    /// Current program-density estimate in dB. Exposed for diagnostics
    /// / tests; not surfaced to the UI (yet).
    var currentDensityDB: Float { density }
}

struct MonoCompressor {
    var thresholdDB: Float = -18.0
    var ratio: Float = 2.0
    var makeupDB: Float = 0.0
    var kneeDB: Float = 0.0
    var detector = EnvelopeFollower()

    mutating func configure(
        sampleRate: Float,
        thresholdDB: Float,
        ratio: Float,
        attackMS: Float,
        releaseMS: Float,
        makeupDB: Float,
        kneeDB: Float = 0.0
    ) {
        self.thresholdDB = thresholdDB
        self.ratio = max(1.0, ratio)
        self.makeupDB = makeupDB
        self.kneeDB = max(0.0, min(12.0, kneeDB))
        detector.configure(sampleRate: sampleRate, attackMS: attackMS, releaseMS: releaseMS)
    }

    mutating func process(_ x: Float, sidechainAbs: Float? = nil) -> Float {
        let detectorSample = sidechainAbs ?? x
        let env = max(1e-8, detector.processAbs(detectorSample))
        let levelDB = 20.0 * log10f(env)
        let gainDB = gainReductionDB(for: levelDB)
        let gain = powf(10.0, (gainDB + makeupDB) / 20.0)
        return x * gain
    }

    private func gainReductionDB(for levelDB: Float) -> Float {
        if ratio <= 1.0 {
            return 0.0
        }
        let kneeHalf = kneeDB * 0.5
        if kneeDB <= 0.01 {
            if levelDB <= thresholdDB {
                return 0.0
            }
            let over = levelDB - thresholdDB
            return -(over - (over / ratio))
        }

        let lower = thresholdDB - kneeHalf
        let upper = thresholdDB + kneeHalf
        if levelDB <= lower {
            return 0.0
        }
        if levelDB >= upper {
            let over = levelDB - thresholdDB
            return -(over - (over / ratio))
        }
        let delta = levelDB - lower
        let curve = ((1.0 / ratio) - 1.0) * ((delta * delta) / (2.0 * max(1e-4, kneeDB)))
        return curve
    }
}

struct LookaheadLimiter {
    var enabled: Bool = false
    var threshold: Float = 0.98
    var lookaheadSamples: Int = 0
    var delayLine: [Float] = []
    var writeIndex: Int = 0
    var gain: Float = 1.0
    var attackCoeff: Float = 0.0
    var releaseCoeff: Float = 0.0
    var holdSamples: Int = 0
    var holdCounter: Int = 0

    mutating func configure(sampleRate: Float, lookaheadMS: Float, threshold: Float, enabled: Bool)
    {
        self.enabled = enabled
        self.threshold = clampf(threshold, 0.5, 0.999)

        let sr = max(8_000.0, sampleRate)
        let laMS = clampf(lookaheadMS, 0.0, 20.0)
        let requestedSamples = max(0, Int((sr * laMS * 0.001).rounded()))
        if requestedSamples != lookaheadSamples {
            lookaheadSamples = requestedSamples
            delayLine = lookaheadSamples > 0 ? Array(repeating: 0.0, count: lookaheadSamples) : []
            writeIndex = 0
        }

        let attackS = 0.00035 as Float
        let releaseS = 0.095 as Float
        attackCoeff = expf(-1.0 / (attackS * sr))
        releaseCoeff = expf(-1.0 / (releaseS * sr))
        holdSamples = max(1, Int((0.004 * sr).rounded()))
        holdCounter = 0
        if !enabled {
            gain = 1.0
        }
    }

    mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }

        let detector = fabsf(x)
        var delayed = x
        if lookaheadSamples > 0, !delayLine.isEmpty {
            delayed = delayLine[writeIndex]
            delayLine[writeIndex] = x
            writeIndex += 1
            if writeIndex >= lookaheadSamples {
                writeIndex = 0
            }
        }

        var targetGain: Float = 1.0
        if detector > threshold {
            targetGain = threshold / max(1e-9, detector)
        }
        targetGain = clampf(targetGain, 0.0, 1.0)

        if targetGain < gain {
            gain = (attackCoeff * gain) + ((1.0 - attackCoeff) * targetGain)
            holdCounter = holdSamples
        } else if holdCounter > 0 {
            holdCounter -= 1
        } else {
            gain = (releaseCoeff * gain) + ((1.0 - releaseCoeff) * targetGain)
        }
        return delayed * gain
    }

    var gainReductionDB: Float {
        let safeGain = max(1e-6, gain)
        return max(0.0, -20.0 * log10f(safeGain))
    }
}

private struct RDSGroupSpec {
    let type: Int
    let versionB: Bool
}

private struct RTPlusTag {
    let contentType: Int
    let start: Int
    let length: Int
}

struct TimedTextFrame: Equatable {
    let duration: Double
    let transmits: Int
    let text: String

    init(duration: Double, text: String) {
        self.duration = duration
        self.transmits = 0
        self.text = text
    }

    init(transmits: Int, text: String) {
        self.duration = 0
        self.transmits = max(1, transmits)
        self.text = text
    }
}

final class BasicRDSCoder {
    private static let bitrate = Float(1187.5)
    private static let crcPoly = 0x5B9
    private static let offsetA = 0x0FC
    private static let offsetB = 0x198
    private static let offsetC = 0x168
    private static let offsetCp = 0x1E0
    private static let offsetD = 0x1B4
    private static let gregorianCalendar = Calendar(identifier: .gregorian)

    private struct CachedClockTimeGroup {
        let minuteToken: Int
        let b2Tail: Int
        let b3Value: Int
        let b4Value: Int
    }

    private var enabled: Bool
    private let levelScale: Float
    private var piCode: Int
    private var pty: Int
    private var tpFlag: Bool
    private var taFlag: Bool
    private var msFlag: Bool
    private var diStereoFlag: Bool
    private var diHeadFlag: Bool
    private var diCompFlag: Bool
    private var diDynFlag: Bool
    private var afEnabled: Bool
    private var afMethod: String
    private var afCodes: [Int]
    private var psCentered: Bool
    // PS banks: 4 text banks (A/B/C/D) with a single active selector.
    // Live-apply — switching the active bank rebuilds psSequence/psFrames.
    private var psBanks: [String]
    private var psActiveBankIndex: Int
    private var psFrameSeconds: Double
    private let rtManualBuffers: Bool
    private var rtCycleAB: Bool
    private var rtRawText: String
    private var rtRawBuffers: [String]
    private let rtBuffers: [String]
    private var rtBufferEnabled: [Bool]
    private var rtCR: Bool
    private var rtCentered: Bool
    private var rtMode2B: Bool
    private let rtCycle: Bool
    private var rtCycleTime: Double
    private let rtActiveBuffer: Int
    private var rtABCycleCount: Int
    private let rdsFreqHz: Float
    private let gaussianEnabled: Bool
    private let gaussianBWHZ: Float
    private let gaussianTaps: Int
    private var schedule: [RDSGroupSpec]
    private var schedulerAuto: Bool
    private var schedulerStandard: Bool
    private var schedulerStandardLPS: Bool
    private var psFrames: [String]
    private var psFrameBytes: [[UInt8]]
    private var rtFrames: [String]
    private var psSequence: [TimedTextFrame]
    private var rtSequence: [TimedTextFrame]
    private var ptynEnabled: Bool
    private var ptynCentered: Bool
    private var ptynRawText: String
    private var ptynFrames: [String]
    private var ptynFrameBytes: [[UInt8]]
    private var ptynSequence: [TimedTextFrame]
    private var lpsEnabled: Bool
    private var lpsCentered: Bool
    private var lpsCR: Bool
    private var lpsRawText: String
    private var lpsFrames: [String]
    private var lpsPreparedFrameBytes: [[UInt8]]
    private var lpsSequence: [TimedTextFrame]
    private var rtPlusEnabled: Bool
    private var rtPlusFormatA: String
    private var rtPlusFormatB: String
    private var nowPlayingEnabled: Bool
    private let nowPlayingState: NowPlayingState?
    private var enCT: Bool
    private var enID: Bool
    private var eccCode: Int
    private var licCode: Int
    private var tzOffset: Double
    private let cachedGroup1Variant = ManagedAtomic<Int>(0)
    private let cachedCTMinuteToken = ManagedAtomic<Int>(-1)
    private let cachedCTPacked = ManagedAtomic<UInt64>(0)
    private let clockUpdateQueue = DispatchQueue(label: "MPXPrime.RDSClockCache", qos: .utility)
    private var clockUpdateTimer: DispatchSourceTimer?

    private var sampleRate: Float
    private var carrierPhase: Float = 0.0
    private var carrierStep: Float = 0.0
    private var pilotPhaseForRDS: Float = 0.0
    private var pilotStepForRDS: Float = 0.0
    private var bitPhase: Float = 0.0
    private var differentialBit: Int = 0
    /// Pre-allocated 104-byte buffer (4 RDS blocks × 26 bits) reused
    /// for every `buildGroupBits` call. The audio thread's `dequeueBit`
    /// path consumes via `self.bitBuffer[i]` and refills via subscript
    /// assignment in `buildGroupBits` — Swift Array's CoW keeps storage
    /// allocation at zero in steady state, since the only reference to
    /// the underlying buffer is `self.bitBuffer` itself. External
    /// callers (tests) that retain the returned `[UInt8]` trigger CoW
    /// on the next refill, paying for one allocation per held reference
    /// — paid by the test, not the audio thread.
    private var bitBuffer: [UInt8] = Array(repeating: 0, count: 104)
    /// Start past the end so the first `dequeueBit` triggers a refill —
    /// avoids returning the zero-initialized buffer as 104 phantom bits
    /// before any group is actually built.
    private var bitBufferIndex: Int = 104

    private var scheduleIndex: Int = 0
    /// Pre-computed RDS group schedules — cached so the audio thread
    /// doesn't allocate a fresh `[RDSGroupSpec]` on every `nextGroupBits`
    /// call (~11×/sec). Rebuilt at init and on `applyRDSRuntimeConfig`
    /// when any of `rtMode2B` / `rtPlusEnabled` change.
    private var cachedAutoSchedule: [RDSGroupSpec] = []
    private var cachedStandardSchedule: [RDSGroupSpec] = []
    /// Flag set when the operator toggles TA. Per UECP §2.5.1.1 a TA
    /// edge must produce an immediate "own TA flag change" group ahead
    /// of the regular schedule so traffic-aware receivers see the flip
    /// within one group time. We force the next emitted group to be 0A
    /// (which carries TP/TA in block B) and clear the flag.
    private var forceNextGroupForTAEdge: Bool = false

    /// Monotonic elapsed-seconds clock for audio-thread elapsed-time
    /// math (PS/RT/PTYN/LPS sequence advance, applyRDSRuntimeConfig
    /// seq-start markers). `ProcessInfo.systemUptime` is real-time
    /// safe — it reads `mach_continuous_time` via the commpage, no
    /// syscall. `Date()` would also typically resolve via commpage on
    /// modern Apple platforms but takes a slow path under some
    /// configurations. Use this for elapsed math; use `Date()` only
    /// where wall-clock time-of-day is genuinely needed (CT cache
    /// refresh on the background queue, RT {time}/{date} macros).
    @inline(__always)
    private static func monotonicSeconds() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
    private var afPointer: Int = 0
    private var ctMinuteLock: Int = -1
    private var psSegment: Int = 0
    private var psFrameIndex: Int = 0
    private var psSeqIndex: Int = 0
    private var psSeqStart: Double = 0.0
    private var psSeqTransmits: Int = 0
    private var rtSegment: Int = 0
    private var rtFrameIndex: Int = 0
    private var rtSeqIndex: Int = 0
    private var rtSeqStart: Double = 0.0
    private var rtSeqTransmits: Int = 0
    private var rtABFlag: Int = 0
    private var rtABCycles: Int = 0
    private var lastManualRTBuffer: Int = -1
    private var ptynSegment: Int = 0
    private var ptynFrameIndex: Int = 0
    private var ptynSeqIndex: Int = 0
    private var ptynSeqStart: Double = 0.0
    private var ptynSeqTransmits: Int = 0
    private var lpsSegment: Int = 0
    private var lpsFrameIndex: Int = 0
    private var lpsSeqIndex: Int = 0
    private var lpsSeqStart: Double = 0.0
    private var lpsSeqTransmits: Int = 0
    private var rtPlusToggle: Int = 0
    private var rtPlusTags: [RTPlusTag] = []
    private var rtPlusSignature: String = ""
    private var rtDynamicSignature: String = ""
    // Cache of the last parsed dynamic RT sequence, to avoid re-running
    // parseTimedSequence on the audio thread every buildGroup2 call when the
    // RT text (with now-playing macros expanded) hasn't changed. Keyed by the
    // signature string plus the limit/centered values so mode changes still
    // invalidate the cache.
    private var rtDynamicSequenceCache: [TimedTextFrame] = []
    private var rtDynamicCacheLimit: Int = 0
    private var rtDynamicCacheCentered: Bool = false
    // Cheap-to-compute "should we bother rebuilding?" keys so the audio
    // thread can skip expandNowPlayingMacros (which does DateFormatter work
    // and multiple string replacements) when nothing relevant has changed.
    private var rtDynamicCacheRevision: UInt64 = UInt64.max
    private var rtDynamicCacheMinuteEpoch: Int64 = Int64.min
    private var rtDynamicCacheDayEpoch: Int64 = Int64.min

    private var biphaseKernel: [Float] = []
    private var gaussianKernel: [Float] = []
    private var shapingKernel: [Float] = []
    private var biphaseOverlapAdd: [Float] = []
    private var biphaseOverlapIndex: Int = 0
    private var shapingPeak: Float = 1.0

    // Live snapshot of the most recently transmitted RDS frame text per field.
    // Updated on the audio thread after each buildGroupX call; polled by the
    // UI for an accurate Monitoring view.
    //
    // Uses OSAllocatedUnfairLock (os_unfair_lock under the hood) — on macOS
    // this performs priority inheritance, so when the real-time audio thread
    // contends with the main thread (e.g. the UI pulling a snapshot during
    // heavy launch-time setup) the holder's priority is temporarily raised
    // and the audio thread is not stalled. NSLock does NOT do this and can
    // cause priority inversion → render deadline misses → ring overflow.
    private struct SnapshotState {
        var ps: String = ""
        var rt: String = ""
        var ptyn: String = ""
        var longPS: String = ""
    }
    private let snapshotLock = OSAllocatedUnfairLock<SnapshotState>(initialState: SnapshotState())

    struct LiveSnapshot {
        let ps: String
        let rt: String
        let ptyn: String
        let longPS: String
    }

    func currentLiveSnapshot() -> LiveSnapshot {
        snapshotLock.withLock { state in
            LiveSnapshot(ps: state.ps, rt: state.rt, ptyn: state.ptyn, longPS: state.longPS)
        }
    }

    private func writeSnapshot(ps: String? = nil, rt: String? = nil, ptyn: String? = nil, longPS: String? = nil) {
        snapshotLock.withLock { state in
            if let ps = ps { state.ps = ps }
            if let rt = rt { state.rt = rt }
            if let ptyn = ptyn { state.ptyn = ptyn }
            if let longPS = longPS { state.longPS = longPS }
        }
    }

    init(config: AppConfig, sampleRate: Float, nowPlayingState: NowPlayingState? = nil) {
        self.enabled = config.enRDS && (config.rdsLevel > 0.0)
        self.levelScale = clampf(Float(config.rdsLevel) / 75.0, 0.0, 0.25)
        self.piCode = Self.parseHexWord(config.rdsPI)
        self.pty = max(0, min(31, config.rdsPTY))
        self.tpFlag = config.rdsTP
        self.taFlag = config.rdsTA
        self.msFlag = config.rdsMS
        self.diStereoFlag = config.rdsDI_STEREO
        self.diHeadFlag = config.rdsDI_HEAD
        self.diCompFlag = config.rdsDI_COMP
        self.diDynFlag = config.rdsDI_DYN
        self.afEnabled = config.rdsEnableAF
        self.afMethod = config.rdsAFMethod.uppercased()
        self.afCodes = Self.parseAFList(config.rdsAFList)
        self.psCentered = config.rdsPSCentered
        self.psBanks = [config.rdsPSA, config.rdsPSB, config.rdsPSC, config.rdsPSD]
        self.psActiveBankIndex = Self.psBankIndex(config.rdsPSActiveBank)
        self.psFrameSeconds = max(0.1, config.rdsPSFrameSeconds)
        self.rtManualBuffers = config.rdsRTManualBuffers
        self.rtCycleAB = config.rdsRTCycleAB
        self.rtRawText = config.rdsRTText
        self.rtRawBuffers = [config.rdsRTA, config.rdsRTB, config.rdsRTC, config.rdsRTD]
        self.rtBuffers = rtRawBuffers.map { Self.sanitizeText($0, uppercase: false) }
        self.rtBufferEnabled = [
            config.rdsRTBufferAEnabled,
            config.rdsRTBufferBEnabled,
            config.rdsRTBufferCEnabled,
            config.rdsRTBufferDEnabled,
        ]
        self.rtCR = config.rdsRTCR
        self.rtCentered = config.rdsRTCentered
        self.rtMode2B = config.rdsRTMode.uppercased() == "2B"
        self.rtCycle = config.rdsRTCycle
        self.rtCycleTime = max(1.0, config.rdsRTCycleTime)
        self.rtActiveBuffer = max(0, min(3, config.rdsRTActiveBuffer))
        self.rtABCycleCount = max(1, config.rdsRTABCycleCount)
        self.rdsFreqHz = clampf(Float(config.rdsFreq), 1000.0, 120_000.0)
        self.gaussianEnabled = config.rdsGaussianEnabled
        self.gaussianBWHZ = clampf(Float(config.rdsGaussianBWHZ), 600.0, 6000.0)
        self.gaussianTaps = max(9, config.rdsGaussianTaps | 1)
        self.schedule = Self.parseGroupSequence(config.rdsGroupSequence)
        self.schedulerAuto = config.rdsSchedulerAuto
        self.schedulerStandard = config.rdsSchedulerStandard
        self.schedulerStandardLPS = config.rdsSchedulerStandardLPS
        let initialPSText = psBanks[psActiveBankIndex]
        self.psFrames = Self.parseTimedFrames(
            initialPSText, width: 8, uppercase: true, center: psCentered,
            allowScroll: true, defaultDuration: self.psFrameSeconds)
        self.psFrameBytes = psFrames.map(Self.rdsBytes)
        self.rtFrames = Self.parseTimedFrames(
            config.rdsRTText,
            width: rtMode2B ? 32 : 64,
            uppercase: false,
            center: rtCentered
        )
        self.psSequence = Self.parseTimedSequence(
            initialPSText, width: 8, uppercase: true, center: psCentered,
            allowScroll: true, defaultDuration: self.psFrameSeconds)
        self.rtSequence = Self.parseTimedSequence(
            config.rdsRTText,
            width: rtMode2B ? 32 : 64,
            uppercase: false,
            center: rtCentered
        )
        self.ptynEnabled = config.rdsEnablePTYN
        self.ptynCentered = config.rdsPTYNCentered
        self.ptynRawText = config.rdsPTYN
        self.ptynFrames = Self.parseTimedFrames(
            config.rdsPTYN, width: 8, uppercase: true, center: ptynCentered)
        self.ptynFrameBytes = ptynFrames.map(Self.rdsBytes)
        self.ptynSequence = Self.parseTimedSequence(
            config.rdsPTYN, width: 8, uppercase: true, center: ptynCentered)
        self.lpsEnabled = config.rdsEnableLPS
        self.lpsCentered = config.rdsLPSCentered
        self.lpsCR = config.rdsLPSCR
        self.lpsRawText = config.rdsLongPS32
        self.lpsFrames = Self.parseTimedFrames(
            config.rdsLongPS32, width: 32, uppercase: false, center: lpsCentered)
        self.lpsPreparedFrameBytes = lpsFrames.map {
            Self.rdsBytes(config.rdsLPSCR ? Self.prepareCRFrame($0, width: 32) : $0)
        }
        self.lpsSequence = Self.parseTimedSequence(
            config.rdsLongPS32, width: 32, uppercase: false, center: lpsCentered)
        self.rtPlusEnabled = config.rdsEnableRTPlus
        self.rtPlusFormatA = config.rdsRTPlusFormatA
        self.rtPlusFormatB = config.rdsRTPlusFormatB
        self.nowPlayingEnabled = config.rdsNowPlayingEnabled
        self.nowPlayingState = nowPlayingState
        self.enCT = config.rdsEnableCT
        self.enID = config.rdsEnableID
        self.eccCode = Self.parseHexByte(config.rdsECC)
        self.licCode = Self.parseHexByte(config.rdsLIC)
        self.tzOffset = config.rdsTZOffset
        self.sampleRate = max(8_000.0, sampleRate)
        let now = Self.monotonicSeconds()
        self.psSeqStart = now
        self.rtSeqStart = now
        self.ptynSeqStart = now
        self.lpsSeqStart = now
        updateDerivedRates()
        updateShapingFilters()
        startClockCacheIfNeeded()
        rebuildScheduleCaches()
    }

    deinit {
        clockUpdateTimer?.cancel()
    }

    func setSampleRate(_ newSampleRate: Float) {
        sampleRate = max(8_000.0, newSampleRate)
        updateDerivedRates()
        updateShapingFilters()
    }

    static func psBankIndex(_ name: String) -> Int {
        switch name.uppercased() {
        case "A": return 0
        case "B": return 1
        case "C": return 2
        case "D": return 3
        default:  return 0
        }
    }

    private func rebuildPSSequence() {
        let text = psBanks[psActiveBankIndex]
        psFrames = Self.parseTimedFrames(
            text, width: 8, uppercase: true, center: psCentered,
            allowScroll: true, defaultDuration: psFrameSeconds)
        psFrameBytes = psFrames.map(Self.rdsBytes)
        psSequence = Self.parseTimedSequence(
            text, width: 8, uppercase: true, center: psCentered,
            allowScroll: true, defaultDuration: psFrameSeconds)
        psSeqIndex = 0
        psSeqStart = Self.monotonicSeconds()
        psSeqTransmits = 0
        psSegment = 0
    }

    func applyRDSRuntimeConfig(_ config: MPXGenerator.RDSRuntimeConfig) {
        // Master enable + identification ---------------------------------
        let wasEnabled = enabled
        enabled = config.enabled
        if !wasEnabled && enabled {
            // Re-engage cleanly: reset bit phase + scheduling so the
            // first transmitted bits are aligned, not whatever was
            // sitting in the disabled state.
            bitPhase = 0.0
            bitBufferIndex = bitBuffer.count
            scheduleIndex = 0
        }

        piCode = config.pi
        pty = max(0, min(31, config.pty))
        eccCode = config.eccCode
        licCode = config.licCode

        // Flags ----------------------------------------------------------
        // Detect TA-edge before the assignment so we can schedule a
        // forced 0A. Per UECP §2.5.1.1, TA flag transitions trigger
        // immediate emission ahead of the regular group sequence.
        let previousTA = taFlag
        tpFlag = config.tp
        taFlag = config.ta
        if previousTA != taFlag {
            forceNextGroupForTAEdge = true
        }
        msFlag = config.ms
        diStereoFlag = config.diStereo
        diHeadFlag = config.diHead
        diCompFlag = config.diComp
        diDynFlag = config.diDyn

        // Alternative Frequencies ----------------------------------------
        afEnabled = config.afEnabled
        afCodes = config.afCodes
        afMethod = config.afMethod.uppercased()
        afPointer = 0

        // Clock ----------------------------------------------------------
        let ctWas = enCT
        let idWas = enID
        enCT = config.enableCT
        enID = config.enableID
        tzOffset = config.tzOffset
        // If CT or ID just turned on for the first time since init,
        // make sure the clock-cache timer is running and pre-populate
        // the cache so the next 4A/1A schedule entry has data ready.
        if (!ctWas && enCT) || (!idWas && enID) {
            startClockCacheIfNeeded()
        }

        // PS banks -------------------------------------------------------
        let previousBanks = psBanks
        let previousActive = psActiveBankIndex
        let previousCentered = psCentered
        let previousPSFrameSeconds = psFrameSeconds
        if !config.psBanks.isEmpty {
            psBanks = Array(config.psBanks.prefix(4))
                + Array(repeating: "", count: max(0, 4 - config.psBanks.count))
        }
        psActiveBankIndex = Self.psBankIndex(config.psActiveBank)
        psCentered = config.psCentered
        psFrameSeconds = max(0.1, config.psFrameSeconds)
        if psBanks != previousBanks
            || psActiveBankIndex != previousActive
            || psCentered != previousCentered
            || psFrameSeconds != previousPSFrameSeconds
        {
            rebuildPSSequence()
        }

        // PTYN -----------------------------------------------------------
        let ptynChanged =
            ptynEnabled != config.ptynEnabled
            || ptynCentered != config.ptynCentered
            || ptynRawText != config.ptynText
        ptynEnabled = config.ptynEnabled
        ptynCentered = config.ptynCentered
        ptynRawText = config.ptynText
        if ptynChanged {
            ptynFrames = Self.parseTimedFrames(
                config.ptynText, width: 8, uppercase: true, center: ptynCentered)
            ptynFrameBytes = ptynFrames.map(Self.rdsBytes)
            ptynSequence = Self.parseTimedSequence(
                config.ptynText, width: 8, uppercase: true, center: ptynCentered)
            ptynSeqIndex = 0
            ptynSegment = 0
            ptynFrameIndex = 0
            ptynSeqTransmits = 0
            ptynSeqStart = Self.monotonicSeconds()
        }

        // Long PS --------------------------------------------------------
        let lpsChanged =
            lpsEnabled != config.lpsEnabled
            || lpsCentered != config.lpsCentered
            || lpsCR != config.lpsCR
            || lpsRawText != config.longPSText
        lpsEnabled = config.lpsEnabled
        lpsCentered = config.lpsCentered
        lpsCR = config.lpsCR
        lpsRawText = config.longPSText
        if lpsChanged {
            lpsFrames = Self.parseTimedFrames(
                config.longPSText, width: 32, uppercase: false, center: lpsCentered)
            lpsPreparedFrameBytes = lpsFrames.map {
                Self.rdsBytes(lpsCR ? Self.prepareCRFrame($0, width: 32) : $0)
            }
            lpsSequence = Self.parseTimedSequence(
                config.longPSText, width: 32, uppercase: false, center: lpsCentered)
            lpsSeqStart = Self.monotonicSeconds()
        }

        // Radiotext ------------------------------------------------------
        rtRawText = config.rtText
        rtRawBuffers =
            Array(config.rtBuffers.prefix(4))
            + Array(repeating: "", count: max(0, 4 - config.rtBuffers.count))
        rtBufferEnabled =
            Array(config.rtBufferEnabled.prefix(4))
            + Array(repeating: false, count: max(0, 4 - config.rtBufferEnabled.count))
        let previousRTMode2B = rtMode2B
        let previousRTPlusEnabled = rtPlusEnabled
        rtCR = config.rtCR
        rtCentered = config.rtCentered
        rtMode2B = config.rtMode2B
        rtCycleTime = max(1.0, config.rtCycleTime)
        rtCycleAB = config.rtCycleAB
        rtABCycleCount = max(1, config.rtABCycleCount)
        rtPlusEnabled = config.rtPlusEnabled
        rtPlusFormatA = config.rtPlusFormatA
        rtPlusFormatB = config.rtPlusFormatB
        nowPlayingEnabled = config.nowPlayingEnabled

        // Scheduler ------------------------------------------------------
        let newSchedule = Self.parseGroupSequence(config.groupSequenceRaw)
        let scheduleChanged =
            newSchedule.count != schedule.count
            || zip(newSchedule, schedule).contains { $0.type != $1.type || $0.versionB != $1.versionB }
        let schedulerFlagsChanged =
            schedulerAuto != config.schedulerAuto
            || schedulerStandard != config.schedulerStandard
            || schedulerStandardLPS != config.schedulerStandardLPS
        schedule = newSchedule
        schedulerAuto = config.schedulerAuto
        schedulerStandard = config.schedulerStandard
        schedulerStandardLPS = config.schedulerStandardLPS

        if scheduleChanged || schedulerFlagsChanged {
            scheduleIndex = 0
        }

        // Rebuild RT-derived caches if mode flipped or RT+ toggled, or
        // if the schedule shape changed (different cached groups apply).
        if rtMode2B != previousRTMode2B
            || rtPlusEnabled != previousRTPlusEnabled
            || scheduleChanged || schedulerFlagsChanged
        {
            rebuildScheduleCaches()
        }

        let width = rtMode2B ? 32 : 64
        rtFrames = Self.parseTimedFrames(
            rtRawText,
            width: width,
            uppercase: false,
            center: rtCentered
        )
        rtSequence = Self.parseTimedSequence(
            rtRawText,
            width: width,
            uppercase: false,
            center: rtCentered
        )

        let now = Self.monotonicSeconds()
        rtSeqStart = now
        rtSeqIndex = 0
        rtSegment = 0
        rtSeqTransmits = 0
        rtABCycles = 0
        rtDynamicSignature = ""
        rtDynamicSequenceCache = []
        lastManualRTBuffer = -1
    }

    func nextSample() -> Float {
        guard enabled else { return 0.0 }

        let previousPhase = bitPhase
        var impulse: Float = 0.0
        bitPhase += Self.bitrate / sampleRate
        while bitPhase >= 1.0 {
            bitPhase -= 1.0
            let nextBit = dequeueBit()
            differentialBit ^= Int(nextBit)
            impulse += differentialBit == 0 ? -1.0 : 1.0
        }
        if previousPhase < 0.5, bitPhase >= 0.5 {
            impulse += differentialBit == 0 ? 1.0 : -1.0
        }

        let shaped = nextShapingSample(impulse: impulse)

        let carrier = sinf(carrierPhase)
        carrierPhase += carrierStep
        if carrierPhase >= twoPi {
            carrierPhase -= twoPi
        }
        let normalized = shaped / max(1e-6, shapingPeak)
        return normalized * carrier * levelScale
    }

    func nextSampleWithPilotLock() -> Float {
        guard enabled else { return 0.0 }

        // Phase is now set externally via updateRDSPilotPhase()
        // RDS subcarrier is 3x pilot frequency (57kHz = 3 * 19kHz)
        let rdsPhase = fmodf(3.0 * pilotPhaseForRDS, twoPi)

        let previousPhase = bitPhase
        var impulse: Float = 0.0
        bitPhase += Self.bitrate / sampleRate
        while bitPhase >= 1.0 {
            bitPhase -= 1.0
            let nextBit = dequeueBit()
            differentialBit ^= Int(nextBit)
            impulse += differentialBit == 0 ? -1.0 : 1.0
        }
        if previousPhase < 0.5, bitPhase >= 0.5 {
            impulse += differentialBit == 0 ? 1.0 : -1.0
        }

        let shaped = nextShapingSample(impulse: impulse)

        let carrier = sinf(rdsPhase)
        let normalized = shaped / max(1e-6, shapingPeak)
        return normalized * carrier * levelScale
    }

    private func updateDerivedRates() {
        carrierStep = twoPi * rdsFreqHz / sampleRate
        pilotStepForRDS = twoPi * 19_000.0 / sampleRate
    }

    func updateRDSPilotPhase(_ phase: Float) {
        pilotPhaseForRDS = phase
    }

    private func updateShapingFilters() {
        biphaseKernel = Self.biphaseShapingTaps(
            sampleRate: sampleRate, bitrate: Self.bitrate, tapCount: 301)
        if gaussianEnabled {
            gaussianKernel = Self.gaussianTaps(
                sampleRate: sampleRate, bandwidthHz: gaussianBWHZ, tapCount: gaussianTaps)
        } else {
            gaussianKernel = [1.0]
        }

        shapingKernel = Self.convolveKernels(biphaseKernel, gaussianKernel)
        if shapingKernel.isEmpty {
            shapingKernel = [1.0]
        }
        let olaSize = max(4096, shapingKernel.count * 8)
        biphaseOverlapAdd = Array(repeating: 0.0, count: olaSize)
        biphaseOverlapIndex = 0
        shapingPeak = estimateShapingPeak()
    }

    private func estimateShapingPeak() -> Float {
        let frames = 8192
        var peak: Float = 1e-6
        var testPhase: Float = 0.0
        var testBit: Int = 0
        var localOLA = Array(repeating: Float.zero, count: max(1024, shapingKernel.count * 6))
        var localIndex = 0
        for _ in 0..<frames {
            let previousPhase = testPhase
            var impulse: Float = 0.0
            testPhase += Self.bitrate / sampleRate
            while testPhase >= 1.0 {
                testPhase -= 1.0
                testBit ^= 1
                impulse += testBit == 0 ? -1.0 : 1.0
            }
            if previousPhase < 0.5, testPhase >= 0.5 {
                impulse += testBit == 0 ? 1.0 : -1.0
            }
            let shaped = Self.nextShapingSampleLocal(
                impulse: impulse,
                kernel: shapingKernel,
                overlapAdd: &localOLA,
                index: &localIndex
            )
            let a = fabsf(shaped)
            if a > peak {
                peak = a
            }
        }
        return max(peak, 1e-6)
    }

    private func nextShapingSample(impulse: Float) -> Float {
        Self.nextShapingSampleLocal(
            impulse: impulse,
            kernel: shapingKernel,
            overlapAdd: &biphaseOverlapAdd,
            index: &biphaseOverlapIndex
        )
    }

    private static func nextShapingSampleLocal(
        impulse: Float,
        kernel: [Float],
        overlapAdd: inout [Float],
        index: inout Int
    ) -> Float {
        guard !overlapAdd.isEmpty else { return 0.0 }
        let n = overlapAdd.count
        var idx = index
        let y = overlapAdd[idx]
        overlapAdd[idx] = 0.0

        if impulse != 0.0, !kernel.isEmpty {
            let scaledImpulse = impulse
            var tap = 0
            var pos = idx
            while tap < kernel.count, pos < n {
                overlapAdd[pos] += scaledImpulse * kernel[tap]
                tap += 1
                pos += 1
            }
            pos = 0
            while tap < kernel.count {
                overlapAdd[pos] += scaledImpulse * kernel[tap]
                tap += 1
                pos += 1
            }
        }

        idx += 1
        if idx >= n {
            idx = 0
        }
        index = idx
        return y
    }

    private static func biphaseShapingTaps(sampleRate: Float, bitrate: Float, tapCount: Int)
        -> [Float]
    {
        // Match Python path intent: firwin2-shaped EN50067 biphase impulse response.
        let count = max(9, tapCount | 1)
        let sr = max(8_000.0, sampleRate)
        let nyquist = sr * 0.5
        let td = 1.0 / max(1.0, bitrate)
        let fmax = max(1.0, min(nyquist, 2.0 * bitrate))
        let points = 128

        var freqs = Array(repeating: Float.zero, count: points + 1)
        var gains = Array(repeating: Float.zero, count: points + 1)
        for i in 0..<points {
            let ratio = Float(i) / Float(max(1, points - 1))
            let f = ratio * fmax
            freqs[i] = f
            gains[i] = cosf(Float.pi * f * td * 0.25)
        }
        freqs[points] = nyquist
        gains[points] = 0.0

        let mid = count / 2
        var taps = Array(repeating: Float.zero, count: count)
        for n in 0..<count {
            let m = Float(n - mid)
            var integral: Float = 0.0
            for k in 0..<points {
                let f0 = freqs[k]
                let f1 = freqs[k + 1]
                let g0 = gains[k]
                let g1 = gains[k + 1]
                let c0 = cosf(twoPi * f0 * m / sr)
                let c1 = cosf(twoPi * f1 * m / sr)
                integral += 0.5 * ((g0 * c0) + (g1 * c1)) * (f1 - f0)
            }
            var h = (2.0 / sr) * integral
            let window = 0.54 - (0.46 * cosf(twoPi * Float(n) / Float(max(1, count - 1))))
            h *= window
            taps[n] = h
        }

        var energy: Float = 0.0
        for t in taps {
            energy += t * t
        }
        if energy > 1e-12 {
            let inv = 1.0 / sqrtf(energy)
            for i in 0..<taps.count {
                taps[i] *= inv
            }
        }
        return taps
    }

    private static func gaussianTaps(sampleRate: Float, bandwidthHz: Float, tapCount: Int)
        -> [Float]
    {
        let count = max(9, tapCount | 1)
        let sr = max(8_000.0, sampleRate)
        let bw = max(100.0, bandwidthHz)
        let sigma = sr / (twoPi * bw)
        let half = count / 2
        var taps = Array(repeating: Float.zero, count: count)
        var sum: Float = 0.0
        for i in 0..<count {
            let x = Float(i - half)
            let v = expf(-0.5 * (x / max(1e-6, sigma)) * (x / max(1e-6, sigma)))
            taps[i] = v
            sum += v
        }
        if sum > 0 {
            for i in 0..<count {
                taps[i] /= sum
            }
        }
        return taps
    }

    private static func convolveKernels(_ a: [Float], _ b: [Float]) -> [Float] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var out = Array(repeating: Float.zero, count: a.count + b.count - 1)
        for i in 0..<a.count {
            let ai = a[i]
            if ai == 0 { continue }
            for j in 0..<b.count {
                out[i + j] += ai * b[j]
            }
        }
        return out
    }

    private func dequeueBit() -> UInt8 {
        if bitBufferIndex >= bitBuffer.count {
            bitBuffer = nextGroupBits()
            bitBufferIndex = 0
        }
        let bit = bitBuffer[bitBufferIndex]
        bitBufferIndex += 1
        return bit
    }

    func nextGroupBits() -> [UInt8] {
        if let ctBits = buildClockTimeGroupIfNeeded() {
            return ctBits
        }

        // TA-edge auto-injection (UECP §2.5.1.1). One forced 0A ahead
        // of the schedule, then the schedule resumes from where it was.
        // CT (above) takes priority — it's minute-aligned and cannot be
        // deferred.
        if forceNextGroupForTAEdge {
            forceNextGroupForTAEdge = false
            return buildGroup0(versionB: false)
        }

        let activeSchedule: [RDSGroupSpec]
        if schedulerStandard {
            activeSchedule = cachedStandardSchedule
        } else if schedulerAuto {
            activeSchedule = cachedAutoSchedule
        } else {
            activeSchedule = schedule
        }
        if activeSchedule.isEmpty {
            return buildGroup0(versionB: false)
        }

        let entry = activeSchedule[scheduleIndex % activeSchedule.count]
        scheduleIndex += 1
        switch entry.type {
        case 2:
            return buildGroup2(versionB: entry.versionB)
        case 3:
            return rtPlusEnabled ? buildGroup3A() : buildGroup0(versionB: false)
        case 4:
            return enCT
                ? (buildClockTimeGroupImmediate() ?? buildGroup0(versionB: false))
                : buildGroup0(versionB: false)
        case 10:
            return ptynEnabled ? buildGroup10A() : buildGroup0(versionB: false)
        case 11:
            // Skip 11A when no usable tags extracted from current RT — an
            // all-zero-content-type 11A reads as "RT+ withdrawn" on several
            // receivers (Pioneer / Sony car radios) and causes the RT+
            // display to flicker on / off. Substitute 0A so the group rate
            // stays constant; the next valid tag set will resume RT+.
            return (rtPlusEnabled && !rtPlusTags.isEmpty)
                ? buildGroup11A()
                : buildGroup0(versionB: false)
        case 15:
            return lpsEnabled ? buildGroup15A() : buildGroup0(versionB: false)
        case 1:
            return enID ? buildGroup1A() : buildGroup0(versionB: false)
        default:
            return buildGroup0(versionB: entry.versionB)
        }
    }

    func buildGroup0(versionB: Bool) -> [UInt8] {
        updatePSSequenceIfNeeded()
        let psFrameText = psSequence.isEmpty
            ? (psFrames.isEmpty ? String(repeating: " ", count: 8) : psFrames[psFrameIndex])
            : psSequence[psSeqIndex].text
        let bytes = psSequence.isEmpty ? psFrameBytes[psFrameIndex] : Self.rdsBytes(psFrameText)
        writeSnapshot(ps: psFrameText)
        let segment = psSegment % 4
        psSegment += 1
        if psSegment % 4 == 0 {
            psSeqTransmits += 1
        }
        let diBit = diBitForSegment(segment) ? 0x04 : 0x00
        let b2Tail = (taFlag ? 0x10 : 0) | (msFlag ? 0x08 : 0) | diBit | segment
        let b3Value: Int
        if versionB {
            b3Value = piCode
        } else if afEnabled, !afCodes.isEmpty {
            // Both Method A and Method B emit via the same dispatcher;
            // it switches internally on `afMethod`.
            b3Value = nextAFBlockValue()
        } else {
            b3Value = 0xE0E0
        }
        let idx = segment * 2
        let b4Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
        return buildGroupBits(
            groupType: 0,
            versionB: versionB,
            b2Tail: b2Tail,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    func buildGroup2(versionB: Bool) -> [UInt8] {
        let useVersionB = rtMode2B || versionB
        let limit = useVersionB ? 32 : 64
        let frameData = currentRTFrame(limit: limit)
        let frame = frameData.text
        let bytes = frameData.bytes
        writeSnapshot(rt: frame)
        let segment = rtSegment % 16
        rtSegment += 1
        if rtSegment % 16 == 0 {
            rtSeqTransmits += 1
        }
        let abFlag = rtABFlag & 1
        let b2Tail = ((abFlag & 1) << 4) | segment
        if rtPlusEnabled {
            let snapshot = currentNowPlayingSnapshot()
            let selectedFormat =
                (nowPlayingEnabled && snapshot.hasContent)
                ? ""
                : ((abFlag == 0) ? rtPlusFormatA : rtPlusFormatB)
            refreshRTPlusTagsIfNeeded(
                text: frame,
                format: selectedFormat,
                snapshot: snapshot
            )
        }
        if useVersionB {
            let idx = segment * 2
            let b4Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
            return buildGroupBits(
                groupType: 2,
                versionB: true,
                b2Tail: b2Tail,
                b3Value: piCode,
                b4Value: b4Value
            )
        }
        let idx = segment * 4
        let b3Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
        let b4Value = (Int(bytes[idx + 2]) << 8) | Int(bytes[idx + 3])
        return buildGroupBits(
            groupType: 2,
            versionB: false,
            b2Tail: b2Tail,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    private func buildGroup3A() -> [UInt8] {
        // ODA application identification for RT+ (AID 0x4BD7)
        return buildGroupBits(
            groupType: 3,
            versionB: false,
            b2Tail: 22,
            b3Value: 0x0000,
            b4Value: 0x4BD7
        )
    }

    func buildGroup10A() -> [UInt8] {
        updatePTYNSequenceIfNeeded()
        let ptynText = ptynSequence.isEmpty
            ? (ptynFrames.isEmpty ? String(repeating: " ", count: 8) : ptynFrames[ptynFrameIndex])
            : ptynSequence[ptynSeqIndex].text
        let bytes = ptynSequence.isEmpty ? ptynFrameBytes[ptynFrameIndex] : Self.rdsBytes(ptynText)
        writeSnapshot(ptyn: ptynText)
        let segment = ptynSegment % 2
        ptynSegment += 1
        if ptynSegment % 2 == 0 {
            ptynSeqTransmits += 1
        }
        let idx = segment * 4
        let b3Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
        let b4Value = (Int(bytes[idx + 2]) << 8) | Int(bytes[idx + 3])
        return buildGroupBits(
            groupType: 10,
            versionB: false,
            b2Tail: segment,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    private func buildGroup11A() -> [UInt8] {
        var t1Type = 0
        var t1Start = 0
        var t1Length = 0
        var t2Type = 0
        var t2Start = 0
        var t2Length = 0

        let orderedTags = Array(rtPlusTags.prefix(2))
        if orderedTags.count > 0 {
            t1Type = orderedTags[0].contentType
            t1Start = max(0, min(63, orderedTags[0].start))
            t1Length = max(0, min(63, orderedTags[0].length > 0 ? orderedTags[0].length - 1 : 0))
        }
        if orderedTags.count > 1 {
            t2Type = orderedTags[1].contentType
            t2Start = max(0, min(63, orderedTags[1].start))
            t2Length = max(0, min(31, orderedTags[1].length > 0 ? orderedTags[1].length - 1 : 0))
        }

        let b2Tail = ((rtPlusToggle & 1) << 4) | 0x08 | ((t1Type >> 3) & 0x07)
        let b3Value =
            ((t1Type & 0x07) << 13)
            | ((t1Start & 0x3F) << 7)
            | ((t1Length & 0x3F) << 1)
            | ((t2Type >> 5) & 0x01)
        let b4Value =
            ((t2Type & 0x1F) << 11)
            | ((t2Start & 0x3F) << 5)
            | (t2Length & 0x1F)
        return buildGroupBits(
            groupType: 11,
            versionB: false,
            b2Tail: b2Tail,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    func buildGroup15A() -> [UInt8] {
        updateLPSSequenceIfNeeded()
        let bytes: [UInt8]
        let lpsFrameText: String
        if lpsSequence.isEmpty {
            lpsFrameText = lpsFrames.isEmpty ? String(repeating: " ", count: 32) : lpsFrames[lpsFrameIndex]
            bytes = lpsPreparedFrameBytes[lpsFrameIndex]
        } else {
            let frame = lpsSequence[lpsSeqIndex].text
            lpsFrameText = frame
            let prepared = lpsCR ? Self.prepareCRFrame(frame, width: 32) : frame
            bytes = Self.rdsBytes(prepared)
        }
        writeSnapshot(longPS: lpsFrameText)
        let segment = lpsSegment % 8
        lpsSegment += 1
        if lpsSegment % 8 == 0 {
            lpsSeqTransmits += 1
        }
        let idx = segment * 4
        let b3Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
        let b4Value = (Int(bytes[idx + 2]) << 8) | Int(bytes[idx + 3])
        return buildGroupBits(
            groupType: 15,
            versionB: false,
            b2Tail: segment,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    private func buildGroup1A() -> [UInt8] {
        // Alternate ECC/LIC variants similar to Python scheduler behavior.
        let variants = [0, 3]
        let selector = cachedGroup1Variant.load(ordering: .acquiring) & 1
        let variant = variants[selector]
        let idValue = (variant == 0) ? eccCode : licCode
        let b3Value = ((variant & 0x0F) << 12) | (idValue & 0xFF)
        return buildGroupBits(
            groupType: 1,
            versionB: false,
            b2Tail: 0,
            b3Value: b3Value,
            b4Value: 0
        )
    }

    private func buildClockTimeGroupIfNeeded() -> [UInt8]? {
        guard enCT else { return nil }
        guard let cached = currentCachedClockTimeGroup() else { return nil }
        guard cached.minuteToken != ctMinuteLock else { return nil }
        ctMinuteLock = cached.minuteToken
        return buildGroupBits(
            groupType: 4,
            versionB: false,
            b2Tail: cached.b2Tail,
            b3Value: cached.b3Value,
            b4Value: cached.b4Value
        )
    }

    func buildClockTimeGroupImmediate() -> [UInt8]? {
        guard enCT else { return nil }
        guard let cached = currentCachedClockTimeGroup() else { return nil }
        return buildGroupBits(
            groupType: 4,
            versionB: false,
            b2Tail: cached.b2Tail,
            b3Value: cached.b3Value,
            b4Value: cached.b4Value
        )
    }

    private func makeClockTimeGroupPayload(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> (b2Tail: Int, b3Value: Int, b4Value: Int) {
        let mjd = Self.modifiedJulianDay(year: year, month: month, day: day)
        let tzHalfHours = max(0, min(31, Int(abs(tzOffset) * 2.0)))
        let tzSign = tzOffset < 0 ? 1 : 0
        let b2Tail = (mjd >> 15) & 0x3
        let b3Value = ((mjd & 0x7FFF) << 1) | ((hour >> 4) & 0x1)
        let b4Value =
            ((hour & 0x0F) << 12) | ((minute & 0x3F) << 6) | (tzSign << 5) | (tzHalfHours & 0x1F)
        return (b2Tail, b3Value, b4Value)
    }

    private func generateAutoSchedule() -> [RDSGroupSpec] {
        var seq: [RDSGroupSpec] = [
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
        ]
        if lpsEnabled {
            seq.append(RDSGroupSpec(type: 15, versionB: false))
            seq.append(RDSGroupSpec(type: 15, versionB: false))
        }
        if ptynEnabled {
            seq.append(RDSGroupSpec(type: 10, versionB: false))
            seq.append(RDSGroupSpec(type: 10, versionB: false))
        }
        if enID {
            seq.append(RDSGroupSpec(type: 1, versionB: false))
        }
        if rtPlusEnabled {
            // Emit 3A AID registration every cycle (was every other cycle).
            // Several receivers require seeing 3A within ~5-10 s of tune-in
            // to keep treating subsequent 11A groups as RT+; the prior
            // every-other-cycle cadence (~4.5 s) was on the edge and could
            // miss the receiver's window depending on tune-in timing.
            seq.append(RDSGroupSpec(type: 3, versionB: false))
            seq.append(RDSGroupSpec(type: 11, versionB: false))
        }
        return seq
    }

    /// Recompute both auto and standard schedule caches. Must be called
    /// from a non-audio context (init or live-apply path) — never from
    /// `nextGroupBits`. The cached arrays are read-only from the audio
    /// thread thereafter, so allocation pressure stays at zero in steady
    /// state.
    private func rebuildScheduleCaches() {
        cachedAutoSchedule = generateAutoSchedule()
        cachedStandardSchedule = generateStandardSchedule()
    }

    private func generateStandardSchedule() -> [RDSGroupSpec] {
        var seq: [RDSGroupSpec] = [
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
        ]
        if enID {
            seq.append(RDSGroupSpec(type: 1, versionB: false))
        }
        if ptynEnabled {
            seq.append(RDSGroupSpec(type: 10, versionB: false))
        }
        if rtPlusEnabled {
            seq.append(RDSGroupSpec(type: 3, versionB: false))
            seq.append(RDSGroupSpec(type: 11, versionB: false))
        }
        if schedulerStandardLPS && lpsEnabled {
            seq.append(RDSGroupSpec(type: 15, versionB: false))
        }
        return seq
    }

    private func startClockCacheIfNeeded() {
        guard enCT || enID else { return }
        refreshClockCache()
        if enCT, let cached = currentCachedClockTimeGroup() {
            // Prime the cache for immediate Group 4A requests without forcing a
            // once-per-minute CT burst right after startup.
            ctMinuteLock = cached.minuteToken
        }
        // Idempotent: if a timer is already running (e.g. from init or a
        // prior live-toggle), keep it instead of leaking a second one.
        guard clockUpdateTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: clockUpdateQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.refreshClockCache()
        }
        clockUpdateTimer = timer
        timer.resume()
    }

    private func refreshClockCache() {
        let now = Date()
        if enID {
            cachedGroup1Variant.store(
                Int(now.timeIntervalSince1970 / 2.0) & 1,
                ordering: .releasing
            )
        }
        guard enCT else { return }
        let comps = Self.gregorianCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: now
        )
        guard let year = comps.year,
            let month = comps.month,
            let day = comps.day,
            let hour = comps.hour,
            let minute = comps.minute
        else {
            return
        }
        let payload = makeClockTimeGroupPayload(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        let minuteToken = (((year * 100 + month) * 100 + day) * 100 + hour) * 100 + minute
        cachedCTPacked.store(
            packCachedClockTimeGroup(
                minuteToken: minuteToken,
                b2Tail: payload.b2Tail,
                b3Value: payload.b3Value,
                b4Value: payload.b4Value
            ),
            ordering: .releasing
        )
        cachedCTMinuteToken.store(minuteToken, ordering: .releasing)
    }

    private func currentCachedClockTimeGroup() -> CachedClockTimeGroup? {
        let minuteToken = cachedCTMinuteToken.load(ordering: .acquiring)
        guard minuteToken >= 0 else { return nil }
        let packed = cachedCTPacked.load(ordering: .acquiring)
        return unpackCachedClockTimeGroup(minuteToken: minuteToken, packed: packed)
    }

    private func packCachedClockTimeGroup(
        minuteToken: Int,
        b2Tail: Int,
        b3Value: Int,
        b4Value: Int
    ) -> UInt64 {
        _ = minuteToken
        return (UInt64(b2Tail & 0x1F) << 32)
            | (UInt64(b3Value & 0xFFFF) << 16)
            | UInt64(b4Value & 0xFFFF)
    }

    private func unpackCachedClockTimeGroup(minuteToken: Int, packed: UInt64) -> CachedClockTimeGroup {
        CachedClockTimeGroup(
            minuteToken: minuteToken,
            b2Tail: Int((packed >> 32) & 0x1F),
            b3Value: Int((packed >> 16) & 0xFFFF),
            b4Value: Int(packed & 0xFFFF)
        )
    }

    private func diBitForSegment(_ segment: Int) -> Bool {
        switch segment % 4 {
        case 0: return diDynFlag
        case 1: return diCompFlag
        case 2: return diHeadFlag
        default: return diStereoFlag
        }
    }

    private func nextAFBlockValue() -> Int {
        guard !afCodes.isEmpty else { return 0xE0E0 }
        if afMethod == "B" {
            return nextAFBlockValueMethodB()
        }
        return nextAFBlockValueMethodA()
    }

    /// Method A (EN 50067 §3.2.1.6.4 / IEC 62106-2 §7.5.2): flat AF
    /// list. First block carries `(count_code, freq[0])`; subsequent
    /// blocks carry pairs `(freq[N], freq[N+1])`. Filler 0xCD (205)
    /// pads odd-count tails. Receivers cannot tell Method A from B
    /// from a single 0A — they deduce by tuned-frequency repetition
    /// across many groups (Method B repeats the tuned frequency in
    /// every pair; Method A does not).
    private func nextAFBlockValueMethodA() -> Int {
        if afPointer == 0 {
            afPointer = 1
            let countCode = (224 + min(25, afCodes.count)) & 0xFF
            return (countCode << 8) | (afCodes[0] & 0xFF)
        }
        let f1 = afCodes[min(afPointer, afCodes.count - 1)] & 0xFF
        let f2: Int
        if afPointer + 1 < afCodes.count {
            f2 = afCodes[afPointer + 1] & 0xFF
            afPointer += 2
            if afPointer >= afCodes.count {
                afPointer = 0
            }
        } else {
            f2 = 205
            afPointer = 0
        }
        return (f1 << 8) | f2
    }

    /// Method B (EN 50067 §3.2.1.6.4 / IEC 62106-2 §7.5.3): tuned
    /// frequency repeated in every pair so receivers can group AF
    /// lists across regional variants. Convention: `afCodes[0]` is
    /// the tuned frequency; `afCodes[1...]` are alternatives. Each
    /// 0A block C carries:
    ///   1st block:    (count_code, tuned)
    ///   subsequent:   (tuned, alternative[N])
    /// Method B caps lists at 12 pairs (EN 50067 §3.2.1.6.4); we
    /// honour that by limiting the count code to 224+12=236 max
    /// when the operator configures more frequencies.
    /// Falls back to Method A semantics if afCodes has only the
    /// tuned frequency (no alternatives to pair with).
    private func nextAFBlockValueMethodB() -> Int {
        guard afCodes.count >= 2 else {
            return nextAFBlockValueMethodA()
        }
        let tuned = afCodes[0] & 0xFF
        let altCount = afCodes.count - 1
        if afPointer == 0 {
            afPointer = 1
            // Count = tuned + alternatives. EN 50067 caps Method B at
            // 12 pairs; clamp accordingly.
            let totalFreqs = min(13, 1 + altCount)
            let countCode = (224 + totalFreqs) & 0xFF
            return (countCode << 8) | tuned
        }
        let altIndex = afPointer
        let alt = afCodes[min(altIndex, afCodes.count - 1)] & 0xFF
        afPointer += 1
        if afPointer >= afCodes.count {
            afPointer = 0
        }
        return (tuned << 8) | alt
    }

    static func shouldAdvanceSequence(
        _ frame: TimedTextFrame, seqStart: Double, transmits: Int, now: Double
    ) -> Bool {
        if frame.transmits > 0 {
            return transmits >= frame.transmits
        }
        return (now - seqStart) >= frame.duration
    }

    private func updatePSSequenceIfNeeded() {
        guard !psSequence.isEmpty else { return }
        let now = Self.monotonicSeconds()
        let current = psSequence[min(psSeqIndex, psSequence.count - 1)]
        if Self.shouldAdvanceSequence(
            current, seqStart: psSeqStart, transmits: psSeqTransmits, now: now
        ) {
            psSeqIndex = (psSeqIndex + 1) % psSequence.count
            psSeqStart = now
            psSegment = 0
            psSeqTransmits = 0
        }
    }

    private func updatePTYNSequenceIfNeeded() {
        guard !ptynSequence.isEmpty else { return }
        let now = Self.monotonicSeconds()
        let current = ptynSequence[min(ptynSeqIndex, ptynSequence.count - 1)]
        if Self.shouldAdvanceSequence(
            current, seqStart: ptynSeqStart, transmits: ptynSeqTransmits, now: now
        ) {
            ptynSeqIndex = (ptynSeqIndex + 1) % ptynSequence.count
            ptynSeqStart = now
            ptynSegment = 0
            ptynSeqTransmits = 0
        }
    }

    private func updateLPSSequenceIfNeeded() {
        guard !lpsSequence.isEmpty else { return }
        let now = Self.monotonicSeconds()
        let current = lpsSequence[min(lpsSeqIndex, lpsSequence.count - 1)]
        if Self.shouldAdvanceSequence(
            current, seqStart: lpsSeqStart, transmits: lpsSeqTransmits, now: now
        ) {
            lpsSeqIndex = (lpsSeqIndex + 1) % lpsSequence.count
            lpsSeqStart = now
            lpsSegment = 0
            lpsSeqTransmits = 0
        }
    }

    private func enabledManualRTBuffers() -> [Int] {
        let enabled = rtBufferEnabled.enumerated().compactMap { index, isEnabled in
            let hasText = !rtRawBuffers[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (isEnabled && hasText) ? index : nil
        }
        return enabled
    }

    private func currentManualRTFrame(limit: Int, snapshot: NowPlayingSnapshot)
        -> (index: Int, text: String, bytes: [UInt8])
    {
        let enabledBuffers = enabledManualRTBuffers()
        guard !enabledBuffers.isEmpty else {
            let frame = Self.prepareRTFrame("", width: limit, centered: rtCentered, appendCR: rtCR)
            return (0, frame, Self.rdsBytes(frame))
        }

        var sequence: [TimedTextFrame] = []
        for bufferIndex in enabledBuffers {
            let raw = rtRawBuffers[bufferIndex]
            let expanded =
                nowPlayingEnabled ? Self.expandNowPlayingMacros(raw, snapshot: snapshot) : raw
            sequence.append(
                contentsOf: Self.parseRTBufferSequence(
                    expanded,
                    width: limit,
                    center: rtCentered,
                    defaultDuration: max(1.0, rtCycleTime)
                )
            )
        }

        guard !sequence.isEmpty else {
            let frame = Self.prepareRTFrame("", width: limit, centered: rtCentered, appendCR: rtCR)
            return (0, frame, Self.rdsBytes(frame))
        }

        if sequence.count == 1 {
            let prepared = Self.prepareRTFrame(
                sequence[0].text,
                width: limit,
                centered: rtCentered,
                appendCR: rtCR
            )
            return (0, prepared, Self.rdsBytes(prepared))
        }

        let total = sequence.reduce(0.0) { $0 + max(0.1, $1.duration) }
        let elapsed = (Self.monotonicSeconds() - rtSeqStart).truncatingRemainder(
            dividingBy: max(0.1, total)
        )
        var acc = 0.0
        for (index, frame) in sequence.enumerated() {
            acc += max(0.1, frame.duration)
            if elapsed <= acc {
                let prepared = Self.prepareRTFrame(
                    frame.text,
                    width: limit,
                    centered: rtCentered,
                    appendCR: rtCR
                )
                return (index, prepared, Self.rdsBytes(prepared))
            }
        }

        let prepared = Self.prepareRTFrame(
            sequence[sequence.count - 1].text,
            width: limit,
            centered: rtCentered,
            appendCR: rtCR
        )
        return (sequence.count - 1, prepared, Self.rdsBytes(prepared))
    }

    private func currentRTFrame(limit: Int) -> (text: String, bytes: [UInt8]) {
        let nowPlayingSnapshot = currentNowPlayingSnapshot()
        if !enabledManualRTBuffers().isEmpty {
            let manual = currentManualRTFrame(limit: limit, snapshot: nowPlayingSnapshot)
            if manual.index != lastManualRTBuffer {
                rtSegment = 0
                rtSeqTransmits = 0
                rtABCycles = 0
                if lastManualRTBuffer >= 0 && !rtCycleAB {
                    rtABFlag ^= 1
                }
                lastManualRTBuffer = manual.index
            }
            return (manual.text, manual.bytes)
        }

        if nowPlayingEnabled {
            // Fast-path cache: skip macro expansion and parseTimedSequence
            // unless one of the inputs that could change the result has
            // actually changed. We're called ~6x/sec on the audio thread, so
            // avoiding DateFormatter + regex + string replacement when there's
            // nothing to do is critical.
            let now = Date()
            let nowEpoch = Int64(now.timeIntervalSince1970)
            let minuteEpoch = nowEpoch / 60
            let dayEpoch = nowEpoch / 86_400
            let containsTimeMacro = rtRawText.contains("{time}")
            let containsDateMacro = rtRawText.contains("{date}")
            let minuteChanged = containsTimeMacro && minuteEpoch != rtDynamicCacheMinuteEpoch
            let dayChanged = containsDateMacro && dayEpoch != rtDynamicCacheDayEpoch
            let revisionChanged = nowPlayingSnapshot.revision != rtDynamicCacheRevision
            let modeChanged = limit != rtDynamicCacheLimit || rtCentered != rtDynamicCacheCentered
            let cacheCold = rtDynamicSequenceCache.isEmpty

            if revisionChanged || minuteChanged || dayChanged || modeChanged || cacheCold {
                let resolvedRaw = Self.expandNowPlayingMacros(rtRawText, snapshot: nowPlayingSnapshot)
                let signature = "\(resolvedRaw)|\(nowPlayingSnapshot.revision)"
                if signature != rtDynamicSignature {
                    rtSegment = 0
                    rtSeqTransmits = 0
                    if !rtCycleAB {
                        rtABFlag ^= 1
                    }
                }
                rtDynamicSignature = signature
                rtDynamicCacheLimit = limit
                rtDynamicCacheCentered = rtCentered
                rtDynamicCacheRevision = nowPlayingSnapshot.revision
                rtDynamicCacheMinuteEpoch = minuteEpoch
                rtDynamicCacheDayEpoch = dayEpoch
                rtDynamicSequenceCache = Self.parseTimedSequence(
                    resolvedRaw,
                    width: limit,
                    uppercase: false,
                    center: rtCentered
                )
            }
            let dynamicSequence = rtDynamicSequenceCache
            guard !dynamicSequence.isEmpty else {
                let frame = Self.prepareRTFrame("", width: limit, centered: rtCentered, appendCR: rtCR)
                return (frame, Self.rdsBytes(frame))
            }

            let seqTime = now.timeIntervalSinceReferenceDate
            let current = dynamicSequence[min(rtSeqIndex, dynamicSequence.count - 1)]
            if Self.shouldAdvanceSequence(
                current, seqStart: rtSeqStart, transmits: rtSeqTransmits, now: seqTime
            ) {
                let prev = rtSeqIndex
                rtSeqIndex = (rtSeqIndex + 1) % dynamicSequence.count
                rtSeqStart = seqTime
                rtSegment = 0
                rtSeqTransmits = 0
                if !rtCycleAB && rtSeqIndex != prev {
                    rtABFlag ^= 1
                }
            }

            if rtCycleAB, rtSegment > 0, (rtSegment % 16) == 0 {
                rtABCycles += 1
                if rtABCycles >= rtABCycleCount {
                    rtABFlag ^= 1
                    rtABCycles = 0
                }
            }

            let frame = dynamicSequence[min(rtSeqIndex, dynamicSequence.count - 1)].text
            let prepared = Self.prepareRTFrame(frame, width: limit, centered: rtCentered, appendCR: rtCR)
            return (prepared, Self.rdsBytes(prepared))
        }

        guard !rtSequence.isEmpty else {
            let frame = Self.prepareRTFrame(
                rtFrames[rtFrameIndex], width: limit, centered: rtCentered, appendCR: rtCR)
            return (frame, Self.rdsBytes(frame))
        }

        let now = Self.monotonicSeconds()
        let current = rtSequence[min(rtSeqIndex, rtSequence.count - 1)]
        if Self.shouldAdvanceSequence(
            current, seqStart: rtSeqStart, transmits: rtSeqTransmits, now: now
        ) {
            let prev = rtSeqIndex
            rtSeqIndex = (rtSeqIndex + 1) % rtSequence.count
            rtSeqStart = now
            rtSegment = 0
            rtSeqTransmits = 0
            if !rtCycleAB && rtSeqIndex != prev {
                rtABFlag ^= 1
            }
        }

        if rtCycleAB, rtSegment > 0, (rtSegment % 16) == 0 {
            rtABCycles += 1
            if rtABCycles >= rtABCycleCount {
                rtABFlag ^= 1
                rtABCycles = 0
            }
        }

        let frame = rtSequence[min(rtSeqIndex, rtSequence.count - 1)].text
        let prepared = Self.prepareRTFrame(frame, width: limit, centered: rtCentered, appendCR: rtCR)
        return (prepared, Self.rdsBytes(prepared))
    }

    private func currentNowPlayingSnapshot() -> NowPlayingSnapshot {
        guard nowPlayingEnabled, let nowPlayingState else { return .empty }
        return nowPlayingState.currentSnapshot()
    }

    private static func rdsBytes(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D, 0x20...0x7E:
                out.append(UInt8(scalar.value))
            default:
                if let mapped = rdsDirectByteMap[scalar.value] {
                    out.append(mapped)
                } else {
                    out.append(UInt8(ascii: "?"))
                }
            }
        }
        return out
    }

    private func buildGroupBits(
        groupType: Int,
        versionB: Bool,
        b2Tail: Int,
        b3Value: Int,
        b4Value: Int
    ) -> [UInt8] {
        let b1Data = piCode & 0xFFFF
        let b2Data =
            ((groupType & 0x0F) << 12)
            | ((versionB ? 1 : 0) << 11)
            | ((tpFlag ? 1 : 0) << 10)
            | ((pty & 0x1F) << 5)
            | (b2Tail & 0x1F)
        let b3Offset = versionB ? Self.offsetCp : Self.offsetC
        let block1 = Self.withCheckword(word: b1Data, offset: Self.offsetA)
        let block2 = Self.withCheckword(word: b2Data, offset: Self.offsetB)
        let block3 = Self.withCheckword(word: b3Value & 0xFFFF, offset: b3Offset)
        let block4 = Self.withCheckword(word: b4Value & 0xFFFF, offset: Self.offsetD)

        // Subscript-assign into the pre-allocated 104-byte bitBuffer.
        // Avoids the per-call [UInt8] allocation (~11x/sec on the audio
        // thread) and the inner 4-element [block1..block4] array
        // allocation. Unrolled four block writes — each writes 26 bits
        // MSB-first starting at offsets 0, 26, 52, 78.
        Self.writeBlockBits(block1, into: &bitBuffer, atOffset: 0)
        Self.writeBlockBits(block2, into: &bitBuffer, atOffset: 26)
        Self.writeBlockBits(block3, into: &bitBuffer, atOffset: 52)
        Self.writeBlockBits(block4, into: &bitBuffer, atOffset: 78)
        return bitBuffer
    }

    @inline(__always)
    private static func writeBlockBits(_ block: Int, into out: inout [UInt8], atOffset offset: Int) {
        for i in 0..<26 {
            out[offset + i] = UInt8((block >> (25 - i)) & 1)
        }
    }

    private static func withCheckword(word: Int, offset: Int) -> Int {
        let checkword = crc(word: word, offset: offset)
        return ((word & 0xFFFF) << 10) | (checkword & 0x03FF)
    }

    private static func crc(word: Int, offset: Int) -> Int {
        var reg = (word & 0xFFFF) << 10
        for _ in 0..<16 {
            if ((reg >> 25) & 1) == 1 {
                reg ^= (crcPoly << 15)
            }
            reg = (reg << 1) & 0x03FF_FFFF
        }
        return ((reg >> 16) & 0x03FF) ^ offset
    }

    static func parseHexWord(_ text: String) -> Int {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleaned = upper.filter { ch in
            switch ch {
            case "0"..."9", "A"..."F":
                return true
            default:
                return false
            }
        }
        if cleaned.isEmpty {
            return 0
        }
        if let parsed = Int(cleaned, radix: 16) {
            return parsed & 0xFFFF
        }
        return 0
    }

    private static func parseGroupSequence(_ raw: String) -> [RDSGroupSpec] {
        let tokens =
            raw
            .uppercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var out: [RDSGroupSpec] = []
        for token in tokens {
            guard !token.isEmpty else { continue }
            var digits = ""
            var suffix = ""
            for scalar in token.unicodeScalars {
                if scalar.value >= 48, scalar.value <= 57 {
                    digits.append(Character(scalar))
                } else {
                    suffix.append(Character(scalar))
                }
            }
            guard let groupType = Int(digits) else { continue }
            let versionB = (groupType == 0 || groupType == 2) && suffix == "B"
            if groupType == 0 || groupType == 1 || groupType == 2 || groupType == 3
                || groupType == 4
                || groupType == 10 || groupType == 11 || groupType == 15
            {
                out.append(RDSGroupSpec(type: groupType, versionB: versionB))
            }
        }
        if out.isEmpty {
            return [
                RDSGroupSpec(type: 0, versionB: false),
                RDSGroupSpec(type: 0, versionB: false),
                RDSGroupSpec(type: 2, versionB: false),
                RDSGroupSpec(type: 0, versionB: false),
            ]
        }
        return out
    }

    private func refreshRTPlusTagsIfNeeded(
        text: String,
        format: String,
        snapshot: NowPlayingSnapshot
    ) {
        let signature =
            text + "|" + format + "|" + snapshot.display + "|" + snapshot.artist + "|" + snapshot.title
        if signature == rtPlusSignature {
            return
        }
        rtPlusSignature = signature
        rtPlusToggle ^= 1
        rtPlusTags = Self.parseRTPlusTags(text: text, format: format, snapshot: snapshot)
    }

    static func parseTimedFrames(
        _ raw: String,
        width: Int,
        uppercase: Bool,
        center: Bool,
        allowScroll: Bool = false,
        defaultDuration: Double = 2.5
    ) -> [String] {
        return parseTimedSequence(
            raw, width: width, uppercase: uppercase, center: center,
            allowScroll: allowScroll, defaultDuration: defaultDuration
        ).map(\.text)
    }

    static func parseRTBufferSequence(
        _ raw: String,
        width: Int,
        center: Bool,
        defaultDuration: Double
    ) -> [TimedTextFrame] {
        let sequence = parseTimedSequence(raw, width: width, uppercase: false, center: center)
        guard !containsTimedCommand(raw) else {
            // Manual RT buffers cycle by wall-clock elapsed time across the
            // whole sequence (see currentManualRTFrame). Normalize any
            // transmit-count frames to the configured cycle time so the
            // duration-sum model stays valid.
            let fallback = max(0.1, defaultDuration)
            return sequence.map { frame in
                if frame.transmits > 0 {
                    return TimedTextFrame(duration: fallback, text: frame.text)
                }
                return frame
            }
        }
        let duration = max(0.1, defaultDuration)
        return sequence.map { TimedTextFrame(duration: duration, text: $0.text) }
    }

    static func containsTimedCommand(_ raw: String) -> Bool {
        RDSTextParser.containsTimedCommand(raw)
    }

    static func parseTimedSequence(
        _ raw: String,
        width: Int,
        uppercase: Bool,
        center: Bool,
        allowScroll: Bool = false,
        defaultDuration: Double = 2.5
    ) -> [TimedTextFrame] {
        let resolved = resolveTextMarkers(raw) ?? raw
        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [TimedTextFrame(duration: 10.0, text: String(repeating: " ", count: width))]
        }

        // Apply Stereotool escape handling: \\< \\> \\| \\: \\/ \\\\ become
        // private-use sentinels so they survive separator splitting; they
        // are decoded back to literals immediately before sanitize/chunk.
        let encoded = RDSTextParser.encodeEscapes(trimmed)
        // || word-wrap toggle is accepted but a no-op (word-wrap is always on).
        let stripped = RDSTextParser.stripWrapMarkers(encoded)

        var out: [TimedTextFrame] = []

        func emit(
            timing: RDSTextTiming,
            body: String,
            fallbackDuration: Double
        ) {
            // Scroll detection runs on the still-encoded body so escaped
            // `\<` and `\>` (now private-use sentinels) do NOT re-trigger
            // scroll. Decode only after we know this isn't a scroll spec.
            let trimmedEncoded = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if allowScroll, let scroll = RDSTextParser.parseScrollMarker(trimmedEncoded) {
                let decodedScrollText = RDSTextParser.decodeEscapes(scroll.text)
                let decodedSpec = RDSScrollSpec(
                    text: decodedScrollText,
                    direction: scroll.direction,
                    speed: scroll.speed
                )
                let windows = RDSTextParser.scrollWindows(decodedSpec, width: width)
                for window in windows {
                    let sanitized = sanitizeText(window, uppercase: uppercase)
                    let padded = Self.padToWidth(sanitized, width: width, center: false)
                    out.append(TimedTextFrame(transmits: 1, text: padded))
                }
                return
            }
            let decoded = RDSTextParser.decodeEscapes(trimmedEncoded)
            let chunks = splitAndPad(decoded, width: width, uppercase: uppercase, center: center)
            let frames: [String] = chunks.isEmpty
                ? [String(repeating: " ", count: width)]
                : chunks
            switch timing {
            case .seconds(let d):
                let duration = d > 0 ? d : fallbackDuration
                for chunk in frames {
                    out.append(TimedTextFrame(duration: duration, text: chunk))
                }
            case .transmits(let n):
                for chunk in frames {
                    out.append(TimedTextFrame(transmits: n, text: chunk))
                }
            }
        }

        let startsTimed = RDSTextParser.startsWithTimingPrefix(stripped)

        if startsTimed {
            let slashParts = RDSTextParser.splitTopLevel(stripped)
                .filter { !$0.isEmpty }
            if slashParts.count > 1 {
                for part in slashParts {
                    let (timing, body) = RDSTextParser.parseTimingPrefix(
                        part, defaultDuration: defaultDuration)
                    emit(timing: timing, body: body, fallbackDuration: defaultDuration)
                }
            } else {
                // Single top-level segment that may contain inline
                // `1s:A 2t:B` whitespace-separated timed tokens.
                let inline = RDSTextParser.extractInlineSegments(
                    stripped, defaultDuration: defaultDuration)
                if inline.count > 1 {
                    for seg in inline {
                        emit(timing: seg.timing, body: seg.body, fallbackDuration: defaultDuration)
                    }
                } else {
                    let part = slashParts.first ?? stripped
                    let (timing, body) = RDSTextParser.parseTimingPrefix(
                        part, defaultDuration: defaultDuration)
                    emit(timing: timing, body: body, fallbackDuration: defaultDuration)
                }
            }
        } else {
            // No timing prefix — treat the whole thing as one body. Untimed
            // single-chunk content holds for 10s; untimed multi-chunk content
            // rotates at the configured default duration per chunk.
            let trimmedEncoded = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedEncoded.isEmpty {
                return [TimedTextFrame(duration: 10.0, text: String(repeating: " ", count: width))]
            }
            if allowScroll, let scroll = RDSTextParser.parseScrollMarker(trimmedEncoded) {
                let decodedScrollText = RDSTextParser.decodeEscapes(scroll.text)
                let decodedSpec = RDSScrollSpec(
                    text: decodedScrollText,
                    direction: scroll.direction,
                    speed: scroll.speed
                )
                let windows = RDSTextParser.scrollWindows(decodedSpec, width: width)
                for window in windows {
                    let sanitized = sanitizeText(window, uppercase: uppercase)
                    let padded = Self.padToWidth(sanitized, width: width, center: false)
                    out.append(TimedTextFrame(transmits: 1, text: padded))
                }
            } else {
                let decoded = RDSTextParser.decodeEscapes(trimmedEncoded)
                let chunks = splitAndPad(decoded, width: width, uppercase: uppercase, center: center)
                if chunks.count <= 1 {
                    let single = chunks.first ?? String(repeating: " ", count: width)
                    out.append(TimedTextFrame(duration: 10.0, text: single))
                } else {
                    for chunk in chunks {
                        out.append(TimedTextFrame(duration: defaultDuration, text: chunk))
                    }
                }
            }
        }

        if out.isEmpty {
            return [TimedTextFrame(duration: 10.0, text: String(repeating: " ", count: width))]
        }
        return out
    }

    private static func padToWidth(_ text: String, width: Int, center: Bool) -> String {
        let count = text.count
        if count >= width { return String(text.prefix(width)) }
        let pad = width - count
        if center {
            let left = pad / 2
            let right = pad - left
            return String(repeating: " ", count: left) + text
                + String(repeating: " ", count: right)
        }
        return text + String(repeating: " ", count: pad)
    }

    private static func splitAndPad(_ raw: String, width: Int, uppercase: Bool, center: Bool)
        -> [String]
    {
        let normalized = sanitizeText(raw, uppercase: uppercase)
        let words = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.isEmpty {
            return [String(repeating: " ", count: width)]
        }
        var out: [String] = []
        var current = ""

        func pad(_ value: String) -> String {
            let clipped = value.count <= width ? value : String(value.prefix(width))
            if clipped.count >= width {
                return clipped
            }
            let padding = width - clipped.count
            if center {
                let left = padding / 2
                let right = padding - left
                return String(repeating: " ", count: left) + clipped
                    + String(repeating: " ", count: right)
            }
            return clipped + String(repeating: " ", count: padding)
        }

        func chunkWord(_ word: String) -> [String] {
            guard word.count > width else { return [word] }
            let chars = Array(word)
            var chunks: [String] = []
            var idx = 0
            while idx < chars.count {
                let end = min(chars.count, idx + width)
                chunks.append(String(chars[idx..<end]))
                idx = end
            }
            return chunks
        }

        for word in words {
            if word.count > width {
                if !current.isEmpty {
                    out.append(pad(current))
                    current = ""
                }
                let chunks = chunkWord(word)
                if chunks.count > 1 {
                    for chunk in chunks.dropLast() {
                        out.append(pad(chunk))
                    }
                }
                current = chunks.last ?? ""
                continue
            }
            let test = current.isEmpty ? word : "\(current) \(word)"
            if test.count <= width {
                current = test
            } else {
                if !current.isEmpty {
                    out.append(pad(current))
                }
                current = word
            }
        }
        if !current.isEmpty {
            out.append(pad(current))
        }
        if out.isEmpty {
            out.append(String(repeating: " ", count: width))
        }
        return out
    }

    private static let rdsDirectByteMap: [UInt32: UInt8] = [
        0x00D8: 0xE7,
        0x00F8: 0xF7,
    ]

    private static let rdsTransliterationMap: [UInt32: String] = [
        0x00C9: "E", 0x00C8: "E", 0x00CA: "E", 0x00CB: "E",
        0x00E9: "e", 0x00E8: "e", 0x00EA: "e", 0x00EB: "e",
        0x00C1: "A", 0x00C0: "A", 0x00C2: "A", 0x00C4: "A", 0x00C5: "A",
        0x00E1: "a", 0x00E0: "a", 0x00E2: "a", 0x00E4: "a", 0x00E5: "a",
        0x00CD: "I", 0x00CC: "I", 0x00CE: "I", 0x00CF: "I",
        0x00ED: "i", 0x00EC: "i", 0x00EE: "i", 0x00EF: "i",
        0x00D3: "O", 0x00D2: "O", 0x00D4: "O", 0x00D6: "O",
        0x00F3: "o", 0x00F2: "o", 0x00F4: "o", 0x00F6: "o",
        0x00DA: "U", 0x00D9: "U", 0x00DB: "U", 0x00DC: "U",
        0x00FA: "u", 0x00F9: "u", 0x00FB: "u", 0x00FC: "u",
        0x00C7: "C", 0x00E7: "c",
        0x00D1: "N", 0x00F1: "n",
        0x00C6: "AE", 0x00E6: "ae",
        0x0152: "OE", 0x0153: "oe",
        0x00DF: "ss",
        0x20AC: "E",
        0x00B0: " ", 0x2122: " ", 0x00AE: " ",
    ]

    private static func resolveTextMarkers(_ text: String) -> String? {
        guard text.contains("\\") else { return text }
        var failed = false
        var resolved = text
        // \R and \F load a file and force uppercase. Stereotool distinguishes
        // "raw" (\R/\r) from "formatted" (\F/\f) file loads; we treat the
        // formatted variants as aliases since loaded content re-enters the
        // parser and inherits all markers that way.
        resolved = replaceMarkers(in: resolved, pattern: #"\\[RF]\"([^\"]+)\""#) { path in
            guard let loaded = loadTextFromFile(path) else {
                failed = true
                return ""
            }
            return cleanMarkerSpaces(transliterateRDSText(loaded)).uppercased()
        }
        resolved = replaceMarkers(in: resolved, pattern: #"\\[rf]\"([^\"]+)\""#) { path in
            guard let loaded = loadTextFromFile(path) else {
                failed = true
                return ""
            }
            return cleanMarkerSpaces(transliterateRDSText(loaded))
        }
        resolved = replaceMarkers(in: resolved, pattern: #"\\w\"([^\"]+)\""#) { source in
            guard let loaded = loadTextFromURL(source) else {
                failed = true
                return ""
            }
            return cleanMarkerSpaces(transliterateRDSText(loaded))
        }
        return failed ? nil : resolved
    }

    private static func replaceMarkers(
        in source: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return source
        }
        let ns = source as NSString
        let matches = regex.matches(
            in: source, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            return source
        }
        var out = source
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let wholeRange = match.range(at: 0)
            let capRange = match.range(at: 1)
            let token = ns.substring(with: capRange)
            let replacement = transform(token)
            if let r = Range(wholeRange, in: out) {
                out.replaceSubrange(r, with: replacement)
            }
        }
        return out
    }

    private static func loadTextFromFile(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func loadTextFromURL(_ source: String) -> String? {
        guard let url = URL(string: source) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        let semaphore = DispatchSemaphore(value: 0)
        final class PayloadBox: @unchecked Sendable {
            var value: String?
        }
        let box = PayloadBox()
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data else { return }
            box.value = String(data: data, encoding: .utf8)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2.5)
        task.cancel()
        return box.value
    }

    private static func cleanMarkerSpaces(_ text: String) -> String {
        return text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(
            of: "\n", with: " ")
    }

    private static func transliterateRDSText(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0D || (scalar.value >= 0x20 && scalar.value <= 0x7E) {
                out.append(Character(scalar))
            } else if rdsDirectByteMap[scalar.value] != nil {
                out.append(Character(scalar))
            } else if let mapped = rdsTransliterationMap[scalar.value] {
                out += mapped
            } else {
                let folded = String(scalar).folding(
                    options: [.diacriticInsensitive, .widthInsensitive],
                    locale: .current
                )
                var appended = false
                for foldedScalar in folded.unicodeScalars {
                    if foldedScalar.value == 0x0D
                        || (foldedScalar.value >= 0x20 && foldedScalar.value <= 0x7E)
                    {
                        out.append(Character(foldedScalar))
                        appended = true
                    }
                }
                if !appended {
                    out += "?"
                }
            }
        }
        return out
    }

    private static func sanitizeText(_ raw: String, uppercase: Bool) -> String {
        let transliterated = transliterateRDSText(raw)
        let mapped = transliterated.unicodeScalars.map { scalar -> Character in
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                return Character(scalar)
            }
            return " "
        }
        let base = String(mapped)
        if uppercase {
            return base.uppercased()
        }
        return base
    }

    private static func prepareRTFrame(_ raw: String, width: Int, centered: Bool, appendCR: Bool)
        -> String
    {
        let sanitized = sanitizeText(raw, uppercase: false)
        let limited = String(sanitized.prefix(width))
        if appendCR {
            let trimmed = limited.trimmingCharacters(in: .whitespacesAndNewlines)
            let withCR = trimmed + "\r"
            if withCR.count >= width {
                return String(withCR.prefix(width))
            }
            return withCR + String(repeating: " ", count: width - withCR.count)
        }
        if centered, limited.count < width {
            let total = width - limited.count
            let left = total / 2
            let right = total - left
            return String(repeating: " ", count: left) + limited
                + String(repeating: " ", count: right)
        }
        if limited.count < width {
            return limited + String(repeating: " ", count: width - limited.count)
        }
        return limited
    }

    private static func prepareCRFrame(_ raw: String, width: Int) -> String {
        let sanitized = sanitizeText(raw, uppercase: false)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        let withCR = trimmed + "\r"
        if withCR.count >= width {
            return String(withCR.prefix(width))
        }
        return withCR + String(repeating: " ", count: width - withCR.count)
    }

    static func parseAFList(_ raw: String) -> [Int] {
        let tokens = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out: [Int] = []
        for token in tokens {
            guard let mhz = Double(token) else { continue }
            if mhz >= 87.6, mhz <= 107.9 {
                out.append(Int((mhz - 87.5) / 0.1 + 0.5))
            }
        }
        return out
    }

    static func parseHexByte(_ raw: String) -> Int {
        let cleaned =
            raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { ch in
                switch ch {
                case "0"..."9", "A"..."F":
                    return true
                default:
                    return false
                }
            }
        if cleaned.isEmpty {
            return 0
        }
        let trimmed = cleaned.count > 2 ? String(cleaned.suffix(2)) : cleaned
        return Int(trimmed, radix: 16) ?? 0
    }

    private static func modifiedJulianDay(year: Int, month: Int, day: Int) -> Int {
        var y = year
        var m = month
        if m <= 2 {
            y -= 1
            m += 12
        }
        let a = y / 100
        let b = 2 - a + (a / 4)
        let jd = Int(
            Double(Int(365.25 * Double(y + 4716)))
                + Double(Int(30.6001 * Double(m + 1)))
                + Double(day + b) - 1524.5)
        return jd - 2_400_001
    }

    private static func parseRTPlusTags(
        text: String,
        format: String,
        snapshot: NowPlayingSnapshot? = nil
    ) -> [RTPlusTag] {
        if text.isEmpty {
            return []
        }
        if let snapshot, snapshot.hasContent, format.isEmpty {
            return parseRTPlusTagsFromSnapshot(text: text, snapshot: snapshot)
        }
        if format.isEmpty {
            return []
        }

        var escaped = NSRegularExpression.escapedPattern(for: format)
        let nowPlayingPattern = capturePattern(
            name: "now_playing",
            exactValue: snapshot?.display
        )
        let displayPattern = capturePattern(
            name: "display",
            exactValue: snapshot?.display
        )
        let artistPattern = capturePattern(
            name: "artist",
            exactValue: snapshot?.artist
        )
        let titlePattern = capturePattern(
            name: "title",
            exactValue: snapshot?.title
        )
        escaped = escaped.replacingOccurrences(
            of: "\\{now_playing\\}", with: nowPlayingPattern)
        escaped = escaped.replacingOccurrences(of: "\\{display\\}", with: displayPattern)
        escaped = escaped.replacingOccurrences(of: "\\{artist\\}", with: artistPattern)
        escaped = escaped.replacingOccurrences(of: "\\{title\\}", with: titlePattern)
        guard let regex = try? NSRegularExpression(pattern: escaped, options: []) else {
            return []
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else {
            return []
        }

        func makeTag(name: String, contentType: Int) -> RTPlusTag? {
            let range = match.range(withName: name)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            let start = max(0, min(63, range.location))
            let length = max(1, min(64 - start, range.length))
            return RTPlusTag(contentType: contentType, start: start, length: length)
        }

        var tags: [RTPlusTag] = []
        if let titleTag = makeTag(name: "title", contentType: 1) {
            tags.append(titleTag)
        }
        if tags.isEmpty, let nowPlayingTag = makeTag(name: "now_playing", contentType: 1) {
            tags.append(nowPlayingTag)
        }
        if tags.isEmpty, let displayTag = makeTag(name: "display", contentType: 1) {
            tags.append(displayTag)
        }
        if let artistTag = makeTag(name: "artist", contentType: 4) {
            tags.append(artistTag)
        }
        return tags.sorted {
            if $0.start == $1.start {
                return $0.contentType < $1.contentType
            }
            return $0.start < $1.start
        }
    }

    private static func expandNowPlayingMacros(_ text: String, snapshot: NowPlayingSnapshot) -> String {
        NowPlayingFormatter.expandTemplate(text, snapshot: snapshot)
    }

    private static func capturePattern(name: String, exactValue: String?) -> String {
        let trimmed = exactValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "(?<\(name)>.+?)"
        }
        let escapedValue = NSRegularExpression.escapedPattern(for: trimmed)
        return "(?<\(name)>\(escapedValue))"
    }

    private static func parseRTPlusTagsFromSnapshot(
        text: String,
        snapshot: NowPlayingSnapshot
    ) -> [RTPlusTag] {
        let nsText = text as NSString

        func firstTag(for value: String, contentType: Int) -> RTPlusTag? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let range = nsText.range(of: trimmed)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            let start = max(0, min(63, range.location))
            let length = max(1, min(64 - start, range.length))
            return RTPlusTag(contentType: contentType, start: start, length: length)
        }

        var tags: [RTPlusTag] = []
        if let artistTag = firstTag(for: snapshot.artist, contentType: 4) {
            tags.append(artistTag)
        }
        if let titleTag = firstTag(for: snapshot.title, contentType: 1) {
            tags.append(titleTag)
        } else if let displayTag = firstTag(for: snapshot.display, contentType: 1) {
            tags.append(displayTag)
        }

        return tags.sorted {
            if $0.start == $1.start {
                return $0.contentType < $1.contentType
            }
            return $0.start < $1.start
        }
    }
}

final class MPXGenerator {
    struct AnalysisBuffers {
        let postAGCLeft: UnsafeMutablePointer<Float>?
        let postAGCRight: UnsafeMutablePointer<Float>?
        let preMPXLeft: UnsafeMutablePointer<Float>?
        let preMPXRight: UnsafeMutablePointer<Float>?

        static var none: AnalysisBuffers {
            AnalysisBuffers(
                postAGCLeft: nil,
                postAGCRight: nil,
                preMPXLeft: nil,
                preMPXRight: nil
            )
        }
    }

    struct AGCStatus {
        let enabled: Bool
        let detectorDB: Float
        let gainDB: Float
        let gateActive: Bool
    }

    struct FinalLimiterStatus {
        let enabled: Bool
        let gainReductionDB: Float
        let preEncodeGainReductionDB: Float
        let safetyGainReductionDB: Float
    }

    struct CompositeCalibrationStatus {
        let pilotPercent: Float
        let rdsPercent: Float
        let audioPeak: Float
        let budgetMarginDB: Float
    }

    private struct FinalCompositeThresholds {
        let effectiveThreshold: Float
        let preLimiterCeiling: Float
        let postLimiterCeiling: Float
    }

    private static let finalCompositePreLimiterHeadroom: Float = 0.040
    private static let finalCompositePostLimiterHeadroom: Float = 0.030
    private static let finalCompositePreLimiterFloor: Float = 0.18
    private static let finalCompositePostLimiterFloor: Float = 0.16
    private static let monitorDiffDecodeGain: Float = 1.06

    private struct EncoderComplianceConfig {
        let programLowpassHz: Float
        let encoderLowpassHz: Float
        let hfGuardCrossoverHz: Float
    }

    struct RuntimeConfig: Equatable {
        let inputGainDB: Float
        let outputGainDB: Float
        let finalDriveDB: Float
        let widebandAGCEnabled: Bool
        let widebandAGCTargetDB: Float
        let widebandAGCMaxGainDB: Float
        let widebandAGCMinGainDB: Float
        let widebandAGCAttackMS: Float
        let widebandAGCReleaseMS: Float
        let widebandAGCKWeightingEnabled: Bool
        let widebandAGCReleaseProgramDependent: Bool
        let preEncodeAudioLimiterEnabled: Bool
        let mpxDeviationKHz: Float
        let primeBassEnabled: Bool
        let primeBassAmount: Float
        let primeBassHarmonics: Float
        let primeBassDrive: Float
        let primeBassDensity: Float
        let primeBassSubharmonicsEnabled: Bool
        let primeBassSubharmonicsAmount: Float
        let primeBassFreqHz: Float
        let stereoWidenEnabled: Bool
        let monoBassEnabled: Bool
        let monoBassFreqHz: Float
        let widenWidth: Float
        let widenCenter: Float
        let widenMix: Float
        let multibandEnabled: Bool
        let multibandMode: Int
        let multibandMakeupDB: Float
        let multibandKneeDB: Float
        let multibandLinkStrength: Float
        let multibandReleaseProgramDependent: Bool
        let multibandX1Hz: Float
        let multibandX2Hz: Float
        let multibandX3Hz: Float
        let multibandX4Hz: Float
        let multibandLowThresholdDB: Float
        let multibandMidThresholdDB: Float
        let multibandHighThresholdDB: Float
        let multibandLowRatio: Float
        let multibandMidRatio: Float
        let multibandHighRatio: Float
        let multibandLowAttackMS: Float
        let multibandMidAttackMS: Float
        let multibandHighAttackMS: Float
        let multibandLowReleaseMS: Float
        let multibandMidReleaseMS: Float
        let multibandHighReleaseMS: Float
        let phaseRotationEnabled: Bool
        let phaseRotationFreqHz: Float
        let parametricEQEnabled: Bool
        // Bands 1 and 4 are shelves (no Q control); bands 2 and 3 are peaking.
        let peqB1FreqHz: Float
        let peqB1GainDB: Float
        let peqB2FreqHz: Float
        let peqB2GainDB: Float
        let peqB2Q: Float
        let peqB3FreqHz: Float
        let peqB3GainDB: Float
        let peqB3Q: Float
        let peqB4FreqHz: Float
        let peqB4GainDB: Float
        let multibandLimiterEnabled: Bool
        let multibandLimiterThresholdDB: Float
        let multibandLimiterAttackMS: Float
        let multibandLimiterReleaseMS: Float
        let downwardExpanderEnabled: Bool
        let expanderThresholdDB: Float
        let expanderRatio: Float
        let expanderAttackMS: Float
        let expanderReleaseMS: Float
        let bassClipperEnabled: Bool
        let bassClipperCrossoverHz: Float
        let bassClipperThresholdDB: Float
        let bassClipperDrive: Float
        let dcClipperEnabled: Bool
        let dcClipperCeilingDB: Float
        let dcClipperCancelFreqHz: Float
        let bs412Enabled: Bool
        let bs412ThresholdDB: Float
        let bs412WindowSeconds: Float
        let compositeClipperEnabled: Bool
        let compositeClipperThresholdDB: Float
        let compositeClipperCeilingDB: Float
        let compositeClipperCancelAudio: Bool
        let compositeClipperCancelStereo: Bool
        let compositeClipperCancelPilot: Bool
        let compositeClipperCancelRDS: Bool

        // Tone-generator parameters. Live-applicable so the Test Tone
        // tab can toggle source / type / freq / mode / level without
        // restarting the engine.
        let sourceMode: String        // "input" | "tone"
        let testToneType: String      // "sine" | "pink" | "white"
        let testToneMode: String      // "mono" | "stereo" | "left" | "right"
        let testToneFreq: Float
        let testToneLevelDB: Float
    }

    /// Runtime-applicable RDS state. Anything an operator can change
    /// without restarting transport flows through this struct. The
    /// only RDS settings NOT here are physical-layer (subcarrier
    /// frequency, Gaussian shaping FIR, RDS injection level) — those
    /// touch DSP allocation and stay restart-only.
    struct RDSRuntimeConfig: Equatable {
        // Master + injection
        let enabled: Bool

        // Identification
        let pi: Int
        let pty: Int
        let ptynText: String
        let ptynEnabled: Bool
        let ptynCentered: Bool
        let eccCode: Int
        let licCode: Int

        // Flags (operationally toggled)
        let tp: Bool
        let ta: Bool
        let ms: Bool
        let diStereo: Bool
        let diHead: Bool
        let diComp: Bool
        let diDyn: Bool

        // Program Service
        let psBanks: [String]        // 4 PS text banks (A, B, C, D)
        let psActiveBank: String     // "A" / "B" / "C" / "D"
        let psCentered: Bool
        let psFrameSeconds: Double   // fallback per-segment duration when no Ns: marker

        // Long PS (15A)
        let longPSText: String
        let lpsEnabled: Bool
        let lpsCentered: Bool
        let lpsCR: Bool

        // Radiotext + RT+
        let rtText: String
        let rtBuffers: [String]
        let rtBufferEnabled: [Bool]
        let rtCR: Bool
        let rtCentered: Bool
        let rtMode2B: Bool
        let rtCycleTime: Double
        let rtCycleAB: Bool
        let rtABCycleCount: Int
        let rtPlusEnabled: Bool
        let rtPlusFormatA: String
        let rtPlusFormatB: String
        let nowPlayingEnabled: Bool

        // Alternative Frequencies
        let afEnabled: Bool
        let afCodes: [Int]
        let afMethod: String

        // Clock + scheduler
        let enableCT: Bool
        let enableID: Bool
        let tzOffset: Double
        /// Raw `0A 0A 2A 0A` group-sequence string. Parsed by the
        /// consumer; keeps RDSRuntimeConfig free of file-private types.
        let groupSequenceRaw: String
        let schedulerAuto: Bool
        let schedulerStandard: Bool
        let schedulerStandardLPS: Bool

        /// Build a runtime config snapshot from the current `AppConfig`.
        /// Single source of truth for the AppConfig → RDS-runtime mapping
        /// (used by both `AudioOutputEngine.applyRDSRuntimeConfig` and
        /// the test suite).
        static func make(from config: AppConfig) -> RDSRuntimeConfig {
            RDSRuntimeConfig(
                enabled: config.enRDS && config.rdsLevel > 0.0,
                pi: BasicRDSCoder.parseHexWord(config.rdsPI),
                pty: max(0, min(31, config.rdsPTY)),
                ptynText: config.rdsPTYN,
                ptynEnabled: config.rdsEnablePTYN,
                ptynCentered: config.rdsPTYNCentered,
                eccCode: BasicRDSCoder.parseHexByte(config.rdsECC),
                licCode: BasicRDSCoder.parseHexByte(config.rdsLIC),
                tp: config.rdsTP,
                ta: config.rdsTA,
                ms: config.rdsMS,
                diStereo: config.rdsDI_STEREO,
                diHead: config.rdsDI_HEAD,
                diComp: config.rdsDI_COMP,
                diDyn: config.rdsDI_DYN,
                psBanks: [config.rdsPSA, config.rdsPSB, config.rdsPSC, config.rdsPSD],
                psActiveBank: config.rdsPSActiveBank,
                psCentered: config.rdsPSCentered,
                psFrameSeconds: config.rdsPSFrameSeconds,
                longPSText: config.rdsLongPS32,
                lpsEnabled: config.rdsEnableLPS,
                lpsCentered: config.rdsLPSCentered,
                lpsCR: config.rdsLPSCR,
                rtText: config.rdsRTText,
                rtBuffers: [config.rdsRTA, config.rdsRTB, config.rdsRTC, config.rdsRTD],
                rtBufferEnabled: [
                    config.rdsRTBufferAEnabled,
                    config.rdsRTBufferBEnabled,
                    config.rdsRTBufferCEnabled,
                    config.rdsRTBufferDEnabled,
                ],
                rtCR: config.rdsRTCR,
                rtCentered: config.rdsRTCentered,
                rtMode2B: config.rdsRTMode.uppercased() == "2B",
                rtCycleTime: config.rdsRTCycleTime,
                rtCycleAB: config.rdsRTCycleAB,
                rtABCycleCount: config.rdsRTABCycleCount,
                rtPlusEnabled: config.rdsEnableRTPlus,
                rtPlusFormatA: config.rdsRTPlusFormatA,
                rtPlusFormatB: config.rdsRTPlusFormatB,
                nowPlayingEnabled: config.rdsNowPlayingEnabled,
                afEnabled: config.rdsEnableAF,
                afCodes: BasicRDSCoder.parseAFList(config.rdsAFList),
                afMethod: config.rdsAFMethod,
                enableCT: config.rdsEnableCT,
                enableID: config.rdsEnableID,
                tzOffset: config.rdsTZOffset,
                groupSequenceRaw: config.rdsGroupSequence,
                schedulerAuto: config.rdsSchedulerAuto,
                schedulerStandard: config.rdsSchedulerStandard,
                schedulerStandardLPS: config.rdsSchedulerStandardLPS
            )
        }
    }

    private var sampleRate: Float
    private let preemphasisUS: Int
    // Tone-generator parameters. All `var` for live-apply through
    // `applyRuntimeConfig` — the Test Tone tab adjusts these on a
    // running engine without restart.
    private var toneFreq: Float
    private var toneMode: String
    private var toneType: String = "sine"
    private var toneLevel: Float = 0.1   // 10^(-20/20) — −20 dBFS default
    private let monoMode: Bool
    private let processingBypass: Bool
    private let pilotLevel: Float
    private let pilotInjectionPercent: Float
    private let rdsInjectionPercent: Float
    private let sumLevel: Float
    private let diffLevel: Float
    private var inputGain: Float
    private var outputGain: Float
    private var finalDrive: Float
    private let limitEnabled: Bool
    private let threshold: Float
    private var deviationScale: Float
    private let programLowpassHz: Float
    private let encoderHFGuardEnabled: Bool

    private var widebandAGCEnabled: Bool
    private var widebandAGCTargetDB: Float
    private var widebandAGCMaxGainDB: Float
    private var widebandAGCMinGainDB: Float
    private var widebandAGCAttackMS: Float
    private var widebandAGCReleaseMS: Float
    private var widebandAGCKWeightingEnabled: Bool = true
    private var widebandAGCReleaseProgramDependent: Bool = true
    private var widebandAGC = WidebandAGCRider()

    private var phaseRotationEnabled: Bool
    private var phaseRotationFreqHz: Float
    private var phaseRotator = StereoPhaseRotator()

    private var parametricEQEnabled: Bool
    private var peqB1FreqHz: Float
    private var peqB1GainDB: Float
    private var peqB2FreqHz: Float
    private var peqB2GainDB: Float
    private var peqB2Q: Float
    private var peqB3FreqHz: Float
    private var peqB3GainDB: Float
    private var peqB3Q: Float
    private var peqB4FreqHz: Float
    private var peqB4GainDB: Float
    private var parametricEQ = ParametricEQ4Band()

    private let hpfHz: Float
    private let hfTrimDB: Float
    private let hfTrimHz: Float
    private var inputHPF = StereoBiquad()
    private var hfTrim = StereoBiquad()

    private let limitLookaheadEnabled: Bool
    private let limitLookaheadMS: Float
    private var lookaheadLimiter = LookaheadLimiter()
    private let audioCompositeSoftClipEnabled: Bool
    private let audioCompositeSmootherRequested: Bool
    private let finalMPXSoftClipEnabled: Bool

    private var primeBassEnabled: Bool
    private var primeBassAmount: Float
    private var primeBassHarmonics: Float
    private var primeBassDrive: Float
    private var primeBassDensity: Float
    private var primeBassSubharmonicsEnabled: Bool
    private var primeBassSubharmonicsAmount: Float
    private var primeBassFreqHz: Float
    private var primeBassLP = OnePoleLP()
    private var primeBassSubLP = OnePoleLP()
    private var primeBassHarmHPF = Biquad()
    private var primeBassHarmLPF = Biquad()
    // Allpass at F0 — Aphex US 4,150,253 "HP-then-clip" topology
    // adapted for bass enhancement: instead of a HPF (which would
    // attenuate F0 itself), use an allpass that preserves amplitude
    // but rotates phase by ~180° across F0. Harmonics generated
    // downstream are then phase-decorrelated from the direct
    // lowboost path, preventing comb-filter summing at the bass
    // clipper's input.
    private var primeBassSideAP = Biquad()
    private var primeBassSubPrevSample: Float = 0.0
    private var primeBassSubPhase: Int = 0
    // Werrbach Big Bottom dynamic-bass-extension envelope follower
    // (US 5,359,665, Aphex, expired 2012-07-31). Drives `primeBassAdaptiveGain`
    // directly via its asymmetric attack/release: fast attack (~10 ms)
    // catches the leading edge of a kick / plucked-bass note; slow
    // release (~300 ms) extends the boost over the natural decay.
    // Net effect per the patent: "envelope duration extension" —
    // perceived bass holds longer without growing the peak. Replaces
    // the prior spectral-ratio detector + transient-hold machinery,
    // which tracked compositional balance over seconds and so
    // couldn't engage on a typical drum hit before the hit was over.
    // `internal` access on env so tests can verify dynamics directly.
    var primeBassBigBottomEnv: Float = 0.0
    private var primeBassBigBottomAttackCoeff: Float = 0.0
    private var primeBassBigBottomReleaseCoeff: Float = 0.0
    var primeBassAdaptiveGain: Float = 0.0
    private var primeBassLevelEst: Float = 1e-3
    private var primeBassMakeupGain: Float = 1.0
    private var primeBassLevelAlpha: Float = 0.0
    private var primeBassMakeupAttackCoeff: Float = 0.0
    private var primeBassMakeupReleaseCoeff: Float = 0.0
    // MaxxBass-style equal-loudness weighting (US 5,930,373, expired
    // 2017): per-harmonic-order gain derived from an ISO 226 phon-curve
    // approximation evaluated at 2..5 x F0 at configure time.
    // Even-harmonic weight applies to the asymmetric (squared-with-sign)
    // generator's output; odd-harmonic weight applies to the soft-clip
    // difference generator's output. Precomputing avoids per-sample
    // log/exp.
    private var primeBassHarmEvenWeight: Float = 0.55
    private var primeBassHarmOddWeight: Float = 0.65
    // MaxxBass: when harmonic synthesis is active, the direct LF gain
    // is reduced — the perceived bass is carried more by the
    // weighted harmonics, less by the LF amplitude itself. This buys
    // headroom in the bass clipper and pre-encode limiter while
    // preserving subjective bass weight.
    private let primeBassDirectGainReduction: Float = 0.62
    // Werrbach transient-discriminate harmonic gain (US 5,424,488,
    // Aphex Sound Enhancement System, expired 2013). The harmonic-band
    // gain is modulated by a transient detector built from two
    // envelopes — a fast follower (~5 ms attack) tracking the LF
    // input and a slow follower (~50 ms attack) tracking its baseline.
    // Their normalized difference is positive on real onsets (drum
    // hits, plucked bass) and decays to zero as the slow follower
    // catches up, ~50–150 ms post-attack. Mapped through a
    // floor → peak range to give a brief harmonic burst on attacks
    // and a lower sustain floor on continuous program — "punchy
    // not boomy."
    // `internal` access on these three so tests can verify the
    // transient detector directly without relying on FFT spectral
    // analysis, which is muddied by fundamental-bin leakage when
    // input and harmonic frequencies are close.
    var primeBassFastEnv: Float = 0.0
    var primeBassSlowEnv: Float = 0.0
    var primeBassTransientGainObserved: Float = primeBassTransientFloor
    private var primeBassFastAttackCoeff: Float = 0.0
    private var primeBassFastReleaseCoeff: Float = 0.0
    private var primeBassSlowAttackCoeff: Float = 0.0
    private var primeBassSlowReleaseCoeff: Float = 0.0
    private static let primeBassTransientFloor: Float = 0.7
    private static let primeBassTransientPeak: Float = 1.4

    private var multibandEnabled: Bool
    private var multibandMode: Int
    private var multibandMakeup: Float
    private var multibandKneeDB: Float
    private var multibandLinkStrength: Float
    private var multibandReleaseProgramDependent: Bool
    private var multibandX1Hz: Float
    private var multibandX2Hz: Float
    private var multibandX3Hz: Float
    private var multibandX4Hz: Float
    private var multibandLowThresholdDB: Float
    private var multibandMidThresholdDB: Float
    private var multibandHighThresholdDB: Float
    private var multibandLowRatio: Float
    private var multibandMidRatio: Float
    private var multibandHighRatio: Float
    private var multibandLowAttackMS: Float
    private var multibandMidAttackMS: Float
    private var multibandHighAttackMS: Float
    private var multibandLowReleaseMS: Float
    private var multibandMidReleaseMS: Float
    private var multibandHighReleaseMS: Float

    private var mb3Split1 = StereoLinkwitzRiley4()
    private var mb3Split2 = StereoLinkwitzRiley4()
    // Linear-phase FIR splitter — used in TX mode in place of mb3Split1/2
    // to keep transients time-coherent across bands.
    private var mb3FIRSplitter = LinearPhaseMultibandSplitter3()
    private var mbLowCompL = MonoCompressor()
    private var mbLowCompR = MonoCompressor()
    private var mbMidCompL = MonoCompressor()
    private var mbMidCompR = MonoCompressor()
    private var mbHighCompL = MonoCompressor()
    private var mbHighCompR = MonoCompressor()

    private var mb5Split1 = StereoLinkwitzRiley4()
    private var mb5Split2 = StereoLinkwitzRiley4()
    private var mb5Split3 = StereoLinkwitzRiley4()
    private var mb5Split4 = StereoLinkwitzRiley4()
    // Linear-phase FIR splitter — used in TX mode in place of
    // mb5Split1..4 to keep transients time-coherent across bands.
    private var mb5FIRSplitter = LinearPhaseMultibandSplitter5()
    private var mb5Comp1L = MonoCompressor()
    private var mb5Comp1R = MonoCompressor()
    private var mb5Comp2L = MonoCompressor()
    private var mb5Comp2R = MonoCompressor()
    private var mb5Comp3L = MonoCompressor()
    private var mb5Comp3R = MonoCompressor()
    private var mb5Comp4L = MonoCompressor()
    private var mb5Comp4R = MonoCompressor()
    private var mb5Comp5L = MonoCompressor()
    private var mb5Comp5R = MonoCompressor()

    // Multiband limiter: per-band fast peak limiters after compression
    private var multibandLimiterEnabled: Bool
    private var multibandLimiterThresholdDB: Float
    private var multibandLimiterAttackMS: Float
    private var multibandLimiterReleaseMS: Float
    private var mbLimLow = BandLimiter()
    private var mbLimMid = BandLimiter()
    private var mbLimHigh = BandLimiter()
    private var mbLim5B1 = BandLimiter()
    private var mbLim5B2 = BandLimiter()
    private var mbLim5B3 = BandLimiter()
    private var mbLim5B4 = BandLimiter()
    private var mbLim5B5 = BandLimiter()

    // Downward expander: per-band noise reduction
    private var downwardExpanderEnabled: Bool
    private var expanderThresholdDB: Float
    private var expanderRatio: Float
    private var expanderAttackMS: Float
    private var expanderReleaseMS: Float
    private var mbExpLow = DownwardExpander()
    private var mbExpMid = DownwardExpander()
    private var mbExpHigh = DownwardExpander()
    private var mbExp5B1 = DownwardExpander()
    private var mbExp5B2 = DownwardExpander()
    private var mbExp5B3 = DownwardExpander()
    private var mbExp5B4 = DownwardExpander()
    private var mbExp5B5 = DownwardExpander()

    // Bass clipper: dedicated LF clipper before final limiter
    private var bassClipperEnabled: Bool
    private var bassClipperCrossoverHz: Float
    private var bassClipperThresholdDB: Float
    private var bassClipperDrive: Float
    private var bassClipper = BassClipper()

    // Distortion-cancelled clipper: L/R domain with LF distortion cancellation
    private var dcClipperEnabled: Bool
    private var dcClipperCeilingDB: Float
    private var dcClipperCancelFreqHz: Float
    private var dcClipper = DistortionCancelledClipper()

    // BS.412 MPX power limiter
    private var bs412Enabled: Bool
    private var bs412ThresholdDB: Float
    private var bs412WindowSeconds: Float
    private var bs412Limiter = BS412PowerLimiter()
    // CompositeClipper: disabled by default, field only for size/layout test.
    private var compositeClipperEnabled: Bool = false
    private var compositeClipperThresholdDB: Float = -3.0
    private var compositeClipperCeilingDB: Float = -0.5
    private var compositeClipperCancelAudio: Bool = true
    private var compositeClipperCancelStereo: Bool = true
    private var compositeClipperCancelPilot: Bool = true
    private var compositeClipperCancelRDS: Bool = true
    private var compositeClipper = CompositeClipper()

    private var stereoWidenEnabled: Bool
    private var monoBassEnabled: Bool
    private var monoBassFreqHz: Float
    private var widenWidth: Float
    private var widenCenter: Float
    private var widenMix: Float
    private var monoBassSideLP = Biquad()
    private var widenSideHP = Biquad()
    private var stereoProtectInputMidEnv: Float = 0.0
    private var stereoProtectInputSideEnv: Float = 0.0
    private var stereoProtectMidEnv: Float = 0.0
    private var stereoProtectSideEnv: Float = 0.0
    private var stereoProtectGain: Float = 1.0
    private var stereoProtectAttackCoeff: Float = 0.0
    private var stereoProtectReleaseCoeff: Float = 0.0
    private var rdsCoder: BasicRDSCoder?

    private var preEncodeAudioLimiterEnabled: Bool
    private var preEncodeAudioLimiter = PreEncodeAudioLimiter()
    private var preEncodeThreshold: Float = 0.85
    private var preEncodeReleaseMS: Float = 50.0

    private var toneStep: Float
    private var tonePhase: Float = 0.0
    /// Paul Kellet's 4-pole pink-noise IIR state. Cheap, well-known
    /// approximation (~3 dB/octave from ~0.4 Hz upward). Cycle artefacts
    /// above ~10 kHz aren't a concern at the test-tone level / use
    /// case (broadband fill, not deterministic measurement).
    private var pinkB0: Float = 0.0
    private var pinkB1: Float = 0.0
    private var pinkB2: Float = 0.0
    private var pinkB3: Float = 0.0
    private var pinkB4: Float = 0.0
    private var pinkB5: Float = 0.0
    private var pinkB6: Float = 0.0
    /// xorshift64* seed for white noise. Initialised on engine start;
    /// the audio thread mutates it without locks (xorshift is a pure
    /// scalar update; the noise stream doesn't need to be reproducible
    /// across runs).
    private var toneNoiseRNG: UInt64 = 0xCAFE_BABE_DEAD_BEEF
    private var pilotOsc = SineCosOsc()
    private var pilotPhaseForRDS: Float = 0.0
    private var subPhase: Float = 0.0

    private var pilotSupported: Bool = false
    private var stereoSubcarrierSupported: Bool = false
    private var rdsSupported: Bool = false

    // Pre-emphasis runs in L/R domain immediately upstream of the pre-encode
    // limiter (canonical Optimod / Stereotool placement). The limiter then
    // peak-controls the HF-boosted signal before it crosses into composite
    // assembly. Moved here from M/S inside `makeCompositeComponents` in the
    // 2026-05 chain-order audit — see plan.md "Pre-emphasis placement" and
    // the chain-order-audit report at macOS/.audit-out/chain_order/REPORT.md.
    private var preL = PreemphasisFilter()
    private var preR = PreemphasisFilter()
    private var programLP = ProgramLowpass()
    private var encoderProgramLP = ProgramLowpass()
    private var encoderProgramFIR = LinearPhaseFIRLowpass()
    // Selects the TX-grade FIR over the low-latency Butterworth. Set by
    // AudioOutputEngine based on output mode (composite → FIR, monitor →
    // Butterworth) and the `encoderFirEnabled` config toggle.
    private var useEncoderFIR: Bool = false
    // Selects linear-phase FIR multiband crossovers over the IIR LR4
    // chain. TX mode default; monitor mode keeps LR4 for low latency.
    // Phase-flat band reconstruction prevents transient smear and
    // inter-band phase artifacts.
    private var useMultibandFIR: Bool = false
    private var pilotNotchL = Biquad()
    private var pilotNotchR = Biquad()
    private var encoderHFGuardSplit = StereoLinkwitzRiley4()
    private var encoderHFGuardEnv: Float = 0.0
    private var encoderHFGuardGain: Float = 1.0
    private var encoderHFGuardAttackCoeff: Float = 0.0
    private var encoderHFGuardReleaseCoeff: Float = 0.0
    private var compositeAudioSmoother = OnePoleLP()
    private var compositeAudioSmootherEnabled: Bool = false
    private var monitorLPRLP = BiquadCascade6()
    private var monitorDiffBandHP = BiquadCascade6()
    private var monitorDiffBandLP = BiquadCascade6()
    private var monitorDiffLP = BiquadCascade6()
    private var monitorRFNotchPilot = Biquad()
    private var monitorRFNotchRDS = Biquad()
    private var monitorPilotNotchL = Biquad()
    private var monitorPilotNotchR = Biquad()
    private var monitorDeemphasisL = DeemphasisFilter()
    private var monitorDeemphasisR = DeemphasisFilter()
    private var lastSubcarrierSample: Float = 0.0
    private var audioCompositePeakState: Float = 0.0
    private var audioCompositePeakDecayCoeff: Float = 0.0
    private var subcarrierReservationEnv: Float = 0.0
    private var subcarrierReservationAttackCoeff: Float = 0.0
    private var subcarrierReservationReleaseCoeff: Float = 0.0
    private var monitorNoiseGateGain: Float = 0.0
    private var monitorNoiseGateOpen: Bool = false
    private var lastProgramActivity: Float = 0.0
    private struct ProgramStereoState {
        var left: Float
        var right: Float
        var referenceLeft: Float
        var referenceRight: Float
        var postAGCLeft: Float
        var postAGCRight: Float
        var inputActivity: Float
    }

    private struct CompositeComponents {
        var base: Float
        var diff: Float
        var sub: Float
        var pilot: Float
        var rds: Float
    }

    private struct StereoImageState {
        var left: Float
        var right: Float
    }
    private var monitorProgramEnv: Float = 0.0
    private var monitorProgramNoiseFloor: Float = 0.0
    private var monitorExpectedSideEnv: Float = 0.0
    private var monitorExpectedSideAttackCoeff: Float = 0.0
    private var monitorExpectedSideReleaseCoeff: Float = 0.0
    private var monitorCollapseHoldSamples: Int = 0
    private var monitorCollapseCooldownSamples: Int = 0
    private var monitorProgramEnvAttackCoeff: Float = 0.0
    private var monitorProgramEnvReleaseCoeff: Float = 0.0
    private var monitorNoiseFloorRiseCoeff: Float = 0.0
    private var monitorNoiseFloorFallCoeff: Float = 0.0
    private var monitorNoiseGateAttackCoeff: Float = 0.0
    private var monitorNoiseGateReleaseCoeff: Float = 0.0
    private var monitorCollapseHoldThresholdSamples: Int = 0
    private var monitorCollapseCooldownResetSamples: Int = 0

    init(config: AppConfig, sampleRate: Double, nowPlayingState: NowPlayingState? = nil) {
        self.sampleRate = Float(max(8_000.0, sampleRate))
        self.preemphasisUS = config.preemphasisUS
        self.toneFreq = Float(config.testToneFreq)
        self.toneMode = config.testToneMode.lowercased()
        self.toneType = config.testToneType.lowercased()
        self.toneLevel = powf(10.0, Float(config.testToneLevelDB) / 20.0)
        self.monoMode = config.monoMode
        self.processingBypass = config.processingBypass
        self.pilotLevel = Float(config.pilotLevel)
        self.pilotInjectionPercent = Float(config.pilotLevel * 100.0)
        self.rdsInjectionPercent = Float(max(0.0, config.rdsLevel / 75.0 * 100.0))
        self.sumLevel = Float(config.sumLevel)
        self.diffLevel = Float(config.diffLevel)
        self.inputGain = powf(10.0, Float(config.inputGainDB) / 20.0)
        self.outputGain = powf(10.0, Float(config.outputGainDB) / 20.0)
        self.finalDrive = powf(10.0, Float(config.finalDriveDB) / 20.0)
        self.limitEnabled = config.limitMPX
        self.threshold = clampf(Float(config.limitThreshold), 0.5, 0.999)
        self.deviationScale = Float(config.mpxDeviationKHz / 75.0)
        self.programLowpassHz = Float(config.programLowpassHz)
        self.encoderHFGuardEnabled = config.preemphasisUS > 0

        self.widebandAGCEnabled = config.widebandAGCEnabled
        self.widebandAGCTargetDB = Float(config.widebandAGCTargetDB)
        self.widebandAGCMaxGainDB = Float(config.widebandAGCMaxGainDB)
        self.widebandAGCMinGainDB = Float(config.widebandAGCMinGainDB)
        self.widebandAGCAttackMS = Float(config.widebandAGCAttackMS)
        self.widebandAGCReleaseMS = Float(config.widebandAGCReleaseMS)
        self.widebandAGCKWeightingEnabled = config.widebandAGCKWeightingEnabled
        self.widebandAGCReleaseProgramDependent = config.widebandAGCReleaseProgramDependent

        self.phaseRotationEnabled = config.phaseRotationEnabled
        self.phaseRotationFreqHz = clampf(Float(config.phaseRotationFreqHz), 50.0, 500.0)

        self.parametricEQEnabled = config.parametricEQEnabled
        self.peqB1FreqHz = clampf(Float(config.peqB1FreqHz), 20.0, 500.0)
        self.peqB1GainDB = clampf(Float(config.peqB1GainDB), -12.0, 12.0)
        self.peqB2FreqHz = clampf(Float(config.peqB2FreqHz), 100.0, 5000.0)
        self.peqB2GainDB = clampf(Float(config.peqB2GainDB), -12.0, 12.0)
        self.peqB2Q = clampf(Float(config.peqB2Q), 0.1, 10.0)
        self.peqB3FreqHz = clampf(Float(config.peqB3FreqHz), 500.0, 12000.0)
        self.peqB3GainDB = clampf(Float(config.peqB3GainDB), -12.0, 12.0)
        self.peqB3Q = clampf(Float(config.peqB3Q), 0.1, 10.0)
        self.peqB4FreqHz = clampf(Float(config.peqB4FreqHz), 1000.0, 16000.0)
        self.peqB4GainDB = clampf(Float(config.peqB4GainDB), -12.0, 12.0)

        self.hpfHz = clampf(Float(config.hpfHz), 10.0, 200.0)
        self.hfTrimDB = clampf(Float(config.hfTrimDB), -12.0, 0.0)
        self.hfTrimHz = clampf(Float(config.hfTrimHz), 500.0, 12_000.0)

        self.limitLookaheadEnabled = config.limitLookaheadEnabled
        self.limitLookaheadMS = clampf(Float(config.limitLookaheadMS), 0.0, 20.0)
        self.preEncodeAudioLimiterEnabled = config.preEncodeAudioLimiterEnabled
        self.audioCompositeSoftClipEnabled = config.audioCompositeSoftClipEnabled
        self.audioCompositeSmootherRequested = config.audioCompositeSmootherEnabled
        self.finalMPXSoftClipEnabled = config.finalMPXSoftClipEnabled

        self.primeBassEnabled = config.primeBassEnabled
        self.primeBassAmount = clampf(Float(config.primeBassAmount), 0.0, 1.0)
        self.primeBassHarmonics = clampf(Float(config.primeBassHarmonics), 0.0, 1.0)
        self.primeBassDrive = clampf(Float(config.primeBassDrive), 0.0, 2.5)
        self.primeBassDensity = clampf(Float(config.primeBassDensity), 0.0, 1.0)
        self.primeBassSubharmonicsEnabled = config.primeBassSubharmonicsEnabled
        self.primeBassSubharmonicsAmount = clampf(Float(config.primeBassSubharmonicsAmount), 0.0, 1.0)
        self.primeBassFreqHz = clampf(Float(config.primeBassFreqHz), 45.0, 220.0)

        self.multibandEnabled = config.multibandEnabled
        self.multibandMode = (config.multibandMode == 5) ? 5 : 3
        self.multibandMakeup = powf(10.0, Float(config.multibandMakeupDB) / 20.0)
        self.multibandKneeDB = clampf(Float(config.multibandKneeDB), 0.0, 12.0)
        self.multibandLinkStrength = clampf(Float(config.multibandLinkStrength), 0.0, 1.0)
        self.multibandReleaseProgramDependent = config.multibandReleaseProgramDependent
        let crossovers = Self.resolveMultibandCrossovers(
            sampleRate: self.sampleRate,
            x1: Float(config.multibandX1Hz),
            x2: Float(config.multibandX2Hz),
            x3: Float(config.multibandX3Hz),
            x4: Float(config.multibandX4Hz)
        )
        self.multibandX1Hz = crossovers.x1
        self.multibandX2Hz = crossovers.x2
        self.multibandX3Hz = crossovers.x3
        self.multibandX4Hz = crossovers.x4
        self.multibandLowThresholdDB = Float(config.multibandLowThresholdDB)
        self.multibandMidThresholdDB = Float(config.multibandMidThresholdDB)
        self.multibandHighThresholdDB = Float(config.multibandHighThresholdDB)
        self.multibandLowRatio = Float(config.multibandLowRatio)
        self.multibandMidRatio = Float(config.multibandMidRatio)
        self.multibandHighRatio = Float(config.multibandHighRatio)
        self.multibandLowAttackMS = Float(config.multibandLowAttackMS)
        self.multibandMidAttackMS = Float(config.multibandMidAttackMS)
        self.multibandHighAttackMS = Float(config.multibandHighAttackMS)
        self.multibandLowReleaseMS = Float(config.multibandLowReleaseMS)
        self.multibandMidReleaseMS = Float(config.multibandMidReleaseMS)
        self.multibandHighReleaseMS = Float(config.multibandHighReleaseMS)

        self.multibandLimiterEnabled = config.multibandLimiterEnabled
        self.multibandLimiterThresholdDB = clampf(Float(config.multibandLimiterThresholdDB), -20.0, 0.0)
        self.multibandLimiterAttackMS = clampf(Float(config.multibandLimiterAttackMS), 0.01, 10.0)
        self.multibandLimiterReleaseMS = clampf(Float(config.multibandLimiterReleaseMS), 10.0, 500.0)

        self.downwardExpanderEnabled = config.downwardExpanderEnabled
        self.expanderThresholdDB = clampf(Float(config.expanderThresholdDB), -60.0, -20.0)
        self.expanderRatio = clampf(Float(config.expanderRatio), 1.0, 8.0)
        self.expanderAttackMS = clampf(Float(config.expanderAttackMS), 0.1, 100.0)
        self.expanderReleaseMS = clampf(Float(config.expanderReleaseMS), 10.0, 2000.0)

        self.bassClipperEnabled = config.bassClipperEnabled
        self.bassClipperCrossoverHz = clampf(Float(config.bassClipperCrossoverHz), 60.0, 300.0)
        self.bassClipperThresholdDB = clampf(Float(config.bassClipperThresholdDB), -12.0, 0.0)
        self.bassClipperDrive = clampf(Float(config.bassClipperDrive), 0.5, 3.0)

        self.dcClipperEnabled = config.dcClipperEnabled
        self.dcClipperCeilingDB = clampf(Float(config.dcClipperCeilingDB), -6.0, 0.0)
        self.dcClipperCancelFreqHz = clampf(Float(config.dcClipperCancelFreqHz), 500.0, 4000.0)

        self.bs412Enabled = config.bs412Enabled
        self.bs412ThresholdDB = clampf(Float(config.bs412ThresholdDB), -20.0, 0.0)
        self.bs412WindowSeconds = clampf(Float(config.bs412WindowSeconds), 1.0, 120.0)
        self.compositeClipperEnabled = config.compositeClipperEnabled
        self.compositeClipperThresholdDB = clampf(Float(config.compositeClipperThresholdDB), -12.0, 0.0)
        self.compositeClipperCeilingDB = clampf(Float(config.compositeClipperCeilingDB), -6.0, 0.0)
        self.compositeClipperCancelAudio = config.compositeClipperCancelAudio
        self.compositeClipperCancelStereo = config.compositeClipperCancelStereo
        self.compositeClipperCancelPilot = config.compositeClipperCancelPilot
        self.compositeClipperCancelRDS = config.compositeClipperCancelRDS

        self.stereoWidenEnabled = config.stereoWidenEnabled
        self.monoBassEnabled = config.monoBassEnabled
        self.monoBassFreqHz = clampf(Float(config.monoBassFreqHz), 60.0, 250.0)
        self.widenWidth = clampf(Float(config.stereoWidenWidth), 0.0, 1.0)
        self.widenCenter = clampf(Float(config.stereoWidenCenter), 0.0, 1.0)
        self.widenMix = clampf(Float(config.stereoWidenMix), 0.0, 1.0)
        self.rdsCoder = BasicRDSCoder(
            config: config,
            sampleRate: self.sampleRate,
            nowPlayingState: nowPlayingState
        )

        self.toneStep = 0.0

        preL.configure(tauUS: preemphasisUS, sampleRate: self.sampleRate)
        preR.configure(tauUS: preemphasisUS, sampleRate: self.sampleRate)
        applyEncoderComplianceConfiguration(sampleRate: self.sampleRate)

        widebandAGC.configure(
            sampleRate: self.sampleRate,
            targetDB: widebandAGCTargetDB,
            attackMS: widebandAGCAttackMS,
            releaseMS: widebandAGCReleaseMS,
            minGainDB: widebandAGCMinGainDB,
            maxGainDB: widebandAGCMaxGainDB,
            kWeightingEnabled: widebandAGCKWeightingEnabled,
            programDependentRelease: widebandAGCReleaseProgramDependent
        )
        inputHPF.configureHighpass(cutoffHz: hpfHz, sampleRate: self.sampleRate)
        hfTrim.configureHighShelf(gainDB: hfTrimDB, cutoffHz: hfTrimHz, sampleRate: self.sampleRate)
        phaseRotator.configure(freqHz: phaseRotationFreqHz, sampleRate: self.sampleRate)
        configureParametricEQ()
        configurePrimeBassFilters()
        configureMultibandFilters()
        configureMultibandCompressors()
        configureMultibandLimiters()
        configureDownwardExpanders()
        configureStereoWidener()
        bassClipper.configure(
            sampleRate: self.sampleRate,
            crossoverHz: bassClipperCrossoverHz,
            thresholdDB: bassClipperThresholdDB,
            drive: bassClipperDrive
        )
        configureDistortionCancelledClipper()
        lookaheadLimiter.configure(
            sampleRate: self.sampleRate,
            lookaheadMS: limitLookaheadMS,
            threshold: threshold,
            enabled: limitEnabled && limitLookaheadEnabled
        )
        preEncodeThreshold = clampf(Float(config.preEncodeThreshold), 0.5, 0.999)
        preEncodeReleaseMS = clampf(Float(config.preEncodeReleaseMS), 10.0, 200.0)
        preEncodeAudioLimiter.configure(
            sampleRate: self.sampleRate,
            threshold: preEncodeThreshold,
            releaseMS: preEncodeReleaseMS
        )
        bs412Limiter.configure(
            sampleRate: self.sampleRate,
            thresholdDB: bs412ThresholdDB,
            windowSeconds: bs412WindowSeconds
        )
        compositeClipper.configure(
            sampleRate: self.sampleRate,
            thresholdDB: compositeClipperThresholdDB,
            ceilingDB: compositeClipperCeilingDB,
            cancelAudio: compositeClipperCancelAudio,
            cancelStereo: compositeClipperCancelStereo,
            cancelPilot: compositeClipperCancelPilot,
            cancelRDS: compositeClipperCancelRDS
        )
        updateDerivedRates()
        configureMonitorDemod()
    }

    /// Called by AudioOutputEngine at start() to pick the TX-grade FIR or
    /// low-latency Butterworth for the encoder program lowpass, based on the
    /// engine's output mode (composite/monitor) and the user's config toggle.
    func setEncoderFIREnabled(_ enabled: Bool) {
        if enabled == useEncoderFIR { return }
        useEncoderFIR = enabled
        encoderProgramLP.configure(
            cutoffHz: effectiveEncoderLowpassHz(configured: programLowpassHz, preemphasisUS: preemphasisUS),
            sampleRate: sampleRate
        )
        encoderProgramFIR.configure(
            cutoffHz: effectiveEncoderLowpassHz(configured: programLowpassHz, preemphasisUS: preemphasisUS),
            sampleRate: sampleRate
        )
    }

    var encoderFIRTapCount: Int { encoderProgramFIR.tapCount }
    var encoderFIRGroupDelaySamples: Int { encoderProgramFIR.groupDelaySamples }

    /// Called by AudioOutputEngine at start() to pick linear-phase FIR
    /// multiband crossovers (TX) over IIR LR4 (monitor). Phase-flat
    /// reconstruction kills the transient-smear / inter-band-pumping
    /// artifacts that make multiband sound worse than single-band on
    /// percussive content.
    func setMultibandFIREnabled(_ enabled: Bool) {
        if enabled == useMultibandFIR { return }
        useMultibandFIR = enabled
        configureMultibandFilters()
    }

    var multibandFIRGroupDelaySamples: Int {
        useMultibandFIR
            ? max(mb5FIRSplitter.groupDelaySamples, mb3FIRSplitter.groupDelaySamples)
            : 0
    }

    func setSampleRate(_ newSampleRate: Double) {
        let sr = Float(max(8_000.0, newSampleRate))
        if fabsf(sr - sampleRate) < 0.1 {
            return
        }
        sampleRate = sr
        preL.configure(tauUS: preemphasisUS, sampleRate: sampleRate)
        preR.configure(tauUS: preemphasisUS, sampleRate: sampleRate)
        applyEncoderComplianceConfiguration(sampleRate: sampleRate)
        widebandAGC.configure(
            sampleRate: sampleRate,
            targetDB: widebandAGCTargetDB,
            attackMS: widebandAGCAttackMS,
            releaseMS: widebandAGCReleaseMS,
            minGainDB: widebandAGCMinGainDB,
            maxGainDB: widebandAGCMaxGainDB
        )
        inputHPF.configureHighpass(cutoffHz: hpfHz, sampleRate: sampleRate)
        hfTrim.configureHighShelf(gainDB: hfTrimDB, cutoffHz: hfTrimHz, sampleRate: sampleRate)
        phaseRotator.configure(freqHz: phaseRotationFreqHz, sampleRate: sampleRate)
        configureParametricEQ()
        configurePrimeBassFilters()
        configureMultibandFilters()
        configureMultibandCompressors()
        configureMultibandLimiters()
        configureDownwardExpanders()
        configureStereoWidener()
        bassClipper.configure(
            sampleRate: sampleRate,
            crossoverHz: bassClipperCrossoverHz,
            thresholdDB: bassClipperThresholdDB,
            drive: bassClipperDrive
        )
        configureDistortionCancelledClipper()
        lookaheadLimiter.configure(
            sampleRate: sampleRate,
            lookaheadMS: limitLookaheadMS,
            threshold: threshold,
            enabled: limitEnabled && limitLookaheadEnabled
        )
        preEncodeAudioLimiter.configure(
            sampleRate: sampleRate,
            threshold: preEncodeThreshold,
            releaseMS: preEncodeReleaseMS
        )
        bs412Limiter.configure(
            sampleRate: sampleRate,
            thresholdDB: bs412ThresholdDB,
            windowSeconds: bs412WindowSeconds
        )
        compositeClipper.configure(
            sampleRate: sampleRate,
            thresholdDB: compositeClipperThresholdDB,
            ceilingDB: compositeClipperCeilingDB,
            cancelAudio: compositeClipperCancelAudio,
            cancelStereo: compositeClipperCancelStereo,
            cancelPilot: compositeClipperCancelPilot,
            cancelRDS: compositeClipperCancelRDS
        )
        rdsCoder?.setSampleRate(sampleRate)
        updateDerivedRates()
        configureMonitorDemod()
    }

    func applyRuntimeConfig(_ config: RuntimeConfig) {
        inputGain = powf(10.0, config.inputGainDB / 20.0)
        outputGain = powf(10.0, config.outputGainDB / 20.0)
        finalDrive = powf(10.0, config.finalDriveDB / 20.0)
        deviationScale = config.mpxDeviationKHz / 75.0
        preEncodeAudioLimiterEnabled = config.preEncodeAudioLimiterEnabled

        let agcChanged =
            widebandAGCEnabled != config.widebandAGCEnabled
            || fabsf(widebandAGCTargetDB - config.widebandAGCTargetDB) > 0.0001
            || fabsf(widebandAGCMaxGainDB - config.widebandAGCMaxGainDB) > 0.0001
            || fabsf(widebandAGCMinGainDB - config.widebandAGCMinGainDB) > 0.0001
            || fabsf(widebandAGCAttackMS - config.widebandAGCAttackMS) > 0.0001
            || fabsf(widebandAGCReleaseMS - config.widebandAGCReleaseMS) > 0.0001

        widebandAGCEnabled = config.widebandAGCEnabled
        widebandAGCTargetDB = config.widebandAGCTargetDB
        widebandAGCMaxGainDB = config.widebandAGCMaxGainDB
        widebandAGCMinGainDB = config.widebandAGCMinGainDB
        widebandAGCAttackMS = config.widebandAGCAttackMS
        widebandAGCReleaseMS = config.widebandAGCReleaseMS

        let agcFlagsChanged =
            widebandAGCKWeightingEnabled != config.widebandAGCKWeightingEnabled
            || widebandAGCReleaseProgramDependent != config.widebandAGCReleaseProgramDependent
        widebandAGCKWeightingEnabled = config.widebandAGCKWeightingEnabled
        widebandAGCReleaseProgramDependent = config.widebandAGCReleaseProgramDependent

        if agcChanged || agcFlagsChanged {
            widebandAGC.configure(
                sampleRate: sampleRate,
                targetDB: widebandAGCTargetDB,
                attackMS: widebandAGCAttackMS,
                releaseMS: widebandAGCReleaseMS,
                minGainDB: widebandAGCMinGainDB,
                maxGainDB: widebandAGCMaxGainDB,
                kWeightingEnabled: widebandAGCKWeightingEnabled,
                programDependentRelease: widebandAGCReleaseProgramDependent
            )
        }

        let primeBassFiltersChanged =
            primeBassEnabled != config.primeBassEnabled
            || fabsf(primeBassFreqHz - config.primeBassFreqHz) > 0.0001
        primeBassEnabled = config.primeBassEnabled
        primeBassAmount = clampf(config.primeBassAmount, 0.0, 1.0)
        primeBassHarmonics = clampf(config.primeBassHarmonics, 0.0, 1.0)
        primeBassDrive = clampf(config.primeBassDrive, 0.0, 2.5)
        primeBassDensity = clampf(config.primeBassDensity, 0.0, 1.0)
        primeBassSubharmonicsEnabled = config.primeBassSubharmonicsEnabled
        primeBassSubharmonicsAmount = clampf(config.primeBassSubharmonicsAmount, 0.0, 1.0)
        primeBassFreqHz = clampf(config.primeBassFreqHz, 45.0, 220.0)
        if primeBassFiltersChanged {
            configurePrimeBassFilters()
        }

        let stereoImageChanged =
            stereoWidenEnabled != config.stereoWidenEnabled
            || monoBassEnabled != config.monoBassEnabled
            || fabsf(monoBassFreqHz - config.monoBassFreqHz) > 0.0001
            || fabsf(widenWidth - config.widenWidth) > 0.0001
            || fabsf(widenCenter - config.widenCenter) > 0.0001
            || fabsf(widenMix - config.widenMix) > 0.0001
        stereoWidenEnabled = config.stereoWidenEnabled
        monoBassEnabled = config.monoBassEnabled
        monoBassFreqHz = clampf(config.monoBassFreqHz, 60.0, 250.0)
        widenWidth = clampf(config.widenWidth, 0.0, 1.0)
        widenCenter = clampf(config.widenCenter, 0.0, 1.0)
        widenMix = clampf(config.widenMix, 0.0, 1.0)
        if stereoImageChanged {
            configureStereoWidener()
        }

        let resolvedCrossovers = Self.resolveMultibandCrossovers(
            sampleRate: sampleRate,
            x1: config.multibandX1Hz,
            x2: config.multibandX2Hz,
            x3: config.multibandX3Hz,
            x4: config.multibandX4Hz
        )
        let multibandStructureChanged =
            multibandEnabled != config.multibandEnabled
            || multibandMode != (config.multibandMode == 5 ? 5 : 3)
            || fabsf(multibandX1Hz - resolvedCrossovers.x1) > 0.0001
            || fabsf(multibandX2Hz - resolvedCrossovers.x2) > 0.0001
            || fabsf(multibandX3Hz - resolvedCrossovers.x3) > 0.0001
            || fabsf(multibandX4Hz - resolvedCrossovers.x4) > 0.0001
        let multibandCompressorChanged =
            fabsf(multibandKneeDB - config.multibandKneeDB) > 0.0001
            || multibandReleaseProgramDependent != config.multibandReleaseProgramDependent
            || fabsf(multibandLowThresholdDB - config.multibandLowThresholdDB) > 0.0001
            || fabsf(multibandMidThresholdDB - config.multibandMidThresholdDB) > 0.0001
            || fabsf(multibandHighThresholdDB - config.multibandHighThresholdDB) > 0.0001
            || fabsf(multibandLowRatio - config.multibandLowRatio) > 0.0001
            || fabsf(multibandMidRatio - config.multibandMidRatio) > 0.0001
            || fabsf(multibandHighRatio - config.multibandHighRatio) > 0.0001
            || fabsf(multibandLowAttackMS - config.multibandLowAttackMS) > 0.0001
            || fabsf(multibandMidAttackMS - config.multibandMidAttackMS) > 0.0001
            || fabsf(multibandHighAttackMS - config.multibandHighAttackMS) > 0.0001
            || fabsf(multibandLowReleaseMS - config.multibandLowReleaseMS) > 0.0001
            || fabsf(multibandMidReleaseMS - config.multibandMidReleaseMS) > 0.0001
            || fabsf(multibandHighReleaseMS - config.multibandHighReleaseMS) > 0.0001
        multibandEnabled = config.multibandEnabled
        multibandMode = (config.multibandMode == 5) ? 5 : 3
        multibandMakeup = powf(10.0, config.multibandMakeupDB / 20.0)
        multibandKneeDB = clampf(config.multibandKneeDB, 0.0, 12.0)
        multibandLinkStrength = clampf(config.multibandLinkStrength, 0.0, 1.0)
        multibandReleaseProgramDependent = config.multibandReleaseProgramDependent
        multibandX1Hz = resolvedCrossovers.x1
        multibandX2Hz = resolvedCrossovers.x2
        multibandX3Hz = resolvedCrossovers.x3
        multibandX4Hz = resolvedCrossovers.x4
        multibandLowThresholdDB = config.multibandLowThresholdDB
        multibandMidThresholdDB = config.multibandMidThresholdDB
        multibandHighThresholdDB = config.multibandHighThresholdDB
        multibandLowRatio = config.multibandLowRatio
        multibandMidRatio = config.multibandMidRatio
        multibandHighRatio = config.multibandHighRatio
        multibandLowAttackMS = config.multibandLowAttackMS
        multibandMidAttackMS = config.multibandMidAttackMS
        multibandHighAttackMS = config.multibandHighAttackMS
        multibandLowReleaseMS = config.multibandLowReleaseMS
        multibandMidReleaseMS = config.multibandMidReleaseMS
        multibandHighReleaseMS = config.multibandHighReleaseMS
        if multibandStructureChanged {
            configureMultibandFilters()
        }
        if multibandStructureChanged || multibandCompressorChanged {
            configureMultibandCompressors()
        }

        // Phase rotator
        let phaseRotChanged =
            phaseRotationEnabled != config.phaseRotationEnabled
            || fabsf(phaseRotationFreqHz - config.phaseRotationFreqHz) > 0.0001
        phaseRotationEnabled = config.phaseRotationEnabled
        phaseRotationFreqHz = clampf(config.phaseRotationFreqHz, 50.0, 500.0)
        if phaseRotChanged {
            phaseRotator.configure(freqHz: phaseRotationFreqHz, sampleRate: sampleRate)
        }

        // Parametric EQ
        let peqChanged =
            parametricEQEnabled != config.parametricEQEnabled
            || fabsf(peqB1FreqHz - config.peqB1FreqHz) > 0.0001
            || fabsf(peqB1GainDB - config.peqB1GainDB) > 0.0001
            || fabsf(peqB2FreqHz - config.peqB2FreqHz) > 0.0001
            || fabsf(peqB2GainDB - config.peqB2GainDB) > 0.0001
            || fabsf(peqB2Q - config.peqB2Q) > 0.0001
            || fabsf(peqB3FreqHz - config.peqB3FreqHz) > 0.0001
            || fabsf(peqB3GainDB - config.peqB3GainDB) > 0.0001
            || fabsf(peqB3Q - config.peqB3Q) > 0.0001
            || fabsf(peqB4FreqHz - config.peqB4FreqHz) > 0.0001
            || fabsf(peqB4GainDB - config.peqB4GainDB) > 0.0001
        parametricEQEnabled = config.parametricEQEnabled
        peqB1FreqHz = clampf(config.peqB1FreqHz, 20.0, 500.0)
        peqB1GainDB = clampf(config.peqB1GainDB, -12.0, 12.0)
        peqB2FreqHz = clampf(config.peqB2FreqHz, 100.0, 5000.0)
        peqB2GainDB = clampf(config.peqB2GainDB, -12.0, 12.0)
        peqB2Q = clampf(config.peqB2Q, 0.1, 10.0)
        peqB3FreqHz = clampf(config.peqB3FreqHz, 500.0, 12000.0)
        peqB3GainDB = clampf(config.peqB3GainDB, -12.0, 12.0)
        peqB3Q = clampf(config.peqB3Q, 0.1, 10.0)
        peqB4FreqHz = clampf(config.peqB4FreqHz, 1000.0, 16000.0)
        peqB4GainDB = clampf(config.peqB4GainDB, -12.0, 12.0)
        if peqChanged {
            configureParametricEQ()
        }

        // Multiband limiter
        let mbLimChanged =
            multibandLimiterEnabled != config.multibandLimiterEnabled
            || fabsf(multibandLimiterThresholdDB - config.multibandLimiterThresholdDB) > 0.0001
            || fabsf(multibandLimiterAttackMS - config.multibandLimiterAttackMS) > 0.0001
            || fabsf(multibandLimiterReleaseMS - config.multibandLimiterReleaseMS) > 0.0001
        multibandLimiterEnabled = config.multibandLimiterEnabled
        multibandLimiterThresholdDB = clampf(config.multibandLimiterThresholdDB, -20.0, 0.0)
        multibandLimiterAttackMS = clampf(config.multibandLimiterAttackMS, 0.01, 10.0)
        multibandLimiterReleaseMS = clampf(config.multibandLimiterReleaseMS, 10.0, 500.0)
        if mbLimChanged {
            configureMultibandLimiters()
        }

        // Downward expander
        let expChanged =
            downwardExpanderEnabled != config.downwardExpanderEnabled
            || fabsf(expanderThresholdDB - config.expanderThresholdDB) > 0.0001
            || fabsf(expanderRatio - config.expanderRatio) > 0.0001
            || fabsf(expanderAttackMS - config.expanderAttackMS) > 0.0001
            || fabsf(expanderReleaseMS - config.expanderReleaseMS) > 0.0001
        downwardExpanderEnabled = config.downwardExpanderEnabled
        expanderThresholdDB = clampf(config.expanderThresholdDB, -60.0, -20.0)
        expanderRatio = clampf(config.expanderRatio, 1.0, 8.0)
        expanderAttackMS = clampf(config.expanderAttackMS, 0.1, 100.0)
        expanderReleaseMS = clampf(config.expanderReleaseMS, 10.0, 2000.0)
        if expChanged {
            configureDownwardExpanders()
        }

        // Bass clipper
        let bassClipChanged =
            bassClipperEnabled != config.bassClipperEnabled
            || fabsf(bassClipperCrossoverHz - config.bassClipperCrossoverHz) > 0.0001
            || fabsf(bassClipperThresholdDB - config.bassClipperThresholdDB) > 0.0001
            || fabsf(bassClipperDrive - config.bassClipperDrive) > 0.0001
        bassClipperEnabled = config.bassClipperEnabled
        bassClipperCrossoverHz = clampf(config.bassClipperCrossoverHz, 60.0, 300.0)
        bassClipperThresholdDB = clampf(config.bassClipperThresholdDB, -12.0, 0.0)
        bassClipperDrive = clampf(config.bassClipperDrive, 0.5, 3.0)
        if bassClipChanged {
            bassClipper.configure(
                sampleRate: sampleRate,
                crossoverHz: bassClipperCrossoverHz,
                thresholdDB: bassClipperThresholdDB,
                drive: bassClipperDrive
            )
        }

        // Distortion-cancelled clipper
        let dcClipChanged =
            dcClipperEnabled != config.dcClipperEnabled
            || fabsf(dcClipperCeilingDB - config.dcClipperCeilingDB) > 0.0001
            || fabsf(dcClipperCancelFreqHz - config.dcClipperCancelFreqHz) > 0.0001
        dcClipperEnabled = config.dcClipperEnabled
        dcClipperCeilingDB = clampf(config.dcClipperCeilingDB, -6.0, 0.0)
        dcClipperCancelFreqHz = clampf(config.dcClipperCancelFreqHz, 500.0, 4000.0)
        if dcClipChanged {
            configureDistortionCancelledClipper()
        }

        // BS.412
        let bs412Changed =
            bs412Enabled != config.bs412Enabled
            || fabsf(bs412ThresholdDB - config.bs412ThresholdDB) > 0.0001
            || fabsf(bs412WindowSeconds - config.bs412WindowSeconds) > 0.0001
        bs412Enabled = config.bs412Enabled
        bs412ThresholdDB = clampf(config.bs412ThresholdDB, -20.0, 0.0)
        bs412WindowSeconds = clampf(config.bs412WindowSeconds, 1.0, 120.0)
        if bs412Changed {
            bs412Limiter.configure(
                sampleRate: sampleRate,
                thresholdDB: bs412ThresholdDB,
                windowSeconds: bs412WindowSeconds
            )
        }

        let compClipChanged =
            compositeClipperEnabled != config.compositeClipperEnabled
            || fabsf(compositeClipperThresholdDB - config.compositeClipperThresholdDB) > 0.0001
            || fabsf(compositeClipperCeilingDB - config.compositeClipperCeilingDB) > 0.0001
            || compositeClipperCancelAudio != config.compositeClipperCancelAudio
            || compositeClipperCancelStereo != config.compositeClipperCancelStereo
            || compositeClipperCancelPilot != config.compositeClipperCancelPilot
            || compositeClipperCancelRDS != config.compositeClipperCancelRDS
        compositeClipperEnabled = config.compositeClipperEnabled
        compositeClipperThresholdDB = clampf(config.compositeClipperThresholdDB, -12.0, 0.0)
        compositeClipperCeilingDB = clampf(config.compositeClipperCeilingDB, -6.0, 0.0)
        compositeClipperCancelAudio = config.compositeClipperCancelAudio
        compositeClipperCancelStereo = config.compositeClipperCancelStereo
        compositeClipperCancelPilot = config.compositeClipperCancelPilot
        compositeClipperCancelRDS = config.compositeClipperCancelRDS
        if compClipChanged {
            compositeClipper.configure(
                sampleRate: sampleRate,
                thresholdDB: compositeClipperThresholdDB,
                ceilingDB: compositeClipperCeilingDB,
                cancelAudio: compositeClipperCancelAudio,
                cancelStereo: compositeClipperCancelStereo,
                cancelPilot: compositeClipperCancelPilot,
                cancelRDS: compositeClipperCancelRDS
            )
        }

        // Tone-generator parameters. Recompute `toneStep` when freq
        // changes (preserving phase across a freq update — no zero-
        // crossing artefacts on the change), `toneLevel` from dBFS.
        // Reset noise-state on type change so a Pink ↔ White switch
        // doesn't carry filter state across types.
        let newToneFreq = clampf(config.testToneFreq, 20.0, 20_000.0)
        if newToneFreq != toneFreq {
            toneFreq = newToneFreq
            toneStep = twoPi * toneFreq / sampleRate
        }
        let normalisedMode = config.testToneMode.lowercased()
        if ["mono", "stereo", "left", "right"].contains(normalisedMode) {
            toneMode = normalisedMode
        }
        let normalisedType = config.testToneType.lowercased()
        let typeChanged = normalisedType != toneType
        if ["sine", "pink", "white"].contains(normalisedType) {
            toneType = normalisedType
        }
        if typeChanged {
            // Clear pink filter state and re-prime the white-noise RNG
            // so a type switch lands cleanly without DC offset or stuck
            // pink filter values from the prior generator.
            pinkB0 = 0; pinkB1 = 0; pinkB2 = 0; pinkB3 = 0
            pinkB4 = 0; pinkB5 = 0; pinkB6 = 0
            tonePhase = 0
        }
        toneLevel = powf(10.0, clampf(config.testToneLevelDB, -60.0, 0.0) / 20.0)
    }

    func currentRDSLiveSnapshot() -> BasicRDSCoder.LiveSnapshot? {
        rdsCoder?.currentLiveSnapshot()
    }

    func applyRDSRuntimeConfig(_ config: RDSRuntimeConfig) {
        rdsCoder?.applyRDSRuntimeConfig(config)
    }

    private func makeEncoderComplianceConfig() -> EncoderComplianceConfig {
        let effectiveProgramLP = effectiveProgramLowpassHz(
            configured: programLowpassHz,
            preemphasisUS: preemphasisUS
        )
        let effectiveEncoderLP = effectiveEncoderLowpassHz(
            configured: effectiveProgramLP,
            preemphasisUS: preemphasisUS
        )
        return EncoderComplianceConfig(
            programLowpassHz: effectiveProgramLP,
            encoderLowpassHz: effectiveEncoderLP,
            hfGuardCrossoverHz: 6_200.0
        )
    }

    private func applyEncoderComplianceConfiguration(sampleRate: Float) {
        let config = makeEncoderComplianceConfig()
        programLP.configure(cutoffHz: config.programLowpassHz, sampleRate: sampleRate)
        encoderProgramLP.configure(cutoffHz: config.encoderLowpassHz, sampleRate: sampleRate)
        encoderProgramFIR.configure(cutoffHz: config.encoderLowpassHz, sampleRate: sampleRate)
        if preemphasisUS > 0 {
            pilotNotchL.configureNotch(freqHz: 19_000.0, sampleRate: sampleRate, q: 50.0)
            pilotNotchR.configureNotch(freqHz: 19_000.0, sampleRate: sampleRate, q: 50.0)
        } else {
            pilotNotchL.configureIdentity()
            pilotNotchR.configureIdentity()
        }
        encoderHFGuardSplit.configure(cutoffHz: config.hfGuardCrossoverHz, sampleRate: sampleRate)
    }

    var isProcessingBypassEnabled: Bool {
        processingBypass
    }

    var agcStatus: AGCStatus {
        let telemetry = widebandAGC.telemetry
        return AGCStatus(
            enabled: widebandAGCEnabled && !processingBypass,
            detectorDB: telemetry.detectorDB,
            gainDB: telemetry.gainDB,
            gateActive: telemetry.gateActive
        )
    }

    var finalLimiterStatus: FinalLimiterStatus {
        FinalLimiterStatus(
            enabled: (compositeClipperEnabled || preEncodeAudioLimiterEnabled) && !processingBypass,
            gainReductionDB: compositeClipperEnabled ? compositeClipper.gainReductionDB : 0.0,
            preEncodeGainReductionDB: preEncodeAudioLimiter.gainReductionDB,
            safetyGainReductionDB: (limitEnabled && !processingBypass)
                ? lookaheadLimiter.gainReductionDB : 0.0
        )
    }

    var compositeCalibrationStatus: CompositeCalibrationStatus {
        let calibration = Self.makeCompositeCalibration(
            audioPeakState: audioCompositePeakState,
            reservationEnv: subcarrierReservationEnv,
            outputGain: outputGain
        )
        return CompositeCalibrationStatus(
            pilotPercent: monoMode ? 0.0 : pilotInjectionPercent,
            rdsPercent: monoMode ? 0.0 : rdsInjectionPercent,
            audioPeak: calibration.audioPeak,
            budgetMarginDB: calibration.budgetMarginDB
        )
    }

    private func updateDerivedRates() {
        toneStep = twoPi * toneFreq / sampleRate
        pilotOsc.configure(freq: pilotFreq, sampleRate: sampleRate)
        let sr = max(8_000.0, sampleRate)
        audioCompositePeakDecayCoeff = expf(-1.0 / (0.250 * sr))
        subcarrierReservationAttackCoeff = expf(-1.0 / (0.0005 * sr))
        subcarrierReservationReleaseCoeff = expf(-1.0 / (0.012 * sr))
        encoderHFGuardEnv = 0.0
        encoderHFGuardGain = 1.0
        encoderHFGuardAttackCoeff = expf(-1.0 / (0.004 * sr))
        encoderHFGuardReleaseCoeff = expf(-1.0 / (0.080 * sr))
        let nyquist = (sampleRate * 0.5) - 100.0
        if audioCompositeSmootherRequested, nyquist > 56_000.0 {
            compositeAudioSmoother.configure(
                cutoffHz: min(54_000.0, nyquist - 1_500.0),
                sampleRate: sampleRate
            )
            compositeAudioSmootherEnabled = true
        } else {
            compositeAudioSmootherEnabled = false
            compositeAudioSmoother.state = 0.0
        }
        pilotSupported = nyquist > (pilotFreq + 100.0)
        stereoSubcarrierSupported = nyquist > (subcarrierFreq + 100.0)
        rdsSupported = nyquist > 57_100.0

        updateMonitorRecoveryRates()
        updatePrimeBassDynamicRates()
    }

    private func updateMonitorRecoveryRates() {
        let sr = max(8_000.0, sampleRate)
        monitorExpectedSideAttackCoeff = expf(-1.0 / (0.010 * sr))
        monitorExpectedSideReleaseCoeff = expf(-1.0 / (0.260 * sr))
        monitorProgramEnvAttackCoeff = expf(-1.0 / (0.010 * sr))
        monitorProgramEnvReleaseCoeff = expf(-1.0 / (0.180 * sr))
        monitorNoiseFloorRiseCoeff = expf(-1.0 / (3.0 * sr))
        monitorNoiseFloorFallCoeff = expf(-1.0 / (0.50 * sr))
        monitorNoiseGateAttackCoeff = expf(-1.0 / (0.006 * sr))
        monitorNoiseGateReleaseCoeff = expf(-1.0 / (0.140 * sr))
        monitorCollapseHoldThresholdSamples = max(1, Int((sr * 0.55).rounded()))
        monitorCollapseCooldownResetSamples = max(1, Int((sr * 2.0).rounded()))
    }

    private func updatePrimeBassDynamicRates() {
        let sr = max(8_000.0, sampleRate)
        let dt = 1.0 / sr
        // Slow level estimate, used by the gate-floor calculation at
        // function entry. ~1.1 s tracks the longer-term mid level for
        // the gate threshold without flickering on per-note dynamics.
        primeBassLevelAlpha = 1.0 - expf(-dt / 1.1)
        primeBassMakeupAttackCoeff = expf(-1.0 / ((45.0 * 0.001) * sr))
        primeBassMakeupReleaseCoeff = expf(-1.0 / ((220.0 * 0.001) * sr))
        // Big Bottom envelope follower (US 5,359,665). Fast attack so
        // the boost ramps up within the leading edge of a kick or
        // plucked-bass note (~10 ms); slow release so it extends over
        // the natural decay of the note (~300 ms) — that's the
        // patent's "envelope duration extension" behaviour.
        primeBassBigBottomAttackCoeff = expf(-1.0 / ((10.0 * 0.001) * sr))
        primeBassBigBottomReleaseCoeff = expf(-1.0 / ((300.0 * 0.001) * sr))
        // Werrbach dual-envelope transient detector. Fast envelope
        // follows the LF input quickly so its level reflects the
        // *current* attack; slow envelope tracks the recent baseline.
        // Their (fast − slow) / slow difference saturates positive on
        // onsets and decays to zero as the slow follower catches up —
        // ~50–150 ms post-attack. The asymmetric attack/release on
        // each follower keeps the response sharp at the leading edge
        // (fast attack) without letting it dip on cycle-by-cycle
        // valleys of a sustained tone (slower release).
        primeBassFastAttackCoeff = expf(-1.0 / ((5.0 * 0.001) * sr))
        primeBassFastReleaseCoeff = expf(-1.0 / ((30.0 * 0.001) * sr))
        primeBassSlowAttackCoeff = expf(-1.0 / ((50.0 * 0.001) * sr))
        primeBassSlowReleaseCoeff = expf(-1.0 / ((250.0 * 0.001) * sr))
    }

    private func configureStereoWidener() {
        let sr = max(8_000.0, sampleRate)
        monoBassSideLP.configureLowpass(cutoffHz: monoBassFreqHz, sampleRate: sr, q: 0.7071068)
        widenSideHP.configureHighpass(cutoffHz: 115.0, sampleRate: sr, q: 0.7071068)
        stereoProtectInputMidEnv = 0.0
        stereoProtectInputSideEnv = 0.0
        stereoProtectMidEnv = 0.0
        stereoProtectSideEnv = 0.0
        stereoProtectGain = 1.0
        stereoProtectAttackCoeff = expf(-1.0 / (0.010 * sr))
        stereoProtectReleaseCoeff = expf(-1.0 / (0.300 * sr))
    }

    private func configureMonitorDemod() {
        let sr = max(8_000.0, sampleRate)
        let nyquist = max(6_000.0, (sr * 0.5) - 200.0)

        monitorLPRLP.configureLowpass(cutoffHz: 15_500.0, sampleRate: sr)

        monitorDiffBandHP.configureHighpass(cutoffHz: 23_000.0, sampleRate: sr)
        let diffHigh = min(54_000.0, nyquist)
        if diffHigh > 24_000.0 {
            monitorDiffBandLP.configureLowpass(cutoffHz: diffHigh, sampleRate: sr)
        } else {
            monitorDiffBandLP.configureIdentity()
        }

        monitorDiffLP.configureLowpass(cutoffHz: 15_500.0, sampleRate: sr)

        if nyquist > (pilotFreq + 100.0) {
            monitorRFNotchPilot.configureNotch(freqHz: pilotFreq, sampleRate: sr, q: 18.0)
            monitorPilotNotchL.configureNotch(freqHz: pilotFreq, sampleRate: sr, q: 24.0)
            monitorPilotNotchR.configureNotch(freqHz: pilotFreq, sampleRate: sr, q: 24.0)
        } else {
            monitorRFNotchPilot.configureIdentity()
            monitorPilotNotchL.configureIdentity()
            monitorPilotNotchR.configureIdentity()
        }

        if nyquist > 57_100.0 {
            monitorRFNotchRDS.configureNotch(freqHz: 57_000.0, sampleRate: sr, q: 22.0)
        } else {
            monitorRFNotchRDS.configureIdentity()
        }

        monitorDeemphasisL.configure(tauUS: preemphasisUS, sampleRate: sr)
        monitorDeemphasisR.configure(tauUS: preemphasisUS, sampleRate: sr)
        lastSubcarrierSample = 0.0
        monitorNoiseGateGain = 0.0
        monitorNoiseGateOpen = false
        lastProgramActivity = 0.0
        monitorProgramEnv = 0.0
        monitorProgramNoiseFloor = 0.0
        monitorCollapseHoldSamples = 0
    }

    private func demodulateMonitorFromMPXSample(_ mpx: Float) -> (Float, Float) {
        var monSrc = monitorRFNotchPilot.process(mpx)
        monSrc = monitorRFNotchRDS.process(monSrc)

        let lpr = monitorLPRLP.process(monSrc)

        let dsbHP = monitorDiffBandHP.process(monSrc)
        let dsb = monitorDiffBandLP.process(dsbHP)
        var diff = 2.0 * dsb * lastSubcarrierSample
        diff = monitorDiffLP.process(diff)
        diff *= Self.monitorDiffDecodeGain
        diff = -diff

        var left = lpr + diff
        var right = lpr - diff

        left = monitorPilotNotchL.process(left)
        right = monitorPilotNotchR.process(right)
        left = monitorDeemphasisL.process(left)
        right = monitorDeemphasisR.process(right)

        let activity = max(0.0, lastProgramActivity)

        let envCoeff =
            activity > monitorProgramEnv ? monitorProgramEnvAttackCoeff : monitorProgramEnvReleaseCoeff
        monitorProgramEnv = (envCoeff * monitorProgramEnv) + ((1.0 - envCoeff) * activity)

        // Track the long-term idle floor to reject ADC hiss when no real program is present.
        let floorTarget = monitorProgramEnv
        if !monitorNoiseGateOpen || floorTarget <= (monitorProgramNoiseFloor * 1.4) {
            let floorCoeff =
                floorTarget > monitorProgramNoiseFloor
                ? monitorNoiseFloorRiseCoeff : monitorNoiseFloorFallCoeff
            monitorProgramNoiseFloor =
                (floorCoeff * monitorProgramNoiseFloor) + ((1.0 - floorCoeff) * floorTarget)
        }

        let openThreshold = max(0.00016, monitorProgramNoiseFloor * 2.3)
        let closeThreshold = max(0.00008, monitorProgramNoiseFloor * 1.6)
        if monitorNoiseGateOpen {
            if monitorProgramEnv < closeThreshold {
                monitorNoiseGateOpen = false
            }
        } else if monitorProgramEnv > openThreshold {
            monitorNoiseGateOpen = true
        }
        let targetGain: Float = monitorNoiseGateOpen ? 1.0 : 0.0
        let coeff =
            targetGain > monitorNoiseGateGain ? monitorNoiseGateAttackCoeff : monitorNoiseGateReleaseCoeff
        monitorNoiseGateGain = (coeff * monitorNoiseGateGain) + ((1.0 - coeff) * targetGain)
        left *= monitorNoiseGateGain
        right *= monitorNoiseGateGain

        // Auto-recover demod state if decoded stereo collapses while encoded side persists.
        if monitorCollapseCooldownSamples > 0 {
            monitorCollapseCooldownSamples -= 1
        }
        let outSideAbs = fabsf((left - right) * 0.5)
        let expectedSide = monitorExpectedSideEnv
        let sidePresent = expectedSide > max(0.0012, monitorProgramEnv * 0.08)
        let collapsed = outSideAbs < (expectedSide * 0.12)
        if sidePresent && collapsed {
            monitorCollapseHoldSamples += 1
            if monitorCollapseCooldownSamples <= 0,
                monitorCollapseHoldSamples > monitorCollapseHoldThresholdSamples
            {
                configureMonitorDemod()
                monitorCollapseCooldownSamples = monitorCollapseCooldownResetSamples
                monitorCollapseHoldSamples = 0
            }
        } else {
            monitorCollapseHoldSamples = max(0, monitorCollapseHoldSamples - 1)
        }

        return (clampf(left, -1.0, 1.0), clampf(right, -1.0, 1.0))
    }

    private func configurePrimeBassFilters() {
        let nyquist = max(200.0, (sampleRate * 0.5) - 200.0)
        let bassCutoff = clampf(primeBassFreqHz, 45.0, nyquist)
        primeBassLP.configure(cutoffHz: bassCutoff, sampleRate: sampleRate)
        let subCutoff = clampf(max(45.0, primeBassFreqHz * 0.8), 45.0, nyquist)
        primeBassSubLP.configure(cutoffHz: subCutoff, sampleRate: sampleRate)
        let harmHPFCutoff = clampf(max(120.0, primeBassFreqHz * 1.6), 45.0, nyquist)
        let harmLPFMin = min(nyquist - 20.0, max(harmHPFCutoff + 20.0, 280.0))
        let harmLPFCutoff = clampf(max(280.0, primeBassFreqHz * 5.0), harmLPFMin, nyquist)
        primeBassHarmHPF.configureHighpass(cutoffHz: harmHPFCutoff, sampleRate: sampleRate)
        primeBassHarmLPF.configureLowpass(cutoffHz: harmLPFCutoff, sampleRate: sampleRate)

        // Aphex-style phase-shifting allpass at F0 (Q=0.7 for ~180°
        // shift across F0 with unit magnitude). The waveshaper sees a
        // phase-rotated copy of the LF, so the synthesized harmonics
        // are phase-decorrelated from the direct lowboost path.
        primeBassSideAP.configureAllpass(freqHz: bassCutoff, sampleRate: sampleRate)

        // MaxxBass equal-loudness weighting (US 5,930,373). Compute
        // per-order perceptual weights at the harmonic frequencies of
        // the configured PrimeBass cutoff and combine into two scalars:
        // one for the even-harmonic generator (2nd + 4th) and one for
        // the odd-harmonic generator (3rd + 5th). Weights are biased
        // by the relative perceptual contribution of each harmonic
        // order to "missing-fundamental" reconstruction (3rd > 2nd >
        // 4th > 5th in the 80-300 Hz warmth band).
        let f0 = clampf(primeBassFreqHz, 45.0, 200.0)
        let w2 = Self.primeBassEqualLoudnessWeight(2.0 * f0)
        let w3 = Self.primeBassEqualLoudnessWeight(3.0 * f0)
        let w4 = Self.primeBassEqualLoudnessWeight(4.0 * f0)
        let w5 = Self.primeBassEqualLoudnessWeight(5.0 * f0)
        primeBassHarmEvenWeight = 0.5 * (w2 + (0.4 * w4))
        primeBassHarmOddWeight = 0.5 * (w3 + (0.4 * w5))
    }

    /// Approximation of the ISO 226 (40 phon) inverse-threshold
    /// equal-loudness curve over 60-600 Hz, returned as a unit-bounded
    /// perceptual weight. Peaks near 150 Hz (the warmth band where
    /// missing-fundamental reconstruction is strongest), falls off
    /// below 60 Hz (sub-bass loses sensitivity at low SPL) and above
    /// 500 Hz (no longer in the bass-extension band). Used to weight
    /// the synthesized harmonics in MaxxBass-style bass enhancement.
    @inline(__always)
    private static func primeBassEqualLoudnessWeight(_ f: Float) -> Float {
        let logF = log10f(max(20.0, f))
        // Bell curve centered at log10(150) ≈ 2.176.
        let center: Float = 2.176
        let width: Float = 0.55
        let dx = (logF - center) / width
        return 0.85 * expf(-(dx * dx))
    }

    private func configureMultibandFilters() {
        let x1 = clampf(multibandX1Hz, 40.0, max(60.0, (sampleRate * 0.5) - 300.0))
        let x2 = clampf(multibandX2Hz, x1 + 40.0, max(x1 + 60.0, (sampleRate * 0.5) - 200.0))
        let x3 = clampf(multibandX3Hz, x2 + 80.0, max(x2 + 100.0, (sampleRate * 0.5) - 120.0))
        let x4 = clampf(multibandX4Hz, x3 + 120.0, max(x3 + 140.0, (sampleRate * 0.5) - 60.0))

        mb3Split1.configure(cutoffHz: x1, sampleRate: sampleRate)
        mb3Split2.configure(cutoffHz: x2, sampleRate: sampleRate)

        mb5Split1.configure(cutoffHz: x1, sampleRate: sampleRate)
        mb5Split2.configure(cutoffHz: x2, sampleRate: sampleRate)
        mb5Split3.configure(cutoffHz: x3, sampleRate: sampleRate)
        mb5Split4.configure(cutoffHz: x4, sampleRate: sampleRate)

        // Linear-phase FIR splitters (TX mode). Stop-band 60 dB,
        // transition band scaled to the lowest crossover so the longest
        // FIR (lp1 at x1) sets a reasonable tap budget. At 192 kHz with
        // x1 = 90 Hz and transition = 1.5 kHz, the Kaiser estimate yields
        // ~310 taps = ~155 sample group delay = ~0.81 ms.
        let firTransition = max(1_000.0, x1 * 0.6)
        if useMultibandFIR {
            mb3FIRSplitter.configure(
                lowHz: x1, highHz: x2,
                sampleRate: sampleRate,
                stopBandDB: 60.0,
                transitionHz: firTransition
            )
            mb5FIRSplitter.configure(
                x1Hz: x1, x2Hz: x2, x3Hz: x3, x4Hz: x4,
                sampleRate: sampleRate,
                stopBandDB: 60.0,
                transitionHz: firTransition
            )
        }
    }

    private func configureMultibandCompressors() {
        configureCompressorPair(
            left: &mbLowCompL,
            right: &mbLowCompR,
            thresholdDB: multibandLowThresholdDB,
            ratio: multibandLowRatio,
            attackMS: multibandLowAttackMS,
            releaseMS: releaseAdjusted(multibandLowReleaseMS)
        )
        configureCompressorPair(
            left: &mbMidCompL,
            right: &mbMidCompR,
            thresholdDB: multibandMidThresholdDB,
            ratio: multibandMidRatio,
            attackMS: multibandMidAttackMS,
            releaseMS: releaseAdjusted(multibandMidReleaseMS)
        )
        configureCompressorPair(
            left: &mbHighCompL,
            right: &mbHighCompR,
            thresholdDB: multibandHighThresholdDB,
            ratio: multibandHighRatio,
            attackMS: multibandHighAttackMS,
            releaseMS: releaseAdjusted(multibandHighReleaseMS)
        )

        let t2 = lerpf(multibandLowThresholdDB, multibandMidThresholdDB, 0.5)
        let t4 = lerpf(multibandMidThresholdDB, multibandHighThresholdDB, 0.5)
        let r2 = lerpf(multibandLowRatio, multibandMidRatio, 0.5)
        let r4 = lerpf(multibandMidRatio, multibandHighRatio, 0.5)
        let a2 = lerpf(multibandLowAttackMS, multibandMidAttackMS, 0.5)
        let a4 = lerpf(multibandMidAttackMS, multibandHighAttackMS, 0.5)
        let rel2 = releaseAdjusted(lerpf(multibandLowReleaseMS, multibandMidReleaseMS, 0.5))
        let rel4 = releaseAdjusted(lerpf(multibandMidReleaseMS, multibandHighReleaseMS, 0.5))

        configureCompressorPair(
            left: &mb5Comp1L,
            right: &mb5Comp1R,
            thresholdDB: multibandLowThresholdDB,
            ratio: multibandLowRatio,
            attackMS: multibandLowAttackMS,
            releaseMS: releaseAdjusted(multibandLowReleaseMS)
        )
        configureCompressorPair(
            left: &mb5Comp2L,
            right: &mb5Comp2R,
            thresholdDB: t2,
            ratio: r2,
            attackMS: a2,
            releaseMS: rel2
        )
        configureCompressorPair(
            left: &mb5Comp3L,
            right: &mb5Comp3R,
            thresholdDB: multibandMidThresholdDB,
            ratio: multibandMidRatio,
            attackMS: multibandMidAttackMS,
            releaseMS: releaseAdjusted(multibandMidReleaseMS)
        )
        configureCompressorPair(
            left: &mb5Comp4L,
            right: &mb5Comp4R,
            thresholdDB: t4,
            ratio: r4,
            attackMS: a4,
            releaseMS: rel4
        )
        configureCompressorPair(
            left: &mb5Comp5L,
            right: &mb5Comp5R,
            thresholdDB: multibandHighThresholdDB,
            ratio: multibandHighRatio,
            attackMS: multibandHighAttackMS,
            releaseMS: releaseAdjusted(multibandHighReleaseMS)
        )
    }

    private func releaseAdjusted(_ releaseMS: Float) -> Float {
        if multibandReleaseProgramDependent {
            return releaseMS * 1.1
        }
        return releaseMS
    }

    private func configureCompressorPair(
        left: inout MonoCompressor,
        right: inout MonoCompressor,
        thresholdDB: Float,
        ratio: Float,
        attackMS: Float,
        releaseMS: Float
    ) {
        left.configure(
            sampleRate: sampleRate,
            thresholdDB: thresholdDB,
            ratio: ratio,
            attackMS: attackMS,
            releaseMS: releaseMS,
            makeupDB: 0.0,
            kneeDB: multibandKneeDB
        )
        right.configure(
            sampleRate: sampleRate,
            thresholdDB: thresholdDB,
            ratio: ratio,
            attackMS: attackMS,
            releaseMS: releaseMS,
            makeupDB: 0.0,
            kneeDB: multibandKneeDB
        )
    }

    private func configureParametricEQ() {
        parametricEQ.configure(
            sampleRate: sampleRate,
            b1FreqHz: peqB1FreqHz, b1GainDB: peqB1GainDB,
            b2FreqHz: peqB2FreqHz, b2GainDB: peqB2GainDB, b2Q: peqB2Q,
            b3FreqHz: peqB3FreqHz, b3GainDB: peqB3GainDB, b3Q: peqB3Q,
            b4FreqHz: peqB4FreqHz, b4GainDB: peqB4GainDB
        )
    }

    private func configureMultibandLimiters() {
        let thr = multibandLimiterThresholdDB
        let atk = multibandLimiterAttackMS
        let rel = multibandLimiterReleaseMS
        mbLimLow.configure(sampleRate: sampleRate, thresholdDB: thr, attackMS: atk, releaseMS: rel)
        mbLimMid.configure(sampleRate: sampleRate, thresholdDB: thr, attackMS: atk, releaseMS: rel)
        mbLimHigh.configure(sampleRate: sampleRate, thresholdDB: thr, attackMS: atk, releaseMS: rel)
        mbLim5B1.configure(sampleRate: sampleRate, thresholdDB: thr, attackMS: atk, releaseMS: rel)
        mbLim5B2.configure(sampleRate: sampleRate, thresholdDB: thr, attackMS: atk, releaseMS: rel)
        mbLim5B3.configure(sampleRate: sampleRate, thresholdDB: thr, attackMS: atk, releaseMS: rel)
        mbLim5B4.configure(sampleRate: sampleRate, thresholdDB: thr, attackMS: atk, releaseMS: rel)
        mbLim5B5.configure(sampleRate: sampleRate, thresholdDB: thr, attackMS: atk, releaseMS: rel)
    }

    private func configureDownwardExpanders() {
        let thr = expanderThresholdDB
        let rat = expanderRatio
        let atk = expanderAttackMS
        let rel = expanderReleaseMS
        mbExpLow.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExpMid.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExpHigh.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B1.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B2.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B3.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B4.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B5.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
    }

    private func configureDistortionCancelledClipper() {
        dcClipper.configure(
            sampleRate: sampleRate,
            ceilingDB: dcClipperCeilingDB,
            cancelFreqHz: dcClipperCancelFreqHz
        )
    }

    /// Generate one tone-source sample. Switches between sine /
    /// pink / white based on `toneType`. Sine advances `tonePhase` by
    /// `toneStep` and wraps; noise paths use the engine's xorshift RNG
    /// + Paul Kellet's pink IIR. Output is unscaled; callers multiply
    /// by `toneLevel` for the final output amplitude.
    @inline(__always)
    private func nextToneRawSample() -> Float {
        switch toneType {
        case "white":
            return nextWhiteSample()
        case "pink":
            return nextPinkSample()
        default:
            let s = sinf(tonePhase)
            tonePhase += toneStep
            if tonePhase >= twoPi { tonePhase -= twoPi }
            return s
        }
    }

    /// xorshift64* white noise → uniform [-1, +1]. Single scalar
    /// state mutation per sample; cheap.
    @inline(__always)
    private func nextWhiteSample() -> Float {
        var x = toneNoiseRNG
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        toneNoiseRNG = x
        let mixed = x &* 0x2545_F491_4F6C_DD1D
        // Top 24 bits → float in [0, 1) → [-1, +1)
        let u = Float(mixed >> 40) / Float(1 << 24)
        return (u * 2.0) - 1.0
    }

    /// Paul Kellet's 4-pole pink-noise IIR (the well-known short
    /// recipe). Produces ~3 dB/octave rolloff from white noise. Cycle
    /// artefacts above ~10 kHz are acceptable for a test-tone source
    /// — operators use pink for broadband response checks, not for
    /// deterministic measurement.
    @inline(__always)
    private func nextPinkSample() -> Float {
        let white = nextWhiteSample()
        pinkB0 = 0.99886 * pinkB0 + white * 0.0555179
        pinkB1 = 0.99332 * pinkB1 + white * 0.0750759
        pinkB2 = 0.96900 * pinkB2 + white * 0.1538520
        pinkB3 = 0.86650 * pinkB3 + white * 0.3104856
        pinkB4 = 0.55000 * pinkB4 + white * 0.5329522
        pinkB5 = -0.7616 * pinkB5 - white * 0.0168980
        let pink = pinkB0 + pinkB1 + pinkB2 + pinkB3 + pinkB4 + pinkB5 + pinkB6 + white * 0.5362
        pinkB6 = white * 0.115926
        // The recipe yields peaks around ±3.5; scale to roughly ±1
        // so `toneLevel` interpretation matches the sine path.
        return pink * 0.11
    }

    private static func resolveMultibandCrossovers(
        sampleRate: Float,
        x1: Float,
        x2: Float,
        x3: Float,
        x4: Float
    ) -> (x1: Float, x2: Float, x3: Float, x4: Float) {
        let nyquistLimit = max(600.0, (sampleRate * 0.5) - 100.0)
        let c1 = clampf(x1, 40.0, nyquistLimit - 400.0)
        var c2 = clampf(x2, c1 + 40.0, nyquistLimit - 300.0)
        var c3 = clampf(x3, c2 + 80.0, nyquistLimit - 200.0)
        var c4 = clampf(x4, c3 + 120.0, nyquistLimit - 100.0)
        if c2 <= c1 + 30.0 {
            c2 = c1 + 40.0
        }
        if c3 <= c2 + 60.0 {
            c3 = c2 + 80.0
        }
        if c4 <= c3 + 100.0 {
            c4 = c3 + 120.0
        }
        return (c1, c2, c3, c4)
    }

    func renderNonInterleaved(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            // Tone source: sine / pink / white via `nextToneRawSample`,
            // scaled by `toneLevel` (linear; default ≈ 0.1 = −20 dBFS).
            // Pre-fix: this path used `sinf(tonePhase)` without
            // advancing the phase, generating DC silence.
            let raw = nextToneRawSample()
            let tone = raw * toneLevel
            var l: Float
            var r: Float
            switch toneMode {
            case "left":
                l = tone
                r = 0.0
            case "right":
                l = 0.0
                r = tone
            case "stereo":
                l = tone
                r = -tone
            default:
                l = tone
                r = tone
            }
            let detail = processSampleDetailed(leftIn: l, rightIn: r)
            writeAnalysisSample(index: i, stereo: detail.analysisStereo, analysis: analysis)
            let mpx = detail.mpx
            left[i] = mpx
            right[i] = mpx
        }
    }

    @inline(__always)
    func renderSingleSample(leftIn: Float, rightIn: Float) -> Float {
        processSample(leftIn: leftIn, rightIn: rightIn)
    }

    func renderFromInputInPlace(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            let detail = processSampleDetailed(leftIn: left[i], rightIn: right[i])
            writeAnalysisSample(index: i, stereo: detail.analysisStereo, analysis: analysis)
            let mpx = detail.mpx
            left[i] = mpx
            right[i] = mpx
        }
    }

    func renderMonitorFromInputInPlace(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            let direct = directMonitorStereo(leftIn: left[i], rightIn: right[i])
            writeAnalysisSample(index: i, postAGCLeft: direct.0, postAGCRight: direct.1, preMPXLeft: direct.0, preMPXRight: direct.1, analysis: analysis)
            left[i] = direct.0
            right[i] = direct.1
        }
    }

    func renderFromInputAndMonitorInPlace(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        mpxLeft: UnsafeMutablePointer<Float>,
        mpxRight: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            let inputL = left[i]
            let inputR = right[i]

            let detail = processSampleDetailed(leftIn: inputL, rightIn: inputR)
            writeAnalysisSample(index: i, stereo: detail.analysisStereo, analysis: analysis)
            let mpx = detail.mpx
            mpxLeft[i] = mpx
            mpxRight[i] = mpx

            let demod = demodulateMonitorFromMPXSample(mpx)
            left[i] = demod.0
            right[i] = demod.1
        }
    }

    func renderMonitorToneNonInterleaved(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            // Phase advance is handled inside `nextToneRawSample` for
            // the sine path; pink / white paths ignore phase.
            let raw = nextToneRawSample()
            let tone = raw * toneLevel
            var l: Float
            var r: Float
            switch toneMode {
            case "left":
                l = tone
                r = 0.0
            case "right":
                l = 0.0
                r = tone
            case "stereo":
                l = tone
                r = -tone
            default:
                l = tone
                r = tone
            }
            let direct = directMonitorStereo(leftIn: l, rightIn: r)
            writeAnalysisSample(index: i, postAGCLeft: direct.0, postAGCRight: direct.1, preMPXLeft: direct.0, preMPXRight: direct.1, analysis: analysis)
            left[i] = direct.0
            right[i] = direct.1
        }
    }

    func renderToneAndMonitorNonInterleaved(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        mpxLeft: UnsafeMutablePointer<Float>,
        mpxRight: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            let raw = nextToneRawSample()
            let tone = raw * toneLevel
            var srcL: Float
            var srcR: Float
            switch toneMode {
            case "left":
                srcL = tone
                srcR = 0.0
            case "right":
                srcL = 0.0
                srcR = tone
            case "stereo":
                srcL = tone
                srcR = -tone
            default:
                srcL = tone
                srcR = tone
            }

            let detail = processSampleDetailed(leftIn: srcL, rightIn: srcR)
            writeAnalysisSample(index: i, stereo: detail.analysisStereo, analysis: analysis)
            let mpx = detail.mpx
            mpxLeft[i] = mpx
            mpxRight[i] = mpx

            let demod = demodulateMonitorFromMPXSample(mpx)
            left[i] = demod.0
            right[i] = demod.1
        }
    }

    private func processSample(leftIn: Float, rightIn: Float) -> Float {
        processSampleDetailed(leftIn: leftIn, rightIn: rightIn).mpx
    }

    private func processSampleDetailed(leftIn: Float, rightIn: Float) -> (mpx: Float, analysisStereo: ProgramStereoState) {
        // High-level chain order:
        // 1. Program-domain stereo processing (AGC, filtering, enhancement, multiband)
        // 2. Stereo-image protection and monitoring
        // 3. Composite component assembly (L+R, L-R, pilot, stereo subcarrier, RDS)
        // 4. Final composite loudness and safety limiting
        var stereo = processProgramStereo(leftIn: leftIn, rightIn: rightIn)
        // Snapshot the program-stereo state BEFORE stereo-image protection so
        // analysis and metering callers see the unprotected program signal.
        // Image protection is a downstream side-channel limiter — it should
        // not colour upstream analysis readouts (widener, mid/side, scopes).
        let analysisStereo = stereo

        if !processingBypass {
            let protected = protectStereoImage(
                inputL: stereo.referenceLeft,
                inputR: stereo.referenceRight,
                outputL: stereo.left,
                outputR: stereo.right
            )
            stereo.left = protected.0
            stereo.right = protected.1
        }

        updateStereoImageMonitor(left: stereo.left, right: stereo.right)

        // Pre-emphasis on L/R immediately upstream of the pre-encode limiter,
        // so the limiter peak-controls the HF-boosted signal. See `preL`/`preR`.
        stereo.left = preL.process(stereo.left)
        stereo.right = preR.process(stereo.right)

        if preEncodeAudioLimiterEnabled && !processingBypass {
            let limited = preEncodeAudioLimiter.process(left: stereo.left, right: stereo.right)
            stereo.left = limited.0
            stereo.right = limited.1
        }

        let composite = makeCompositeComponents(
            left: stereo.left,
            right: stereo.right,
            inputActivity: stereo.inputActivity
        )

        let mpx = processFinalComposite(
            base: composite.base,
            diff: composite.diff,
            sub: composite.sub,
            pilot: composite.pilot,
            rds: composite.rds
        )
        return (mpx, analysisStereo)
    }

    private func processProgramStereo(leftIn: Float, rightIn: Float) -> ProgramStereoState {
        var left = leftIn * inputGain
        var right = rightIn * inputGain

        if monoMode {
            let mono = (left + right) * 0.5
            left = mono
            right = mono
        }
        let inputActivity = max(fabsf(left), fabsf(right))

        if !processingBypass {
            // Phase rotation: reduce waveform asymmetry before AGC
            if phaseRotationEnabled {
                let rotated = phaseRotator.process(left: left, right: right)
                left = rotated.0
                right = rotated.1
            }

            if widebandAGCEnabled {
                let adjusted = widebandAGC.process(left: left, right: right)
                left = adjusted.0
                right = adjusted.1
            }

            let filteredInput = inputHPF.process(left: left, right: right)
            left = filteredInput.0
            right = filteredInput.1
        }

        let postAGCLeft = left
        let postAGCRight = right
        let programBand = programLP.process(left: left, right: right)
        left = programBand.0
        right = programBand.1
        let referenceLeft = left
        let referenceRight = right

        if !processingBypass {
            let trimmed = hfTrim.process(left: left, right: right)
            left = trimmed.0
            right = trimmed.1

            // Parametric EQ: tonal shaping before dynamics processing
            if parametricEQEnabled {
                let eqd = parametricEQ.process(left: left, right: right)
                left = eqd.0
                right = eqd.1
            }

            // PrimeBass runs after the multiband stereo block (see below) so
            // multiband doesn't compress the synthesised harmonics it adds.
            // Canonical post-multiband placement matches MaxxBass / Aural
            // Exciter / Big Bottom industry practice — moved here from
            // pre-multiband in the 2026-05 chain-order audit.
            let stereoImage = processStereoImageStage(left: left, right: right)
            left = stereoImage.left
            right = stereoImage.right

            if multibandEnabled {
                let multiband = processMultibandStereo(left: left, right: right)
                left = multiband.0
                right = multiband.1
            }

            if primeBassEnabled {
                let primeBassOut = processPrimeBass(left: left, right: right)
                left = primeBassOut.0
                right = primeBassOut.1
            }

            // Bass clipper: pre-clip bass peaks independently to reduce LF-induced IMD
            if bassClipperEnabled {
                let bassClipped = bassClipper.process(left: left, right: right)
                left = bassClipped.0
                right = bassClipped.1
            }

            // Distortion-cancelled clipper: LF distortion cancellation
            if dcClipperEnabled {
                let dcOut = dcClipper.process(left: left, right: right)
                left = dcOut.0
                right = dcOut.1
            }
        }

        if encoderHFGuardEnabled {
            let guarded = processEncoderHFGuard(left: left, right: right)
            left = guarded.0
            right = guarded.1
        }

        // Final encoder-facing bandwidth guard. This sits immediately ahead of
        // stereo encoding and pre-emphasis so later nonlinear stages do not
        // re-broaden the transmitted audio spectrum.
        //
        // Transmit mode uses a Kaiser-windowed linear-phase FIR for a >80 dB
        // stop-band (~1.67 ms latency at 192 kHz). Monitor mode uses the
        // Butterworth cascade for minimum latency. The choice is made per
        // engine start by AudioOutputEngine via setEncoderFIREnabled(_:).
        let encoderBand: (Float, Float)
        if useEncoderFIR {
            encoderBand = encoderProgramFIR.process(left: left, right: right)
        } else {
            encoderBand = encoderProgramLP.process(left: left, right: right)
        }
        left = encoderBand.0
        right = encoderBand.1

        // 19 kHz pilot-protection notch
        left = pilotNotchL.process(left)
        right = pilotNotchR.process(right)

        return ProgramStereoState(
            left: left,
            right: right,
            referenceLeft: referenceLeft,
            referenceRight: referenceRight,
            postAGCLeft: postAGCLeft,
            postAGCRight: postAGCRight,
            inputActivity: inputActivity
        )
    }

    @inline(__always)
    private func directMonitorStereo(leftIn: Float, rightIn: Float) -> (Float, Float) {
        var left = leftIn * inputGain
        var right = rightIn * inputGain
        if monoMode {
            let mono = (left + right) * 0.5
            left = mono
            right = mono
        }
        return (clampf(left, -1.0, 1.0), clampf(right, -1.0, 1.0))
    }

    @inline(__always)
    private func writeAnalysisSample(index: Int, stereo: ProgramStereoState, analysis: AnalysisBuffers) {
        writeAnalysisSample(
            index: index,
            postAGCLeft: stereo.postAGCLeft,
            postAGCRight: stereo.postAGCRight,
            preMPXLeft: stereo.left,
            preMPXRight: stereo.right,
            analysis: analysis
        )
    }

    @inline(__always)
    private func writeAnalysisSample(
        index: Int,
        postAGCLeft: Float,
        postAGCRight: Float,
        preMPXLeft: Float,
        preMPXRight: Float,
        analysis: AnalysisBuffers
    ) {
        analysis.postAGCLeft?[index] = postAGCLeft
        analysis.postAGCRight?[index] = postAGCRight
        analysis.preMPXLeft?[index] = preMPXLeft
        analysis.preMPXRight?[index] = preMPXRight
    }

    private func processEncoderHFGuard(left: Float, right: Float) -> (Float, Float) {
        let split = encoderHFGuardSplit.process(left: left, right: right)
        let lowL = split.0.0
        let highL = split.0.1
        let lowR = split.1.0
        let highR = split.1.1

        let hfDrive = max(fabsf(highL), fabsf(highR))
        encoderHFGuardEnv = Self.smoothEnvelope(
            current: encoderHFGuardEnv,
            input: hfDrive,
            attackCoeff: encoderHFGuardAttackCoeff,
            releaseCoeff: encoderHFGuardReleaseCoeff
        )

        let threshold: Float = 0.11
        let over = max(0.0, encoderHFGuardEnv - threshold)
        let targetReductionDB = min(2.0, over * 24.0)
        let targetGain = powf(10.0, -targetReductionDB / 20.0)
        encoderHFGuardGain = Self.smoothTowardTarget(
            current: encoderHFGuardGain,
            target: targetGain,
            attackCoeff: encoderHFGuardAttackCoeff,
            releaseCoeff: encoderHFGuardReleaseCoeff
        )

        return (
            lowL + (highL * encoderHFGuardGain),
            lowR + (highR * encoderHFGuardGain)
        )
    }

    private func makeCompositeComponents(left: Float, right: Float, inputActivity: Float)
        -> CompositeComponents
    {
        let base = ((left + right) * 0.5) * sumLevel
        let diff = monoMode ? 0.0 : (((right - left) * 0.5) * diffLevel)
        // Pre-emphasis ran here pre-2026-05; it now runs in L/R domain
        // immediately upstream of the pre-encode limiter. See `preL` / `preR`.
        lastProgramActivity = inputActivity

        // (Phase advance for the tone source moved into
        // `nextToneRawSample` — was a side-effect here that only
        // worked when the source was a tone going through
        // `processSampleDetailed`. The render-time helper now owns
        // phase advance for all three tone paths.)

        pilotOsc.step()
        pilotPhaseForRDS = pilotOsc.phase
        let stereoServicesEnabled = !monoMode
        let pilot = (stereoServicesEnabled && pilotSupported) ? (pilotOsc.s * pilotLevel) : 0.0
        let sub = (stereoServicesEnabled && stereoSubcarrierSupported) ? pilotOsc.sin2x() : 0.0
        lastSubcarrierSample = sub

        if stereoServicesEnabled {
            rdsCoder?.updateRDSPilotPhase(pilotPhaseForRDS)
        }
        let rds =
            (stereoServicesEnabled && rdsSupported) ? (rdsCoder?.nextSampleWithPilotLock() ?? 0.0)
            : 0.0

        return CompositeComponents(base: base, diff: diff, sub: sub, pilot: pilot, rds: rds)
    }

    private func processStereoImageStage(left: Float, right: Float) -> StereoImageState {
        var state = StereoImageState(left: left, right: right)

        if monoBassEnabled {
            let monoBass = processMonoBass(left: state.left, right: state.right)
            state.left = monoBass.0
            state.right = monoBass.1
        }

        if stereoWidenEnabled {
            let widened = processStereoWidener(left: state.left, right: state.right)
            state.left = widened.0
            state.right = widened.1
        }

        return state
    }

    private func processFinalComposite(
        base: Float,
        diff: Float,
        sub: Float,
        pilot: Float,
        rds: Float
    ) -> Float {
        let subcarriers = (pilot + rds) * deviationScale
        let reserved = updateSubcarrierReservation(subcarriers)
        let thresholds = Self.makeFinalCompositeThresholds(
            outputGain: outputGain,
            threshold: threshold,
            reserved: reserved
        )

        // Keep the loudness work in the audio composite before the calibrated
        // pilot/RDS subcarriers are added back into the final MPX waveform.
        let rawAudioComposite = Self.makeDrivenAudioComposite(
            base: base,
            diff: diff,
            sub: sub,
            deviationScale: deviationScale,
            finalDrive: finalDrive
        )
        let audioCompositeShaperActive = audioCompositeSoftClipEnabled
        var audioComposite = rawAudioComposite
        if audioCompositeShaperActive {
            audioComposite = Self.softClipSafety(
                rawAudioComposite,
                threshold: thresholds.preLimiterCeiling
            )
        }
        if compositeAudioSmootherEnabled && audioCompositeShaperActive {
            audioComposite = compositeAudioSmoother.process(audioComposite)
        }

        if audioCompositeShaperActive {
            audioComposite = Self.softClipSafety(
                audioComposite,
                threshold: thresholds.postLimiterCeiling
            )
        }

        let audioCompositeAbs = fabsf(audioComposite)
        audioCompositePeakState = max(
            audioCompositeAbs,
            audioCompositePeakState * audioCompositePeakDecayCoeff
        )

        // Composite clipper: 8x oversampled soft-clip on audio composite.
        if compositeClipperEnabled {
            audioComposite = compositeClipper.process(audioComposite)
        }

        // BS.412 MPX power limiter — rolling average power limit for EU compliance.
        if bs412Enabled {
            audioComposite = bs412Limiter.process(audioComposite)
        }

        // Safety limiter on audio composite only — pilot and RDS are injected
        // after all limiting to preserve constant amplitude.  Professional
        // broadcast standard (Omnia, Orban, Stereotool): subcarriers bypass
        // the final limiter so the receiver's stereo decoder and RDS decoder
        // always see stable reference signals.
        var mpx = audioComposite * outputGain

        if limitEnabled {
            mpx = lookaheadLimiter.process(mpx)
            if finalMPXSoftClipEnabled {
                mpx = Self.softClipSafety(mpx, threshold: threshold)
            }
        }

        // Inject pilot and RDS after all limiting — constant amplitude
        mpx += subcarriers * outputGain

        return clampf(mpx, -1.0, 1.0)
    }

    @inline(__always)
    private func updateSubcarrierReservation(_ subcarriers: Float) -> Float {
        let subcarrierAbs = fabsf(subcarriers)
        subcarrierReservationEnv = Self.smoothEnvelope(
            current: subcarrierReservationEnv,
            input: subcarrierAbs,
            attackCoeff: subcarrierReservationAttackCoeff,
            releaseCoeff: subcarrierReservationReleaseCoeff
        )
        return subcarrierReservationEnv
    }

    private func updateStereoImageMonitor(left: Float, right: Float) {
        let postSideAbs = fabsf((left - right) * 0.5)
        monitorExpectedSideEnv = Self.smoothEnvelope(
            current: monitorExpectedSideEnv,
            input: postSideAbs,
            attackCoeff: monitorExpectedSideAttackCoeff,
            releaseCoeff: monitorExpectedSideReleaseCoeff
        )
    }

    private static func makeFinalCompositeThresholds(
        outputGain: Float,
        threshold: Float,
        reserved: Float
    ) -> FinalCompositeThresholds {
        let effectiveThreshold = threshold / max(1.0, outputGain)
        return FinalCompositeThresholds(
            effectiveThreshold: effectiveThreshold,
            preLimiterCeiling: max(
                Self.finalCompositePreLimiterFloor,
                effectiveThreshold - reserved - Self.finalCompositePreLimiterHeadroom
            ),
            postLimiterCeiling: max(
                Self.finalCompositePostLimiterFloor,
                effectiveThreshold - reserved - Self.finalCompositePostLimiterHeadroom
            )
        )
    }

    private static func makeCompositeCalibration(
        audioPeakState: Float,
        reservationEnv: Float,
        outputGain: Float
    ) -> (audioPeak: Float, budgetMarginDB: Float) {
        let postGain = max(0.0, outputGain)
        let reserved = max(0.0, min(1.2, reservationEnv * postGain))
        let audioPeak = audioPeakState * postGain
        let totalPeakBudget = max(1e-6, audioPeak + reserved)
        let budgetMarginDB = -20.0 * log10f(totalPeakBudget)
        return (audioPeak, budgetMarginDB)
    }

    @inline(__always)
    private static func makeDrivenAudioComposite(
        base: Float,
        diff: Float,
        sub: Float,
        deviationScale: Float,
        finalDrive: Float
    ) -> Float {
        (base + (diff * sub)) * deviationScale * finalDrive
    }

    @inline(__always)
    private static func makeOutputComposite(
        audioComposite: Float,
        subcarriers: Float,
        outputGain: Float
    ) -> Float {
        (audioComposite + subcarriers) * outputGain
    }

    @inline(__always)
    private static func smoothEnvelope(
        current: Float,
        input: Float,
        attackCoeff: Float,
        releaseCoeff: Float
    ) -> Float {
        let coeff = input > current ? attackCoeff : releaseCoeff
        return (coeff * current) + ((1.0 - coeff) * input)
    }

    @inline(__always)
    private static func smoothTowardTarget(
        current: Float,
        target: Float,
        attackCoeff: Float,
        releaseCoeff: Float
    ) -> Float {
        let coeff = target < current ? attackCoeff : releaseCoeff
        return (coeff * current) + ((1.0 - coeff) * target)
    }

    private func protectStereoImage(
        inputL: Float,
        inputR: Float,
        outputL: Float,
        outputR: Float
    ) -> (Float, Float) {
        let inputMid = (inputL + inputR) * 0.5
        let inputSide = (inputL - inputR) * 0.5
        let outputMid = (outputL + outputR) * 0.5
        let outputSide = (outputL - outputR) * 0.5

        let inputMidAbs = fabsf(inputMid)
        let inputSideAbs = fabsf(inputSide)
        let outputMidAbs = fabsf(outputMid)
        let outputSideAbs = fabsf(outputSide)

        stereoProtectInputMidEnv = Self.smoothEnvelope(
            current: stereoProtectInputMidEnv,
            input: inputMidAbs,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )
        stereoProtectInputSideEnv = Self.smoothEnvelope(
            current: stereoProtectInputSideEnv,
            input: inputSideAbs,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )
        stereoProtectMidEnv = Self.smoothEnvelope(
            current: stereoProtectMidEnv,
            input: outputMidAbs,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )
        stereoProtectSideEnv = Self.smoothEnvelope(
            current: stereoProtectSideEnv,
            input: outputSideAbs,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )

        let inputRatio = stereoProtectInputSideEnv / max(0.02, stereoProtectInputMidEnv)
        let configuredRatio = 0.70 + (widenWidth * 0.65)
        let allowedRatio = min(1.55, max(configuredRatio, inputRatio * 1.16))
        let allowedSide = max(0.008, stereoProtectMidEnv * allowedRatio)

        var targetGain: Float = 1.0
        if stereoProtectSideEnv > allowedSide {
            targetGain = clampf(allowedSide / max(1e-5, stereoProtectSideEnv), 0.0, 1.0)
        }

        stereoProtectGain = Self.smoothTowardTarget(
            current: stereoProtectGain,
            target: targetGain,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )

        let protectedSide = outputSide * stereoProtectGain
        return (outputMid + protectedSide, outputMid - protectedSide)
    }

    private func processStereoWidener(left: Float, right: Float) -> (Float, Float) {
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5
        let highSide = widenSideHP.process(side)
        let lowSide = side - highSide

        let sideGain = 1.0 + ((widenWidth - 0.5) * 1.35)
        let midGain = 1.0 + ((widenCenter - 0.5) * 0.35)
        let lowSideRetain = 0.34 + ((1.0 - widenWidth) * 0.16)

        var wetMid = mid * midGain
        var wetSide = (highSide * sideGain) + (lowSide * lowSideRetain)

        let inputEnergy = max(1e-6, (mid * mid) + (side * side))
        let wetEnergy = max(1e-6, (wetMid * wetMid) + (wetSide * wetSide))
        let norm = clampf(sqrtf(inputEnergy / wetEnergy), 0.90, 1.12)
        wetMid *= norm
        wetSide *= norm

        let wetLeft = wetMid + wetSide
        let wetRight = wetMid - wetSide
        let mixedLeft = lerpf(left, wetLeft, widenMix)
        let mixedRight = lerpf(right, wetRight, widenMix)
        return (mixedLeft, mixedRight)
    }

    private func processMonoBass(left: Float, right: Float) -> (Float, Float) {
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5
        let lowSide = monoBassSideLP.process(side)
        let highSide = side - lowSide
        let combinedSide = highSide
        return (mid + combinedSide, mid - combinedSide)
    }


    private func processPrimeBass(left: Float, right: Float) -> (Float, Float) {
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5
        let low = primeBassLP.process(mid)

        let drive = clampf(primeBassDrive, 0.0, 2.5)
        let density = clampf(primeBassDensity, 0.0, 1.0)
        let amount = clampf(primeBassAmount, 0.0, 1.0)
        let harmonics = clampf(primeBassHarmonics, 0.0, 1.0)
        let subAmount = (primeBassSubharmonicsEnabled ? primeBassSubharmonicsAmount : 0.0)
        if amount <= 1e-4, harmonics <= 1e-4, subAmount <= 1e-4 {
            return (left, right)
        }

        let midAbs = max(1e-6, fabsf(mid))
        let bassAbs = fabsf(low)
        let gateFloor = max(0.012, primeBassLevelEst * 0.18)
        if midAbs < gateFloor, bassAbs < gateFloor {
            return (left, right)
        }

        // Big Bottom dynamic-bass envelope follower (Werrbach US 5,359,665,
        // Aphex, expired 2012-07-31). Track LF level with fast attack
        // (~10 ms) and slow release (~300 ms): the boost ramps up
        // within the leading edge of a kick / plucked-bass note and
        // then extends over the natural decay. "Envelope duration
        // extension" — same peak boost as a static gain, just held
        // longer. Replaces the prior spectral-ratio detector +
        // transient-hold machinery, which tracked compositional
        // balance over seconds and so couldn't engage on a typical
        // drum hit before the hit was already over.
        let bigBottomCoeff =
            bassAbs > primeBassBigBottomEnv
            ? primeBassBigBottomAttackCoeff
            : primeBassBigBottomReleaseCoeff
        primeBassBigBottomEnv =
            (bigBottomCoeff * primeBassBigBottomEnv)
            + ((1.0 - bigBottomCoeff) * bassAbs)

        // Map envelope to [0, 1]. The ×4 normalization brings typical
        // program-level LF (~0.15-0.25 average) to roughly full
        // engagement; loud bass clamps at 1.0. The user's `amount` /
        // `drive` / `density` knobs upstream still scale how much that
        // engagement actually contributes to `boostGain` and
        // `harmonicGain`, so the follower's job here is just per-note
        // envelope tracking — knob-mediated intensity stays a separate
        // dimension.
        let adaptive = clampf(primeBassBigBottomEnv * 4.0, 0.0, 1.0)
        primeBassAdaptiveGain = adaptive

        // Slow level estimate for the next-tick gate floor. Same role
        // as before — gate uses last tick's value, this updates for
        // the next call.
        primeBassLevelEst += (midAbs - primeBassLevelEst) * primeBassLevelAlpha

        let driveFactor = 0.55 + (0.42 * drive)
        let densityFactor = 0.50 + (0.42 * density)
        let boostGain = amount * driveFactor * densityFactor * (0.62 + (0.42 * adaptive))
        // MaxxBass: reduce direct LF gain when harmonic synthesis is
        // engaged — the equal-loudness-weighted harmonics carry part
        // of the perceived bass weight that the LF amplitude carried
        // before. Buys headroom in the bass clipper / pre-encode
        // limiter without sacrificing subjective bass.
        let directScale = 1.0 - ((1.0 - primeBassDirectGainReduction) * harmonics)
        let lowBoost = low * boostGain * directScale

        // Aphex-style phase decorrelation (US 4,150,253, expired 1996):
        // pre-waveshape the LF through an allpass at F0 to rotate
        // phase ~180° across the band without changing amplitude. The
        // synthesized harmonics' phase is then decorrelated from the
        // direct lowboost path, preventing comb-filter summing at the
        // bass clipper's input. (The classic Aphex HP-then-clip
        // topology uses a high-pass, but for a bass-extension target
        // a HP at F0×1.6 would also kill the F0 amplitude entering
        // the waveshaper — an allpass preserves amplitude while
        // achieving the same phase decorrelation.)
        let lowSide = primeBassSideAP.process(low)

        let nlDrive = 1.0 + (drive * (1.0 + (amount * 1.8) + (harmonics * 1.4)))
        let driven = lowSide * nlDrive
        // Odd-harmonic generator (3rd, 5th): tanh-difference soft-clip.
        let oddSrc = tanhf(driven) - tanhf(lowSide * (0.65 + (0.18 * density)))
        // Even-harmonic generator (2nd, 4th): asymmetric sign-preserving
        // squaring — primarily 2nd-harmonic content with bounded peak.
        let evenSrc = lowSide * fabsf(lowSide) * (0.6 + (0.4 * drive))
        // MaxxBass equal-loudness weighting (US 5,930,373) — per-order
        // weights precomputed at configure time from an ISO 226
        // approximation evaluated at 2..5 x F0.
        let weighted =
            (oddSrc * primeBassHarmOddWeight) + (evenSrc * primeBassHarmEvenWeight)
        // Band-limit the harmonics: HP above F0 to remove the residual
        // fundamental that the waveshaper passes through, then LP at
        // ~5×F0 to keep harmonic energy out of the upper audio band.
        let harmonicBand = primeBassHarmLPF.process(primeBassHarmHPF.process(weighted))

        // Werrbach transient-discriminate gain (US 5,424,488). Two
        // independent envelope followers on the LF input: fast (~5 ms
        // attack / 30 ms release) reflects the current attack; slow
        // (~50 ms attack / 250 ms release) tracks the recent baseline.
        // The normalized difference (fast − slow) / slow saturates
        // positive on real onsets (fast jumps above slow) and decays
        // to zero as slow catches up. Mapped directly to the harmonic
        // gain — no further smoothing — so the burst shape is set
        // entirely by the input followers' time constants: fast
        // attack within ~5 ms, return to floor within ~50–150 ms.
        let fastCoeff =
            midAbs > primeBassFastEnv
            ? primeBassFastAttackCoeff : primeBassFastReleaseCoeff
        primeBassFastEnv =
            (fastCoeff * primeBassFastEnv) + ((1.0 - fastCoeff) * midAbs)
        let slowCoeff =
            midAbs > primeBassSlowEnv
            ? primeBassSlowAttackCoeff : primeBassSlowReleaseCoeff
        primeBassSlowEnv =
            (slowCoeff * primeBassSlowEnv) + ((1.0 - slowCoeff) * midAbs)
        let transientDrive = clampf(
            (primeBassFastEnv - primeBassSlowEnv) / max(1e-3, primeBassSlowEnv),
            0.0,
            1.0
        )
        let transientPeak = Self.primeBassTransientPeak
        let transientFloor = Self.primeBassTransientFloor
        let transientGain = transientFloor + (transientDrive * (transientPeak - transientFloor))
        primeBassTransientGainObserved = transientGain

        let harmonicGain =
            harmonics * (0.32 + (0.34 * density)) * (0.62 + (0.36 * adaptive))
            * transientGain
        var enhancement = lowBoost + (harmonicBand * harmonicGain)

        if subAmount > 1e-4 {
            let prev = primeBassSubPrevSample
            if prev <= 0.0, low > 0.0 {
                primeBassSubPhase ^= 1
            }
            primeBassSubPrevSample = low
            let square: Float = primeBassSubPhase == 0 ? -1.0 : 1.0
            let envelope = sqrtf(max(0.0, fabsf(low)))
            let subRaw = square * envelope
            let subWave = primeBassSubLP.process(subRaw)
            let subGain = subAmount * (0.22 + (0.24 * density)) * (0.55 + (0.24 * drive))
            enhancement += subWave * subGain
        }

        let enhClip = max(0.52, 0.72 - (0.08 * density))
        let satEnhancement = enhClip * tanhf(enhancement / max(1e-4, enhClip))
        var midOut = mid + satEnhancement
        midOut *= 1.0 / (1.0 + (0.03 * amount) + (0.03 * subAmount))

        let outMidAbs = max(1e-6, fabsf(midOut))
        let targetMakeupPower = 0.34 + (0.08 * density)
        let targetMakeup = clampf(
            powf(midAbs / outMidAbs, targetMakeupPower),
            0.94,
            1.06 + (0.06 * density)
        )
        primeBassMakeupGain = smoothPrimeBassGain(
            current: primeBassMakeupGain,
            target: targetMakeup,
            attackCoeff: primeBassMakeupAttackCoeff,
            releaseCoeff: primeBassMakeupReleaseCoeff
        )
        midOut *= primeBassMakeupGain

        let outL = midOut + side
        let outR = midOut - side
        return Self.limitStereoDeltaPeak(
            inputLeft: left,
            inputRight: right,
            outputLeft: outL,
            outputRight: outR,
            allowedPeakScale: 1.04 + (0.04 * amount) + (0.04 * subAmount)
        )
    }

    private func smoothPrimeBassGain(
        current: Float,
        target: Float,
        attackCoeff: Float,
        releaseCoeff: Float
    ) -> Float {
        let coeff = target > current ? attackCoeff : releaseCoeff
        return (coeff * current) + ((1.0 - coeff) * target)
    }

    private static func limitStereoDeltaPeak(
        inputLeft: Float,
        inputRight: Float,
        outputLeft: Float,
        outputRight: Float,
        allowedPeakScale: Float
    ) -> (Float, Float) {
        let inPeak = max(max(fabsf(inputLeft), fabsf(inputRight)), 1e-6)
        let outPeak = max(max(fabsf(outputLeft), fabsf(outputRight)), 1e-6)
        let allowedPeak = inPeak * allowedPeakScale
        guard outPeak > allowedPeak else {
            return (outputLeft, outputRight)
        }

        let scale = allowedPeak / outPeak
        return (
            inputLeft + ((outputLeft - inputLeft) * scale),
            inputRight + ((outputRight - inputRight) * scale)
        )
    }

    private func processMultibandStereo(left: Float, right: Float) -> (Float, Float) {
        if multibandMode == 5 {
            return processFiveBandMultiband(left: left, right: right)
        }
        return processThreeBandMultiband(left: left, right: right)
    }

    private func processThreeBandMultiband(left: Float, right: Float) -> (Float, Float) {
        let lowBandL: Float, lowBandR: Float
        let midBandL: Float, midBandR: Float
        let highBandL: Float, highBandR: Float

        if useMultibandFIR {
            // Linear-phase FIR splitter — all 3 bands time-aligned at exit.
            let bands = mb3FIRSplitter.process(left: left, right: right)
            lowBandL = bands.0.0; lowBandR = bands.0.1
            midBandL = bands.1.0; midBandR = bands.1.1
            highBandL = bands.2.0; highBandR = bands.2.1
        } else {
            // IIR LR4 cascade — monitor mode, low latency, allpass-flat
            // sum but with per-crossover phase rotation.
            let split1 = mb3Split1.process(left: left, right: right)
            lowBandL = split1.0.0
            lowBandR = split1.1.0
            let highResidL = split1.0.1
            let highResidR = split1.1.1

            let split2 = mb3Split2.process(left: highResidL, right: highResidR)
            midBandL = split2.0.0
            midBandR = split2.1.0
            highBandL = split2.0.1
            highBandR = split2.1.1
        }

        var lowOut = compressStereoBand(
            left: lowBandL,
            right: lowBandR,
            leftComp: &mbLowCompL,
            rightComp: &mbLowCompR
        )
        var midOut = compressStereoBand(
            left: midBandL,
            right: midBandR,
            leftComp: &mbMidCompL,
            rightComp: &mbMidCompR
        )
        var highOut = compressStereoBand(
            left: highBandL,
            right: highBandR,
            leftComp: &mbHighCompL,
            rightComp: &mbHighCompR
        )

        // Per-band downward expander (noise reduction)
        if downwardExpanderEnabled {
            let lowExpGain = mbExpLow.expanderGain(left: lowOut.0, right: lowOut.1)
            lowOut = (lowOut.0 * lowExpGain, lowOut.1 * lowExpGain)
            let midExpGain = mbExpMid.expanderGain(left: midOut.0, right: midOut.1)
            midOut = (midOut.0 * midExpGain, midOut.1 * midExpGain)
            let highExpGain = mbExpHigh.expanderGain(left: highOut.0, right: highOut.1)
            highOut = (highOut.0 * highExpGain, highOut.1 * highExpGain)
        }

        // Per-band fast peak limiter (transient control)
        if multibandLimiterEnabled {
            lowOut = mbLimLow.process(left: lowOut.0, right: lowOut.1)
            midOut = mbLimMid.process(left: midOut.0, right: midOut.1)
            highOut = mbLimHigh.process(left: highOut.0, right: highOut.1)
        }

        return Self.sumStereoBands(
            lowOut,
            midOut,
            highOut,
            makeup: multibandMakeup
        )
    }

    private func processFiveBandMultiband(left: Float, right: Float) -> (Float, Float) {
        let b1L: Float, b1R: Float
        let b2L: Float, b2R: Float
        let b3L: Float, b3R: Float
        let b4L: Float, b4R: Float
        let b5L: Float, b5R: Float

        if useMultibandFIR {
            let bands = mb5FIRSplitter.process(left: left, right: right)
            b1L = bands.0.0; b1R = bands.0.1
            b2L = bands.1.0; b2R = bands.1.1
            b3L = bands.2.0; b3R = bands.2.1
            b4L = bands.3.0; b4R = bands.3.1
            b5L = bands.4.0; b5R = bands.4.1
        } else {
            let split1 = mb5Split1.process(left: left, right: right)
            b1L = split1.0.0
            b1R = split1.1.0
            let rem1L = split1.0.1
            let rem1R = split1.1.1

            let split2 = mb5Split2.process(left: rem1L, right: rem1R)
            b2L = split2.0.0
            b2R = split2.1.0
            let rem2L = split2.0.1
            let rem2R = split2.1.1

            let split3 = mb5Split3.process(left: rem2L, right: rem2R)
            b3L = split3.0.0
            b3R = split3.1.0
            let rem3L = split3.0.1
            let rem3R = split3.1.1

            let split4 = mb5Split4.process(left: rem3L, right: rem3R)
            b4L = split4.0.0
            b4R = split4.1.0
            b5L = split4.0.1
            b5R = split4.1.1
        }

        var o1 = compressStereoBand(
            left: b1L, right: b1R, leftComp: &mb5Comp1L, rightComp: &mb5Comp1R)
        var o2 = compressStereoBand(
            left: b2L, right: b2R, leftComp: &mb5Comp2L, rightComp: &mb5Comp2R)
        var o3 = compressStereoBand(
            left: b3L, right: b3R, leftComp: &mb5Comp3L, rightComp: &mb5Comp3R)
        var o4 = compressStereoBand(
            left: b4L, right: b4R, leftComp: &mb5Comp4L, rightComp: &mb5Comp4R)
        var o5 = compressStereoBand(
            left: b5L, right: b5R, leftComp: &mb5Comp5L, rightComp: &mb5Comp5R)

        // Per-band downward expander (noise reduction)
        if downwardExpanderEnabled {
            let g1 = mbExp5B1.expanderGain(left: o1.0, right: o1.1)
            o1 = (o1.0 * g1, o1.1 * g1)
            let g2 = mbExp5B2.expanderGain(left: o2.0, right: o2.1)
            o2 = (o2.0 * g2, o2.1 * g2)
            let g3 = mbExp5B3.expanderGain(left: o3.0, right: o3.1)
            o3 = (o3.0 * g3, o3.1 * g3)
            let g4 = mbExp5B4.expanderGain(left: o4.0, right: o4.1)
            o4 = (o4.0 * g4, o4.1 * g4)
            let g5 = mbExp5B5.expanderGain(left: o5.0, right: o5.1)
            o5 = (o5.0 * g5, o5.1 * g5)
        }

        // Per-band fast peak limiter (transient control)
        if multibandLimiterEnabled {
            o1 = mbLim5B1.process(left: o1.0, right: o1.1)
            o2 = mbLim5B2.process(left: o2.0, right: o2.1)
            o3 = mbLim5B3.process(left: o3.0, right: o3.1)
            o4 = mbLim5B4.process(left: o4.0, right: o4.1)
            o5 = mbLim5B5.process(left: o5.0, right: o5.1)
        }

        return Self.sumStereoBands(
            o1,
            o2,
            o3,
            o4,
            o5,
            makeup: multibandMakeup
        )
    }

    private func compressStereoBand(
        left: Float,
        right: Float,
        leftComp: inout MonoCompressor,
        rightComp: inout MonoCompressor
    ) -> (Float, Float) {
        let absL = fabsf(left)
        let absR = fabsf(right)
        if multibandLinkStrength > 1e-4 {
            // When link is enabled, drive both channels from one shared detector.
            // This keeps gain reduction matched between L/R and prevents slow image collapse.
            let sidechain = Self.makeLinkedBandSidechain(
                absLeft: absL,
                absRight: absR,
                linkStrength: multibandLinkStrength
            )
            return (
                leftComp.process(left, sidechainAbs: sidechain),
                rightComp.process(right, sidechainAbs: sidechain)
            )
        }
        return (leftComp.process(left), rightComp.process(right))
    }

    @inline(__always)
    private static func sumStereoBands(
        _ a: (Float, Float),
        _ b: (Float, Float),
        _ c: (Float, Float),
        makeup: Float
    ) -> (Float, Float) {
        ((a.0 + b.0 + c.0) * makeup, (a.1 + b.1 + c.1) * makeup)
    }

    @inline(__always)
    private static func sumStereoBands(
        _ a: (Float, Float),
        _ b: (Float, Float),
        _ c: (Float, Float),
        _ d: (Float, Float),
        _ e: (Float, Float),
        makeup: Float
    ) -> (Float, Float) {
        ((a.0 + b.0 + c.0 + d.0 + e.0) * makeup, (a.1 + b.1 + c.1 + d.1 + e.1) * makeup)
    }

    @inline(__always)
    private static func makeLinkedBandSidechain(
        absLeft: Float,
        absRight: Float,
        linkStrength: Float
    ) -> Float {
        let avgAbs = (absLeft + absRight) * 0.5
        let linkedRMS = sqrtf(((absLeft * absLeft) + (absRight * absRight)) * 0.5)
        return lerpf(avgAbs, linkedRMS, linkStrength)
    }

    static func softClipSafety(_ x: Float, threshold: Float) -> Float {
        let thr = clampf(threshold, 0.5, 0.999)
        let ax = fabsf(x)
        if ax <= thr {
            return x
        }
        let margin = clampf(0.08 * (1.0 - thr), 0.004, 0.03)
        let outMax = min(1.0, thr + margin)
        let knee = max(1e-4, margin * 0.85)
        let clipped = thr + ((outMax - thr) * tanhf((ax - thr) / knee))
        return copysignf(clipped, x)
    }
}
