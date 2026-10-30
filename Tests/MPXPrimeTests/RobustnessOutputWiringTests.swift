import Testing
import Atomics
import Foundation
@testable import MPXPrime

// The output-side decisions both engines take from `OutputWiring`
// (test-suite review 2026-10 finding 10). Every expectation here runs
// the production function; none re-derives its formula. Each was shown to
// fail under a mutation of that function (sign flip, mode gate removed, seed
// removed) in a scratch copy on 2026-10-16.
@Suite("Output wiring")
struct RobustnessOutputWiringTests {

    @Test func theDeviationScaleDividesTheTrimBackOut() {
        // A -7.89 dB exciter trim: the field case (30.2 kHz displayed against
        // about 75 on air). The scale must RAISE the metered peak.
        let scale = OutputWiring.modulationReferenceScale(outputGainDB: -7.89, mode: .mpxComposite)
        #expect(abs(20.0 * log10(Double(scale)) - 7.89) < 1e-4, "scale \(scale) is not +7.89 dB")
        // Full modulation metered post-trim reads 75 kHz again.
        let meteredPeak = powf(10.0, -7.89 / 20.0)
        let kHz = DeviationReadout.kilohertz(compositePeak: meteredPeak, modulationReferenceScale: scale)
        #expect(abs(kHz - 75.0) < 0.01, "full modulation reads \(kHz) kHz")
        #expect(OutputWiring.modulationReferenceScale(outputGainDB: 0.0, mode: .mpxComposite) == 1.0)
    }

    @Test(arguments: [AudioOutputMode.processedAudio, .monitorAudio])
    func theDeviationScaleIsUnityOutsideCompositeMode(mode: AudioOutputMode) {
        #expect(OutputWiring.modulationReferenceScale(outputGainDB: -7.89, mode: mode) == 1.0)
    }

    @Test func theLineTrimAppliesInCompositeMode() {
        let scale = OutputWiring.lineOutputScale(lineOutputDBFS: -6.0, mode: .mpxComposite)
        #expect(abs(20.0 * log10(Double(scale)) + 6.0) < 1e-4, "scale \(scale) is not -6 dB")
        // 0 dBFS is EXACTLY 1.0: the macOS render path skips the multiply on
        // that value, which keeps the default path bit-identical.
        #expect(OutputWiring.lineOutputScale(lineOutputDBFS: 0.0, mode: .mpxComposite) == 1.0)
    }

    @Test(arguments: [AudioOutputMode.processedAudio, .monitorAudio])
    func theLineTrimIsInertOutsideCompositeMode(mode: AudioOutputMode) {
        // The trim calibrates a composite DAC; processed audio feeds an
        // external stereo coder at its own level. Both engines now apply the
        // scale without a mode check of their own, so this IS the gate.
        #expect(OutputWiring.lineOutputScale(lineOutputDBFS: -6.0, mode: mode) == 1.0)
        #expect(OutputWiring.dacPeak(
            compositePeak: 0.8,
            lineOutputScale: OutputWiring.lineOutputScale(lineOutputDBFS: -6.0, mode: mode)) == 0.8)
    }

    @Test func theDACPeakIsTheCompositePeakTimesTheAppliedTrim() {
        let scale = OutputWiring.lineOutputScale(lineOutputDBFS: -3.0, mode: .mpxComposite)
        let peak = OutputWiring.dacPeak(compositePeak: 0.9, lineOutputScale: scale)
        #expect(abs(20.0 * log10(Double(peak / 0.9)) + 3.0) < 1e-4, "DAC Peak \(peak) for 0.9 at -3 dB")
    }

    @Test func theMonitorStartSeedsTheConfiguredLevel() {
        // The atomic starts at unity, as in both players.
        var conditioner = MonitorConditioner()
        let pending = ManagedAtomic<UInt32>(Float(1.0).bitPattern)
        OutputWiring.configureMonitor(
            &conditioner, shape: .flat, sampleRate: 48_000, gainDB: -12.0, pendingGain: pending)
        let seeded = Float(bitPattern: pending.load(ordering: .relaxed))
        #expect(abs(20.0 * log10(Double(seeded)) + 12.0) < 1e-4, "seeded \(seeded), not -12 dB")
        #expect(conditioner.gainLinear == seeded)
    }

    @Test(arguments: [-24.0, -12.0, 0.0, 6.0])
    func aLiveLevelChangePublishesWhatAStartWouldSeed(gainDB: Double) {
        // A live change and a fresh start at the same level must hand the
        // audio thread the same number, or the level steps on the first
        // control change after a start.
        var conditioner = MonitorConditioner()
        let pending = ManagedAtomic<UInt32>(0)
        OutputWiring.configureMonitor(
            &conditioner, shape: .flat, sampleRate: 48_000, gainDB: gainDB, pendingGain: pending)
        #expect(OutputWiring.monitorGainBitPattern(gainDB: gainDB) == pending.load(ordering: .relaxed))
    }
}
