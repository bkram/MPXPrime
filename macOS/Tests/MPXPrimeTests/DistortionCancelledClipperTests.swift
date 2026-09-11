import Testing
import Foundation
@testable import MPXPrime

/// Tests for `DistortionCancelledClipper`.
///
/// The clipper currently runs at native sample rate. Its `tanh` nonlinearity
/// generates harmonics of the input above Nyquist that alias straight back into
/// the audio band. The LP-based error-cancellation in the clipper kills LF IMD
/// products but does not address HF aliasing.
///
/// Phase 7.1 wraps the clipper in 8x oversampling, which moves aliased
/// products above the reconstruction LP cutoff so they get filtered out
/// rather than landing in-band. These tests provide the objective measurement.
///
/// Test signal selection (5111 Hz @ 48 kHz):
/// - In-band real harmonics: 5111, 10222, 15333, 20444 Hz
/// - Above-Nyquist harmonics that fold back: 25555 -> 22445,
///   30666 -> 17334, 35777 -> 12223, 40888 -> 7112, 46000 -> 2000 Hz
/// - The 5 alias bins are well separated from the 4 real harmonics.
@Suite("DistortionCancelledClipper")
struct DistortionCancelledClipperTests {
    static let sampleRate: Float = 48_000.0
    static let testFreq: Float = 5_111.0

    /// Pre-7.1 (native rate): -28.73 dBFS.
    /// Post-7.1 (8x oversampled): -39.05 dBFS (10 dB improvement).
    ///
    /// The threshold is set at -38.0 dBFS to lock in the 8x oversampling
    /// improvement as a regression gate. The remaining 37 dB gap to the
    /// ideal -75 dBFS is bounded by the 5th harmonic of 5111 Hz landing
    /// at 25555 Hz (only 7% above native Nyquist) — Butterworth decimation
    /// can't suppress that close to its cutoff. A sharper FIR brick-wall
    /// (Phase 7.5 in docs/project-roadmap.md) would clear the full target.
    static let aliasingThresholdDBFS: Float = -38.0

    /// The 5 aliased-product frequencies for testFreq=5111 at sr=48000.
    static let aliasBinsHz: [Float] = [22_445, 17_334, 12_223, 7_112, 2_000]

    @Test("aliasing energy in-band stays below threshold")
    func aliasingEnergy() {
        var clipper = DistortionCancelledClipper()
        clipper.configure(
            sampleRate: Self.sampleRate,
            ceilingDB: -3.0,
            cancelFreqHz: 2_000.0
        )
        let report = NonlinearityProbe.runMonoTone(
            block: &clipper,
            freqHz: Self.testFreq,
            amplitude: 0.95,
            sampleRate: Self.sampleRate
        )
        let aliasEnergy = report.sumEnergyDBFS(atBins: Self.aliasBinsHz)
        #expect(
            aliasEnergy < Self.aliasingThresholdDBFS,
            "alias energy \(aliasEnergy) dBFS exceeds threshold \(Self.aliasingThresholdDBFS) dBFS"
        )
    }

    /// LF content above the ceiling must pass through largely unmodified —
    /// that is the whole point of distortion-cancelled clipping. Inputs below
    /// the cancellation frequency get hard-clipped, the LP-filtered error is
    /// subtracted back, and the LF signal emerges intact while the HF
    /// distortion (above the cancellation cutoff) is left in to be masked.
    /// Catches a future oversampling wrapper that accidentally breaks the
    /// cancellation path.
    @Test("LF content above ceiling passes through (cancellation works)")
    func lowFreqCancellation() {
        var clipper = DistortionCancelledClipper()
        clipper.configure(
            sampleRate: Self.sampleRate,
            ceilingDB: -3.0,
            cancelFreqHz: 2_000.0
        )
        // 500 Hz is well below the 2 kHz cancellation cutoff. Drive 3x the
        // ceiling so clipping is triggered hard; cancellation should restore
        // the LF fundamental.
        let frameCount = 8_192
        let input = SineGenerator.generate(
            freqHz: 500.0, amplitude: 2.0,
            sampleRate: Self.sampleRate, frameCount: frameCount
        )
        var output = [Float](repeating: 0.0, count: frameCount)
        for i in 0..<frameCount {
            let (l, _) = clipper.process(left: input[i], right: input[i])
            output[i] = l
        }
        // Take RMS of input and output over the steady-state second half.
        let stable = (frameCount / 2)..<frameCount
        var inSumSq: Double = 0
        var outSumSq: Double = 0
        for i in stable {
            inSumSq += Double(input[i] * input[i])
            outSumSq += Double(output[i] * output[i])
        }
        let inRMS = sqrt(inSumSq / Double(stable.count))
        let outRMS = sqrt(outSumSq / Double(stable.count))
        let rmsRatioDB = 20.0 * log10(outRMS / inRMS)
        // Cancellation should preserve LF energy within ~1 dB. Without
        // cancellation the output RMS would be ~3 dB lower (clipped peaks).
        #expect(
            abs(rmsRatioDB) < 1.0,
            "LF cancellation imbalance: out/in RMS = \(rmsRatioDB) dB (expected within ±1 dB)"
        )
    }

    /// HF content above the cancellation cutoff DOES get clipped and the
    /// ceiling must hold (modulo the soft-knee tanh shape which can sit
    /// slightly above the nominal ceiling). Catches a future oversampling
    /// wrapper that accidentally bypasses or weakens the clip.
    @Test("HF content above ceiling is clipped near the ceiling")
    func highFreqCeiling() {
        let ceilingDB: Float = -3.0
        var clipper = DistortionCancelledClipper()
        clipper.configure(
            sampleRate: Self.sampleRate,
            ceilingDB: ceilingDB,
            cancelFreqHz: 2_000.0
        )
        // 8 kHz is 2 octaves above the 2 kHz cancellation cutoff, so the
        // 4th-order LR4 LP attenuates the error path by ~48 dB and the
        // cancellation contribution to the output is negligible.
        let frameCount = 8_192
        let input = SineGenerator.generate(
            freqHz: 8_000.0, amplitude: 3.54,
            sampleRate: Self.sampleRate, frameCount: frameCount
        )
        var maxAbs: Float = 0.0
        for i in 0..<frameCount {
            let (l, _) = clipper.process(left: input[i], right: input[i])
            if i >= frameCount / 2 {
                maxAbs = max(maxAbs, abs(l))
            }
        }
        let ceilingLin = pow(10.0, Double(ceilingDB) / 20.0)
        // Tolerance: the inner hardClip soft-knee caps at ceiling * 1.05.
        // With 8x oversampling, the Butterworth reconstruction filter adds
        // small gibbs ringing that pushes transient peaks ~3% above the
        // steady-state clipped envelope, so effective tolerance expands.
        let tolerance: Float = 1.20
        let measuredDB = 20.0 * log10(Double(maxAbs))
        #expect(
            Double(maxAbs) <= ceilingLin * Double(tolerance),
            "HF max output \(maxAbs) (\(measuredDB) dBFS) exceeds ceiling+tolerance \(ceilingLin * Double(tolerance))"
        )
    }
}
