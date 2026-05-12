import Testing
@testable import MPXPrime

struct AcceleratedBandlimitedResidualClipperTests {
    @Test func reportsTapCountAndGroupDelay() {
        let clipper = AcceleratedBandlimitedResidualClipper(
            threshold: 0.62,
            tapCount: 64,
            cutoffFraction: 0.20
        )

        #expect(clipper.tapCount == 65)
        #expect(clipper.groupDelaySamples == 32)
        #expect(clipper.enabled)
    }

    @Test func belowThresholdSignalEmergesDelayedButUnchanged() {
        var clipper = AcceleratedBandlimitedResidualClipper(
            threshold: 0.62,
            tapCount: 65,
            cutoffFraction: 0.20
        )
        var output = [Float]()
        let input = [Float](repeating: 0.25, count: 96)
        for sample in input {
            output.append(clipper.process(sample))
        }

        for i in 0..<clipper.groupDelaySamples {
            #expect(output[i] == 0.0)
        }
        for i in clipper.groupDelaySamples..<output.count {
            #expect(abs(output[i] - 0.25) < 1e-6)
        }
    }

    @Test func hardClipReferenceUsesConfiguredThreshold() {
        let clipper = AcceleratedBandlimitedResidualClipper(
            threshold: 0.62,
            tapCount: 65,
            cutoffFraction: 0.20
        )

        #expect(clipper.hardClip(0.9) == 0.62)
        #expect(clipper.hardClip(-0.9) == -0.62)
        #expect(clipper.hardClip(0.3) == 0.3)
    }

    @Test func resetClearsDelayState() {
        var clipper = AcceleratedBandlimitedResidualClipper(
            threshold: 0.62,
            tapCount: 65,
            cutoffFraction: 0.20
        )
        for _ in 0..<96 {
            _ = clipper.process(0.9)
        }

        clipper.reset()
        for _ in 0..<clipper.groupDelaySamples {
            #expect(clipper.process(0.0) == 0.0)
        }
    }
}
