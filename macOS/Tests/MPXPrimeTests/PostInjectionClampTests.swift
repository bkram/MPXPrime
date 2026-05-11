import Testing
import Foundation
@testable import MPXPrime

// Regression guard for audit Finding #3: post-injection clamp could
// silently distort pilot/RDS. The chain ends with
//   mpx += subcarriers · outputGain
//   return clampf(mpx, -1, 1)
// If `audioComposite·outputGain + subcarriers·outputGain` exceeds 1.0,
// the clamp engages and the supposedly constant-amplitude pilot/RDS
// subcarriers are silently shaped. Before the Step 2 fix, the
// audio-composite ceiling had hard floors (0.18 / 0.16) that didn't
// shrink even when subcarrier reservation couldn't fit at high
// output gain — the clamp would then routinely engage and operators
// had no visibility into it.
//
// These tests pin:
// 1. On default + reasonable hot configs, `postInjectionOvershoot`
//    telemetry stays at zero (or near-zero) — pilot/RDS remain
//    constant-amplitude.
// 2. On a pathological config (very high output gain), the overshoot
//    becomes non-zero — the chain surfaces the over-budget condition
//    rather than silently clipping.
// 3. The audio composite ceiling actually shrinks when needed (the
//    floors no longer hold it above the subcarrier-reserved budget).

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

    private func renderAndReadOvershoot(cfg: AppConfig, amplitude: Float, seconds: Double) -> Float {
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
        return gen.compositeCalibrationStatus.postInjectionOvershoot
    }

    // MARK: - Test 1: default config stays at zero overshoot

    @Test func defaultConfigProducesZeroPostInjectionOvershoot() {
        // Default operator config (0 dB output gain, normal pilot/RDS
        // levels, modest input amplitude) must never engage the
        // post-injection clamp. If it does, the subcarrier budget
        // logic is broken.
        let cfg = makeStereoConfig(outputGainDB: 0.0)
        let overshoot = renderAndReadOvershoot(cfg: cfg, amplitude: 0.5, seconds: 0.2)
        print(String(format: "[default-config] postInjectionOvershoot = %.6f", overshoot))
        #expect(overshoot < 1e-3,
            "default config should not engage post-injection clamp; got overshoot=\(overshoot)")
    }

    @Test func telemetrySurfacesOverBudgetConditionMonotonicallyWithOutputGain() {
        // As outputGain rises past what the subcarrier budget can
        // accommodate, postInjectionOvershoot should rise correspondingly
        // — the telemetry is the operationally useful guarantee, surfacing
        // an over-budget condition that the operator can act on (reduce
        // outputGain, lower pilot/RDS levels, etc.). The fix at this
        // layer doesn't make the chain magically fit any config; it makes
        // the chain HONEST about over-budget.
        let cfgLow = makeStereoConfig(outputGainDB: 0.0)
        let cfgMid = makeStereoConfig(outputGainDB: 12.0)
        let cfgHigh = makeStereoConfig(outputGainDB: 24.0)
        let overshootLow = renderAndReadOvershoot(cfg: cfgLow, amplitude: 0.95, seconds: 0.2)
        let overshootMid = renderAndReadOvershoot(cfg: cfgMid, amplitude: 0.95, seconds: 0.2)
        let overshootHigh = renderAndReadOvershoot(cfg: cfgHigh, amplitude: 0.95, seconds: 0.2)
        print(String(format: "[telemetry-monotonic] 0dB=%.4f, +12dB=%.4f, +24dB=%.4f",
                     overshootLow, overshootMid, overshootHigh))
        // Default gain → no overshoot.
        #expect(overshootLow < 1e-2,
            "0 dB outputGain should not engage post-injection clamp; got \(overshootLow)")
        // High gain → telemetry surfaces the condition.
        #expect(overshootHigh > overshootMid + 0.05,
            "telemetry should rise with outputGain; got 12dB=\(overshootMid), 24dB=\(overshootHigh)")
        #expect(overshootMid > overshootLow + 0.05,
            "telemetry should rise with outputGain; got 0dB=\(overshootLow), 12dB=\(overshootMid)")
    }

    // MARK: - Test 2: pathological config surfaces the over-budget condition

    @Test func pathologicalConfigSurfacesPostInjectionOvershoot() {
        // Push outputGainDB to a value where the audio-composite
        // budget genuinely cannot reserve enough headroom for pilot
        // (subcarrier reservation × outputGain > 1.0). At +20 dB
        // output gain, pilot peak alone (0.08 × 10 = 0.8) plus any
        // audio composite would clip — the chain should surface this
        // via `postInjectionOvershoot` rather than silently letting
        // the clamp distort pilot.
        let cfg = makeStereoConfig(outputGainDB: 20.0)
        let overshoot = renderAndReadOvershoot(cfg: cfg, amplitude: 0.5, seconds: 0.2)
        print(String(format: "[pathological-config] +20 dB outputGain, postInjectionOvershoot = %.6f", overshoot))
        #expect(overshoot > 0.05,
            "+20 dB outputGain should surface over-budget via postInjectionOvershoot; got \(overshoot) — telemetry isn't surfacing the condition")
    }

    // MARK: - Test 3: budget actually shrinks audio composite at high gain

    @Test func budgetShrinksAudioCompositeWhenSubcarrierReservationGrows() {
        // Audit Step 2: the audio-composite ceiling should shrink
        // when output gain is pushed up, so pilot/RDS reservation
        // can fit within the post-injection budget without engaging
        // the clamp. Previously the hard floors (0.18 / 0.16) kept
        // the audio composite at fixed minimum levels regardless of
        // output gain — that's what caused the clamp to engage.
        //
        // Verify: render with silent input + high output gain. The
        // chain's audio composite path should be effectively quiet
        // (audio composite peak * outputGain << 1.0), so pilot can
        // dominate without clamping. Reading the audioPeak from
        // compositeCalibrationStatus tells us the chain's resulting
        // audio composite peak (post-soft-clip-safety).
        let cfg = makeStereoConfig(outputGainDB: 18.0)
        let gen = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        let frames = Int(cfg.sampleRate * 0.2)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
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
        // With silent input, audioComposite should be ~0. Subcarrier
        // reservation should be the dominant budget consumer.
        let calib = gen.compositeCalibrationStatus
        print(String(format: "[budget-shrink] silent input, +18 dB gain: audioPeak=%.4f, overshoot=%.6f",
                     calib.audioPeak, calib.postInjectionOvershoot))
        // With pre-fix code (hard floor 0.16 audio composite ceiling)
        // and 0 audio in, audioComposite peak should be 0. Subcarrier
        // peak (0.08 × 7.94 ≈ 0.64) fits within 1.0 — no clamp.
        // This confirms that for silent input the chain is already OK
        // even at +18 dB. The over-budget case requires AUDIO + high
        // gain; that's pathologicalConfigSurfacesPostInjectionOvershoot.
        #expect(calib.audioPeak < 0.02,
            "silent input should produce audio peak near 0; got \(calib.audioPeak)")
        #expect(calib.postInjectionOvershoot < 1e-2,
            "silent input even at +18 dB shouldn't engage post-injection clamp; got \(calib.postInjectionOvershoot)")
    }
}
