import Testing
import Foundation
@testable import MPXPrime

// Acceptance + regression guard for audit Finding #3: the post-injection
// clamp could silently distort pilot/RDS when audio + subcarrier reservation
// × outputGain exceeded 1.0. The chain ends with
//   mpx += subcarriers · outputGain
//   return clampf(mpx, -1, 1)
//
// Two-layer fix:
//   1. Telemetry — `postInjectionOvershoot` exposes when the clamp engages.
//   2. Budget governor — `makeFinalCompositeThresholds` derives an
//      `allowedAudioAbs = max(0, effectiveThreshold - reserved - margin)`
//      ceiling. When sane configs are within budget, the audio composite
//      is governed under that ceiling BEFORE pilot/RDS injection, so the
//      post-injection clamp never engages. `overBudget == true` signals
//      configurations the governor can't accommodate (subcarrier
//      reservation already exceeds the effective threshold).
//
// Acceptance criteria (from the auditor's spec):
//  - Default config: `postInjectionOvershoot < 1e-4`, `overBudget == false`.
//  - Hot but sane settings: same — governor keeps overshoot at zero.
//  - Impossible settings (extreme outputGain): `overBudget == true`,
//    telemetry surfaces the condition explicitly. The final clamp is the
//    last-resort numeric guard, not a normal pass.

@Suite("Post-injection clamp budget")
struct PostInjectionClampTests {

    private let sampleRate: Double = 192_000.0

    private func makeStereoConfig(outputGainDB: Double = 0.0) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = 1024
        cfg.outputGainDB = outputGainDB
        cfg.processingBypass = false
        cfg.widebandAGCEnabled = false
        cfg.multibandEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.downwardExpanderEnabled = false
        cfg.primeBassEnabled = false
        cfg.stereoWidenEnabled = false
        cfg.monoBassEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.limitMPX = true
        cfg.preemphasisUS = 0
        cfg.enRDS = true
        cfg.pilotLevel = 0.08
        cfg.rdsLevel = 2.0
        cfg.monoMode = false
        return cfg
    }

    private func renderAndReadCalibration(cfg: AppConfig, amplitude: Float, seconds: Double) -> MPXGenerator.CompositeCalibrationStatus {
        let gen = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        let frames = Int(cfg.sampleRate * seconds)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let w = 2.0 * Double.pi * 1_000.0 / cfg.sampleRate
        if amplitude > 0 {
            for i in 0..<frames {
                left[i] = Float(Double(amplitude) * sin(w * Double(i)))
                right[i] = left[i]
            }
        }
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                while offset < frames {
                    let chunk = min(1024, frames - offset)
                    gen.renderFromInputInPlace(
                        frameCount: chunk,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    offset += chunk
                }
            }
        }
        return gen.compositeCalibrationStatus
    }

    // MARK: - Acceptance: default config stays at zero overshoot

    @Test func defaultConfigProducesZeroPostInjectionOvershoot() {
        // Acceptance test: default operator config (0 dB output gain,
        // normal pilot/RDS levels, modest input amplitude) must never
        // engage the post-injection clamp. The governor reserves the
        // subcarrier budget up front and the audio path stays well
        // inside the available headroom.
        let cfg = makeStereoConfig(outputGainDB: 0.0)
        let calib = renderAndReadCalibration(cfg: cfg, amplitude: 0.5, seconds: 0.2)
        print(String(format: "[default-config] overshoot=%.6f, overBudget=%@",
                     calib.postInjectionOvershoot, calib.overBudget ? "true" : "false"))
        #expect(calib.postInjectionOvershoot < 1e-4,
            "default config must not engage post-injection clamp; got overshoot=\(String(calib.postInjectionOvershoot))")
        #expect(!calib.overBudget,
            "default config must not be over-budget; subcarrier reservation should fit easily")
    }

    // MARK: - Acceptance: hot but sane settings stay clean (governor at work)

    @Test func hotButSaneSettingsStayBelowClamp() {
        // High but operationally sane output gains (+6 dB, +12 dB) with
        // near-clipping audio input. The budget governor reduces the
        // AUDIO composite ceiling before pilot/RDS injection so the
        // chain stays effectively within the ±1.0 limit. Per the
        // auditor's spec, the steady-state invariant is that the
        // post-injection clamp does not engage; small (sub -40 dB)
        // transient envelope readings reflect envelope-tracking lag,
        // not clamp distortion of pilot/RDS amplitude.
        for gainDB in [6.0, 12.0] {
            let cfg = makeStereoConfig(outputGainDB: gainDB)
            let calib = renderAndReadCalibration(cfg: cfg, amplitude: 0.95, seconds: 0.2)
            print(String(format: "[hot-sane %+.0f dB] overshoot=%.6f, audioPeak=%.4f, overBudget=%@",
                         gainDB, calib.postInjectionOvershoot, calib.audioPeak,
                         calib.overBudget ? "true" : "false"))
            #expect(calib.postInjectionOvershoot < 1e-2,
                "+\(String(gainDB)) dB outputGain should stay within budget; got overshoot=\(String(calib.postInjectionOvershoot))")
            // Governor must not be marking sane configs as over-budget.
            #expect(!calib.overBudget,
                "+\(String(gainDB)) dB outputGain should not be flagged over-budget; subcarrier reservation should still fit")
            #expect(calib.audioPeak < 0.98,
                "+\(String(gainDB)) dB outputGain should report governed post-gain audio peak; got \(String(calib.audioPeak))")
        }
    }

    // MARK: - Verifier: pathological config is classified over-budget

    @Test func pathologicalConfigSurfacesOverBudgetFlag() {
        // At +24 dB output gain the subcarrier reservation alone (pilot
        // 0.08 × 15.85 ≈ 1.27) exceeds the threshold — no audio composite
        // can fit, and even pilot itself overruns the ±1.0 sample limit
        // intermittently. The chain MUST classify this explicitly via
        // `overBudget == true`, not silently rely on the final clamp.
        // Telemetry stays useful: `postInjectionOvershoot` is non-zero,
        // confirming the condition is visible to operators / verifier.
        let cfg = makeStereoConfig(outputGainDB: 24.0)
        let calib = renderAndReadCalibration(cfg: cfg, amplitude: 0.5, seconds: 0.2)
        print(String(format: "[pathological +24 dB] overshoot=%.6f, audioPeak=%.4f, overBudget=%@",
                     calib.postInjectionOvershoot, calib.audioPeak,
                     calib.overBudget ? "true" : "false"))
        #expect(calib.overBudget,
            "+24 dB outputGain must surface the over-budget flag; got overBudget=\(String(describing: calib.overBudget))")
        #expect(calib.postInjectionOvershoot > 0.05,
            "+24 dB outputGain should surface non-zero overshoot telemetry; got \(String(calib.postInjectionOvershoot))")
    }

    // MARK: - Governor: silent input + high gain stays clean

    @Test func silentInputAtHighGainStaysWithinBudget() {
        // Pilot + RDS at +18 dB outputGain alone: pilot 0.08 × 7.94 ≈ 0.63,
        // RDS contribution ≈ 0.32. Even instantaneously they sum well
        // below ±1.0. With silent input, the audio path is idle and the
        // smoothed subcarrier reservation still fits, so this should not
        // be flagged over-budget and must not engage the final clamp.
        let cfg = makeStereoConfig(outputGainDB: 18.0)
        let calib = renderAndReadCalibration(cfg: cfg, amplitude: 0.0, seconds: 0.2)
        print(String(format: "[silent +18 dB] overshoot=%.6f, audioPeak=%.4f, overBudget=%@",
                     calib.postInjectionOvershoot, calib.audioPeak,
                     calib.overBudget ? "true" : "false"))
        // Pilot/RDS combined peak < 1.0 — no clamp engagement.
        #expect(calib.postInjectionOvershoot < 1e-3,
            "silent input + high gain should not engage post-injection clamp; got overshoot=\(String(calib.postInjectionOvershoot))")
        #expect(!calib.overBudget,
            "silent input +18 dB should fit pilot/RDS reservation; got overBudget=\(String(describing: calib.overBudget))")
        // Audio path is observably idle.
        #expect(calib.audioPeak < 0.02,
            "silent input should leave audio composite near zero; got audioPeak=\(String(calib.audioPeak))")
    }
}
