import Foundation
import Testing
@testable import MPXPrime

@Suite("Anti-aliased clipper probe")
struct AntiAliasedClipperProbeTests {
    private static let sampleRate: Float = 48_000.0
    private static let testFreq: Float = 5_111.0
    private static let threshold: Float = 0.62
    private static let ceiling: Float = 0.82
    private static let aliasBinsHz: [Float] = [22_445, 17_334, 12_223, 7_112, 2_000]

    @Test func tanhKneeIsValueAndSlopeContinuousAtThreshold() {
        let eps: Float = 1e-4
        let belowValue = Self.softKnee(Self.threshold - eps)
        let thresholdValue = Self.softKnee(Self.threshold)
        let aboveValue = Self.softKnee(Self.threshold + eps)
        let leftSlope = (thresholdValue - belowValue) / eps
        let rightSlope = (aboveValue - thresholdValue) / eps

        #expect(abs(thresholdValue - Self.threshold) < 1e-6)
        #expect(abs(leftSlope - 1.0) < 2e-3)
        #expect(abs(rightSlope - 1.0) < 2e-3)
    }

    @Test func spectralGateComparesPatentStyleAndCurrentKnees() {
        var hard = ProbeClipper(mode: .hard)
        var blamp = ProbeClipper(mode: .hardWithBLAMP)
        var patentResidual = ProbeClipper(mode: .hardWithPatentResidual)
        var tanh = ProbeClipper(mode: .tanh)

        let hardReport = NonlinearityProbe.runMonoTone(
            block: &hard,
            freqHz: Self.testFreq,
            amplitude: 1.0,
            sampleRate: Self.sampleRate
        )
        let blampReport = NonlinearityProbe.runMonoTone(
            block: &blamp,
            freqHz: Self.testFreq,
            amplitude: 1.0,
            sampleRate: Self.sampleRate
        )
        let patentResidualReport = NonlinearityProbe.runMonoTone(
            block: &patentResidual,
            freqHz: Self.testFreq,
            amplitude: 1.0,
            sampleRate: Self.sampleRate
        )
        let tanhReport = NonlinearityProbe.runMonoTone(
            block: &tanh,
            freqHz: Self.testFreq,
            amplitude: 1.0,
            sampleRate: Self.sampleRate
        )

        let hardAlias = hardReport.sumEnergyDBFS(atBins: Self.aliasBinsHz)
        let blampAlias = blampReport.sumEnergyDBFS(atBins: Self.aliasBinsHz)
        let patentResidualAlias = patentResidualReport.sumEnergyDBFS(atBins: Self.aliasBinsHz)
        let tanhAlias = tanhReport.sumEnergyDBFS(atBins: Self.aliasBinsHz)
        let hardFundamental = hardReport.dBFSAt(freqHz: Self.testFreq)
        let patentResidualFundamental = patentResidualReport.dBFSAt(freqHz: Self.testFreq)

        print(String(format: "[anti-alias gate] hard %.2f dBFS, BLAMP %.2f dBFS, patent-residual %.2f dBFS, tanh %.2f dBFS; fund hard %.2f, patent %.2f",
                     hardAlias, blampAlias, patentResidualAlias, tanhAlias,
                     hardFundamental, patentResidualFundamental))

        #expect(hardAlias.isFinite)
        #expect(blampAlias.isFinite)
        #expect(patentResidualAlias.isFinite)
        #expect(tanhAlias.isFinite)
        #expect(abs(tanhAlias - hardAlias) < 3.0,
                "current tanh knee should remain close to the hard-knee alias baseline on this stress probe")
        #expect(abs(blampAlias - hardAlias) < 1.0,
                "normalized BLAMP candidate should stay near the hard-knee baseline until further tuning proves an improvement")
        #expect(patentResidualAlias < hardAlias - 6.0,
                "patent-style residual bandlimiting should materially reduce hard-knee alias energy before production promotion")
        #expect(abs(patentResidualFundamental - hardFundamental) < 1.0,
                "patent-style residual bandlimiting must preserve wanted fundamental level")
    }

    private static func softKnee(_ x: Float) -> Float {
        let ax = abs(x)
        if ax <= threshold { return x }
        let knee = max(1e-4, ceiling - threshold)
        let clipped = threshold + ((ceiling - threshold) * tanhf((ax - threshold) / knee))
        return copysignf(min(clipped, ceiling), x)
    }

    private struct ProbeClipper: StereoNonlinearity {
        enum Mode {
            case hard
            case hardWithBLAMP
            case hardWithPatentResidual
            case tanh
        }

        var mode: Mode
        private var previousInput: Float = 0.0
        private var previousHardOutput: Float = 0.0
        private var positiveCorrection = BandLimitedStep(windowSamples: 32, cutoffFraction: 0.45)
        private var negativeCorrection = BandLimitedStep(windowSamples: 32, cutoffFraction: 0.45)
        private var hardDelay = [Float](repeating: 0.0, count: 16)
        private var hardDelayIndex = 0
        private var residualClipper = AcceleratedBandlimitedResidualClipper(
            threshold: AntiAliasedClipperProbeTests.threshold,
            tapCount: 65,
            cutoffFraction: 0.20
        )
        private var initialized = false

        init(mode: Mode) {
            self.mode = mode
        }

        mutating func process(left: Float, right: Float) -> (Float, Float) {
            let y = processSample(left)
            return (y, y)
        }

        private mutating func processSample(_ x: Float) -> Float {
            defer {
                previousInput = x
                previousHardOutput = hardClip(x)
                initialized = true
            }

            switch mode {
            case .hard:
                return hardClip(x)
            case .tanh:
                return AntiAliasedClipperProbeTests.softKnee(x)
            case .hardWithBLAMP:
                if initialized {
                    scheduleBLAMPIfNeeded(currentInput: x)
                }
                let delayedHard = hardDelay[hardDelayIndex]
                hardDelay[hardDelayIndex] = hardClip(x)
                hardDelayIndex += 1
                if hardDelayIndex >= hardDelay.count { hardDelayIndex = 0 }
                return delayedHard
                    + positiveCorrection.process(0.0)
                    + negativeCorrection.process(0.0)
            case .hardWithPatentResidual:
                return residualClipper.process(x)
            }
        }

        private mutating func scheduleBLAMPIfNeeded(currentInput x: Float) {
            let currentHard = hardClip(x)
            let inputSlope = x - previousInput
            let outputSlope = currentHard - previousHardOutput
            let slopeDelta = outputSlope - inputSlope
            guard abs(slopeDelta) > 1e-7 else { return }

            if let frac = BandLimitedStep.crossingFraction(
                previous: previousInput,
                current: x,
                threshold: AntiAliasedClipperProbeTests.threshold
            ) {
                positiveCorrection.scheduleRampCorrection(
                    slopeDelta: slopeDelta,
                    fractionalOffset: frac
                )
            }
            if let frac = BandLimitedStep.crossingFraction(
                previous: previousInput,
                current: x,
                threshold: -AntiAliasedClipperProbeTests.threshold
            ) {
                negativeCorrection.scheduleRampCorrection(
                    slopeDelta: slopeDelta,
                    fractionalOffset: frac
                )
            }
        }

        private func hardClip(_ x: Float) -> Float {
            min(AntiAliasedClipperProbeTests.threshold, max(-AntiAliasedClipperProbeTests.threshold, x))
        }
    }
}
