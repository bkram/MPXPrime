import Testing
import Foundation
@testable import MPXPrime

// End-to-end tests for BasicRDSCoder.parseTimedSequence — the composed
// pipeline that orchestrates file resolution, escape handling, timing prefix
// parsing, scroll expansion, sanitize, and chunking. The individual
// primitives are covered in RDSTextParserTests; this suite verifies they
// compose correctly under the grammar documented in the README.

@Suite("RDS text orchestration")
struct RDSTextOrchestrationTests {

    // MARK: - Empty / plain

    @Test func emptyInputProducesSingleBlankFrame() {
        let out = BasicRDSCoder.parseTimedSequence(
            "", width: 32, uppercase: false, center: false)
        #expect(out.count == 1)
        #expect(out[0].duration == 10.0)
        #expect(out[0].transmits == 0)
        #expect(out[0].text == String(repeating: " ", count: 32))
    }

    @Test func whitespaceOnlyTreatedAsEmpty() {
        let out = BasicRDSCoder.parseTimedSequence(
            "   \n  ", width: 32, uppercase: false, center: false)
        #expect(out.count == 1)
        #expect(out[0].text == String(repeating: " ", count: 32))
    }

    @Test func plainShortTextGetsTenSecondHold() {
        let out = BasicRDSCoder.parseTimedSequence(
            "Hi", width: 8, uppercase: false, center: false)
        #expect(out.count == 1)
        #expect(out[0].duration == 10.0)
        #expect(out[0].text.hasPrefix("Hi"))
        #expect(out[0].text.count == 8)
    }

    // MARK: - Seconds timing

    @Test func singleSecondsSegment() {
        let out = BasicRDSCoder.parseTimedSequence(
            "10s:Hi", width: 8, uppercase: false, center: false)
        #expect(out.count == 1)
        #expect(out[0].duration == 10.0)
        #expect(out[0].transmits == 0)
    }

    @Test func slashSeparatedSecondsSegments() {
        let out = BasicRDSCoder.parseTimedSequence(
            "5s:Alpha/3s:Beta", width: 8, uppercase: false, center: false)
        #expect(out.count == 2)
        #expect(out[0].duration == 5.0)
        #expect(out[0].text.hasPrefix("Alpha"))
        #expect(out[1].duration == 3.0)
        #expect(out[1].text.hasPrefix("Beta"))
    }

    @Test func fractionalSecondsAccepted() {
        let out = BasicRDSCoder.parseTimedSequence(
            "1.5s:A/2.25s:B", width: 8, uppercase: false, center: false)
        #expect(out.count == 2)
        #expect(abs(out[0].duration - 1.5) < 1e-6)
        #expect(abs(out[1].duration - 2.25) < 1e-6)
    }

    @Test func inlineWhitespaceSeparatedSegments() {
        let out = BasicRDSCoder.parseTimedSequence(
            "1s:First 2s:Second", width: 16, uppercase: false, center: false)
        #expect(out.count == 2)
        #expect(out[0].duration == 1.0)
        #expect(out[1].duration == 2.0)
        #expect(out[0].text.hasPrefix("First"))
        #expect(out[1].text.hasPrefix("Second"))
    }

    // MARK: - Transmits timing

    @Test func singleTransmitsSegment() {
        let out = BasicRDSCoder.parseTimedSequence(
            "3t:Hi", width: 16, uppercase: false, center: false)
        #expect(out.count == 1)
        #expect(out[0].transmits == 3)
        #expect(out[0].duration == 0)
    }

    @Test func mixedSecondsAndTransmits() {
        let out = BasicRDSCoder.parseTimedSequence(
            "5s:Intro/2t:Repeat", width: 16, uppercase: false, center: false)
        #expect(out.count == 2)
        #expect(out[0].duration == 5.0)
        #expect(out[0].transmits == 0)
        #expect(out[1].transmits == 2)
        #expect(out[1].duration == 0)
    }

    // MARK: - Escape handling

    @Test func escapedSpecialsTransmitLiterally() {
        let out = BasicRDSCoder.parseTimedSequence(
            #"10s:\<A\>B\|C\:D"#, width: 16, uppercase: false, center: false)
        #expect(out.count == 1)
        // After decode the text should contain literal specials
        let trimmed = out[0].text.trimmingCharacters(in: .whitespaces)
        #expect(trimmed == "<A>B|C:D")
    }

    @Test func escapedSlashDoesNotSplitSegments() {
        let out = BasicRDSCoder.parseTimedSequence(
            #"10s:One\/Two"#, width: 16, uppercase: false, center: false)
        #expect(out.count == 1)
        let trimmed = out[0].text.trimmingCharacters(in: .whitespaces)
        #expect(trimmed == "One/Two")
    }

    @Test func escapedColonDoesNotFormTimingPrefix() {
        // The leading "Hello\:" starts with letters so it never looked like
        // a timing prefix; but after encodeEscapes "\:" is safely hidden.
        let out = BasicRDSCoder.parseTimedSequence(
            #"Hello\: world"#, width: 32, uppercase: false, center: false)
        #expect(out.count == 1)
        let trimmed = out[0].text.trimmingCharacters(in: .whitespaces)
        #expect(trimmed == "Hello: world")
    }

    // MARK: - Wrap marker

    @Test func wrapMarkerIsNoOp() {
        let out = BasicRDSCoder.parseTimedSequence(
            "10s:||Hello||", width: 16, uppercase: false, center: false)
        let trimmed = out[0].text.trimmingCharacters(in: .whitespaces)
        #expect(trimmed == "Hello")
    }

    // MARK: - Scroll (PS only)

    @Test func scrollDisabledByDefault() {
        // Without allowScroll, "<HI" is treated as literal text.
        let out = BasicRDSCoder.parseTimedSequence(
            "<HI", width: 8, uppercase: true, center: false)
        #expect(out.count == 1)
        let trimmed = out[0].text.trimmingCharacters(in: .whitespaces)
        #expect(trimmed == "<HI")
    }

    @Test func scrollEnabledExpandsToTransmitFrames() {
        let out = BasicRDSCoder.parseTimedSequence(
            "<HELLO", width: 8, uppercase: true, center: false, allowScroll: true)
        #expect(out.count > 1)
        for frame in out {
            #expect(frame.transmits == 1)
            #expect(frame.text.count == 8)
        }
        // First window starts as all blanks (left pad).
        #expect(out[0].text == "        ")
        // Some interior window contains HELLO.
        #expect(out.contains(where: { $0.text.contains("HELLO") }))
    }

    @Test func scrollSpeedControl() {
        let slow = BasicRDSCoder.parseTimedSequence(
            "<HELLO", width: 8, uppercase: true, center: false, allowScroll: true)
        let fast = BasicRDSCoder.parseTimedSequence(
            "<<HELLO", width: 8, uppercase: true, center: false, allowScroll: true)
        #expect(fast.count < slow.count)
    }

    @Test func rightScrollProducesFrames() {
        let out = BasicRDSCoder.parseTimedSequence(
            ">HI", width: 8, uppercase: true, center: false, allowScroll: true)
        #expect(out.count > 1)
        #expect(out.allSatisfy { $0.transmits == 1 && $0.text.count == 8 })
    }

    @Test func escapedScrollMarkerIsLiteral() {
        // \< HI should transmit literal "< HI", not scroll.
        let out = BasicRDSCoder.parseTimedSequence(
            #"\<HI"#, width: 8, uppercase: true, center: false, allowScroll: true)
        // Expect a single static frame, not a scroll sequence of transmits=1 frames.
        #expect(out.count == 1)
        #expect(out[0].transmits == 0)
    }

    // MARK: - Chunking / word-wrap

    @Test func longTextChunksOnWordBoundaries() {
        // 64-char width, supply a long string; should word-wrap into chunks.
        let msg = "This is a longer message intended to exceed eight characters"
        let out = BasicRDSCoder.parseTimedSequence(
            msg, width: 8, uppercase: false, center: false)
        #expect(out.count >= 2)
        for chunk in out {
            #expect(chunk.text.count == 8)
        }
    }

    // MARK: - Uppercase / centering

    @Test func uppercaseFlagAppliedForPS() {
        let out = BasicRDSCoder.parseTimedSequence(
            "hi", width: 8, uppercase: true, center: false)
        #expect(out[0].text.hasPrefix("HI"))
    }

    @Test func centerFlagPadsSymmetrically() {
        let out = BasicRDSCoder.parseTimedSequence(
            "AB", width: 8, uppercase: false, center: true)
        // "AB" in 8 chars, centered: "   AB   " (pad=6, left=3, right=3)
        #expect(out[0].text == "   AB   ")
    }

    // MARK: - containsTimedCommand

    @Test func containsTimedCommandCoversAllForms() {
        #expect(BasicRDSCoder.containsTimedCommand("10s:Hi"))
        #expect(BasicRDSCoder.containsTimedCommand("1.5s:Hi"))
        #expect(BasicRDSCoder.containsTimedCommand("3t:Hi"))
        #expect(BasicRDSCoder.containsTimedCommand("First/5s:Second"))
        #expect(!BasicRDSCoder.containsTimedCommand("plain"))
    }

    // MARK: - parseRTBufferSequence

    @Test func manualBufferWithoutTimingUsesDefaultDuration() {
        let out = BasicRDSCoder.parseRTBufferSequence(
            "Static message", width: 64, center: false, defaultDuration: 8.0)
        #expect(out.count >= 1)
        for frame in out {
            #expect(frame.duration == 8.0)
            #expect(frame.transmits == 0)
        }
    }

    @Test func manualBufferWithExplicitTimingKeepsIt() {
        let out = BasicRDSCoder.parseRTBufferSequence(
            "5s:Alpha/3s:Beta", width: 64, center: false, defaultDuration: 8.0)
        #expect(out.count == 2)
        #expect(out[0].duration == 5.0)
        #expect(out[1].duration == 3.0)
    }

    @Test func manualBufferNormalizesTransmitFramesToDefaultDuration() {
        // Manual RT buffers advance by wall-clock duration-sum, so Nt: frames
        // would break the sum. They get normalized to defaultDuration.
        let out = BasicRDSCoder.parseRTBufferSequence(
            "2t:Repeated/5s:Timed", width: 64, center: false, defaultDuration: 7.5)
        #expect(out.count == 2)
        #expect(out[0].duration == 7.5)
        #expect(out[0].transmits == 0)
        #expect(out[1].duration == 5.0)
    }

    // MARK: - RT 2B width parity

    @Test func rtMode2BWidth32IsChunked() {
        let longish = "Twenty four characters here! And some more text follows."
        let out = BasicRDSCoder.parseTimedSequence(
            longish, width: 32, uppercase: false, center: false)
        for chunk in out {
            #expect(chunk.text.count == 32)
        }
    }
}
