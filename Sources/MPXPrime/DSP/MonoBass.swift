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

/// Mono below `mono_bass_freq_hz`, as a linear-phase complementary pair: the
/// side becomes `delay(side) - LP(side)` with a Kaiser-windowed-sinc lowpass
/// and the mid is delayed by the same `groupDelaySamples`. Mid and side
/// stay sample-aligned at every frequency, so above the corner L and R are
/// the input delayed and nothing else, and the bass keeps its polarity and
/// waveform (`BassPolarityTests`). The lowpass is -6 dB at the corner with a
/// transition as wide as the corner (passband to fc / 2, stopband from
/// 1.5 fc) and a 40 dB Kaiser design: measured at 140 Hz / 48 kHz the side
/// is -33 dB at 60 Hz, -6 dB at fc, and within +/-0.11 dB of flat above
/// 1.5 fc (the old stage: -4.1 dB at 60 Hz, +2.1 dB at 179 Hz). Cost and
/// latency follow the corner (taps ~ 107,000 / fc at the 48 kHz audio
/// domain): 765 taps / 8.0 ms at 140 Hz, 9.7 ms at 115 Hz, 12.4 ms at
/// 90 Hz, 18.6 ms at 60 Hz, 4.5 ms at 250 Hz. A live corner edit re-times
/// the programme once, like a restart. With the dual-rate boundary off
/// (192 kHz audio domain) the design hits the 2049-tap clamp and the
/// transition widens.
///
/// Until 2026-10 the side was `side - LP2(side)` with a 2nd-order
/// Butterworth lowpass, which is not a highpass: it removed 4 dB of side at
/// 60 Hz, nothing at 100 Hz, and BOOSTED the side +1.8 dB at the corner and
/// +2.1 dB at 179 Hz (`|1 - H|` = sqrt(3/2) at the corner;
/// levelling review 2026-10 finding 1). The IIR repair the review
/// proposed -- LR4 highpass on the side, the LR4 allpass on the mid -- was
/// tried first and rejected on measurement: the allpass turns the mid bass
/// 60 to 100 degrees at 50 / 80 Hz, `BassPolarityTests` read the decoded
/// bass against the input at InPol 0.29 (defaults) and -0.06 (Music - Loud)
/// against a 0.5 floor, and an INVERTED chain then read +0.52, so the
/// guard could no longer see a real inversion. `EncoderMonoBassTests` pins
/// the side response, the untouched mid and the alignment.
struct MonoBassFilter {
    private var coeffs: [Float] = []
    /// Side history, double-buffered so the dot-product window is contiguous.
    private var sideDelay: [Float] = []
    /// Mid history (ring of `halfLength`: read-then-write delays by exactly that).
    private var midDelay: [Float] = []
    private var writeIndex = 0
    private var midIndex = 0
    private var lengthTaps = 0
    private var halfLength = 0

    var groupDelaySamples: Int { halfLength }

    static let stopBandDB: Float = 40.0

    mutating func configure(cutoffHz: Float, sampleRate: Float) {
        let corner = max(30.0, cutoffHz)
        // `kaiserSincLowpassCoefficients` puts -6 dB at cutoff + transition / 2.
        coeffs = kaiserSincLowpassCoefficients(
            cutoffHz: corner * 0.5, sampleRate: sampleRate,
            stopBandDB: Self.stopBandDB, transitionHz: corner)
        lengthTaps = coeffs.count
        halfLength = (lengthTaps - 1) / 2
        sideDelay = [Float](repeating: 0.0, count: lengthTaps * 2)
        midDelay = [Float](repeating: 0.0, count: max(1, halfLength))
        writeIndex = 0
        midIndex = 0
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        guard lengthTaps > 0 else { return (left, right) }
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5
        sideDelay[writeIndex] = side
        sideDelay[writeIndex + lengthTaps] = side
        // Oldest -> newest window at [writeIndex + 1, writeIndex + lengthTaps];
        // the kernel is symmetric, so direction does not matter.
        var low: Float = 0.0
        let start = writeIndex + 1
        coeffs.withUnsafeBufferPointer { c in
            sideDelay.withUnsafeBufferPointer { d in
                // swiftlint:disable:next force_unwrapping
                vDSP_dotpr(c.baseAddress!, 1, d.baseAddress!.advanced(by: start), 1, &low, vDSP_Length(lengthTaps))
            }
        }
        // The window's centre tap is side(t - halfLength).
        let centre = sideDelay[start + halfLength]
        writeIndex += 1
        if writeIndex >= lengthTaps { writeIndex = 0 }
        // Mid delayed by the same halfLength samples.
        let delayedMid = midDelay[midIndex]
        midDelay[midIndex] = mid
        midIndex += 1
        if midIndex >= midDelay.count { midIndex = 0 }
        let highSide = centre - low
        return (delayedMid + highSide, delayedMid - highSide)
    }
}
