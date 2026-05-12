import Foundation
import Testing
@testable import MPXPrime

struct PreEncodeBandlimitedResidualLimiterTests {
    @Test func runtimeConfigCarriesBandlimitedResidualFlag() {
        var cfg = AppConfig()
        cfg.preEncodeBandlimitedResidualEnabled = true

        let runtime = MPXGenerator.makeRuntimeConfig(from: cfg)

        #expect(runtime.preEncodeBandlimitedResidualEnabled)
    }

    @Test func singleChannelLimiterEnablesBandlimitedResidualCeiling() {
        var limiter = OversampledPeakLimiter()
        limiter.configure(
            sampleRate: 48_000,
            threshold: 0.82,
            releaseMS: 35,
            bandlimitedResidualEnabled: true
        )

        #expect(limiter.bandlimitedResidualEnabled)

        var peak: Float = 0.0
        for i in 0..<8_192 {
            let sample = Float(sinf(2.0 * .pi * 997.0 * Float(i) / 48_000.0)) * 1.6
            let y = limiter.process(sample)
            if i > 512 {
                peak = max(peak, abs(y))
            }
        }

        #expect(peak.isFinite)
        #expect(peak < 1.02)
    }

    @Test func stereoLimiterKeepsSharedGainWithBandlimitedResidualCeiling() {
        var limiter = StereoLinkedOversampledPeakLimiter()
        limiter.configure(
            sampleRate: 48_000,
            threshold: 0.82,
            releaseMS: 80,
            bandlimitedResidualEnabled: true
        )

        var quietRightPeak: Float = 0.0
        var reducedRightPeak: Float = 0.0
        var limitedLeftPeak: Float = 0.0

        for i in 0..<12_000 {
            let phase = 2.0 * Float.pi * 997.0 * Float(i) / 48_000.0
            let s = sinf(phase)
            let (l, r) = limiter.process(left: s * 1.7, right: s * 0.25)
            if i > 4_096 {
                limitedLeftPeak = max(limitedLeftPeak, abs(l))
                reducedRightPeak = max(reducedRightPeak, abs(r))
                quietRightPeak = max(quietRightPeak, abs(s * 0.25))
            }
        }

        #expect(limitedLeftPeak.isFinite)
        #expect(reducedRightPeak.isFinite)
        #expect(limitedLeftPeak < 1.02)
        #expect(reducedRightPeak < quietRightPeak * 0.95)
    }

    @Test func residualClipperKeepsTwoToneIMBoundedAgainstHardClip() {
        var hard = TwoToneClipper(mode: .hard)
        var residual = TwoToneClipper(mode: .residual)

        let hardReport = Self.runTwoTone(block: &hard)
        let residualReport = Self.runTwoTone(block: &residual)

        let imBins: [Float] = [1_111, 3_889, 6_111, 8_889, 13_889, 16_111]
        let hardIM = hardReport.sumEnergyDBFS(atBins: imBins)
        let residualIM = residualReport.sumEnergyDBFS(atBins: imBins)

        #expect(hardIM.isFinite)
        #expect(residualIM.isFinite)
        #expect(residualIM < hardIM + 6.0)
    }

    private enum TwoToneMode {
        case hard
        case residual
    }

    private struct TwoToneClipper {
        var mode: TwoToneMode
        private var residual = AcceleratedBandlimitedResidualClipper(
            threshold: 0.62,
            tapCount: 65,
            cutoffFraction: 0.20
        )

        init(mode: TwoToneMode) {
            self.mode = mode
        }

        mutating func process(_ x: Float) -> Float {
            switch mode {
            case .hard:
                return min(0.62, max(-0.62, x))
            case .residual:
                return residual.process(x)
            }
        }
    }

    private static func runTwoTone(block: inout TwoToneClipper) -> SpectralReport {
        let sampleRate: Float = 48_000.0
        let frameCount = 65_536
        let skipTransient = 4_096
        let fftSize = 16_384
        var output = [Float](repeating: 0.0, count: frameCount)

        for i in 0..<frameCount {
            let t = Float(i) / sampleRate
            let x = 0.72 * sinf(2.0 * .pi * 5_111.0 * t)
                + 0.72 * sinf(2.0 * .pi * 7_333.0 * t)
            output[i] = block.process(x)
        }

        let analysis = FFTAnalyzer(fftSize: fftSize)
        let steadyState = Array(output[skipTransient..<(skipTransient + fftSize)])
        return analysis.analyze(steadyState, sampleRate: sampleRate)
    }
}
