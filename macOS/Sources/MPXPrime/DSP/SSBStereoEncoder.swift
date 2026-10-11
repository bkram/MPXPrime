// Platform split: on macOS these resolve to the real Accelerate / Darwin /
// os modules (numerics and locking untouched); on Linux the
// MPXPrimeAcceleration shim provides same-name vDSP/vvtanhf functions and an
// OSAllocatedUnfairLock polyfill, and Glibc provides libm.
#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Atomics
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import MPXPrimeCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest on Linux corelibs
#endif
#if canImport(os)
import os
#endif

/// Experimental "SSB Stereo": a fixed LOWER-sideband SSB / VSB stereo
/// encoder (default off).
///
/// Classic FM stereo transmits L-R as double-sideband suppressed-carrier
/// around 38 kHz: `diff * sin(2t)`, one sideband at 38 - f and one at
/// 38 + f. Adding the quadrature term
///
///     stereo = diff*sin(2t) - amount * hilbert(diff)*cos(2t)
///
/// (hilbert(sin) = -cos) scales the sidebands to (1 + amount) / 2 at
/// 38 - f and (1 - amount) / 2 at 38 + f. The gains sum to 1, so a
/// product detector with the standard sin(2t) reference recovers L-R
/// unchanged (Orban's compatibility condition) and amount = 0 is exact
/// DSB. At amount = 1 the upper sideband is gone and the L-R information
/// sits in 23-38 kHz only, as in Orban's 8600 SSB/VSB mode and Stereo
/// Tool's "Standard" SSB: the occupied RF spectrum narrows and 38-53 kHz
/// is freed (the published multipath and RDS-protection argument), and
/// no full-level sideband rides the composite clipper's 53 kHz guard
/// edge. The kept sideband is FIXED; it never follows program.
///
/// What it does NOT do: reclaim composite headroom. The sideband
/// envelope sqrt(d^2 + H{d}^2) never dips below |d|, so SSB can only
/// raise the composite peak -- L/R correlated at 90 degrees costs up to
/// 20*log10(1 + amount), +3 dB at full SSB (Orban's documented overshoot
/// case). The earlier "opportunistic" selector that switched between the
/// two sidebands compared two signals with identical envelopes and
/// measured 0.00 dB of reclaim (docs/ssb-stereo-review.md); it is gone.
///
/// Receiver cost: a decoder whose 38 kHz reference is phi degrees off
/// leaks sin(phi) of L-R into the other channel with SSB, against
/// (1 - cos(phi)) with DSB -- about 21 dB of separation at 10 degrees
/// instead of 42 dB. `--verify-ssb-stereo` sweeps this.
///
/// Notes:
/// - The Hilbert FIR is linear-phase type III (anti-symmetric); base and
///   diff ride matching delay lines so mono/stereo stay time-aligned.
///   The double-buffered dotpr window runs oldest->newest, which
///   time-reverses the anti-symmetric taps: `h` is MINUS the Hilbert
///   transform of the delayed diff, so `dsb + amount * h * cos2` is the
///   lower sideband. Pinned by `ssbKeepsLowerSidebandAtEveryFrequency`
///   and the encoder-side sideband table of `--verify-receiver`.
/// - Below the Hilbert's usable band (~2*fs/N, about 750 Hz) the
///   quadrature term rolls off and the encoder degrades gracefully to
///   plain DSB with the sideband gains still summing to 1 -- bass stays
///   textbook stereo encoding by construction.
/// - amount = 0 is exactly DSB (delayed); the flag OFF is bit-identical
///   to the classic path (zero-drift).
/// - No decaying state: two FIR delay lines and one dot product, so
///   there is nothing to denormal-zap and nothing program-dependent.
struct SSBStereoEncoder {
    /// The kept sideband in the `dsb - sel * quad` convention of the
    /// former selector: -1 keeps 38 - f (lower). A constant now, exposed
    /// so diagnostics and tests can pin that it never moves.
    static let lowerSidebandSelection: Float = -1.0

    private var taps: [Float] = []
    private var hilbertDelay: [Float] = []   // double-buffered (2N)
    private var baseDelay: [Float] = []
    private var diffDelay: [Float] = []
    private var writeIdx: Int = 0
    private var alignIdx: Int = 0
    private var lengthTaps: Int = 0
    private var halfLength: Int = 0

    private var amount: Float = 0.7

    var groupDelaySamples: Int { halfLength }
    var enabled: Bool { lengthTaps > 0 }
    /// Diagnostics: the sideband selection (-1 = lower, fixed).
    var currentSelection: Float { Self.lowerSidebandSelection }

    /// `sampleRate` is part of the generator-facing API; the structure
    /// itself is rate-independent (the Hilbert band scales with fs/N).
    mutating func configure(sampleRate: Float, tapCount: Int = 511) {
        // Odd tap count, type III Hilbert: h[k] = 2/(pi*k) for odd k,
        // 0 for even k (and k = 0), Kaiser-windowed (beta 6 ~ 60 dB).
        let n = max(63, tapCount | 1)
        let m = (n - 1) / 2
        let beta: Float = 6.0
        let i0Beta = kaiserI0(beta)
        var h = [Float](repeating: 0.0, count: n)
        for k in stride(from: -m, through: m, by: 1) where k % 2 != 0 {
            let ideal = 2.0 / (Float.pi * Float(k))
            let x = Float(k) / Float(m)
            let w = kaiserI0(beta * sqrtf(max(0.0, 1.0 - (x * x)))) / i0Beta
            h[k + m] = ideal * w
        }
        taps = h
        lengthTaps = n
        halfLength = m
        hilbertDelay = [Float](repeating: 0.0, count: n * 2)
        // Program delay must be EXACTLY the Hilbert group delay (m).
        // Read-then-write on a ring of length m gives an m-sample delay;
        // m+1 here cost one sample of quadrature misalignment = ~19 deg
        // at 10 kHz = the sideband null bottoming out at ~-15 dB.
        baseDelay = [Float](repeating: 0.0, count: max(1, m))
        diffDelay = [Float](repeating: 0.0, count: max(1, m))
        writeIdx = 0
        alignIdx = 0
    }

    mutating func setAmount(_ newAmount: Float) {
        amount = clampf(newAmount, 0.0, 1.0)
    }

    mutating func reset() {
        guard lengthTaps > 0 else { return }
        for i in 0..<hilbertDelay.count { hilbertDelay[i] = 0.0 }
        for i in 0..<baseDelay.count { baseDelay[i] = 0.0; diffDelay[i] = 0.0 }
        writeIdx = 0
        alignIdx = 0
    }

    /// One sample of lower-sideband stereo assembly. Returns the delayed
    /// base (L+R) and the stereo (L-R on 38 kHz) term, both aligned to
    /// the Hilbert group delay, at the same scale the classic
    /// `base + diff*sub` assembly uses.
    mutating func process(
        base: Float, diff: Float, sub: Float, cos2: Float
    ) -> (base: Float, stereo: Float) {
        guard lengthTaps > 0 else { return (base, diff * sub) }

        // Hilbert of diff (double-buffered dotpr window, FIR pattern).
        hilbertDelay[writeIdx] = diff
        hilbertDelay[writeIdx + lengthTaps] = diff
        let startIdx = writeIdx + 1
        var h: Float = 0.0
        let n = vDSP_Length(lengthTaps)
        // baseAddress is non-nil for non-empty pre-allocated arrays (vDSP idiom).
        // swiftlint:disable force_unwrapping
        taps.withUnsafeBufferPointer { coeffPtr in
            hilbertDelay.withUnsafeBufferPointer { delayPtr in
                vDSP_dotpr(
                    coeffPtr.baseAddress!, 1,
                    delayPtr.baseAddress!.advanced(by: startIdx), 1,
                    &h,
                    n
                )
            }
        }
        // swiftlint:enable force_unwrapping
        writeIdx += 1
        if writeIdx >= lengthTaps { writeIdx = 0 }

        // Matching program delay for mono and stereo content.
        let alignN = baseDelay.count
        let delayedBase = baseDelay[alignIdx]
        let delayedDiff = diffDelay[alignIdx]
        baseDelay[alignIdx] = base
        diffDelay[alignIdx] = diff
        alignIdx += 1
        if alignIdx >= alignN { alignIdx = 0 }

        // Lower sideband, always: dsb + quad (see the sign note above).
        let dsb = delayedDiff * sub
        let quad = amount * h * cos2
        return (delayedBase, dsb - (Self.lowerSidebandSelection * quad))
    }
}
