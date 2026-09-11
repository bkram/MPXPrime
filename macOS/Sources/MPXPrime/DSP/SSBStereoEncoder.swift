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

/// Experimental "SSB Stereo" SSB-leaning stereo encoder (default off).
///
/// Classic FM stereo transmits L-R as double-sideband suppressed-carrier
/// around 38 kHz: `diff * sin(2t)`. Adding the quadrature term turns it
/// toward single-sideband:
///
///     stereo = diff*sin(2t) -/+ amount * hilbert(diff)*cos(2t)
///
/// which suppresses one sideband and grows the other (full SSB at
/// amount = 1). A coherent receiver demodulating with sin(2t) recovers
/// L-R either way -- SSB stereo is decode-compatible (phase errors on
/// real receivers trade a little separation, which is why this ships
/// hard-gated by the receiver-decode metrics). The win: the composite
/// peak of the two sideband choices differs with program, so picking
/// whichever variant currently peaks LOWER reclaims headroom (~up to
/// 1 dB) before the composite clipper has to work. Implemented from first principles on published SSB/quadrature theory.
///
/// Notes:
/// - The Hilbert FIR is linear-phase type III (anti-symmetric); base and
///   diff ride matching delay lines so mono/stereo stay time-aligned.
///   The double-buffered dotpr window runs oldest->newest, which
///   time-reverses anti-symmetric taps into a global sign flip -- moot
///   here because the sideband sign is chosen opportunistically anyway.
/// - Below the Hilbert's usable band (~2*fs/N) the quadrature term rolls
///   off and the encoder gracefully degrades to plain DSB -- bass stays
///   textbook stereo encoding by construction.
/// - amount = 0 is exactly DSB (delayed); the flag OFF is bit-identical
///   to the classic path (zero-drift).
struct SSBStereoEncoder {
    private var taps: [Float] = []
    private var hilbertDelay: [Float] = []   // double-buffered (2N)
    private var baseDelay: [Float] = []
    private var diffDelay: [Float] = []
    private var writeIdx: Int = 0
    private var alignIdx: Int = 0
    private var lengthTaps: Int = 0
    private var halfLength: Int = 0

    // Opportunistic sideband selection: leaky per-variant composite peak
    // trackers pick the lower-peak sideband; the selection slews so a
    // flip is a short crossfade, never a click.
    private var peakA: Float = 0.0
    private var peakB: Float = 0.0
    private var peakDecay: Float = 0.0
    private var sel: Float = 1.0
    private var targetSel: Float = 1.0
    private var selCoeff: Float = 0.0

    private var amount: Float = 0.7

    var groupDelaySamples: Int { halfLength }
    var enabled: Bool { lengthTaps > 0 }
    /// Diagnostics: current smoothed sideband selection (-1..+1).
    var currentSelection: Float { sel }

    mutating func configure(sampleRate: Float, tapCount: Int = 511) {
        let sr = max(8_000.0, sampleRate)
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
        peakDecay = expf(-1.0 / (0.005 * sr))   // ~5 ms leaky peak window
        selCoeff = expf(-1.0 / (0.005 * sr))    // ~5 ms selection crossfade
        peakA = 0.0
        peakB = 0.0
        sel = 1.0
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
        peakA = 0.0
        peakB = 0.0
        sel = 1.0
    }

    /// One sample of SSB-leaning stereo assembly. Returns the delayed
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

        let dsb = delayedDiff * sub
        let quad = amount * h * cos2

        // Track both candidate composite peaks (leaky max) and slew the
        // selection toward whichever sideband currently peaks lower.
        // Hysteresis (3%) is load-bearing: when both variants peak equally
        // (any single tone -- they are time-mirror images), a bare
        // comparison chatters on numeric noise, sel averages to a partial
        // value, and the sideband null bottoms out around -14 dB instead
        // of the Hilbert's real depth. Hold the current side unless the
        // other one is meaningfully lower.
        let candA = delayedBase + (dsb - quad)
        let candB = delayedBase + (dsb + quad)
        peakA = max(fabsf(candA), peakA * peakDecay)
        peakB = max(fabsf(candB), peakB * peakDecay)
        if peakB < peakA * 0.97 {
            targetSel = -1.0
        } else if peakA < peakB * 0.97 {
            targetSel = 1.0
        }
        sel = (selCoeff * sel) + ((1.0 - selCoeff) * targetSel)

        return (delayedBase, dsb - (sel * quad))
    }
}
