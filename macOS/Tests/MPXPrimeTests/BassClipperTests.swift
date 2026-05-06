import Testing
import Foundation
@testable import MPXPrime

/// Tests for `BassClipper`.
///
/// `BassClipper` is an LR4 split + tanh-clip on the low band + sum with the
/// unfiltered high band. The clipper currently runs at native sample rate.
/// `tanh` of a low-frequency tone generates a very long harmonic series; in
/// the existing implementation, harmonics that exceed Nyquist alias back into
/// the audio band and ride into the output via the `clippedLow + originalHigh`
/// sum.
///
/// Phase 7.1 wraps the clipper in 4x oversampling so those aliased harmonics
/// are pushed above the reconstruction LP cutoff and removed.
///
/// Test signal selection (113 Hz @ 48 kHz):
/// - 113 is chosen so `48000 / 113 = 424.78...` is **not** an integer.
/// - Real harmonics live at exact multiples of 113: 113, 226, 339, ...
/// - Aliased harmonics fold to `48000 - 113·k = 113·N - 25` for some N.
///   They're offset 25 Hz from the real-harmonic ladder — about 8 FFT bins
///   away at fftSize=16384, sampleRate=48000 (binWidth = 2.93 Hz).
/// - This gives clean separation between real and aliased products so the
///   alias-energy measurement is unambiguous.
@Suite("BassClipper")
struct BassClipperTests {
    static let sampleRate: Float = 48_000.0
    static let testFreq: Float = 113.0
    static let fundamentalSpacing: Float = 113.0
    static let aliasOffset: Float = -25.0  // aliased - nearest real harmonic

    /// Pre-7.1 expectation: aliasing energy somewhere around -40 to -30 dBFS.
    /// Post-7.1 target: < -75 dBFS.
    /// **Expected to FAIL on current code.**
    static let aliasingThresholdDBFS: Float = -75.0

    /// Aliased-harmonic frequencies in the high band (above 1 kHz, below 16 kHz)
    /// where alias energy from a 113 Hz tone clipped at 48 kHz would land.
    /// Each bin: 113·N - 25 for selected N spanning a wide range.
    static let aliasBinsHz: [Float] = stride(from: 10, through: 140, by: 5)
        .map { Float($0) * fundamentalSpacing + aliasOffset }
        .filter { $0 > 1_000.0 && $0 < 16_000.0 }

    @Test("aliasing energy in high band stays below threshold")
    func aliasingEnergy() {
        var clipper = BassClipper()
        clipper.configure(
            sampleRate: Self.sampleRate,
            crossoverHz: 150.0,
            thresholdDB: -3.0,
            drive: 1.5
        )
        let report = NonlinearityProbe.runMonoTone(
            block: &clipper,
            freqHz: Self.testFreq,
            amplitude: 0.95,
            sampleRate: Self.sampleRate
        )
        let aliasEnergy = report.sumEnergyDBFS(atBins: Self.aliasBinsHz, toleranceHz: 5.0)
        #expect(
            aliasEnergy < Self.aliasingThresholdDBFS,
            "alias energy \(aliasEnergy) dBFS exceeds threshold \(Self.aliasingThresholdDBFS) dBFS"
        )
    }

    /// HF content above the LR4 crossover should pass through largely
    /// unchanged. The `clippedLow + originalHigh` sum implies the high-band
    /// path is just the LR4 high-pass of the input, with no nonlinear
    /// processing. Catches a future oversampling wrapper that breaks the
    /// LR4 split/sum phase coherence.
    @Test("HF passthrough is phase-coherent")
    func highFreqPassthrough() {
        var clipper = BassClipper()
        clipper.configure(
            sampleRate: Self.sampleRate,
            crossoverHz: 150.0,
            thresholdDB: -3.0,
            drive: 1.5
        )
        // 4 kHz: well above 150 Hz crossover, well within the high-band
        // passthrough region. Drive low enough that the low-band (which sees
        // ~0 of this frequency) doesn't matter.
        let amp: Float = 0.5
        let frameCount = 8_192
        let input = SineGenerator.generate(
            freqHz: 4_000.0, amplitude: amp,
            sampleRate: Self.sampleRate, frameCount: frameCount
        )
        var output = [Float](repeating: 0.0, count: frameCount)
        for i in 0..<frameCount {
            let (l, _) = clipper.process(left: input[i], right: input[i])
            output[i] = l
        }
        // Compare RMS in the steady-state half — the LR4 has measurable group
        // delay at low frequencies but at 4 kHz it's flat and aligned, so
        // RMS through the clipper should equal RMS of the input within 0.5 dB.
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
        #expect(
            abs(rmsRatioDB) < 0.5,
            "HF passthrough RMS imbalance: \(rmsRatioDB) dB (expected within ±0.5 dB)"
        )
    }

    /// Driving the bass band hard must visibly cap the output. Predicting the
    /// exact ceiling is messy because the output is `clippedLow + originalHigh`
    /// and the LR4 HP at 80 Hz still leaks ~25 dB of input into the high band,
    /// which adds to the clipped low band. So instead of comparing to a
    /// theoretical ceiling, assert "the output peak is dramatically lower
    /// than the input peak" — that's exactly what catches an accidentally
    /// bypassed clip in a future refactor.
    @Test("output is dramatically capped under hard drive")
    func clippingHappens() {
        let thresholdDB: Float = -3.0
        let drive: Float = 1.5
        var clipper = BassClipper()
        clipper.configure(
            sampleRate: Self.sampleRate,
            crossoverHz: 150.0,
            thresholdDB: thresholdDB,
            drive: drive
        )
        let inputAmp: Float = 3.0
        let frameCount = 8_192
        let input = SineGenerator.generate(
            freqHz: 80.0, amplitude: inputAmp,
            sampleRate: Self.sampleRate, frameCount: frameCount
        )
        var maxAbs: Float = 0.0
        for i in 0..<frameCount {
            let (l, _) = clipper.process(left: input[i], right: input[i])
            if i >= frameCount / 2 {
                maxAbs = max(maxAbs, abs(l))
            }
        }
        // Allow up to ~30% of input peak — current measured value is ~23%
        // (0.7 / 3.0). A bypass would put output peak ≥ input peak (>= 1.0
        // since clipping never amplifies), so this catches gross failures
        // with comfortable margin and won't be brittle to small DSP shifts.
        let cap: Float = inputAmp * 0.30
        #expect(
            maxAbs < cap,
            "output peak \(maxAbs) is not appreciably below input peak \(inputAmp) (cap \(cap)) — clipping appears bypassed"
        )
    }
}
