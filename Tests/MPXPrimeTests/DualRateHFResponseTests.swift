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
//     --filter DualRateHFResponse
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
        cfg.advancedDynamicsEnabled = false  // AD is the default levelling since 2026-10-15
        cfg.primeBassEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandEnabled = false          // disable multiband so the response is unshaped
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false   // disable clipper so it doesn't shape HF
        cfg.enRDS = false                     // disable RDS so 57 kHz region is clean
        cfg.rdsLevel = 0.0
        cfg.pilotLevel = 0.0                  // disable pilot too — its notch will warp at 48 kHz
        return cfg
    }

    private func renderToneToMPX(frequency: Double, dualRateOn: Bool, encoderFIR: Bool,
                                 amplitude amp: Float = 0.5) -> [Float] {
        renderToneMeasuringGR(frequency: frequency, dualRateOn: dualRateOn, encoderFIR: encoderFIR,
                              amplitude: amp).mpx
    }

    /// Same render, also returning the largest pre-encode and final-limiter
    /// gain reduction seen after `measureFrom` (the Goertzel window): a
    /// response comparison is only a response comparison while neither
    /// limiter is pinning the output (test-suite review 2026-10
    /// finding 5: at amplitude 0.5 both paths sat at the same 0.959 ceiling
    /// from 4 kHz up, so the on/off delta compared two limited peaks).
    private func renderToneMeasuringGR(frequency: Double, dualRateOn: Bool, encoderFIR: Bool,
                                       amplitude amp: Float,
                                       measureFrom: Int = 0) -> (mpx: [Float], maxGRDB: Float) {
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
        var maxGR: Float = 0.0
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
                    if offset > measureFrom {
                        let status = gen.finalLimiterStatus
                        maxGR = max(maxGR, status.preEncodeGainReductionDB, status.safetyGainReductionDB)
                    }
                }
            }
        }
        return (left, maxGR)
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
        // 12 kHz moved to `dualRateOnMatchesOffNearEncoderCutoff`: measured
        // below the limiters it reads +0.50 dB on/off (2026-10-15), part of
        // the same boundary-off HF deficit that test is blocked on.
        let passbandFrequencies: [Double] = [1_000, 2_000, 4_000, 8_000, 10_000]
        // The boundary itself + bilinear warping at the lower rate add
        // sub-dB response variation. 0.5 dB is generous for the
        // passband.
        let passbandToleranceDB: Double = 0.5

        for f in passbandFrequencies {
            // Amplitude 0.05 (as productionChainFollowsTheAnalogPreemphasisCurve):
            // below every limiter even with the 12 kHz pre-emphasis boost.
            let skip = Int(0.5 * sampleRate)
            let off = renderToneMeasuringGR(frequency: f, dualRateOn: false, encoderFIR: true,
                                            amplitude: 0.05, measureFrom: skip)
            let on = renderToneMeasuringGR(frequency: f, dualRateOn: true, encoderFIR: true,
                                           amplitude: 0.05, measureFrom: skip)
            #expect(off.maxGRDB == 0.0 && on.maxGRDB == 0.0,
                    "a limiter acted inside the measurement window at \(Int(f)) Hz (off \(off.maxGRDB) dB, on \(on.maxGRDB) dB): the comparison would be of limited peaks")
            let mpxOff = off.mpx
            let mpxOn = on.mpx
            let magOff = goertzelMagnitude(buf: mpxOff, freqHz: f, sampleRate: sampleRate, startFrame: skip)
            let magOn  = goertzelMagnitude(buf: mpxOn,  freqHz: f, sampleRate: sampleRate, startFrame: skip)
            let dbOff = 20.0 * log10(max(1e-12, magOff))
            let dbOn  = 20.0 * log10(max(1e-12, magOn))
            let delta = dbOn - dbOff
            #expect(abs(delta) < passbandToleranceDB,
                    "HF response delta at \(Int(f)) Hz is \(String(format: "%.2f", delta)) dB (boundary off \(String(format: "%.2f", dbOff)) dBFS, on \(String(format: "%.2f", dbOn)) dBFS). Tolerance ±\(passbandToleranceDB) dB. Likely an audio-domain stage is configured at the wrong sample rate when the dual-rate boundary is on — audit recent .configure(sampleRate:) calls and confirm they use audioDomainSampleRate, not self.sampleRate.")
        }
    }

    /// The production chain's receiver-side frequency response (metric P2 of
    /// the 0.45 chain review): with pre-emphasis on, the composite level at f
    /// relative to 1 kHz must follow the ANALOG pre-emphasis curve to
    /// +/-0.5 dB up to 14 kHz (the Omnia.11 spec figure; a receiver
    /// de-emphasises with the analog network). Tone amplitude is kept low so
    /// the pre-encode limiter never engages. Before 0.45 this read -3.5 dB at
    /// 14 kHz: the limiter's 6th-order Butterworth decimator at 14.4 kHz plus
    /// the matched-z pre-emphasis error, both artefacts of the 48 kHz audio
    /// domain that `dualRateOnMatchesOffNearEncoderCutoff` tolerated at 2.5 dB.
    @Test func productionChainFollowsTheAnalogPreemphasisCurve() {
        let tau = 50e-6
        func analogDB(_ f: Double) -> Double {
            let wt = 2.0 * .pi * f * tau
            return 10.0 * log10(1.0 + wt * wt)
        }
        func levelDB(_ f: Double) -> Double {
            let mpx = renderToneToMPX(frequency: f, dualRateOn: true, encoderFIR: true, amplitude: 0.05)
            let skip = Int(0.5 * sampleRate)
            return 20.0 * log10(max(1e-12, goertzelMagnitude(buf: mpx, freqHz: f, sampleRate: sampleRate, startFrame: skip)))
        }
        let reference = levelDB(1_000.0)
        for f in [2_000.0, 5_000.0, 8_000.0, 10_000.0, 12_000.0, 13_000.0, 14_000.0] {
            let measuredRel = levelDB(f) - reference
            let expectedRel = analogDB(f) - analogDB(1_000.0)
            let error = measuredRel - expectedRel
            #expect(abs(error) < 0.5,
                    "production chain at \(Int(f)) Hz is \(String(format: "%+.2f", error)) dB off the analog pre-emphasis curve (measured \(String(format: "%+.2f", measuredRel)) dB re 1 kHz, expected \(String(format: "%+.2f", expectedRel)))")
        }
    }

    /// Transition-region check -- 13-15 kHz sits just inside / against the
    /// encoder LP's 14.9 kHz compliance cutoff. Since 0.45 both rates use the
    /// same linear-phase FIR decimator and the analog-fitted pre-emphasis, so
    /// the on/off difference is a fraction of a dB (it was 2.5 dB before).
    ///
    /// Measured below the limiters (amplitude 0.05, 2026-10-15) the boundary-
    /// OFF path reads 1.04 dB under the boundary-on path at 14 kHz and 0.50 dB
    /// at 12 kHz; against the analogue pre-emphasis curve the off path is
    /// 1.24 dB low at 14 kHz and the on path 0.2 dB. At amplitude 0.5 both
    /// renders sat at the same limiter ceiling and the test passed by
    /// comparing two limited peaks (test-suite review 2026-10
    /// finding 5). The off path is the full-rate audio domain that the
    /// processed-audio modes (fm / hd / am) use at the output device rate.
    /// Root cause (2026-10-16, re-measured: 0.77 dB at 14 kHz on this tree):
    /// the 6th-order Butterworth program lowpass at 15.3 kHz is bilinear, so
    /// its droop depends on the rate it is designed at -- -0.47 dB at 14 kHz
    /// on the 48 kHz domain, -1.24 dB at 192 kHz. The full-rate composite now
    /// runs the 48 kHz design as H(z^4) (`StridedProgramLowpass`), identical
    /// below 24 kHz; the processed-audio modes drop it and keep the encoder
    /// FIR alone (`OutputResponseTests`).
    @Test func dualRateOnMatchesOffNearEncoderCutoff() {
        let frequencies: [Double] = [12_000, 13_000, 14_000, 15_000]
        // Both paths now run the same program-lowpass response; measured
        // on/off delta <= 0.001 dB at 10-15 kHz (2026-10-16), against 0.77 dB
        // at 14 kHz before -- which the old 1.0 dB tolerance let through.
        let toleranceDB: Double = 0.3
        for f in frequencies {
            let skip = Int(0.5 * sampleRate)
            let off = renderToneMeasuringGR(frequency: f, dualRateOn: false, encoderFIR: true,
                                            amplitude: 0.05, measureFrom: skip)
            let on = renderToneMeasuringGR(frequency: f, dualRateOn: true, encoderFIR: true,
                                           amplitude: 0.05, measureFrom: skip)
            #expect(off.maxGRDB == 0.0 && on.maxGRDB == 0.0,
                    "a limiter acted inside the measurement window at \(Int(f)) Hz (off \(off.maxGRDB) dB, on \(on.maxGRDB) dB)")
            let mpxOff = off.mpx
            let mpxOn = on.mpx
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

    // Opt-in report. `.enabled(if:)` instead of an early return, so a
    // default run lists it as skipped rather than counting an empty pass.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MPXPRIME_HF_RESPONSE"] != nil))
    func measureHFResponseDeltaIfRequested() {

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
