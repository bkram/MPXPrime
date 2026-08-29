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

/// Single-channel oversampled true-peak limiter. Used by `PreEncodeAudioLimiter`
/// per L/R channel before stereo encoding — operating on independent audio
/// channels (no multiplexed subcarrier), the trailing tanh ceiling here is a
/// normal soft-knee limiter behavior. **Never use this on the FM composite
/// signal** — the memoryless tanh on a (M + S·cos38k) waveform creates
/// intermod that demodulates as stereo-image collapse. Composite-domain
/// peak control belongs in `CompositeClipper` (distortion-cancelled).
struct OversampledPeakLimiter {
    var threshold: Float = 0.94
    var releaseMS: Float = 35.0
    var ceiling: Float = 0.985
    var bandlimitedResidualEnabled: Bool = false

    private var gain: Float = 1.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0
    private var prevPrevPrevIn: Float = 0.0
    private var prevPrevIn: Float = 0.0
    private var prevIn: Float = 0.0
    private var decimationLP = BiquadCascade6()
    private var residualClipper = AcceleratedBandlimitedResidualClipper()
    private var initialized: Bool = false

    mutating func configure(
        sampleRate: Float,
        threshold: Float,
        releaseMS: Float = 35.0,
        bandlimitedResidualEnabled: Bool = false,
        residualTapCount: Int = 33,
        residualCutoffFraction: Float = 0.25
    ) {
        let sr = max(8_000.0, sampleRate * 4.0)
        self.threshold = clampf(threshold, 0.75, 0.995)
        self.releaseMS = max(8.0, releaseMS)
        self.bandlimitedResidualEnabled = bandlimitedResidualEnabled
        let ceilingMargin = max(0.012, (1.0 - self.threshold) * 0.65)
        ceiling = min(0.999, self.threshold + ceilingMargin)

        let attackS = 0.00025 as Float
        let relS = max(0.008, Double(self.releaseMS) * 0.001)
        attackCoeff = expf(-1.0 / (attackS * sr))
        releaseCoeff = expf(-1.0 / Float(relS * Double(sr)))
        holdSamples = max(1, Int((0.004 * sr).rounded()))
        holdCounter = 0
        gain = 1.0
        prevPrevPrevIn = 0.0
        prevPrevIn = 0.0
        prevIn = 0.0
        let cutoff = min(sampleRate * 0.30, (sr * 0.5) - 1_000.0)
        decimationLP.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: sr)
        residualClipper.configure(
            threshold: ceiling,
            tapCount: residualTapCount,
            cutoffFraction: residualCutoffFraction
        )
        initialized = false
    }

    mutating func process(_ x: Float) -> Float {
        if !initialized {
            initialized = true
            prevPrevPrevIn = x
            prevPrevIn = x
            prevIn = x
            let q = processStep(x)
            return decimate(q1: q, q2: q, q3: q, q4: q)
        }

        let q1 = processStep(interpolateLagrange4(t: 0.25, current: x))
        let q2 = processStep(interpolateLagrange4(t: 0.50, current: x))
        let q3 = processStep(interpolateLagrange4(t: 0.75, current: x))
        let q4 = processStep(x)
        let output = decimate(q1: q1, q2: q2, q3: q3, q4: q4)

        let priorPrev = prevPrevIn
        let priorCurrent = prevIn
        prevPrevPrevIn = priorPrev
        prevPrevIn = priorCurrent
        prevIn = x
        return output
    }

    var gainReductionDB: Float {
        let safeGain = max(1e-6, gain)
        return max(0.0, -20.0 * log10f(safeGain))
    }

    @inline(__always)
    private mutating func processStep(_ x: Float) -> Float {
        let peak = fabsf(x)

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

        let y = x * gain
        return clipToCeiling(y)
    }

    @inline(__always)
    private func interpolateLagrange4(t: Float, current: Float) -> Float {
        // Causal 4-point reconstruction between prevIn and current using
        // two prior samples for better curvature tracking.
        let l0 = -((t + 1.0) * t * (t - 1.0)) / 6.0
        let l1 = ((t + 2.0) * t * (t - 1.0)) * 0.5
        let l2 = -((t + 2.0) * (t + 1.0) * (t - 1.0)) * 0.5
        let l3 = ((t + 2.0) * (t + 1.0) * t) / 6.0
        return (prevPrevPrevIn * l0) + (prevPrevIn * l1) + (prevIn * l2) + (current * l3)
    }

    @inline(__always)
    private mutating func decimate(q1: Float, q2: Float, q3: Float, q4: Float) -> Float {
        _ = decimationLP.process(q1)
        _ = decimationLP.process(q2)
        _ = decimationLP.process(q3)
        return decimationLP.process(q4)
    }

    @inline(__always)
    private mutating func clipToCeiling(_ x: Float) -> Float {
        if bandlimitedResidualEnabled {
            return residualClipper.process(x)
        }
        let ax = fabsf(x)
        if ax <= threshold { return x }

        let knee = max(1e-4, ceiling - threshold)
        let clipped = threshold + ((ceiling - threshold) * tanhf((ax - threshold) / knee))
        return copysignf(min(clipped, ceiling), x)
    }
}

/// Stereo-linked variant of OversampledPeakLimiter. Shared gain
/// envelope driven by `max(|L_os|, |R_os|)` at OS rate; per-channel
/// Lagrange interpolation and decimation filter.
///
/// Replaces the prior per-channel limiter pair (one OversampledPeakLimiter
/// per channel) which made independent gain decisions and produced an
/// asymmetric image on hard-panned content — the chain-order audit
/// recorded a +15 dB side-to-mid blowup on the synthetic-pathological
/// `hard_panned_hf` scenario in 0.25. Stereo-linked detection applies
/// the same GR to both channels, so L/R relative balance is preserved
/// even when one channel peaks asymmetrically.
///
/// For monaural input (L = R) the output is bit-identical to two
/// OversampledPeakLimiter instances on each channel.
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
    // Per-channel decimation low-pass (same 12th-order Butterworth
    // cascade as OversampledPeakLimiter)
    private var lDecimLP = BiquadCascade6()
    private var rDecimLP = BiquadCascade6()
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
        let cutoff = min(sampleRate * 0.30, (sr * 0.5) - 1_000.0)
        let cutoffHz = max(12_000.0 as Float, cutoff)
        lDecimLP.configureLowpass(cutoffHz: cutoffHz, sampleRate: sr)
        rDecimLP.configureLowpass(cutoffHz: cutoffHz, sampleRate: sr)
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
        // Same Lagrange-4 coefficients as OversampledPeakLimiter's
        // internal helper — causal 4-point reconstruction.
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
        switch ch {
        case .left:
            _ = lDecimLP.process(q1)
            _ = lDecimLP.process(q2)
            _ = lDecimLP.process(q3)
            return lDecimLP.process(q4)
        case .right:
            _ = rDecimLP.process(q1)
            _ = rDecimLP.process(q2)
            _ = rDecimLP.process(q3)
            return rDecimLP.process(q4)
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
}

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

        let attackS = 0.00035 as Float
        let releaseS = 0.095 as Float
        attackCoeff = expf(-1.0 / (attackS * sr))
        releaseCoeff = expf(-1.0 / (releaseS * sr))
        // Hold must outlast the look-ahead delay: the detector sees a peak
        // `lookaheadSamples` before it leaves the delay line, so a shorter
        // hold lets the release start lifting the gain before the peak has
        // actually passed the gain stage (measured as ~1% overshoot at the
        // old fixed 4 ms hold against a 5 ms look-ahead).
        holdSamples = max(
            Int((0.004 * sr).rounded()),
            lookaheadSamples + Int((0.001 * sr).rounded()))
        holdCounter = 0
        if !enabled {
            gain = 1.0
        }
    }

    mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }

        let detector = fabsf(x)
        var delayed = x
        if lookaheadSamples > 0, !delayLine.isEmpty {
            delayed = delayLine[writeIndex]
            delayLine[writeIndex] = x
            writeIndex += 1
            if writeIndex >= lookaheadSamples {
                writeIndex = 0
            }
        }

        var targetGain: Float = 1.0
        if detector > threshold {
            targetGain = threshold / max(1e-9, detector)
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
        return delayed * gain
    }

    var gainReductionDB: Float {
        let safeGain = max(1e-6, gain)
        return max(0.0, -20.0 * log10f(safeGain))
    }
}
