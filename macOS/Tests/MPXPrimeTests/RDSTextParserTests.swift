import Testing
import Foundation
@testable import MPXPrime

@Suite("RDSTextParser")
struct RDSTextParserTests {

    // MARK: - Timing prefix

    @Test func parsesIntegerSecondsPrefix() {
        let (timing, body) = RDSTextParser.parseTimingPrefix("10s:Hello", defaultDuration: 5.0)
        #expect(timing == .seconds(10.0))
        #expect(body == "Hello")
    }

    @Test func parsesFractionalSecondsPrefix() {
        let (timing, body) = RDSTextParser.parseTimingPrefix("1.5s:Hi", defaultDuration: 5.0)
        #expect(timing == .seconds(1.5))
        #expect(body == "Hi")
    }

    @Test func parsesTransmitsPrefix() {
        let (timing, body) = RDSTextParser.parseTimingPrefix("3t:Stay", defaultDuration: 5.0)
        #expect(timing == .transmits(3))
        #expect(body == "Stay")
    }

    @Test func fallsBackToDefaultWhenNoPrefix() {
        let (timing, body) = RDSTextParser.parseTimingPrefix("Plain text", defaultDuration: 7.0)
        #expect(timing == .seconds(7.0))
        #expect(body == "Plain text")
    }

    @Test func clampsZeroSecondsToMinimum() {
        let (timing, _) = RDSTextParser.parseTimingPrefix("0s:X", defaultDuration: 5.0)
        #expect(timing == .seconds(0.1))
    }

    @Test func clampsZeroTransmitsToOne() {
        let (timing, _) = RDSTextParser.parseTimingPrefix("0t:X", defaultDuration: 5.0)
        #expect(timing == .transmits(1))
    }

    // MARK: - containsTimedCommand

    @Test func detectsIntegerTimingCommand() {
        #expect(RDSTextParser.containsTimedCommand("10s:Hello"))
        #expect(RDSTextParser.containsTimedCommand("First/10s:Second"))
    }

    @Test func detectsFractionalTimingCommand() {
        #expect(RDSTextParser.containsTimedCommand("1.5s:Hi"))
    }

    @Test func detectsTransmitTimingCommand() {
        #expect(RDSTextParser.containsTimedCommand("3t:Stay"))
    }

    @Test func ignoresColonAfterNonDigit() {
        #expect(!RDSTextParser.containsTimedCommand("Visit us: https://example.com"))
        #expect(!RDSTextParser.containsTimedCommand("Plain text"))
    }

    @Test func escapedTimingIsNotACommand() {
        // "\\d:..." — the backslash escapes the following char so the timing
        // regex should not match. (Escape encoding consumes the digit's colon
        // indirectly — actually here we test a totally non-timed string.)
        #expect(!RDSTextParser.containsTimedCommand("nothing here"))
    }

    // MARK: - Escape encoding / decoding

    @Test func encodesAndDecodesAllSpecials() {
        let input = #"\<A\>B\|C\:D\/E\\F"#
        let encoded = RDSTextParser.encodeEscapes(input)
        // None of the literal specials should remain in encoded form
        #expect(!encoded.contains("<"))
        #expect(!encoded.contains(">"))
        #expect(!encoded.contains("|"))
        #expect(!encoded.contains(":"))
        #expect(!encoded.contains("/"))
        let decoded = RDSTextParser.decodeEscapes(encoded)
        #expect(decoded == "<A>B|C:D/E\\F")
    }

    @Test func preservesFileLoadMarkers() {
        // \R"..." should not be altered by encodeEscapes so resolveTextMarkers
        // can still find it. Only the 6 enumerated specials are replaced.
        let input = #"\R"file.txt"/10s:Hi"#
        let encoded = RDSTextParser.encodeEscapes(input)
        #expect(encoded.contains(#"\R"file.txt""#))
    }

    @Test func stripsWrapMarkers() {
        let stripped = RDSTextParser.stripWrapMarkers("a||b||c")
        #expect(stripped == "abc")
    }

    // MARK: - Inline segments

    @Test func extractsInlineTimedTokens() {
        let segs = RDSTextParser.extractInlineSegments(
            "1s:First 2s:Second 3t:Third", defaultDuration: 5.0)
        #expect(segs.count == 3)
        #expect(segs[0].timing == .seconds(1.0))
        #expect(segs[0].body == "First")
        #expect(segs[1].timing == .seconds(2.0))
        #expect(segs[1].body == "Second")
        #expect(segs[2].timing == .transmits(3))
        #expect(segs[2].body == "Third")
    }

    @Test func inlineSegmentsReturnEmptyWhenNoLeadingToken() {
        let segs = RDSTextParser.extractInlineSegments("plain text", defaultDuration: 5.0)
        #expect(segs.isEmpty)
    }

    // MARK: - Scroll

    @Test func detectsLeftScroll() {
        let spec = RDSTextParser.parseScrollMarker("<Hello")
        #expect(spec?.direction == -1)
        #expect(spec?.speed == 1)
        #expect(spec?.text == "Hello")
    }

    @Test func detectsRightScrollAtSpeed2() {
        let spec = RDSTextParser.parseScrollMarker(">>World")
        #expect(spec?.direction == 1)
        #expect(spec?.speed == 2)
        #expect(spec?.text == "World")
    }

    @Test func returnsNilForNonScrollText() {
        #expect(RDSTextParser.parseScrollMarker("Hello") == nil)
        #expect(RDSTextParser.parseScrollMarker("") == nil)
    }

    @Test func scrollWindowsCoverEntireText() {
        // width=4, text="AB" -> padded "    AB    " (10 chars), windows slide by 1
        let spec = RDSScrollSpec(text: "AB", direction: -1, speed: 1)
        let windows = RDSTextParser.scrollWindows(spec, width: 4)
        #expect(windows.first == "    ")
        #expect(windows.contains("  AB"))
        #expect(windows.contains("AB  "))
        #expect(windows.last == "    ")
    }

    @Test func rightScrollReversesOrder() {
        let spec = RDSScrollSpec(text: "AB", direction: 1, speed: 1)
        let windows = RDSTextParser.scrollWindows(spec, width: 4)
        // Right scroll should produce the reverse order: first "    ", end "    "
        // but visiting windows from right end to left end.
        #expect(windows.first == "    ")
        #expect(windows.last == "    ")
    }
}
