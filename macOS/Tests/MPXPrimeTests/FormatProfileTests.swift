// macOS-only: exercises the SwiftUI view model, which the Linux CLI build excludes.
#if os(macOS)

import Testing
import Foundation
@testable import MPXPrime

// Format Profile is the top-level "Station Format" picker — one selection
// atomically applies multiband + final-stage + PrimeBass + stereo widener
// + composite-clipper settings appropriate to the chosen format. These
// tests pin the contract: each profile resolves to a known per-stage
// preset ID, the apply path actually mutates the expected config fields,
// and the default profile produces a config equivalent to the prior
// shipping default (so the rename to "Community Radio" is not a
// behavioural change at first install).
//
// MPXPrimeViewModel is @MainActor-isolated; mark the whole suite so test
// bodies can call its static catalogue and instance methods without ad
// hoc `await MainActor.run` plumbing.

@Suite("Format Profile")
@MainActor
struct FormatProfileTests {

    /// Build a viewmodel pointed at a throwaway INI path so save attempts
    /// during apply don't clobber the user's real config. The path
    /// doesn't need to exist; load failures fall back to defaults inside
    /// the VM init.
    private func makeViewModel() -> MPXPrimeViewModel {
        let tempPath = NSTemporaryDirectory()
            + "MPXPrime-FormatProfileTests-\(UUID().uuidString).ini"
        return MPXPrimeViewModel(configPath: tempPath)
    }

    // MARK: - Catalogue integrity

    @Test func everyProfileHasUniqueID() {
        let ids = MPXPrimeViewModel.formatProfiles.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count,
            "duplicate format profile IDs: \(ids)")
    }

    @Test func defaultProfileExists() {
        let appConfig = AppConfig()
        let profile = MPXPrimeViewModel.formatProfile(forID: appConfig.formatProfileID)
        #expect(profile != nil,
            "default formatProfileID `\(appConfig.formatProfileID)` doesn't match any profile")
    }

    @Test func everyProfileReferencesKnownPerStagePresets() {
        // Each format profile delegates to four per-stage preset IDs.
        // If a profile names a preset that doesn't exist, the apply path
        // silently no-ops on that stage — caller sees inconsistent state.
        // Catch typos at compile/test time.
        let knownMultiband: Set<String> = [
            "5_ac", "5_chr", "5_rock", "5_classic", "5_talk", "5_urban",
            "5_dance", "5_italo", "5_news", "5_jazz", "5_oldies",
            "3_chr", "3_rock", "3_ac", "3_country", "3_talk", "3_urban",
            "3_dance", "3_italo", "3_news", "3_jazz", "3_classic",
        ]
        let knownFinalStage: Set<String> = ["balanced", "chr", "punchy", "speech"]
        let knownPrimeBass: Set<String> = ["chr", "urban", "rock", "ac", "talk"]
        let knownWidener: Set<String> = ["safe_fm", "open_music", "wide_chr"]

        for profile in MPXPrimeViewModel.formatProfiles {
            #expect(knownMultiband.contains(profile.multibandPresetID),
                "profile `\(profile.id)` references unknown multiband preset `\(profile.multibandPresetID)`")
            #expect(knownFinalStage.contains(profile.finalStagePresetID),
                "profile `\(profile.id)` references unknown final-stage preset `\(profile.finalStagePresetID)`")
            #expect(knownPrimeBass.contains(profile.primeBassPresetID),
                "profile `\(profile.id)` references unknown PrimeBass preset `\(profile.primeBassPresetID)`")
            #expect(knownWidener.contains(profile.widenerPresetID),
                "profile `\(profile.id)` references unknown widener preset `\(profile.widenerPresetID)`")
        }
    }

    // MARK: - Apply path

    @Test func applyMusicLoudProfileSetsExpectedFields() {
        let model = makeViewModel()
        model.applyFormatProfile("music_loud")

        #expect(model.config.formatProfileID == "music_loud")
        #expect(model.config.multibandPresetID == "5_chr")
        #expect(model.config.multibandIntensity == "normal")
        #expect(model.config.finalStagePresetID == "chr")
        #expect(model.config.primeBassEnabled == true)
        #expect(model.config.primeBassPresetID == "chr")
        #expect(model.config.stereoWidenEnabled == true)  // wide_chr has stereoWidenEnabled = true
        #expect(abs(model.config.compositeClipperThresholdDB - (-0.8)) < 1e-6)
        #expect(abs(model.config.compositeClipperCeilingDB - (-0.2)) < 1e-6)
        #expect(abs(model.config.finalDriveDB - 8.0) < 1e-6)
        // HF control is the gain-riding HF limiter, not the HF clipper: the
        // clipper cost 17 dB of decoded HF SINAD on hats (--verify-hf-transients).
        #expect(model.config.hfLimiterEnabled == true)
        #expect(model.config.hfClipperEnabled == false)
    }

    @Test func profilesOwnTheFullGainStructure() {
        // The 2026-08 rework contract: NO profile may leave the safety
        // soft-clips as the de-facto peak controller. Every profile turns
        // the AGC, the pre-encode limiter, the composite clipper, and the
        // final safety limiter on -- from any prior state.
        let model = makeViewModel()
        for id in ["music_clean", "music_loud", "speech", "classical_wide"] {
            model.config.widebandAGCEnabled = false
            model.config.preEncodeAudioLimiterEnabled = false
            model.config.limitMPX = false
            model.config.compositeClipperEnabled = false
            model.applyFormatProfile(id)
            #expect(model.config.widebandAGCEnabled, "\(id): AGC must be on")
            #expect(model.config.preEncodeAudioLimiterEnabled, "\(id): limiter must be on")
            #expect(model.config.limitMPX, "\(id): safety limiter must be on")
            #expect(model.config.compositeClipperEnabled, "\(id): composite clipper must be on")
            #expect(model.config.compositeClipperLookaheadMS > 1.0, "\(id): clipper look-ahead expected")
        }
    }

    @Test func applyClassicalWideProfilePreservesDynamics() {
        let model = makeViewModel()
        model.applyFormatProfile("classical_wide")

        #expect(model.config.formatProfileID == "classical_wide")
        #expect(model.config.multibandPresetID == "5_classic")
        #expect(model.config.multibandIntensity == "light")
        #expect(model.config.primeBassEnabled == false)
        #expect(abs(model.config.widebandAGCTargetDB - (-18.0)) < 1e-6)
        #expect(abs(model.config.finalDriveDB - 3.0) < 1e-6)
    }

    @Test func applySpeechProfileDisablesPrimeBassAndUsesSpeechFinalStage() {
        let model = makeViewModel()
        // Pre-condition: turn PrimeBass on first so we can prove the
        // profile turned it off.
        model.config.primeBassEnabled = true
        model.applyFormatProfile("speech")

        #expect(model.config.formatProfileID == "speech")
        #expect(model.config.phaseRotationEnabled == true, "speech profile enables the phase rotator")
        #expect(model.config.multibandPresetID == "5_talk")
        #expect(model.config.multibandIntensity == "light")
        #expect(model.config.finalStagePresetID == "speech")
        #expect(model.config.primeBassEnabled == false,
            "speech profile must disable PrimeBass")
        #expect(model.config.stereoWidenEnabled == false)  // safe_fm has stereoWidenEnabled = false
        #expect(abs(model.config.finalDriveDB - 4.5) < 1e-6)
    }

    // MARK: - Default profile (music_clean)

    @Test func defaultProfileMatchesShippingDefaults() {
        // The music_clean profile should produce a chain state in the
        // same ballpark as a fresh `AppConfig` for the headline knobs.
        let fresh = AppConfig()
        let model = makeViewModel()
        model.applyFormatProfile("music_clean")

        #expect(model.config.multibandPresetID == fresh.multibandPresetID,
            "default profile multiband ID drifted from AppConfig default")
        #expect(model.config.finalStagePresetID == fresh.finalStagePresetID,
            "default profile final-stage ID drifted from AppConfig default")
        // PrimeBass off in both
        #expect(model.config.primeBassEnabled == fresh.primeBassEnabled,
            "default profile PrimeBass-enabled drifted from AppConfig default")
    }

    // MARK: - Custom profile (sentinel — no settings changes)

    @Test func customProfileDoesNotChangePerStageSettings() {
        let model = makeViewModel()
        // Apply Music - Loud first so we have a known non-default state.
        model.applyFormatProfile("music_loud")
        let snapshotMultiband = model.config.multibandPresetID
        let snapshotIntensity = model.config.multibandIntensity
        let snapshotFinalStage = model.config.finalStagePresetID
        let snapshotPrimeBassEnabled = model.config.primeBassEnabled
        let snapshotPrimeBassID = model.config.primeBassPresetID
        let snapshotWidenEnabled = model.config.stereoWidenEnabled
        let snapshotClipperThreshold = model.config.compositeClipperThresholdDB
        let snapshotClipperCeiling = model.config.compositeClipperCeilingDB
        let snapshotFinalDrive = model.config.finalDriveDB

        // Picking Custom must change ONLY the formatProfileID label.
        model.applyFormatProfile("custom")

        #expect(model.config.formatProfileID == "custom",
            "Custom selection must record the label")
        #expect(model.config.multibandPresetID == snapshotMultiband)
        #expect(model.config.multibandIntensity == snapshotIntensity)
        #expect(model.config.finalStagePresetID == snapshotFinalStage)
        #expect(model.config.primeBassEnabled == snapshotPrimeBassEnabled)
        #expect(model.config.primeBassPresetID == snapshotPrimeBassID)
        #expect(model.config.stereoWidenEnabled == snapshotWidenEnabled)
        #expect(abs(model.config.compositeClipperThresholdDB - snapshotClipperThreshold) < 1e-9)
        #expect(abs(model.config.compositeClipperCeilingDB - snapshotClipperCeiling) < 1e-9)
        #expect(abs(model.config.finalDriveDB - snapshotFinalDrive) < 1e-9)
    }

    @Test func customProfileIsListedInCatalogue() {
        let custom = MPXPrimeViewModel.formatProfile(forID: "custom")
        #expect(custom != nil, "Custom profile must exist in the catalogue")
        #expect(custom?.title == "Custom")
    }

    // MARK: - Unknown ID handling

    @Test func unknownProfileIsNoOp() {
        let model = makeViewModel()
        let beforeFormat = model.config.formatProfileID
        let beforeMultiband = model.config.multibandPresetID
        let beforeFinalStage = model.config.finalStagePresetID

        model.applyFormatProfile("nonsense_format_that_does_not_exist")

        #expect(model.config.formatProfileID == beforeFormat,
            "unknown profile ID must not change formatProfileID")
        #expect(model.config.multibandPresetID == beforeMultiband,
            "unknown profile ID must not touch multiband")
        #expect(model.config.finalStagePresetID == beforeFinalStage,
            "unknown profile ID must not touch final stage")
    }

    // MARK: - INI round-trip

    @Test func iniRoundTripPreservesFormatProfileID() throws {
        let tempPath = NSTemporaryDirectory()
            + "MPXPrime-FormatProfile-roundtrip-\(UUID().uuidString).ini"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        var cfg = AppConfig()
        cfg.formatProfileID = "music_loud"
        try cfg.save(toINI: tempPath)

        let loaded = try AppConfig.load(fromINI: tempPath)
        #expect(loaded.formatProfileID == "music_loud")
    }

    // MARK: - Summary helper

    @Test func currentFormatProfileSummaryMatchesSelection() {
        let model = makeViewModel()
        model.applyFormatProfile("speech")
        let expected = MPXPrimeViewModel.formatProfile(forID: "speech")!.summary
        #expect(model.currentFormatProfileSummary == expected)
    }

    @Test func currentFormatProfileSummaryFallsBackForUnknownID() {
        let model = makeViewModel()
        model.config.formatProfileID = "garbage_unknown_value"
        #expect(model.currentFormatProfileSummary.contains("Custom"))
    }
}

#endif  // os(macOS)
