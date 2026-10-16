import Testing
import Foundation
@testable import MPXPrime

// Phase 1 of the dual-rate audio chain refactor (docs/project-roadmap.md "Next up" #1):
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
        // Bit-identity across two renders requires RDS OFF: the RDS text
        // scheduler paces PS/RT by wall clock, so two renders that take
        // different real time can emit different bits (this exact class
        // reddened CompositeShaperOrderingTests on a contended CI runner).
        cfgA.enRDS = false
        cfgB.enRDS = false

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
        // Engine rate 176.4 kHz, audio rate 48 kHz -> ratio 3.675, not
        // integer. Phase 1 only supports integer ratios; the boundary
        // must refuse to engage. "Refuse" means the output IS the
        // boundary-disabled output, sample for sample: the old check
        // (max > 0.01, |mean| < 0.5) was met by the 0.08 pilot alone with
        // the audio fully muted (test-suite review 2026-10
        // finding 13). RDS off: its text scheduler paces by wall clock.
        var requested = makeBaseConfig()
        requested.sampleRate = 176_400.0
        requested.enRDS = false
        requested.dualRateAudioDomainEnabled = true
        requested.dualRateAudioDomainRateHz = 48_000.0
        var disabled = requested
        disabled.dualRateAudioDomainEnabled = false

        let frames = 8_192
        let rejected = renderAt(config: requested, sampleRate: 176_400.0, frames: frames)
        let reference = renderAt(config: disabled, sampleRate: 176_400.0, frames: frames)
        let rejectedFinite = rejected.allSatisfy { $0.isFinite }
        #expect(rejectedFinite, "output must be finite with a rejected boundary config")
        #expect(rejected == reference,
                "a rejected (non-integer) boundary request changed the output: it did not fall back to disabled")
        // And the programme is really there, not just the pilot: a muted
        // chain leaves the 1 kHz bin at numerical noise (< 1e-5); the
        // levelling stages are still settling in 46 ms, so the bound is
        // -30 dB re the 0.3 input tone, not its full level.
        // `generateStereo` synthesises at the suite's 192 kHz, so rendered at
        // 176.4 kHz the "1 kHz" tone is at 918.75 Hz: measure it there. At
        // 1 kHz the projection read a leakage sidelobe that moved with the
        // chain's latency (0.023 before the FIR splitter's tap limit was
        // raised for rates above 96 kHz, 0.006 after, the tone unchanged).
        let toneHz = 1_000.0 * 176_400.0 / Double(sampleRate)
        let level = goertzelAmplitude(rejected, freqHz: toneHz, sampleRate: 176_400.0, start: 2_048)
        print(String(format: "[dual-rate fallback] 1 kHz (918.75 Hz) programme in the composite: %.4f", level))
        #expect(level > 0.01, "1 kHz programme reads \(level) in the composite -- the audio is muted")
    }

    // MARK: - Enabled at 192/48=4 produces recognisable output

    @Test func enabledAt4xRatioProducesRecognisableOutput() {
        // 192 kHz / 48 kHz = 4. Boundary engages. The round trip is
        // identity for content well inside the 21.6 kHz cutoff, so each
        // programme tone must come out at the boundary-off level. Measured
        // per tone (Goertzel) after 0.4 s with every level-dependent stage
        // idle -- AGC / Advanced Dynamics / multiband off, tones at 0.05 --
        // instead of comparing clipper-limited peaks inside the 150 ms AGC
        // attack (test-suite review 2026-10 finding 13).
        var cfgOff = makeBaseConfig()
        cfgOff.enRDS = false
        cfgOff.widebandAGCEnabled = false
        cfgOff.advancedDynamicsEnabled = false
        cfgOff.multibandEnabled = false
        cfgOff.dualRateAudioDomainEnabled = false
        var cfgOn = cfgOff
        cfgOn.dualRateAudioDomainEnabled = true
        cfgOn.dualRateAudioDomainRateHz = 48_000.0

        let frames = Int(0.6 * Double(sampleRate))
        let outOff = renderAt(config: cfgOff, sampleRate: Double(sampleRate), frames: frames, scale: 0.05 / 0.30)
        let outOn = renderAt(config: cfgOn, sampleRate: Double(sampleRate), frames: frames, scale: 0.05 / 0.30)
        let onFinite = outOn.allSatisfy { $0.isFinite }
        #expect(onFinite, "boundary-on output must be finite")
        let start = Int(0.4 * Double(sampleRate))
        for f in [1_000.0, 4_000.0, 10_000.0] {
            let off = goertzelAmplitude(outOff, freqHz: f, sampleRate: Double(sampleRate), start: start)
            let on = goertzelAmplitude(outOn, freqHz: f, sampleRate: Double(sampleRate), start: start)
            let deltaDB = 20.0 * log10(max(on, 1e-12) / max(off, 1e-12))
            #expect(off > 1e-3, "fixture problem: \(Int(f)) Hz reads \(off) with the boundary off")
            #expect(abs(deltaDB) < 0.5,
                    "\(Int(f)) Hz: boundary on reads \(deltaDB) dB against boundary off (on \(on), off \(off))")
        }
    }

    // MARK: - Measurement helpers

    /// `render` at an explicit engine rate, with the programme scaled by
    /// `scale` (1.0 = the fixture's levels).
    private func renderAt(config: AppConfig, sampleRate rate: Double, frames: Int, scale: Float = 1.0) -> [Float] {
        let gen = MPXGenerator(config: config, sampleRate: rate)
        var (l, r) = generateStereo(frames: frames)
        if scale != 1.0 {
            for i in 0..<frames { l[i] *= scale; r[i] *= scale }
        }
        l.withUnsafeMutableBufferPointer { lBuf in
            r.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                while offset < frames {
                    let n = min(blockSize, frames - offset)
                    gen.renderFromInputInPlace(
                        frameCount: n,
                        // swiftlint:disable force_unwrapping
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                        // swiftlint:enable force_unwrapping
                    )
                    offset += n
                }
            }
        }
        return l
    }

    /// Amplitude of `freqHz` in `x[start...]` (projection onto sin/cos).
    private func goertzelAmplitude(_ x: [Float], freqHz: Double, sampleRate rate: Double, start: Int) -> Double {
        let w = 2.0 * Double.pi * freqHz / rate
        var s = 0.0, c = 0.0
        for i in start..<x.count {
            s += Double(x[i]) * sin(w * Double(i))
            c += Double(x[i]) * cos(w * Double(i))
        }
        return 2.0 * hypot(s, c) / Double(x.count - start)
    }
}
