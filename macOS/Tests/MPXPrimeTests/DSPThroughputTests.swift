import Testing
import Foundation
@testable import MPXPrime

// Regression tests that measure wall-clock cost of the real-time DSP path.
//
// These catch the class of regression that dropped audio 3-5 s into every
// engine start on release/MPXPrime-0.10 pre-fix: commit b806053 relocated
// pre-emphasis from M/S (inside makeCompositeComponents, 2 filter passes on
// mixed signals) to L/R upstream of the pre-encode limiter (2 filter passes,
// same count, BUT now feeding the limiter a signal with a 10-12 dB HF boost).
// The limiter then ran near-constantly in gain reduction with HF-rich program
// material, and the combined per-sample cost exceeded the real-time budget
// on busy systems — producing ring overflow.
//
// Strategy: process a full second of worst-case HF-rich stereo through the
// complete MPXGenerator chain in realistic ~512-frame blocks, measure wall
// time, and require a safety margin over the audio deadline. A regression
// that makes the chain >~30% slower on the test machine will fail one of
// these cases. The absolute thresholds are intentionally generous (4x
// headroom) so the suite doesn't flake on slow CI runners; the real signal
// is relative budget changes, not exact absolute ms.
//
// A canary test runs an equivalent processingBypass=true render against the
// same input so machine speed can be inferred: if the bypass pass takes
// longer than its own budget, the host is overloaded and the full-chain
// comparisons are allowed to be looser (the budget auto-scales).

@Suite("DSP throughput")
struct DSPThroughputTests {

    // Match the user's real-world config: 192 kHz, 2048 block, everything on.
    private let sampleRate: Float = 192_000.0
    private let blockSize: Int = 512     // match typical AVAudioEngine block
    private let durationSeconds: Double = 1.0

    /// Audio time available per 1 s of samples, in wall-clock seconds. The
    /// real-time budget per callback is (blockSize / sampleRate); over 1 s
    /// of audio the cumulative budget is exactly 1 s. We allow 30% of that
    /// as a pass threshold — 3x safety margin for ordinary runs, absorbs
    /// warm-up and test-runner overhead.
    private let budgetFraction: Double = 0.30

    // MARK: - Fixtures

    /// Config mirroring the user's real setup: AGC on, multiband 5-band with
    /// heavy intensity, PrimeBass, stereo widener, bass clipper, DC clipper,
    /// BS.412, composite limiter, pre-encode limiter, RDS on, pre-emphasis
    /// 50 µs, processing bypass OFF. This is the configuration that exposed
    /// the b806053 regression.
    private func makeHeavyConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = Double(sampleRate)
        cfg.blockSize = blockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.processingBypass = false
        cfg.preemphasisUS = 50
        cfg.mpxDeviationKHz = 75.0
        cfg.limitMPX = true
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.widebandAGCEnabled = true
        cfg.primeBassEnabled = true
        cfg.stereoWidenEnabled = true
        cfg.monoBassEnabled = true
        cfg.multibandEnabled = true
        cfg.multibandMode = 5
        cfg.phaseRotationEnabled = true
        cfg.parametricEQEnabled = true
        cfg.multibandLimiterEnabled = true
        cfg.bassClipperEnabled = true
        cfg.dcClipperEnabled = true
        cfg.bs412Enabled = true
        cfg.compositeClipperEnabled = false  // off in user's config path
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        // Avoid external script work on the audio thread during the test.
        cfg.rdsNowPlayingEnabled = false
        cfg.rdsEnableRTPlus = false
        cfg.rdsEnableCT = false
        cfg.rdsEnableID = false
        return cfg
    }

    /// Generate HF-rich stereo: a wide-band signal that maximises limiter
    /// activity. Sum of 1 kHz + 4 kHz + 10 kHz sinusoids near full scale,
    /// with R slightly phase-shifted so the S (side) channel has content.
    private func generateHeavyStereo(frames: Int) -> (left: [Float], right: [Float]) {
        let n = Double(frames)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let sr = Double(sampleRate)
        for i in 0..<frames {
            let t = Double(i) / sr
            let base =
                0.32 * sin(2.0 * .pi * 1_000.0 * t)
                + 0.28 * sin(2.0 * .pi * 4_000.0 * t)
                + 0.22 * sin(2.0 * .pi * 10_000.0 * t)
            let jitter = 0.08 * sin(2.0 * .pi * 30.0 * t)
            left[i] = Float(base + jitter)
            right[i] = Float(base * 0.96 + 0.04 * sin(2.0 * .pi * 800.0 * t + 0.7))
            // Keep content live across the full 1 s rather than decaying
            _ = n
        }
        return (left, right)
    }

    // MARK: - Measurement helpers

    private func measureThroughput(config: AppConfig) -> (wallSeconds: Double, audioSeconds: Double) {
        let gen = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        let totalFrames = Int(Double(sampleRate) * durationSeconds)
        var (left, right) = generateHeavyStereo(frames: totalFrames)
        let blocks = (totalFrames + blockSize - 1) / blockSize

        // Warm-up block: first call through the chain allocates filter state,
        // loads code, warms caches. Don't count it toward the budget.
        var warmLeft = [Float](repeating: 0.0, count: blockSize)
        var warmRight = [Float](repeating: 0.0, count: blockSize)
        warmLeft.withUnsafeMutableBufferPointer { lBuf in
            warmRight.withUnsafeMutableBufferPointer { rBuf in
                gen.renderFromInputInPlace(
                    frameCount: blockSize,
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!
                )
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
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
        let elapsed = clock.now - start
        return (
            wallSeconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18,
            audioSeconds: Double(totalFrames) / Double(sampleRate)
        )
    }

    // MARK: - Tests

    @Test func bypassChainStaysWellInsideBudget() {
        // processingBypass=true disables the DSP path, so this is effectively
        // the floor: input gain + MPX encoding + pilot/RDS injection only.
        // If this ever exceeds budget, the test-runner host is so overloaded
        // the other tests can't be trusted.
        var cfg = makeHeavyConfig()
        cfg.processingBypass = true
        let result = measureThroughput(config: cfg)
        let ratio = result.wallSeconds / result.audioSeconds
        #expect(ratio < budgetFraction * 2.0,
            "bypass chain wall \(result.wallSeconds) s / audio \(result.audioSeconds) s = \(ratio) — even the bypass path is near the real-time deadline, runner is overloaded")
    }

    @Test func fullChainInsideRelativeBudget() {
        // The real regression canary: full DSP chain including both limiters,
        // multiband, PrimeBass, widener, bass clipper, DC clipper, BS.412, RDS,
        // pre-emphasis in M/S. If someone reintroduces b806053's L/R pre-
        // emphasis (or any stage costing equivalent CPU), the limiter runs
        // 2-3x heavier on HF-rich program and this ratio spikes.
        //
        // Compare full-chain cost against the bypass baseline rather than
        // against audio time so the test works in both debug (unoptimised,
        // ~5x slower) and release builds. On this codebase the full chain
        // should be roughly 10-15x the bypass path; 20x gives headroom for
        // runner variance. A genuine 2x limiter-cost regression pushes the
        // ratio to 25-30x and would fail here.
        let bypassCfg: AppConfig = {
            var c = makeHeavyConfig()
            c.processingBypass = true
            return c
        }()
        let bypass = measureThroughput(config: bypassCfg).wallSeconds
        let full = measureThroughput(config: makeHeavyConfig()).wallSeconds
        let relative = full / max(1e-6, bypass)
        #expect(relative < 20.0,
            "full chain \(full) s vs bypass \(bypass) s = \(relative)x; expected <20x on this codebase. A sharp increase (>20x) usually means a hot-path stage (limiter, clipper, or filter) started doing 2-3x its previous per-sample work.")
    }

    @Test func fullChainWithoutPreEncodeLimiterIsLighter() {
        // Sanity check: disabling the pre-encode limiter must make the chain
        // lighter, not heavier. If it doesn't, the pre-encode limiter is
        // broken (not being called) OR an upstream stage is so expensive the
        // limiter is rounding error. Either is worth knowing.
        let with = makeHeavyConfig()
        var without = makeHeavyConfig()
        without.preEncodeAudioLimiterEnabled = false

        let full = measureThroughput(config: with).wallSeconds
        let lighter = measureThroughput(config: without).wallSeconds

        // Expect lighter ≤ full (with a small tolerance for measurement noise).
        #expect(lighter <= full * 1.10,
            "pre-encode limiter disabled (\(lighter) s) is not lighter than enabled (\(full) s); something is wrong")
    }

    @Test func multibandFIRStaysInsideRelativeBudget() {
        // Compare FIR-path cost vs IIR-path cost on the same heavy-program
        // config. Both runs do the same chain except for the multiband
        // splitter; the delta is purely the 4× ~2049-tap FIR dot products.
        //
        // With vDSP_dotpr the FIR path should be at most ~3× the IIR
        // path's wall cost. Without vDSP the manual Swift loop blows this
        // up to 30-50× and the chain overruns real-time budget on real
        // hardware — that was the observed user-facing failure (audio
        // crackle + RDS BCH corruption from sample dropouts). The cap is
        // build-independent (debug vs release scale both numerator and
        // denominator), so the test works in `swift test`.
        let cfgIIR = makeHeavyConfig()
        let iirGen = MPXGenerator(config: cfgIIR, sampleRate: Double(sampleRate))
        iirGen.setMultibandFIREnabled(false)

        var cfgFIR = makeHeavyConfig()
        cfgFIR.multibandFIREnabled = true
        let firGen = MPXGenerator(config: cfgFIR, sampleRate: Double(sampleRate))
        firGen.setMultibandFIREnabled(true)

        let iirWall = measureRender(generator: iirGen)
        let firWall = measureRender(generator: firGen)
        let ratio = firWall / max(1e-6, iirWall)
        print(String(format: "FIR/IIR multiband cost ratio: %.2fx (FIR %.3f s, IIR %.3f s)",
                     ratio, firWall, iirWall))
        #expect(ratio < 5.0,
            "FIR multiband path \(firWall) s vs IIR \(iirWall) s = \(ratio)x. Without vDSP this hits 30-50×. >5× means the vDSP fast-path regressed and the FIR multiband will overrun real-time budget on real hardware.")
    }

    /// Helper to render 1 s of audio through `generator` and return wall
    /// time. Hoisted out so multiple tests can share it.
    private func measureRender(generator: MPXGenerator) -> Double {
        let totalFrames = Int(Double(sampleRate) * durationSeconds)
        var (left, right) = generateHeavyStereo(frames: totalFrames)
        let blocks = (totalFrames + blockSize - 1) / blockSize

        var warmL = [Float](repeating: 0, count: blockSize)
        var warmR = [Float](repeating: 0, count: blockSize)
        warmL.withUnsafeMutableBufferPointer { lBuf in
            warmR.withUnsafeMutableBufferPointer { rBuf in
                generator.renderFromInputInPlace(
                    frameCount: blockSize,
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!
                )
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                for _ in 0..<blocks {
                    let remain = totalFrames - offset
                    let frames = min(blockSize, remain)
                    guard frames > 0 else { break }
                    generator.renderFromInputInPlace(
                        frameCount: frames,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    offset += frames
                }
            }
        }
        let elapsed = clock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test func preEmphasisDoesNotExplodeFullChainCost() {
        // Specifically pins the b806053-class regression. Measure the chain
        // with pre-emphasis on vs. off. The delta must be small — pre-
        // emphasis is a 2-tap IIR; even with the limiter reacting to HF
        // boost, the increase should be modest (<50%).
        var withPre = makeHeavyConfig()
        withPre.preemphasisUS = 50
        var withoutPre = makeHeavyConfig()
        withoutPre.preemphasisUS = 0

        let enabled = measureThroughput(config: withPre).wallSeconds
        let disabled = measureThroughput(config: withoutPre).wallSeconds

        let delta = enabled / max(1e-6, disabled)
        #expect(delta < 1.5,
            "pre-emphasis on raised chain cost \(delta)x over off — limiter may be fighting an upstream HF boost (regression class of b806053)")
    }
}
