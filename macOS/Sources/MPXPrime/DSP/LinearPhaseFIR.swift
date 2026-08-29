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
func kaiserI0(_ x: Float) -> Float {
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
func kaiserSincLowpassCoefficients(
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
            // baseAddress is non-nil for non-empty pre-allocated arrays (vDSP idiom).
            // swiftlint:disable force_unwrapping
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
            // swiftlint:enable force_unwrapping
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
        let factor = max(1, decimateFactor)
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
        self.decimateFactor = factor
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
                    // baseAddress is non-nil for non-empty pre-allocated arrays (vDSP idiom).
                    // swiftlint:disable force_unwrapping
                    vDSP_dotpr(
                        c.baseAddress!, 1,
                        d.baseAddress!.advanced(by: writeIdx), 1,
                        &out,
                        n
                    )
                    // swiftlint:enable force_unwrapping
                }
            }
            lastOutput = out
        }
        return lastOutput
    }
}

/// Linear-phase 1:L FIR interpolator. Companion to `LinearPhaseFIRDecimator`.
///
/// **Purpose.** Feeds the dual-rate audio chain boundary planned for 0.31:
/// when the audio domain runs at 48 kHz and the MPX domain at >= 176.4 kHz,
/// this primitive performs the upsample at the boundary. Designed at OS
/// (output) rate so the stopband sits cleanly above the wanted band and
/// alias images from zero-stuffing land below the noise floor.
///
/// **Polyphase decomposition.** A direct 1:L interpolator zero-stuffs the
/// input by L and runs an N-tap FIR at OS rate — most multiplies are by
/// zero. Polyphase reorganises into L sub-filters (phases), each of length
/// `tapsPerPhase = ceil(N / L)`, operating at the *input* rate. Per input
/// sample we emit L outputs, each costing one `tapsPerPhase`-length dot
/// product against the input-rate delay line. Total work per input is
/// L × tapsPerPhase ≈ N multiplies — the same as direct OS-rate
/// convolution, but with no wasted multiplies by zero and a single shared
/// delay line.
///
/// **Coefficient orientation.** The kernel `h[0..N-1]` is the Kaiser-sinc
/// designed at OS rate, scaled by L to preserve unity DC gain (each output
/// sample sums only the 1/L of the kernel that falls under a non-zero
/// input). Phase p contains taps `h[p], h[p+L], h[p+2L], ...` in
/// chronological order — i.e. tap 0 weights the *newest* input. Because
/// our shared delay-line convention puts the *oldest* sample at the start
/// of the read window (matching `LinearPhaseFIRDecimator`'s
/// `delay.baseAddress! + writeIdx` layout), the stored phases are reversed
/// at configure() time so `vDSP_dotpr` against the oldest-first window
/// produces the correct result.
///
/// **Emission order.** Per `push(x)`, the L emitted samples are at OS-rate
/// times `Lx(n - groupDelay) + 0, +1, ..., +L-1` — i.e. `out[0]` is
/// chronologically earliest, `out[L-1]` is latest.
struct LinearPhaseFIRInterpolator {
    private var phaseCoeffs: [[Float]] = []  // L arrays, each `tapsPerPhase` long, REVERSED
    private var delay: [Float] = []          // input-rate, double-buffered (size = 2 × tapsPerPhase)
    private var writeIdx: Int = 0
    private var tapsPerPhase: Int = 0
    private var totalTaps: Int = 0
    private var interpolateFactor: Int = 1

    var tapCount: Int { totalTaps }
    /// Group delay measured in OS-rate (output) samples = kernel midpoint.
    var groupDelayOSSamples: Int { max(0, (totalTaps - 1) / 2) }
    /// Group delay measured in input-rate samples, rounded to nearest integer.
    /// The ±0.5 OS-sample residual is sub-microsecond at typical rates.
    var groupDelayInputSamples: Int {
        guard interpolateFactor > 0 else { return 0 }
        return (groupDelayOSSamples + interpolateFactor / 2) / interpolateFactor
    }
    var factor: Int { interpolateFactor }
    var enabled: Bool { tapsPerPhase > 0 }

    mutating func configure(
        cutoffHz: Float,
        sampleRateOS: Float,
        interpolateFactor: Int,
        stopBandDB: Float = 90.0,
        transitionHz: Float = 60_000.0
    ) {
        let L = max(1, interpolateFactor)
        // Kaiser-sinc designed at OS rate. Same coefficient kernel as the
        // decimator — symmetric, linear-phase, configurable stopband.
        let kernel = kaiserSincLowpassCoefficients(
            cutoffHz: cutoffHz,
            sampleRate: sampleRateOS,
            stopBandDB: stopBandDB,
            transitionHz: transitionHz
        )
        // Scale by L so the DC gain stays unity: each output sample sums
        // contributions from at most 1/L of the kernel under the polyphase
        // decomposition.
        let scaled = kernel.map { $0 * Float(L) }
        let N = scaled.count
        let T = (N + L - 1) / L
        // Build phase tables, stored REVERSED so the dot-product against
        // the shared oldest-first delay window gives the natural newest-
        // weighted-by-tap-0 result.
        var phases = [[Float]](repeating: [Float](repeating: 0.0, count: T), count: L)
        for n in 0..<N {
            let p = n % L
            let k = n / L
            phases[p][T - 1 - k] = scaled[n]
        }
        self.phaseCoeffs = phases
        self.totalTaps = N
        self.tapsPerPhase = T
        self.interpolateFactor = L
        delay = [Float](repeating: 0.0, count: max(1, T) * 2)
        writeIdx = 0
    }

    mutating func reset() {
        guard tapsPerPhase > 0 else { return }
        for i in 0..<delay.count { delay[i] = 0 }
        writeIdx = 0
    }

    /// Push one input sample. Emits `factor` output samples into the
    /// caller-supplied buffer `out`, which MUST be at least `factor`
    /// elements long. Real-time-safe: no allocations.
    @inline(__always)
    mutating func push(_ x: Float, into out: UnsafeMutablePointer<Float>) {
        guard tapsPerPhase > 0 else {
            // Disabled — passthrough: emit `factor` copies of input.
            for i in 0..<interpolateFactor { out[i] = x }
            return
        }
        // Write into both halves of the double-buffer so the read window
        // is contiguous regardless of writeIdx wrap.
        delay[writeIdx] = x
        delay[writeIdx + tapsPerPhase] = x
        writeIdx += 1
        if writeIdx >= tapsPerPhase { writeIdx = 0 }

        let n = vDSP_Length(tapsPerPhase)
        let L = interpolateFactor
        delay.withUnsafeBufferPointer { d in
            // baseAddress is non-nil for non-empty pre-allocated arrays (vDSP idiom).
            // swiftlint:disable force_unwrapping
            let dStart = d.baseAddress!.advanced(by: writeIdx)
            for p in 0..<L {
                phaseCoeffs[p].withUnsafeBufferPointer { c in
                    var y: Float = 0
                    vDSP_dotpr(c.baseAddress!, 1, dStart, 1, &y, n)
                    out[p] = y
                }
            }
            // swiftlint:enable force_unwrapping
        }
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
        -> (lowL: Float, lowR: Float, highL: Float, highR: Float) {
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
        -> ((Float, Float), (Float, Float), (Float, Float), (Float, Float), (Float, Float)) {
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
        -> ((Float, Float), (Float, Float), (Float, Float)) {
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
