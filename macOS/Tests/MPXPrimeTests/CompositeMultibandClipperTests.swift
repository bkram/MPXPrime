import Testing
import Foundation
@testable import MPXPrime

@Suite("Composite multiband clipper")
struct CompositeMultibandClipperTests {
    private let sampleRate: Float = 192_000.0

    private func makeChainConfig(multibandClipperEnabled: Bool) -> AppConfig {
        var config = AppConfig()
        config.sampleRate = Double(sampleRate)
        config.sourceMode = "input"
        config.processingBypass = false
        config.widebandAGCEnabled = false
        config.preEncodeAudioLimiterEnabled = true
        config.preEncodeThreshold = 0.90
        config.compositeClipperEnabled = true
        config.compositeClipperThresholdDB = -1.0
        config.compositeClipperCeilingDB = -0.3
        config.compositeClipperCancelStereo = true
        config.compositeClipperCancelPilot = true
        config.compositeClipperCancelRDS = true
        config.compositeClipperLookaheadMS = 0.0
        config.compositeMultibandClipperEnabled = multibandClipperEnabled
        config.limitMPX = true
        config.limitLookaheadEnabled = true
        config.limitLookaheadMS = 5.0
        config.enRDS = true
        config.rdsLevel = 2.0
        return config
    }

    private func renderLeftOnlyMPX(config: AppConfig, toneHz: Float, amplitude: Float, frames: Int) -> [Float] {
        let generator = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        var samples = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let left = amplitude * sinf(2.0 * Float.pi * toneHz * t)
            samples[i] = generator.renderSingleSample(leftIn: left, rightIn: 0.0)
        }
        return samples
    }

    private func renderHFEdgeMetrics(config: AppConfig) -> (
        peak: Float,
        audioPeak: Float,
        postInjectionOvershoot: Float
    ) {
        let generator = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        let frames = Int(sampleRate * 1.2)
        let warmup = Int(sampleRate * 0.4)
        var peak: Float = 0.0
        var audioPeak: Float = 0.0
        var overshoot: Float = 0.0
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let left = 0.92 * sinf(2.0 * Float.pi * 12_000.0 * t)
                + 0.22 * sinf(2.0 * Float.pi * 9_700.0 * t)
            let mpx = generator.renderSingleSample(leftIn: left, rightIn: 0.0)
            if i >= warmup {
                peak = max(peak, fabsf(mpx))
                let calibration = generator.compositeCalibrationStatus
                audioPeak = max(audioPeak, calibration.audioPeak)
                overshoot = max(overshoot, calibration.postInjectionOvershoot)
            }
        }
        return (peak, audioPeak, overshoot)
    }

    @Test func runtimeConfigCarriesCompositeMultibandClipperFlag() {
        var config = AppConfig()
        #expect(config.compositeMultibandClipperEnabled == false)
        config.compositeMultibandClipperEnabled = true

        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        #expect(runtime.compositeMultibandClipperEnabled == true)
    }

    @Test func enabledStageAddsItsGroupDelayToSubcarrierAlignment() {
        var config = AppConfig()
        config.compositeMultibandClipperEnabled = false
        let disabled = MPXGenerator(config: config, sampleRate: Double(sampleRate))
            .subcarrierDelayActiveCount

        config.compositeMultibandClipperEnabled = true
        let enabled = MPXGenerator(config: config, sampleRate: Double(sampleRate))
            .subcarrierDelayActiveCount

        var clipper = CompositeMultibandClipper()
        clipper.configure(sampleRate: sampleRate)
        #expect(enabled - disabled == clipper.groupDelaySamples)
    }

    @Test func belowThresholdSignalReconstructsAfterDelay() {
        var clipper = CompositeMultibandClipper()
        clipper.configure(sampleRate: sampleRate)
        let delay = clipper.groupDelaySamples
        #expect(delay > 0)

        let frames = 8_192
        var input = [Float](repeating: 0.0, count: frames)
        var output = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            input[i] = 0.18 * sinf(2.0 * Float.pi * 90.0 * t)
                + 0.12 * sinf(2.0 * Float.pi * 1_200.0 * t)
                + 0.08 * sinf(2.0 * Float.pi * 9_000.0 * t)
            output[i] = clipper.process(input[i])
        }

        var maxError: Float = 0.0
        for i in (delay + 2_000)..<frames {
            maxError = max(maxError, fabsf(output[i] - input[i - delay]))
        }
        #expect(maxError < 0.015)
    }

    @Test func hotSignalIsFiniteAndPeakReduced() {
        var clipper = CompositeMultibandClipper()
        clipper.configure(sampleRate: sampleRate)

        let frames = 12_000
        var inputPeak: Float = 0.0
        var outputPeak: Float = 0.0
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let x = 1.16 * sinf(2.0 * Float.pi * 85.0 * t)
                + 0.76 * sinf(2.0 * Float.pi * 1_900.0 * t)
                + 0.52 * sinf(2.0 * Float.pi * 12_000.0 * t)
            let y = clipper.process(x)
            if i > clipper.groupDelaySamples + 2_000 {
                inputPeak = max(inputPeak, fabsf(x))
                outputPeak = max(outputPeak, fabsf(y))
            }
            #expect(y.isFinite)
        }

        #expect(outputPeak < inputPeak * 0.92)
    }

    @Test func enabledChainPreservesRawStereoSidebandSymmetry() {
        let toneHz: Float = 10_000.0
        let fftSize = 65_536
        let frames = fftSize * 2
        let analyzer = FFTAnalyzer(fftSize: fftSize)

        let disabled = renderLeftOnlyMPX(
            config: makeChainConfig(multibandClipperEnabled: false),
            toneHz: toneHz,
            amplitude: 0.82,
            frames: frames
        )
        let enabled = renderLeftOnlyMPX(
            config: makeChainConfig(multibandClipperEnabled: true),
            toneHz: toneHz,
            amplitude: 0.82,
            frames: frames
        )

        let disabledReport = analyzer.analyze(Array(disabled.suffix(fftSize)), sampleRate: sampleRate)
        let enabledReport = analyzer.analyze(Array(enabled.suffix(fftSize)), sampleRate: sampleRate)
        let lowerHz = 38_000.0 - toneHz
        let upperHz = 38_000.0 + toneHz
        let disabledAsym = abs(disabledReport.dBFSAt(freqHz: lowerHz) - disabledReport.dBFSAt(freqHz: upperHz))
        let enabledAsym = abs(enabledReport.dBFSAt(freqHz: lowerHz) - enabledReport.dBFSAt(freqHz: upperHz))

        // Contract: the multiband clipper must not ADD material sideband
        // asymmetry over the chain it sits in. The chain's own asymmetry at a
        // 48 kHz upper sideband is ~2 dB since 0.45 (the composite clipper is
        // now actually engaged and its 53 kHz stereo-guard LR4 shapes the
        // sideband edge); before 0.45 the clipper sat idle behind the shaper
        // and the base figure was ~0 dB, which the old absolute 1.5 dB bound
        // pinned. Measured with the engaged clipper: +1.4 dB.
        #expect(enabledAsym <= disabledAsym + 1.5,
                "multiband clipper added \(enabledAsym - disabledAsym) dB sideband asymmetry (base \(disabledAsym) dB)")
        #expect(enabledAsym < 5.0)
    }

    // Regression: a release-build SIGILL crash. configure() used to
    // precondition(lpLow.tapCount == lpMid.tapCount). At a degenerate
    // sample rate (e.g. an output device briefly reporting ~0 Hz on
    // engine restart, floored to 8 kHz) the 4.2 kHz band's Kaiser
    // transition clamps against Nyquist while the 180 Hz band's does
    // not, so the tap counts diverge and the precondition took the whole
    // app down on the main thread (observed on an Intel MBP16,1 running
    // v0.30.2 with mpx_multiband_clipper_enabled = True). configure()
    // must now degrade to pass-through at such rates, never crash.
    @Test(arguments: [Float(0.0), 8_000.0, 11_025.0, 22_050.0, 31_999.0])
    func degenerateRateDegradesToPassThroughInsteadOfCrashing(rate: Float) {
        var clipper = CompositeMultibandClipper()
        clipper.configure(sampleRate: rate)
        // Below the 32 kHz floor the stage disables itself: zero group
        // delay and exact pass-through.
        #expect(clipper.groupDelaySamples == 0)
        for value in [Float(-0.8), -0.1, 0.0, 0.37, 1.25] {
            #expect(clipper.process(value) == value)
        }
    }

    @Test func saneRateConfiguresActiveStageWithMatchedBands() {
        var clipper = CompositeMultibandClipper()
        clipper.configure(sampleRate: 192_000.0)
        #expect(clipper.groupDelaySamples > 0)
        // Reconfiguring down to a degenerate rate and back must not
        // crash and must restore an active stage.
        clipper.configure(sampleRate: 8_000.0)
        #expect(clipper.groupDelaySamples == 0)
        clipper.configure(sampleRate: 96_000.0)
        #expect(clipper.groupDelaySamples > 0)
    }

    @Test func enabledChainReducesHFEdgePeakWithoutBudgetOvershoot() {
        let disabled = renderHFEdgeMetrics(config: makeChainConfig(multibandClipperEnabled: false))
        let enabled = renderHFEdgeMetrics(config: makeChainConfig(multibandClipperEnabled: true))
        let peakDeltaDB = 20.0 * log10f(max(1e-9, enabled.peak) / max(1e-9, disabled.peak))
        let audioPeakDeltaDB = 20.0 * log10f(max(1e-9, enabled.audioPeak) / max(1e-9, disabled.audioPeak))

        #expect(peakDeltaDB < -1.0)
        #expect(audioPeakDeltaDB < -1.0)
        #expect(enabled.postInjectionOvershoot <= 1e-5)
    }
}
