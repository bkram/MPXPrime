// Accelerate compatibility shim for platforms without Apple's Accelerate
// framework (the Linux CLI build). Same names, same signatures, same
// numeric semantics as the small vDSP/vForce surface the encoder uses, so
// call sites compile unchanged via:
//
//   #if canImport(Accelerate)
//   import Accelerate
//   #else
//   import MPXPrimeAcceleration
//   #endif
//
// On macOS this whole file compiles away (#if !canImport(Accelerate)) and the
// DSP code links the real Accelerate -- macOS numerics are untouched by
// construction. Correctness of this shim against real Accelerate is pinned by
// the golden fixture in AccelerateShimTests (captured on macOS from Accelerate
// itself; the Linux build must reproduce it).
//
// Scalar implementations are intentional for milestone 1: every consumer on
// the Linux CLI path is either offline (verifier, baseline capture, tests) or
// per-block small (metering FIR). SIMD (e.g. sleef-class tanh) is a follow-up
// that would move Linux numerics and require a Linux baseline recapture.
#if !canImport(Accelerate)

#if canImport(Glibc)
import Glibc
#endif

// vDSP_Length/vDSP_Stride must match Accelerate's exact type names so call
// sites compile unchanged on Linux.
// swiftlint:disable:next type_name
public typealias vDSP_Length = UInt
// swiftlint:disable:next type_name
public typealias vDSP_Stride = Int

/// Split-complex sample as produced by interleaving-aware callers.
public struct DSPComplex {
    public var real: Float
    public var imag: Float
    public init(real: Float = 0, imag: Float = 0) {
        self.real = real
        self.imag = imag
    }
}

/// Split-complex vector: separate real / imaginary planes.
public struct DSPSplitComplex {
    public var realp: UnsafeMutablePointer<Float>
    public var imagp: UnsafeMutablePointer<Float>
    public init(realp: UnsafeMutablePointer<Float>, imagp: UnsafeMutablePointer<Float>) {
        self.realp = realp
        self.imagp = imagp
    }
}

// MARK: - Reductions

/// Dot product: C = sum(A[n*IA] * B[n*IB]).
public func vDSP_dotpr(
    _ a: UnsafePointer<Float>, _ ia: vDSP_Stride,
    _ b: UnsafePointer<Float>, _ ib: vDSP_Stride,
    _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length
) {
    var acc: Float = 0
    var pa = 0, pb = 0
    for _ in 0..<Int(n) {
        acc += a[pa] * b[pb]
        pa += ia
        pb += ib
    }
    c.pointee = acc
}

/// Sum of elements.
public func vDSP_sve(
    _ a: UnsafePointer<Float>, _ ia: vDSP_Stride,
    _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length
) {
    var acc: Float = 0
    var p = 0
    for _ in 0..<Int(n) {
        acc += a[p]
        p += ia
    }
    c.pointee = acc
}

/// Mean of elements.
public func vDSP_meanv(
    _ a: UnsafePointer<Float>, _ ia: vDSP_Stride,
    _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length
) {
    var acc: Float = 0
    var p = 0
    for _ in 0..<Int(n) {
        acc += a[p]
        p += ia
    }
    c.pointee = n == 0 ? 0 : acc / Float(n)
}

/// Maximum magnitude.
public func vDSP_maxmgv(
    _ a: UnsafePointer<Float>, _ ia: vDSP_Stride,
    _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length
) {
    var best: Float = 0
    var p = 0
    for _ in 0..<Int(n) {
        let m = abs(a[p])
        if m > best { best = m }
        p += ia
    }
    c.pointee = best
}

// MARK: - Elementwise vector ops

/// C = A * scalar B.
public func vDSP_vsmul(
    _ a: UnsafePointer<Float>, _ ia: vDSP_Stride,
    _ b: UnsafePointer<Float>,
    _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride,
    _ n: vDSP_Length
) {
    let s = b.pointee
    var pa = 0, pc = 0
    for _ in 0..<Int(n) {
        c[pc] = a[pa] * s
        pa += ia
        pc += ic
    }
}

/// C = A + scalar B.
public func vDSP_vsadd(
    _ a: UnsafePointer<Float>, _ ia: vDSP_Stride,
    _ b: UnsafePointer<Float>,
    _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride,
    _ n: vDSP_Length
) {
    let s = b.pointee
    var pa = 0, pc = 0
    for _ in 0..<Int(n) {
        c[pc] = a[pa] + s
        pa += ia
        pc += ic
    }
}

/// C = A * B (elementwise).
public func vDSP_vmul(
    _ a: UnsafePointer<Float>, _ ia: vDSP_Stride,
    _ b: UnsafePointer<Float>, _ ib: vDSP_Stride,
    _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride,
    _ n: vDSP_Length
) {
    var pa = 0, pb = 0, pc = 0
    for _ in 0..<Int(n) {
        c[pc] = a[pa] * b[pb]
        pa += ia
        pb += ib
        pc += ic
    }
}

// MARK: - FIR correlation

/// Correlation (Accelerate semantics: C[n] = sum_p A[n+p] * F[p]).
/// The input pointer A must reference at least N + P - 1 valid elements.
public func vDSP_conv(
    _ a: UnsafePointer<Float>, _ ia: vDSP_Stride,
    _ f: UnsafePointer<Float>, _ ifStride: vDSP_Stride,
    _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride,
    _ n: vDSP_Length, _ p: vDSP_Length
) {
    let taps = Int(p)
    for i in 0..<Int(n) {
        var acc: Float = 0
        let base = i * ia
        var pf = 0
        for j in 0..<taps {
            acc += a[base + j * ia] * f[pf]
            pf += ifStride
        }
        c[i * ic] = acc
    }
}

// MARK: - Windows

/// Hann window flags (values match Accelerate's).
public let vDSP_HANN_DENORM: Int32 = 0
public let vDSP_HALF_WINDOW: Int32 = 1
public let vDSP_HANN_NORM: Int32 = 2

/// Hann window. NORM scales so the window has unity power (matches
/// Accelerate: w[i] = k * (1 - cos(2 pi i / N)) with k = 0.5 for DENORM and
/// k = sqrt(2/3) ~ 0.8165 for NORM). Pinned against real Accelerate by the
/// golden fixture in AccelerateShimTests.
public func vDSP_hann_window(
    _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length, _ flag: Int32
) {
    let count = Int(n)
    guard count > 0 else { return }
    let full = (flag & vDSP_HALF_WINDOW) == 0
    let points = full ? count : count * 2
    let k: Double = (flag & vDSP_HANN_NORM) != 0 ? (2.0 / 3.0).squareRoot() : 0.5
    for i in 0..<count {
        let phase = 2.0 * Double.pi * Double(i) / Double(points)
        c[i] = Float(k * (1.0 - cos(phase)))
    }
}

// MARK: - Split-complex helpers

/// De-interleave complex (real, imag) pairs into split form.
public func vDSP_ctoz(
    _ c: UnsafePointer<DSPComplex>, _ ic: vDSP_Stride,
    _ z: UnsafePointer<DSPSplitComplex>, _ iz: vDSP_Stride,
    _ n: vDSP_Length
) {
    // Accelerate strides DSPComplex input in FLOAT elements (a stride of 2 is
    // "consecutive complex values"); the split output strides in complex
    // elements. Only the (2, 1) shape is used in this codebase.
    let zp = z.pointee
    var src = 0
    for i in 0..<Int(n) {
        let v = UnsafeRawPointer(c).advanced(by: src * MemoryLayout<Float>.stride)
            .assumingMemoryBound(to: DSPComplex.self).pointee
        zp.realp[i * iz] = v.real
        zp.imagp[i * iz] = v.imag
        src += ic
    }
}

/// C = |A|^2 for split-complex A.
public func vDSP_zvmags(
    _ a: UnsafePointer<DSPSplitComplex>, _ ia: vDSP_Stride,
    _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride,
    _ n: vDSP_Length
) {
    let ap = a.pointee
    var pc = 0
    for i in 0..<Int(n) {
        let re = ap.realp[i * ia]
        let im = ap.imagp[i * ia]
        c[pc] = re * re + im * im
        pc += ic
    }
}

// MARK: - vForce

/// y[i] = tanh(x[i]), n elements. Scalar libm loop (see header note on SIMD).
public func vvtanhf(
    _ y: UnsafeMutablePointer<Float>, _ x: UnsafePointer<Float>, _ n: UnsafePointer<Int32>
) {
    for i in 0..<Int(n.pointee) {
        y[i] = tanhf(x[i])
    }
}

#endif  // !canImport(Accelerate)
