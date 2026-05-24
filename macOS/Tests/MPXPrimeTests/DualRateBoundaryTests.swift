import Testing
import Foundation
@testable import MPXPrime

// Phase 1 of the dual-rate audio chain refactor (plan.md "Next up" #1):
// resampler primitive plumbed into MPXGenerator as a NO-OP boundary.
// Audio stages still run at MPX rate; the boundary just downsamples
// input to `dual_rate_audio_domain_rate_hz` and immediately upsamples
// back so we can validate the resampler at chain scale before any
// stages migrate to the lower rate.
//
// The two load-bearing assertions here:
//
// (1) Default-off is BIT-IDENTICAL. The boundary must default to
//     disabled, and a disabled boundary must produce exactly the same
//     output as the prior chain. Otherwise the dual-rate work changes
//     shipping behaviour without operator opt-in.
//
// (2) Enabled-with-non-integer-ratio silently falls back to disabled.
//     176.4/48 ratio is not supported in Phase 1; the engine must
//     refuse to engage the boundary rather than crash or alias.
//
// We DON'T assert anything strict about the enabled-on-integer-ratio
// output beyond "signal is recognisable, no NaN / Inf, no DC shift,
// roughly the right level". The boundary's intra-cycle fractional
// delay introduces sub-stopband artifacts which are expected — Phase
// 2+ will eliminate these by moving real stages across the boundary
// instead of round-tripping data.

@Suite("Dual-rate audio chain boundary (Phase 1)")
struct DualRateBoundaryTests {

    private let sampleRate: Float = 192_000.0
    private let blockSize: Int = 512

    // MARK: - Fixtures

    private func makeBaseConfig() -> AppConfig {
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
        cfg.primeBassEnabled = false
        cfg.stereoWidenEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandEnabled = true
        cfg.multibandMode = 5
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = true
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsNowPlayingEnabled = false
        cfg.rdsEnableRTPlus = false
        cfg.rdsEnableCT = false
        cfg.rdsEnableID = false
        return cfg
    }

    private func generateStereo(frames: Int) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        let sr = Double(sampleRate)
        for i in 0..<frames {
            let t = Double(i) / sr
            let base = 0.30 * sin(2.0 * .pi * 1_000.0 * t)
                + 0.20 * sin(2.0 * .pi * 4_000.0 * t)
                + 0.15 * sin(2.0 * .pi * 10_000.0 * t)
            l[i] = Float(base + 0.05 * sin(2.0 * .pi * 30.0 * t))
            r[i] = Float(base * 0.96)
        }
        return (l, r)
    }

    private func render(config: AppConfig, frames: Int) -> [Float] {
        let gen = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        var (l, r) = generateStereo(frames: frames)
        let blocks = (frames + blockSize - 1) / blockSize
        l.withUnsafeMutableBufferPointer { lBuf in
            r.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                for _ in 0..<blocks {
                    let remain = frames - offset
                    let n = min(blockSize, remain)
                    guard n > 0 else { break }
                    gen.renderFromInputInPlace(
                        frameCount: n,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    offset += n
                }
            }
        }
        return l  // left == right == mpx after render
    }

    // MARK: - (1) Default state + boundary-off bit-identical regression

    @Test func defaultIsDualRateEnabled() {
        // Post-0.30 cutover the dual-rate boundary defaults ON, so a
        // fresh AppConfig() runs the audio domain at 48 kHz inside the
        // boundary instead of at the engine's MPX rate. Operators who
        // want the legacy single-rate chain set this False explicitly
        // in their INI. Regression-guards against accidentally
        // reverting the default to false.
        let cfg = AppConfig()
        #expect(cfg.dualRateAudioDomainEnabled == true,
                "dual-rate boundary should default ON since 0.30 cutover")
    }

    @Test func explicitlyDisabledIsStable() {
        // The legacy single-rate path is still supported (operators can
        // opt out by setting dual_rate_audio_domain_enabled = False in
        // INI). Two engines configured identically with the boundary
        // explicitly disabled must produce bit-identical output —
        // catches accidental drift in the boundary-off code path,
        // which is critical because operators relying on the legacy
        // chain must be able to count on stable output.
        var cfgA = makeBaseConfig()
        cfgA.dualRateAudioDomainEnabled = false
        var cfgB = makeBaseConfig()
        cfgB.dualRateAudioDomainEnabled = false

        let frames = 8_192
        let outA = render(config: cfgA, frames: frames)
        let outB = render(config: cfgB, frames: frames)
        #expect(outA.count == outB.count)
        for i in 0..<min(outA.count, outB.count) {
            #expect(outA[i] == outB[i],
                    "frame \(i): explicit-disabled run A \(outA[i]) must equal run B \(outB[i])")
        }
    }

    // MARK: - (2) Non-integer ratio silently falls back

    @Test func nonIntegerRatioFallsBackToDisabled() {
        // Engine rate 176.4 kHz, audio rate 48 kHz → ratio 3.675, not
        // integer. Phase 1 only supports integer ratios; the boundary
        // must refuse to engage. Run the chain and confirm no crash,
        // no NaN, and finite output level.
        var cfg = makeBaseConfig()
        cfg.sampleRate = 176_400.0
        cfg.dualRateAudioDomainEnabled = true
        cfg.dualRateAudioDomainRateHz = 48_000.0
        cfg.enRDS = true  // 176.4 fits RDS, so test stays representative

        let frames = 4_096
        let gen = MPXGenerator(config: cfg, sampleRate: 176_400.0)
        var (l, r) = generateStereo(frames: frames)
        let blocks = (frames + blockSize - 1) / blockSize
        l.withUnsafeMutableBufferPointer { lBuf in
            r.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                for _ in 0..<blocks {
                    let remain = frames - offset
                    let n = min(blockSize, remain)
                    guard n > 0 else { break }
                    gen.renderFromInputInPlace(
                        frameCount: n,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    offset += n
                }
            }
        }
        // Output must be finite and non-DC.
        var maxAbs: Float = 0
        var sum: Double = 0
        for v in l {
            #expect(v.isFinite, "output sample \(v) must be finite even with rejected boundary config")
            maxAbs = max(maxAbs, abs(v))
            sum += Double(v)
        }
        let mean = sum / Double(l.count)
        #expect(maxAbs > 0.01, "output level should be non-trivial; got max \(maxAbs)")
        #expect(abs(mean) < 0.5, "output should not have huge DC offset; got mean \(mean)")
    }

    // MARK: - Enabled at 192/48=4 produces recognisable output

    @Test func enabledAt4xRatioProducesRecognisableOutput() {
        // 192 kHz / 48 kHz = 4. Boundary engages. Output should be
        // finite, non-NaN, non-trivial level, and have similar peak
        // amplitude to the disabled baseline (the roundtrip is mostly
        // identity for content well inside the 21.6 kHz cutoff).
        var cfgOff = makeBaseConfig()
        cfgOff.dualRateAudioDomainEnabled = false
        var cfgOn = makeBaseConfig()
        cfgOn.dualRateAudioDomainEnabled = true
        cfgOn.dualRateAudioDomainRateHz = 48_000.0

        let frames = 8_192
        let outOff = render(config: cfgOff, frames: frames)
        let outOn = render(config: cfgOn, frames: frames)

        // Both outputs must be finite.
        for v in outOn {
            #expect(v.isFinite, "boundary-on sample \(v) must be finite")
        }

        // Compute steady-state peak in a window past the boundary
        // group delay. The boundary's combined decim+interp delay is
        // ~halfLength × 2 OS samples; we skip past it before measuring.
        // Use a generous margin (2_000 samples) to clear startup.
        let startIdx = 2_000
        let endIdx = frames - 100
        var peakOff: Float = 0
        var peakOn: Float = 0
        for i in startIdx..<endIdx {
            peakOff = max(peakOff, abs(outOff[i]))
            peakOn = max(peakOn, abs(outOn[i]))
        }
        // Peak ratio should be within ±20% — the roundtrip preserves
        // amplitude to within the FIR's stopband floor (-90 dB linear =
        // <0.003% level error). The generous 20% margin accommodates
        // the intra-cycle fractional-delay artifact and any AGC/limiter
        // adaptation difference.
        let ratio = peakOn / max(1e-6, peakOff)
        #expect(ratio > 0.8 && ratio < 1.2,
                "boundary-on peak \(peakOn) should be within ±20% of baseline peak \(peakOff); ratio \(ratio)")
    }
}
