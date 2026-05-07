import Testing
import Foundation
@testable import MPXPrime

// Locks in the PS frame-seconds behavior: explicit `Ns:` / `Nt:` markers
// in PS text override the configured default; the default only applies
// when the source text has no marker. Regression guard for the
// post-0.11 `rds_ps_frame_seconds` config — flagged by an operator who
// asked "when using stereotool style ps use the timing inside that".

@Suite("PS frame seconds default")
struct PSFrameSecondsTests {

    private func parse(_ raw: String, defaultDuration: Double) -> [TimedTextFrame] {
        BasicRDSCoder.parseTimedSequence(
            raw,
            width: 8,
            uppercase: true,
            center: false,
            allowScroll: true,
            defaultDuration: defaultDuration
        )
    }

    @Test func explicitSecondsMarkerOverridesDefault() {
        let seq = parse("3s:NEWS/4s:WEATHER", defaultDuration: 7.0)
        #expect(seq.count == 2)
        #expect(seq[0].duration == 3.0)
        #expect(seq[1].duration == 4.0)
        #expect(seq[0].transmits == 0)
        #expect(seq[1].transmits == 0)
    }

    @Test func explicitTransmitsMarkerOverridesDefault() {
        let seq = parse("3t:NEWS/5t:WEATHER", defaultDuration: 7.0)
        #expect(seq.count == 2)
        #expect(seq[0].transmits == 3)
        #expect(seq[1].transmits == 5)
        #expect(seq[0].duration == 0.0)
        #expect(seq[1].duration == 0.0)
    }

    @Test func inlineMixedMarkersHonorEachExplicit() {
        let seq = parse("2s:HELLO 3t:HI 4s:BYE", defaultDuration: 7.0)
        #expect(seq.count == 3)
        #expect(seq[0].duration == 2.0)
        #expect(seq[1].transmits == 3)
        #expect(seq[2].duration == 4.0)
    }

    @Test func unmarkedMultiChunkUsesConfiguredDefault() {
        // Three 8-char chunks separated by spaces, no Ns: markers.
        let seq = parse("CHUNK001 CHUNK002 CHUNK003", defaultDuration: 4.5)
        // The parser may chunk by width; confirm whatever chunks emerge
        // all share the configured default (not the historical 2.5).
        #expect(seq.count >= 2)
        for frame in seq {
            #expect(frame.duration == 4.5)
        }
    }

    @Test func unmarkedSingleChunkHoldsForTenSeconds() {
        // Single sub-width chunk gets the historical 10 s "hold" duration,
        // not the configured default — this is the empty-PS / static-PS
        // fallback and is intentionally distinct.
        let seq = parse("HELLO", defaultDuration: 4.5)
        #expect(seq.count == 1)
        #expect(seq[0].duration == 10.0)
    }

    @Test func explicitMarkerWithoutNumberFallsBackToDefault() {
        // `s:HELLO` (no leading digits) doesn't match the timing-prefix
        // regex, so the segment is treated as plain text with no marker
        // and falls back to defaultDuration. Lock in that the *configured*
        // default is what's used (not a silent 2.5).
        let seq = parse("s:HELLO/s:WORLD", defaultDuration: 4.5)
        #expect(seq.count == 2)
        for frame in seq {
            #expect(frame.duration == 4.5)
        }
    }
}
