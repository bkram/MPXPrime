import Foundation
import MPXPrimeCore
import Testing

/// The Audio I/O input ladder meters use Prime Mixer's ballistics: instant
/// attack, 24 dB/s fall-back, 1.5 s peak hold, 2 s clip latch.
@Suite("Ladder meter ballistics")
struct LadderMeterBallisticsTests {

    @Test func attackIsInstant() {
        var meter = LadderMeterBallistics()
        let reading = meter.update(peak: 0.5, now: 0, interval: 1.0 / 30.0)
        #expect(abs(reading.peakDBFS - (20 * log10(Float(0.5)))) < 0.01)
        #expect(reading.heldPeakDBFS == reading.peakDBFS)
    }

    @Test func peakFallsBackAt24DBPerSecond() {
        var meter = LadderMeterBallistics()
        meter.update(peak: 1.0 / 2, now: 0, interval: 0.1)
        let start = meter.reading.peakDBFS
        var now = 0.0
        for _ in 0..<10 {
            now += 0.1
            meter.update(peak: 0, now: now, interval: 0.1)
        }
        #expect(abs((start - meter.reading.peakDBFS) - 24) < 0.05, "fell \(start - meter.reading.peakDBFS) dB in 1 s")
    }

    @Test func heldPeakStaysForItsHoldTimeThenFollows() {
        var meter = LadderMeterBallistics()
        meter.update(peak: 0.5, now: 0, interval: 0.1)
        meter.update(peak: 0.01, now: 1.0, interval: 0.1)
        #expect(abs(meter.reading.heldPeakDBFS - (20 * log10(Float(0.5)))) < 0.01, "still held at 1.0 s")
        meter.update(peak: 0.01, now: 1.6, interval: 0.1)
        #expect(abs(meter.reading.heldPeakDBFS - (20 * log10(Float(0.01)))) < 0.01, "released after 1.5 s")
    }

    @Test func clipLatchesForTwoSecondsAtFullScale() {
        var meter = LadderMeterBallistics()
        #expect(!meter.update(peak: 0.99, now: 0, interval: 0.1).clipped)
        #expect(meter.update(peak: 1.0, now: 0.1, interval: 0.1).clipped)
        #expect(meter.update(peak: 0.1, now: 2.0, interval: 0.1).clipped)
        #expect(!meter.update(peak: 0.1, now: 2.2, interval: 0.1).clipped)
    }

    @Test func deviationLatchIgnoresPeaksHeldAtTheLimit() {
        // Fed kHz / limit: the clipper holds the composite at 1.0, which must
        // not light the over-deviation latch; 2 % over does.
        var meter = LadderMeterBallistics(clipThreshold: 1.02)
        #expect(!meter.update(peak: 1.0, now: 0, interval: 0.1).clipped)
        #expect(meter.update(peak: 1.03, now: 0.1, interval: 0.1).clipped)
        meter.reset()
        #expect(!meter.update(peak: 1.0, now: 0.2, interval: 0.1).clipped, "reset keeps the threshold")
    }

    @Test func postGainMeterReadsPreMeterPlusTheGain() {
        // The post meters are fed the same peaks times Input Gain, so below
        // full scale they read exactly that many dB higher.
        var pre = LadderMeterBallistics()
        var post = LadderMeterBallistics()
        let gain = powf(10, 6.0 / 20)
        var now = 0.0
        for peak: Float in [0.1, 0.05, 0.2, 0.02, 0.0] {
            now += 1.0 / 30
            pre.update(peak: peak, now: now, interval: 1.0 / 30)
            post.update(peak: peak * gain, now: now, interval: 1.0 / 30)
            #expect(abs((post.reading.peakDBFS - pre.reading.peakDBFS) - 6) < 0.01)
            #expect(abs((post.reading.heldPeakDBFS - pre.reading.heldPeakDBFS) - 6) < 0.01)
        }
    }

    @Test func nonFiniteAndSilenceReadAsSilent() {
        var meter = LadderMeterBallistics()
        #expect(meter.update(peak: .nan, now: 0, interval: 0.1) == .silent)
        #expect(meter.update(peak: 0, now: 0.1, interval: 0.1).peakDBFS == -.infinity)
        meter.update(peak: 0.5, now: 0.2, interval: 0.1)
        meter.reset()
        #expect(meter.reading == .silent)
    }
}
