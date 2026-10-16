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

// MARK: - Composite Clipper (audio composite, 8/16/32x oversampled)
// Oversampled tanh soft-clipper on the audio composite in DIFFERENTIAL
// topology (Orban US 6,337,999, expired 2022) with per-band protection of the
// clipping residual (the delta-cancellation primitive of Orban US 4,460,871 /
// 5,737,434, expired).
//
// Signal flow (2026-10 peak-control review, F3 / F8 / F9 / F10):
//
//   x --(look-ahead delay x gain)--> xPath
//   xPath --2x Kaiser FIR interpolator--> Lagrange-4 to factor x host rate
//         --> soft clip --> residual = up - clipped --(pad)--> FIR decimator
//         --> host-rate residual r
//   r --guard FIR (linear phase)--> r_kept = r delayed - sum(w_b * band_b(r))
//   out = xPath delayed - r_kept
//
// * Guard bands. One linear-phase Kaiser FIR at host rate removes the
//   protected bands from the residual: audio 0-16 kHz (opt-in), pilot
//   16-22 kHz, stereo subcarrier 22-54 kHz weighted by the 0...1 SHARE
//   `mpx_clipper_stereo_guard`, RDS 54-60 kHz. Band edges sit in the gaps
//   with a 2 kHz transition and 50 dB of depth, so 17-21, 23-53 and 55-59 kHz
//   are protected in full. Until 2026-10 each guard subtracted an IIR band
//   (LR4 / RBJ) from the residual: `r - BP(r)` is "r without the band" only
//   if BP has zero phase across it, which an IIR does not, so the stereo
//   guard left the residual at -2.4 dB at 30 kHz and AMPLIFIED it (+2.5 dB)
//   at 23 and 53 kHz; S content above ~8 kHz was not protected at all. The
//   FIR's group delay is added to the bypass and to `totalDelayHostSamples`.
// * Alignment. The decimator's half-length is padded with an OS-rate delay
//   so interpolator + decimator delay is a whole number of host samples; the
//   bypass is that long exactly. It used to be rounded (146 OS = 9.125 host
//   samples at 16x, bypass 9), leaving the residual 1/8 host sample late:
//   -16 dB of uncancelled residual at 38 kHz.
// * Interpolation. A 2x linear-phase Kaiser FIR, then the causal Lagrange-4
//   to the full factor. Lagrange alone from the host rate imaged 53 kHz
//   content at -21 dB (38 kHz at -32 dB) whatever the factor, so the clip
//   decisions were taken on a waveform up to 9 % wrong; on the 2x stream the
//   image is -44 dB.
//
// Pilot (19 kHz) and RDS (57 kHz) are injected post-clipper, so their
// amplitudes bypass this stage; the pilot and RDS guards keep clipper IM out
// from under them.
struct CompositeClipper {
    private var thresholdLin: Float = 0.708
    private var ceilingLin: Float = 0.944
    private var knee: Float = 0.236
    /// Configured ceiling as a linear amplitude; the final stage normalises
    /// the audio composite so this ceiling lands exactly on the composite budget.
    var ceilingLinear: Float { ceilingLin }

    /// Oversampling factor (8 / 16 / 32), `mpx_clipper_oversampling`.
    /// Applies live: a change re-runs `configure` (filters and batch buffers
    /// re-sized for the new factor) and the generator re-times the pilot /
    /// RDS delay to the clipper's new group delay.
    private var factor: Int = 16
    /// Batch buffers are allocated for the largest factor before
    /// `configure()` runs, so the audio thread never allocates.
    private static let defaultFactor: Int = 32

    // === Interpolation: 2x Kaiser FIR, then Lagrange-4 on the 2x stream ===
    private var interp = LinearPhaseFIRInterpolator()
    private var lag = Lagrange4Interp()
    private var interpPair: [Float] = [0.0, 0.0]
    /// Lagrange basis weights for the `factor / 2` phases between two 2x
    /// samples (t = (i + 1) / (factor / 2)).
    private var lagBasis: [SIMD4<Float>] = Array(repeating: .zero, count: defaultFactor / 2)
    /// OS-rate delay of the interpolation section: the last OS sample of a
    /// host step represents the input this many OS samples ago.
    private var interpDelayOS: Int = 0

    // === Decimation of the residual ===
    private var decimLP = LinearPhaseFIRDecimator()
    /// OS-rate pad in front of the decimator: interpolator + pad + decimator
    /// add up to a whole number of host samples.
    private var padLine: [Float] = []
    private var padIndex: Int = 0
    /// Host samples from xPath to the decimated residual.
    private var residualDelayHost: Int = 0

    // === Guard bands: one linear-phase FIR on the host-rate residual ===
    private var guardKernel: [Float] = []
    private var guardLine: [Float] = []
    private var guardIndex: Int = 0
    /// Consecutive exact-zero samples written into `guardLine`.
    private var guardZeroRun: Int = 0
    private var guardTaps: Int = 0
    private var guardHalf: Int = 0
    /// Guard FIR transition (Hz) and depth (dB). The edges sit in the gaps
    /// between the bands, so a 2 kHz transition protects every band in full.
    static let guardTransitionHz: Float = 2_000.0
    static let guardDepthDB: Float = 50.0
    /// Band edges (Hz): audio | pilot | stereo | RDS.
    static let guardEdgesHz: (audioPilot: Float, pilotStereo: Float, stereoRDS: Float, rdsTop: Float) =
        (16_000.0, 22_000.0, 54_000.0, 60_000.0)

    /// Host-rate bypass delay line: the wanted signal, delayed to line up
    /// with the decimated, guarded residual.
    private var bypassDelay: [Float] = [0.0]
    private var bypassWriteIdx: Int = 0

    private var cancelAudio: Bool = false
    /// 0...1 share of the 22-54 kHz clipping residual restored to the output
    /// (`mpx_clipper_stereo_guard`). 1: the S subchannel passes untouched and
    /// only the M share of each peak is clipped; the Final-MPX limiter rides
    /// the overshoot. 0: full composite clipping (industry practice).
    private var stereoGuard: Float = 1.0
    private var cancelPilot: Bool = true
    private var cancelRDS: Bool = true

    // Soft-clip attenuation telemetry for the UI meter: the oversampled
    // clip-kernel gain, not an input/output peak ratio.
    private var clipGainEnv: Float = 1.0
    private var peakDecayCoeff: Float = 0.0

    // Batch buffers for vvtanhf-accelerated soft clipping, one oversample
    // step per element.
    private var upBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)
    private var clipBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)
    private var clipExcessBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)
    private var clipTanhBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)

    // === Look-ahead peak control (0.26) ===
    // Predictive sidechain that knows the peak over the next
    // `lookaheadHostSamples` host samples. A gain applied at the input makes
    // the clip kernel see an already-shaved signal. Sliding-window-max
    // detector (Lemire deque) over the detector's own interpolated OS stream,
    // so intersample peaks count. Disabled when the window is 0.
    private var lookaheadEnabled: Bool = false
    private var lookaheadHostSamples: Int = 0
    private var lookaheadDelay: [Float] = []
    private var lookaheadResizeScratch: [Float] = []
    private var lookaheadDelayWriteIdx: Int = 0
    private var deqValues: [Float] = []
    private var deqIndices: [Int] = []
    private var deqCapacity: Int = 0
    private var deqHead: Int = 0
    private var deqTail: Int = 0
    private var deqSampleCounter: Int = 0
    // The detector's own interpolator (same design as the audio path) on the
    // UN-delayed input.
    private var detInterp = LinearPhaseFIRInterpolator()
    private var detLag = Lagrange4Interp()
    private var detPair: [Float] = [0.0, 0.0]
    private var detOSBatch: [Float] = Array(repeating: 0.0, count: defaultFactor)
    // Gain: window-minimum target -> `LookaheadGainRamp` (instant-attack
    // hold, 80 ms release, two cascaded moving averages spanning the window).
    // The ramp arrives at the required gain exactly when the peak reaches the
    // clip kernel. Until 2026-10 an exponential attack (time constant
    // window / 4) followed by a 200 Hz one-pole reached only 81 % of the
    // needed reduction on arrival (F10). The box cascade is also the better
    // spectral guard: two 1 ms boxes are -46 dB at a 4 kHz offset where the
    // 200 Hz one-pole was -26 dB, so the gain cannot move 15 kHz program
    // into the pilot band.
    private var ramp = LookaheadGainRamp()
    private var lookaheadReleaseCoeff: Float = 0.0
    // Telemetry: minimum look-ahead gain with a 50 ms decay.
    private var lookaheadGainEnv: Float = 1.0

    mutating func configure(sampleRate: Float, thresholdDB: Float, ceilingDB: Float,
                            cancelAudio: Bool = false, stereoGuard: Float = 1.0,
                            cancelPilot: Bool = true, cancelRDS: Bool = true,
                            lookaheadMS: Float = 0.0,
                            oversamplingFactor: Int = 16) {
        // Only accept 8 / 16 / 32 (AppConfig.sanitize() clamps the same way).
        let validFactor: Int
        switch oversamplingFactor {
        case ...8:        validFactor = 8
        case 9...16:      validFactor = 16
        default:          validFactor = 32
        }
        self.factor = validFactor
        let half = validFactor / 2
        if upBatch.count != validFactor { upBatch = [Float](repeating: 0.0, count: validFactor) }
        if clipBatch.count != validFactor { clipBatch = [Float](repeating: 0.0, count: validFactor) }
        if clipExcessBatch.count != validFactor { clipExcessBatch = [Float](repeating: 0.0, count: validFactor) }
        if clipTanhBatch.count != validFactor { clipTanhBatch = [Float](repeating: 0.0, count: validFactor) }
        if detOSBatch.count != validFactor { detOSBatch = [Float](repeating: 0.0, count: validFactor) }
        if lagBasis.count != half { lagBasis = [SIMD4<Float>](repeating: .zero, count: half) }
        let basisStep = 1.0 / Float(half)
        for i in 0..<half {
            lagBasis[i] = Lagrange4Interp.basisWeights(t: basisStep * Float(i + 1))
        }

        thresholdLin = clampf(powf(10.0, min(0.0, thresholdDB) / 20.0), 0.1, 0.995)
        let cMin: Float = thresholdLin + 0.02
        ceilingLin = clampf(powf(10.0, min(0.0, ceilingDB) / 20.0), cMin, 0.999)
        knee = max(1e-4, ceilingLin - thresholdLin)
        let sr = max(8_000.0, sampleRate)
        let osRate = sr * Float(self.factor)

        // 2x interpolator: passband the audio composite (0-53 kHz), stopband
        // from the first image of 53 kHz (host rate - 53 kHz). 90 dB; the tap
        // count floor (63) makes it far better than that at 192 kHz.
        let composite: Float = min(53_000.0, sr * 0.45)
        let interpTransition = max(2_000.0, sr - (2.0 * composite))
        interp.configure(cutoffHz: composite, sampleRateOS: 2.0 * sr, interpolateFactor: 2,
                         stopBandDB: 90.0, transitionHz: interpTransition)
        detInterp.configure(cutoffHz: composite, sampleRateOS: 2.0 * sr, interpolateFactor: 2,
                            stopBandDB: 90.0, transitionHz: interpTransition)
        interpPair = [0.0, 0.0]
        detPair = [0.0, 0.0]
        lag = Lagrange4Interp()
        detLag = Lagrange4Interp()
        // Output p of a push at host step n is y[2n + p] ~ x(n + (p - c) / 2),
        // c the kernel centre; the last one (p = 1) is (c - 1) / 2 host samples
        // late, i.e. (c - 1) x factor / 2 OS samples. The causal Lagrange
        // section adds none (its last point IS the 2x sample).
        let centre = interp.groupDelayOSSamples
        interpDelayOS = max(0, (centre - 1) * half)

        // FIR decimator for the residual: passband the whole audio composite
        // (0-53 kHz), stopband from 113 kHz with a 60 kHz transition (-6 dB
        // at 83 kHz), 90 dB. Kaiser-sinc, tap count auto-sized (293 at 16x).
        let firPassband = clampf(53_000.0, 20_000.0, osRate * 0.45)
        let firTransition: Float = 60_000.0
        decimLP.configure(
            cutoffHz: firPassband,
            sampleRateOS: osRate,
            decimateFactor: self.factor,
            stopBandDB: 90.0,
            transitionHz: firTransition
        )
        let osDelay = interpDelayOS + decimLP.groupDelayOSSamples
        let pad = (self.factor - (osDelay % self.factor)) % self.factor
        padLine = [Float](repeating: 0.0, count: pad)
        padIndex = 0
        residualDelayHost = (osDelay + pad) / self.factor

        self.cancelAudio = cancelAudio
        self.stereoGuard = clampf(stereoGuard, 0.0, 1.0)
        self.cancelPilot = cancelPilot
        self.cancelRDS = cancelRDS
        configureGuard(sampleRate: sr)

        let bypassLen = max(1, residualDelayHost + guardHalf)
        bypassDelay = [Float](repeating: 0.0, count: bypassLen)
        bypassWriteIdx = 0

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
        deqCapacity = (cap + 1) * self.factor + 2
        deqValues = [Float](repeating: 0.0, count: deqCapacity)
        deqIndices = [Int](repeating: 0, count: deqCapacity)
        deqHead = 0
        deqTail = 0
        deqSampleCounter = 0
        lookaheadDelayWriteIdx = 0
        // Release time constant: 80 ms (hardcoded).
        lookaheadReleaseCoeff = expf(-1.0 / (0.080 * sr))
        ramp.configure(rampSamples: rampSamples(window: n), holdSamples: n,
                       releaseCoeff: lookaheadReleaseCoeff,
                       capacityRampSamples: rampSamples(window: cap))
        lookaheadGainEnv = 1.0
    }

    /// The longest gain ramp that still arrives in time: the detector sees
    /// the input through its own interpolator (late by its group delay) and
    /// the gain itself is interpolated with the audio path (smeared over the
    /// kernel), so both are taken off the window.
    private func rampSamples(window n: Int) -> Int {
        let interpHost = (interpDelayOS + factor - 1) / factor
        return max(0, n - (2 * interpHost) - 1)
    }

    /// Design the guard FIR for the enabled bands (allocates; configure only).
    private mutating func configureGuard(sampleRate sr: Float) {
        let edges = Self.guardEdgesHz
        var bands: [(lo: Float, hi: Float, weight: Float)] = []
        if cancelAudio { bands.append((0.0, edges.audioPilot, 1.0)) }
        if cancelPilot { bands.append((edges.audioPilot, edges.pilotStereo, 1.0)) }
        if stereoGuard > 0.0 { bands.append((edges.pilotStereo, edges.stereoRDS, stereoGuard)) }
        if cancelRDS { bands.append((edges.stereoRDS, edges.rdsTop, 1.0)) }
        guardKernel = Self.guardKernel(sampleRate: sr, bands: bands,
                                       transitionHz: Self.guardTransitionHz,
                                       depthDB: Self.guardDepthDB)
        guardTaps = guardKernel.count
        guardHalf = guardTaps > 0 ? (guardTaps - 1) / 2 : 0
        guardLine = [Float](repeating: 0.0, count: guardTaps * 2)
        guardIndex = 0
        guardZeroRun = 0
    }

    /// Linear-phase "keep" kernel: a delta at the centre minus the weighted
    /// sum of Kaiser-windowed band-pass kernels. Empty when no band applies.
    /// Exposed for tests (the guard depth is measured on this kernel).
    static func guardKernel(sampleRate: Float, bands: [(lo: Float, hi: Float, weight: Float)],
                            transitionHz: Float, depthDB: Float) -> [Float] {
        let sr = max(8_000.0, sampleRate)
        let nyquist = sr * 0.5
        let usable = bands.filter { $0.weight > 0.0 && $0.lo < nyquist - 1_000.0 && $0.hi > $0.lo }
        guard !usable.isEmpty else { return [] }
        let attenuation = max(21.0, depthDB)
        let rawN = Int(ceilf((attenuation - 8.0) / (2.285 * 2.0 * .pi * (transitionHz / sr))))
        let count = max(63, min(2_049, rawN | 1))
        let beta: Float = attenuation > 50.0
            ? 0.1102 * (attenuation - 8.7)
            : (0.5842 * powf(attenuation - 21.0, 0.4)) + (0.07886 * (attenuation - 21.0))
        let i0Beta = kaiserI0(beta)
        let centre = (count - 1) / 2
        var kernel = [Float](repeating: 0.0, count: count)
        // Lowpass impulse response with cutoff f (Double for the long sums).
        func lowpass(_ f: Double, _ m: Int) -> Double {
            if m == 0 { return 2.0 * f / Double(sr) }
            let mm = Double(m)
            return sin(2.0 * Double.pi * f * mm / Double(sr)) / (Double.pi * mm)
        }
        for k in 0..<count {
            let m = k - centre
            var band: Double = 0.0
            for b in usable {
                let hi = min(Double(b.hi), Double(nyquist))
                band += Double(b.weight) * (lowpass(hi, m) - lowpass(Double(b.lo), m))
            }
            let u = Float(2 * m) / Float(count - 1)
            let window = kaiserI0(beta * sqrtf(max(0.0, 1.0 - (u * u)))) / i0Beta
            let keep = (m == 0 ? 1.0 : 0.0) - (band * Double(window))
            kernel[k] = Float(keep)
        }
        return kernel
    }

    /// Total host-rate delay added by this clipper: look-ahead window plus
    /// interpolator, decimator and guard FIR group delay. The pilot/RDS
    /// subcarrier delay is built from it.
    var totalDelayHostSamples: Int {
        lookaheadHostSamples + bypassDelay.count
    }

    /// Maximum delay this configured clipper can add without reallocating
    /// during a live look-ahead resize.
    var maxTotalDelayHostSamples: Int {
        lookaheadDelay.count + bypassDelay.count
    }

    /// Focused live update of the look-ahead window only. Keeps the gain
    /// state (a slider drag must not snap the gain), resizes the delay within
    /// the preallocated capacity without allocating, and resets the detector
    /// deque (it refills within the window). Interpolators, decimator,
    /// bypass and guard are untouched.
    mutating func setLookaheadMS(_ lookaheadMS: Float, sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        let cap = Int((5.0 / 1000.0) * sr)
        let storageCap = min(cap, lookaheadDelay.count)
        let n = max(0, min(storageCap, Int(roundf((lookaheadMS / 1000.0) * sr))))
        let oldN = lookaheadHostSamples
        let oldEnabled = lookaheadEnabled
        let newEnabled = n > 0

        if newEnabled, n != oldN {
            // Preserve audio content: read oldest-to-newest into scratch,
            // then prepend zeros or drop the oldest to fit the new length.
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
        }
        lookaheadDelayWriteIdx = 0
        deqHead = 0
        deqTail = 0
        deqSampleCounter = 0
        lookaheadHostSamples = n
        lookaheadEnabled = newEnabled
        ramp.resize(rampSamples: rampSamples(window: n), holdSamples: n)
    }

    /// Lookahead gain reduction in dB (positive = look-ahead is shaving
    /// peaks), decayed at ~50 ms. Separate from `gainReductionDB` so
    /// operators can tell predictive shaving (clean) from soft clipping.
    var lookaheadGainReductionDB: Float {
        let g = max(1e-6, lookaheadGainEnv)
        return max(0.0, -20.0 * log10f(g))
    }

    /// One host sample through the 2x FIR + Lagrange interpolator into `out`
    /// (`factor` OS samples, chronological).
    @inline(__always)
    private static func upsample(_ x: Float, interp: inout LinearPhaseFIRInterpolator,
                                 lag: inout Lagrange4Interp, pair: inout [Float],
                                 basis: [SIMD4<Float>], half: Int, out: inout [Float]) {
        pair.withUnsafeMutableBufferPointer { p in
            // swiftlint:disable:next force_unwrapping
            interp.push(x, into: p.baseAddress!)
        }
        if !lag.isPrimed { lag.prime(pair[0]) }
        out.withUnsafeMutableBufferPointer { o in
            for j in 0..<2 {
                let y = pair[j]
                let base = j * half
                for i in 0..<(half - 1) {
                    o[base + i] = lag.interpolate(weights: basis[i], cur: y)
                }
                o[base + half - 1] = y
                lag.advance(y)
            }
        }
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let f = self.factor
        let half = f / 2

        // === Phase 0: look-ahead peak control ===
        let xPath: Float
        if lookaheadEnabled {
            // 1. Detector: interpolate the UN-delayed input and push every OS
            //    sample into the sliding-window maximum. The window spans one
            //    host sample more than the delay, so the OS interval the audio
            //    path is about to clip (between the delayed sample and the one
            //    before it) is always inside it (F10).
            Self.upsample(x, interp: &detInterp, lag: &detLag, pair: &detPair,
                          basis: lagBasis, half: half, out: &detOSBatch)
            let nWindowOS = (lookaheadHostSamples + 1) * f
            for i in 0..<f {
                let absV = fabsf(detOSBatch[i])
                let curIdx = deqSampleCounter
                let oldestValidIdx = curIdx - nWindowOS + 1
                while deqHead != deqTail && deqIndices[deqHead] < oldestValidIdx {
                    deqHead += 1
                    if deqHead >= deqCapacity { deqHead = 0 }
                }
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

            // 2. Required gain over the window, ramped (see `ramp`).
            let peakAhead = (deqHead != deqTail) ? deqValues[deqHead] : 0.0
            let gTarget: Float = peakAhead > ceilingLin
                ? ceilingLin / max(1e-6, peakAhead)
                : 1.0
            let g = ramp.push(gTarget)
            lookaheadGainEnv = min(g, 1.0 - (1.0 - lookaheadGainEnv) * peakDecayCoeff)

            // 3. Delayed input, gain applied before the interpolator, so the
            //    clip kernel and the bypass see the same scaled signal.
            let dLen = lookaheadHostSamples
            let xDelayed = lookaheadDelay[lookaheadDelayWriteIdx]
            lookaheadDelay[lookaheadDelayWriteIdx] = x
            lookaheadDelayWriteIdx += 1
            if lookaheadDelayWriteIdx >= dLen { lookaheadDelayWriteIdx = 0 }
            xPath = xDelayed * g
        } else {
            xPath = x
            // Decay the telemetry toward 1.0 so a disable does not pin it.
            lookaheadGainEnv = 1.0 - (1.0 - lookaheadGainEnv) * peakDecayCoeff
        }

        // === Phase 1: oversample the path ===
        Self.upsample(xPath, interp: &interp, lag: &lag, pair: &interpPair,
                      basis: lagBasis, half: half, out: &upBatch)

        // === Phase 2: batched soft clip (vvtanhf) ===
        let thr = thresholdLin
        let kn = knee
        // Idle fast path (bit-identical): when no OS sample of this host
        // sample exceeds the threshold the clip kernel is the identity, the
        // residual is exactly zero and the tanh batch is never read.
        var anyOver = false
        upBatch.withUnsafeBufferPointer { ub in
            for i in 0..<f where fabsf(ub[i]) > thr { anyOver = true; break }
        }
        if anyOver {
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
        }
        var sampleClipGain: Float = 1.0
        if anyOver {
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
        }

        // === Phase 3: residual -> pad -> decimator (differential topology) ===
        //     out_HOST = bypass_delayed - guard(decimate(up - clipped))
        // Only the clipping residual sees the decimator; the wanted signal
        // rides the delay-matched bypass.
        var residualDecimated: Float = 0.0
        let padLen = padLine.count
        for i in 0..<f {
            var r: Float = anyOver ? upBatch[i] - clipBatch[i] : 0.0
            if padLen > 0 {
                let delayed = padLine[padIndex]
                padLine[padIndex] = r
                padIndex += 1
                if padIndex >= padLen { padIndex = 0 }
                r = delayed
            }
            residualDecimated = decimLP.push(r)
        }

        // === Phase 4: guard bands (linear-phase FIR on the host residual) ===
        if guardTaps > 0 {
            guardLine[guardIndex] = residualDecimated
            guardLine[guardIndex + guardTaps] = residualDecimated
            guardIndex += 1
            if guardIndex >= guardTaps { guardIndex = 0 }
            // A window of exact zeros dots to exactly +0: skip it.
            guardZeroRun = residualDecimated == 0.0 ? guardZeroRun + 1 : 0
            var kept: Float = 0.0
            let count = vDSP_Length(guardTaps)
            if guardZeroRun < guardTaps {
            guardKernel.withUnsafeBufferPointer { k in
                guardLine.withUnsafeBufferPointer { d in
                    // swiftlint:disable force_unwrapping
                    vDSP_dotpr(k.baseAddress!, 1, d.baseAddress!.advanced(by: guardIndex), 1,
                               &kept, count)
                    // swiftlint:enable force_unwrapping
                }
            }
            }
            residualDecimated = kept
        }

        // === Phase 5: bypass ===
        let bypassLen = bypassDelay.count
        let bypassed = bypassDelay[bypassWriteIdx]
        bypassDelay[bypassWriteIdx] = xPath
        bypassWriteIdx += 1
        if bypassWriteIdx >= bypassLen { bypassWriteIdx = 0 }

        let out = bypassed - residualDecimated

        clipGainEnv = min(sampleClipGain, 1.0 - (1.0 - clipGainEnv) * peakDecayCoeff)
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
