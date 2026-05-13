import Testing
import Foundation
@testable import MPXPrime

@Suite("Composite multiband clipper")
struct CompositeMultibandClipperTests {
    private let sampleRate: Float = 192_000.0

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
}
