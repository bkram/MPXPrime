import Darwin
import Foundation

// Foundational DSP filter primitives shared between the transmit chain
// (MPXPrime) and the MPX decoder (also used by the future MPXPrimeMeter
// companion app). These were extracted verbatim from MPXGenerator.swift
// in the v0.31 modularization step; the bodies are byte-for-byte the
// same math as before so composite output is unchanged (gated by
// --verify --baseline-strict).
//
// Cross-module inlining: process() is a per-sample hot-path call inside
// the transmit chain's oversampled clipper decimators, EQ, phase
// rotation, and notch stages. Without @inlinable, Swift will not inline
// these across the MPXPrimeCore -> MPXPrime module boundary in release
// builds, which would cost real-time CPU even though the output is
// identical. The hot process() methods are therefore @inlinable, with
// the stored state they touch marked @usableFromInline and the trivial
// zapDenorm helper @inlinable so it folds into the inlined body. The
// configure*() methods are NOT hot (called on reconfigure, not per
// sample) so they stay plain public and freely reference the
// module-private clampf / twoPi helpers.

let twoPi = Float.pi * 2.0

@inline(__always)
func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
    return max(lo, min(hi, x))
}

@inlinable
@inline(__always)
func zapDenorm(_ x: Float) -> Float {
    return (fabsf(x) < 1e-20) ? 0.0 : x
}

public struct Biquad {
    @usableFromInline var b0: Float = 1.0
    @usableFromInline var b1: Float = 0.0
    @usableFromInline var b2: Float = 0.0
    @usableFromInline var a1: Float = 0.0
    @usableFromInline var a2: Float = 0.0
    @usableFromInline var z1: Float = 0.0
    @usableFromInline var z2: Float = 0.0

    public init() {}

    public mutating func reset() {
        z1 = 0.0
        z2 = 0.0
    }

    public mutating func configureIdentity() {
        b0 = 1.0
        b1 = 0.0
        b2 = 0.0
        a1 = 0.0
        a2 = 0.0
        reset()
    }

    public mutating func configureLowpass(cutoffHz: Float, sampleRate: Float, q: Float = 0.7071068) {
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

    public mutating func configureHighpass(cutoffHz: Float, sampleRate: Float, q: Float = 0.7071068) {
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

    public mutating func configureNotch(freqHz: Float, sampleRate: Float, q: Float = 12.0) {
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

    public mutating func configureBandpass(freqHz: Float, sampleRate: Float, q: Float = 4.0) {
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

    public mutating func configureAllpass(freqHz: Float, sampleRate: Float, q: Float = 0.7071068) {
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

    public mutating func configurePeakingEQ(freqHz: Float, gainDB: Float, sampleRate: Float, q: Float = 1.0) {
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

    public mutating func configureLowShelf(
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

    public mutating func configureHighShelf(
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

    @inlinable
    public mutating func process(_ x: Float) -> Float {
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

public struct BiquadCascade6 {
    private static let butterworthQ: (Float, Float, Float) = (0.5176381, 0.7071068, 1.9318517)
    @usableFromInline var s1 = Biquad()
    @usableFromInline var s2 = Biquad()
    @usableFromInline var s3 = Biquad()

    public init() {}

    public mutating func configureIdentity() {
        s1.configureIdentity()
        s2.configureIdentity()
        s3.configureIdentity()
    }

    public mutating func configureLowpass(cutoffHz: Float, sampleRate: Float) {
        let q = Self.butterworthQ
        s1.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.0)
        s2.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.1)
        s3.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.2)
    }

    public mutating func configureHighpass(cutoffHz: Float, sampleRate: Float) {
        let q = Self.butterworthQ
        s1.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.0)
        s2.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.1)
        s3.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate, q: q.2)
    }

    @inlinable
    public mutating func process(_ x: Float) -> Float {
        return s3.process(s2.process(s1.process(x)))
    }
}

public struct DeemphasisFilter {
    public var enabled: Bool = false
    @usableFromInline var a: Float = 0.0
    @usableFromInline var y1: Float = 0.0

    public init() {}

    public mutating func configure(tauUS: Int, sampleRate: Float) {
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

    @inlinable
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let y = (1.0 - a) * x + a * y1
        y1 = zapDenorm(y)
        return y
    }

    public mutating func reset() { y1 = 0.0 }
}
