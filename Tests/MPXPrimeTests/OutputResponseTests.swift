import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// Frequency response of the three processed-audio outputs (FM Output, HD
// Output, AM Output) -- the L/R an external coder or transmitter receives.
// These modes always run with the dual-rate boundary off, so the whole engine
// runs at the output device rate; each curve is therefore pinned at 48, 96 and
// 192 kHz. Tones are kept below every limiter (asserted, not assumed), so the
// figures are the chain's linear response, not a limited peak.
//
// Until 2026-10-16 the 6th-order Butterworth program lowpass (15.3 kHz at
// 50 us) ran in series with the encoder FIR on these paths and drooped the
// treble by an amount that depended on the device rate: FM Output at 14 kHz
// read -0.47 dB off the analogue 50 us curve at 48 kHz, -1.10 dB at 96 kHz
// and -1.24 dB at 192 kHz, and AM Output -0.76 dB off NRSC-1 at 9 kHz. In
// these modes the encoder FIR (1 kHz transition) is now the only band-limit;
// measured after: within 0.01 dB of the curve to 14 kHz (FM) and 9 kHz (AM).
@Suite("Processed-audio output frequency response")
struct OutputResponseTests {

    private let blockSize = 512
    private static let rates: [Double] = [48_000.0, 96_000.0, 192_000.0]

    private func config(_ mode: AppConfig.OperatingMode, sampleRate: Double) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = blockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.operatingMode = mode
        cfg.processingBypass = false
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.widebandAGCEnabled = false
        cfg.advancedDynamicsEnabled = false
        cfg.primeBassEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.hfLimiterEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false
        cfg.enRDS = false
        cfg.encoderFIREnabled = true
        return cfg
    }

    /// Level of a steady L = R tone at the output, in dB, plus the largest
    /// pre-encode limiter gain reduction seen inside the measurement window.
    private func level(_ cfg: AppConfig, frequency f: Double, amplitude: Double = 0.03)
        -> (db: Double, grDB: Float) {
        let sr = cfg.sampleRate
        let gen = MPXGenerator(config: cfg, sampleRate: sr)
        // Mirror AudioOutputEngine.start() for a processed-audio mode.
        gen.setAudioOutputOnly(true)
        gen.setSampleRate(sr)
        gen.setEncoderFIREnabled(cfg.encoderFIREnabled)
        gen.setMultibandFIREnabled(cfg.multibandFIREnabled)
        let total = Int(sr * 0.5)
        let skip = Int(sr * 0.2)
        var left = [Float](repeating: 0, count: total)
        for i in 0..<total { left[i] = Float(amplitude * sin(2.0 * .pi * f * Double(i) / sr)) }
        var right = left
        var maxGR: Float = 0
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
                    if offset > skip {
                        maxGR = max(maxGR, gen.finalLimiterStatus.preEncodeGainReductionDB)
                    }
                }
            }
        }
        // Goertzel at f over the settled window.
        let span = total - skip
        let k = (Double(span) * f / sr).rounded()
        let omega = 2.0 * .pi * k / Double(span)
        let coeff = 2.0 * cos(omega)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<span {
            let s0 = coeff * s1 - s2 + Double(left[skip + i])
            s2 = s1
            s1 = s0
        }
        let re = s1 - s2 * cos(omega)
        let im = s2 * sin(omega)
        let mag = sqrt(re * re + im * im) / Double(span) * 2.0
        return (20.0 * log10(max(1e-12, mag)), maxGR)
    }

    /// Measured response re 1 kHz minus the target curve re 1 kHz, per
    /// frequency, with every render checked to be below the limiter.
    private func errors(_ cfg: AppConfig, frequencies: [Double],
                        target: (Double) -> Double) -> [(hz: Double, errorDB: Double)] {
        let reference = level(cfg, frequency: 1_000.0)
        #expect(reference.grDB == 0.0, "the limiter acted on the 1 kHz reference (\(reference.grDB) dB)")
        return frequencies.map { f in
            let measured = level(cfg, frequency: f)
            #expect(measured.grDB == 0.0,
                    "the limiter acted at \(Int(f)) Hz (\(measured.grDB) dB): this would compare limited peaks")
            let error = (measured.db - reference.db) - (target(f) - target(1_000.0))
            return (f, error)
        }
    }

    private func report(_ rows: [(hz: Double, errorDB: Double)]) -> String {
        rows.map { String(format: "%.0f Hz %+.2f dB", $0.hz, $0.errorDB) }.joined(separator: ", ")
    }

    @Test(arguments: [50, 75])
    func fmOutputFollowsTheAnaloguePreemphasisCurveAtEveryRate(tauUS: Int) {
        // What an external stereo coder fed by FM Output receives must be the
        // analogue pre-emphasis network: the receiver de-emphasises with it.
        let curve = PreemphasisCurve.fm(tauUS: tauUS)
        // 15 kHz only for 50 us: the encoder FIR is flat to its cutoff, which
        // `effectiveEncoderLowpassHz` caps at 14.9 kHz for 50 us but 14.6 kHz
        // for 75 us, so at 75 us 15 kHz is inside the transition by design.
        var frequencies: [Double] = [100, 2_000, 5_000, 8_000, 10_000, 12_000, 13_000, 14_000]
        if tauUS <= 50 { frequencies.append(15_000) }
        for sr in Self.rates {
            var cfg = config(.fm, sampleRate: sr)
            cfg.preemphasisUS = tauUS
            let rows = errors(cfg, frequencies: frequencies) { curve.analogGainDB(frequencyHz: $0) }
            for row in rows {
                let tolerance = 0.3
                #expect(abs(row.errorDB) < tolerance,
                        "FM Output \(tauUS) us at a \(Int(sr)) Hz rate is \(String(format: "%+.2f", row.errorDB)) dB off the analogue curve at \(Int(row.hz)) Hz -- \(report(rows))")
            }
        }
    }

    @Test func fmOutputBandLimitStaysAtFifteenKilohertz() {
        // The 15 kHz band limit does not move: the encoder FIR (and the
        // pre-encode limiter's decimator) hold 17 and 19 kHz far down at
        // every rate that can represent them.
        for sr in [96_000.0, 192_000.0] {
            var cfg = config(.fm, sampleRate: sr)
            cfg.preemphasisUS = 50
            let reference = level(cfg, frequency: 1_000.0).db
            for f in [17_000.0, 19_000.0] {
                let rel = level(cfg, frequency: f, amplitude: 0.01).db - reference
                #expect(rel < -60.0, "FM Output at \(Int(sr)) Hz passes \(Int(f)) Hz at \(String(format: "%.1f", rel)) dB re 1 kHz")
            }
        }
    }

    @Test func hdOutputIsFlatAtEveryRate() {
        // A codec must receive the programme, not an FM-shaped version of it.
        let frequencies: [Double] = [100, 2_000, 5_000, 8_000, 10_000, 12_000, 14_000, 15_000]
        for sr in Self.rates {
            var cfg = config(.hd, sampleRate: sr)
            cfg.preemphasisUS = 50   // forced off for digital delivery
            cfg.programLowpassHz = 20_000.0
            let rows = errors(cfg, frequencies: frequencies) { _ in 0.0 }
            for row in rows {
                #expect(abs(row.errorDB) < 0.2,
                        "HD Output at a \(Int(sr)) Hz rate is \(String(format: "%+.2f", row.errorDB)) dB off flat at \(Int(row.hz)) Hz -- \(report(rows))")
            }
        }
    }

    @Test func amOutputFollowsTheNRSCCurveAtEveryRate() {
        // NRSC-1-C inside the AM band (10 kHz default). The encoder FIR is
        // flat to its cutoff, so the curve holds to 9 kHz.
        let frequencies: [Double] = [100, 2_000, 4_000, 6_000, 7_500, 8_000, 9_000]
        for sr in Self.rates {
            var cfg = config(.am, sampleRate: sr)
            cfg.amPreemphasisUS = 75
            let rows = errors(cfg, frequencies: frequencies) {
                PreemphasisCurve.nrsc.analogGainDB(frequencyHz: $0)
            }
            for row in rows {
                #expect(abs(row.errorDB) < 0.3,
                        "AM Output at a \(Int(sr)) Hz rate is \(String(format: "%+.2f", row.errorDB)) dB off NRSC-1 at \(Int(row.hz)) Hz -- \(report(rows))")
            }
        }
    }
}
