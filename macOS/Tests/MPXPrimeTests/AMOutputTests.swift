import Testing
import Foundation
@testable import MPXPrime

// AM Output mode: a mono transmitter feed. Four things make it AM rather than
// "processed audio with a narrow filter", and each is measured here:
// the L+R sum, the NRSC-1 pre-emphasis curve, the band limit, and the
// asymmetric peak headroom (47 CFR 73.1570: positive peaks to 125 % while the
// negative peak stays at 100 %, which is what the transmitter is calibrated on).
@Suite("AM output mode")
struct AMOutputTests {

    private let blockSize = 512

    private func amConfig(sampleRate: Double) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = blockSize
        cfg.sourceMode = "input"
        cfg.operatingMode = .am
        cfg.processingBypass = false
        cfg.widebandAGCEnabled = false
        cfg.multibandEnabled = false
        cfg.primeBassEnabled = false
        cfg.monoBassEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.hfLimiterEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false
        cfg.enRDS = false
        cfg.preEncodeAudioLimiterEnabled = true
        return cfg
    }

    private func render(
        cfg: AppConfig, seconds: Double,
        sample: (_ i: Int, _ t: Double) -> (Float, Float)
    ) -> (left: [Float], right: [Float]) {
        let sr = cfg.sampleRate
        let gen = MPXGenerator(config: cfg, sampleRate: sr)
        gen.setAudioOutputOnly(true)
        gen.setEncoderFIREnabled(cfg.encoderFIREnabled)
        gen.setMultibandFIREnabled(cfg.multibandFIREnabled)
        let total = Int(sr * seconds)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let s = sample(i, Double(i) / sr)
            left[i] = s.0
            right[i] = s.1
        }
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                while offset < total {
                    let frames = min(blockSize, total - offset)
                    // swiftlint:disable force_unwrapping
                    gen.renderAudioOnlyFromInputInPlace(
                        frameCount: frames,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset))
                    // swiftlint:enable force_unwrapping
                    offset += frames
                }
            }
        }
        return (left, right)
    }

    private func goertzel(_ buf: [Float], freqHz: Double, sampleRate: Double, startFrame: Int) -> Double {
        let span = buf.count - startFrame
        guard span > 1_024 else { return 0 }
        let k = (Double(span) * freqHz / sampleRate).rounded()
        let omega = 2.0 * .pi * k / Double(span)
        let coeff = 2.0 * cos(omega)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<span {
            let s0 = coeff * s1 - s2 + Double(buf[startFrame + i])
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cos(omega)
        let imag = s2 * sin(omega)
        return sqrt(real * real + imag * imag) / Double(span) * 2.0
    }

    @Test func outputIsMonoRegardlessOfTheSource() {
        // AM is a mono service: a hard-panned source must leave as the sum on
        // both channels, not as a channel that happens to be silent.
        let sr = 48_000.0
        let cfg = amConfig(sampleRate: sr)
        let out = render(cfg: cfg, seconds: 0.5) { _, t in
            (Float(0.4 * sin(2.0 * .pi * 700.0 * t)), 0.0)   // hard left
        }
        let skip = Int(sr * 0.2)
        var worst: Float = 0
        for i in skip..<out.left.count { worst = max(worst, abs(out.left[i] - out.right[i])) }
        #expect(worst < 1e-6, "AM output must be identical on both channels; worst difference \(worst)")
        #expect(goertzel(out.right, freqHz: 700.0, sampleRate: sr, startFrame: skip) > 0.05,
                "the right channel must carry the summed program, not silence")
    }

    @Test func bandLimitFollowsTheAMBandwidthKey() {
        let sr = 48_000.0
        var cfg = amConfig(sampleRate: sr)
        cfg.amLowpassHz = 5_000.0
        cfg.amPreemphasisUS = 0
        let skip = Int(sr * 0.2)
        func level(_ f: Double) -> Double {
            let out = render(cfg: cfg, seconds: 0.5) { _, t in
                let s = Float(0.05 * sin(2.0 * .pi * f * t)); return (s, s)
            }
            return goertzel(out.left, freqHz: f, sampleRate: sr, startFrame: skip)
        }
        let reference = level(1_000.0)
        let inBand = level(4_000.0)
        let outOfBand = level(8_000.0)
        #expect(inBand > reference * 0.5,
                "4 kHz must pass a 5 kHz AM band limit: \(inBand) vs 1 kHz \(reference)")
        #expect(outOfBand < reference * 0.1,
                "8 kHz must be well down past a 5 kHz AM band limit: \(outOfBand) vs 1 kHz \(reference)")
    }

    @Test func nrscPreemphasisRisesWithFrequency() {
        // NRSC-1 pre-emphasis is the 75 us curve: +2.4 dB at 2 kHz, +9.6 dB at
        // 7.5 kHz relative to 1 kHz on the analog curve. The chain's limiter
        // rides the boosted peaks, so this checks the SHAPE at a level low
        // enough that nothing is limiting.
        let sr = 48_000.0
        var cfg = amConfig(sampleRate: sr)
        cfg.preEncodeAudioLimiterEnabled = false
        let skip = Int(sr * 0.2)
        func level(_ cfg: AppConfig, _ f: Double) -> Double {
            let out = render(cfg: cfg, seconds: 0.5) { _, t in
                let s = Float(0.02 * sin(2.0 * .pi * f * t)); return (s, s)
            }
            return 20.0 * log10(max(1e-12, goertzel(out.left, freqHz: f, sampleRate: sr, startFrame: skip)))
        }
        var flat = cfg
        flat.amPreemphasisUS = 0
        cfg.amPreemphasisUS = 75
        let reference = level(cfg, 1_000.0) - level(flat, 1_000.0)
        for (f, expected) in [(2_000.0, 2.4), (5_000.0, 7.0), (7_500.0, 9.6)] {
            let boost = (level(cfg, f) - level(flat, f)) - reference
            #expect(abs(boost - expected) < 1.0,
                    "75 us NRSC boost at \(Int(f)) Hz is \(boost) dB, expected about \(expected) dB")
        }
    }

    @Test func negativePeaksHoldTheModulationCeilingWhilePositivePeaksRideHigher() {
        // The asymmetry, on a deliberately positive-heavy program: the
        // negative side is the calibrated 100 % reference and must stay at
        // 100/125 of full scale, while the positive side may use the rest.
        let sr = 48_000.0
        var cfg = amConfig(sampleRate: sr)
        cfg.amPositivePeakPct = 125.0
        cfg.inputGainDB = 12.0
        let out = render(cfg: cfg, seconds: 0.6) { _, t in
            // Asymmetric by construction: a sine plus its own rectified half.
            let base = sin(2.0 * .pi * 300.0 * t)
            let s = Float(0.5 * base + 0.35 * max(0.0, base))
            return (s, s)
        }
        let skip = Int(sr * 0.25)
        var maxPositive: Float = 0
        var maxNegative: Float = 0
        for i in skip..<out.left.count {
            maxPositive = max(maxPositive, out.left[i])
            maxNegative = max(maxNegative, -out.left[i])
        }
        let negativeCeiling: Float = 100.0 / 125.0
        #expect(maxNegative <= negativeCeiling + 0.01,
                "negative peak \(maxNegative) exceeds the 100 % modulation reference \(negativeCeiling)")
        #expect(maxPositive > negativeCeiling,
                "positive peak \(maxPositive) should use the asymmetric headroom above \(negativeCeiling)")
        #expect(maxPositive <= 1.0 + 1e-6, "positive peak \(maxPositive) must stay inside full scale")
    }

    @Test func symmetricAsymmetryKeepsBothSidesAtFullModulation() {
        // At 100 % the mode is symmetric again: both halves reach the same
        // ceiling, so an operator who does not want asymmetric modulation
        // simply gets a normalised mono feed.
        let sr = 48_000.0
        var cfg = amConfig(sampleRate: sr)
        cfg.amPositivePeakPct = 100.0
        cfg.inputGainDB = 12.0
        let out = render(cfg: cfg, seconds: 0.5) { _, t in
            let s = Float(0.6 * sin(2.0 * .pi * 400.0 * t)); return (s, s)
        }
        let skip = Int(sr * 0.25)
        var maxPositive: Float = 0
        var maxNegative: Float = 0
        for i in skip..<out.left.count {
            maxPositive = max(maxPositive, out.left[i])
            maxNegative = max(maxNegative, -out.left[i])
        }
        #expect(maxPositive <= 1.0 + 1e-6 && maxNegative <= 1.0 + 1e-6)
        #expect(abs(maxPositive - maxNegative) < 0.05,
                "a symmetric program at 100 % should land symmetric: +\(maxPositive) / -\(maxNegative)")
        #expect(maxPositive > 0.7, "the feed should be normalised, not left quiet; got \(maxPositive)")
    }

    @Test func amModeCannotAffectTheCompositePath() {
        // Same construction rule as the digital target: the AM keys must be
        // inert on an MPX config, so a composite render is bit-identical.
        var composite = amConfig(sampleRate: 192_000.0)
        composite.operatingMode = .mpx
        var tagged = composite
        tagged.amPreemphasisUS = 0
        tagged.amLowpassHz = 3_000.0
        tagged.amPositivePeakPct = 100.0
        func renderComposite(_ c: AppConfig) -> [Float] {
            let gen = MPXGenerator(config: c, sampleRate: c.sampleRate)
            var left = [Float](repeating: 0, count: 8_192)
            for i in 0..<left.count {
                left[i] = Float(0.3 * sin(2.0 * .pi * 1_000.0 * Double(i) / c.sampleRate))
            }
            var right = left
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    // swiftlint:disable:next force_unwrapping
                    gen.renderFromInputInPlace(frameCount: l.count, left: l.baseAddress!, right: r.baseAddress!)
                }
            }
            return left
        }
        #expect(renderComposite(composite) == renderComposite(tagged),
                "AM keys moved the composite output")
    }
}
