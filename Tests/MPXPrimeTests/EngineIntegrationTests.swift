import Foundation
import Testing
@testable import MPXPrime
import MPXPrimeCore

// Engine integration of the 2026-10 levelling / peak-control review fixes
// (fix round G1): the allpass-compensated IIR crossovers on the low-latency
// path, the multiband stereo link as an L/R amount, the classic band
// limiters' per-band peak hold, the FIR splitter's tap limit with the
// dual-rate boundary off, `setSampleRate` re-deriving the dual-rate factor,
// and the encoder FIR's 1 kHz processed-audio transition.
@Suite("Engine integration (levelling review)")
struct EngineIntegrationTests {

    private let blockSize = 512

    // MARK: - Processed-audio harness (dual-rate boundary off, L/R out)

    private func fmConfig(sampleRate: Double = 48_000.0) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = blockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.operatingMode = .fm
        cfg.processingBypass = false
        cfg.preEncodeAudioLimiterEnabled = false
        cfg.widebandAGCEnabled = false
        cfg.advancedDynamicsEnabled = false
        cfg.primeBassEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.downwardExpanderEnabled = false
        cfg.multibandInterBandCouplingEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.hfLimiterEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false
        cfg.enRDS = false
        cfg.encoderFIREnabled = true
        return cfg
    }

    private func makeProcessedAudioGenerator(_ cfg: AppConfig) -> MPXGenerator {
        let gen = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        // Mirror AudioOutputEngine.start() for a processed-audio mode.
        gen.setAudioOutputOnly(true)
        gen.setSampleRate(cfg.sampleRate)
        gen.setEncoderFIREnabled(cfg.encoderFIREnabled)
        gen.setMultibandFIREnabled(cfg.multibandFIREnabled)
        return gen
    }

    /// Render L / R through the processed-audio path and return the output.
    private func renderAudio(_ gen: MPXGenerator, left: [Float], right: [Float]) -> (l: [Float], r: [Float]) {
        var l = left
        var r = right
        let total = l.count
        l.withUnsafeMutableBufferPointer { lBuf in
            r.withUnsafeMutableBufferPointer { rBuf in
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
        return (l, r)
    }

    /// Amplitude (dB) of the component at `f` over `samples[skip...]`.
    private func toneDB(_ samples: [Float], frequency f: Double, sampleRate sr: Double, skip: Int) -> Double {
        let span = samples.count - skip
        let omega = 2.0 * .pi * f / sr
        var re = 0.0, im = 0.0
        for i in 0..<span {
            let x = Double(samples[skip + i])
            re += x * cos(omega * Double(i))
            im += x * sin(omega * Double(i))
        }
        return 20.0 * log10(max(1e-12, 2.0 * sqrt(re * re + im * im) / Double(span)))
    }

    private func sine(_ f: Double, amplitude: Double, frames: Int, sampleRate sr: Double) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2.0 * .pi * f * Double($0) / sr)) }
    }

    /// Steady L = R tone level at the processed-audio output.
    private func level(_ cfg: AppConfig, frequency f: Double) -> Double {
        let sr = cfg.sampleRate
        let total = Int(sr * 0.5)
        let x = sine(f, amplitude: 0.03, frames: total, sampleRate: sr)
        let out = renderAudio(makeProcessedAudioGenerator(cfg), left: x, right: x)
        return toneDB(out.l, frequency: f, sampleRate: sr, skip: Int(sr * 0.25))
    }

    // MARK: - 1a. IIR crossovers sum flat

    @Test(arguments: [3, 5])
    func iirMonitorCrossoversSumFlat(bands: Int) {
        // The low-latency (IIR) multiband path, every band idle: the
        // multiband stage must be a flat-magnitude allpass. The generator
        // used to run a plain LR4 tree, LP1 + HP1 (LP2 + HP2 (...)), which
        // is not one: -0.81 dB at 116 Hz on the 5-band 90 / 350 / 1800 /
        // 6800 Hz crossovers, -0.18 dB around 420 Hz on the 3-band ones.
        var off = fmConfig()
        off.multibandFIREnabled = false
        var on = off
        on.multibandEnabled = true
        on.multibandMode = bands
        on.multibandMakeupDB = 0.0
        on.multibandX1Hz = bands == 5 ? 90.0 : 320.0
        on.multibandX2Hz = bands == 5 ? 350.0 : 2_550.0
        on.multibandX3Hz = 1_800.0
        on.multibandX4Hz = 6_800.0
        let frequencies: [Double] = [60, 90, 116, 150, 200, 350, 422, 700, 1_000, 1_800, 2_550, 4_000, 6_800, 10_000]
        var worst = 0.0
        var rows: [String] = []
        for f in frequencies {
            let delta = level(on, frequency: f) - level(off, frequency: f)
            rows.append(String(format: "%.0f Hz %+.3f dB", f, delta))
            worst = max(worst, abs(delta))
        }
        print("IIR \(bands)-band multiband (idle) re bypass: " + rows.joined(separator: ", "))
        #expect(worst < 0.05, "\(bands)-band IIR crossovers do not sum flat: \(rows.joined(separator: ", "))")
    }

    // MARK: - 1b. Stereo link is an L/R amount

    /// Gain reduction (dB) on a loud L tone and a quiet R tone in the same
    /// band, at a given link amount.
    private func channelGainReduction(link: Double) -> (left: Double, right: Double) {
        var cfg = fmConfig()
        cfg.multibandEnabled = true
        cfg.multibandMode = 3
        cfg.multibandFIREnabled = false
        cfg.multibandLowThresholdDB = -30.0
        cfg.multibandMidThresholdDB = -30.0
        cfg.multibandHighThresholdDB = -30.0
        cfg.multibandLowRatio = 4.0
        cfg.multibandMidRatio = 4.0
        cfg.multibandHighRatio = 4.0
        cfg.multibandKneeDB = 0.0
        cfg.multibandReleaseProgramDependent = false
        cfg.multibandLinkStrength = link
        let sr = cfg.sampleRate
        let frames = Int(sr * 1.0)
        let left = sine(1_000.0, amplitude: 0.2, frames: frames, sampleRate: sr)
        let right = sine(1_000.0, amplitude: 0.005, frames: frames, sampleRate: sr)
        // The same chain with the multiband off is the reference (pre-
        // emphasis and the encoder FIR are common to both).
        var bypass = cfg
        bypass.multibandEnabled = false
        let out = renderAudio(makeProcessedAudioGenerator(cfg), left: left, right: right)
        let ref = renderAudio(makeProcessedAudioGenerator(bypass), left: left, right: right)
        let skip = Int(sr * 0.5)
        func db(_ x: [Float]) -> Double { toneDB(x, frequency: 1_000.0, sampleRate: sr, skip: skip) }
        return (db(ref.l) - db(out.l), db(ref.r) - db(out.r))
    }

    @Test func stereoLinkIsAnAmountBetweenIndependentAndLinked() {
        // 0 = each channel compressed on its own (the quiet R is below
        // threshold and passes untouched), 1 = one shared gain (R takes L's
        // reduction exactly), and values between give R part of it. The old
        // control fed both channels ONE sidechain at any value above 1e-4,
        // so L and R always took the same reduction and the value only
        // blended that shared detector between two near-equal readings.
        let independent = channelGainReduction(link: 0.0)
        let half = channelGainReduction(link: 0.5)
        let linked = channelGainReduction(link: 1.0)
        print(String(format: "GR L / R: link 0 %.2f / %.2f dB, 0.5 %.2f / %.2f dB, 1 %.2f / %.2f dB",
                     independent.left, independent.right, half.left, half.right, linked.left, linked.right))
        #expect(abs(independent.right) < 0.1, "unlinked, the quiet R must pass untouched (\(independent.right) dB)")
        #expect(abs(linked.left - linked.right) < 0.05, "fully linked, L and R must take one reduction")
        #expect(linked.right > 6.0, "fully linked, R must take L's reduction (\(linked.right) dB)")
        #expect(half.left - half.right > 1.0 && half.right > 1.0,
                "link 0.5 must give R part of L's reduction (L \(half.left) dB, R \(half.right) dB)")
    }

    @Test func shippedLinkDefaultsAreFullyLinked() {
        // Today's fully linked sound is kept by shipping 1.0 everywhere.
        #expect(AppConfig().multibandLinkStrength == 1.0)
        for preset in PresetCatalog.multibandPresets {
            #expect(preset.linkStrength == 1.0, "\(preset.id) ships link \(preset.linkStrength)")
        }
    }

    // MARK: - 1c. Band limiter hold follows each band's lower crossover

    @Test func bandLimiterHoldFollowsTheBandsLowerCrossover() {
        // Each classic band limiter's peak hold is one period of its band's
        // lower edge (the bottom band keeps the 50 Hz default). Until this
        // round every band held for one 50 Hz period (20 ms), so the treble
        // bands released 40 ms late.
        var cfg = fmConfig()
        cfg.multibandEnabled = true
        cfg.multibandMode = 5
        cfg.multibandLimiterEnabled = true
        let gen = makeProcessedAudioGenerator(cfg)
        // One period at 48 kHz, computed as `BandLimiter.configure` does.
        func expected(_ hz: Float) -> Int { Int(((1.0 / hz) * Float(48_000.0)).rounded(.up)) }
        let five = gen.multibandLimiterHoldSamples.five
        #expect(five == [expected(50), expected(90), expected(350), expected(1_800), expected(6_800)],
                "5-band holds \(five)")
        let three = gen.multibandLimiterHoldSamples.three
        #expect(three == [expected(50), expected(90), expected(350)], "3-band holds \(three)")

        // A live crossover edit re-designs the holds.
        var edited = cfg
        edited.multibandX2Hz = 500.0
        gen.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: edited))
        #expect(gen.multibandLimiterHoldSamples.five[2] == expected(500),
                "after X2 -> 500 Hz band 3 holds \(gen.multibandLimiterHoldSamples.five[2])")
    }

    // MARK: - 2. FIR splitter tap limit at the full MPX rate

    @Test func firSplitterLowestCrossoverKeepsItsTransitionAt192kHz() {
        // With the dual-rate boundary off the splitter runs at 192 kHz, where
        // the 90 Hz crossover's 120 Hz transition needs ~3,570 taps. Clamped
        // to 2049 the transition widened to ~209 Hz: band 1 still carried
        // 160 Hz at about -21 dB instead of being 40 dB down.
        var splitter = LinearPhaseMultibandSplitter5()
        let sr: Float = 192_000.0
        splitter.configure(x1Hz: 90, x2Hz: 350, x3Hz: 1_800, x4Hz: 6_800, sampleRate: sr)
        let taps = (2 * splitter.groupDelaySamples) + 1
        let frames = (2 * taps) + Int(sr * 0.1)
        let skip = 2 * taps
        var band1: [Float] = []
        band1.reserveCapacity(frames)
        for i in 0..<frames {
            let x = sinf(2.0 * Float.pi * 160.0 * Float(i) / sr)
            band1.append(splitter.process(left: x, right: x).0.0)
        }
        let db = toneDB(band1, frequency: 160.0, sampleRate: Double(sr), skip: skip)
        print(String(format: "192 kHz FIR splitter: %d taps, band 1 at 160 Hz %.1f dB", taps, db))
        #expect(taps > 2_049, "the 192 kHz design is still clamped at \(taps) taps")
        #expect(db < -38.0, "band 1 passes 160 Hz at \(db) dB; the 120 Hz transition should have it 40 dB down")

        // The 48 kHz audio domain design is unchanged (the clamp never bit there).
        var at48 = LinearPhaseMultibandSplitter5()
        at48.configure(x1Hz: 90, x2Hz: 350, x3Hz: 1_800, x4Hz: 6_800, sampleRate: 48_000)
        #expect(at48.groupDelaySamples == 446, "48 kHz group delay \(at48.groupDelaySamples)")
    }

    // MARK: - 6. setSampleRate re-derives the dual-rate factor

    private func mpxConfig(sampleRate: Double) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = blockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.dualRateAudioDomainEnabled = true
        cfg.dualRateAudioDomainRateHz = 48_000.0
        cfg.enRDS = false
        return cfg
    }

    private func renderMPX(_ gen: MPXGenerator, sampleRate sr: Double, seconds: Double) -> [Float] {
        let frames = Int(sr * seconds)
        var l = (0..<frames).map { i -> Float in
            let t = Double(i) / sr
            return Float(0.2 * sin(2.0 * .pi * 1_000.0 * t) + 0.1 * sin(2.0 * .pi * 14_000.0 * t))
        }
        var r = l.map { $0 * 0.5 }
        l.withUnsafeMutableBufferPointer { lBuf in
            r.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                while offset < frames {
                    let n = min(blockSize, frames - offset)
                    // swiftlint:disable force_unwrapping
                    gen.renderFromInputInPlace(
                        frameCount: n,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset))
                    // swiftlint:enable force_unwrapping
                    offset += n
                }
            }
        }
        return l
    }

    @Test func setSampleRateRederivesTheDualRateFactor() {
        // An engine built at 192 kHz (factor 4 to the 48 kHz audio domain)
        // and moved to 96 kHz must run factor 2, exactly like one built at
        // 96 kHz. `setSampleRate` kept factor 4: the audio domain ran at
        // 24 kHz on 48 kHz coefficients.
        let moved = MPXGenerator(config: mpxConfig(sampleRate: 192_000.0), sampleRate: 192_000.0)
        moved.setSampleRate(96_000.0)
        let fresh = MPXGenerator(config: mpxConfig(sampleRate: 96_000.0), sampleRate: 96_000.0)
        let a = renderMPX(moved, sampleRate: 96_000.0, seconds: 0.3)
        let b = renderMPX(fresh, sampleRate: 96_000.0, seconds: 0.3)
        var worst: Float = 0.0
        for i in Int(96_000.0 * 0.15)..<a.count { worst = max(worst, abs(a[i] - b[i])) }
        let tone14A = toneDB(a, frequency: 14_000.0, sampleRate: 96_000.0, skip: Int(96_000.0 * 0.15))
        let tone14B = toneDB(b, frequency: 14_000.0, sampleRate: 96_000.0, skip: Int(96_000.0 * 0.15))
        print(String(format: "setSampleRate 192k -> 96k vs fresh 96k: max |diff| %.2e, 14 kHz %.2f vs %.2f dB",
                     worst, tone14A, tone14B))
        #expect(worst < 1e-3, "moved engine differs from a fresh one by up to \(worst)")
        #expect(abs(tone14A - tone14B) < 0.1)
    }

    // MARK: - 7. Encoder FIR, 1 kHz processed-audio transition

    @Test(arguments: [48_000.0, 192_000.0])
    func encoderFIRWithTheOneKilohertzTransition(sampleRate sr: Double) {
        // Where the encoder FIR is the only band-limit (FM / HD / AM Output)
        // it is designed with a 1 kHz transition (`EncoderBandwidthTests`
        // covers the 1.5 kHz MPX-path default): flat to 14.9 kHz, -6 dB at
        // 15.4 kHz, 82 dB down from 15.9 kHz.
        var fir = LinearPhaseFIRLowpass()
        fir.configure(cutoffHz: 14_900.0, sampleRate: Float(sr), transitionHz: 1_000.0)
        func response(_ f: Double) -> Double {
            let frames = (2 * fir.tapCount) + Int(sr * 0.05)
            var y: [Float] = []
            y.reserveCapacity(frames)
            fir.reset()
            for i in 0..<frames {
                let x = Float(sin(2.0 * .pi * f * Double(i) / sr))
                y.append(fir.process(left: x, right: x).0)
            }
            return toneDB(y, frequency: f, sampleRate: sr, skip: 2 * fir.tapCount)
        }
        let ref = response(1_000.0)
        let at14 = response(14_000.0) - ref
        let at149 = response(14_900.0) - ref
        let at154 = response(15_400.0) - ref
        let at16 = response(16_000.0) - ref
        let at19 = response(19_000.0) - ref
        print(String(format: "encoder FIR 1 kHz transition @ %.0f Hz (%d taps): 14k %+.3f, 14.9k %+.3f, 15.4k %+.2f, 16k %.1f, 19k %.1f dB",
                     sr, fir.tapCount, at14, at149, at154, at16, at19))
        #expect(abs(at14) < 0.05 && abs(at149) < 0.1, "passband not flat to 14.9 kHz")
        #expect(abs(at154 + 6.0) < 1.0, "-6 dB point is not at 15.4 kHz (\(at154) dB)")
        #expect(at16 < -75.0, "16 kHz only \(at16) dB down")
        #expect(at19 < -78.0, "19 kHz (pilot) only \(at19) dB down")
    }

    @Test func processedAudioOutputUsesTheOneKilohertzTransition() {
        // Through the engine: FM Output at 48 kHz removes 16 kHz to below
        // -70 dB relative to the pre-emphasis curve. With the MPX path's
        // 1.5 kHz transition 16 kHz would sit in the transition band.
        let cfg = fmConfig()
        let curve = PreemphasisCurve.fm(tauUS: cfg.preemphasisUS)
        let rel = level(cfg, frequency: 16_000.0) - level(cfg, frequency: 1_000.0)
        let error = rel - (curve.analogGainDB(frequencyHz: 16_000.0) - curve.analogGainDB(frequencyHz: 1_000.0))
        print(String(format: "FM Output 16 kHz re curve: %.1f dB", error))
        #expect(error < -70.0, "16 kHz is only \(error) dB below the curve on FM Output")
    }
}
