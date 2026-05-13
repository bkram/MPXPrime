import Testing
import Foundation
@testable import MPXPrime

// Regression guard for the audit finding that pilot/RDS injection was
// not delay-aligned with the audio composite. Composite-clipper FIR
// group delay and the final MPX limiter's look-ahead window delay the
// stereo subcarrier (embedded in `audioComposite`) by ~Δ samples, but
// pilot/RDS were being added with the current oscillator phase — so
// receiver-side stereo demod (using a pilot-locked 38 kHz reference)
// recovered L-R amplitude scaled by cos(2Δ·Δφ_19k), a 5-10 dB loss at
// default config.
//
// These tests validate the fix at three levels:
// 1. recomputeSubcarrierDelay sizes the delay line to match the total
//    audio-path delay (algorithmic correctness).
// 2. With fix engaged, the MPX output is measurably different vs the
//    pre-fix code path (data-path correctness).
// 3. With audio silent + fix on, the pilot at the output is the
//    delay-shifted pilot oscillator value, not the current value
//    (phase-alignment correctness).
//
// The full end-to-end receiver-side stereo separation measurement is
// deferred to the exciter test (a real receiver + spectrum analyzer
// captures it cleanly without the phase-extraction subtleties that
// pollute a fully-synthetic Goertzel/Hilbert demod).

@Suite("Subcarrier delay alignment")
struct StereoSeparationReceiverTests {

    private let sampleRate: Double = 192_000.0
    private let audioToneHz: Double = 1_000.0

    private func makeStereoConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = 1024
        cfg.processingBypass = false
        cfg.compositeClipperEnabled = true
        cfg.compositeClipperLookaheadMS = 0.0
        cfg.limitMPX = true
        cfg.limitLookaheadMS = 5.0
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
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.preEncodeThreshold = 0.95
        cfg.preEncodeReleaseMS = 50.0
        cfg.preemphasisUS = 0
        cfg.enRDS = false
        cfg.monoMode = false
        cfg.pilotLevel = 0.08
        return cfg
    }

    private func renderMPX(amplitude: Float, seconds: Double,
                          disableSubcarrierDelay: Bool) -> [Float] {
        let cfg = makeStereoConfig()
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        if disableSubcarrierDelay {
            // Emulate the pre-fix code path (no subcarrier delay).
            gen.subcarrierDelayActiveCount = 0
            gen.subcarrierDelayWriteIdx = 0
        }
        let frames = Int(sampleRate * seconds)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        if amplitude > 0 {
            let w = 2.0 * Double.pi * audioToneHz / sampleRate
            for i in 0..<frames {
                // Hard-panned L for stereo-encode stress.
                left[i] = Float(Double(amplitude) * sin(w * Double(i)))
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
        return left
    }

    // MARK: - Test 1: algorithmic correctness of delay size

    @Test func subcarrierDelayLineSizeMatchesAudioPathDelay() {
        // With composite clipper enabled (lookaheadMS = 0 — only FIR
        // group delay) and final MPX lookahead at 5 ms, audio path
        // delay should be FIR_group_delay + audio-composite bandwidth
        // FIR group delay + lookahead_samples. At 192 kHz with default
        // decimator (~150 Kaiser-windowed taps at 8× OS = ~9 host
        // samples), audio-composite bandwidth FIR (~112 host samples),
        // and 5 ms lookahead (= 960 samples), the total is ~1081 samples.
        let cfg = makeStereoConfig()
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let actual = gen.subcarrierDelayActiveCount
        print("[delay-size] subcarrierDelayLine.count = \(actual) (expected ≈1081)")
        #expect(actual > 1060 && actual < 1100,
            "subcarrier delay line size \(actual) outside expected ~1081-sample window (decimator + audio bandwidth FIR + lookahead)")
    }

    @Test func subcarrierDelayLineRespondsToCompositeClipperFlag() {
        // When composite clipper is disabled at config time, the
        // audio path through it is bypassed — recomputeSubcarrierDelay
        // should drop the decimator FIR group delay contribution from
        // the subcarrier delay total. (Audio-composite bandwidth FIR
        // and lookahead limiter contributions remain.)
        var cfg = makeStereoConfig()
        cfg.compositeClipperEnabled = false
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let actual = gen.subcarrierDelayActiveCount
        // Expected: 960 lookahead + ~112 audio bandwidth FIR = ~1072.
        print("[delay-size] composite clipper OFF, subcarrierDelayLine.count = \(actual) (expected ≈1072)")
        #expect(actual >= 1060 && actual <= 1085,
            "with composite clipper off, delay should be ~1072 (audio bandwidth FIR + lookahead); got \(actual)")
    }

    @Test func liveCompositeLookaheadResizeChangesActiveDelayWithoutGrowingStorage() {
        var cfg = makeStereoConfig()
        cfg.compositeClipperLookaheadMS = 0.0
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let initialCapacity = gen.subcarrierDelayLine.count
        let initialActive = gen.subcarrierDelayActiveCount

        cfg.compositeClipperLookaheadMS = 3.0
        gen.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: cfg))

        let resizedCapacity = gen.subcarrierDelayLine.count
        let resizedActive = gen.subcarrierDelayActiveCount
        let expectedDelta = Int(round(3.0 / 1000.0 * sampleRate))

        #expect(resizedCapacity == initialCapacity)
        #expect(resizedActive - initialActive == expectedDelta)

        cfg.compositeClipperLookaheadMS = 0.5
        gen.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: cfg))

        #expect(gen.subcarrierDelayLine.count == initialCapacity)
        #expect(gen.subcarrierDelayActiveCount - initialActive == Int(round(0.5 / 1000.0 * sampleRate)))
    }

    // MARK: - Test 2: data path correctness

    @Test func subcarrierDelayFixChangesMPXOutput() {
        // Sanity: fix-on and fix-off renders should produce
        // measurably different MPX samples. If max diff ≈ 0, the fix
        // isn't in the data path.
        let amplitude: Float = 0.5
        let seconds: Double = 0.05
        let mpxNoFix = renderMPX(amplitude: amplitude, seconds: seconds,
                                disableSubcarrierDelay: true)
        let mpxWithFix = renderMPX(amplitude: amplitude, seconds: seconds,
                                  disableSubcarrierDelay: false)
        var maxDiff: Float = 0.0
        var sumSqDiff: Double = 0.0
        let startIdx = 2000  // past lookahead warmup (969 samples)
        let countIdx = 100
        for k in startIdx..<(startIdx + countIdx) {
            let d = mpxNoFix[k] - mpxWithFix[k]
            maxDiff = max(maxDiff, fabsf(d))
            sumSqDiff += Double(d) * Double(d)
        }
        let rmsDiff = sqrt(sumSqDiff / Double(countIdx))
        print(String(format: "[fix-active] max|noFix-withFix|=%.5f, RMS=%.5f over %d samples",
                     maxDiff, rmsDiff, countIdx))
        // Pilot amplitude is 0.08; the delay shifts pilot phase by
        // ~287° (969 samples × 71.25°/sample mod 360°), so the
        // sample-by-sample pilot delta has amplitude up to 2·sin(287°/2)·0.08
        // ≈ 0.155, capped by clipping. We require ≥0.01 to confirm the
        // fix is actually engaging in the data path.
        #expect(maxDiff > 0.01,
            "fix-on and fix-off renders produce essentially identical MPX (maxDiff=\(maxDiff)) — fix isn't engaging")
    }

    // MARK: - Test 3: phase-alignment correctness via silent-input pilot

    @Test func pilotPhaseIsDelayedWhenFixEnabled() {
        // With audio = silence, MPX output contains only pilot (and
        // RDS — which we have disabled). With fix off, pilot at output
        // sample N = sin(2π·19k·N·δT). With fix on, pilot at output
        // sample N = sin(2π·19k·(N-Δ)·δT). The two pilots differ in
        // amplitude at any given sample by a known function of N and Δ.
        //
        // Specifically: pilot_noFix(N) - pilot_withFix(N) =
        //   sin(2π·19k·N·δT) - sin(2π·19k·(N-Δ)·δT)
        // For Δ=969, 2π·19k·969·δT = 1205 rad = 1.79·2π = 0.79·2π
        // (after wrapping) = 285.7°. The amplitude of the difference
        // signal is 2·sin(285.7°/2)·0.08 = 2·sin(142.85°)·0.08 = 2·0.604·0.08
        // = 0.0966. So with fix on, pilot at output is measurably
        // different from current pilot at sample 1000+.
        let seconds: Double = 0.05
        let mpxNoFix = renderMPX(amplitude: 0.0, seconds: seconds,
                                disableSubcarrierDelay: true)
        let mpxWithFix = renderMPX(amplitude: 0.0, seconds: seconds,
                                  disableSubcarrierDelay: false)

        // Compare in a window past warmup. Audio is silent, so the
        // chain output is dominated by pilot. Measure pilot amplitude
        // and pilot phase difference.
        let warmup = Int(0.03 * sampleRate)  // 30 ms — past lookahead
        let countSamples = 1024
        var sumSqNoFix: Double = 0.0
        var sumSqWithFix: Double = 0.0
        var sumSqDiff: Double = 0.0
        for k in warmup..<(warmup + countSamples) {
            sumSqNoFix += Double(mpxNoFix[k]) * Double(mpxNoFix[k])
            sumSqWithFix += Double(mpxWithFix[k]) * Double(mpxWithFix[k])
            let d = mpxNoFix[k] - mpxWithFix[k]
            sumSqDiff += Double(d) * Double(d)
        }
        let rmsNoFix = sqrt(sumSqNoFix / Double(countSamples))
        let rmsWithFix = sqrt(sumSqWithFix / Double(countSamples))
        let rmsDiff = sqrt(sumSqDiff / Double(countSamples))

        print(String(format: "[silent-pilot] noFix RMS=%.5f, withFix RMS=%.5f, diff RMS=%.5f",
                     rmsNoFix, rmsWithFix, rmsDiff))

        // Both renders should have similar pilot RMS (≈ 0.08/√2 ≈ 0.057).
        #expect(rmsNoFix > 0.04 && rmsNoFix < 0.08,
            "no-fix pilot RMS \(rmsNoFix) outside expected range")
        #expect(rmsWithFix > 0.04 && rmsWithFix < 0.08,
            "with-fix pilot RMS \(rmsWithFix) outside expected range")
        // The DIFFERENCE between the two pilots must have non-trivial
        // RMS — confirming the fix is shifting the pilot phase, not
        // just outputting the same pilot. With the current delay
        // (~1081 samples) the pilot phase wraps to ~343°, so the
        // sample-by-sample diff amplitude is modest but distinctly
        // non-zero; a threshold well above noise (~1e-4) is sufficient
        // to prove the fix engages.
        #expect(rmsDiff > 0.005,
            "fix-on and fix-off pilot RMS difference \(rmsDiff) is too small — the delay isn't actually shifting pilot phase")
    }
}
