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

// MARK: - Phase Rotator (4-pole allpass chain)
// Reduces waveform asymmetry (especially male voice) by ~3-4 dB,
// yielding free headroom for downstream AGC, compressors, and limiters.
// Standard in Orban Optimod, Stereotool, BreakawayOne.
struct PhaseRotator {
    private var ap1 = Biquad()
    private var ap2 = Biquad()
    private var ap3 = Biquad()
    private var ap4 = Biquad()

    mutating func configure(freqHz: Float, sampleRate: Float) {
        let q: Float = 0.7071068
        ap1.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
        ap2.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
        ap3.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
        ap4.configureAllpass(freqHz: freqHz, sampleRate: sampleRate, q: q)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        ap4.process(ap3.process(ap2.process(ap1.process(x))))
    }
}

struct StereoPhaseRotator {
    var left = PhaseRotator()
    var right = PhaseRotator()

    mutating func configure(freqHz: Float, sampleRate: Float) {
        left.configure(freqHz: freqHz, sampleRate: sampleRate)
        right.configure(freqHz: freqHz, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(left l: Float, right r: Float) -> (Float, Float) {
        (self.left.process(l), self.right.process(r))
    }
}

// MARK: - Parametric EQ (4-band: low shelf + 2 peaking + high shelf)
struct ParametricEQ4Band {
    private var band1 = StereoBiquad()  // low shelf
    private var band2 = StereoBiquad()  // peaking
    private var band3 = StereoBiquad()  // peaking
    private var band4 = StereoBiquad()  // high shelf

    // Shelf bands (1 and 4) use the RBJ default slope=1.0 (Butterworth
    // shelf); they expose no Q control since the shelf biquad is slope-
    // parameterized, not Q-parameterized. Only the peaking bands (2 and 3)
    // take a Q.
    mutating func configure(
        sampleRate: Float,
        b1FreqHz: Float, b1GainDB: Float,
        b2FreqHz: Float, b2GainDB: Float, b2Q: Float,
        b3FreqHz: Float, b3GainDB: Float, b3Q: Float,
        b4FreqHz: Float, b4GainDB: Float
    ) {
        band1.configureLowShelf(gainDB: b1GainDB, cutoffHz: b1FreqHz, sampleRate: sampleRate)
        band2.configurePeakingEQ(freqHz: b2FreqHz, gainDB: b2GainDB, sampleRate: sampleRate, q: b2Q)
        band3.configurePeakingEQ(freqHz: b3FreqHz, gainDB: b3GainDB, sampleRate: sampleRate, q: b3Q)
        band4.configureHighShelf(gainDB: b4GainDB, cutoffHz: b4FreqHz, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(left l: Float, right r: Float) -> (Float, Float) {
        var out = band1.process(left: l, right: r)
        out = band2.process(left: out.0, right: out.1)
        out = band3.process(left: out.0, right: out.1)
        out = band4.process(left: out.0, right: out.1)
        return out
    }
}

@inline(__always)
func effectiveProgramLowpassHz(configured: Float, preemphasisUS: Int, digital: Bool = false)
    -> Float {
    // Digital delivery (stream / DAB+) has no FM band plan: the configured
    // lowpass stands as written, up to the config clamp (20 kHz).
    if digital { return configured }
    // Composite and FM-coder feeds stay under the 19 kHz pilot even when the
    // INI asks for more -- this cap is what lets the config clamp be 20 kHz.
    guard preemphasisUS > 0 else { return min(configured, 16_000.0) }
    let complianceCap: Float = preemphasisUS <= 50 ? 15_300.0 : 15_000.0
    return min(configured, complianceCap)
}

@inline(__always)
func effectiveEncoderLowpassHz(configured: Float, preemphasisUS: Int, digital: Bool = false)
    -> Float {
    if digital { return configured }
    guard preemphasisUS > 0 else { return min(configured, 16_000.0) }
    let encoderCap: Float = preemphasisUS <= 50 ? 14_900.0 : 14_600.0
    return min(configured, encoderCap)
}

/// The program lowpass (6th-order Butterworth, RBJ sections) with the response
/// it has at a REFERENCE rate, run at an integer multiple of it.
///
/// A bilinear Butterworth's passband droop depends on the rate it is designed
/// at: at 15.3 kHz it is -0.47 dB at 14 kHz on the 48 kHz audio domain but
/// -1.24 dB at 192 kHz, so the boundary-off (full-rate) composite read 0.77 dB
/// under the boundary-on chain at 14 kHz. Here the reference-rate design runs
/// as H(z^k), k = rate / reference: each delay is k samples, which is k
/// interleaved copies of the reference filter. Below reference/2 its magnitude
/// AND phase equal the reference design's exactly; the images it passes above
/// that (from 33 kHz up for a 48 kHz reference) are what the encoder FIR
/// downstream removes, as the boundary's own decimator does on the dual-rate
/// path. `isStrided` is false when the rate is not an integer multiple (>= 2)
/// of the reference; callers then keep the plain `ProgramLowpass`.
struct StridedProgramLowpass {
    private static let butterworthQ: [Double] = [0.5176381, 0.7071068, 1.9318517]
    private var b0: [Float] = []
    private var b1: [Float] = []
    private var b2: [Float] = []
    private var a1: [Float] = []
    private var a2: [Float] = []
    // Transposed direct form II state, one ring of `stride` slots per section
    // and channel: slot `phase` holds what the section wrote `stride` samples ago.
    private var z1L: [Float] = []
    private var z2L: [Float] = []
    private var z1R: [Float] = []
    private var z2R: [Float] = []
    private var stride: Int = 1
    private var phase: Int = 0

    var isStrided: Bool { stride >= 2 }

    mutating func configure(cutoffHz: Float, sampleRate: Float, referenceRate: Float) {
        let reference = max(8_000.0, referenceRate)
        let k = Int((sampleRate / reference).rounded())
        guard k >= 2, abs(sampleRate - (Float(k) * reference)) < 0.5 else {
            stride = 1
            b0 = []; b1 = []; b2 = []; a1 = []; a2 = []
            z1L = []; z2L = []; z1R = []; z2R = []
            phase = 0
            return
        }
        stride = k
        // RBJ lowpass, as `Biquad.configureLowpass`, at the reference rate.
        let sr = Double(reference)
        let fc = min(max(8.0, Double(cutoffHz)), max(16.0, (sr * 0.5) - 10.0))
        let w0 = 2.0 * Double.pi * fc / sr
        let c = cos(w0)
        let s = sin(w0)
        b0 = []; b1 = []; b2 = []; a1 = []; a2 = []
        for q in Self.butterworthQ {
            let alpha = s / (2.0 * q)
            let a0 = 1.0 + alpha
            b0.append(Float(((1.0 - c) * 0.5) / a0))
            b1.append(Float((1.0 - c) / a0))
            b2.append(Float(((1.0 - c) * 0.5) / a0))
            a1.append(Float((-2.0 * c) / a0))
            a2.append(Float((1.0 - alpha) / a0))
        }
        let slots = Self.butterworthQ.count * k
        z1L = [Float](repeating: 0.0, count: slots)
        z2L = [Float](repeating: 0.0, count: slots)
        z1R = [Float](repeating: 0.0, count: slots)
        z2R = [Float](repeating: 0.0, count: slots)
        phase = 0
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        guard isStrided else { return (left, right) }
        var l = left
        var r = right
        for section in 0..<b0.count {
            let i = (section * stride) + phase
            let yl = (b0[section] * l) + z1L[i]
            z1L[i] = zapDenorm((b1[section] * l) - (a1[section] * yl) + z2L[i])
            z2L[i] = zapDenorm((b2[section] * l) - (a2[section] * yl))
            l = yl
            let yr = (b0[section] * r) + z1R[i]
            z1R[i] = zapDenorm((b1[section] * r) - (a1[section] * yr) + z2R[i])
            z2R[i] = zapDenorm((b2[section] * r) - (a2[section] * yr))
            r = yr
        }
        phase = (phase + 1 == stride) ? 0 : phase + 1
        return (l, r)
    }
}

/// FM pre-emphasis (50 / 75 us) matched to the analog network |1 + j omega tau|.
///
/// A direct-form biquad whose coefficients come from `PreemphasisDesign.fit`
/// (MPXPrimeCore; the decoder's `DeemphasisFilter` is its exact inverse). See
/// the design's documentation for why the textbook matched-z zero was replaced.
struct PreemphasisFilter {
    var enabled: Bool = false
    private var b0: Float = 1.0
    private var b1: Float = 0.0
    private var b2: Float = 0.0
    private var a1: Float = 0.0
    private var a2: Float = 0.0
    private var x1: Float = 0.0
    private var x2: Float = 0.0
    private var y1: Float = 0.0
    private var y2: Float = 0.0

    /// FM pre-emphasis. Shorthand for `configure(curve: .fm(tauUS:), ...)`.
    mutating func configure(tauUS: Int, sampleRate: Float) {
        configure(curve: .fm(tauUS: tauUS), sampleRate: sampleRate)
    }

    /// Apply a named standard. AM must pass `.nrsc`, never `.fm(tauUS: 75)`:
    /// the two curves differ by 3.6 dB at 10 kHz and keep diverging above it.
    mutating func configure(curve: PreemphasisCurve, sampleRate: Float) {
        guard let design = curve.design(sampleRate: sampleRate) else {
            enabled = false
            b0 = 1.0; b1 = 0.0; b2 = 0.0; a1 = 0.0; a2 = 0.0
            reset()
            return
        }
        enabled = true
        b0 = Float(design.b0); b1 = Float(design.b1); b2 = Float(design.b2)
        a1 = Float(design.a1); a2 = Float(design.a2)
        reset()
    }

    mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let y = (b0 * x) + (b1 * x1) + (b2 * x2) - (a1 * y1) - (a2 * y2)
        x2 = x1
        x1 = x
        y2 = y1
        y1 = zapDenorm(y)
        return y
    }

    mutating func reset() {
        x1 = 0.0; x2 = 0.0; y1 = 0.0; y2 = 0.0
    }
}
