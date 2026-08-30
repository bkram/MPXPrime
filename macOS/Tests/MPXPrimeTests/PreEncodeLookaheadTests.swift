import Testing
import Foundation
@testable import MPXPrime

// Phase 1 lookahead for the pre-encode L/R limiter. Two contracts:
//
// 1. lookahead_ms = 0 must be bit-identical to the no-lookahead path.
//    This is the regression guard — changing the default config or
//    leaving lookahead disabled in a preset must not perturb existing
//    baselines / verifier results.
//
// 2. lookahead_ms > 0 must measurably reduce peak overshoot on a
//    synthetic HF transient that hits a feedback-only limiter hard.
//    This is the "did we actually wire the future-peak hint into the
//    detector?" test.
//
// Subband-aware HF-only lookahead (US 5,579,404 / EP 0685130, Dolby,
// expired 2013) is the Phase 2 follow-up — see plan.md.

@Suite("Pre-encode limiter look-ahead")
struct PreEncodeLookaheadTests {

    private let sampleRate: Float = 192_000.0

    // MARK: - Phase 1.1: lookahead = 0 is bit-identical

    @Test func zeroLookaheadIsBitIdenticalToLegacyPath() {
        var legacy = StereoLinkedOversampledPeakLimiter()
        var lookahead = StereoLinkedOversampledPeakLimiter()
        legacy.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0)
        lookahead.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0,
                            lookaheadMS: 0.0)

        // Hot mix: HF tone + transient burst, the kind of signal the
        // feedback-only limiter has to work hard on. Bit-identical
        // output verifies the lookahead == 0 short-circuit.
        let frames = 4096
        let f1: Float = 7_000.0
        for i in 0..<frames {
            let phase = 2.0 * Float.pi * f1 * Float(i) / sampleRate
            var x = 0.9 * sinf(phase)
            if i % 256 == 0 { x += 0.8 }   // transient burst every ~1.3 ms
            let (legL, legR) = legacy.process(left: x, right: x)
            let (lhL, lhR) = lookahead.process(left: x, right: x)
            #expect(legL == lhL, "L channel diverges at sample \(i): legacy=\(legL) vs lookahead=\(lhL)")
            #expect(legR == lhR, "R channel diverges at sample \(i): legacy=\(legR) vs lookahead=\(lhR)")
        }
    }

    // MARK: - Phase 1.2: lookahead > 0 reduces peak overshoot on a transient

    @Test func nonzeroLookaheadReducesPeakOvershoot() {
        // Synthetic step burst — quiet for 5 ms, then a sustained loud
        // tone. A feedback limiter has to react after the step lands; a
        // lookahead limiter sees the step coming and ramps gain in
        // advance, so the overshoot at the leading edge is lower.
        let frames = 8_192
        let stepStart = 960   // 5 ms at 192 kHz
        let loudLevel: Float = 1.5  // well over 1.0 ceiling
        let f: Float = 5_000.0  // HF where pre-emphasis would normally pile peaks
        var input = [Float](repeating: 0.0, count: frames)
        for i in stepStart..<frames {
            let phase = 2.0 * Float.pi * f * Float(i - stepStart) / sampleRate
            input[i] = loudLevel * sinf(phase)
        }

        func renderPeak(lookaheadMS: Float) -> Float {
            var lim = StereoLinkedOversampledPeakLimiter()
            lim.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0,
                          lookaheadMS: lookaheadMS)
            var peak: Float = 0.0
            // Inspect only the first ~1 ms after step onset — that is
            // where the feedback limiter overshoots while attack ramps.
            let inspectStart = stepStart
            let inspectEnd = stepStart + 192  // 1 ms
            for i in 0..<frames {
                let (outL, _) = lim.process(left: input[i], right: input[i])
                if i >= inspectStart && i < inspectEnd {
                    peak = max(peak, fabsf(outL))
                }
            }
            return peak
        }

        let peakNoLookahead = renderPeak(lookaheadMS: 0.0)
        let peakWithLookahead = renderPeak(lookaheadMS: 1.0)

        // 1 ms of lookahead at 192 kHz = 192 samples — comfortably more
        // than the 0.25 ms attack window. The leading-edge overshoot
        // should drop by at least 5% of the no-lookahead peak; in practice
        // we see considerably more, but this threshold is the contract.
        let improvement = (peakNoLookahead - peakWithLookahead) / max(1e-6, peakNoLookahead)
        #expect(improvement > 0.05,
            "lookahead=1ms should reduce leading-edge overshoot by >5%; got \(improvement * 100)% (no-lookahead peak=\(peakNoLookahead), lookahead peak=\(peakWithLookahead))")
    }

    // MARK: - Phase 1.3: live-apply must not silently reset lookahead

    @Test func liveApplyReconfigurePreservesLookahead() {
        // Bug guard: applyRuntimeConfig() reconfigures the limiter when
        // threshold/release/residual settings change, but lookahead is
        // a restart-only field (not part of RuntimeConfig). If the
        // live-apply reconfigure forgets to pass the current lookaheadMS,
        // the limiter silently drops to lookahead=0 — operator-set
        // lookahead disappears the next time anyone moves an unrelated
        // slider. This test exercises the full MPXGenerator live-apply
        // path and asserts the lookahead survives.
        var cfg = AppConfig()
        cfg.preEncodeLookaheadMS = 1.0
        cfg.preEncodeThreshold = 0.85
        let gen = MPXGenerator(config: cfg, sampleRate: Double(sampleRate))

        // Trigger live-apply by changing an unrelated limiter setting.
        var nextCfg = cfg
        nextCfg.preEncodeThreshold = 0.90
        gen.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: nextCfg))

        // Push a loud HF transient burst and capture the leading-edge peak.
        // If lookahead got reset to 0 by the live-apply, the peak will be
        // measurably higher (no advance gain ramp). The render must outlast
        // the TX chain's group delay (FIR crossovers + encoder FIR + limiter
        // decimator + dual-rate boundary, ~15 ms) or the burst never reaches
        // the output inside the window.
        let frames = 19_200
        let f: Float = 5_000.0
        let stepStart = 960
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        for i in stepStart..<frames {
            let phase = 2.0 * Float.pi * f * Float(i - stepStart) / sampleRate
            left[i] = 1.5 * sinf(phase)
            right[i] = left[i]
        }
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                gen.renderFromInputInPlace(
                    frameCount: frames,
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!
                )
            }
        }

        // Compare against a reference generator with lookahead explicitly = 0
        // — the live-apply path should match the cfg.preEncodeLookaheadMS = 1.0
        // generator, not this reference.
        var zeroCfg = cfg
        zeroCfg.preEncodeLookaheadMS = 0.0
        zeroCfg.preEncodeThreshold = 0.90
        let genZero = MPXGenerator(config: zeroCfg, sampleRate: Double(sampleRate))
        var leftZero = [Float](repeating: 0.0, count: frames)
        var rightZero = [Float](repeating: 0.0, count: frames)
        for i in stepStart..<frames {
            let phase = 2.0 * Float.pi * f * Float(i - stepStart) / sampleRate
            leftZero[i] = 1.5 * sinf(phase)
            rightZero[i] = leftZero[i]
        }
        leftZero.withUnsafeMutableBufferPointer { lBuf in
            rightZero.withUnsafeMutableBufferPointer { rBuf in
                genZero.renderFromInputInPlace(
                    frameCount: frames,
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!
                )
            }
        }

        // The live-apply gen (lookahead=1) and the reference gen (lookahead=0)
        // should produce measurably different output. If the live-apply
        // accidentally reset lookahead to 0, both would match — that's the
        // regression we're guarding against.
        var anyDiff = false
        let warmup = Int(sampleRate * 0.010)  // 10 ms warm-up for FIR settling
        for i in warmup..<frames {
            if fabsf(left[i] - leftZero[i]) > 1e-4 {
                anyDiff = true
                break
            }
        }
        #expect(anyDiff,
            "lookahead silently reset to 0 by live-apply — output matches the lookahead=0 reference")
    }

    // MARK: - Phase 1.4: mono in → mono out (stereo-link discipline holds)

    @Test func monoInputProducesMonoOutputWithLookahead() {
        var lim = StereoLinkedOversampledPeakLimiter()
        lim.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0,
                      lookaheadMS: 1.5)
        for i in 0..<2048 {
            let x = 1.2 * sinf(2.0 * Float.pi * 3_000.0 * Float(i) / sampleRate)
            let (outL, outR) = lim.process(left: x, right: x)
            #expect(outL == outR,
                "stereo-link broken at sample \(i): L=\(outL) R=\(outR)")
        }
    }

    // MARK: - Phase 2: HF-subband-aware look-ahead per US 5,579,404

    @Test func phase2HFOnlyDetectorIgnoresLFTransients() {
        // Sustained 100 Hz sine at amplitude 1.5 — well above the limiter's
        // threshold. With broadband lookahead, the detector sees the LF
        // peaks via the un-delayed futurePeak path and engages GR on every
        // half-cycle. With HF-only detector (HP at 4 kHz), the 100 Hz
        // content is filtered out of the detector path → futurePeak stays
        // near zero from the lookahead view; only the OS-rate peak of the
        // delayed sample can trigger limiting via the normal (no-lookahead)
        // path, which is the reactive feedback behavior.
        //
        // What we measure: with HF-only OFF the limiter sees the LF peak
        // via the lookahead AND via the OS path, so its GR is steady and
        // hits its full target. With HF-only ON it can only see the LF
        // peak via the OS path (no lookahead boost), so the gain ramps
        // less aggressively at the leading edge of the first peak.
        let frames = 4_096
        let f: Float = 100.0
        var input = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let phase = 2.0 * Float.pi * f * Float(i) / sampleRate
            input[i] = 1.5 * sinf(phase)
        }

        // Inspect window: first 0.5 ms of the rising edge of the first
        // peak. At 100 Hz, the sine reaches 0.9 × peak at ~3 ms (the
        // first quarter-period is 2.5 ms). Sample peak GR in the window
        // covering the sine's rise from 0.0 to ~0.85 of its peak — that's
        // where the broadband detector's "future peak" knowledge gives it
        // a head start versus the HF-only detector that can only react.
        let inspectStart = 0
        let inspectEnd = 480  // 2.5 ms — quarter period of 100 Hz

        func renderPeakGR(hfOnly: Bool) -> Float {
            var lim = StereoLinkedOversampledPeakLimiter()
            lim.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0,
                          lookaheadMS: 1.0, lookaheadHFOnly: hfOnly,
                          lookaheadHFCutoffHz: 4_000.0)
            var peakGR: Float = 0.0
            for i in 0..<inspectEnd {
                _ = lim.process(left: input[i], right: input[i])
                if i >= inspectStart {
                    peakGR = max(peakGR, lim.gainReductionDB)
                }
            }
            return peakGR
        }

        let grBroadband = renderPeakGR(hfOnly: false)
        let grHFOnly = renderPeakGR(hfOnly: true)

        // Broadband sees the LF peak coming via future-peak hint → larger
        // early GR. HF-only filters the LF out of the detector → less
        // early GR. The gap should be at least 0.5 dB during the rising
        // edge.
        #expect(grHFOnly < grBroadband - 0.5,
            "HF-only detector should respond less to a 100 Hz transient than broadband; got HF-only=\(grHFOnly) dB vs broadband=\(grBroadband) dB during rising edge")
    }

    @Test func phase2HFOnlyDetectorStillCatchesHFTransients() {
        // Inverse of the LF test: a 6 kHz transient burst (well above the
        // 4 kHz HP cutoff). HF-only should still see this, engage the
        // look-ahead path, and produce GR comparable to broadband mode.
        let frames = 4_096
        let f: Float = 6_000.0  // HF
        let stepStart = 960
        var input = [Float](repeating: 0.0, count: frames)
        for i in stepStart..<frames {
            let phase = 2.0 * Float.pi * f * Float(i - stepStart) / sampleRate
            input[i] = 1.5 * sinf(phase)
        }

        func renderPeakGR(hfOnly: Bool) -> Float {
            var lim = StereoLinkedOversampledPeakLimiter()
            lim.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0,
                          lookaheadMS: 1.0, lookaheadHFOnly: hfOnly,
                          lookaheadHFCutoffHz: 4_000.0)
            var peakGR: Float = 0.0
            for i in 0..<(stepStart + 384) {  // 2 ms post-onset (catches the full attack ramp)
                _ = lim.process(left: input[i], right: input[i])
                if i >= stepStart {
                    peakGR = max(peakGR, lim.gainReductionDB)
                }
            }
            return peakGR
        }

        let grBroadband = renderPeakGR(hfOnly: false)
        let grHFOnly = renderPeakGR(hfOnly: true)

        // HF transient: HF-only mode should still engage, within ~1 dB of
        // broadband. (HP filter rolls off slightly even above cutoff, so
        // a tiny gap is expected, but they should be in the same ballpark.)
        let gap = fabsf(grBroadband - grHFOnly)
        #expect(gap < 1.5,
            "HF-only detector should still catch 6 kHz transients; broadband=\(grBroadband) dB vs HF-only=\(grHFOnly) dB (gap \(gap) dB > 1.5 dB tolerance)")
        #expect(grHFOnly > 1.0,
            "HF-only should produce >1 dB GR on a 6 kHz transient at threshold 0.85; got \(grHFOnly) dB")
    }

    @Test func phase2HFOnlyOffMatchesBroadbandLookahead() {
        // Regression guard: with lookaheadHFOnly = false, behavior must be
        // bit-identical to Phase 1 (broadband detector).
        let frames = 2_048
        var inputL = [Float](repeating: 0.0, count: frames)
        var inputR = [Float](repeating: 0.0, count: frames)
        let f: Float = 5_000.0
        for i in 0..<frames {
            let phase = 2.0 * Float.pi * f * Float(i) / sampleRate
            let v = 1.1 * sinf(phase)
            inputL[i] = v
            inputR[i] = v
        }

        var p1 = StereoLinkedOversampledPeakLimiter()
        var p2default = StereoLinkedOversampledPeakLimiter()
        p1.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0,
                     lookaheadMS: 1.0)
        p2default.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0,
                            lookaheadMS: 1.0, lookaheadHFOnly: false)

        for i in 0..<frames {
            let (l1, r1) = p1.process(left: inputL[i], right: inputR[i])
            let (l2, r2) = p2default.process(left: inputL[i], right: inputR[i])
            #expect(l1 == l2, "Phase 2 with HF-only=false diverges at sample \(i): \(l1) vs \(l2)")
            #expect(r1 == r2, "Phase 2 with HF-only=false diverges at sample \(i): \(r1) vs \(r2)")
        }
    }
}
