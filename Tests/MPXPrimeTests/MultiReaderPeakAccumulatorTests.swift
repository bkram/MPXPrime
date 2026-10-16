import Foundation
import Testing

@testable import MPXPrimeCore

// Peak-since-last-read per meter consumer (MultiReaderPeakAccumulator), the
// type both engines publish their meter peaks through. Two bugs it fixes:
// on macOS the GUI tick and the web meter stream shared ONE pending peak and
// each read cleared it, so whichever read second missed what the other had
// taken; on Linux the ALSA engine OVERWROTE its published peak every period,
// so a 20 Hz reader saw one period in ten. Pure and headless.
@Suite struct MultiReaderPeakAccumulatorTests {
    @Test func twoInterleavedReadersBothSeeThePeak() {
        let acc = MultiReaderPeakAccumulator(channels: 2)
        let gui = MeterPeakReader.make()
        let stream = MeterPeakReader.make()
        // Both readers have read once (claims their slots).
        _ = acc.take(gui, now: 0)
        _ = acc.take(stream, now: 0)

        acc.record(channel: 0, peak: 0.8)
        let guiRead = acc.take(gui, now: 0.03)
        // The GUI's read must not clear the stream's pending peak.
        let streamRead = acc.take(stream, now: 0.05)
        #expect(guiRead.peaks[0] == 0.8)
        #expect(streamRead.peaks[0] == 0.8)

        // And the other way round, with the reads interleaved between writes.
        acc.record(channel: 1, peak: 0.3)
        #expect(acc.take(stream, now: 0.1).peaks[1] == 0.3)
        acc.record(channel: 1, peak: 0.2)
        #expect(acc.take(gui, now: 0.12).peaks[1] == 0.3, "the GUI keeps the larger, older peak")
        #expect(acc.take(stream, now: 0.15).peaks[1] == 0.2)
    }

    @Test func aPeakIsHeldUntilTheReaderTakesItNotOverwritten() {
        // The ALSA bug: a loud period followed by quiet ones must still read
        // loud on the next take.
        let acc = MultiReaderPeakAccumulator(channels: 1)
        let reader = MeterPeakReader.make()
        _ = acc.take(reader, now: 0)
        acc.record(channel: 0, peak: 0.9)
        for _ in 0..<10 { acc.record(channel: 0, peak: 0.1) }
        #expect(acc.take(reader, now: 0.05).peaks[0] == 0.9)
        // Taken: the next read sees only what arrived since.
        #expect(acc.take(reader, now: 0.1).peaks[0] == 0.0)
        acc.record(channel: 0, peak: 0.4)
        #expect(acc.take(reader, now: 0.15).peaks[0] == 0.4)
    }

    @Test func aReaderStartsFromItsFirstReadAndIsToldItsSlotIsFresh() {
        let acc = MultiReaderPeakAccumulator(channels: 1)
        acc.record(channel: 0, peak: 0.7)
        let late = MeterPeakReader.make()
        let first = acc.take(late, now: 0)
        #expect(first.claimedNow)
        #expect(first.peaks[0] == 0.0, "nothing from before the reader existed")
        let second = acc.take(late, now: 0.1)
        #expect(!second.claimedNow)
        #expect(second.slot == first.slot)
    }

    @Test func theSharedReaderAlwaysAccumulates() {
        let acc = MultiReaderPeakAccumulator(channels: 1)
        acc.record(channel: 0, peak: 0.6)
        let take = acc.take(.shared, now: 0)
        #expect(take.slot == 0)
        #expect(take.peaks[0] == 0.6)
    }

    @Test func nonFiniteAndNonPositiveValuesAreIgnored() {
        let acc = MultiReaderPeakAccumulator(channels: 1)
        acc.record(channel: 0, peak: 0.25)
        acc.record(channel: 0, peak: .nan)
        acc.record(channel: 0, peak: .infinity)
        acc.record(channel: 0, peak: -2)
        acc.record(channel: 5, peak: 1)  // out of range: ignored, no trap
        #expect(acc.take(.shared, now: 0).peaks[0] == 0.25)
    }

    @Test func slotsAreReusedAfterIdleOrReleaseAndOverflowFallsBackToShared() {
        let acc = MultiReaderPeakAccumulator(channels: 1, slots: 3, idleEvictionSeconds: 10)
        let a = MeterPeakReader.make()
        let b = MeterPeakReader.make()
        let c = MeterPeakReader.make()
        #expect(acc.take(a, now: 0).slot == 1)
        #expect(acc.take(b, now: 0).slot == 2)
        // Full and nobody idle: c degrades to the shared slot.
        #expect(acc.take(c, now: 1).slot == 0)
        // a idle for 10 s: c takes its slot, starting fresh.
        _ = acc.take(b, now: 10.5)
        let reclaimed = acc.take(c, now: 11)
        #expect(reclaimed.slot == 1)
        #expect(reclaimed.claimedNow)
        // An explicit release frees a slot at once.
        acc.release(b)
        let d = MeterPeakReader.make()
        #expect(acc.take(d, now: 11.1).slot == 2)
    }

    @Test func resetClearsEveryReader() {
        let acc = MultiReaderPeakAccumulator(channels: 1)
        let r = MeterPeakReader.make()
        _ = acc.take(r, now: 0)
        acc.record(channel: 0, peak: 0.5)
        acc.reset()
        #expect(acc.take(r, now: 0.1).peaks[0] == 0.0)
        #expect(acc.take(.shared, now: 0.1).peaks[0] == 0.0)
    }

    @Test func concurrentWritesNeverLoseTheMaximum() async {
        // One writer thread folding a ramp, the reader taking concurrently:
        // the maximum of everything written must appear in exactly the union
        // of the takes (lossless exchange, compare-exchange fold).
        let acc = MultiReaderPeakAccumulator(channels: 1)
        let reader = MeterPeakReader.make()
        _ = acc.take(reader, now: 0)
        let writes = 20_000
        let writer = Task.detached {
            for i in 1...writes {
                acc.record(channel: 0, peak: Float(i) / Float(writes))
            }
        }
        var seen: Float = 0
        for _ in 0..<200 {
            seen = max(seen, acc.take(reader, now: 0.1).peaks[0])
            await Task.yield()
        }
        await writer.value
        seen = max(seen, acc.take(reader, now: 0.2).peaks[0])
        #expect(seen == 1.0)
    }
}
