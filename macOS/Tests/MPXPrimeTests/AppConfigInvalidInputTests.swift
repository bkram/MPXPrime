import Testing
import Foundation
@testable import MPXPrime

// AppConfig INI parsing must degrade gracefully when keys hold garbage —
// never crash, never silently produce out-of-range numerics. The on-disk
// config is operator-edited, so a stray typo or copy-paste from a different
// processor shouldn't brick the engine. Verifies the type-coercion helpers
// (string / int / double / bool) all fall back to defaults on bad input.

@Suite("AppConfig invalid input")
struct AppConfigInvalidInputTests {

    private func write(_ contents: String, suffix: String = "ini") throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir
            .appendingPathComponent("mpxprime-invalid-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
            .path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func unreadableFileThrows() {
        let bogus = "/var/empty/does-not-exist-\(UUID().uuidString).ini"
        #expect(throws: INIParserError.self) {
            _ = try AppConfig.load(fromINI: bogus)
        }
    }

    @Test func emptyINIYieldsAllDefaults() throws {
        let path = try write("")
        defer { cleanup(path) }
        let cfg = try AppConfig.load(fromINI: path)
        let baseline = AppConfig()
        #expect(cfg.sampleRate == baseline.sampleRate)
        #expect(cfg.preemphasisUS == baseline.preemphasisUS)
        #expect(cfg.processingBypass == baseline.processingBypass)
        #expect(cfg.compositeClipperEnabled == baseline.compositeClipperEnabled)
    }

    @Test func garbageNumericFallsBackToDefault() throws {
        let ini = """
        [INTERFACES]
        sample_rate = banana

        [MPX]
        preemphasis_us = forty
        input_gain_db = not-a-number
        mpx_deviation_khz = abc

        [RDS]
        rds_level = xyz
        ps_frame_seconds = oops
        """
        let path = try write(ini)
        defer { cleanup(path) }
        let cfg = try AppConfig.load(fromINI: path)
        let baseline = AppConfig()
        #expect(cfg.sampleRate == baseline.sampleRate)
        #expect(cfg.preemphasisUS == baseline.preemphasisUS)
        #expect(cfg.inputGainDB == baseline.inputGainDB)
        #expect(cfg.mpxDeviationKHz == baseline.mpxDeviationKHz)
        #expect(cfg.rdsLevel == baseline.rdsLevel)
        #expect(cfg.rdsPSFrameSeconds == baseline.rdsPSFrameSeconds)
    }

    @Test func boolSynonymsAllRecognised() throws {
        // "yes"/"on"/"true"/"1" must parse as true; "no"/"off"/"false"/"0"
        // must parse as false. Stereotool / Optimod operators have varied
        // INI conventions and a fresh-eyes user often writes "yes".
        let pairs: [(String, Bool)] = [
            ("True", true), ("true", true), ("YES", true), ("yes", true),
            ("on", true), ("1", true),
            ("False", false), ("false", false), ("NO", false), ("no", false),
            ("off", false), ("0", false),
        ]
        for (raw, expected) in pairs {
            let ini = """
            [MPX]
            processing_bypass = \(raw)
            """
            let path = try write(ini)
            defer { cleanup(path) }
            let cfg = try AppConfig.load(fromINI: path)
            #expect(cfg.processingBypass == expected,
                "processing_bypass = \(raw) should parse as \(expected)")
        }
    }

    @Test func garbageBoolFallsBackToDefault() throws {
        let ini = """
        [MPX]
        processing_bypass = maybe

        [RDS]
        en_rds = sometimes
        """
        let path = try write(ini)
        defer { cleanup(path) }
        let cfg = try AppConfig.load(fromINI: path)
        let baseline = AppConfig()
        #expect(cfg.processingBypass == baseline.processingBypass)
        #expect(cfg.enRDS == baseline.enRDS)
    }

    @Test func emptyValueFallsBackToDefault() throws {
        let ini = """
        [INTERFACES]
        sample_rate =

        [MPX]
        preemphasis_us =
        """
        let path = try write(ini)
        defer { cleanup(path) }
        let cfg = try AppConfig.load(fromINI: path)
        let baseline = AppConfig()
        #expect(cfg.sampleRate == baseline.sampleRate)
        #expect(cfg.preemphasisUS == baseline.preemphasisUS)
    }

    @Test func inlineCommentStrippedFromValue() throws {
        // INIParser strips `; comment` from the value — verify a numeric
        // field with a trailing comment still parses to the leading number,
        // not falls back as if it were garbage.
        let ini = """
        [MPX]
        preemphasis_us = 75 ; US/Canada/Korea
        """
        let path = try write(ini)
        defer { cleanup(path) }
        let cfg = try AppConfig.load(fromINI: path)
        #expect(cfg.preemphasisUS == 75)
    }

    @Test func unknownSectionsAndKeysIgnored() throws {
        // Keys we don't recognise must not throw, and unrelated keys must
        // not pollute the parsed config.
        let ini = """
        [INTERFACES]
        sample_rate = 192000

        [futuristic]
        warp_drive = on

        [MPX]
        unknown_key = nonsense
        """
        let path = try write(ini)
        defer { cleanup(path) }
        let cfg = try AppConfig.load(fromINI: path)
        #expect(cfg.sampleRate == 192000)
    }
}
