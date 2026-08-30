#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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

/// Receiver-side FM de-emphasis: the exact inverse of `PreemphasisDesign.fit`
/// (numerator and denominator swapped), so it sits on the analog
/// 1 / |1 + j omega tau| curve within the fit's residual and the encoder's
/// pre-emphasis -> this filter cascade is algebraically flat. Used by
/// `MPXDecoder` (monitor path, verifier, the Meter on real stations).
public struct DeemphasisFilter {
    public var enabled: Bool = false
    @usableFromInline var b0: Float = 1.0
    @usableFromInline var b1: Float = 0.0
    @usableFromInline var b2: Float = 0.0
    @usableFromInline var a1: Float = 0.0
    @usableFromInline var a2: Float = 0.0
    @usableFromInline var x1: Float = 0.0
    @usableFromInline var x2: Float = 0.0
    @usableFromInline var y1: Float = 0.0
    @usableFromInline var y2: Float = 0.0

    public init() {}

    public mutating func configure(tauUS: Int, sampleRate: Float) {
        guard tauUS > 0 else {
            enabled = false
            b0 = 1.0; b1 = 0.0; b2 = 0.0; a1 = 0.0; a2 = 0.0
            reset()
            return
        }
        enabled = true
        let pre = PreemphasisDesign.fit(tau: Double(tauUS) * 1e-6, sampleRate: Double(max(8_000.0, sampleRate)))
        let inv = 1.0 / pre.b0
        b0 = Float(inv)
        b1 = Float(pre.a1 * inv)
        b2 = Float(pre.a2 * inv)
        a1 = Float(pre.b1 * inv)
        a2 = Float(pre.b2 * inv)
        reset()
    }

    @inlinable
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let y = (b0 * x) + (b1 * x1) + (b2 * x2) - (a1 * y1) - (a2 * y2)
        x2 = x1
        x1 = x
        y2 = y1
        y1 = zapDenorm(y)
        return y
    }

    public mutating func reset() {
        x1 = 0.0; x2 = 0.0; y1 = 0.0; y2 = 0.0
    }
}

/// Biquad design for FM pre-emphasis: least-squares fit (Levenberg-Marquardt
/// on the log-magnitude) of two zeros / two poles to the analog network
/// |1 + j omega tau| over 100 Hz .. min(15.5 kHz, 0.45 fs), unity gain at DC by
/// construction, starting from the textbook matched-z zero
/// (`a = exp(-1/(tau fs))`). The matched-z zero is exact at DC but saturates
/// toward Nyquist: at the 48 kHz audio-domain rate it sits -0.6 dB low at
/// 10 kHz and -1.4 dB at 15 kHz, and a receiver de-emphasises with the analog
/// curve, so that error went on air as an HF droop. The fit holds the curve
/// within 0.05 dB. Falls back to matched-z if the fit is unstable, not
/// minimum-phase, or not better. Runs at configure time only (double
/// precision, deterministic iteration count). The encoder's pre-emphasis uses
/// it directly; `DeemphasisFilter` uses its inverse.
public struct PreemphasisDesign {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double
    /// Worst |fitted - analog| in dB over the design grid.
    public var maxErrorDB: Double

    /// Analog network gain |1 + j omega tau| in dB.
    public static func analogGainDB(frequencyHz: Double, tau: Double) -> Double {
        let wt = 2.0 * Double.pi * frequencyHz * tau
        return 10.0 * log10(1.0 + (wt * wt))
    }

    public static func matchedZ(tau: Double, sampleRate: Double) -> PreemphasisDesign {
        let fs = max(8_000.0, sampleRate)
        let a = exp(-1.0 / (tau * fs))
        let scale = 1.0 / max(1e-12, 1.0 - a)
        var design = PreemphasisDesign(b0: scale, b1: -a * scale, b2: 0.0, a1: 0.0, a2: 0.0, maxErrorDB: 0.0)
        let grid = designGrid(tau: tau, sampleRate: fs)
        design.maxErrorDB = maxAbs(residuals(design.parameters, grid: grid))
        return design
    }

    public static func fit(tau: Double, sampleRate: Double) -> PreemphasisDesign {
        let fs = max(8_000.0, sampleRate)
        let fallback = matchedZ(tau: tau, sampleRate: fs)
        let grid = designGrid(tau: tau, sampleRate: fs)

        var p = fallback.parameters
        var r = residuals(p, grid: grid)
        var err = sumSquares(r)
        var lambda = 1e-3
        let count = grid.omegas.count
        for _ in 0..<60 {
            // Jacobian by central differences (4 parameters).
            var jac = [[Double]](repeating: [Double](repeating: 0.0, count: 4), count: count)
            let h = 1e-6
            for j in 0..<4 {
                var plus = p; plus[j] += h
                var minus = p; minus[j] -= h
                let rp = residuals(plus, grid: grid)
                let rm = residuals(minus, grid: grid)
                for k in 0..<count { jac[k][j] = (rp[k] - rm[k]) / (2.0 * h) }
            }
            var normal = [[Double]](repeating: [Double](repeating: 0.0, count: 4), count: 4)
            var gradient = [Double](repeating: 0.0, count: 4)
            for k in 0..<count {
                for i in 0..<4 {
                    gradient[i] += jac[k][i] * r[k]
                    for j in 0..<4 { normal[i][j] += jac[k][i] * jac[k][j] }
                }
            }
            var improved = false
            for _ in 0..<8 {
                var damped = normal
                for i in 0..<4 { damped[i][i] += lambda * max(1e-12, normal[i][i]) }
                guard let step = solve4(damped, gradient) else {
                    lambda *= 10.0
                    continue
                }
                var candidate = p
                for i in 0..<4 { candidate[i] -= step[i] }
                let rc = residuals(candidate, grid: grid)
                let ec = sumSquares(rc)
                if ec.isFinite, ec < err {
                    p = candidate; r = rc; err = ec
                    lambda = max(1e-9, lambda / 3.0)
                    improved = true
                    break
                }
                lambda *= 4.0
            }
            if !improved || err < 1e-10 { break }
        }

        let fitted = PreemphasisDesign(
            b0: 1.0 + p[2] + p[3] - p[0] - p[1], b1: p[0], b2: p[1], a1: p[2], a2: p[3],
            maxErrorDB: maxAbs(r))
        guard fitted.isStableMinimumPhase, fitted.maxErrorDB.isFinite,
              fitted.maxErrorDB < fallback.maxErrorDB else {
            return fallback
        }
        return fitted
    }

    // MARK: - Internals

    /// Free parameters [b1, b2, a1, a2]; b0 follows from unity DC gain.
    private var parameters: [Double] { [b1, b2, a1, a2] }

    /// Poles and zeros inside the unit circle -- required so the inverse
    /// (de-emphasis) is stable as well.
    private var isStableMinimumPhase: Bool {
        guard b0.isFinite, b0 > 1e-9 else { return false }
        let z1 = b1 / b0, z2 = b2 / b0
        let polesInside = abs(a2) < 1.0 && abs(a1) < 1.0 + a2
        let zerosInside = abs(z2) < 1.0 && abs(z1) < 1.0 + z2
        return polesInside && zerosInside
    }

    private struct Grid {
        var omegas: [Double]
        var targetsDB: [Double]
    }

    private static func designGrid(tau: Double, sampleRate: Double) -> Grid {
        let count = 96
        let fMax = min(15_500.0, 0.45 * sampleRate)
        var omegas = [Double](repeating: 0.0, count: count)
        var targets = [Double](repeating: 0.0, count: count)
        for i in 0..<count {
            let f = 100.0 + ((fMax - 100.0) * Double(i) / Double(count - 1))
            omegas[i] = 2.0 * Double.pi * f / sampleRate
            targets[i] = analogGainDB(frequencyHz: f, tau: tau)
        }
        return Grid(omegas: omegas, targetsDB: targets)
    }

    private static func responseDB(_ p: [Double], omega: Double) -> Double {
        let b1 = p[0], b2 = p[1], a1 = p[2], a2 = p[3]
        let b0 = 1.0 + a1 + a2 - b1 - b2
        let c1 = cos(omega), s1 = sin(omega)
        let c2 = cos(2.0 * omega), s2 = sin(2.0 * omega)
        let numRe = b0 + (b1 * c1) + (b2 * c2)
        let numIm = -((b1 * s1) + (b2 * s2))
        let denRe = 1.0 + (a1 * c1) + (a2 * c2)
        let denIm = -((a1 * s1) + (a2 * s2))
        let num2 = (numRe * numRe) + (numIm * numIm)
        let den2 = max(1e-300, (denRe * denRe) + (denIm * denIm))
        return 10.0 * log10(max(1e-300, num2 / den2))
    }

    private static func residuals(_ p: [Double], grid: Grid) -> [Double] {
        var out = [Double](repeating: 0.0, count: grid.omegas.count)
        for k in 0..<out.count {
            out[k] = responseDB(p, omega: grid.omegas[k]) - grid.targetsDB[k]
        }
        return out
    }

    private static func sumSquares(_ r: [Double]) -> Double {
        r.reduce(0.0) { $0 + ($1 * $1) }
    }

    private static func maxAbs(_ r: [Double]) -> Double {
        r.reduce(0.0) { max($0, abs($1)) }
    }

    /// Gaussian elimination with partial pivoting for the 4x4 normal system.
    private static func solve4(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        var m = matrix
        var v = rhs
        for col in 0..<4 {
            var pivot = col
            for row in (col + 1)..<4 where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            guard abs(m[pivot][col]) > 1e-18 else { return nil }
            if pivot != col {
                m.swapAt(pivot, col)
                v.swapAt(pivot, col)
            }
            for row in (col + 1)..<4 {
                let factor = m[row][col] / m[col][col]
                if factor == 0.0 { continue }
                for k in col..<4 { m[row][k] -= factor * m[col][k] }
                v[row] -= factor * v[col]
            }
        }
        var x = [Double](repeating: 0.0, count: 4)
        for row in stride(from: 3, through: 0, by: -1) {
            var acc = v[row]
            for k in (row + 1)..<4 { acc -= m[row][k] * x[k] }
            x[row] = acc / m[row][row]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }
}
