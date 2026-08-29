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

// MARK: - Bass Clipper (4x oversampled)
struct BassClipper {
    private var splitL = LinkwitzRiley4()
    private var splitR = LinkwitzRiley4()
    private var thresholdLin: Float = 0.8
    private var drive: Float = 1.0
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

    mutating func configure(sampleRate: Float, crossoverHz: Float, thresholdDB: Float, drive drv: Float) {
        let osRate = sampleRate * Float(Self.factor)
        splitL.configure(cutoffHz: crossoverHz, sampleRate: osRate)
        splitR.configure(cutoffHz: crossoverHz, sampleRate: osRate)
        thresholdLin = powf(10.0, min(0.0, thresholdDB) / 20.0)
        drive = max(0.1, drv)
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
        for i in 0..<(f * 2) {
            clipDrivenBatch[i] = (lowBatch[i] * drv) / thr
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
            let ax = fabsf(driven)
            if ax <= thr {
                clipResultBatch[i] = lowBatch[i]
            } else {
                clipResultBatch[i] = (thr * clipTanhBatch[i]) * invDrv
            }
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

// MARK: - HF Clipper (pre-emphasis-aware, L/R domain, oversampled)
// Pre-emphasis-aware HF limiting. Clips only the HIGH band of the
// (pre-emphasized) L/R signal so HF transients are tamed by a dedicated stage
// instead of forcing the broadband pre-encode limiter to pull gain across the
// whole signal (which dulls everything -- the classic FM-processing artifact).
//
// De-emphasis-correct by construction: it limits the *pre-emphasized* HF, so
// the receiver's fixed 50/75 us de-emphasis still restores the intended curve
// -- the trade is HF density, NOT the curve mismatch that relaxing pre-emphasis
// (dynamic pre-emphasis) would cause. This is the Orban/Omnia/Stereotool
// approach (see plan.md "HF limiter / clipper").
//
// Structurally a mirror of `BassClipper`: LR4 split at the crossover, oversample
// + tanh soft-clip the band, decimate, recombine. BassClipper clips `.low`; this
// clips `.high`. Oversampling (Lagrange4Interp up + BiquadCascade6 decimation)
// keeps the clipping harmonics from aliasing. Default off -> passthrough
// (bit-identical); ships opt-in, verifier-backed.
struct HFClipper {
    private var enabled = false
    private var splitL = LinkwitzRiley4()
    private var splitR = LinkwitzRiley4()
    private var thresholdLin: Float = 0.9
    private var drive: Float = 1.0
    private var lagL = Lagrange4Interp()
    private var lagR = Lagrange4Interp()
    private var decimL = BiquadCascade6()
    private var decimR = BiquadCascade6()
    private static let factor: Int = 4
    private var lowBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var highBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipDrivenBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipTanhBatch: [Float] = Array(repeating: 0.0, count: factor * 2)
    private var clipResultBatch: [Float] = Array(repeating: 0.0, count: factor * 2)

    mutating func configure(enabled: Bool, sampleRate: Float, crossoverHz: Float,
                            thresholdDB: Float, drive drv: Float) {
        self.enabled = enabled
        let osRate = sampleRate * Float(Self.factor)
        splitL.configure(cutoffHz: crossoverHz, sampleRate: osRate)
        splitR.configure(cutoffHz: crossoverHz, sampleRate: osRate)
        thresholdLin = powf(10.0, min(0.0, thresholdDB) / 20.0)
        drive = max(0.1, drv)
        let cutoff = min(sampleRate * 0.45, (osRate * 0.5) - 1_000.0)
        decimL.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
        decimR.configureLowpass(cutoffHz: max(12_000.0, cutoff), sampleRate: osRate)
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        guard enabled else { return (left, right) }
        if !lagL.isPrimed { lagL.prime(left); lagR.prime(right) }
        let f = Self.factor
        let step = 1.0 / Float(f)

        // Phase 1: per-OS-step interpolate + LR4 split (state advances here).
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

        // Phase 2: batched tanh soft-clip of the HIGH band via vvtanhf.
        let thr = thresholdLin
        let drv = drive
        let invDrv = 1.0 / drv
        for i in 0..<(f * 2) {
            clipDrivenBatch[i] = (highBatch[i] * drv) / thr
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
            let driven = highBatch[i] * drv
            if fabsf(driven) <= thr {
                clipResultBatch[i] = highBatch[i]
            } else {
                clipResultBatch[i] = (thr * clipTanhBatch[i]) * invDrv
            }
        }

        // Phase 3: recombine (low + clipped high) and decimate.
        var outL: Float = 0
        var outR: Float = 0
        for i in 0..<f {
            outL = decimL.process(lowBatch[i] + clipResultBatch[i])
            outR = decimR.process(lowBatch[i + f] + clipResultBatch[i + f])
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
// pre-emphasis boost for a few milliseconds instead of being waveshaped by
// the HF clipper or dragging the whole mix down in the broadband limiter.
// g = 1 is full pre-emphasis, g = 0 the flat response -- the stage can never
// cut HF below the program's own level. The receiver's fixed de-emphasis
// turns the action into a brief, bounded HF dip; that is the trade every
// broadcast HF limiter makes (Orban, "Transmission Audio Processing").
//
// Detector, feed-forward and stereo-linked: when the pre-emphasised peak
// exceeds the threshold AND the boost accounts for at least half the excess,
// the target gain removes exactly the excess from the boost; whatever is left
// goes to the pre-encode limiter that follows (Orban's clipper-after-HF-
// limiter division of labour). Peaks driven by bass/mids with little boost
// are ignored so they cannot flutter the HF (the Dolby US 4,498,055
// "modulation control" idea). Attack ~1.5 ms / release ~20 ms (Orban used
// 3 ms / 10 ms in the analog original). Default off -> bit-identical chain.
struct HFLimiter {
    private var enabled = false
    private var thresholdLin: Float = 0.794
    private var minGain: Float = 0.25
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    // Peak hold before release (5 ms): without it the gain rides back up
    // between the half-cycles of a sustained HF tone and the steady-state
    // peak ripples ~4% above threshold.
    private var holdSamples: Int = 1
    private var holdCounter: Int = 0
    private(set) var gain: Float = 1.0

    /// The boost must carry at least this fraction of the pre-emphasised
    /// peak for the stage to act: peaks driven by bass/mids with a small HF
    /// boost are left to the broadband limiter (Dolby "modulation control").
    private static let boostDominanceFraction: Float = 0.2

    mutating func configure(enabled: Bool, sampleRate: Float, thresholdDB: Float,
                            attackMS: Float, releaseMS: Float, maxReductionDB: Float) {
        self.enabled = enabled
        let sr = max(8_000.0, sampleRate)
        thresholdLin = powf(10.0, min(0.0, thresholdDB) / 20.0)
        minGain = powf(10.0, -clampf(maxReductionDB, 0.0, 40.0) / 20.0)
        let attackS = max(0.05, attackMS) * 0.001
        let releaseS = max(1.0, releaseMS) * 0.001
        attackCoeff = expf(-1.0 / (attackS * sr))
        releaseCoeff = expf(-1.0 / (releaseS * sr))
        holdSamples = max(1, Int((0.005 * sr).rounded()))
        holdCounter = 0
        if !enabled { gain = 1.0 }
    }

    var gainReductionDB: Float { max(0.0, -20.0 * log10f(max(1e-6, gain))) }

    mutating func reset() {
        gain = 1.0
        holdCounter = 0
    }

    @inline(__always)
    mutating func process(flatL: Float, flatR: Float,
                          emphasizedL: Float, emphasizedR: Float) -> (Float, Float) {
        guard enabled else { return (emphasizedL, emphasizedR) }
        let boostL = emphasizedL - flatL
        let boostR = emphasizedR - flatR
        let peak = max(fabsf(emphasizedL), fabsf(emphasizedR))
        var target: Float = 1.0
        let excess = peak - thresholdLin
        if excess > 0.0 {
            let boostAbs = max(fabsf(boostL), fabsf(boostR))
            if boostAbs > Self.boostDominanceFraction * peak {
                target = max(minGain, 1.0 - (excess / boostAbs))
            }
        }
        if target < gain {
            gain = (attackCoeff * gain) + ((1.0 - attackCoeff) * target)
            holdCounter = holdSamples
        } else if holdCounter > 0 {
            holdCounter -= 1
        } else {
            gain = (releaseCoeff * gain) + ((1.0 - releaseCoeff) * target)
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
