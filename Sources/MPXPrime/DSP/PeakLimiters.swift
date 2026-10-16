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
/// linear-phase FIR interpolation and decimation.
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
    private(set) var ceilingKnee: Float = 1e-4

    // Shared envelope state (the load-bearing change vs the prior pair
    // of independent OversampledPeakLimiters: same gain for both L/R).
    private var gain: Float = 1.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0

    // Per-channel 1:4 interpolator: linear-phase Kaiser FIR (polyphase).
    // Until 2026-10 this was a causal 4-point Lagrange with no image filter:
    // 15 kHz imaged at 33 kHz only 16 dB down and 10 kHz at -29 dB, and the
    // detector settled a steady 14 kHz tone 0.58 dB UNDER the threshold
    // (peak-control review F9).
    private var lInterp = LinearPhaseFIRInterpolator()
    private var rInterp = LinearPhaseFIRInterpolator()
    private var lOS: [Float] = [0.0, 0.0, 0.0, 0.0]
    private var rOS: [Float] = [0.0, 0.0, 0.0, 0.0]
    // Per-channel 4:1 decimator: linear-phase Kaiser FIR designed at the OS
    // rate (see configure). Until 0.45 this was a 6th-order Butterworth at
    // 0.30 x host rate -- 14.4 kHz at the 48 kHz audio domain, i.e. -2.3 dB
    // at 14 kHz / -4 dB at 14.9 kHz on the program AFTER the encoder FIR,
    // with only -27 dB alias rejection at 24 kHz.
    private var lDecim = LinearPhaseFIRDecimator()
    private var rDecim = LinearPhaseFIRDecimator()
    private var lResidualClipper = AcceleratedBandlimitedResidualClipper()
    private var rResidualClipper = AcceleratedBandlimitedResidualClipper()

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
        lookaheadHFCutoffHz: Float = 4_000.0,
        passbandHz: Float = 15_000.0
    ) {
        let sr = max(8_000.0, sampleRate * 4.0)
        self.threshold = clampf(threshold, 0.75, 0.995)
        self.releaseMS = max(8.0, releaseMS)
        self.bandlimitedResidualEnabled = bandlimitedResidualEnabled
        ceiling = oversampledLimiterCeiling(threshold: self.threshold)
        // The CLAMPED threshold: the argument may lie outside 0.75...0.995
        // (AppConfig accepts 0.5...0.999), and a knee measured from it is
        // either far too wide (a slope kink at the join) or a hard clip.
        ceilingKnee = max(1e-4, ceiling - self.threshold)

        let attackS = 0.00025 as Float
        let relS = max(0.008, Double(self.releaseMS) * 0.001)
        attackCoeff = expf(-1.0 / (attackS * sr))
        releaseCoeff = expf(-1.0 / Float(relS * Double(sr)))
        holdSamples = max(1, Int((0.004 * sr).rounded()))
        holdCounter = 0
        gain = 1.0
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
        // 15 kHz is the FM band plan; a digital delivery target hands in its own
        // (wider) program bandwidth, which is why this is a parameter now.
        let passband = clampf(passbandHz, 10_000.0, max(10_000.0, sampleRate * 0.42))
        let transitionHz = max(1_500.0, sampleRate / 32.0)
        // Interpolator: flat over the same passband, image of its edge
        // (host rate - passband) in the stopband. Anything between the two is
        // removed by the decimator anyway.
        let interpTransition = max(1_500.0, sampleRate - (2.0 * passband))
        lInterp.configure(cutoffHz: passband, sampleRateOS: sr, interpolateFactor: 4,
                          stopBandDB: 80.0, transitionHz: interpTransition)
        rInterp.configure(cutoffHz: passband, sampleRateOS: sr, interpolateFactor: 4,
                          stopBandDB: 80.0, transitionHz: interpTransition)
        lDecim.configure(cutoffHz: passband, sampleRateOS: sr, decimateFactor: 4,
                         stopBandDB: 80.0, transitionHz: transitionHz)
        rDecim.configure(cutoffHz: passband, sampleRateOS: sr, decimateFactor: 4,
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

        // 4x upsample both channels (polyphase Kaiser FIR).
        lOS.withUnsafeMutableBufferPointer { o in
            // swiftlint:disable:next force_unwrapping
            lInterp.push(procL, into: o.baseAddress!)
        }
        rOS.withUnsafeMutableBufferPointer { o in
            // swiftlint:disable:next force_unwrapping
            rInterp.push(procR, into: o.baseAddress!)
        }
        let l1 = lOS[0], l2 = lOS[1], l3 = lOS[2], l4 = lOS[3]
        let r1 = rOS[0], r2 = rOS[1], r3 = rOS[2], r4 = rOS[3]

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
        return (outL, outR)
    }

    var gainReductionDB: Float {
        let safeGain = max(1e-6, gain)
        return max(0.0, -20.0 * log10f(safeGain))
    }

    /// Host-rate samples of delay this stage adds to the L/R path: the
    /// look-ahead delay line, the interpolator's and the decimator's group
    /// delay and, when it is in the path, the band-limited residual
    /// clipper's (an OS-rate FIR). The OS delays are summed BEFORE the
    /// rounding to host samples: rounding the decimator alone (321 OS = 80.25
    /// host) and leaving the residual clipper out (16 OS = 4 host)
    /// under-reported the latency (peak-control review F14).
    var latencySamples: Int {
        let residualOS = bandlimitedResidualEnabled ? lResidualClipper.groupDelaySamples : 0
        // The interpolator's last output of a step is (centre - 3) OS
        // samples behind the input it was pushed with.
        let interpOS = max(0, lInterp.groupDelayOSSamples - 3)
        let osDelay = interpOS + lDecim.groupDelayOSSamples + residualOS
        return lookaheadSamples + Int((Float(osDelay) / 4.0).rounded())
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

/// The hard upper bound an `OversampledPeakLimiter` imposes for a given
/// threshold: the soft knee sits between the two and nothing leaves the stage
/// above this value. Shared as a free function so a caller that has to map the
/// limiter's REAL ceiling onto another target -- the processed-audio digital
/// true-peak ceiling does exactly that -- cannot drift from the limiter's own
/// rule. Mapping the THRESHOLD instead reads about 1.3 dB hot, which is how
/// this was found.
@inline(__always)
func oversampledLimiterCeiling(threshold: Float) -> Float {
    let thr = clampf(threshold, 0.75, 0.995)
    return min(0.999, thr + max(0.012, (1.0 - thr) * 0.65))
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
        lookaheadHFCutoffHz: Float = 4_000.0,
        passbandHz: Float = 15_000.0
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
            lookaheadHFCutoffHz: lookaheadHFCutoffHz,
            passbandHz: passbandHz
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

/// Step-free look-ahead gain for a limiter that knows, through a sliding-window
/// detector, the gain each sample will need when it leaves its delay line.
///
/// Feed it the window-minimum required gain (`target`) once per sample. The
/// target is first passed through an instant-attack / hold / release follower
/// (`held <= target` always), then averaged by two cascaded moving averages
/// whose combined span is `rampSamples + 1`. The result is a gain that starts
/// moving `rampSamples` before the peak leaves the line, follows a smooth
/// S-shaped (piecewise-quadratic) ramp, and arrives at the required value
/// exactly when the peak does -- with no step anywhere.
///
/// Why this is a bound and not just a smoother: every `held` value inside the
/// averaging span was taken from a detector window that still contained the
/// exiting sample, as long as `rampSamples <= lookahead`, so each of them is
/// at most that sample's required gain, and so is their average. The previous
/// design (a one-pole attack plus a hard floor `gain = min(gain, target)`
/// written back into the state) met the bound by jumping: the moment a larger
/// peak entered the window the gain stepped to the new target in one sample,
/// a -1.36 dB step that spread -66 dBc of spill above 60 kHz on a 1.6x level
/// jump (2026-10 peak-control review, F6). Nothing filters behind the final
/// limiter, so that spill went on air.
///
/// The running sums are Double and re-summed from the ring on every wrap, so
/// they cannot drift. No allocation after `configure`.
struct LookaheadGainRamp {
    private var ring1: [Float] = [1.0]
    private var ring2: [Float] = [1.0]
    private var length1: Int = 1
    private var length2: Int = 1
    private var index1: Int = 0
    private var index2: Int = 0
    private var sum1: Double = 1.0
    private var sum2: Double = 1.0
    private var held: Float = 1.0
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0
    private var releaseCoeff: Float = 0.0
    private(set) var rampSamples: Int = 0
    /// The gain on the last sample.
    private(set) var gain: Float = 1.0

    /// A released gain above this snaps to unity, so an idle stage is an
    /// exact delay.
    static let unitySnap: Float = 0.999_999

    /// Box lengths for a ramp: two boxes of lengths m1, m2 span
    /// m1 + m2 - 1 = ramp + 1 samples.
    private static func boxLengths(_ ramp: Int) -> (Int, Int) {
        ((ramp / 2) + 1, ramp - (ramp / 2) + 1)
    }

    /// - Parameter capacityRampSamples: the longest ramp `resize` may later
    ///   ask for without allocating (defaults to `rampSamples`).
    mutating func configure(rampSamples: Int, holdSamples: Int, releaseCoeff: Float,
                            capacityRampSamples: Int? = nil) {
        let ramp = max(0, rampSamples)
        let capacity = max(ramp, capacityRampSamples ?? ramp)
        let (c1, c2) = Self.boxLengths(capacity)
        if ring1.count < c1 { ring1 = [Float](repeating: 1.0, count: c1) }
        if ring2.count < c2 { ring2 = [Float](repeating: 1.0, count: c2) }
        self.rampSamples = ramp
        (length1, length2) = Self.boxLengths(ramp)
        self.holdSamples = max(0, holdSamples)
        self.releaseCoeff = releaseCoeff
        reset()
    }

    mutating func reset() {
        for i in 0..<ring1.count { ring1[i] = 1.0 }
        for i in 0..<ring2.count { ring2[i] = 1.0 }
        index1 = 0
        index2 = 0
        sum1 = Double(length1)
        sum2 = Double(length2)
        held = 1.0
        holdCounter = 0
        gain = 1.0
    }

    /// Live change of the ramp length within the configured capacity, with
    /// no allocation: both boxes restart filled with the current gain, so the
    /// output is continuous across the change.
    mutating func resize(rampSamples: Int, holdSamples: Int) {
        let (c1, c2) = (ring1.count, ring2.count)
        var ramp = max(0, rampSamples)
        while ramp > 0 {
            let (m1, m2) = Self.boxLengths(ramp)
            if m1 <= c1 && m2 <= c2 { break }
            ramp -= 1
        }
        self.rampSamples = ramp
        (length1, length2) = Self.boxLengths(ramp)
        self.holdSamples = max(0, holdSamples)
        let g = gain
        for i in 0..<length1 { ring1[i] = g }
        for i in 0..<length2 { ring2[i] = g }
        index1 = 0
        index2 = 0
        sum1 = Double(g) * Double(length1)
        sum2 = Double(g) * Double(length2)
        held = min(held, g)
    }

    /// Push the required gain for the window that ends with this sample;
    /// returns the gain to apply to the sample leaving the line now.
    @inline(__always)
    mutating func push(_ target: Float) -> Float {
        if target < held {
            held = target
            holdCounter = holdSamples
        } else if holdCounter > 0 {
            holdCounter -= 1
        } else {
            held = (releaseCoeff * held) + ((1.0 - releaseCoeff) * target)
            if held > Self.unitySnap && target >= 1.0 { held = 1.0 }
        }
        let a = Self.boxPush(held, ring: &ring1, length: length1, index: &index1, sum: &sum1)
        let b = Self.boxPush(a, ring: &ring2, length: length2, index: &index2, sum: &sum2)
        gain = b
        return b
    }

    @inline(__always)
    private static func boxPush(_ x: Float, ring: inout [Float], length n: Int, index: inout Int,
                                sum: inout Double) -> Float {
        if n <= 1 {
            return x
        }
        sum += Double(x) - Double(ring[index])
        ring[index] = x
        index += 1
        if index >= n {
            index = 0
            // Exact re-sum once per cycle: no long-run drift.
            var exact: Double = 0.0
            for k in 0..<n { exact += Double(ring[k]) }
            sum = exact
        }
        return Float(sum / Double(n))
    }
}

/// Final-MPX look-ahead limiter (the safety gain ride behind the composite
/// clipper). Since 0.45 (chain review A1b) the detector is a sliding-window
/// maximum over every sample inside the delay line, so the required gain is
/// known `lookaheadSamples` before the peak leaves the line. Since 2026-10
/// (peak-control review F6) that target drives a `LookaheadGainRamp`: the gain
/// ramps smoothly over the whole look-ahead and reaches the required value
/// exactly when the peak exits, with no one-sample step. A floor on the OUTPUT
/// sample (never on the gain state) absorbs Float rounding only. The previous
/// design fed an instantaneous |x| into a 0.35 ms one-pole, which on program
/// whose peaks move faster than 0.35 ms tracked a blurred target and leaked:
/// Music - Loud reported 0.02 dB of GR while 0.87 dB of dense program reached
/// the 1x safety shaper (2.7 dB on a hot chain riding 5.8 dB) --
/// `--verify-final-ride`.
struct LookaheadLimiter {
    var enabled: Bool = false
    var threshold: Float = 0.98
    var lookaheadSamples: Int = 0
    var delayLine: [Float] = []
    var writeIndex: Int = 0
    private var ramp = LookaheadGainRamp()
    private var windowMax = SlidingWindowMax()

    /// Gain applied to the last sample (1 = no reduction).
    var gain: Float { ramp.gain }

    /// Host-rate samples of delay the stage adds while it runs. Zero when it
    /// is disabled: it then returns its input untouched, and a caller that
    /// aligns the pilot with the audio must not count a delay that is not in
    /// the path (F12).
    var latencySamples: Int { enabled ? lookaheadSamples : 0 }

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

        // The ramp spans the whole look-ahead (the longest span that is still
        // a bound, see `LookaheadGainRamp`). Without look-ahead it degenerates
        // to an instant gain on the current sample. Short hold after the last
        // attack so successive peaks do not release between them; ~95 ms
        // release.
        let releaseS = 0.095 as Float
        ramp.configure(rampSamples: lookaheadSamples,
                       holdSamples: Int((0.004 * sr).rounded()),
                       releaseCoeff: expf(-1.0 / (releaseS * sr)))
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
        let g = ramp.push(clampf(targetGain, 0.0, 1.0))
        // Output floor for Float rounding only (the ramp is a bound by
        // construction); it never feeds back into the gain state.
        let y = delayed * g
        if fabsf(y) > threshold {
            return copysignf(threshold, y)
        }
        return y
    }

    var gainReductionDB: Float {
        let safeGain = max(1e-6, gain)
        return max(0.0, -20.0 * log10f(safeGain))
    }
}
