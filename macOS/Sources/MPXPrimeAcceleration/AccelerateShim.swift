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
// dotpr/conv/vvtanhf are SIMD (portable Swift SIMD8 -> SSE2 on x86-64
// baseline; NO AVX flags -- Goldmont Plus class CPUs have none). Measured on
// a J4105 @ 192 kHz with the full chain: scalar was 102% of a core (constant
// xruns); SIMD is what lets FIR multiband + the 16x composite clipper fit,
// mirroring macOS where vDSP_dotpr/vvtanhf are documented as required for
// the real-time budget. The Linux strict baseline is captured WITH these
// implementations; changing their numerics requires a recapture.
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
///
/// Unit-stride (the FIR-convolution hot path: multiband crossovers,
/// encoder FIR, decimators) runs 4x-unrolled SIMD8 -- the scalar loop left
/// the J4105-class CPU ~2% over real-time budget at 192 kHz; this is the
/// Linux counterpart of macOS's vDSP_dotpr (SSE2 codegen; no AVX, Goldmont
/// Plus has none). Strided calls keep the scalar path.
public func vDSP_dotpr(
    _ a: UnsafePointer<Float>, _ ia: vDSP_Stride,
    _ b: UnsafePointer<Float>, _ ib: vDSP_Stride,
    _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length
) {
    let count = Int(n)
    if ia == 1 && ib == 1 {
        c.pointee = simdDot(a, b, count)
        return
    }
    var acc: Float = 0
    var pa = 0, pb = 0
    for _ in 0..<count {
        acc += a[pa] * b[pb]
        pa += ia
        pb += ib
    }
    c.pointee = acc
}

@inline(__always)
func simdDot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ count: Int) -> Float {
    var acc0 = SIMD8<Float>()
    var acc1 = SIMD8<Float>()
    var acc2 = SIMD8<Float>()
    var acc3 = SIMD8<Float>()
    let ra = UnsafeRawPointer(a)
    let rb = UnsafeRawPointer(b)
    var i = 0
    while i + 32 <= count {
        let byte = i * 4
        acc0 += ra.loadUnaligned(fromByteOffset: byte, as: SIMD8<Float>.self)
            * rb.loadUnaligned(fromByteOffset: byte, as: SIMD8<Float>.self)
        acc1 += ra.loadUnaligned(fromByteOffset: byte + 32, as: SIMD8<Float>.self)
            * rb.loadUnaligned(fromByteOffset: byte + 32, as: SIMD8<Float>.self)
        acc2 += ra.loadUnaligned(fromByteOffset: byte + 64, as: SIMD8<Float>.self)
            * rb.loadUnaligned(fromByteOffset: byte + 64, as: SIMD8<Float>.self)
        acc3 += ra.loadUnaligned(fromByteOffset: byte + 96, as: SIMD8<Float>.self)
            * rb.loadUnaligned(fromByteOffset: byte + 96, as: SIMD8<Float>.self)
        i += 32
    }
    while i + 8 <= count {
        acc0 += ra.loadUnaligned(fromByteOffset: i * 4, as: SIMD8<Float>.self)
            * rb.loadUnaligned(fromByteOffset: i * 4, as: SIMD8<Float>.self)
        i += 8
    }
    var acc = ((acc0 + acc1) + (acc2 + acc3)).sum()
    while i < count {
        acc += a[i] * b[i]
        i += 1
    }
    return acc
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
    if ia == 1 && ifStride == 1 {
        for i in 0..<Int(n) {
            c[i * ic] = simdDot(a + i, f, taps)
        }
        return
    }
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

/// y[i] = tanh(x[i]), n elements -- vectorized (SIMD8 lanes).
///
/// tanh(x) = (e^(2|x|) - 1) / (e^(2|x|) + 1) with the sign restored, using a
/// Cephes-style SIMD expf (Cody-Waite range reduction + degree-5 polynomial,
/// 2^k via exponent-bit assembly). |x| is clamped at 9.1 where Float tanh
/// saturates to 1.0 exactly. Max abs error vs libm tanhf is ~1e-7 (verified
/// by AccelerateShimTests.tanhApproximationMatchesLibm) -- far below the
/// verifier thresholds; the Linux strict baseline is captured WITH this
/// implementation. The remainder goes through a padded SIMD lane so every
/// element takes the identical code path regardless of batch length.
public func vvtanhf(
    _ y: UnsafeMutablePointer<Float>, _ x: UnsafePointer<Float>, _ n: UnsafePointer<Int32>
) {
    let count = Int(n.pointee)
    let rx = UnsafeRawPointer(x)
    var i = 0
    while i + 8 <= count {
        let v = tanh8(rx.loadUnaligned(fromByteOffset: i * 4, as: SIMD8<Float>.self))
        UnsafeMutableRawPointer(y).storeBytes(of: v, toByteOffset: i * 4, as: SIMD8<Float>.self)
        i += 8
    }
    if i < count {
        var pad = SIMD8<Float>()
        for j in i..<count { pad[j - i] = x[j] }
        let v = tanh8(pad)
        for j in i..<count { y[j] = v[j - i] }
    }
}

@inline(__always)
func tanh8(_ v: SIMD8<Float>) -> SIMD8<Float> {
    // |v| via mantissa/exponent mask; sign kept for reassembly.
    let bits = unsafeBitCast(v, to: SIMD8<UInt32>.self)
    let signBits = bits & SIMD8<UInt32>(repeating: 0x8000_0000)
    var ax = unsafeBitCast(bits & SIMD8<UInt32>(repeating: 0x7FFF_FFFF), to: SIMD8<Float>.self)
    // Float tanh saturates to 1.0 by ~9.01; clamp keeps exp in range.
    ax = ax.replacing(with: SIMD8<Float>(repeating: 9.1), where: ax .> 9.1)
    let e = exp8(ax + ax)                     // e^(2|x|), <= e^18.2, no overflow
    let one = SIMD8<Float>(repeating: 1.0)
    let t = (e - one) / (e + one)
    return unsafeBitCast(unsafeBitCast(t, to: SIMD8<UInt32>.self) | signBits, to: SIMD8<Float>.self)
}

/// SIMD e^x for x in [0, ~88] (only non-negative inputs reach it here).
@inline(__always)
func exp8(_ x: SIMD8<Float>) -> SIMD8<Float> {
    let log2e = SIMD8<Float>(repeating: 1.442695040888963)
    // Round-to-nearest via the 2^23 magic constant (values here are small
    // and positive, well inside the trick's domain).
    let magic = SIMD8<Float>(repeating: 12_582_912.0)   // 1.5 * 2^23
    let k = (x * log2e + magic) - magic
    // Cody-Waite: f = x - k*ln2 in two constants to keep f accurate.
    let ln2Hi = SIMD8<Float>(repeating: 0.693359375)
    let ln2Lo = SIMD8<Float>(repeating: -2.12194440e-4)
    let f = (x - k * ln2Hi) - k * ln2Lo
    // Degree-5 minimax polynomial for e^f on [-0.347, 0.347] (Cephes expf).
    var p = SIMD8<Float>(repeating: 1.9875691500e-4)
    p = p * f + SIMD8<Float>(repeating: 1.3981999507e-3)
    p = p * f + SIMD8<Float>(repeating: 8.3334519073e-3)
    p = p * f + SIMD8<Float>(repeating: 4.1665795894e-2)
    p = p * f + SIMD8<Float>(repeating: 1.6666665459e-1)
    p = p * f + SIMD8<Float>(repeating: 5.0000001201e-1)
    p = ((p * f) * f + f) + SIMD8<Float>(repeating: 1.0)
    // 2^k assembled into the exponent field.
    let ki = SIMD8<Int32>(k)
    let twoK = unsafeBitCast((ki &+ SIMD8<Int32>(repeating: 127)) &<< 23, to: SIMD8<Float>.self)
    return p * twoK
}

#endif  // !canImport(Accelerate)
