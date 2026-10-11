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

// MARK: - Shared band waveshaper

/// The soft-clip curve `BassClipper` applies to its driven band (the HF
/// clipper shared it until that stage was removed in 0.61).
///
/// Until 0.60 both did this:
///
///     |x| <= threshold  ->  x                    (untouched)
///     |x| >  threshold  ->  threshold * tanh(x / threshold)
///
/// which is DISCONTINUOUS at the join: just above it the output drops to
/// `tanh(1)` = 0.7616 of where it was, a 24 % step down, and then climbs
/// back toward the same ceiling -- so the transfer is not monotonic either.
/// Oversampling reduces alias folding but cannot repair a discontinuous
/// curve; the step itself is broadband distortion (0.60 audit, P0-2).
///
/// The replacement is a shifted soft knee. Below `x0 = knee * threshold` the
/// band passes untouched; above it the excess is compressed by a tanh scaled
/// to the remaining headroom:
///
///     |x| <= x0  ->  x
///     |x| >  x0  ->  sign(x) * (x0 + w * tanh((|x| - x0) / w)),  w = threshold - x0
///
/// At the join the value is `x0` from both sides and the slope is 1 from
/// both sides (`sech^2(0) = 1`), so value AND first derivative are
/// continuous. It is monotonic, odd-symmetric, and its asymptote is still
/// exactly `threshold`, so "Threshold" keeps the operator meaning it always
/// had -- only the way the curve approaches it changes.
enum BandWaveshaper {
    /// Fraction of the threshold below which the band is untouched -- 0.9 is
    /// a knee about 1 dB wide. Chosen by measurement THROUGH the real
    /// 4x-oversampled `BassClipper` at the shipped operating point (150 Hz /
    /// -3 dB / drive 1.5), THD of a 113 Hz tone, 2026-09-12:
    ///
    ///     input level      old curve   knee 0.5   knee 0.9
    ///     light  (0.45)     -34.0       -35.1      -34.0  dB
    ///     moderate (0.65)   -19.6       -27.5      -34.4
    ///     hard   (0.95)     -16.6       -19.1      -18.0
    ///     drive 2.5 (0.6)   -16.5       -18.4      -17.3
    ///
    /// The old curve cut a NOTCH into the crest of every over-threshold peak
    /// (just above threshold it mapped to 0.76 of the pass-through value),
    /// and moderate drive -- a kick landing a little over threshold, which
    /// is where a bass clipper lives -- is where that hurt most. The widest
    /// knee removes the notch with the least added curvature, so it wins
    /// there by 15 dB and is never worse than the old curve anywhere; a
    /// narrower knee buys about a decibel back only under 2x overdrive. A
    /// bare-curve sweep without the decimator had suggested the opposite
    /// trade; the stage's own filters are what make the wide knee right.
    static let defaultKnee: Float = 0.9

    /// The tanh ARGUMENT for a driven sample, for the vectorised path:
    /// 0 below the knee, `(|x| - x0) / w` above it.
    @inline(__always)
    static func tanhArgument(driven: Float, threshold: Float, knee: Float) -> Float {
        let x0 = knee * threshold
        let width = max(1e-6, threshold - x0)
        let magnitude = fabsf(driven)
        return magnitude > x0 ? (magnitude - x0) / width : 0.0
    }

    /// Combine a driven sample with its already-computed tanh to give the
    /// shaped result, still in the driven domain.
    @inline(__always)
    static func shaped(driven: Float, tanhValue: Float, threshold: Float, knee: Float) -> Float {
        let x0 = knee * threshold
        let magnitude = fabsf(driven)
        guard magnitude > x0 else { return driven }
        let width = max(1e-6, threshold - x0)
        return copysignf(x0 + (width * tanhValue), driven)
    }

    /// Scalar reference, for tests and for anything not on the batched path.
    @inline(__always)
    static func apply(driven: Float, threshold: Float, knee: Float) -> Float {
        shaped(
            driven: driven,
            tanhValue: tanhf(tanhArgument(driven: driven, threshold: threshold, knee: knee)),
            threshold: threshold,
            knee: knee
        )
    }
}

// MARK: - Bass Clipper (4x oversampled)
struct BassClipper {
    private var splitL = LinkwitzRiley4()
    private var splitR = LinkwitzRiley4()
    private var thresholdLin: Float = 0.8
    private var drive: Float = 1.0
    private var knee: Float = BandWaveshaper.defaultKnee
    private var lagL = Lagrange4Interp()
    private var lagR = Lagrange4Interp()
    private var decimL = BiquadCascade6()
    private var decimR = BiquadCascade6()
    private static let factor: Int = 4
    // Stack-allocated batch buffers for vvtanhf-accelerated clipBass.
    // 8 elements = 4 oversample steps × L+R LP-band samples. At 8 elements
    // vvtanhf is ~5× faster than scalar tanhf per TanhBatchSizeBench.
    private var lowBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var highBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipDrivenBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipTanhBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipResultBatch: [Float] = Array(repeating: 0.0, count: factor * 2)

    mutating func configure(
        sampleRate: Float, crossoverHz: Float, thresholdDB: Float, drive drv: Float,
        knee kneeFraction: Float = BandWaveshaper.defaultKnee
    ) {
        let osRate = sampleRate * Float(Self.factor)
        splitL.configure(cutoffHz: crossoverHz, sampleRate: osRate)
        splitR.configure(cutoffHz: crossoverHz, sampleRate: osRate)
        thresholdLin = powf(10.0, min(0.0, thresholdDB) / 20.0)
        drive = max(0.1, drv)
        knee = min(0.95, max(0.05, kneeFraction))
        let cutoff = min(sampleRate * 0.45, (osRate * 0.5) - 1_000.0)
        decimL.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
        decimR.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        if !lagL.isPrimed { lagL.prime(left); lagR.prime(right) }
        let f = Self.factor
        let step = 1.0 / Float(f)

        // Phase 1: per-OS-step interpolate + LR4 split. State advances
        // here. Save .low and .high so the clip and decimate phases
        // can run as separate loops.
        for i in 0..<f {
            let t = step * Float(i + 1)
            let upL = (i == f - 1) ? left : lagL.interpolate(t: t, cur: left)
            let upR = (i == f - 1) ? right : lagR.interpolate(t: t, cur: right)
            let sL = splitL.process(upL)
            let sR = splitR.process(upR)
            lowBatch[i] = sL.low
            lowBatch[i + f] = sR.low
            highBatch[i] = sL.high
            highBatch[i + f] = sR.high
        }

        // Phase 2: batched clipBass via vvtanhf on 8 elements (4 L-low +
        // 4 R-low). ~5× faster than 8 scalar tanhf calls.
        let thr = thresholdLin
        let drv = drive
        let invDrv = 1.0 / drv
        let knee = self.knee
        for i in 0..<(f * 2) {
            clipDrivenBatch[i] = BandWaveshaper.tanhArgument(
                driven: lowBatch[i] * drv, threshold: thr, knee: knee)
        }
        var n = Int32(f * 2)
        clipDrivenBatch.withUnsafeMutableBufferPointer { dPtr in
            clipTanhBatch.withUnsafeMutableBufferPointer { tPtr in
                // baseAddress is non-nil for non-empty pre-allocated arrays (vForce idiom).
                // swiftlint:disable force_unwrapping
                vvtanhf(tPtr.baseAddress!, dPtr.baseAddress!, &n)
                // swiftlint:enable force_unwrapping
            }
        }
        for i in 0..<(f * 2) {
            let driven = lowBatch[i] * drv
            clipResultBatch[i] = BandWaveshaper.shaped(
                driven: driven, tanhValue: clipTanhBatch[i],
                threshold: thr, knee: knee) * invDrv
        }

        // Phase 3: per-OS-step decimation. State advances here.
        var outL: Float = 0
        var outR: Float = 0
        for i in 0..<f {
            outL = decimL.process(clipResultBatch[i] + highBatch[i])
            outR = decimR.process(clipResultBatch[i + f] + highBatch[i + f])
        }
        lagL.advance(left)
        lagR.advance(right)
        return (outL, outR)
    }
}

// MARK: - HF Limiter (pre-emphasis-aware, gain-riding, L/R domain)
// Program-controlled pre-emphasis after Orban US 4,103,243 (the Optimod-FM
// 8100 HF limiter, expired 1997): the pre-emphasised signal is treated as
// flat + boost and only the BOOST component rides a fast gain,
//
//     out = flat + g * (pre - flat),   g in [gMin, 1]
//
// so a cymbal or hi-hat that overshoots after pre-emphasis loses part of its
// pre-emphasis boost for a few milliseconds instead of dragging the whole
// mix down in the broadband limiter. g = 1 is full pre-emphasis, g = 0 the
// flat response -- the stage can never cut HF below the program's own
// level. The receiver's fixed de-emphasis turns the action into a brief,
// bounded HF dip; that is the trade every broadcast HF limiter makes
// (Orban, "Transmission Audio Processing").
//
// Detector, feed-forward and stereo-linked, in two parts (2026-10,
// docs/hf-limiter-review.md finding 1):
//
// 1. The PROGRAM GATE decides whether the overshoot is the boost's to fix.
//    Two peak-hold envelopes -- the pre-emphasised peak and the boost
//    magnitude, 15 ms hold (a half period of the lowest bass) then the
//    release -- and the gate opens only when the boost could cover the
//    excess on its own: `boostEnv >= k * (peakEnv - threshold)`, k = 1. A
//    kick at 0.95 with a 10 kHz hat 20 dB down has an emphasised hat of
//    ~0.31 and a boost of ~0.3 against an excess of ~0.3-0.47: closed, the
//    peak is the kick's and goes whole to the broadband limiter. Until
//    2026-10 the gate compared the boost with the PEAK, sample by sample,
//    and floored at -12 dB on every kick crest of loud program with hats;
//    a per-sample gate of any strength does the same on the kick's flanks,
//    where the hat alone is what crosses the threshold for a moment, so the
//    decision has to span the bass cycle (the HF-to-total ratio idea of
//    US 5,574,791). The review's own k = 0.5 would still open on its own
//    scenario (0.3 > 0.5 x 0.47).
// 2. The LAW, per sample, once the gate is open: the SIGNED projection of
//    the boost onto the peak, `boostProj = boost * sign(e)`, is how much of
//    the peak the boost is responsible for, and the target gain
//    `1 - excess / boostProj` removes exactly the excess and never more --
//    only Max Reduction can stop it short. A boost of the opposite sign to
//    the peak (`boostProj <= 0`) is never touched: reducing it would RAISE
//    the peak.
//
// Attack ~1.5 ms / 5 ms hold / release ~20 ms (Orban used 3 ms / 10 ms in
// the analog original). Default off -> bit-identical chain.
//
// Split ceiling (0.61): the top octave, 13 kHz and up, is held to its own,
// tighter threshold (`hf_limiter_top_threshold_db`, default 1 dB under the
// main one). The split lives in the DETECTOR, not in the signal path: a
// zero-latency IIR band split of the boost cannot feed a projection
// detector, because an LR4 highpass is inverted at its corner -- the "top"
// of a 13 kHz tone projects NEGATIVE onto the peak and that band could never
// engage -- and the lowpass side of the same pair carries a 1.5x bump next
// to the corner. Instead an LR4 highpass at 13 kHz on the boost feeds a
// 3 ms power envelope, and the share of the boost sitting above 13 kHz
// slides the threshold from the main one (share 0.3 and below: 10 kHz and
// down) to the top one (share 0.5 and above: the corner and up). One gain
// on the whole boost, as before, so a 14 kHz tone lands on the top
// threshold, a 6 kHz tone on the main one, and the stage stays
// bit-identical to pre-emphasis while idle.
struct HFLimiter {
    private var enabled = false
    private var thresholdLin: Float = 0.955
    private var topThresholdLin: Float = 0.851
    private var minGain: Float = 0.25
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    // Peak hold before release (5 ms): without it the gain rides back up
    // between the half-cycles of a sustained HF tone and the steady-state
    // peak ripples ~4% above threshold.
    private var holdSamples: Int = 1
    private var holdCounter: Int = 0
    private(set) var gain: Float = 1.0
    // Program gate envelopes (peak hold, `gateHoldMS`, then the release).
    private var peakEnvelope: Float = 0.0
    private var boostEnvelope: Float = 0.0
    private var gateHoldSamples: Int = 1
    private var peakHoldCounter: Int = 0
    private var boostHoldCounter: Int = 0
    /// Whether the program gate was open on the last sample (test-visible).
    private(set) var gateOpen: Bool = false
    // Top-octave share detector: LR4 highpass on the boost, one-pole power
    // envelopes of the top band and of the whole boost.
    private var topSplitL = LR4Section()
    private var topSplitR = LR4Section()
    private var topPower: Float = 0.0
    private var boostPower: Float = 0.0
    private var envelopeCoeff: Float = 0.0
    private var splitSampleRate: Float = 0.0
    /// The share of the boost above `topBandCrossoverHz` on the last
    /// sample, 0...1 (test-visible).
    private(set) var topShare: Float = 0.0

    /// The boost envelope must cover at least this fraction of the EXCESS of
    /// the peak envelope over the threshold for the gate to open. At 1 the
    /// stage only ever starts a ride it can finish; a peak the boost cannot
    /// bring down to the threshold is left to the broadband limiter (Dolby
    /// US 4,498,055 "modulation control"; finding 1 of
    /// docs/hf-limiter-review.md). Below 1 the ride floors on bass-driven
    /// peaks with a moderate hat -- the audible HF duck at the beat rate.
    static let boostExcessFraction: Float = 1.0
    /// Hold of the gate's envelopes: a half period of 33 Hz, so one kick
    /// crest keeps the gate closed across the flanks where the hat alone
    /// crosses the threshold for a moment.
    static let gateHoldMS: Float = 15.0
    /// A target within this factor of the gain still refreshes the hold: at
    /// convergence on a steady tone the target equals the gain up to
    /// rounding, and without the tolerance the hold lapses and the release
    /// starts a 0.3 % sawtooth (0.025 dB measured at 10 kHz).
    static let holdRefreshTolerance: Float = 1.0001
    /// A released gain above this is snapped to 1 (-0.001 dB).
    static let unitySnap: Float = 0.9999
    /// Corner of the detector's LR4 highpass: boost above it is "top band".
    static let topBandCrossoverHz: Float = 13_000.0
    /// Amplitude share of the boost above the corner that selects the main
    /// threshold (0.3: the 48 kHz LR4 passes 0.17 of a 10 kHz tone) and the
    /// top one (0.5: the LR4's own corner); linear in between.
    static let topShareMainBelow: Float = 0.3
    static let topShareTopAbove: Float = 0.5
    /// Time constant of the share's power envelopes. Long against the top
    /// octave's period (a steady tone's share has no ripple to speak of),
    /// short against the hold/release so a crash is on the top threshold
    /// within its first few milliseconds.
    static let topShareEnvelopeMS: Float = 3.0

    mutating func configure(enabled: Bool, sampleRate: Float, thresholdDB: Float,
                            topThresholdDB: Float, attackMS: Float, releaseMS: Float,
                            maxReductionDB: Float) {
        self.enabled = enabled
        let sr = max(8_000.0, sampleRate)
        thresholdLin = powf(10.0, min(0.0, thresholdDB) / 20.0)
        topThresholdLin = powf(10.0, min(0.0, topThresholdDB) / 20.0)
        minGain = powf(10.0, -clampf(maxReductionDB, 0.0, 40.0) / 20.0)
        let attackS = max(0.05, attackMS) * 0.001
        let releaseS = max(1.0, releaseMS) * 0.001
        attackCoeff = expf(-1.0 / (attackS * sr))
        releaseCoeff = expf(-1.0 / (releaseS * sr))
        envelopeCoeff = expf(-1.0 / (Self.topShareEnvelopeMS * 0.001 * sr))
        holdSamples = max(1, Int((0.005 * sr).rounded()))
        holdCounter = 0
        gateHoldSamples = max(1, Int((Self.gateHoldMS * 0.001 * sr).rounded()))
        if splitSampleRate != sr {
            // Only a rate change redesigns the split: a live threshold edit
            // keeps the detector's state like it keeps the gain's.
            topSplitL.configureHighpass(cutoffHz: Self.topBandCrossoverHz, sampleRate: sr)
            topSplitR.configureHighpass(cutoffHz: Self.topBandCrossoverHz, sampleRate: sr)
            splitSampleRate = sr
        }
        if !enabled { gain = 1.0 }
    }

    var gainReductionDB: Float { max(0.0, -20.0 * log10f(max(1e-6, gain))) }

    /// The threshold in force on the last sample (linear), between the main
    /// and the top one according to `topShare` (test-visible).
    var effectiveThresholdLin: Float {
        thresholdLin + ((topThresholdLin - thresholdLin) * Self.topWeight(share: topShare))
    }

    mutating func reset() {
        gain = 1.0
        holdCounter = 0
        peakEnvelope = 0.0
        boostEnvelope = 0.0
        peakHoldCounter = 0
        boostHoldCounter = 0
        gateOpen = false
        topPower = 0.0
        boostPower = 0.0
        topShare = 0.0
    }

    @inline(__always)
    private static func topWeight(share: Float) -> Float {
        clampf((share - topShareMainBelow) / (topShareTopAbove - topShareMainBelow), 0.0, 1.0)
    }

    /// Peak hold: instant attack, `holdSamples` of hold, then exponential
    /// release toward the input.
    @inline(__always)
    private static func peakHold(_ envelope: inout Float, _ counter: inout Int, _ x: Float,
                                 holdSamples: Int, releaseCoeff: Float) {
        if x >= envelope {
            envelope = x
            counter = holdSamples
        } else if counter > 0 {
            counter -= 1
        } else {
            envelope = max(x, zapDenorm(envelope * releaseCoeff))
        }
    }

    /// One channel's target gain: 1 unless the peak is over the threshold AND
    /// the boost projects positively onto it. The removal is capped at the
    /// excess by construction (`1 - excess / boostProj` lands exactly on the
    /// threshold; the `minGain` floor removes less), and an opposite-signed
    /// boost (`boostProj <= 0`) is never touched.
    @inline(__always)
    private static func channelTarget(emphasized: Float, boost: Float,
                                      threshold: Float, minGain: Float) -> Float {
        let excess = fabsf(emphasized) - threshold
        guard excess > 0.0 else { return 1.0 }
        let boostProj = emphasized >= 0.0 ? boost : -boost
        guard boostProj > 0.0 else { return 1.0 }
        return max(minGain, 1.0 - (excess / boostProj))
    }

    @inline(__always)
    mutating func process(flatL: Float, flatR: Float,
                          emphasizedL: Float, emphasizedR: Float) -> (Float, Float) {
        guard enabled else { return (emphasizedL, emphasizedR) }
        let boostL = emphasizedL - flatL
        let boostR = emphasizedR - flatR

        // Top-octave share of the boost (detector only; the signal path is
        // one gain on the whole boost).
        let topL = topSplitL.process(boostL)
        let topR = topSplitR.process(boostR)
        let c = envelopeCoeff
        topPower = zapDenorm((c * topPower) + ((1.0 - c) * ((topL * topL) + (topR * topR))))
        boostPower = zapDenorm((c * boostPower) + ((1.0 - c) * ((boostL * boostL) + (boostR * boostR))))
        topShare = boostPower > 1e-12 ? min(1.0, sqrtf(topPower / boostPower)) : 0.0
        let threshold = thresholdLin + ((topThresholdLin - thresholdLin) * Self.topWeight(share: topShare))

        // Program gate: is this overshoot the boost's to fix?
        let peak = max(fabsf(emphasizedL), fabsf(emphasizedR))
        let boostAbs = max(fabsf(boostL), fabsf(boostR))
        Self.peakHold(&peakEnvelope, &peakHoldCounter, peak,
                      holdSamples: gateHoldSamples, releaseCoeff: releaseCoeff)
        Self.peakHold(&boostEnvelope, &boostHoldCounter, boostAbs,
                      holdSamples: gateHoldSamples, releaseCoeff: releaseCoeff)
        gateOpen = boostEnvelope >= Self.boostExcessFraction * (peakEnvelope - threshold)

        // Stereo link: one gain, the more demanding channel's.
        var target: Float = 1.0
        if gateOpen {
            target = min(
                Self.channelTarget(emphasized: emphasizedL, boost: boostL, threshold: threshold, minGain: minGain),
                Self.channelTarget(emphasized: emphasizedR, boost: boostR, threshold: threshold, minGain: minGain))
        }
        if target < gain {
            gain = (attackCoeff * gain) + ((1.0 - attackCoeff) * target)
            holdCounter = holdSamples
        } else if target <= gain * Self.holdRefreshTolerance {
            holdCounter = holdSamples
        } else if holdCounter > 0 {
            holdCounter -= 1
        } else {
            gain = (releaseCoeff * gain) + ((1.0 - releaseCoeff) * target)
            // The exponential release never quite arrives; within 1e-4 of
            // unity the stage is idle, and idle means bit-identical.
            if gain > Self.unitySnap { gain = 1.0 }
        }
        return (flatL + (boostL * gain), flatR + (boostR * gain))
    }
}

// MARK: - Distortion-Cancelled Clipper (L/R domain, 8x oversampled)
struct DistortionCancelledClipper {
    private var ceiling: Float = 0.95
    private var errorLPL = Biquad()
    private var errorLPR = Biquad()
    private var errorLP2L = Biquad()
    private var errorLP2R = Biquad()
    private var lagL = Lagrange4Interp()
    private var lagR = Lagrange4Interp()
    private var decimL = BiquadCascade6()
    private var decimR = BiquadCascade6()
    private static let factor: Int = 8
    // Stack-allocated batch buffers for vvtanhf-accelerated hardClip.
    // 16 elements = 8 oversample steps × L+R. At 16 elements vvtanhf is
    // ~9× faster than scalar tanhf per the TanhBatchSizeBench.
    private var upBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipExcessBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipTanhBatch: [Float] = Array(repeating: 0.0, count: factor * 2)

    mutating func configure(sampleRate: Float, ceilingDB: Float, cancelFreqHz: Float) {
        ceiling = powf(10.0, min(0.0, ceilingDB) / 20.0)
        let osRate = sampleRate * Float(Self.factor)
        let q: Float = 0.7071068
        errorLPL.configureLowpass(cutoffHz: cancelFreqHz, sampleRate: osRate, q: q)
        errorLPR.configureLowpass(cutoffHz: cancelFreqHz, sampleRate: osRate, q: q)
        errorLP2L.configureLowpass(cutoffHz: cancelFreqHz, sampleRate: osRate, q: q)
        errorLP2R.configureLowpass(cutoffHz: cancelFreqHz, sampleRate: osRate, q: q)
        let cutoff = min(sampleRate * 0.45, (osRate * 0.5) - 1_000.0)
        decimL.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
        decimR.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        if !lagL.isPrimed { lagL.prime(left); lagR.prime(right) }
        let f = Self.factor
        let step = 1.0 / Float(f)

        // Phase 1: pre-compute 8 OS upL + 8 OS upR (no filter state advances
        // here — Lagrange interp reads from h-state but doesn't write).
        for i in 0..<f {
            let t = step * Float(i + 1)
            upBatch[i] = (i == f - 1) ? left : lagL.interpolate(t: t, cur: left)
            upBatch[i + f] = (i == f - 1) ? right : lagR.interpolate(t: t, cur: right)
        }

        // Phase 2: batched hardClip via vvtanhf on 16 elements (~9× faster
        // than 16 scalar tanhf calls on Apple Silicon).
        let cl = ceiling
        let kn = max(0.01, ceiling * 0.15)
        let amplitude = ceiling * 0.05
        for i in 0..<(f * 2) {
            clipExcessBatch[i] = (fabsf(upBatch[i]) - cl) / kn
        }
        var n = Int32(f * 2)
        clipExcessBatch.withUnsafeMutableBufferPointer { exPtr in
            clipTanhBatch.withUnsafeMutableBufferPointer { thPtr in
                // baseAddress is non-nil for non-empty pre-allocated arrays (vForce idiom).
                // swiftlint:disable force_unwrapping
                vvtanhf(thPtr.baseAddress!, exPtr.baseAddress!, &n)
                // swiftlint:enable force_unwrapping
            }
        }
        for i in 0..<(f * 2) {
            let up = upBatch[i]
            let ax = fabsf(up)
            if ax <= cl {
                clipBatch[i] = up
            } else {
                clipBatch[i] = copysignf(cl + amplitude * clipTanhBatch[i], up)
            }
        }

        // Phase 3: per-OS-step error-cancel filtering and decimation.
        var outL: Float = 0
        var outR: Float = 0
        for i in 0..<f {
            let upL = upBatch[i]
            let upR = upBatch[i + f]
            let clL = clipBatch[i]
            let clR = clipBatch[i + f]
            let fErrL = errorLP2L.process(errorLPL.process(clL - upL))
            let fErrR = errorLP2R.process(errorLPR.process(clR - upR))
            outL = decimL.process(clL - fErrL)
            outR = decimR.process(clR - fErrR)
        }
        lagL.advance(left)
        lagR.advance(right)
        return (outL, outR)
    }
}
