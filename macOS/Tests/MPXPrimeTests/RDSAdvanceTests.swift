import Testing
import Foundation
@testable import MPXPrime

// Tests the sequence-advance decision logic used by buildGroup0 (PS),
// buildGroup2 (RT), buildGroup10A (PTYN), and buildGroup15A (LPS). The
// advance helper distinguishes wall-clock (seconds) timing from transmit-count
// timing; both were added when Stereotool-compatible Nt: support landed.

@Suite("RDS sequence advance")
struct RDSAdvanceTests {

    // MARK: - Seconds mode

    @Test func secondsModeDoesNotAdvanceBeforeDeadline() {
        let frame = TimedTextFrame(duration: 10.0, text: "A")
        let now = 100.0
        let start = 95.0  // 5 seconds elapsed
        let advance = BasicRDSCoder.shouldAdvanceSequence(
            frame, seqStart: start, transmits: 0, now: now)
        #expect(advance == false)
    }

    @Test func secondsModeAdvancesOnceDeadlineReached() {
        let frame = TimedTextFrame(duration: 10.0, text: "A")
        let now = 110.0
        let start = 100.0  // exactly 10 seconds elapsed
        let advance = BasicRDSCoder.shouldAdvanceSequence(
            frame, seqStart: start, transmits: 0, now: now)
        #expect(advance == true)
    }

    @Test func secondsModeIgnoresTransmitCounter() {
        // Transmit counter is meaningless in seconds mode; a large count
        // must not force an advance before the time deadline.
        let frame = TimedTextFrame(duration: 10.0, text: "A")
        let advance = BasicRDSCoder.shouldAdvanceSequence(
            frame, seqStart: 100.0, transmits: 9999, now: 101.0)
        #expect(advance == false)
    }

    // MARK: - Transmits mode

    @Test func transmitsModeDoesNotAdvanceBelowThreshold() {
        let frame = TimedTextFrame(transmits: 3, text: "A")
        let advance = BasicRDSCoder.shouldAdvanceSequence(
            frame, seqStart: 100.0, transmits: 2, now: 100.001)
        #expect(advance == false)
    }

    @Test func transmitsModeAdvancesAtThreshold() {
        let frame = TimedTextFrame(transmits: 3, text: "A")
        let advance = BasicRDSCoder.shouldAdvanceSequence(
            frame, seqStart: 100.0, transmits: 3, now: 100.001)
        #expect(advance == true)
    }

    @Test func transmitsModeIgnoresWallClock() {
        // Wall-clock never triggers an advance in transmits mode, regardless
        // of elapsed time.
        let frame = TimedTextFrame(transmits: 5, text: "A")
        let advance = BasicRDSCoder.shouldAdvanceSequence(
            frame, seqStart: 0.0, transmits: 0, now: 1_000_000.0)
        #expect(advance == false)
    }

    @Test func transmitsModeAdvancesWhenCounterExceedsThreshold() {
        // Safety: if we ever miss the exact boundary (due to reset timing)
        // the "greater than" case must still advance.
        let frame = TimedTextFrame(transmits: 2, text: "A")
        let advance = BasicRDSCoder.shouldAdvanceSequence(
            frame, seqStart: 0.0, transmits: 5, now: 0.0)
        #expect(advance == true)
    }

    // MARK: - TimedTextFrame shape

    @Test func durationInitProducesSecondsFrame() {
        let frame = TimedTextFrame(duration: 5.0, text: "Hi")
        #expect(frame.duration == 5.0)
        #expect(frame.transmits == 0)
    }

    @Test func transmitsInitProducesTransmitsFrame() {
        let frame = TimedTextFrame(transmits: 4, text: "Hi")
        #expect(frame.duration == 0)
        #expect(frame.transmits == 4)
    }

    @Test func transmitsInitClampsToAtLeastOne() {
        let frame = TimedTextFrame(transmits: 0, text: "Hi")
        #expect(frame.transmits == 1)
    }
}
