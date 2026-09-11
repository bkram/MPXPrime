import Testing
import Foundation
@testable import MPXPrime

// Tests for the processed-audio output mode (`AudioOutputMode.processedAudio` /
// `MPXGenerator.setAudioOutputOnly`). In this mode the render path emits the
// post-pre-encode-limiter stereo L/R and skips ALL composite-domain work (stereo
// encode, composite clipper, BS.412, pilot/RDS injection). The invariants under
// test:
//   1. No subcarriers in the output — no 19 kHz pilot, no 38 kHz DSB-SC stereo
//      subcarrier, no 57 kHz RDS. The output is plain audio.
//   2. The output is true stereo L/R (NOT the mono composite written to both
//      channels), so L and R carry independent program.
//   3. The audio-domain program lowpass still applies (band-limited ~15 kHz).
//   4. The pre-encode true-peak limiter still controls peaks (no overs).
//   5. The config flag round-trips through the INI.
@Suite("Processed-audio output mode")
struct ProcessedAudioOutputTests {

    private let blockSize: Int = 512

    private func baseConfig(sampleRate: Double) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = blockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.operatingMode = .fm
        cfg.processingBypass = false
        cfg.preemphasisUS = 0                 // flat for clean spectral assertions
        cfg.mpxDeviationKHz = 75.0
        cfg.limitMPX = true
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.widebandAGCEnabled = false
        cfg.primeBassEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false
        cfg.enRDS = false
        cfg.encoderFIREnabled = true          // audio-domain 15 kHz FIR band-limit
        return cfg
    }

    /// Render a stereo program through the audio-only path. `gen` of L/R input is
    /// produced by the supplied closure. Returns the processed (left, right).
    private func renderAudioOnly(
        cfg: AppConfig,
        seconds: Double,
        sample: (_ i: Int, _ t: Double) -> (Float, Float)
    ) -> (left: [Float], right: [Float]) {
        let sr = cfg.sampleRate
        let gen = MPXGenerator(config: cfg, sampleRate: sr)
        gen.setAudioOutputOnly(true)
        // Mirror the engine start(): in processed-audio mode the audio-domain FIR
        // band-limit and multiband FIR crossovers both run (only the low-latency
        // monitor path keeps the IIR fallbacks).
        gen.setEncoderFIREnabled(cfg.encoderFIREnabled)
        gen.setMultibandFIREnabled(cfg.multibandFIREnabled)
        let total = Int(sr * seconds)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / sr
            let s = sample(i, t)
            left[i] = s.0
            right[i] = s.1
        }
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                let blocks = (total + blockSize - 1) / blockSize
                for _ in 0..<blocks {
                    let frames = min(blockSize, total - offset)
                    guard frames > 0 else { break }
                    gen.renderAudioOnlyFromInputInPlace(
                        frameCount: frames,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset))
                    offset += frames
                }
            }
        }
        return (left, right)
    }

    /// True-peak estimate in dBTP: 8x Kaiser-sinc interpolation (90 dB stopband,
    /// a sharper reconstruction than the guard's own 4x detector, so the test is
    /// not merely checking the guard against itself), max magnitude from `skip`.
    private func truePeakDBTP(_ left: [Float], _ right: [Float], sampleRate: Double, skip: Int) -> Double {
        var peak: Float = 0
        var os = [Float](repeating: 0, count: 8)
        for buf in [left, right] {
            var interp = LinearPhaseFIRInterpolator()
            interp.configure(cutoffHz: Float(sampleRate) * 0.45, sampleRateOS: Float(sampleRate) * 8,
                             interpolateFactor: 8, stopBandDB: 90.0, transitionHz: Float(sampleRate) * 0.06)
            let lead = interp.groupDelayInputSamples
            for (i, x) in buf.enumerated() {
                os.withUnsafeMutableBufferPointer { o in interp.push(x, into: o.baseAddress!) }
                if i - lead >= skip { for v in os { peak = max(peak, abs(v)) } }
            }
        }
        return 20.0 * log10(max(1e-9, Double(peak)))
    }

    /// Goertzel single-bin magnitude (linear amplitude).
    private func goertzel(_ buf: [Float], freqHz: Double, sampleRate: Double, startFrame: Int) -> Double {
        let span = buf.count - startFrame
        guard span > 1_024 else { return 0 }
        let k = (Double(span) * freqHz / sampleRate).rounded()
        let omega = 2.0 * .pi * k / Double(span)
        let cosw = cos(omega)
        let coeff = 2.0 * cosw
        var s1 = 0.0, s2 = 0.0
        for i in 0..<span {
            let s0 = coeff * s1 - s2 + Double(buf[startFrame + i])
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cosw
        let imag = s2 * sin(omega)
        return sqrt(real * real + imag * imag) / Double(span) * 2.0
    }

    // 1. No pilot / 38 kHz stereo subcarrier / 57 kHz RDS in the output. Rendered
    // at 192 kHz so all three frequencies are below Nyquist and measurable. A pure
    // SIDE input (L = -R) would, in composite mode, produce a 38 kHz DSB-SC pair
    // and a 19 kHz pilot — here there must be none.
    // 0. The generator seeds `audioOutputOnly` from `processed_audio_output`
    // at construction, so an engine that never calls setAudioOutputOnly (the
    // ALSA engine) still gets the identical audio-only chain -- before the
    // seed, Linux processed-audio ran with the dual-rate boundary wrongly on
    // (48 kHz coefficients at the output rate) and the optional final clipper
    // could never engage. Pinned as: config-seeded render (no setter calls at
    // all) is bit-identical to the engine-mirroring explicit path.
    @Test func configSeedMatchesExplicitSetAudioOutputOnly() {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        cfg.sourceMode = "input"
        cfg.processedAudioOutput = true
        cfg.processedAudioCoderHasClipper = false

        let sr = cfg.sampleRate
        let total = Int(sr * 0.5)
        let seeded = MPXGenerator(config: cfg, sampleRate: sr)
        var seededOut = [Float](repeating: 0, count: total)
        var seededRight = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / sr
            seededOut[i] = Float(0.6 * sin(2.0 * .pi * 1_000.0 * t))
            seededRight[i] = Float(0.4 * sin(2.0 * .pi * 5_000.0 * t))
        }
        seeded.renderAudioOnlyFromInputInPlace(
            frameCount: total, left: &seededOut, right: &seededRight)

        let explicit = renderAudioOnly(cfg: cfg, seconds: 0.5) { _, t in
            (Float(0.6 * sin(2.0 * .pi * 1_000.0 * t)),
             Float(0.4 * sin(2.0 * .pi * 5_000.0 * t)))
        }
        var mismatches = 0
        for i in 0..<total where seededOut[i] != explicit.left[i] || seededRight[i] != explicit.right[i] {
            mismatches += 1
            if mismatches > 4 { break }
        }
        #expect(mismatches == 0,
            "config-seeded audioOutputOnly renders differently from the explicit engine path")
    }

    @Test func processedAudioEmitsNoSubcarriers() {
        let sr = 192_000.0
        let cfg = baseConfig(sampleRate: sr)
        let f = 1_000.0
        let amp: Float = 0.3
        let out = renderAudioOnly(cfg: cfg, seconds: 1.0) { _, t in
            // Hard-left: carries both mid and side, so any erroneous stereo encode
            // would still produce a 19 kHz pilot + 38 kHz DSB-SC. (A pure-side L=-R
            // input would be pulled down by the stereo-image protection limiter and
            // is a poor program-presence probe.)
            let s = Float(Double(amp) * sin(2.0 * .pi * f * t))
            return (s, 0)
        }
        let skip = Int(sr * 0.2)
        // Audio tone is present on the left channel...
        let toneL = goertzel(out.left, freqHz: f, sampleRate: sr, startFrame: skip)
        #expect(toneL > 0.1, "expected the 1 kHz program tone in the output, got \(toneL)")
        // ...and there is essentially nothing at the subcarrier frequencies.
        for (name, freq) in [("pilot", 19_000.0), ("stereo-subcarrier", 38_000.0), ("rds", 57_000.0)] {
            let magL = goertzel(out.left, freqHz: freq, sampleRate: sr, startFrame: skip)
            let magR = goertzel(out.right, freqHz: freq, sampleRate: sr, startFrame: skip)
            #expect(magL < 1e-3, "unexpected \(name) energy in L: \(magL)")
            #expect(magR < 1e-3, "unexpected \(name) energy in R: \(magR)")
        }
        // Also check the 38 kHz +- 1 kHz sidebands a stereo encode would create.
        for freq in [37_000.0, 39_000.0] {
            let mag = goertzel(out.left, freqHz: freq, sampleRate: sr, startFrame: skip)
            #expect(mag < 1e-3, "unexpected DSB-SC sideband at \(freq) Hz: \(mag)")
        }
    }

    // 2. True stereo: independent tones on L and R survive as independent tones
    // (the output is NOT the mono composite copied to both channels).
    @Test func processedAudioPreservesStereo() {
        let sr = 96_000.0
        let cfg = baseConfig(sampleRate: sr)
        let fL = 1_000.0, fR = 3_000.0
        let amp: Float = 0.3
        let out = renderAudioOnly(cfg: cfg, seconds: 1.0) { _, t in
            (Float(Double(amp) * sin(2.0 * .pi * fL * t)),
             Float(Double(amp) * sin(2.0 * .pi * fR * t)))
        }
        let skip = Int(sr * 0.2)
        let lAtL = goertzel(out.left, freqHz: fL, sampleRate: sr, startFrame: skip)
        let lAtR = goertzel(out.left, freqHz: fR, sampleRate: sr, startFrame: skip)
        let rAtR = goertzel(out.right, freqHz: fR, sampleRate: sr, startFrame: skip)
        let rAtL = goertzel(out.right, freqHz: fL, sampleRate: sr, startFrame: skip)
        // Each channel is dominated by ITS OWN tone. If the path mono-summed (as
        // the composite path does, writing mpx to both channels), both channels
        // would contain both tones roughly equally.
        #expect(lAtL > 0.1, "left should carry its 1 kHz tone, got \(lAtL)")
        #expect(rAtR > 0.1, "right should carry its 3 kHz tone, got \(rAtR)")
        #expect(lAtR < lAtL * 0.1, "left leaked the right tone: \(lAtR) vs \(lAtL)")
        #expect(rAtL < rAtR * 0.1, "right leaked the left tone: \(rAtL) vs \(rAtR)")
    }

    // 3. Audio-domain program lowpass still applies: content well above 15 kHz is
    // strongly attenuated relative to a 1 kHz reference.
    @Test func processedAudioBandLimitsAboveFifteenK() {
        let sr = 96_000.0
        let cfg = baseConfig(sampleRate: sr)
        let amp: Float = 0.3
        let ref = renderAudioOnly(cfg: cfg, seconds: 0.6) { _, t in
            let s = Float(Double(amp) * sin(2.0 * .pi * 1_000.0 * t)); return (s, s)
        }
        let hi = renderAudioOnly(cfg: cfg, seconds: 0.6) { _, t in
            let s = Float(Double(amp) * sin(2.0 * .pi * 19_000.0 * t)); return (s, s)
        }
        let skip = Int(sr * 0.2)
        let refMag = goertzel(ref.left, freqHz: 1_000.0, sampleRate: sr, startFrame: skip)
        let hiMag = goertzel(hi.left, freqHz: 19_000.0, sampleRate: sr, startFrame: skip)
        #expect(refMag > 0.1, "1 kHz reference should pass, got \(refMag)")
        #expect(hiMag < refMag * 0.1, "19 kHz should be band-limited well below the 1 kHz reference: \(hiMag) vs \(refMag)")
    }

    // 3b. Every audio-domain stage runs at the processed-audio rate. Selecting
    // this mode turns the dual-rate boundary off AFTER the generator was built
    // with 48 kHz coefficients; until 0.45 only the encoder FIR and the
    // crossovers were reconfigured, so pre-emphasis (and the limiters) ran 48 kHz
    // coefficients at the output rate -- a 50 us curve became ~12.5 us, +2 dB at
    // 10 kHz instead of +10.3. Pin the curve at the output.
    @Test func processedAudioKeepsThePreemphasisCurve() {
        let sr = 96_000.0
        var cfg = baseConfig(sampleRate: sr)
        cfg.preemphasisUS = 50
        let amp: Float = 0.03   // far below the limiter threshold even after +10 dB of boost
        func level(_ f: Double) -> Double {
            let out = renderAudioOnly(cfg: cfg, seconds: 0.6) { _, t in
                let s = Float(Double(amp) * sin(2.0 * .pi * f * t)); return (s, s)
            }
            return 20.0 * log10(max(1e-12, goertzel(out.left, freqHz: f, sampleRate: sr, startFrame: Int(sr * 0.2))))
        }
        let boostDB = level(10_000.0) - level(1_000.0)
        func analog(_ f: Double) -> Double { 10.0 * log10(1.0 + pow(2.0 * .pi * f * 50e-6, 2)) }
        let expected = analog(10_000.0) - analog(1_000.0)
        #expect(abs(boostDB - expected) < 0.5,
                "processed-audio pre-emphasis boost 10 kHz re 1 kHz is \(boostDB) dB, expected \(expected)")
    }

    // 4. Pre-encode limiter still controls peaks AND the output is normalized to
    // full scale: a hot stereo program produces no output overs but reaches near
    // 0 dBFS (the limiter ceiling is mapped to full scale so the line feed to an
    // external coder is at a proper level, not the raw ~-1.4 dBFS ceiling).
    @Test func processedAudioNormalizesToFullScaleWithoutOvers() {
        let sr = 96_000.0
        var cfg = baseConfig(sampleRate: sr)
        cfg.preEncodeThreshold = 0.85
        cfg.outputGainDB = 0.0
        let amp: Float = 0.98
        let out = renderAudioOnly(cfg: cfg, seconds: 0.6) { _, t in
            let s = Float(Double(amp) * sin(2.0 * .pi * 1_000.0 * t)); return (s, s)
        }
        let skip = Int(sr * 0.2)
        var peak: Float = 0
        for i in skip..<out.left.count {
            peak = max(peak, abs(out.left[i]))
            peak = max(peak, abs(out.right[i]))
        }
        #expect(peak <= 1.0, "no output overs allowed, peak=\(peak)")
        #expect(peak >= 0.9, "hot program should reach near full scale (limiter ceiling normalized to 0 dBFS), peak=\(peak)")
    }

    // 5. Config flag round-trips through the INI.
    @Test func processedAudioOutputConfigRoundTrips() throws {
        #expect(AppConfig().processedAudioOutput == false, "default should be composite output")
        var cfg = AppConfig()
        cfg.processedAudioOutput = true
        let restored = try AppConfig.loadFromINIString(cfg.captureAsINIString())
        #expect(restored.processedAudioOutput == true)
        var cfg2 = AppConfig()
        cfg2.processedAudioOutput = false
        let restored2 = try AppConfig.loadFromINIString(cfg2.captureAsINIString())
        #expect(restored2.processedAudioOutput == false)
    }

    // 6. Optional final loudness clipper: when the external coder has NO clipper,
    // MPX Prime's final clipper drives the feed denser (higher RMS) while still
    // producing no output overs.
    @Test func processedAudioFinalClipAddsDensityWithoutOvers() {
        let sr = 96_000.0
        func renderRMSAndPeak(coderHasClipper: Bool) -> (rms: Float, peak: Float) {
            var cfg = baseConfig(sampleRate: sr)
            cfg.processedAudioCoderHasClipper = coderHasClipper
            cfg.processedAudioFinalClipDriveDB = 9.0
            cfg.outputGainDB = 0.0
            let out = renderAudioOnly(cfg: cfg, seconds: 0.6) { _, t in
                let s = Float(0.3 * sin(2.0 * .pi * 1_000.0 * t)); return (s, s)
            }
            let skip = Int(sr * 0.2)
            var sumSq = 0.0
            var peak: Float = 0
            for i in skip..<out.left.count {
                sumSq += Double(out.left[i]) * Double(out.left[i])
                peak = max(peak, abs(out.left[i]))
            }
            let rms = Float((sumSq / Double(out.left.count - skip)).squareRoot())
            return (rms, peak)
        }
        let off = renderRMSAndPeak(coderHasClipper: true)   // final clip off
        let on = renderRMSAndPeak(coderHasClipper: false)   // final clip on, +9 dB drive
        #expect(on.rms > off.rms * 1.1, "final clipper should make the feed denser: on=\(on.rms) off=\(off.rms)")
        #expect(on.peak <= 1.0, "final clipper output must not over: peak=\(on.peak)")
        #expect(off.peak <= 1.0, "clean output must not over: peak=\(off.peak)")
    }

    // 7. Final-clipper config round-trips and defaults to the safe "coder has a
    // clipper" (so MPX Prime adds no extra clipping by default).
    @Test func processedAudioFinalClipConfigRoundTrips() throws {
        #expect(AppConfig().processedAudioCoderHasClipper == true, "safe default: assume coder clips")
        var cfg = AppConfig()
        cfg.processedAudioCoderHasClipper = false
        cfg.processedAudioFinalClipDriveDB = 7.5
        let restored = try AppConfig.loadFromINIString(cfg.captureAsINIString())
        #expect(restored.processedAudioCoderHasClipper == false)
        #expect(abs(restored.processedAudioFinalClipDriveDB - 7.5) < 0.01)
    }

    // MARK: - Digital delivery target (0.50)
    //
    // `processed_audio_target = digital` aims the audio-only path at a stream or
    // a DAB+ / AAC encoder instead of an FM stereo coder. The FM-only stages
    // leave the path (band limit under the pilot, pre-emphasis, image
    // protection, the optional final clipper) and peaks are held at a true-peak
    // ceiling instead of being normalised to full scale. Every assertion below
    // has an FM-target counterpart above: BOTH must hold, one per target.

    private func digitalConfig(sampleRate: Double) -> AppConfig {
        var cfg = baseConfig(sampleRate: sampleRate)
        cfg.operatingMode = .hd
        cfg.programLowpassHz = 20_000.0
        return cfg
    }

    @Test func digitalTargetPassesAboveFifteenK() {
        // The FM counterpart (`processedAudioBandLimitsAboveFifteenK`) pins the
        // opposite for the same rate: this is the one behaviour the target flips.
        let sr = 96_000.0
        let cfg = digitalConfig(sampleRate: sr)
        let amp: Float = 0.3
        let skip = Int(sr * 0.2)
        let ref = renderAudioOnly(cfg: cfg, seconds: 0.6) { _, t in
            let s = Float(Double(amp) * sin(2.0 * .pi * 1_000.0 * t)); return (s, s)
        }
        let hi = renderAudioOnly(cfg: cfg, seconds: 0.6) { _, t in
            let s = Float(Double(amp) * sin(2.0 * .pi * 18_000.0 * t)); return (s, s)
        }
        let refMag = goertzel(ref.left, freqHz: 1_000.0, sampleRate: sr, startFrame: skip)
        let hiMag = goertzel(hi.left, freqHz: 18_000.0, sampleRate: sr, startFrame: skip)
        #expect(refMag > 0.1, "1 kHz reference should pass, got \(refMag)")
        #expect(hiMag > refMag * 0.5,
                "18 kHz must survive the digital target: \(hiMag) vs 1 kHz \(refMag), the 16 kHz FM cap must not apply here")
    }

    @Test func digitalTargetIsFlatWithNoPreemphasis() {
        // Pre-emphasis is FORCED off for the digital target even when the INI
        // still carries 50 us, because the curve is meaningless ahead of a codec
        // and would be applied twice if the operator switched targets.
        let sr = 96_000.0
        var cfg = digitalConfig(sampleRate: sr)
        cfg.preemphasisUS = 50
        let amp: Float = 0.03
        func level(_ f: Double) -> Double {
            let out = renderAudioOnly(cfg: cfg, seconds: 0.6) { _, t in
                let s = Float(Double(amp) * sin(2.0 * .pi * f * t)); return (s, s)
            }
            return 20.0 * log10(
                max(1e-12, goertzel(out.left, freqHz: f, sampleRate: sr, startFrame: Int(sr * 0.2))))
        }
        let boostDB = level(10_000.0) - level(1_000.0)
        #expect(abs(boostDB) < 0.5,
                "digital delivery must be flat, 10 kHz re 1 kHz read \(boostDB) dB")
    }

    @Test func digitalTargetHoldsTheTruePeakCeiling() {
        // The ceiling is a TRUE-peak claim, so measure it the way a codec sees
        // it: 4x oversampled through a linear interpolation of the output, not
        // the sample peak. The limiter's tanh knee is soft, hence the 0.3 dB
        // tolerance -- but it must never read ABOVE the ceiling.
        let sr = 96_000.0
        var cfg = digitalConfig(sampleRate: sr)
        cfg.processedAudioCeilingDBTP = -2.0
        cfg.inputGainDB = 12.0
        let out = renderAudioOnly(cfg: cfg, seconds: 0.8) { i, t in
            let burst: Double = (i / 4_096) % 2 == 0 ? 1.0 : 0.35
            let l = Float(burst * 0.9 * sin(2.0 * .pi * 700.0 * t))
            let r = Float(burst * 0.9 * sin(2.0 * .pi * 1_100.0 * t + 0.7))
            return (l, r)
        }
        let peakDB = truePeakDBTP(out.left, out.right, sampleRate: sr, skip: Int(sr * 0.25))
        #expect(peakDB < -2.0 + 0.05,
                "true peak \(peakDB) dBTP must not exceed the -2.0 dBTP ceiling")
        #expect(peakDB > -2.0 - 1.5,
                "true peak \(peakDB) dBTP is far under the ceiling; the make-up is not reaching it")
    }

    @Test func digitalTargetKeepsTheStereoImage() {
        // Image protection is an FM deviation / multipath guard. A digital
        // carrier has neither, so a hard-panned source must keep its side energy.
        let sr = 96_000.0
        var cfg = digitalConfig(sampleRate: sr)
        cfg.inputGainDB = 6.0
        func sideToMid(_ mode: AppConfig.OperatingMode) -> Double {
            var c = cfg
            c.operatingMode = mode
            let out = renderAudioOnly(cfg: c, seconds: 0.6) { _, t in
                (Float(0.7 * sin(2.0 * .pi * 900.0 * t)), 0.0)   // hard left
            }
            let skip = Int(sr * 0.2)
            var mid = 0.0, side = 0.0
            for i in skip..<out.left.count {
                let m = (Double(out.left[i]) + Double(out.right[i])) * 0.5
                let s = (Double(out.left[i]) - Double(out.right[i])) * 0.5
                mid += m * m
                side += s * s
            }
            return sqrt(side) / max(1e-9, sqrt(mid))
        }
        let digital = sideToMid(.hd)
        #expect(digital > 0.95,
                "hard-panned side/mid should stay near 1.0 on the digital target, got \(digital)")
    }

    @Test func digitalTargetNeverRunsTheFinalClipper() {
        // Clipping into a codec costs quality, so the FM-coder escape hatch
        // ("the coder has no clipper of its own") is inert for digital.
        let sr = 96_000.0
        var cfg = digitalConfig(sampleRate: sr)
        cfg.inputGainDB = 10.0
        var clipperRequested = cfg
        clipperRequested.processedAudioCoderHasClipper = false
        func render(_ c: AppConfig) -> [Float] {
            renderAudioOnly(cfg: c, seconds: 0.4) { _, t in
                let s = Float(0.8 * sin(2.0 * .pi * 500.0 * t)); return (s, s)
            }.left
        }
        let a = render(cfg)
        let b = render(clipperRequested)
        #expect(a.count == b.count)
        let firstDiff = (0..<min(a.count, b.count)).first { a[$0] != b[$0] }
        #expect(firstDiff == nil,
                "the coder-has-clipper flag changed the digital output at frame \(firstDiff ?? -1)")
    }

    @Test func digitalTargetConfigRoundTripsAndDefaultsToMPX() {
        var cfg = AppConfig()
        #expect(cfg.operatingMode == .mpx, "default mode must not change existing installs")
        #expect(cfg.processedAudioDigitalDelivery == false)
        cfg.operatingMode = .hd
        cfg.processedAudioCeilingDBTP = -2.0
        #expect(cfg.processedAudioDigitalDelivery == true)
        let restored = try? AppConfig.loadFromINIString(cfg.captureAsINIString())
        #expect(restored?.operatingMode == .hd)
        #expect(abs((restored?.processedAudioCeilingDBTP ?? 0) - (-2.0)) < 0.01)
        #expect(restored?.processedAudioDigitalDelivery == true)
        // An unknown mode word falls back to MPX rather than silently
        // dropping the composite.
        let bogus = try? AppConfig.loadFromINIString(
            cfg.captureAsINIString().replacingOccurrences(
                of: "operating_mode = hd", with: "operating_mode = hd-radio"))
        #expect(bogus?.operatingMode == .mpx)
    }

    @Test func digitalTargetFrequencyResponseIsFlatAcrossTheAudioBand() {
        // The point of the target: what a codec receives is the program, not
        // an FM-shaped version of it. Tolerances come from the measured table
        // (2026-09-05, stage isolation): with the pre-encode limiter off the
        // path is flat within 0.05 dB to 18 kHz at both rates; every deviation
        // below is the limiter's one-sided Lagrange-4 interpolator (points at
        // -2..+1 host samples, evaluated between the last two), whose
        // polyphase response is +0.32 dB at fs/4 and -0.41 dB at 3fs/8 --
        // reproduced analytically to 0.02 dB. It is a property of the
        // limiter, shared with the FM chain at its 48 kHz audio domain, and is
        // recorded in the roadmap as a chain-review item because fixing it
        // moves every composite baseline. The 48 kHz case is the production
        // audio rate operators get; 96 kHz is the rate the rest of this suite
        // renders at (the ripple sits at half the normalised frequency there).
        struct Row { let hz: Double; let tol48: Double; let tol96: Double }
        let rows = [Row(hz: 100, tol48: 0.15, tol96: 0.15), Row(hz: 300, tol48: 0.1, tol96: 0.1),
                    Row(hz: 3_000, tol48: 0.1, tol96: 0.1), Row(hz: 8_000, tol48: 0.25, tol96: 0.15),
                    Row(hz: 12_000, tol48: 0.45, tol96: 0.2), Row(hz: 15_000, tol48: 0.35, tol96: 0.2),
                    Row(hz: 17_000, tol48: 0.3, tol96: 0.3), Row(hz: 18_000, tol48: 0.6, tol96: 0.8)]
        for sr in [48_000.0, 96_000.0] {
            let cfg = digitalConfig(sampleRate: sr)
            let amp: Float = 0.05
            let skip = Int(sr * 0.2)
            func level(_ f: Double) -> Double {
                let out = renderAudioOnly(cfg: cfg, seconds: 0.5) { _, t in
                    let s = Float(Double(amp) * sin(2.0 * .pi * f * t)); return (s, s)
                }
                return 20.0 * log10(max(1e-12, goertzel(out.left, freqHz: f, sampleRate: sr, startFrame: skip)))
            }
            let reference = level(1_000.0)
            let table = rows.map { row in (row, level(row.hz) - reference) }
            let report = table.map { String(format: "%.0f Hz: %+.2f dB", $0.0.hz, $0.1) }.joined(separator: ", ")
            for (row, delta) in table {
                let tol = sr < 60_000 ? row.tol48 : row.tol96
                #expect(abs(delta) < tol,
                        "digital response at \(Int(sr)) Hz rate, \(Int(row.hz)) Hz off by \(delta) dB re 1 kHz -- \(report)")
            }
        }
    }

    @Test func digitalTargetTruePeakHoldsOnAdversarialProgram() {
        // The ceiling has to hold on the material that breaks true-peak
        // limiters: dense bright multitone, hard-panned HF, and clicks -- not
        // just the tidy burst the basic ceiling test uses. Same 4x linear
        // interpolation estimate; the make-up's 0.4 dB margin is what keeps
        // this under the line.
        let sr = 96_000.0
        var cfg = digitalConfig(sampleRate: sr)
        cfg.processedAudioCeilingDBTP = -1.0
        cfg.inputGainDB = 14.0
        let programs: [(String, (Int, Double) -> (Float, Float))] = [
            ("bright dense", { _, t in
                var l = 0.0, r = 0.0
                for (k, f) in [220.0, 1_330.0, 4_010.0, 7_900.0, 11_700.0, 14_300.0].enumerated() {
                    l += 0.22 * sin(2.0 * .pi * f * t + Double(k))
                    r += 0.22 * sin(2.0 * .pi * (f * 1.013) * t - Double(k))
                }
                return (Float(l), Float(r))
            }),
            ("hard-panned HF", { _, t in
                (Float(0.9 * sin(2.0 * .pi * 9_800.0 * t) * (0.6 + 0.4 * sin(2.0 * .pi * 3.0 * t))), 0.0)
            }),
            ("clicks", { i, t in
                let click: Double = (i % 4_800) < 3 ? 0.95 : 0.0
                let bed = 0.3 * sin(2.0 * .pi * 440.0 * t)
                return (Float(bed + click), Float(bed - click))
            }),
        ]
        let skip = Int(sr * 0.25)
        var report: [String] = []
        var peaks: [(String, Double)] = []
        for (name, program) in programs {
            let out = renderAudioOnly(cfg: cfg, seconds: 0.8, sample: program)
            let peakDB = truePeakDBTP(out.left, out.right, sampleRate: sr, skip: skip)
            peaks.append((name, peakDB))
            report.append(String(format: "%@ %.2f dBTP", name, peakDB))
        }
        let summary = report.joined(separator: ", ")
        for (name, peakDB) in peaks {
            #expect(peakDB < -1.0 + 0.05, "\(name) exceeds the -1.0 dBTP ceiling -- \(summary)")
            #expect(peakDB > -1.0 - 1.5, "\(name) sits far under the ceiling -- \(summary)")
        }
    }

    @Test func digitalTargetCannotAffectTheCompositePath() {
        // The whole feature is gated on `processedAudioDigitalDelivery`, which is
        // false unless processed-audio output is on. A composite config carrying
        // the digital target must render identically to one without it.
        var composite = baseConfig(sampleRate: 192_000.0)
        composite.operatingMode = .mpx
        composite.preemphasisUS = 50
        var tagged = composite
        tagged.processedAudioCeilingDBTP = -3.0     // an HD-only key on an MPX config
        #expect(tagged.processedAudioDigitalDelivery == false)
        func renderComposite(_ c: AppConfig) -> [Float] {
            let gen = MPXGenerator(config: c, sampleRate: c.sampleRate)
            var out = [Float](repeating: 0, count: 8_192)
            for i in 0..<out.count {
                let t = Double(i) / c.sampleRate
                let l = Float(0.4 * sin(2.0 * .pi * 1_000.0 * t))
                let r = Float(0.3 * sin(2.0 * .pi * 1_400.0 * t))
                out[i] = gen.renderSingleSample(leftIn: l, rightIn: r)
            }
            return out
        }
        let a = renderComposite(composite)
        let b = renderComposite(tagged)
        let firstDiff = (0..<min(a.count, b.count)).first { a[$0] != b[$0] }
        #expect(firstDiff == nil,
                "the digital target leaked into the composite path at frame \(firstDiff ?? -1)")
    }
}
