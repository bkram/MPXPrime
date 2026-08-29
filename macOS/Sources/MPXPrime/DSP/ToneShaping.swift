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
func effectiveProgramLowpassHz(configured: Float, preemphasisUS: Int) -> Float {
    guard preemphasisUS > 0 else { return configured }
    let complianceCap: Float = preemphasisUS <= 50 ? 15_300.0 : 15_000.0
    return min(configured, complianceCap)
}

@inline(__always)
func effectiveEncoderLowpassHz(configured: Float, preemphasisUS: Int) -> Float {
    guard preemphasisUS > 0 else { return configured }
    let encoderCap: Float = preemphasisUS <= 50 ? 14_900.0 : 14_600.0
    return min(configured, encoderCap)
}

struct PreemphasisFilter {
    var enabled: Bool = false
    private var a: Float = 0.0
    private var invOneMinusA: Float = 1.0
    private var x1: Float = 0.0

    mutating func configure(tauUS: Int, sampleRate: Float) {
        guard tauUS > 0 else {
            enabled = false
            a = 0.0
            invOneMinusA = 1.0
            x1 = 0.0
            return
        }
        enabled = true
        let sr = max(8_000.0 as Float, sampleRate)
        let tau = Float(tauUS) * 1e-6
        a = expf(-1.0 / (tau * sr))
        invOneMinusA = 1.0 / max(1e-9, (1.0 - a))
        x1 = 0.0
    }

    mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let y = (x - a * x1) * invOneMinusA
        x1 = zapDenorm(x)
        return y
    }

    mutating func reset() { x1 = 0.0 }
}
