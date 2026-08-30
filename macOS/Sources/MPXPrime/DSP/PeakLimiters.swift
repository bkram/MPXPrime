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

/// Stereo-linked 4x oversampled true-peak limiter used by
/// `PreEncodeAudioLimiter` on L/R before stereo encoding. Shared gain
/// envelope driven by `max(|L_os|, |R_os|)` at OS rate; per-channel
/// Lagrange interpolation and linear-phase FIR decimation.
///
/// Operating on independent audio channels (no multiplexed subcarrier),
/// the trailing tanh ceiling is normal soft-knee limiter behaviour.
/// **Never use this on the FM composite signal** -- a memoryless tanh on a
/// (M + S sin 38k) waveform creates intermod that demodulates as
/// stereo-image collapse. Composite-domain peak control belongs in
/// `CompositeClipper` (distortion-cancelled).
///
/// Replaced the prior per-channel limiter pair, which made independent
/// gain decisions and produced an asymmetric image on hard-panned content
/// (the chain-order audit recorded a +15 dB side-to-mid blowup on the
/// synthetic `hard_panned_hf` scenario in 0.25). Stereo-linked detection
/// applies the same GR to both channels, so L/R balance is preserved even
/// when one channel peaks asymmetrically.
struct StereoLinkedOversampledPeakLimiter {
    var threshold: Float = 0.94
    var releaseMS: Float = 35.0
    var ceiling: Float = 0.985
    var bandlimitedResidualEnabled: Bool = false
    // Precomputed soft-knee width (ceiling - threshold, floored at 1e-4).
    // Depends only on configure() inputs, so it is computed once there
    // instead of per over-threshold sample in clipToCeiling.
    private var ceilingKnee: Float = 1e-4

    // Shared envelope state (the load-bearing change vs the prior pair
    // of independent OversampledPeakLimiters: same gain for both L/R).
    private var gain: Float = 1.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0

    // Per-channel Lagrange-4 interpolator state
    private var lPrev3: Float = 0.0
    private var lPrev2: Float = 0.0
    private var lPrev1: Float = 0.0
    private var rPrev3: Float = 0.0
    private var rPrev2: Float = 0.0
    private var rPrev1: Float = 0.0
    // Per-channel 4:1 decimator: linear-phase Kaiser FIR designed at the OS
    // rate (see configure). Until 0.45 this was a 6th-order Butterworth at
    // 0.30 x host rate -- 14.4 kHz at the 48 kHz audio domain, i.e. -2.3 dB
    // at 14 kHz / -4 dB at 14.9 kHz on the program AFTER the encoder FIR,
    // with only -27 dB alias rejection at 24 kHz.
    private var lDecim = LinearPhaseFIRDecimator()
    private var rDecim = LinearPhaseFIRDecimator()
    private var lResidualClipper = AcceleratedBandlimitedResidualClipper()
    private var rResidualClipper = AcceleratedBandlimitedResidualClipper()
    private var initialized: Bool = false

    // Look-ahead: audio-rate delay so the detector sees the incoming peak
    // before it reaches the gain stage, letting the attack ramp engage
    // ahead of the audio. lookaheadSamples == 0 → bit-identical to the
    // no-lookahead path (cheap regression guard). Prior art: US 4,208,548
    // (delay+detector primitive, expired ~1997).
    private var lookaheadSamples: Int = 0
    private var lDelay: [Float] = []
    private var rDelay: [Float] = []
    private var delayWriteIndex: Int = 0

    // Phase 2: HF-subband-aware look-ahead per US 5,579,404 / EP 0685130
    // (Dolby, expired 2013). When `lookaheadHFOnly` is true, the detector
    // path runs through a 2nd-order Butterworth high-pass at ~4 kHz so
    // futurePeak only fires on HF transients. Audio path stays full-band.
    // Architecturally clean: pre-emphasis concentrates peaks above ~3 kHz,
    // so the detector matches the band where the limiter actually fights.
    // LF dynamics (kick, bass) are not subject to the look-ahead's gain
    // ramp and retain their punch.
    private var lookaheadHFOnly: Bool = false
    private var hfDetectorL = Biquad()
    private var hfDetectorR = Biquad()

    mutating func configure(
        sampleRate: Float,
        threshold: Float,
        releaseMS: Float = 35.0,
        bandlimitedResidualEnabled: Bool = false,
        residualTapCount: Int = 33,
        residualCutoffFraction: Float = 0.25,
        lookaheadMS: Float = 0.0,
        lookaheadHFOnly: Bool = false,
        lookaheadHFCutoffHz: Float = 4_000.0
    ) {
        let sr = max(8_000.0, sampleRate * 4.0)
        self.threshold = clampf(threshold, 0.75, 0.995)
        self.releaseMS = max(8.0, releaseMS)
        self.bandlimitedResidualEnabled = bandlimitedResidualEnabled
        let ceilingMargin = max(0.012, (1.0 - self.threshold) * 0.65)
        ceiling = min(0.999, self.threshold + ceilingMargin)
        ceilingKnee = max(1e-4, ceiling - threshold)

        let attackS = 0.00025 as Float
        let relS = max(0.008, Double(self.releaseMS) * 0.001)
        attackCoeff = expf(-1.0 / (attackS * sr))
        releaseCoeff = expf(-1.0 / Float(relS * Double(sr)))
        holdSamples = max(1, Int((0.004 * sr).rounded()))
        holdCounter = 0
        gain = 1.0
        lPrev3 = 0.0; lPrev2 = 0.0; lPrev1 = 0.0
        rPrev3 = 0.0; rPrev2 = 0.0; rPrev1 = 0.0
        // Decimator doubling as the post-limiter 15 kHz band-limit in the
        // PRE-EMPHASISED domain (Orban: "band-limit slightly above 15 kHz,
        // embedded before the composite stage"). The encoder FIR (14.9 kHz,
        // -6 dB at 15.65 kHz) runs before pre-emphasis, so its transition
        // tail arrives here boosted by +14 dB; this filter matches its
        // transition (15.0 kHz passband, 80 dB by 16.5 kHz at the 48 kHz
        // audio domain) so the cascade rolls off twice as fast, the ceiling's
        // products cannot fold back into the program, and the 15-23 kHz gap
        // around the pilot stays clean. ~640 taps at 192 kHz OS (vDSP dot
        // product), 1.67 ms. The transition scales with the host rate so the
        // legacy 192 kHz-domain path stays affordable (6 kHz).
        let passbandHz: Float = 15_000.0
        let transitionHz = max(1_500.0, sampleRate / 32.0)
        lDecim.configure(cutoffHz: passbandHz, sampleRateOS: sr, decimateFactor: 4,
                         stopBandDB: 80.0, transitionHz: transitionHz)
        rDecim.configure(cutoffHz: passbandHz, sampleRateOS: sr, decimateFactor: 4,
                         stopBandDB: 80.0, transitionHz: transitionHz)
        lResidualClipper.configure(
            threshold: ceiling,
            tapCount: residualTapCount,
            cutoffFraction: residualCutoffFraction
        )
        rResidualClipper.configure(
            threshold: ceiling,
            tapCount: residualTapCount,
            cutoffFraction: residualCutoffFraction
        )

        // Look-ahead delay buffers (audio-rate). Clamp 0-5 ms — anything
        // above ~3 ms is past the point of diminishing returns for HF
        // transient capture on this stage and starts costing real chain
        // latency.
        let clampedLookahead = clampf(lookaheadMS, 0.0, 5.0)
        let newLookaheadSamples = max(0, Int((sampleRate * clampedLookahead * 0.001).rounded()))
        if newLookaheadSamples != lookaheadSamples {
            lookaheadSamples = newLookaheadSamples
            lDelay = lookaheadSamples > 0 ? Array(repeating: 0.0, count: lookaheadSamples) : []
            rDelay = lookaheadSamples > 0 ? Array(repeating: 0.0, count: lookaheadSamples) : []
            delayWriteIndex = 0
        }

        // Phase 2 detector HP at host rate. Clamp cutoff 1-12 kHz; default
        // 4 kHz matches the Dolby spec where pre-emphasis-induced peaks
        // start dominating. Reset filter state on each reconfigure.
        self.lookaheadHFOnly = lookaheadHFOnly
        let hfCutoff = clampf(lookaheadHFCutoffHz, 1_000.0, 12_000.0)
        hfDetectorL.configureHighpass(cutoffHz: hfCutoff, sampleRate: sampleRate)
        hfDetectorR.configureHighpass(cutoffHz: hfCutoff, sampleRate: sampleRate)
        hfDetectorL.reset()
        hfDetectorR.reset()

        initialized = false
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        // Look-ahead: the detector reads the un-delayed input while the
        // audio path processes the delayed sample. With attack time
        // calibrated near lookaheadSamples / sampleRate the gain ramp is
        // already fully engaged when the actual peak reaches the gain
        // stage. lookaheadSamples == 0 short-circuits to the legacy path
        // for bit-identical regression behavior.
        var procL = left
        var procR = right
        var futurePeak: Float = 0.0
        if lookaheadSamples > 0, !lDelay.isEmpty {
            // Detector input: full-band (Phase 1) or HF-filtered (Phase 2).
            // HF mode high-passes a COPY of the input through a biquad so
            // futurePeak only triggers on HF transients (the band where
            // pre-emphasis concentrates peaks). Audio path stays full-band.
            if lookaheadHFOnly {
                let hpL = hfDetectorL.process(left)
                let hpR = hfDetectorR.process(right)
                futurePeak = max(fabsf(hpL), fabsf(hpR))
            } else {
                futurePeak = max(fabsf(left), fabsf(right))
            }
            procL = lDelay[delayWriteIndex]
            procR = rDelay[delayWriteIndex]
            lDelay[delayWriteIndex] = left
            rDelay[delayWriteIndex] = right
            delayWriteIndex += 1
            if delayWriteIndex >= lookaheadSamples {
                delayWriteIndex = 0
            }
        }

        if !initialized {
            initialized = true
            lPrev3 = procL; lPrev2 = procL; lPrev1 = procL
            rPrev3 = procR; rPrev2 = procR; rPrev1 = procR
            let (qL, qR) = stereoStep(lOS: procL, rOS: procR, futurePeakHint: futurePeak)
            return (decimate(qL, qL, qL, qL, ch: .left),
                    decimate(qR, qR, qR, qR, ch: .right))
        }

        // 4x upsample both channels via Lagrange interp.
        let l1 = interpolateLagrange4(t: 0.25, current: procL,
                                      p3: lPrev3, p2: lPrev2, p1: lPrev1)
        let l2 = interpolateLagrange4(t: 0.50, current: procL,
                                      p3: lPrev3, p2: lPrev2, p1: lPrev1)
        let l3 = interpolateLagrange4(t: 0.75, current: procL,
                                      p3: lPrev3, p2: lPrev2, p1: lPrev1)
        let l4 = procL
        let r1 = interpolateLagrange4(t: 0.25, current: procR,
                                      p3: rPrev3, p2: rPrev2, p1: rPrev1)
        let r2 = interpolateLagrange4(t: 0.50, current: procR,
                                      p3: rPrev3, p2: rPrev2, p1: rPrev1)
        let r3 = interpolateLagrange4(t: 0.75, current: procR,
                                      p3: rPrev3, p2: rPrev2, p1: rPrev1)
        let r4 = procR

        // Stereo-linked gain step at each OS position. Same gain
        // applied to both channels each step. The future-peak hint biases
        // the detector toward an incoming (un-delayed) peak so the
        // attack engages early.
        let (qL1, qR1) = stereoStep(lOS: l1, rOS: r1, futurePeakHint: futurePeak)
        let (qL2, qR2) = stereoStep(lOS: l2, rOS: r2, futurePeakHint: futurePeak)
        let (qL3, qR3) = stereoStep(lOS: l3, rOS: r3, futurePeakHint: futurePeak)
        let (qL4, qR4) = stereoStep(lOS: l4, rOS: r4, futurePeakHint: futurePeak)

        let outL = decimate(qL1, qL2, qL3, qL4, ch: .left)
        let outR = decimate(qR1, qR2, qR3, qR4, ch: .right)

        lPrev3 = lPrev2; lPrev2 = lPrev1; lPrev1 = procL
        rPrev3 = rPrev2; rPrev2 = rPrev1; rPrev1 = procR
        return (outL, outR)
    }

    var gainReductionDB: Float {
        let safeGain = max(1e-6, gain)
        return max(0.0, -20.0 * log10f(safeGain))
    }

    /// Host-rate samples of delay this stage adds to the L/R path: the
    /// look-ahead delay line plus the decimator's group delay.
    var latencySamples: Int { lookaheadSamples + lDecim.groupDelayHostSamples }

    @inline(__always)
    private mutating func stereoStep(lOS: Float, rOS: Float, futurePeakHint: Float = 0.0) -> (Float, Float) {
        // Stereo-linked detector: peak of either channel drives the
        // shared gain envelope. This is the core of the stereo-link
        // discipline — both channels see the same multiplicative gain.
        // `futurePeakHint` (look-ahead path) is the un-delayed input
        // peak; using max() ensures we never under-detect when a peak
        // is incoming but not yet at the gain stage.
        let osPeak = max(fabsf(lOS), fabsf(rOS))
        let peak = max(osPeak, futurePeakHint)
        var targetGain: Float = 1.0
        if peak > threshold {
            targetGain = threshold / max(1e-9, peak)
        }
        targetGain = clampf(targetGain, 0.0, 1.0)

        if targetGain < gain {
            gain = (attackCoeff * gain) + ((1.0 - attackCoeff) * targetGain)
            holdCounter = holdSamples
        } else if holdCounter > 0 {
            holdCounter -= 1
        } else {
            gain = (releaseCoeff * gain) + ((1.0 - releaseCoeff) * targetGain)
        }

        let yL = lOS * gain
        let yR = rOS * gain
        return (clipToCeiling(yL, ch: .left), clipToCeiling(yR, ch: .right))
    }

    @inline(__always)
    private func interpolateLagrange4(t: Float, current: Float,
                                      p3: Float, p2: Float, p1: Float) -> Float {
        // Causal 4-point Lagrange reconstruction between p1 and current.
        let l0 = -((t + 1.0) * t * (t - 1.0)) / 6.0
        let l1 = ((t + 2.0) * t * (t - 1.0)) * 0.5
        let l2 = -((t + 2.0) * (t + 1.0) * (t - 1.0)) * 0.5
        let l3 = ((t + 2.0) * (t + 1.0) * t) / 6.0
        return (p3 * l0) + (p2 * l1) + (p1 * l2) + (current * l3)
    }

    private enum Channel { case left, right }

    @inline(__always)
    private mutating func decimate(_ q1: Float, _ q2: Float, _ q3: Float, _ q4: Float,
                                   ch: Channel) -> Float {
        // Exactly four pushes per host sample, so the fourth push is the
        // one that emits a decimated output.
        switch ch {
        case .left:
            _ = lDecim.push(q1)
            _ = lDecim.push(q2)
            _ = lDecim.push(q3)
            return lDecim.push(q4)
        case .right:
            _ = rDecim.push(q1)
            _ = rDecim.push(q2)
            _ = rDecim.push(q3)
            return rDecim.push(q4)
        }
    }

    @inline(__always)
    private mutating func clipToCeiling(_ x: Float, ch: Channel) -> Float {
        if bandlimitedResidualEnabled {
            switch ch {
            case .left:
                return lResidualClipper.process(x)
            case .right:
                return rResidualClipper.process(x)
            }
        }
        let ax = fabsf(x)
        if ax <= threshold { return x }
        let clipped = threshold + ((ceiling - threshold) * tanhf((ax - threshold) / ceilingKnee))
        return copysignf(min(clipped, ceiling), x)
    }
}

struct PreEncodeAudioLimiter {
    private var limiter = StereoLinkedOversampledPeakLimiter()
    private var gainReduction: Float = 0.0

    mutating func configure(
        sampleRate: Float,
        threshold: Float,
        releaseMS: Float = 50.0,
        bandlimitedResidualEnabled: Bool = false,
        residualTapCount: Int = 33,
        residualCutoffFraction: Float = 0.25,
        lookaheadMS: Float = 0.0,
        lookaheadHFOnly: Bool = false,
        lookaheadHFCutoffHz: Float = 4_000.0
    ) {
        limiter.configure(
            sampleRate: sampleRate,
            threshold: threshold,
            releaseMS: releaseMS,
            bandlimitedResidualEnabled: bandlimitedResidualEnabled,
            residualTapCount: residualTapCount,
            residualCutoffFraction: residualCutoffFraction,
            lookaheadMS: lookaheadMS,
            lookaheadHFOnly: lookaheadHFOnly,
            lookaheadHFCutoffHz: lookaheadHFCutoffHz
        )
        gainReduction = 0.0
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        let (outL, outR) = limiter.process(left: left, right: right)
        gainReduction = limiter.gainReductionDB
        return (outL, outR)
    }

    var gainReductionDB: Float { gainReduction }
    /// Host-rate (audio-domain) samples of delay the stage adds to L/R.
    var latencySamples: Int { limiter.latencySamples }
}

/// Final-MPX look-ahead limiter (the safety gain ride behind the composite
/// clipper). Since 0.45 (chain review A1b) the detector is a sliding-window
/// maximum over every sample inside the delay line, so the required gain is
/// known `lookaheadSamples` before the peak leaves the line and the attack
/// (time constant = window / 4) has settled by then; a hard floor guarantees
/// the exiting sample never exceeds the threshold. The previous design fed an
/// instantaneous |x| into a 0.35 ms one-pole, which on program whose peaks
/// move faster than 0.35 ms tracked a blurred target and leaked: Music - Loud
/// reported 0.02 dB of GR while 0.87 dB of dense program reached the 1x safety
/// shaper (2.7 dB on a hot chain riding 5.8 dB) -- `--verify-final-ride`.
struct LookaheadLimiter {
    var enabled: Bool = false
    var threshold: Float = 0.98
    var lookaheadSamples: Int = 0
    var delayLine: [Float] = []
    var writeIndex: Int = 0
    var gain: Float = 1.0
    var attackCoeff: Float = 0.0
    var releaseCoeff: Float = 0.0
    var holdSamples: Int = 0
    var holdCounter: Int = 0
    private var windowMax = SlidingWindowMax()

    mutating func configure(sampleRate: Float, lookaheadMS: Float, threshold: Float, enabled: Bool) {
        self.enabled = enabled
        self.threshold = clampf(threshold, 0.5, 0.999)

        let sr = max(8_000.0, sampleRate)
        let laMS = clampf(lookaheadMS, 0.0, 20.0)
        let requestedSamples = max(0, Int((sr * laMS * 0.001).rounded()))
        if requestedSamples != lookaheadSamples {
            lookaheadSamples = requestedSamples
            delayLine = lookaheadSamples > 0 ? Array(repeating: 0.0, count: lookaheadSamples) : []
            writeIndex = 0
        }
        // The window covers the sample leaving the line now plus everything
        // still inside it (lookaheadSamples + 1 values).
        windowMax.configure(windowLength: lookaheadSamples + 1)

        // Attack settles to 98% within the look-ahead window; without
        // look-ahead fall back to the 0.35 ms feedback attack.
        let attackS = lookaheadSamples > 0 ? Float(lookaheadSamples) / (4.0 * sr) : 0.00035
        let releaseS = 0.095 as Float
        attackCoeff = expf(-1.0 / (attackS * sr))
        releaseCoeff = expf(-1.0 / (releaseS * sr))
        // Short hold after the last attack so successive peaks do not release
        // between them; the windowed detector already holds the gain for as
        // long as the peak is inside the line.
        holdSamples = Int((0.004 * sr).rounded())
        holdCounter = 0
        if !enabled {
            gain = 1.0
        }
    }

    mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }

        var delayed = x
        if lookaheadSamples > 0, !delayLine.isEmpty {
            delayed = delayLine[writeIndex]
            delayLine[writeIndex] = x
            writeIndex += 1
            if writeIndex >= lookaheadSamples {
                writeIndex = 0
            }
        }
        // Largest peak among the sample leaving now and all samples queued.
        let peakAhead = windowMax.push(fabsf(x))

        var targetGain: Float = 1.0
        if peakAhead > threshold {
            targetGain = threshold / max(1e-9, peakAhead)
        }
        targetGain = clampf(targetGain, 0.0, 1.0)

        if targetGain < gain {
            gain = (attackCoeff * gain) + ((1.0 - attackCoeff) * targetGain)
            holdCounter = holdSamples
        } else if holdCounter > 0 {
            holdCounter -= 1
        } else {
            gain = (releaseCoeff * gain) + ((1.0 - releaseCoeff) * targetGain)
        }
        // Floor: whatever the smoother's residual lag, the exiting sample must
        // not exceed the threshold (the shaper behind us runs at 1x).
        gain = min(gain, targetGain)
        return delayed * gain
    }

    var gainReductionDB: Float {
        let safeGain = max(1e-6, gain)
        return max(0.0, -20.0 * log10f(safeGain))
    }
}
