import Foundation
import Testing

@testable import MPXPrime

// RDS text arrives from the GUI, the INI, the REST API and the Now Playing
// script; Unicode-aware sources (Music.app metadata, web CMS exports) carry
// typographic punctuation and sometimes decomposed accents. EN 50067 Annex E
// has none of those, so the coder must fold them to ASCII instead of sending
// "?" -- field report 2026-09-05: a track title's U+2019 apostrophe went on
// air as "?". These tests read the bytes actually put on air (group 2A / 0A).
@Suite struct RDSTextNormalizationTests {

    private func config(rt: String, ps: String = "TEST") -> AppConfig {
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "1234"
        cfg.rdsPSA = ps
        cfg.rdsPSB = ""
        cfg.rdsPSC = ""
        cfg.rdsPSD = ""
        cfg.rdsPSActiveBank = "A"
        cfg.rdsRTText = rt
        cfg.rdsRTMode = "2A"
        cfg.rdsRTBufferAEnabled = false
        cfg.rdsRTBufferBEnabled = false
        cfg.rdsRTBufferCEnabled = false
        cfg.rdsRTBufferDEnabled = false
        return cfg
    }

    private func onAirRT(_ text: String) -> String {
        let coder = BasicRDSCoder(config: config(rt: text), sampleRate: 192_000)
        let groups = (0..<16).map { _ in
            RDSGroupDecoder.decode(coder.buildGroup2(versionB: false))
        }
        return RDSGroupDecoder.reconstructRT(groups: groups, versionB: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func typographicApostrophesAndQuotesFoldToASCII() {
        #expect(onAirRT("Don\u{2019}t Stop Believin\u{2019}") == "Don't Stop Believin'")
        #expect(onAirRT("Rock \u{2018}n\u{2019} Roll") == "Rock 'n' Roll")
        #expect(onAirRT("\u{201C}Heroes\u{201D}") == "\"Heroes\"")
        #expect(onAirRT("Rock\u{02BC}n") == "Rock'n")
    }

    @Test func dashesEllipsisAndTypographicSpacesFold() {
        #expect(onAirRT("Artist \u{2014} Title \u{2013} Live\u{2026}") == "Artist - Title - Live...")
        #expect(onAirRT("A\u{00A0}B\u{2009}C") == "A B C")
        #expect(onAirRT("2\u{00D7}4 \u{00A9} 2026") == "2x4 (c) 2026")
    }

    @Test func decomposedAccentsFoldLikePrecomposedOnes() {
        let composed = onAirRT("Caf\u{00E9} del Mar")
        let decomposed = onAirRT("Cafe\u{0301} del Mar")
        #expect(composed == "Cafe del Mar")
        #expect(decomposed == composed, "NFC must happen before folding; a lone combining mark used to become '?'")
    }

    @Test func unknownScriptKeepsTheVisibleQuestionMark() {
        // No Latin fold exists for CJK; a visible marker beats a silent drop.
        #expect(onAirRT("\u{4E2D}") == "?")
    }

    @Test func psFramesFoldTheSameWay() {
        let coder = BasicRDSCoder(config: config(rt: "x", ps: "L\u{2019}AMOUR"), sampleRate: 192_000)
        let groups = (0..<4).map { _ in
            RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        }
        #expect(RDSGroupDecoder.reconstructPS(groups: groups).trimmingCharacters(in: .whitespaces) == "L'AMOUR")
    }
}
