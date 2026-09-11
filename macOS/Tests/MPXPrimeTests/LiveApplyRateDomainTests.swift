import Testing
import Foundation
@testable import MPXPrime

// Live-apply must configure every stage at the rate that stage actually
// RUNS at. The chain is dual-rate: the audio-domain stages (everything up
// to stereo encoding) run at `dual_rate_audio_domain_rate_hz` (48 kHz by
// default) while the composite side runs at the MPX rate (192 kHz), so a
// stage handed the wrong one has its time constants and corner frequencies
// off by the ratio -- 4x on the default engine format -- until the next
// restart.
//
// Found by the 0.60 chain audit (P0-1): the wideband AGC, the phase
// rotator and the bass clipper took the MPX rate in `applyRuntimeConfig`
// while construction and `setSampleRate` gave them the audio rate. Cold
// start was therefore correct and every offline gate passed; only an
// operator editing one of those controls on a running engine got a
// 4x-wrong stage, and it stayed wrong until the transport was restarted.
//
// The contract these tests pin is restart-equals-live: a generator built
// at configuration A and live-applied to B must render bit-identically to
// a generator built at B. RDS is off in every render -- its text scheduler
// paces by wall clock, so two renders would otherwise diverge on timing
// alone.
@Suite("Live-apply rate domain")
struct LiveApplyRateDomainTests {

    private let sampleRate: Double = 192_000.0
    private let audioRateHz: Double = 48_000.0

    // MARK: - Fixtures

    /// Everything off, dual-rate boundary on. Each test enables exactly the
    /// stage it is about, so a difference can only come from that stage.
    private func baseConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = 1024
        cfg.dualRateAudioDomainEnabled = true
        cfg.dualRateAudioDomainRateHz = audioRateHz
        cfg.processingBypass = false
        cfg.widebandAGCEnabled = false
        cfg.advancedDynamicsEnabled = false
        cfg.multibandEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.downwardExpanderEnabled = false
        cfg.primeBassEnabled = false
        cfg.monoBassEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.hfClipperEnabled = false
        cfg.hfLimiterEnabled = false
        cfg.preEncodeAudioLimiterEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false
        cfg.limitMPX = false
        cfg.enRDS = false
        cfg.preemphasisUS = 0
        return cfg
    }

    /// 80 Hz + 1 kHz two-tone with a level step half way through. The low
    /// tone exercises a bass-band crossover and an all-pass corner, the
    /// step exercises envelope time constants, and the pair makes a
    /// waveform whose samples move when any of the three is misconfigured.
    private func probe(frames: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let wLow = 2.0 * Double.pi * 80.0 / sampleRate
        let wHigh = 2.0 * Double.pi * 1_000.0 / sampleRate
        for i in 0..<frames {
            let amp = i < frames / 2 ? 0.15 : 0.85
            let v = amp * (0.7 * sin(wLow * Double(i)) + 0.3 * sin(wHigh * Double(i)))
            left[i] = Float(v)
            // A little channel asymmetry so a stereo-linked stage cannot
            // hide a fault behind a perfectly correlated pair.
            right[i] = Float(v * 0.85)
        }
        return (left, right)
    }

    private func render(_ generator: MPXGenerator, frames: Int) -> [Float] {
        var (left, right) = probe(frames: frames)
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                let blockSize = 1024
                var offset = 0
                while offset < frames {
                    let chunk = min(blockSize, frames - offset)
                    generator.renderFromInputInPlace(
                        frameCount: chunk,
                        // swiftlint:disable:next force_unwrapping
                        left: lBuf.baseAddress!.advanced(by: offset),
                        // swiftlint:disable:next force_unwrapping
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    offset += chunk
                }
            }
        }
        return left
    }

    /// The contract: build at A, live-apply B, and the result must equal a
    /// generator built at B sample for sample.
    private func expectRestartEqualsLive(
        stage: String,
        from configA: AppConfig,
        to configB: AppConfig,
        seconds: Double = 0.25
    ) {
        let frames = Int(sampleRate * seconds)

        let restarted = MPXGenerator(config: configB, sampleRate: sampleRate)
        let expected = render(restarted, frames: frames)

        let live = MPXGenerator(config: configA, sampleRate: sampleRate)
        live.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: configB))
        let actual = render(live, frames: frames)

        var worst: Float = 0.0
        var worstIndex = -1
        for i in 0..<frames where fabsf(actual[i] - expected[i]) > worst {
            worst = fabsf(actual[i] - expected[i])
            worstIndex = i
        }
        #expect(worst == 0.0,
                """
                \(stage): live-apply did not match a restart at the same \
                configuration -- worst sample delta \(worst) at frame \
                \(worstIndex). A stage configured at the MPX rate while it \
                runs at the audio rate is the usual cause.
                """)
    }

    /// A live-applied change must also be a real change, or the comparison
    /// above would pass on a generator that ignored the edit entirely.
    private func expectTheEditIsAudible(
        stage: String,
        from configA: AppConfig,
        to configB: AppConfig,
        seconds: Double = 0.25
    ) {
        let frames = Int(sampleRate * seconds)
        let a = render(MPXGenerator(config: configA, sampleRate: sampleRate), frames: frames)
        let b = render(MPXGenerator(config: configB, sampleRate: sampleRate), frames: frames)
        var worst: Float = 0.0
        for i in 0..<frames {
            worst = max(worst, fabsf(a[i] - b[i]))
        }
        #expect(worst > 1e-6,
                "\(stage): configurations A and B render the same, so the parity check proves nothing")
    }

    // MARK: - The three stages the audit found

    @Test func widebandAGCTimeConstantsSurviveALiveEdit() {
        var a = baseConfig()
        a.widebandAGCEnabled = true
        a.widebandAGCTargetDB = -12.0
        a.widebandAGCAttackMS = 20.0
        a.widebandAGCReleaseMS = 400.0
        var b = a
        b.widebandAGCAttackMS = 80.0
        b.widebandAGCReleaseMS = 1_200.0
        expectTheEditIsAudible(stage: "Wideband AGC", from: a, to: b)
        expectRestartEqualsLive(stage: "Wideband AGC", from: a, to: b)
    }

    @Test func phaseRotatorCornerSurvivesALiveEdit() {
        var a = baseConfig()
        a.phaseRotationEnabled = true
        a.phaseRotationFreqHz = 100.0
        var b = a
        b.phaseRotationFreqHz = 400.0
        expectTheEditIsAudible(stage: "Phase rotator", from: a, to: b)
        expectRestartEqualsLive(stage: "Phase rotator", from: a, to: b)
    }

    @Test func bassClipperCrossoverSurvivesALiveEdit() {
        var a = baseConfig()
        a.bassClipperEnabled = true
        a.bassClipperCrossoverHz = 120.0
        a.bassClipperThresholdDB = -6.0
        a.bassClipperDrive = 1.5
        var b = a
        b.bassClipperCrossoverHz = 300.0
        expectTheEditIsAudible(stage: "Bass clipper", from: a, to: b)
        expectRestartEqualsLive(stage: "Bass clipper", from: a, to: b)
    }

    // MARK: - Stages fixed earlier, kept as regression cover

    @Test func hfStagesSurviveALiveEdit() {
        var a = baseConfig()
        a.preemphasisUS = 75
        a.hfLimiterEnabled = true
        a.hfLimiterThresholdDB = -6.0
        a.hfLimiterAttackMS = 1.5
        a.hfLimiterReleaseMS = 20.0
        a.hfClipperEnabled = true
        a.hfClipperCrossoverHz = 4_000.0
        a.hfClipperThresholdDB = -4.0
        var b = a
        b.hfLimiterAttackMS = 6.0
        b.hfLimiterReleaseMS = 120.0
        b.hfClipperCrossoverHz = 7_000.0
        expectTheEditIsAudible(stage: "HF limiter + HF clipper", from: a, to: b)
        expectRestartEqualsLive(stage: "HF limiter + HF clipper", from: a, to: b)
    }

    @Test func preEncodeLimiterSurvivesALiveEdit() {
        var a = baseConfig()
        a.preEncodeAudioLimiterEnabled = true
        a.preEncodeThreshold = 0.95
        a.preEncodeReleaseMS = 50.0
        var b = a
        b.preEncodeThreshold = 0.7
        b.preEncodeReleaseMS = 250.0
        expectTheEditIsAudible(stage: "Pre-encode limiter", from: a, to: b)
        expectRestartEqualsLive(stage: "Pre-encode limiter", from: a, to: b)
    }

    // MARK: - The boundary itself

    /// With the dual-rate boundary off, the two rates coincide, so the
    /// parity above must hold for a reason other than "both sites happen
    /// to pass the same value".
    @Test func parityAlsoHoldsWithTheDualRateBoundaryDisabled() {
        var a = baseConfig()
        a.dualRateAudioDomainEnabled = false
        a.widebandAGCEnabled = true
        a.phaseRotationEnabled = true
        a.phaseRotationFreqHz = 100.0
        a.bassClipperEnabled = true
        a.bassClipperCrossoverHz = 120.0
        var b = a
        b.phaseRotationFreqHz = 400.0
        b.bassClipperCrossoverHz = 300.0
        b.widebandAGCAttackMS = 80.0
        expectTheEditIsAudible(stage: "Boundary disabled", from: a, to: b)
        expectRestartEqualsLive(stage: "Boundary disabled", from: a, to: b)
    }
}
