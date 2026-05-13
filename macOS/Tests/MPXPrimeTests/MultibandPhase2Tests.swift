import Testing
import Foundation
@testable import MPXPrime

@Suite("Multiband Phase 2 transient-aware attack")
struct MultibandPhase2Tests {
    private let sampleRate: Float = 192_000.0

    private func configuredCompressor(transientAware: Bool) -> MonoCompressor {
        var compressor = MonoCompressor()
        compressor.configure(
            sampleRate: sampleRate,
            thresholdDB: -24.0,
            ratio: 4.0,
            attackMS: 3.0,
            releaseMS: 180.0,
            makeupDB: 0.0,
            kneeDB: 1.0,
            transientAwareAttackEnabled: transientAware
        )
        return compressor
    }

    @Test func transientAwareAttackLetsPercussiveFrontThrough() {
        var classic = configuredCompressor(transientAware: false)
        var smart = configuredCompressor(transientAware: true)

        // Prime both detectors with a steady over-threshold bed, then
        // hit them with a larger short burst. Phase 2 should avoid
        // chasing that first burst as aggressively as the classic
        // peak detector.
        let bedFrames = Int(sampleRate * 0.120)
        for i in 0..<bedFrames {
            let tone = Float(0.32 * sin(2.0 * Double.pi * 220.0 * Double(i) / Double(sampleRate)))
            _ = classic.process(tone)
            _ = smart.process(tone)
        }

        var classicPeak: Float = 0.0
        var smartPeak: Float = 0.0
        let burstFrames = Int(sampleRate * 0.006)
        for i in 0..<burstFrames {
            let t = Double(i) / Double(sampleRate)
            let env = Float(exp(-t / 0.004))
            let hit = Float(0.95 * sin(2.0 * Double.pi * 110.0 * t)) * env
            classicPeak = max(classicPeak, abs(classic.process(hit)))
            smartPeak = max(smartPeak, abs(smart.process(hit)))
        }

        #expect(smart.transientDriveObserved > 0.10)
        #expect(smartPeak > classicPeak * 1.04)
    }

    @Test func transientAwareAttackConvergesOnSustainedLevel() {
        var classic = configuredCompressor(transientAware: false)
        var smart = configuredCompressor(transientAware: true)

        let frames = Int(sampleRate * 0.500)
        var classicTail: Float = 0.0
        var smartTail: Float = 0.0
        var tailCount: Float = 0.0
        for i in 0..<frames {
            let tone = Float(0.82 * sin(2.0 * Double.pi * 440.0 * Double(i) / Double(sampleRate)))
            let classicOut = abs(classic.process(tone))
            let smartOut = abs(smart.process(tone))
            if i > frames - Int(sampleRate * 0.050) {
                classicTail += classicOut
                smartTail += smartOut
                tailCount += 1.0
            }
        }

        let classicMean = classicTail / max(1.0, tailCount)
        let smartMean = smartTail / max(1.0, tailCount)
        let ratio = smartMean / max(1e-6, classicMean)
        #expect(ratio > 0.85)
        #expect(ratio < 1.20)
    }

    @Test func runtimeConfigCarriesTransientAwareAttackFlag() {
        var config = AppConfig()
        #expect(config.multibandTransientAwareAttackEnabled == false)
        config.multibandTransientAwareAttackEnabled = true

        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        #expect(runtime.multibandTransientAwareAttackEnabled == true)
    }
}
