import Testing
import Foundation
@testable import MPXPrime

@Suite("Multiband inter-band coupling")
struct MultibandInterBandCouplingTests {
    private let sampleRate: Float = 192_000.0

    private func configuredCompressor() -> MonoCompressor {
        var compressor = MonoCompressor()
        compressor.configure(
            sampleRate: sampleRate,
            thresholdDB: -18.0,
            ratio: 3.0,
            attackMS: 2.0,
            releaseMS: 160.0,
            makeupDB: 0.0,
            kneeDB: 0.0,
            transientAwareAttackEnabled: false
        )
        return compressor
    }

    @Test func runtimeConfigCarriesInterBandCouplingFlag() {
        var config = AppConfig()
        #expect(config.multibandInterBandCouplingEnabled == false)
        config.multibandInterBandCouplingEnabled = true

        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        #expect(runtime.multibandInterBandCouplingEnabled == true)
    }

    @Test func couplingBiasArithmeticMatchesDesignRatios() {
        let threeBand = MPXGenerator.multibandCouplingBiases(lowGainReductionDB: 6.0)
        #expect(abs(threeBand.mid - -0.90) < 0.001)
        #expect(abs(threeBand.high - -1.50) < 0.001)

        let fiveBand = MPXGenerator.multibandFiveBandCouplingBiases(lowGainReductionDB: 6.0)
        #expect(abs(fiveBand.b2 - -0.60) < 0.001)
        #expect(abs(fiveBand.b3 - -0.90) < 0.001)
        #expect(abs(fiveBand.b4 - -1.32) < 0.001)
        #expect(abs(fiveBand.b5 - -1.50) < 0.001)
    }

    @Test func thresholdBiasIncreasesUpperBandControl() {
        var classic = configuredCompressor()
        var coupled = configuredCompressor()

        let frames = Int(sampleRate * 0.120)
        var classicRMS: Float = 0.0
        var coupledRMS: Float = 0.0
        for i in 0..<frames {
            let tone = Float(0.38 * sin(2.0 * Double.pi * 1600.0 * Double(i) / Double(sampleRate)))
            let classicOut = classic.process(tone)
            let coupledOut = coupled.process(tone, thresholdBiasDB: -1.5)
            if i > frames / 2 {
                classicRMS += classicOut * classicOut
                coupledRMS += coupledOut * coupledOut
            }
        }

        #expect(coupled.lastGainReductionDB < classic.lastGainReductionDB - 0.50)
        #expect(coupledRMS < classicRMS * 0.90)
    }

    @Test func zeroBiasMatchesClassicCompression() {
        var classic = configuredCompressor()
        var biased = configuredCompressor()

        var maxDelta: Float = 0.0
        let frames = Int(sampleRate * 0.080)
        for i in 0..<frames {
            let tone = Float(0.42 * sin(2.0 * Double.pi * 700.0 * Double(i) / Double(sampleRate)))
            let a = classic.process(tone)
            let b = biased.process(tone, thresholdBiasDB: 0.0)
            maxDelta = max(maxDelta, abs(a - b))
        }

        #expect(maxDelta < 1e-6)
    }
}
