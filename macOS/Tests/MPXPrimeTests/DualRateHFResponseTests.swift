import Testing
import Foundation
@testable import MPXPrime

// Diagnostic test for HF amplitude regression reported after 0.30
// shipped. Measures the AUDIO-BAND frequency response of the full
// chain with the dual-rate boundary off vs on, exposing any HF
// amplitude difference caused by audio-domain stages running at
// 48 kHz instead of 192 kHz (pilot notch warping, pre-emphasis
// bilinear shelf approaching audio-rate Nyquist, etc.).
//
// Strategy: feed L=R=sin(2π·f·t) into the chain at 192 kHz, render,
// then measure the in-band amplitude at f in the MPX output via
// Goertzel. The audio-band content (0-15 kHz) sits below the pilot
// (19 kHz) and the upper stereo subcarrier (53 kHz) in the composite,
// so a Goertzel at f directly reads the audio path's HF response.
//
// We expect at least a few tenths of a dB difference (any audio chain
// resampled to a different rate has SOME response delta). The point of
// the test is to QUANTIFY it — if 14-19 kHz is losing 1+ dB vs the
// pre-cutover chain, that's the smoking gun for the user-reported
// "lost a lot of high frequencies" regression.
//
// Run with:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     MPXPRIME_HF_RESPONSE=1 swift test -c release \
//     --package-path macOS --filter DualRateHFResponse
//
// Output: markdown table to stdout listing per-frequency dB delta of
// boundary-on vs boundary-off.

@Suite("Dual-rate HF response diagnostic")
struct DualRateHFResponseTests {

    private let sampleRate: Double = 192_000.0
    private let blockSize: Int = 512
    // 2 s of audio per frequency — long enough for the chain to settle
    // and Goertzel to converge cleanly.
    private let secondsPerFreq: Double = 2.0

    // Sweep frequencies that exercise the audio-band response. 1 kHz is
    // a reference; 14-18 kHz is where pre-emphasis warping + pilot
    // notch effects show up most.
    private static let testFrequencies: [Double] = [
        1_000, 2_000, 4_000, 6_000, 8_000, 10_000,
        12_000, 13_000, 14_000, 15_000, 16_000, 17_000, 18_000
    ]

    private func baseConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = blockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.processingBypass = false
        cfg.preemphasisUS = 50
        cfg.mpxDeviationKHz = 75.0
        cfg.limitMPX = true
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.widebandAGCEnabled = false        // disable AGC so it doesn't slew on a steady tone
        cfg.primeBassEnabled = false
        cfg.stereoWidenEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandEnabled = false          // disable multiband so the response is unshaped
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false   // disable clipper so it doesn't shape HF
        cfg.compositeMultibandClipperEnabled = false
        cfg.enRDS = false                     // disable RDS so 57 kHz region is clean
        cfg.rdsLevel = 0.0
        cfg.pilotLevel = 0.0                  // disable pilot too — its notch will warp at 48 kHz
        return cfg
    }

    private func renderToneToMPX(frequency: Double, dualRateOn: Bool, encoderFIR: Bool) -> [Float] {
        var cfg = baseConfig()
        cfg.dualRateAudioDomainEnabled = dualRateOn
        cfg.dualRateAudioDomainRateHz = 48_000.0
        cfg.encoderFIREnabled = encoderFIR

        let gen = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        // AudioOutputEngine calls setEncoderFIREnabled(true) at start;
        // mirror that here so the FIR path actually runs in the test.
        gen.setEncoderFIREnabled(encoderFIR)
        let totalFrames = Int(sampleRate * secondsPerFreq)
        var left = [Float](repeating: 0, count: totalFrames)
        var right = [Float](repeating: 0, count: totalFrames)
        let amp: Float = 0.5
        let sr = sampleRate
        for i in 0..<totalFrames {
            let t = Double(i) / sr
            let s = Float(Double(amp) * sin(2.0 * .pi * frequency * t))
            left[i] = s
            right[i] = s
        }

        // Render in blockSize chunks; output goes back into the L array
        // (output is mono MPX — L and R receive identical mpx).
        let blocks = (totalFrames + blockSize - 1) / blockSize
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                for _ in 0..<blocks {
                    let remain = totalFrames - offset
                    let frames = min(blockSize, remain)
                    guard frames > 0 else { break }
                    gen.renderFromInputInPlace(
                        frameCount: frames,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    offset += frames
                }
            }
        }
        return left
    }

    /// Goertzel single-bin magnitude (linear amplitude).
    private func goertzelMagnitude(buf: [Float], freqHz: Double, sampleRate: Double, startFrame: Int) -> Double {
        let span = buf.count - startFrame
        guard span > 1_024 else { return 0 }
        let k = (Double(span) * freqHz / sampleRate).rounded()
        let omega = 2.0 * .pi * k / Double(span)
        let cosw = cos(omega)
        let coeff = 2.0 * cosw
        var s1: Double = 0
        var s2: Double = 0
        for i in 0..<span {
            let x = Double(buf[startFrame + i])
            let s0 = coeff * s1 - s2 + x
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cosw
        let imag = s2 * sin(omega)
        return sqrt(real * real + imag * imag) / Double(span) * 2.0
    }

    // MARK: - Regression guard (runs on every `swift test`)

    /// Catches the pre-0.30.1 regression where a stage configured for
    /// MPX rate but called at audio rate effectively divides its cutoff
    /// by L, brick-walling at the wrong frequency. Specifically the
    /// `setEncoderFIREnabled` + `setSampleRate` paths were reconfiguring
    /// encoder LP/FIR (and several other audio-domain stages) at
    /// `self.sampleRate` instead of `audioDomainSampleRate`, which
    /// destroyed the production chain's HF above ~4 kHz when the
    /// dual-rate boundary was on. With the fix in place, the dual-rate-
    /// on chain matches the dual-rate-off chain to within a small
    /// tolerance across the audio passband.
    ///
    /// If this test fails, an audio-domain stage is being configured at
    /// the wrong sample rate when the boundary is on. Audit any recent
    /// `.configure(sampleRate:)` call against `audioDomainSampleRate`.
    @Test func dualRateOnMatchesOffInAudioPassbandWithProductionFIR() {
        // Test frequencies safely inside the FIR's 14.9 kHz cutoff so
        // we're measuring the audio-domain chain's response, not the
        // encoder LP's natural rolloff.
        let passbandFrequencies: [Double] = [1_000, 2_000, 4_000, 8_000, 10_000, 12_000]
        // The boundary itself + bilinear warping at the lower rate add
        // sub-dB response variation. 0.5 dB is generous for the
        // passband.
        let passbandToleranceDB: Double = 0.5

        for f in passbandFrequencies {
            let mpxOff = renderToneToMPX(frequency: f, dualRateOn: false, encoderFIR: true)
            let mpxOn  = renderToneToMPX(frequency: f, dualRateOn: true,  encoderFIR: true)
            let skip = Int(0.5 * sampleRate)
            let magOff = goertzelMagnitude(buf: mpxOff, freqHz: f, sampleRate: sampleRate, startFrame: skip)
            let magOn  = goertzelMagnitude(buf: mpxOn,  freqHz: f, sampleRate: sampleRate, startFrame: skip)
            let dbOff = 20.0 * log10(max(1e-12, magOff))
            let dbOn  = 20.0 * log10(max(1e-12, magOn))
            let delta = dbOn - dbOff
            #expect(abs(delta) < passbandToleranceDB,
                    "HF response delta at \(Int(f)) Hz is \(String(format: "%.2f", delta)) dB (boundary off \(String(format: "%.2f", dbOff)) dBFS, on \(String(format: "%.2f", dbOn)) dBFS). Tolerance ±\(passbandToleranceDB) dB. Likely an audio-domain stage is configured at the wrong sample rate when the dual-rate boundary is on — audit recent .configure(sampleRate:) calls and confirm they use audioDomainSampleRate, not self.sampleRate.")
        }
    }

    /// Transition-region tolerance — 13-15 kHz sits just inside / against
    /// the encoder LP's 14.9 kHz compliance cutoff, so a wider tolerance
    /// is allowed here. Still catches catastrophic regressions (10+ dB
    /// loss) without flagging the small bilinear-warping differences
    /// inherent to running a steep filter at a lower rate.
    @Test func dualRateOnMatchesOffNearEncoderCutoff() {
        let frequencies: [Double] = [13_000, 14_000, 15_000]
        let toleranceDB: Double = 2.5
        for f in frequencies {
            let mpxOff = renderToneToMPX(frequency: f, dualRateOn: false, encoderFIR: true)
            let mpxOn  = renderToneToMPX(frequency: f, dualRateOn: true,  encoderFIR: true)
            let skip = Int(0.5 * sampleRate)
            let magOff = goertzelMagnitude(buf: mpxOff, freqHz: f, sampleRate: sampleRate, startFrame: skip)
            let magOn  = goertzelMagnitude(buf: mpxOn,  freqHz: f, sampleRate: sampleRate, startFrame: skip)
            let dbOff = 20.0 * log10(max(1e-12, magOff))
            let dbOn  = 20.0 * log10(max(1e-12, magOn))
            let delta = dbOn - dbOff
            #expect(abs(delta) < toleranceDB,
                    "Near-cutoff response delta at \(Int(f)) Hz is \(String(format: "%.2f", delta)) dB (off \(String(format: "%.2f", dbOff)), on \(String(format: "%.2f", dbOn))). Tolerance ±\(toleranceDB) dB.")
        }
    }

    // MARK: - Full sweep markdown report (env-gated)

    @Test func measureHFResponseDeltaIfRequested() {
        guard ProcessInfo.processInfo.environment["MPXPRIME_HF_RESPONSE"] != nil else {
            return
        }

        var lines: [String] = []
        lines.append("# Dual-rate HF amplitude response (audio chain, full chain @ 192 kHz)")
        lines.append("")
        lines.append("Captured: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("Test: L=R sine at frequency f, amplitude 0.5; measure Goertzel magnitude at f in MPX output (audio-band content sits below pilot/subcarriers when those are off).")
        lines.append("")
        lines.append("AGC / multiband / clippers / pilot / RDS disabled so the only stages active are: input gain, pre-emphasis, pre-encode limiter, stereo encode, composite-bandwidth FIR, final-MPX safety limiter. The dual-rate boundary still toggles those stages between MPX-rate and audio-rate processing.")
        lines.append("")
        // Two paths: production (encoder FIR linear-phase, sample-rate-
        // invariant magnitude response) and legacy (12th-order Butterworth
        // cascade, bilinear-warped near Nyquist at audio rate).
        for fir in [true, false] {
            let pathName = fir ? "Encoder FIR ENABLED (production / TX default)" : "Encoder FIR disabled (legacy Butterworth)"
            lines.append("")
            lines.append("## \(pathName)")
            lines.append("")
            lines.append("| Freq (Hz) | OFF (dBFS) | ON  (dBFS) | Δ ON-OFF (dB) |")
            lines.append("| --------: | ---------: | ---------: | ------------: |")
            for f in Self.testFrequencies {
                let mpxOff = renderToneToMPX(frequency: f, dualRateOn: false, encoderFIR: fir)
                let mpxOn  = renderToneToMPX(frequency: f, dualRateOn: true,  encoderFIR: fir)
                let skip = Int(0.5 * sampleRate)
                let magOff = goertzelMagnitude(buf: mpxOff, freqHz: f, sampleRate: sampleRate, startFrame: skip)
                let magOn  = goertzelMagnitude(buf: mpxOn,  freqHz: f, sampleRate: sampleRate, startFrame: skip)
                let dbOff = 20.0 * log10(max(1e-12, magOff))
                let dbOn  = 20.0 * log10(max(1e-12, magOn))
                let delta = dbOn - dbOff
                lines.append(String(
                    format: "| %9.0f | %10.2f | %10.2f | %13.2f |",
                    f, dbOff, dbOn, delta
                ))
            }
        }

        lines.append("")
        lines.append("Negative Δ values = boundary-on chain produces LESS amplitude at that frequency than boundary-off (HF loss the user is hearing).")
        print(lines.joined(separator: "\n"))
    }
}
