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
//     stereo_chosen  = HP_22(LR4_LP_53(clipped + stereoGuard * residual))
//                      (stereoGuard 1 restores the whole L-R subcarrier as it
//                      went in -- the clipper then only ever removes the mono
//                      share of an M+S peak; 0 clips the full composite the
//                      way Orban / Omnia / Stereo Tool do; in between blends)
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
// Pilot (19 kHz) and RDS (57 kHz) are injected post-clipper, so their
// amplitudes bypass this stage. Clipper IM in the 17-21 kHz pilot guard
// and 55-59 kHz RDS guard still rides under those clean subcarriers at
// the receiver, so the pilot/RDS cancel flags actively subtract
// bandpass-isolated residual energy before decimation.
struct CompositeClipper {
    private var thresholdLin: Float = 0.708
    private var ceilingLin: Float = 0.944
    private var knee: Float = 0.236
    /// Configured ceiling as a linear amplitude; the final stage normalises
    /// the audio composite so this ceiling lands exactly on the composite budget.
    var ceilingLinear: Float { ceilingLin }
    private var lag = Lagrange4Interp()
    /// Decimation filter for the OS-rate clipping residual. Replaced
    /// the prior `BiquadCascade6` (12th-order Butterworth) with a
    /// linear-phase Kaiser-windowed FIR — see `LinearPhaseFIRDecimator`
    /// header for the rationale. Used in the differential-clipper
    /// topology: only the *residual* (up − clipped) goes through
    /// decimation; the wanted signal rides a 1× delay-matched bypass.
    /// Inspired by Orban US 6,337,999 (expired 2022).
    private var decimLP = LinearPhaseFIRDecimator()
    /// Oversampling factor (8 / 16 / 32). Configurable since 0.31 via
    /// `mpx_clipper_oversampling`. Changing it reconfigures the FIR
    /// decimator, the Lagrange interpolator state, and the per-host
    /// batch buffers — restart-required.
    private var factor: Int = 16
    /// Default factor used for stack-allocated batch sizing before
    /// `configure()` runs. Keep aligned with the highest factor in the
    /// valid set so the default-init buffers can hold the largest
    /// configuration without reallocation if a caller later up-sizes.
    private static let defaultFactor: Int = 32

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

    // Per-band extraction filters run on the *residual* (up - clipped).
    // The band cancellation needs bandpass(up) - bandpass(clipped); since
    // every filter here is LTI, by superposition that equals
    // bandpass(up - clipped) exactly. So one filter per band on the residual
    // replaces the prior clipped+orig filter pair, halving the per-OS-step
    // band-filter cost (the composite clipper is the single heaviest stage).
    //
    // Audio + stereo bands use LR4 splits (sum-to-flat at the shared
    // crossover keeps substitution phase-coherent across their wide
    // passbands).
    private var residualAudio15 = LinkwitzRiley4()
    private var residualStereo53 = LinkwitzRiley4()
    private var residualStereoHP = LinkwitzRiley4()
    // Pilot (19 kHz) and RDS (57 kHz) guards use RBJ bandpass biquads tuned
    // to the subcarrier centre frequency. RBJ BPF has 0 dB peak and zero
    // phase shift at fc, so subtracting BP(residual) cleanly cancels clipper
    // IM at the protected centre. Wider LR4-style splits don't work here --
    // the 17-21 kHz / 55-59 kHz windows are too narrow for a flat LR4
    // passband, bounding achievable cancellation depth to a few dB.
    private var residualPilotBP = Biquad()
    private var residualRDSBP = Biquad()

    private var cancelAudio: Bool = false
    /// 0...1 share of the 22-53 kHz clipping residual restored to the output
    /// (`mpx_clipper_stereo_guard`). 1 = the pre-0.45 "Protect Stereo
    /// Subcarrier" toggle on: the S subchannel passes untouched and only the
    /// M share of each peak is clipped, so the composite overshoots the
    /// ceiling and the Final-MPX limiter has to ride ~1.5 dB routinely.
    /// 0 = full composite clipping (industry practice). Picked from the
    /// `--verify-stereo-guard` sweep.
    private var stereoGuard: Float = 1.0
    // Pilot (19 kHz) and RDS (57 kHz) subcarriers are injected
    // post-clipper. Even so, clipper IM in the 17–21 kHz pilot guard
    // and 55–59 kHz RDS guard bands vector-sums with the cleanly-
    // injected subcarriers at the receiver, corrupting pilot PLL lock
    // and RDS BER. Cancellation here subtracts the bandpass-isolated
    // clipper IM from the output before pilot/RDS injection.
    private var cancelPilot: Bool = true
    private var cancelRDS: Bool = true

    // Soft-clip attenuation telemetry for the UI meter. This tracks the
    // actual oversampled clip-kernel gain, not input/output peak ratio:
    // the differential FIR path delays and band-cancels the output, so
    // a direct peak ratio is not a valid gain-reduction measurement.
    private var clipGainEnv: Float = 1.0
    private var peakDecayCoeff: Float = 0.0

    // Stack-allocated batch buffers for vvtanhf-accelerated soft-clipping.
    // `factor` elements = one oversample step per host sample.
    // Pre-allocated to `defaultFactor` so the audio thread never allocates
    // even before configure() runs; resized to the active factor in configure().
    private var upBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)
    private var clipBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)
    private var clipExcessBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)
    private var clipTanhBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)
    // Precomputed Lagrange basis weights per oversample phase. The
    // interpolation fraction t = (i+1)/factor is fixed per phase, so these
    // weights are constant; computing them once in configure() instead of
    // re-evaluating the basis polynomials per host sample removes the
    // clipper's largest scalar cost. Bit-identical to the inline path.
    private var lagBasis: [SIMD4<Float>] = Array(repeating: .zero, count: defaultFactor)

    // === Look-ahead peak control (0.26) ===
    // Predictive sidechain that knows the future peak amplitude over the
    // next `lookaheadHostSamples` host samples. Multiplicative gain is
    // applied at the input so the soft-clip kernel sees an already-shaved
    // signal, mathematically bounding overshoots tighter than the soft-
    // clip alone. Patent-clean: half-cosine attack from US 6,434,241
    // (expired 2014); 200 Hz smoothing from US 5,737,434 (expired ~2017);
    // sliding-window-max detector from public DSP literature
    // (Signalsmith / musicdsp.org #274).
    //
    // Disabled when lookaheadHostSamples == 0; default OFF.
    private var lookaheadEnabled: Bool = false
    private var lookaheadHostSamples: Int = 0
    private var lookaheadDelay: [Float] = []
    private var lookaheadResizeScratch: [Float] = []
    private var lookaheadDelayWriteIdx: Int = 0

    // Lemire monotonic deque (sliding-window max) over OS-rate samples.
    // Operating at OS rate (`factor` × host) so the detector sees
    // Lagrange-interpolated intersample peaks — closes the gap where a host-rate
    // detector misses the 0.3-1.0 dB intersample peaks above |x| and
    // lets them through after pre-clip gain scaling. deqValues /
    // deqIndices are pre-allocated to the 5 ms maximum window at configure
    // time; lookaheadHostSamples is the active logical window length.
    // deqIndices stores the absolute OS-sample counter for expiry.
    private var deqValues: [Float] = []
    private var deqIndices: [Int] = []
    private var deqCapacity: Int = 0
    private var deqHead: Int = 0
    private var deqTail: Int = 0
    private var deqSampleCounter: Int = 0
    // Parallel Lagrange-4 interpolator for the detector. Advances on
    // un-delayed input `x` so the deque sees OS samples that the audio
    // path will encounter `lookaheadHostSamples` host samples from now.
    private var detLag = Lagrange4Interp()
    private var detOSBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)

    // Gain state machine: exponential attack toward gTarget (rate tied
    // to lookaheadHostSamples so gain reaches ~98% by the time the
    // audio path catches up), hold for the window length, then
    // exponential release at 80 ms time constant. The 200 Hz LP
    // smoother on the gain envelope is the load-bearing pilot/RDS
    // protection — modulation sidebands sit ≤200 Hz from carrier,
    // 38+ dB down by 17 kHz so they cannot reach the protected pilot
    // guard band.
    private var lookaheadGain: Float = 1.0
    private var lookaheadHoldRemaining: Int = 0
    private var lookaheadAttackCoeff: Float = 0.0
    private var lookaheadReleaseCoeff: Float = 0.0
    private var lookaheadLPCoeff: Float = 0.0
    private var lookaheadLPState: Float = 1.0

    // Telemetry — minimum lookahead-applied gain over a 50 ms decay
    // envelope, mirroring peakInEnv/peakOutEnv. Surfaced via
    // `lookaheadGainReductionDB` for the UI meter.
    private var lookaheadGainEnv: Float = 1.0

    mutating func configure(sampleRate: Float, thresholdDB: Float, ceilingDB: Float,
                            cancelAudio: Bool = false, stereoGuard: Float = 1.0,
                            cancelPilot: Bool = true, cancelRDS: Bool = true,
                            lookaheadMS: Float = 0.0,
                            oversamplingFactor: Int = 16) {
        // Only accept 8 / 16 / 32. Clamp to the nearest valid value
        // rather than rejecting — keeps callers simple and matches
        // AppConfig.sanitize() which also clamps.
        let validFactor: Int
        switch oversamplingFactor {
        case ...8:        validFactor = 8
        case 9...16:      validFactor = 16
        default:          validFactor = 32
        }
        self.factor = validFactor
        // Resize batch buffers to match the active factor. Default-init
        // size was `defaultFactor` (= 32, the max), so going to a smaller
        // factor shrinks; going larger is a no-op shape-wise but the
        // count change is needed so loop bounds match.
        if upBatch.count != validFactor { upBatch = [Float](repeating: 0.0, count: validFactor) }
        if clipBatch.count != validFactor { clipBatch = [Float](repeating: 0.0, count: validFactor) }
        if clipExcessBatch.count != validFactor { clipExcessBatch = [Float](repeating: 0.0, count: validFactor) }
        if clipTanhBatch.count != validFactor { clipTanhBatch = [Float](repeating: 0.0, count: validFactor) }
        if detOSBatch.count != validFactor { detOSBatch = [Float](repeating: 0.0, count: validFactor) }
        // Precompute the per-phase Lagrange basis weights (t = (i+1)/factor),
        // matching the hot-loop's `step * Float(i + 1)` exactly so the
        // interpolation stays bit-identical.
        if lagBasis.count != validFactor { lagBasis = [SIMD4<Float>](repeating: .zero, count: validFactor) }
        let basisStep = 1.0 / Float(validFactor)
        for i in 0..<validFactor {
            lagBasis[i] = Lagrange4Interp.basisWeights(t: basisStep * Float(i + 1))
        }

        thresholdLin = clampf(powf(10.0, min(0.0, thresholdDB) / 20.0), 0.1, 0.995)
        let cMin: Float = thresholdLin + 0.02
        ceilingLin = clampf(powf(10.0, min(0.0, ceilingDB) / 20.0), cMin, 0.999)
        knee = max(1e-4, ceilingLin - thresholdLin)
        let osRate = sampleRate * Float(self.factor)
        // FIR decimator passband must contain the entire audio
        // composite (0–53 kHz: M, S subcarrier sidebands at 38±15
        // kHz). Cutoff at 53 kHz with a wide transition band — at the
        // default OS rate 3.072 MHz (16× × 192 kHz, factor configurable
        // to 8 / 16 / 32 since 0.30) the available stopband region is
        // so wide that even a moderate transition gives ≥90 dB
        // rejection at the first IM target (64 kHz). Kaiser-sinc
        // designs to the stopBand target; tap count auto-sizes.
        let firPassband = clampf(53_000.0, 20_000.0, osRate * 0.45)
        let firTransition: Float = 60_000.0
        decimLP.configure(
            cutoffHz: firPassband,
            sampleRateOS: osRate,
            decimateFactor: self.factor,
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

        residualAudio15.configure(cutoffHz: 15_000.0, sampleRate: osRate)
        // Stereo guard (22-53 kHz) cancellation also runs at HOST rate on the
        // decimated residual. 53 kHz is the FIR passband edge -- the riskiest
        // band for decimate<->bandpass commuting -- so this move is gated by the
        // receiver separation @ 10/14 kHz, which exercise the stereo subcarrier.
        residualStereo53.configure(cutoffHz: 53_000.0, sampleRate: sampleRate)
        residualStereoHP.configure(cutoffHz: 22_000.0, sampleRate: sampleRate)
        // Pilot guard: BPF centred at 19 kHz, Q=4 → ~4.75 kHz half-power
        // bandwidth (17–21 kHz). RDS guard: BPF centred at 57 kHz, Q=14
        // → ~4 kHz bandwidth (55–59 kHz). Q values keep the bandpasses
        // from bleeding into the adjacent audio (≤15 kHz) and stereo
        // (23–53 kHz) bands respectively.
        // Pilot guard cancellation runs at HOST rate on the decimated residual
        // (see process()) -- 19 kHz sits deep inside the FIR's 53 kHz passband,
        // so decimate and bandpass commute and the per-OS-step filter is
        // redundant. Configured at the host sample rate accordingly.
        residualPilotBP.configureBandpass(freqHz: 19_000.0, sampleRate: sampleRate, q: 4.0)
        residualRDSBP.configureBandpass(freqHz: 57_000.0, sampleRate: osRate, q: 14.0)

        self.cancelAudio = cancelAudio
        self.stereoGuard = clampf(stereoGuard, 0.0, 1.0)
        self.cancelPilot = cancelPilot
        self.cancelRDS = cancelRDS

        let sr = max(8_000.0, sampleRate)
        peakDecayCoeff = expf(-1.0 / (0.050 * sr))
        clipGainEnv = 1.0

        // === Look-ahead peak control ===
        // Window length in host samples. Hard cap 5 ms; 0 ms disables.
        let cap = Int((5.0 / 1000.0) * sr)
        let n = max(0, min(cap, Int(roundf((lookaheadMS / 1000.0) * sr))))
        lookaheadHostSamples = n
        lookaheadEnabled = n > 0
        lookaheadDelay = [Float](repeating: 0.0, count: cap)
        lookaheadResizeScratch = [Float](repeating: 0.0, count: cap)
        let maxWindowOS = cap * self.factor
        deqCapacity = maxWindowOS + 2
        deqValues = [Float](repeating: 0.0, count: deqCapacity)
        deqIndices = [Int](repeating: 0, count: deqCapacity)
        deqHead = 0
        deqTail = 0
        deqSampleCounter = 0
        lookaheadDelayWriteIdx = 0
        detLag = Lagrange4Interp()

        if lookaheadEnabled {
            // Attack rate: reach ~98% of gTarget in `n` samples (4 time
            // constants over the lookahead window). This lets the audio
            // path's clip kernel see a fully-shaved signal by the time
            // it catches up to the detected peak.
            let attackTimeConstantSamples = max(1.0, Float(n) * 0.25)
            lookaheadAttackCoeff = clampf(
                1.0 - expf(-1.0 / attackTimeConstantSamples),
                0.0, 1.0
            )
        } else {
            lookaheadAttackCoeff = 0.0
        }

        // Release time constant: 80 ms (hardcoded). Smoothing 200 Hz
        // single-pole IIR — keeps gain modulation sidebands ≤200 Hz from
        // carrier so they cannot leak into the 17–21 kHz pilot guard
        // band (38+ dB down by 17 kHz).
        let releaseS: Float = 0.080
        lookaheadReleaseCoeff = clampf(
            1.0 - expf(-1.0 / (releaseS * sr)),
            0.0, 1.0
        )
        let lpCutoffHz: Float = 200.0
        lookaheadLPCoeff = clampf(1.0 - expf(-2.0 * .pi * lpCutoffHz / sr), 0.0, 1.0)

        lookaheadGain = 1.0
        lookaheadHoldRemaining = 0
        lookaheadLPState = 1.0
        lookaheadGainEnv = 1.0
    }

    /// Total host-rate delay added by this clipper: lookahead window +
    /// FIR group delay. Used by chain-latency reporting.
    var totalDelayHostSamples: Int {
        lookaheadHostSamples + decimLP.groupDelayHostSamples
    }

    /// Maximum delay this configured clipper can add without reallocating
    /// during a live look-ahead resize. `configure()` preallocates the 5 ms
    /// look-ahead delay capacity; `lookaheadHostSamples` is only the active
    /// logical length.
    var maxTotalDelayHostSamples: Int {
        lookaheadDelay.count + decimLP.groupDelayHostSamples
    }

    /// Focused live-update for the look-ahead window size only. Skips the
    /// FIR decimator / bypass delay / bandpass filter reconfiguration
    /// that `configure(...)` does, and preserves the ducking state
    /// (`lookaheadGain` / `lookaheadGainEnv` / `lookaheadLPState`) so a
    /// GUI slider drag doesn't snap gain back to 1.0 on every tick.
    ///
    /// Logical buffer resizes preserve the time-ordered audio content in
    /// `lookaheadDelay` without allocating: configure() preallocates the
    /// maximum 5 ms host delay and OS-rate deque, while this method only
    /// changes active lengths and copies within those buffers. The Lemire
    /// deque is reset (it refills within `n` samples, while the gain envelope
    /// is held by the LP smoother). Bandwidth, bypass, and all per-band
    /// cancellation state are untouched.
    mutating func setLookaheadMS(_ lookaheadMS: Float, sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        let cap = Int((5.0 / 1000.0) * sr)
        let storageCap = min(cap, lookaheadDelay.count)
        let n = max(0, min(storageCap, Int(roundf((lookaheadMS / 1000.0) * sr))))
        let oldN = lookaheadHostSamples
        let oldEnabled = lookaheadEnabled
        let newEnabled = n > 0

        if newEnabled {
            // Preserve audio content in `lookaheadDelay`: read oldest-to-newest
            // into preallocated scratch, then prepend zeros or drop the oldest
            // to fit the new logical size. This keeps the live audio sample
            // flowing through the resized pipeline without allocating or
            // stepping the delay contents.
            if n != oldN {
                for i in 0..<n {
                    lookaheadResizeScratch[i] = 0.0
                }
                if oldEnabled && oldN > 0 {
                    let copyN = min(oldN, n)
                    var srcIdx = (lookaheadDelayWriteIdx + oldN - copyN) % oldN
                    let dstStart = n - copyN
                    for i in 0..<copyN {
                        lookaheadResizeScratch[dstStart + i] = lookaheadDelay[srcIdx]
                        srcIdx = (srcIdx + 1) % oldN
                    }
                }
                for i in 0..<n {
                    lookaheadDelay[i] = lookaheadResizeScratch[i]
                }
                lookaheadDelayWriteIdx = 0
            }

            deqHead = 0
            deqTail = 0
            deqSampleCounter = 0
            detLag = Lagrange4Interp()

            let attackTimeConstantSamples = max(1.0, Float(n) * 0.25)
            lookaheadAttackCoeff = clampf(
                1.0 - expf(-1.0 / attackTimeConstantSamples),
                0.0, 1.0
            )
        } else {
            // Disabled. Keep the preallocated buffers and only reset logical
            // state; gain envelopes stay at their current values and will
            // decay naturally through the LP smoother when playback resumes.
            lookaheadDelayWriteIdx = 0
            deqHead = 0
            deqTail = 0
            deqSampleCounter = 0
            detLag = Lagrange4Interp()
            lookaheadAttackCoeff = 0.0
        }
        lookaheadHostSamples = n
        lookaheadEnabled = newEnabled
        // Do NOT reset lookaheadGain / lookaheadGainEnv / lookaheadLPState /
        // lookaheadHoldRemaining — preserving them is the load-bearing
        // anti-click property of this method.
    }

    /// Lookahead gain reduction in dB (positive = look-ahead is shaving
    /// peaks). Tracked separately from `gainReductionDB` so operators can
    /// distinguish predictive shaving (clean) from soft-clip shaving
    /// (distortion-producing). Decayed at ~50 ms via lookaheadGainEnv.
    var lookaheadGainReductionDB: Float {
        let g = max(1e-6, lookaheadGainEnv)
        return max(0.0, -20.0 * log10f(g))
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        // === Phase 0: look-ahead peak control ===
        // Push current input to the detector deque, read the delayed
        // input the audio path will actually clip, compute pre-clip gain.
        // When disabled (lookaheadHostSamples == 0): xPath = x, g = 1.0,
        // bit-identical to the pre-look-ahead pipeline.
        let xPath: Float
        let g: Float
        if lookaheadEnabled {
            // 1. OS-rate sliding-window-max push. The detector's
            //    Lagrange interpolator runs on the un-delayed input x;
            //    we compute `factor` OS samples between the previous
            //    host sample and x, then push each to the deque. This sees
            //    Lagrange-interpolated intersample peaks that a
            //    host-rate detector would miss.
            if !detLag.isPrimed { detLag.prime(x) }
            let f = self.factor
            let stepDet = 1.0 / Float(f)
            for i in 0..<f {
                let t = stepDet * Float(i + 1)
                detOSBatch[i] = (i == f - 1) ? x : detLag.interpolate(t: t, cur: x)
            }
            detLag.advance(x)
            let nWindowOS = lookaheadHostSamples * f
            for i in 0..<f {
                let absV = fabsf(detOSBatch[i])
                let curIdx = deqSampleCounter
                // Expire from head: drop entries older than the window.
                let oldestValidIdx = curIdx - nWindowOS + 1
                while deqHead != deqTail && deqIndices[deqHead] < oldestValidIdx {
                    deqHead += 1
                    if deqHead >= deqCapacity { deqHead = 0 }
                }
                // Drop tail entries ≤ absV (can never be max while
                // absV is in window).
                while deqHead != deqTail {
                    let prevTail = deqTail == 0 ? deqCapacity - 1 : deqTail - 1
                    if deqValues[prevTail] <= absV {
                        deqTail = prevTail
                    } else {
                        break
                    }
                }
                deqValues[deqTail] = absV
                deqIndices[deqTail] = curIdx
                deqTail += 1
                if deqTail >= deqCapacity { deqTail = 0 }
                deqSampleCounter += 1
            }

            // 2. Compute peak-ahead and target gain. peakAhead now
            //    reflects worst-case OS-rate intersample peak in the
            //    next n*factor OS samples — the actual peak the
            //    soft-clip kernel will see.
            let peakAhead = (deqHead != deqTail) ? deqValues[deqHead] : 0.0
            let gTarget: Float = peakAhead > ceilingLin
                ? ceilingLin / max(1e-6, peakAhead)
                : 1.0

            // 3. Attack/hold/release state machine. Exponential attack
            //    with rate tied to the lookahead window — the gain
            //    chases gTarget down as long as the detector says peak
            //    is above ceiling. Hold for window length once gain has
            //    reached target, then exponential release (80 ms time
            //    constant) toward gTarget = 1.0 when the peak passes.
            if gTarget < lookaheadGain {
                // Attack: chase gTarget exponentially. Hold counter
                // resets whenever attack engages so a steady stream of
                // peaks doesn't release between them.
                let a = lookaheadAttackCoeff
                lookaheadGain = (1.0 - a) * lookaheadGain + a * gTarget
                lookaheadHoldRemaining = lookaheadHostSamples
            } else if lookaheadHoldRemaining > 0 {
                lookaheadHoldRemaining -= 1
            } else {
                // Release toward gTarget (typically 1.0 once peaks have
                // passed). Exponential with 80 ms time constant.
                let r = lookaheadReleaseCoeff
                lookaheadGain = (1.0 - r) * lookaheadGain + r * gTarget
            }

            // 4. 200 Hz single-pole LP smoother on the gain envelope.
            //    This is the load-bearing pilot/RDS protection: keeps
            //    modulation sidebands ≤200 Hz from carrier so they cannot
            //    reach the 17–21 kHz pilot guard or 55–59 kHz RDS guard.
            lookaheadLPState += lookaheadLPCoeff * (lookaheadGain - lookaheadLPState)
            g = lookaheadLPState

            // Telemetry: track minimum smoothed gain over a 50 ms decay
            // window (parallel to peakInEnv/peakOutEnv).
            let decay = peakDecayCoeff
            // For "minimum gain" envelope: use the inverse-of-max trick.
            // 1.0 = no GR; smaller g = more GR. Decay: env *= decay (toward
            // 1.0); attack: env = min(env, g).
            lookaheadGainEnv = min(g, 1.0 - (1.0 - lookaheadGainEnv) * decay)

            // 5. Read delayed input from lookahead delay ring.
            let dLen = lookaheadHostSamples
            let xDelayed = dLen > 0 ? lookaheadDelay[lookaheadDelayWriteIdx] : x
            lookaheadDelay[lookaheadDelayWriteIdx] = x
            lookaheadDelayWriteIdx += 1
            if lookaheadDelayWriteIdx >= dLen { lookaheadDelayWriteIdx = 0 }
            // Apply gain to the audio path. Multiplicative scaling at
            // input means the entire downstream pipeline (Lagrange interp,
            // soft-clip, per-band cancellation, decimation, bypass) sees
            // a gain-scaled signal in lockstep — the (oBand − cBand)
            // cancellation identity is preserved by linearity.
            xPath = xDelayed * g
        } else {
            xPath = x
            g = 1.0
            // Decay telemetry envelope toward 1.0 even when disabled, so
            // a transient enable/disable doesn't leave the meter pinned.
            lookaheadGainEnv = 1.0 - (1.0 - lookaheadGainEnv) * peakDecayCoeff
        }

        if !lag.isPrimed { lag.prime(xPath) }
        let f = self.factor

        // Phase 1: pre-compute all `f` oversampled inputs via Lagrange interp.
        // Lagrange state advances only at lag.advance(x) below, so this
        // is safe to do as a batch up front.
        // Write through an unsafe buffer pointer so the per-element store
        // doesn't trip a copy-on-write uniqueness check each iteration
        // (these are private, never-aliased scratch buffers). Bit-identical.
        upBatch.withUnsafeMutableBufferPointer { ub in
            for i in 0..<f {
                ub[i] = (i == f - 1) ? xPath : lag.interpolate(weights: lagBasis[i], cur: xPath)
            }
        }

        // Phase 2: batched soft-clip via vvtanhf. Replaces `f` scalar tanhf
        // calls with one vvtanhf call on an `f`-element vector — reduces
        // libm tanhf overhead and uses Apple Silicon's vector exp/log
        // pipeline. Below-threshold samples bypass the tanh result entirely
        // (the tanh is still computed in the batch but its result is
        // discarded for those samples — the cost of the wasted compute is
        // smaller than the cost of a per-element branch on the SIMD path).
        let thr = thresholdLin
        let kn = knee
        clipExcessBatch.withUnsafeMutableBufferPointer { eb in
            for i in 0..<f {
                eb[i] = (fabsf(upBatch[i]) - thr) / kn
            }
        }
        var n = Int32(f)
        clipExcessBatch.withUnsafeMutableBufferPointer { excessPtr in
            clipTanhBatch.withUnsafeMutableBufferPointer { tanhPtr in
                // baseAddress is non-nil for non-empty pre-allocated arrays (vForce idiom).
                // swiftlint:disable force_unwrapping
                vvtanhf(tanhPtr.baseAddress!, excessPtr.baseAddress!, &n)
                // swiftlint:enable force_unwrapping
            }
        }
        var sampleClipGain: Float = 1.0
        clipBatch.withUnsafeMutableBufferPointer { cb in
            for i in 0..<f {
                let up = upBatch[i]
                let ax = fabsf(up)
                if ax <= thr {
                    cb[i] = up
                } else {
                    let clippedAbs = thr + kn * clipTanhBatch[i]
                    cb[i] = copysignf(clippedAbs, up)
                    sampleClipGain = min(sampleClipGain, clippedAbs / max(1e-6, ax))
                }
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
            // Naked clipping residual. Each protected band subtracts its
            // bandpass(residual) so the clipper IM in that band isn't
            // reflected to the output. By LTI superposition,
            // bandpass(residual) == bandpass(up) - bandpass(clipped), so a
            // single filter per band on the residual is exact -- and an
            // off band is skipped entirely (its filter would only need a
            // few OS samples to settle on a later live enable, which is
            // sub-millisecond and inaudible in a guard band).
            let r0 = upBatch[i] - clipBatch[i]
            var residual = r0
            if cancelAudio {
                residual -= residualAudio15.process(r0).low
            }
            // Pilot + stereo guards handled at host rate after decimation (below).
            if cancelRDS {
                residual -= residualRDSBP.process(r0)
            }

            // Push residual into FIR decimator. Returns the most-
            // recent emitted decimated value; the value updates only
            // on the f-th push of each host sample, so the value read
            // after the loop is the freshly-decimated residual.
            residualDecimated = decimLP.push(residual)
        }
        // Pilot (19 kHz) guard cancellation at host rate: 19 kHz is deep within
        // the FIR's 53 kHz passband, so cancelling on the decimated residual
        // once per host sample is equivalent to the former per-OS-step path by
        // LTI commuting -- but ~factor x cheaper. Stereo and RDS stay at OS rate
        // (stereo rides the FIR passband edge; RDS at 57 kHz is outside it).
        if cancelPilot {
            residualDecimated -= residualPilotBP.process(residualDecimated)
        }
        if stereoGuard > 0.0 {
            let split = residualStereo53.process(residualDecimated)
            residualDecimated -= stereoGuard * residualStereoHP.process(split.low).high
        }
        lag.advance(xPath)

        // Bypass: read host-rate input from `groupDelayHostSamples`
        // ago. With a length-N ring buffer (N = group delay), we read
        // the slot we're about to overwrite — that value was written
        // N samples ago. The N=1 special case (FIR group delay rounds
        // to 0 host samples, e.g. on extremely short FIRs) gives
        // zero-delay bypass, which is the correct degenerate
        // behaviour. Bypass holds gain-scaled `xPath` so the
        // differential math `out = bypassed − decimated(residual)`
        // gives the gain-scaled clipped output (per the look-ahead
        // multiplicative-scaling-at-input identity).
        let bypassLen = bypassDelay.count
        let bypassed = bypassLen > 1 ? bypassDelay[bypassWriteIdx] : xPath
        bypassDelay[bypassWriteIdx] = xPath
        bypassWriteIdx += 1
        if bypassWriteIdx >= bypassLen { bypassWriteIdx = 0 }

        let out = bypassed - residualDecimated

        clipGainEnv = min(sampleClipGain, 1.0 - (1.0 - clipGainEnv) * peakDecayCoeff)
        _ = g  // silence unused-when-disabled warning
        return out
    }

    /// Headroom reduction in dB (positive = clipper is shaving peaks).
    /// Computed from the oversampled clip-kernel gain, decayed at ~50
    /// ms; meant for the UI meter, not for sample-accurate analysis.
    var gainReductionDB: Float {
        let g = max(1e-6, clipGainEnv)
        return max(0.0, -20.0 * log10f(g))
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
            // Flush a denormal block average to zero so subnormal arithmetic
            // can't seep into the rolling power ring / Double accumulator on
            // near-silent program.
            let avgPower = zapDenorm(decimationAccumulator / Float(decimationFactor))
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
