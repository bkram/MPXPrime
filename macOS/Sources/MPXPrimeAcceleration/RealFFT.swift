// vDSP-compatible packed real FFT (vDSP_fft_zrip and its setup functions) for
// platforms without Accelerate. Forward direction only -- no inverse call
// site exists in this codebase (precondition guards it).
//
// Semantics reproduced exactly (pinned by the AccelerateShimTests golden
// fixture captured from real Accelerate on macOS):
// - Input: n real samples packed as n/2 split-complex values (even-index
//   samples in realp, odd-index in imagp -- the vDSP_ctoz convention).
// - In-place output packing: realp[0] = 2*DC, imagp[0] = 2*Nyquist, and
//   bins k = 1..n/2-1 hold 2*X_k (vDSP's documented 2x forward scaling).
// - Only stride 1 is supported (the only stride used in this codebase).
#if !canImport(Accelerate)

#if canImport(Glibc)
import Glibc
#endif

public typealias FFTRadix = Int32
public let kFFTRadix2: Int32 = 0

public typealias FFTDirection = Int32
public let FFT_FORWARD: Int32 = 1
public let FFT_INVERSE: Int32 = -1

/// Opaque handle matching Accelerate's FFTSetup. Boxes a twiddle-table object
/// via Unmanaged so create/destroy have the same ownership shape as vDSP.
public typealias FFTSetup = OpaquePointer

/// Precomputed twiddle tables for complex FFTs up to size 2^(log2nMax - 1)
/// (the real transform length is 2^log2nMax; the internal complex FFT runs on
/// half that). Twiddles are computed in Double and stored as Float, matching
/// vDSP's table-based accuracy closely enough for the fixture tolerance.
final class RealFFTSetup {
    let log2nMax: Int
    /// Complex-FFT twiddles: e^(-2 pi i k / mMax), k = 0..<mMax/2, where
    /// mMax = 2^(log2nMax - 1). Smaller transforms stride into this table.
    let twReal: [Float]
    let twImag: [Float]
    /// Real-recombination twiddles: e^(-2 pi i k / nMax), k = 0..<mMax.
    let recReal: [Float]
    let recImag: [Float]

    init(log2nMax: Int) {
        self.log2nMax = log2nMax
        let mMax = 1 << max(0, log2nMax - 1)
        var tr = [Float](repeating: 0, count: max(1, mMax / 2))
        var ti = [Float](repeating: 0, count: max(1, mMax / 2))
        for k in 0..<(mMax / 2) {
            let ang = -2.0 * Double.pi * Double(k) / Double(mMax)
            tr[k] = Float(cos(ang))
            ti[k] = Float(sin(ang))
        }
        var rr = [Float](repeating: 0, count: max(1, mMax))
        var ri = [Float](repeating: 0, count: max(1, mMax))
        for k in 0..<mMax {
            let ang = -2.0 * Double.pi * Double(k) / Double(2 * mMax)
            rr[k] = Float(cos(ang))
            ri[k] = Float(sin(ang))
        }
        twReal = tr
        twImag = ti
        recReal = rr
        recImag = ri
    }
}

public func vDSP_create_fftsetup(_ log2n: vDSP_Length, _ radix: FFTRadix) -> FFTSetup? {
    guard radix == kFFTRadix2, log2n >= 1 else { return nil }
    let box = Unmanaged.passRetained(RealFFTSetup(log2nMax: Int(log2n)))
    return OpaquePointer(box.toOpaque())
}

public func vDSP_destroy_fftsetup(_ setup: FFTSetup?) {
    guard let setup else { return }
    Unmanaged<RealFFTSetup>.fromOpaque(UnsafeRawPointer(setup)).release()
}

/// In-place packed real FFT, forward only. See header for packing/scaling.
public func vDSP_fft_zrip(
    _ setup: FFTSetup, _ z: UnsafePointer<DSPSplitComplex>, _ iz: vDSP_Stride,
    _ log2n: vDSP_Length, _ direction: FFTDirection
) {
    precondition(iz == 1, "shim vDSP_fft_zrip supports stride 1 only")
    precondition(direction == FFT_FORWARD, "shim vDSP_fft_zrip is forward-only")
    let tables = Unmanaged<RealFFTSetup>.fromOpaque(UnsafeRawPointer(setup))
        .takeUnretainedValue()
    let log2nInt = Int(log2n)
    precondition(log2nInt <= tables.log2nMax, "log2n exceeds fftsetup capacity")
    let m = 1 << (log2nInt - 1)   // complex FFT size = half the real length
    let re = z.pointee.realp
    let im = z.pointee.imagp

    // 1) In-place complex FFT of size m over (re, im): bit-reversal permute,
    //    then radix-2 DIT butterflies with table twiddles.
    if m > 1 {
        var j = 0
        for i in 0..<(m - 1) {
            if i < j {
                let tr = re[i]; re[i] = re[j]; re[j] = tr
                let ti = im[i]; im[i] = im[j]; im[j] = ti
            }
            var bit = m >> 1
            while j & bit != 0 {
                j &= ~bit
                bit >>= 1
            }
            j |= bit
        }
        let mMax = 1 << (tables.log2nMax - 1)
        var size = 2
        while size <= m {
            let half = size >> 1
            let step = mMax / size   // twiddle table stride for this stage
            var base = 0
            while base < m {
                var tw = 0
                for pos in base..<(base + half) {
                    let wr = tables.twReal[tw]
                    let wi = tables.twImag[tw]
                    let oR = re[pos + half]
                    let oI = im[pos + half]
                    let tR = oR * wr - oI * wi
                    let tI = oR * wi + oI * wr
                    re[pos + half] = re[pos] - tR
                    im[pos + half] = im[pos] - tI
                    re[pos] += tR
                    im[pos] += tI
                    tw += step
                }
                base += size
            }
            size <<= 1
        }
    }

    // 2) Real-signal recombination into vDSP packed form with 2x scaling.
    //    X[k] = E[k] + e^(-2 pi i k / n) * O[k] where E/O come from the
    //    even/odd interleave; output = 2 * X[k].
    let z0r = re[0]
    let z0i = im[0]
    re[0] = 2.0 * (z0r + z0i)   // 2 * DC
    im[0] = 2.0 * (z0r - z0i)   // 2 * Nyquist
    if m > 1 {
        let mMax = 1 << (tables.log2nMax - 1)
        let recStep = mMax / m
        var k = 1
        while k <= m / 2 {
            let kc = m - k
            let ar = re[k], ai = im[k]
            let br = re[kc], bi = im[kc]
            // Even part: (Z[k] + conj(Z[m-k])) / 2
            let er = 0.5 * (ar + br)
            let ei = 0.5 * (ai - bi)
            // Odd part: (Z[k] - conj(Z[m-k])) / (2i)
            let or_ = 0.5 * (ai + bi)
            let oi = 0.5 * (br - ar)
            // Twiddle: e^(-2 pi i k / n)
            let wr = Double(tables.recReal[k * recStep])
            let wi = Double(tables.recImag[k * recStep])
            let tR = Float(Double(or_) * wr - Double(oi) * wi)
            let tI = Float(Double(or_) * wi + Double(oi) * wr)
            let xkR = er + tR
            let xkI = ei + tI
            // Conjugate-symmetric partner X[m-k] = conj(E[k]) + ... derived
            // from the same quantities with the twiddle at (m-k).
            let wr2 = Double(tables.recReal[kc * recStep])
            let wi2 = Double(tables.recImag[kc * recStep])
            let tR2 = Float(Double(or_) * wr2 + Double(oi) * wi2)
            let tI2 = Float(Double(or_) * wi2 - Double(oi) * wr2)
            let xkcR = er + tR2
            let xkcI = -ei + tI2
            re[k] = 2.0 * xkR
            im[k] = 2.0 * xkI
            if k != kc {
                re[kc] = 2.0 * xkcR
                im[kc] = 2.0 * xkcI
            }
            k += 1
        }
    }
}

#endif  // !canImport(Accelerate)
