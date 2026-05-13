import Foundation
import Testing
@testable import MPXPrime

struct PreEncodeBandlimitedResidualLimiterTests {
    @Test func runtimeConfigCarriesBandlimitedResidualFlag() {
        var cfg = AppConfig()
        cfg.preEncodeBandlimitedResidualEnabled = true

        let runtime = MPXGenerator.makeRuntimeConfig(from: cfg)

        #expect(runtime.preEncodeBandlimitedResidualEnabled)
        #expect(runtime.preEncodeBandlimitedResidualTapCount == cfg.preEncodeBandlimitedResidualTapCount)
        #expect(runtime.preEncodeBandlimitedResidualCutoffFraction == Float(cfg.preEncodeBandlimitedResidualCutoffFraction))
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

    @Test func newLimiterDoesNotRaiseUpperBandHissAgainstClassicCeiling() {
        var classic = LimiterProbe(bandlimitedResidualEnabled: false)
        var residual = LimiterProbe(bandlimitedResidualEnabled: true)

        let classicReport = Self.runBrightLimiterStress(block: &classic)
        let residualReport = Self.runBrightLimiterStress(block: &residual)

        let fundamentals: [Float] = [6_100.0, 7_300.0, 8_900.0]
        let classicUpperGrain = Self.bandEnergyDBFS(
            classicReport,
            band: 10_000.0...20_000.0,
            excluding: fundamentals,
            exclusionHz: 180.0
        )
        let residualUpperGrain = Self.bandEnergyDBFS(
            residualReport,
            band: 10_000.0...20_000.0,
            excluding: fundamentals,
            exclusionHz: 180.0
        )

        print(String(format: "[preencode-hf-grain] classic %.2f dBFS, residual %.2f dBFS, delta %+.2f dB",
                     classicUpperGrain, residualUpperGrain, residualUpperGrain - classicUpperGrain))

        #expect(classicUpperGrain.isFinite)
        #expect(residualUpperGrain.isFinite)
        #expect(residualUpperGrain < classicUpperGrain + 3.0,
                "new band-limited residual ceiling should not raise 10-20 kHz non-program energy by more than 3 dB vs classic tanh")
    }

    @Test func fullMPXChainResidualCeilingDoesNotRegressMeasuredCompositeMetrics() {
        let classic = Self.renderFullMPXChain(bandlimitedResidualEnabled: false)
        let residual = Self.renderFullMPXChain(bandlimitedResidualEnabled: true)

        let classicMetrics = Self.compositeMetrics(for: classic)
        let residualMetrics = Self.compositeMetrics(for: residual)

        print(String(format: "[preencode-full-chain-ab] peak classic %.4f residual %.4f, upper-grain %.2f/%.2f dBFS, alias %.2f/%.2f dBFS, pilot %.2f/%.2f dBFS, rds %.2f/%.2f dBFS",
                     classicMetrics.peak,
                     residualMetrics.peak,
                     classicMetrics.upperBandGrainDBFS,
                     residualMetrics.upperBandGrainDBFS,
                     classicMetrics.aliasBandDBFS,
                     residualMetrics.aliasBandDBFS,
                     classicMetrics.pilotDBFS,
                     residualMetrics.pilotDBFS,
                     classicMetrics.rdsBandDBFS,
                     residualMetrics.rdsBandDBFS))

        #expect(residualMetrics.peak.isFinite)
        #expect(residualMetrics.peak <= max(1.02, classicMetrics.peak + 0.03),
                "new limiter full-chain MPX peak \(residualMetrics.peak) should not exceed classic \(classicMetrics.peak) by more than 0.03")
        #expect(residualMetrics.upperBandGrainDBFS < classicMetrics.upperBandGrainDBFS + 3.0,
                "new limiter full-chain 10-20 kHz non-program energy \(residualMetrics.upperBandGrainDBFS) dBFS should stay within 3 dB of classic \(classicMetrics.upperBandGrainDBFS) dBFS")
        #expect(residualMetrics.aliasBandDBFS < classicMetrics.aliasBandDBFS + 4.0,
                "new limiter full-chain 60-90 kHz alias/IM energy \(residualMetrics.aliasBandDBFS) dBFS should stay within 4 dB of classic \(classicMetrics.aliasBandDBFS) dBFS")
        #expect(abs(residualMetrics.pilotDBFS - classicMetrics.pilotDBFS) < 0.75,
                "new limiter should not materially move post-injection pilot level: classic \(classicMetrics.pilotDBFS) dBFS, residual \(residualMetrics.pilotDBFS) dBFS")
        #expect(abs(residualMetrics.rdsBandDBFS - classicMetrics.rdsBandDBFS) < 1.5,
                "new limiter should not materially move post-injection RDS-band level: classic \(classicMetrics.rdsBandDBFS) dBFS, residual \(residualMetrics.rdsBandDBFS) dBFS")
    }

    @Test func fullMPXChainDefaultKernelMatchesBoundedSweepCandidate() {
        let priorCandidate = ResidualKernelCandidate(tapCount: 65, cutoffFraction: 0.20)
        let defaultCandidate = ResidualKernelCandidate(tapCount: 33, cutoffFraction: 0.25)
        let prior = Self.renderFullMPXChain(
            bandlimitedResidualEnabled: true,
            residualKernel: priorCandidate
        )
        let defaultKernel = Self.renderFullMPXChain(bandlimitedResidualEnabled: true)

        let priorMetrics = Self.compositeMetrics(for: prior)
        let defaultMetrics = Self.compositeMetrics(for: defaultKernel)

        print(String(format: "[preencode-full-chain-kernel] %@ peak %.4f upper %.2f alias %.2f, %@ peak %.4f upper %.2f alias %.2f",
                     priorCandidate.label,
                     priorMetrics.peak,
                     priorMetrics.upperBandGrainDBFS,
                     priorMetrics.aliasBandDBFS,
                     defaultCandidate.label,
                     defaultMetrics.peak,
                     defaultMetrics.upperBandGrainDBFS,
                     defaultMetrics.aliasBandDBFS))

        #expect(defaultMetrics.peak <= max(1.02, priorMetrics.peak + 0.03),
                "default sweep kernel should not create more full-chain peak than prior kernel")
        #expect(defaultMetrics.aliasBandDBFS < priorMetrics.aliasBandDBFS + 4.0,
                "default sweep kernel should not raise full-chain 60-90 kHz alias/IM energy by more than 4 dB")
        #expect(defaultMetrics.upperBandGrainDBFS < priorMetrics.upperBandGrainDBFS + 4.0,
                "default sweep kernel should not raise full-chain 10-20 kHz non-program energy by more than 4 dB")
    }

    @Test func residualKernelParameterSweepFindsCleanerIsolatedCeilingCandidates() {
        let classic = Self.sweepMetrics(for: CeilingSweepProbe(mode: .classicTanh))
        let candidates = [
            ResidualKernelCandidate(tapCount: 33, cutoffFraction: 0.12),
            ResidualKernelCandidate(tapCount: 33, cutoffFraction: 0.16),
            ResidualKernelCandidate(tapCount: 33, cutoffFraction: 0.20),
            ResidualKernelCandidate(tapCount: 33, cutoffFraction: 0.25),
            ResidualKernelCandidate(tapCount: 65, cutoffFraction: 0.12),
            ResidualKernelCandidate(tapCount: 65, cutoffFraction: 0.16),
            ResidualKernelCandidate(tapCount: 65, cutoffFraction: 0.20),
            ResidualKernelCandidate(tapCount: 65, cutoffFraction: 0.25),
            ResidualKernelCandidate(tapCount: 97, cutoffFraction: 0.12),
            ResidualKernelCandidate(tapCount: 97, cutoffFraction: 0.16),
            ResidualKernelCandidate(tapCount: 97, cutoffFraction: 0.20),
            ResidualKernelCandidate(tapCount: 97, cutoffFraction: 0.25)
        ]
        let measured = candidates.map { candidate in
            Self.sweepMetrics(for: CeilingSweepProbe(mode: .residual(candidate)))
        }.sorted { $0.scoreDB < $1.scoreDB }

        let usable = measured.filter { $0.peak <= 1.02 }
        let best = usable.min { $0.scoreDB < $1.scoreDB } ?? measured[0]
        print(String(format: "[residual-sweep] classic score %.2f dB, upper %.2f dBFS, im %.2f dBFS, peak %.4f",
                     classic.scoreDB, classic.upperBandDBFS, classic.imDBFS, classic.peak))
        for result in measured {
            print(String(format: "[residual-sweep] %@ score %.2f dB, upper %.2f dBFS, im %.2f dBFS, peak %.4f",
                         result.label, result.scoreDB, result.upperBandDBFS, result.imDBFS, result.peak))
        }

        #expect(!usable.isEmpty,
                "sweep should find at least one residual kernel candidate with isolated peak <= 1.02")
        #expect(best.scoreDB < classic.scoreDB - 6.0,
                "best residual kernel \(best.label) score \(best.scoreDB) dB should beat classic tanh score \(classic.scoreDB) dB by at least 6 dB on the isolated ceiling stress")
        #expect(best.peak <= 1.02,
                "best usable residual kernel \(best.label) peak \(best.peak) should remain bounded")
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

    private struct LimiterProbe {
        private var limiter = StereoLinkedOversampledPeakLimiter()

        init(bandlimitedResidualEnabled: Bool, residualKernel: ResidualKernelCandidate? = nil) {
            limiter.configure(
                sampleRate: 48_000,
                threshold: 0.82,
                releaseMS: 45,
                bandlimitedResidualEnabled: bandlimitedResidualEnabled,
                residualTapCount: residualKernel?.tapCount ?? 33,
                residualCutoffFraction: residualKernel?.cutoffFraction ?? 0.25
            )
        }

        mutating func process(_ x: Float) -> Float {
            limiter.process(left: x, right: x).0
        }
    }

    private struct CompositeMetrics {
        let peak: Float
        let upperBandGrainDBFS: Float
        let aliasBandDBFS: Float
        let pilotDBFS: Float
        let rdsBandDBFS: Float
    }

    private struct ResidualKernelCandidate {
        let tapCount: Int
        let cutoffFraction: Float

        var label: String {
            String(format: "residual-%dtap-%.2f", tapCount, cutoffFraction)
        }
    }

    private enum CeilingSweepMode {
        case classicTanh
        case residual(ResidualKernelCandidate)
    }

    private struct CeilingSweepProbe {
        private static let threshold: Float = 0.62
        private static let ceiling: Float = 0.82
        let mode: CeilingSweepMode
        private var residualClipper: AcceleratedBandlimitedResidualClipper?

        init(mode: CeilingSweepMode) {
            self.mode = mode
            switch mode {
            case .classicTanh:
                residualClipper = nil
            case .residual(let candidate):
                residualClipper = AcceleratedBandlimitedResidualClipper(
                    threshold: Self.ceiling,
                    tapCount: candidate.tapCount,
                    cutoffFraction: candidate.cutoffFraction
                )
            }
        }

        var label: String {
            switch mode {
            case .classicTanh:
                return "classic-tanh"
            case .residual(let candidate):
                return candidate.label
            }
        }

        mutating func process(_ x: Float) -> Float {
            switch mode {
            case .classicTanh:
                let ax = fabsf(x)
                if ax <= Self.threshold { return x }
                let knee = max(1e-4, Self.ceiling - Self.threshold)
                let clipped = Self.threshold + ((Self.ceiling - Self.threshold) * tanhf((ax - Self.threshold) / knee))
                return copysignf(min(clipped, Self.ceiling), x)
            case .residual:
                return residualClipper!.process(x)
            }
        }
    }

    private struct SweepMetrics {
        let label: String
        let upperBandDBFS: Float
        let imDBFS: Float
        let peak: Float

        var scoreDB: Float {
            let upperPower = pow(10.0, Double(upperBandDBFS) / 10.0)
            let imPower = pow(10.0, Double(imDBFS) / 10.0)
            let total = upperPower + imPower
            return total > 1e-30 ? Float(10.0 * log10(total)) : -200.0
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

    private static func runBrightLimiterStress(block: inout LimiterProbe) -> SpectralReport {
        let sampleRate: Float = 48_000.0
        let frameCount = 65_536
        let skipTransient = 4_096
        let fftSize = 16_384
        var output = [Float](repeating: 0.0, count: frameCount)

        for i in 0..<frameCount {
            let t = Float(i) / sampleRate
            let x = 0.46 * sinf(2.0 * .pi * 6_100.0 * t)
                + 0.43 * sinf(2.0 * .pi * 7_300.0 * t)
                + 0.39 * sinf(2.0 * .pi * 8_900.0 * t)
            output[i] = block.process(x)
        }

        let analysis = FFTAnalyzer(fftSize: fftSize)
        let steadyState = Array(output[skipTransient..<(skipTransient + fftSize)])
        return analysis.analyze(steadyState, sampleRate: sampleRate)
    }

    private static func sweepMetrics(for probe: CeilingSweepProbe) -> SweepMetrics {
        var block = probe
        let sampleRate: Float = 48_000.0
        let frameCount = 65_536
        let skipTransient = 4_096
        let fftSize = 16_384
        var output = [Float](repeating: 0.0, count: frameCount)

        for i in 0..<frameCount {
            let t = Float(i) / sampleRate
            let x = 0.68 * sinf(2.0 * .pi * 5_111.0 * t)
                + 0.64 * sinf(2.0 * .pi * 7_333.0 * t)
                + 0.21 * sinf(2.0 * .pi * 997.0 * t)
            output[i] = block.process(x)
        }

        let steadyState = Array(output[skipTransient..<(skipTransient + fftSize)])
        let report = FFTAnalyzer(fftSize: fftSize).analyze(steadyState, sampleRate: sampleRate)
        let fundamentals: [Float] = [997.0, 5_111.0, 7_333.0]
        var peak: Float = 0.0
        for sample in steadyState {
            peak = max(peak, abs(sample))
        }
        return SweepMetrics(
            label: block.label,
            upperBandDBFS: bandEnergyDBFS(
                report,
                band: 10_000.0...22_000.0,
                excluding: fundamentals,
                exclusionHz: 180.0
            ),
            imDBFS: report.sumEnergyDBFS(
                atBins: [2_222.0, 4_114.0, 6_108.0, 8_330.0, 11_441.0, 12_444.0, 14_666.0],
                toleranceHz: 60.0
            ),
            peak: peak
        )
    }

    private static func renderFullMPXChain(
        bandlimitedResidualEnabled: Bool,
        residualKernel: ResidualKernelCandidate? = nil
    ) -> [Float] {
        let sampleRate: Float = 192_000.0
        let blockSize = 1_024
        let warmupFrames = 16_384
        let analysisFrames = 65_536
        let totalFrames = warmupFrames + analysisFrames
        var cfg = AppConfig()
        cfg.sampleRate = Double(sampleRate)
        cfg.blockSize = blockSize
        cfg.sourceMode = "input"
        cfg.processingBypass = false
        cfg.preemphasisUS = 50
        cfg.inputGainDB = 4.0
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.preEncodeThreshold = 0.72
        cfg.preEncodeReleaseMS = 45.0
        cfg.preEncodeBandlimitedResidualEnabled = bandlimitedResidualEnabled
        if let residualKernel {
            cfg.preEncodeBandlimitedResidualTapCount = residualKernel.tapCount
            cfg.preEncodeBandlimitedResidualCutoffFraction = Double(residualKernel.cutoffFraction)
        }
        cfg.limitMPX = true
        cfg.limitThreshold = 0.98
        cfg.limitLookaheadMS = 5.0
        cfg.compositeClipperEnabled = true
        cfg.compositeClipperThresholdDB = -1.5
        cfg.compositeClipperCeilingDB = -0.3
        cfg.compositeClipperCancelAudio = false
        cfg.compositeClipperCancelStereo = true
        cfg.compositeClipperCancelPilot = true
        cfg.compositeClipperCancelRDS = true
        cfg.widebandAGCEnabled = false
        cfg.multibandEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.downwardExpanderEnabled = false
        cfg.primeBassEnabled = false
        cfg.stereoWidenEnabled = false
        cfg.monoBassEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.enRDS = true
        cfg.rdsNowPlayingEnabled = false
        cfg.rdsEnableCT = false
        cfg.rdsEnableID = false

        let gen = MPXGenerator(config: cfg, sampleRate: Double(sampleRate))
        var left = [Float](repeating: 0.0, count: totalFrames)
        var right = [Float](repeating: 0.0, count: totalFrames)

        for i in 0..<totalFrames {
            let t = Float(i) / sampleRate
            let bright =
                0.34 * sinf(2.0 * .pi * 6_100.0 * t)
                + 0.31 * sinf(2.0 * .pi * 7_300.0 * t)
                + 0.27 * sinf(2.0 * .pi * 8_900.0 * t)
            let mid = 0.24 * sinf(2.0 * .pi * 1_003.0 * t)
            left[i] = bright + mid
            right[i] = (bright * 0.72) - (0.18 * sinf(2.0 * .pi * 1_337.0 * t))
        }

        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                while offset < totalFrames {
                    let frames = min(blockSize, totalFrames - offset)
                    gen.renderFromInputInPlace(
                        frameCount: frames,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    offset += frames
                }
            }
        }

        return Array(left[warmupFrames..<totalFrames])
    }

    private static func compositeMetrics(for samples: [Float]) -> CompositeMetrics {
        let sampleRate: Float = 192_000.0
        let fftSize = 32_768
        let analysis = FFTAnalyzer(fftSize: fftSize).analyze(samples, sampleRate: sampleRate)
        let programFrequencies: [Float] = [1_003.0, 1_337.0, 6_100.0, 7_300.0, 8_900.0, 19_000.0]
        var peak: Float = 0.0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        return CompositeMetrics(
            peak: peak,
            upperBandGrainDBFS: bandEnergyDBFS(
                analysis,
                band: 10_000.0...20_000.0,
                excluding: programFrequencies,
                exclusionHz: 220.0
            ),
            aliasBandDBFS: bandEnergyDBFS(
                analysis,
                band: 60_000.0...90_000.0,
                excluding: [],
                exclusionHz: 0.0
            ),
            pilotDBFS: analysis.peakDBFS(in: 18_800.0...19_200.0),
            rdsBandDBFS: analysis.peakDBFS(in: 55_600.0...58_400.0)
        )
    }

    private static func bandEnergyDBFS(
        _ report: SpectralReport,
        band: ClosedRange<Float>,
        excluding freqsHz: [Float],
        exclusionHz: Float
    ) -> Float {
        let loBin = max(0, Int((band.lowerBound / report.binWidthHz).rounded()))
        let hiBin = min(report.binCount - 1, Int((band.upperBound / report.binWidthHz).rounded()))
        guard loBin <= hiBin else { return -200.0 }

        var power: Double = 0.0
        for bin in loBin...hiBin {
            let freq = Float(bin) * report.binWidthHz
            var excluded = false
            for f in freqsHz {
                if abs(freq - f) <= exclusionHz {
                    excluded = true
                    break
                }
            }
            if excluded { continue }
            let amp = pow(10.0, Double(report.magnitudesDBFS[bin]) / 20.0)
            power += amp * amp
        }
        let amp = sqrt(power)
        return amp > 1e-30 ? Float(20.0 * log10(amp)) : -200.0
    }
}
