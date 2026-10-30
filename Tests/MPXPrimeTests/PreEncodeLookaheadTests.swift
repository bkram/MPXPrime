import Testing
import Foundation
@testable import MPXPrime

// Phase 1 lookahead for the pre-encode L/R limiter. Two contracts:
//
// 1. lookahead_ms = 0 must not change. This is the regression guard --
//    changing the default config or leaving lookahead disabled in a preset
//    must not perturb existing baselines / verifier results. It is pinned
//    against a STORED golden output (captured 2026-10-15): the old check
//    compared `configure(...)` with `configure(..., lookaheadMS: 0.0)`, and
//    0.0 is the parameter's default, so both sides were the same call
//    (test-suite review 2026-10 finding 8).
//
// 2. lookahead_ms > 0 must measurably reduce peak overshoot on a
//    synthetic HF transient that hits a feedback-only limiter hard.
//    This is the "did we actually wire the future-peak hint into the
//    detector?" test.
//
// Subband-aware HF-only lookahead (US 5,579,404 / EP 0685130, Dolby,
// expired 2013) is the Phase 2 follow-up — see docs/project-roadmap.md.

@Suite("Pre-encode limiter look-ahead")
struct PreEncodeLookaheadTests {

    private let sampleRate: Float = 192_000.0

    // MARK: - Phase 1.1: lookahead = 0 is bit-identical

    @Test func zeroLookaheadMatchesTheFrozenGolden() {
        var limiter = StereoLinkedOversampledPeakLimiter()
        limiter.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0,
                          lookaheadMS: 0.0)
        expectMatchesGolden(&limiter, golden: Self.zeroLookaheadGolden, label: "lookahead 0")
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

    @Test func broadbandLookaheadMatchesTheFrozenGolden() {
        // Phase 2 regression guard: with lookaheadHFOnly = false the
        // detector is the Phase 1 broadband one. Pinned against a stored
        // golden for the same reason as the zero-lookahead case: the old
        // comparison passed `lookaheadHFOnly: false`, the default, on one
        // side only, so both sides were the same call.
        var limiter = StereoLinkedOversampledPeakLimiter()
        limiter.configure(sampleRate: sampleRate, threshold: 0.85, releaseMS: 50.0,
                          lookaheadMS: 1.0, lookaheadHFOnly: false)
        expectMatchesGolden(&limiter, golden: Self.broadbandLookaheadGolden, label: "broadband 1 ms")
    }

    // MARK: - Golden fixture

    struct Golden {
        let sumSquaresL: Double
        let sumSquaresR: Double
        /// Output at frames 64, 192, ..., 4032 (stride 128).
        let left: [Float]
        let right: [Float]
    }

    /// Hot HF tone plus a transient every 256 samples on L, a 3 kHz tone on
    /// R (different per channel so a channel swap or a broken stereo link
    /// shows), 4096 frames at 192 kHz, threshold 0.85, release 50 ms.
    /// Tolerance 1e-4 per sample and 1e-5 relative on the energy: far above
    /// Float / libm differences between platforms (~1e-7), far below what a
    /// one-sample delay (up to 0.18 on the 7 kHz tone) or a changed detector
    /// time constant moves.
    private func expectMatchesGolden(_ limiter: inout StereoLinkedOversampledPeakLimiter,
                                     golden: Golden, label: String) {
        var outL = [Float](repeating: 0.0, count: 4096)
        var outR = [Float](repeating: 0.0, count: 4096)
        for i in 0..<4096 {
            let phase = 2.0 * Float.pi * 7_000.0 * Float(i) / sampleRate
            var x = 0.9 * sinf(phase)
            if i % 256 == 0 { x += 0.8 }
            let y = 0.6 * sinf(2.0 * Float.pi * 3_000.0 * Float(i) / sampleRate)
            (outL[i], outR[i]) = limiter.process(left: x, right: y)
        }
        var sumL = 0.0, sumR = 0.0
        for v in outL { sumL += Double(v) * Double(v) }
        for v in outR { sumR += Double(v) * Double(v) }
        #expect(abs(sumL - golden.sumSquaresL) < golden.sumSquaresL * 1e-5,
                "\(label): L energy \(sumL) vs golden \(golden.sumSquaresL)")
        #expect(abs(sumR - golden.sumSquaresR) < golden.sumSquaresR * 1e-5,
                "\(label): R energy \(sumR) vs golden \(golden.sumSquaresR)")
        for (k, frame) in stride(from: 64, to: 4096, by: 128).enumerated() {
            #expect(abs(outL[frame] - golden.left[k]) < 1e-4,
                    "\(label): L[\(frame)] = \(outL[frame]), golden \(golden.left[k])")
            #expect(abs(outR[frame] - golden.right[k]) < 1e-4,
                    "\(label): R[\(frame)] = \(outR[frame]), golden \(golden.right[k])")
        }
    }

    static let zeroLookaheadGolden = Golden(
        sumSquaresL: 1409.3393833015314,
        sumSquaresR: 626.9841929433202,
        left: [
        0.0019705, -0.8048582, 0.0806973, 0.7058573, -0.7742012, 0.0770906,
        0.7074779, -0.7767791, 0.0790517, 0.6912844, -0.7603441, 0.0758737,
        0.6969923, -0.7660820, 0.0781902, 0.6827590, -0.7510026, 0.0749538,
        0.6885201, -0.7567677, 0.0773789, 0.6747754, -0.7422544, 0.0740858,
        0.6805820, -0.7480388, 0.0766315, 0.6672929, -0.7340172, 0.0732816,
        0.6731413, -0.7398523
        ],
        right: [
        -0.0013871, -0.4477667, -0.4429175, -0.4358382, -0.4346043, -0.4331177,
        -0.4325705, -0.4320937, -0.4317190, -0.4268111, -0.4268078, -0.4261482,
        -0.4261494, -0.4261474, -0.4261338, -0.4215461, -0.4215441, -0.4209663,
        -0.4209658, -0.4209660, -0.4209522, -0.4166167, -0.4166166, -0.4161166,
        -0.4161153, -0.4161123, -0.4160995, -0.4119889, -0.4119866, -0.4115563,
        -0.4115564, -0.4115561
        ])

    static let broadbandLookaheadGolden = Golden(
        sumSquaresL: 1279.6054453965794,
        sumSquaresR: 569.257043250182,
        left: [
        0.0000000, -0.0000000, 0.0786642, 0.7037316, -0.7708409, 0.0762817,
        0.6908162, -0.7689611, 0.0743516, 0.6866847, -0.7547843, 0.0746830,
        0.6765954, -0.7531121, 0.0728159, 0.6726978, -0.7400337, 0.0732197,
        0.6635191, -0.7385412, 0.0714062, 0.6598456, -0.7264199, 0.0718750,
        0.6514423, -0.7250838, 0.0700907, 0.6479594, -0.7138088, 0.0706038,
        0.6402291, -0.7126282
        ],
        right: [
        0.0000000, 0.0000000, -0.4411590, -0.4345016, -0.4284533, -0.4284474,
        -0.4277534, -0.4277520, -0.4278400, -0.4239734, -0.4194874, -0.4194821,
        -0.4189349, -0.4189342, -0.4190181, -0.4153356, -0.4112505, -0.4112469,
        -0.4108280, -0.4108260, -0.4109056, -0.4073961, -0.4036483, -0.4036428,
        -0.4033399, -0.4033394, -0.4034172, -0.4000666, -0.3966013, -0.3965974,
        -0.3964041, -0.3964060
        ])
}
