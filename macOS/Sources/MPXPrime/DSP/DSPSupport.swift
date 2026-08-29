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

// Biquad, BiquadCascade6, and DeemphasisFilter were moved to the shared
// MPXPrimeCore target in the v0.31 modularization step (imported above).
// twoPi / clampf / lerpf / zapDenorm are module-internal helpers shared by
// the DSP/ stage files (split out of this file in 0.45); the copies in
// MPXPrimeCore are module-private there and do not collide.
let twoPi = Float.pi * 2.0
let pilotFreq = Float(19_000.0)
let subcarrierFreq = Float(38_000.0)

@inline(__always)
func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
    return max(lo, min(hi, x))
}

@inline(__always)
func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float {
    return a + ((b - a) * t)
}

@inline(__always)
func zapDenorm(_ x: Float) -> Float {
    return (fabsf(x) < 1e-20) ? 0.0 : x
}

struct SineCosOsc {
    var s: Float = 0.0
    var c: Float = 1.0
    var phase: Float = 0.0
    private var sinInc: Float = 0.0
    private var cosInc: Float = 1.0
    private var stepPhase: Float = 0.0
    private var renormCounter: Int = 0

    init() {}

    mutating func configure(freq: Float, sampleRate: Float) {
        let w = twoPi * freq / sampleRate
        stepPhase = w
        sinInc = sinf(w)
        cosInc = cosf(w)
        s = 0.0
        c = 1.0
        phase = 0.0
        renormCounter = 0
    }

    @inline(__always) mutating func step() {
        let ns = s * cosInc + c * sinInc
        let nc = c * cosInc - s * sinInc
        s = ns
        c = nc

        phase += stepPhase
        if phase >= twoPi { phase -= twoPi }

        renormCounter &+= 1
        if (renormCounter & 1023) == 0 {
            let mag2 = s * s + c * c
            if mag2 > 0 {
                let invMag = 1.0 / sqrtf(mag2)
                s *= invMag
                c *= invMag
            }
        }
    }

    @inline(__always) mutating func sin2x() -> Float {
        return 2.0 * s * c
    }

    /// cos(2*theta) from the same recurrence (double-angle identity).
    /// Quadrature companion to `sin2x()` -- the SSB Stereo encoder's SSB-leaning
    /// stereo encoder needs both phases of the 38 kHz subcarrier.
    @inline(__always) func cos2x() -> Float {
        return (c * c) - (s * s)
    }
}

struct DCBlocker1p {
    private var r: Float = 0.995
    private var x1: Float = 0.0
    private var y1: Float = 0.0

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        let fc = max(1.0, min(50.0, cutoffHz))
        r = expf(-twoPi * fc / sr)
        x1 = 0.0
        y1 = 0.0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = x - x1 + r * y1
        x1 = x
        y1 = zapDenorm(y)
        return y
    }
}

struct OnePoleLP {
    var alpha: Float = 1.0
    var state: Float = 0.0

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        let fc = max(8.0, min(45_000.0, cutoffHz))
        let sr = max(8_000.0, sampleRate)
        let pole = expf(-twoPi * fc / sr)
        alpha = clampf(1.0 - pole, 0.0, 1.0)
    }

    mutating func process(_ x: Float) -> Float {
        state += alpha * (x - state)
        state = zapDenorm(state)
        return state
    }
}

struct StereoBiquad {
    var left = Biquad()
    var right = Biquad()

    mutating func configureHighpass(cutoffHz: Float, sampleRate: Float) {
        left.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func configureHighShelf(gainDB: Float, cutoffHz: Float, sampleRate: Float) {
        left.configureHighShelf(gainDB: gainDB, cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configureHighShelf(gainDB: gainDB, cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func configureLowShelf(gainDB: Float, cutoffHz: Float, sampleRate: Float) {
        left.configureLowShelf(gainDB: gainDB, cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configureLowShelf(gainDB: gainDB, cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func configurePeakingEQ(freqHz: Float, gainDB: Float, sampleRate: Float, q: Float = 1.0) {
        left.configurePeakingEQ(freqHz: freqHz, gainDB: gainDB, sampleRate: sampleRate, q: q)
        right.configurePeakingEQ(freqHz: freqHz, gainDB: gainDB, sampleRate: sampleRate, q: q)
    }

    mutating func configureAllpass(freqHz: Float, sampleRate: Float, q: Float = 0.7071068) {
        left.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
        right.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        return (self.left.process(left), self.right.process(right))
    }
}

// MARK: - Shared oversampling helper
struct Lagrange4Interp {
    private var h3: Float = 0
    private var h2: Float = 0
    private var h1: Float = 0
    private var initialized: Bool = false

    mutating func prime(_ x: Float) {
        h3 = x; h2 = x; h1 = x; initialized = true
    }

    @inline(__always)
    func interpolate(t: Float, cur: Float) -> Float {
        let l0 = -((t + 1.0) * t * (t - 1.0)) / 6.0
        let l1 = ((t + 2.0) * t * (t - 1.0)) * 0.5
        let l2 = -((t + 2.0) * (t + 1.0) * (t - 1.0)) * 0.5
        let l3 = ((t + 2.0) * (t + 1.0) * t) / 6.0
        return (h3 * l0) + (h2 * l1) + (h1 * l2) + (cur * l3)
    }

    /// Basis weights for a fixed fractional position `t`. When a caller
    /// oversamples by a fixed integer factor, every host sample evaluates
    /// interpolation at the *same* set of `t` values (i/factor), so these
    /// weights are constant and can be precomputed once instead of being
    /// recomputed per host sample. Returns the four l-coefficients in the
    /// exact (l0, l1, l2, l3) layout `interpolate(weights:cur:)` consumes.
    @inline(__always)
    static func basisWeights(t: Float) -> SIMD4<Float> {
        let l0 = -((t + 1.0) * t * (t - 1.0)) / 6.0
        let l1 = ((t + 2.0) * t * (t - 1.0)) * 0.5
        let l2 = -((t + 2.0) * (t + 1.0) * (t - 1.0)) * 0.5
        let l3 = ((t + 2.0) * (t + 1.0) * t) / 6.0
        return SIMD4<Float>(l0, l1, l2, l3)
    }

    /// Bit-identical to `interpolate(t:cur:)` when `w == basisWeights(t:)` --
    /// same operands, same accumulation order -- but skips the per-call
    /// polynomial evaluation by using precomputed weights.
    @inline(__always)
    func interpolate(weights w: SIMD4<Float>, cur: Float) -> Float {
        (h3 * w.x) + (h2 * w.y) + (h1 * w.z) + (cur * w.w)
    }

    @inline(__always)
    mutating func advance(_ cur: Float) {
        h3 = h2; h2 = h1; h1 = cur
    }

    var isPrimed: Bool { initialized }
}

struct LinkwitzRiley4 {
    private var lp1 = Biquad()
    private var lp2 = Biquad()
    private var hp1 = Biquad()
    private var hp2 = Biquad()

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        lp1.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        lp2.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        hp1.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        hp2.configureHighpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func process(_ x: Float) -> (low: Float, high: Float) {
        let low = lp2.process(lp1.process(x))
        let high = hp2.process(hp1.process(x))
        return (low, high)
    }
}

struct StereoLinkwitzRiley4 {
    private var left = LinkwitzRiley4()
    private var right = LinkwitzRiley4()

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        left.configure(cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configure(cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func process(left: Float, right: Float) -> ((Float, Float), (Float, Float)) {
        (self.left.process(left), self.right.process(right))
    }
}

struct ProgramLowpass {
    var left = BiquadCascade6()
    var right = BiquadCascade6()

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        left.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        right.configureLowpass(cutoffHz: cutoffHz, sampleRate: sampleRate)
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        let l = self.left.process(left)
        let r = self.right.process(right)
        return (l, r)
    }
}

struct EnvelopeFollower {
    var attackCoeff: Float = 0.0
    var releaseCoeff: Float = 0.0
    var value: Float = 0.0

    mutating func configure(sampleRate: Float, attackMS: Float, releaseMS: Float) {
        let sr = max(8_000.0, sampleRate)
        let a = max(0.1, attackMS) * 0.001
        let r = max(1.0, releaseMS) * 0.001
        attackCoeff = expf(-1.0 / (a * sr))
        releaseCoeff = expf(-1.0 / (r * sr))
    }

    mutating func processAbs(_ x: Float) -> Float {
        let ax = fabsf(x)
        if ax > value {
            value = (attackCoeff * value) + ((1.0 - attackCoeff) * ax)
        } else {
            value = (releaseCoeff * value) + ((1.0 - releaseCoeff) * ax)
        }
        value = zapDenorm(value)
        return value
    }
}

/// Approximate ITU-R BS.1770-4 K-weighting pre-filter used as the
/// sidechain feed for perceptual power detection. Two cascaded RBJ
/// biquads (high-pass + high-shelf) approximate the BS.1770 curve:
/// low-frequency rumble is rolled off so it doesn't dominate the
/// detector; mid/upper frequencies get a gentle shelf boost so their
/// perceptually loud content (vocals, sibilance, cymbals) reads hot.
///
/// This doesn't need to be bit-identical to BS.1770 — the goal is
/// simply a rate-flexible, perceptually-weighted detector that sees
/// what humans hear, not what a flat RMS calculation sees. The
/// audio-path signal is untouched; these filters only feed the AGC's
/// power follower.
struct KWeightingFilter {
    private var hpf = Biquad()
    private var shelf = Biquad()

    mutating func configure(sampleRate: Float) {
        // RLB high-pass — roll off below ~38 Hz so sub-audible rumble
        // doesn't bias the detector.
        hpf.configureHighpass(cutoffHz: 38.0, sampleRate: sampleRate, q: 0.5)
        // Head-simulator shelf — +4 dB above ~1.5 kHz lifts the
        // perceptually loud register into the detector's view.
        shelf.configureHighShelf(gainDB: 4.0, cutoffHz: 1_500.0, sampleRate: sampleRate)
    }

    mutating func process(_ x: Float) -> Float {
        shelf.process(hpf.process(x))
    }

    mutating func reset() {
        hpf.reset()
        shelf.reset()
    }
}
