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
        cfg.processedAudioOutput = true
        cfg.processingBypass = false
        cfg.preemphasisUS = 0                 // flat for clean spectral assertions
        cfg.mpxDeviationKHz = 75.0
        cfg.limitMPX = true
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.widebandAGCEnabled = false
        cfg.primeBassEnabled = false
        cfg.stereoWidenEnabled = false
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
}
