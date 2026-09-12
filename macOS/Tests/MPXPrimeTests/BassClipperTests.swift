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


    // MARK: - Transfer continuity through the real stage (0.60 audit, P0-2)

    /// Shipped operating point: 150 Hz / -3 dB / drive 1.5.
    private static func shippedClipper() -> BassClipper {
        var clipper = BassClipper()
        clipper.configure(sampleRate: sampleRate, crossoverHz: 150.0, thresholdDB: -3.0, drive: 1.5)
        return clipper
    }

    /// Output peak of a 60 Hz tone at `amplitude` through a fresh clipper,
    /// measured after the stage has settled.
    private static func settledPeak(amplitude: Float) -> Float {
        var clipper = shippedClipper()
        let frames = Int(sampleRate * 0.4)
        let settle = Int(sampleRate * 0.2)
        var peak: Float = 0.0
        for i in 0..<frames {
            let x = amplitude * sinf(2.0 * .pi * 60.0 * Float(i) / sampleRate)
            let (l, _) = clipper.process(left: x, right: x)
            if i >= settle { peak = max(peak, fabsf(l)) }
        }
        return peak
    }

    /// Louder in must never mean quieter out. The pre-0.60 curve stepped
    /// DOWN 24 % the moment the driven band crossed the threshold, so a kick
    /// whose peak sat exactly there came out quieter than a slightly softer
    /// one. This walks the input level across that point through the real
    /// oversampled stage and requires the output peak to be monotonic.
    @Test("output peak is monotonic in input peak across the threshold")
    func outputPeakIsMonotonicAcrossTheThreshold() {
        // Threshold -3 dB = 0.708 in the driven domain; drive 1.5 puts the
        // crossing at an input of ~0.47. Sweep finely through it.
        var previous: Float = 0.0
        var amplitude: Float = 0.36
        var worstDropDB: Float = 0.0
        var worstAt: Float = 0.0
        while amplitude <= 0.62 {
            let peak = Self.settledPeak(amplitude: amplitude)
            if peak < previous {
                let drop = 20.0 * log10f(peak / previous)
                if drop < worstDropDB { worstDropDB = drop; worstAt = amplitude }
            }
            previous = max(previous, peak)
            amplitude += 0.01
        }
        // Measured through this stage at the shipped point: the pre-0.60 curve
        // dips 0.16 dB (the 4x decimator smears the bare curve's 24 % step
        // down to that), the continuous curve 0.00 dB.
        #expect(worstDropDB > -0.05,
                "output fell \(worstDropDB) dB as input rose to \(worstAt) -- the transfer is not monotonic")
    }

    /// Broadband splatter from a hot low tone. A discontinuous curve is
    /// traversed four times per cycle and each crossing is a step; that
    /// energy lands everywhere, including where the 4x decimator cannot
    /// remove it. The existing alias test above uses the same 113 Hz trick to
    /// tell folded products from real harmonics; this one just bounds the
    /// total energy above 15 kHz, where no real harmonic of a smooth curve
    /// has any business being.
    @Test("a hot low tone leaves no broadband splatter above 15 kHz")
    func hotLowToneLeavesNoBroadbandSplatter() {
        var clipper = Self.shippedClipper()
        let n = 16_384
        let settle = Int(Self.sampleRate * 0.2)
        var out = [Float](repeating: 0.0, count: n)
        var i = 0
        while i < settle + n {
            let x = 0.9 * sinf(2.0 * .pi * Self.testFreq * Float(i) / Self.sampleRate)
            let (l, _) = clipper.process(left: x, right: x)
            if i >= settle { out[i - settle] = l }
            i += 1
        }
        // Energy above 15 kHz vs the fundamental, by Goertzel over a comb of
        // bins so the measurement does not depend on FFT windowing.
        func mag(_ hz: Float) -> Double {
            let k = (Double(hz) * Double(n) / Double(Self.sampleRate)).rounded()
            let w = 2.0 * Double.pi * k / Double(n)
            let c = 2.0 * cos(w)
            var s1 = 0.0, s2 = 0.0
            for v in out { let s0 = c * s1 - s2 + Double(v); s2 = s1; s1 = s0 }
            let re = s1 - s2 * cos(w), im = s2 * sin(w)
            return sqrt(re * re + im * im) / Double(n) * 2.0
        }
        let fundamental = mag(Self.testFreq)
        var high = 0.0
        var f: Float = 15_100.0
        while f < 23_500.0 { high += pow(mag(f), 2.0); f += 100.0 }
        let splatterDB = 20.0 * log10(sqrt(high) / max(1e-12, fundamental))
        // Measured at the shipped point: pre-0.60 curve -55.0 dB, continuous
        // curve -56.6 dB. Oversampling already does most of the work here; the
        // bound is a regression guard against the old curve, not a target.
        #expect(splatterDB < -56.0,
                "energy above 15 kHz is \(splatterDB) dB relative to the fundamental (old curve: -55.0)")
    }
}
