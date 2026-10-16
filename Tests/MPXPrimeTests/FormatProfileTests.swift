// macOS-only: exercises the SwiftUI view model, which the Linux CLI build excludes.
#if os(macOS)

import Testing
import Foundation
@testable import MPXPrime

// Format Profile is the top-level "Station Format" picker — one selection
// atomically applies multiband + final-stage + PrimeBass + mono bass
// + composite-clipper + peak-stage + EQ settings appropriate to the chosen
// format. These tests pin the contract: each profile resolves to a known
// per-stage preset ID, the apply path actually mutates the expected config
// fields, every profile owns the full gain structure (and switches the
// Advanced Dynamics leveler off), and the default profile IS the fresh
// `AppConfig()` key for key (2026-10 format-profile review).
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
        return MPXPrimeViewModel(configPath: tempPath, deviceLister: { [] })
    }

    /// Every shipped profile except the Custom sentinel, from the catalogue
    /// (so a new profile is covered the day it is added).
    private var shippedProfiles: [PresetCatalog.FormatProfile] {
        PresetCatalog.formatProfiles.filter { $0.id != "custom" }
    }

    /// The HF limiter rule (the HF limiter review, finding 2): the main
    /// threshold sits 0.5 dB above the profile's pre-encode limiter
    /// threshold, rounded to 0.1 dB; the top-octave threshold 1 dB under that.
    private func expectedHFThreshold(forPreEncode threshold: Double) -> Double {
        ((20.0 * log10(threshold) + 0.5) * 10.0).rounded() / 10.0
    }

    // MARK: - Catalogue integrity

    @Test func everyProfileHasUniqueID() {
        let ids = MPXPrimeViewModel.formatProfiles.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count,
            "duplicate format profile IDs: \(ids)")
    }

    @Test func catalogueListsTheShippedProfilesInOrder() {
        // The GUI picker, the dashboard picker and /api/presets all derive
        // from this list; the order is the order the operator sees.
        #expect(PresetCatalog.formatProfiles.map(\.id)
            == ["custom", "music_clean", "music_loud", "music_dense", "speech", "classical_wide"])
    }

    @Test func defaultProfileExists() {
        let appConfig = AppConfig()
        let profile = MPXPrimeViewModel.formatProfile(forID: appConfig.formatProfileID)
        #expect(profile != nil,
            "default formatProfileID `\(appConfig.formatProfileID)` doesn't match any profile")
    }

    @Test func everyProfileReferencesKnownPerStagePresets() {
        // Each format profile delegates to per-stage preset IDs. If a
        // profile names a preset that doesn't exist, the apply path
        // silently no-ops on that stage — caller sees inconsistent state.
        let knownMultiband = Set(PresetCatalog.multibandPresets.map(\.id))
        let knownFinalStage = Set(PresetCatalog.finalStagePresets.map(\.id))
        let knownPrimeBass = Set(PresetCatalog.primeBassPresets.map(\.id))
        #expect(knownFinalStage.contains("classical"), "the classical final-stage preset must exist")

        for profile in MPXPrimeViewModel.formatProfiles {
            #expect(knownMultiband.contains(profile.multibandPresetID),
                "profile `\(profile.id)` references unknown multiband preset `\(profile.multibandPresetID)`")
            #expect(knownFinalStage.contains(profile.finalStagePresetID),
                "profile `\(profile.id)` references unknown final-stage preset `\(profile.finalStagePresetID)`")
            #expect(knownPrimeBass.contains(profile.primeBassPresetID),
                "profile `\(profile.id)` references unknown PrimeBass preset `\(profile.primeBassPresetID)`")
            #expect((60.0...250.0).contains(profile.monoBassFreqHz),
                "profile `\(profile.id)` mono-bass crossover \(profile.monoBassFreqHz) Hz is outside the clamp")
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
        #expect(abs(model.config.widebandAGCTargetDB - (-15.0)) < 1e-6)
        #expect(model.config.primeBassEnabled == true)
        #expect(model.config.primeBassPresetID == "chr")
        #expect(model.config.monoBassEnabled == true)
        #expect(abs(model.config.monoBassFreqHz - 115.0) < 1e-6)  // loud profile: mono below 115 Hz
        #expect(abs(model.config.compositeClipperThresholdDB - (-0.8)) < 1e-6)
        #expect(abs(model.config.compositeClipperCeilingDB - (-0.2)) < 1e-6)
        #expect(abs(model.config.finalDriveDB - 8.0) < 1e-6)
        // HF control is the gain-riding HF limiter, 0.5 dB above the profile's
        // pre-encode threshold (0.85 -> -0.9 dB), top octave 1 dB under that.
        #expect(model.config.hfLimiterEnabled == true)
        #expect(abs(model.config.hfLimiterThresholdDB - (-0.9)) < 1e-6)
        #expect(abs(model.config.hfLimiterTopThresholdDB - (-1.9)) < 1e-6)
        // 2026-10 review: spectral shaping and density. +1.5 dB low shelf at
        // 80 Hz, +1.0 dB presence at 3 kHz Q 1, bands 2 and 4 flat; band
        // limiter on at -3 dB, 0.5 / 50 ms.
        #expect(model.config.parametricEQEnabled == true)
        #expect(abs(model.config.peqB1FreqHz - 80.0) < 1e-6)
        #expect(abs(model.config.peqB1GainDB - 1.5) < 1e-6)
        #expect(abs(model.config.peqB2GainDB) < 1e-6)
        #expect(abs(model.config.peqB3FreqHz - 3000.0) < 1e-6)
        #expect(abs(model.config.peqB3GainDB - 1.0) < 1e-6)
        #expect(abs(model.config.peqB3Q - 1.0) < 1e-6)
        #expect(abs(model.config.peqB4GainDB) < 1e-6)
        #expect(model.config.multibandLimiterEnabled == true)
        #expect(abs(model.config.multibandLimiterThresholdDB - (-3.0)) < 1e-6)
        #expect(abs(model.config.multibandLimiterAttackMS - 0.5) < 1e-6)
        #expect(abs(model.config.multibandLimiterReleaseMS - 50.0) < 1e-6)
        #expect(model.config.bassClipperEnabled == true)
    }

    @Test func applyMusicDenseProfileSetsExpectedFields() {
        // The top density tier (2026-10 review): dance multiband at heavy
        // intensity, CHR final stage, 9 dB of drive into a -0.6 / -0.2
        // composite clipper, every peak stage on, no EQ, no phase rotation.
        let model = makeViewModel()
        model.config.phaseRotationEnabled = true
        model.config.advancedDynamicsEnabled = true
        model.applyFormatProfile("music_dense")

        #expect(model.config.formatProfileID == "music_dense")
        #expect(model.config.multibandPresetID == "5_dance")
        #expect(model.config.multibandIntensity == "heavy")
        // 5_dance heavy: -24 - 1.5 dB, 2.5 x 1.12, 16 x 0.88 ms, 285 x 0.9 ms.
        #expect(abs(model.config.multibandLowThresholdDB - (-25.5)) < 1e-6)
        #expect(abs(model.config.multibandLowRatio - 2.8) < 1e-6)
        #expect(abs(model.config.multibandLowAttackMS - 14.08) < 1e-6)
        #expect(abs(model.config.multibandLowReleaseMS - 256.5) < 1e-6)
        #expect(model.config.finalStagePresetID == "chr")
        #expect(model.config.widebandAGCEnabled == true)
        #expect(abs(model.config.widebandAGCTargetDB - (-15.0)) < 1e-6)
        #expect(model.config.primeBassEnabled == true)
        #expect(model.config.primeBassPresetID == "chr")
        #expect(model.config.monoBassEnabled == true)
        #expect(abs(model.config.monoBassFreqHz - 110.0) < 1e-6)
        #expect(model.config.compositeClipperEnabled == true)
        #expect(abs(model.config.compositeClipperThresholdDB - (-0.6)) < 1e-6)
        #expect(abs(model.config.compositeClipperCeilingDB - (-0.2)) < 1e-6)
        #expect(abs(model.config.compositeClipperLookaheadMS - 2.0) < 1e-6)
        #expect(abs(model.config.finalDriveDB - 9.0) < 1e-6)
        #expect(model.config.preEncodeAudioLimiterEnabled == true)
        #expect(abs(model.config.preEncodeThreshold - 0.85) < 1e-6)
        #expect(model.config.limitMPX == true)
        #expect(model.config.hfLimiterEnabled == true)
        #expect(abs(model.config.hfLimiterThresholdDB - (-0.9)) < 1e-6)
        #expect(abs(model.config.hfLimiterTopThresholdDB - (-1.9)) < 1e-6)
        #expect(model.config.bassClipperEnabled == true)
        #expect(model.config.multibandLimiterEnabled == true)
        #expect(model.config.parametricEQEnabled == false)
        #expect(model.config.phaseRotationEnabled == false)
        #expect(model.config.advancedDynamicsEnabled == true)
    }

    @Test func profilesOwnTheFullGainStructure() {
        // The 2026-08 rework contract: NO profile may leave the safety
        // soft-clips as the de-facto peak controller. Every profile turns
        // the AGC, the pre-encode limiter, the composite clipper, and the
        // final safety limiter on -- from any prior state. 2026-10-15: every
        // profile levels with Advanced Dynamics (target = the profile's AGC
        // target, density from its multiband intensity), lands the AGC target its final-stage
        // preset names, and fans the HF limiter thresholds out from its
        // pre-encode threshold (+0.5 dB, top octave 1 dB tighter).
        let model = makeViewModel()
        for profile in shippedProfiles {
            let id = profile.id
            model.config.widebandAGCEnabled = false
            model.config.preEncodeAudioLimiterEnabled = false
            model.config.limitMPX = false
            model.config.compositeClipperEnabled = false
            model.config.advancedDynamicsEnabled = false
            model.config.advancedDynamicsTargetDB = -30.0
            model.config.widebandAGCTargetDB = -30.0
            model.applyFormatProfile(id)
            #expect(model.config.widebandAGCEnabled, "\(id): AGC must be on")
            #expect(model.config.preEncodeAudioLimiterEnabled, "\(id): limiter must be on")
            #expect(model.config.limitMPX, "\(id): safety limiter must be on")
            #expect(model.config.compositeClipperEnabled, "\(id): composite clipper must be on")
            #expect(model.config.compositeClipperLookaheadMS > 1.0, "\(id): clipper look-ahead expected")
            #expect(model.config.advancedDynamicsEnabled,
                "\(id): every profile levels with Advanced Dynamics")
            #expect(model.config.advancedDynamicsTargetDB == model.config.widebandAGCTargetDB - 2.0,
                "\(id): the leveller target is the profile's AGC target less 2 dB (loudness parity with the classic chain)")
            #expect(model.config.advancedDynamicsDensity == profile.multibandIntensity.levelerDensity,
                "\(id): the leveller density follows the profile's intensity")

            let finalStage = PresetCatalog.finalStagePresets.first(where: { $0.id == profile.finalStagePresetID })
            #expect(finalStage != nil, "\(id): final-stage preset \(profile.finalStagePresetID) missing")
            #expect(abs(model.config.widebandAGCTargetDB - (finalStage?.agcTargetDB ?? .nan)) < 1e-9,
                "\(id): AGC target \(model.config.widebandAGCTargetDB) must be the final-stage preset's \(finalStage?.agcTargetDB ?? .nan)")
            #expect(abs(profile.agcTargetDB - model.config.widebandAGCTargetDB) < 1e-9,
                "\(id): FormatProfile.agcTargetDB must report what the apply lands on")

            let expectedHF = expectedHFThreshold(forPreEncode: profile.preEncodeThreshold)
            #expect(model.config.hfLimiterEnabled, "\(id): HF limiter must be on")
            #expect(abs(model.config.hfLimiterThresholdDB - expectedHF) < 1e-9,
                "\(id): HF threshold \(model.config.hfLimiterThresholdDB) should be pre-encode + 0.5 dB = \(expectedHF)")
            #expect(abs(model.config.hfLimiterTopThresholdDB - (expectedHF - 1.0)) < 1e-9,
                "\(id): HF top threshold must be 1 dB under the main one")

            // The peak-stage knobs a profile owns are written at the shipped
            // values whether the stage is on or off.
            #expect(abs(model.config.bassClipperThresholdDB - (-3.0)) < 1e-9, "\(id): bass clipper threshold")
            #expect(abs(model.config.bassClipperCrossoverHz - 150.0) < 1e-9, "\(id): bass clipper crossover")
            #expect(abs(model.config.bassClipperDrive - 1.5) < 1e-9, "\(id): bass clipper drive")
            #expect(abs(model.config.multibandLimiterThresholdDB - (-3.0)) < 1e-9, "\(id): band limiter threshold")
            #expect(abs(model.config.multibandLimiterAttackMS - 0.5) < 1e-9, "\(id): band limiter attack")
            #expect(abs(model.config.multibandLimiterReleaseMS - 50.0) < 1e-9, "\(id): band limiter release")
        }
    }

    @Test func applyClassicalWideProfilePreservesDynamics() {
        let model = makeViewModel()
        model.applyFormatProfile("classical_wide")

        #expect(model.config.formatProfileID == "classical_wide")
        #expect(model.config.multibandPresetID == "5_classic")
        #expect(model.config.multibandIntensity == "light")
        #expect(model.config.finalStagePresetID == "classical")
        #expect(model.config.primeBassEnabled == false)
        #expect(abs(model.config.widebandAGCTargetDB - (-18.0)) < 1e-6)
        #expect(abs(model.config.finalDriveDB - 3.0) < 1e-6)
        // 2026-10 review, finding 3: orchestral LF space is not folded to
        // mono above 90 Hz on the purist profile.
        #expect(abs(model.config.monoBassFreqHz - 90.0) < 1e-6)
        #expect(model.config.bassClipperEnabled == false)
        #expect(model.config.parametricEQEnabled == false)
        #expect(model.config.multibandLimiterEnabled == false)
    }

    @Test func classicalAGCMaxLiftIsSixDecibels() {
        // A gentle 2:1-style ride, no pianissimo lift (Orban CLASSICAL runs
        // the AGC near 0 dB gain reduction; BBC classical distribution keeps
        // an LRA of 15 LU): 6 dB of lift, 12 dB of cut, 200 ms / 3 s.
        var config = AppConfig()
        _ = PresetCatalog.applyFormatProfile(id: "classical_wide", to: &config)
        #expect(abs(config.widebandAGCMaxGainDB - 6.0) < 1e-9,
            "classical AGC max lift must be 6 dB; got \(config.widebandAGCMaxGainDB)")
        #expect(abs(config.widebandAGCMinGainDB - (-12.0)) < 1e-9)
        #expect(abs(config.widebandAGCAttackMS - 200.0) < 1e-9)
        #expect(abs(config.widebandAGCReleaseMS - 3000.0) < 1e-9)

        let preset = PresetCatalog.finalStagePresets.first(where: { $0.id == "classical" })
        #expect(abs((preset?.agcMaxGainDB ?? .nan) - 6.0) < 1e-9)
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
        #expect(model.config.multibandIntensity == "normal")
        #expect(model.config.finalStagePresetID == "speech")
        // Finding 2: the speech final stage's -14 dB target is honoured, not
        // overridden to -16 by the profile.
        #expect(abs(model.config.widebandAGCTargetDB - (-14.0)) < 1e-6)
        #expect(model.config.primeBassEnabled == false,
            "speech profile must disable PrimeBass")
        #expect(abs(model.config.monoBassFreqHz - 140.0) < 1e-6)  // speech: mono below 140 Hz
        #expect(abs(model.config.finalDriveDB - 4.3) < 1e-6)
    }

    @Test func speechMultibandIsFastAndDense() {
        // Finding 1: the talk multiband used to be the slowest and weakest
        // row in the catalogue (ratios 1.12 / 1.06 / 1.0 at 414-644 ms once
        // light-scaled). Orban NEWS-TALK and Omnia Talk run a fast release
        // for density; every band must compress for real and let go quickly.
        var config = AppConfig()
        _ = PresetCatalog.applyFormatProfile(id: "speech", to: &config)
        let ratios = [config.multibandLowRatio, config.multibandMidRatio, config.multibandHighRatio]
        let releases = [config.multibandLowReleaseMS, config.multibandMidReleaseMS, config.multibandHighReleaseMS]
        for (band, ratio) in zip(["low", "mid", "high"], ratios) {
            #expect(ratio > 1.3, "speech \(band) band ratio \(ratio) must be above 1.3:1")
        }
        for (band, release) in zip(["low", "mid", "high"], releases) {
            #expect(release < 250.0, "speech \(band) band release \(release) ms must be below 250 ms")
        }
        // The exact rows the review asked for.
        #expect(abs(config.multibandLowThresholdDB - (-14.0)) < 1e-9)
        #expect(abs(config.multibandLowRatio - 1.8) < 1e-9)
        #expect(abs(config.multibandLowAttackMS - 25.0) < 1e-9)
        #expect(abs(config.multibandLowReleaseMS - 220.0) < 1e-9)
        #expect(abs(config.multibandMidThresholdDB - (-13.0)) < 1e-9)
        #expect(abs(config.multibandMidRatio - 1.7) < 1e-9)
        #expect(abs(config.multibandMidAttackMS - 18.0) < 1e-9)
        #expect(abs(config.multibandMidReleaseMS - 180.0) < 1e-9)
        #expect(abs(config.multibandHighThresholdDB - (-12.0)) < 1e-9)
        #expect(abs(config.multibandHighRatio - 1.5) < 1e-9)
        #expect(abs(config.multibandHighAttackMS - 12.0) < 1e-9)
        #expect(abs(config.multibandHighReleaseMS - 140.0) < 1e-9)
    }

    @Test func musicCleanTurnsTheBassClipperOnAtTheDefaults() {
        // Finding 5: every vendor structure bass-clips; the default profile
        // now does too, at the idle-on-AC defaults.
        var config = AppConfig()
        config.bassClipperEnabled = false
        config.bassClipperDrive = 4.0
        _ = PresetCatalog.applyFormatProfile(id: "music_clean", to: &config)
        #expect(config.bassClipperEnabled)
        #expect(abs(config.bassClipperThresholdDB - (-3.0)) < 1e-9)
        #expect(abs(config.bassClipperCrossoverHz - 150.0) < 1e-9)
        #expect(abs(config.bassClipperDrive - 1.5) < 1e-9)
    }

    // MARK: - Default profile (music_clean)

    @Test func defaultProfileMatchesShippingDefaults() {
        // A fresh install IS Music -- Clean (2026-10 review, finding 7):
        // every key the profile writes must already hold that value in
        // `AppConfig()`, so applying the default profile to a fresh config
        // is a no-op. The per-key tables name the drifted knob; the whole-
        // config equality at the end catches any key the tables miss.
        let fresh = AppConfig()
        var applied = AppConfig()
        #expect(PresetCatalog.applyFormatProfile(id: "music_clean", to: &applied) != nil)

        let doubles: [(String, KeyPath<AppConfig, Double>)] = [
            ("wideband_agc_target_db", \.widebandAGCTargetDB),
            ("wideband_agc_attack_ms", \.widebandAGCAttackMS),
            ("wideband_agc_release_ms", \.widebandAGCReleaseMS),
            ("wideband_agc_max_gain_db", \.widebandAGCMaxGainDB),
            ("wideband_agc_min_gain_db", \.widebandAGCMinGainDB),
            ("final_drive_db", \.finalDriveDB),
            ("pre_encode_threshold", \.preEncodeThreshold),
            ("composite_clipper_threshold_db", \.compositeClipperThresholdDB),
            ("composite_clipper_ceiling_db", \.compositeClipperCeilingDB),
            ("composite_clipper_lookahead_ms", \.compositeClipperLookaheadMS),
            ("hf_limiter_threshold_db", \.hfLimiterThresholdDB),
            ("hf_limiter_top_threshold_db", \.hfLimiterTopThresholdDB),
            ("mono_bass_freq_hz", \.monoBassFreqHz),
            ("bass_clipper_threshold_db", \.bassClipperThresholdDB),
            ("bass_clipper_crossover_hz", \.bassClipperCrossoverHz),
            ("bass_clipper_drive", \.bassClipperDrive),
            ("multiband_x1_hz", \.multibandX1Hz),
            ("multiband_x2_hz", \.multibandX2Hz),
            ("multiband_x3_hz", \.multibandX3Hz),
            ("multiband_x4_hz", \.multibandX4Hz),
            ("multiband_low_threshold_db", \.multibandLowThresholdDB),
            ("multiband_mid_threshold_db", \.multibandMidThresholdDB),
            ("multiband_high_threshold_db", \.multibandHighThresholdDB),
            ("multiband_low_ratio", \.multibandLowRatio),
            ("multiband_mid_ratio", \.multibandMidRatio),
            ("multiband_high_ratio", \.multibandHighRatio),
            ("multiband_low_attack_ms", \.multibandLowAttackMS),
            ("multiband_mid_attack_ms", \.multibandMidAttackMS),
            ("multiband_high_attack_ms", \.multibandHighAttackMS),
            ("multiband_low_release_ms", \.multibandLowReleaseMS),
            ("multiband_mid_release_ms", \.multibandMidReleaseMS),
            ("multiband_high_release_ms", \.multibandHighReleaseMS),
            ("multiband_knee_db", \.multibandKneeDB),
            ("multiband_link_strength", \.multibandLinkStrength),
            ("peq_b1_freq_hz", \.peqB1FreqHz),
            ("peq_b1_gain_db", \.peqB1GainDB),
            ("peq_b2_freq_hz", \.peqB2FreqHz),
            ("peq_b2_gain_db", \.peqB2GainDB),
            ("peq_b2_q", \.peqB2Q),
            ("peq_b3_freq_hz", \.peqB3FreqHz),
            ("peq_b3_gain_db", \.peqB3GainDB),
            ("peq_b3_q", \.peqB3Q),
            ("peq_b4_freq_hz", \.peqB4FreqHz),
            ("peq_b4_gain_db", \.peqB4GainDB),
            ("multiband_limiter_threshold_db", \.multibandLimiterThresholdDB),
            ("multiband_limiter_attack_ms", \.multibandLimiterAttackMS),
            ("multiband_limiter_release_ms", \.multibandLimiterReleaseMS)
        ]
        for (name, key) in doubles {
            #expect(abs(applied[keyPath: key] - fresh[keyPath: key]) < 1e-9,
                "\(name): music_clean writes \(applied[keyPath: key]), AppConfig() ships \(fresh[keyPath: key])")
        }

        let bools: [(String, KeyPath<AppConfig, Bool>)] = [
            ("wideband_agc_enabled", \.widebandAGCEnabled),
            ("pre_encode_audio_limiter_enabled", \.preEncodeAudioLimiterEnabled),
            ("limit_mpx", \.limitMPX),
            ("composite_clipper_enabled", \.compositeClipperEnabled),
            ("hf_limiter_enabled", \.hfLimiterEnabled),
            ("bass_clipper_enabled", \.bassClipperEnabled),
            ("phase_rotation_enabled", \.phaseRotationEnabled),
            ("parametric_eq_enabled", \.parametricEQEnabled),
            ("multiband_limiter_enabled", \.multibandLimiterEnabled),
            ("advanced_dynamics_enabled", \.advancedDynamicsEnabled),
            ("primebass_enabled", \.primeBassEnabled),
            ("mono_bass_enabled", \.monoBassEnabled),
            ("multiband_enabled", \.multibandEnabled),
            ("multiband_release_program_dependent", \.multibandReleaseProgramDependent)
        ]
        for (name, key) in bools {
            #expect(applied[keyPath: key] == fresh[keyPath: key],
                "\(name): music_clean writes \(applied[keyPath: key]), AppConfig() ships \(fresh[keyPath: key])")
        }

        let strings: [(String, KeyPath<AppConfig, String>)] = [
            ("format_profile_id", \.formatProfileID),
            ("multiband_preset_id", \.multibandPresetID),
            ("multiband_intensity", \.multibandIntensity),
            ("final_stage_preset_id", \.finalStagePresetID),
            ("primebass_preset_id", \.primeBassPresetID)
        ]
        for (name, key) in strings {
            #expect(applied[keyPath: key] == fresh[keyPath: key],
                "\(name): music_clean writes \(applied[keyPath: key]), AppConfig() ships \(fresh[keyPath: key])")
        }
        #expect(applied.multibandMode == fresh.multibandMode, "multiband_mode drifted")

        #expect(applied == fresh,
            "applying music_clean to a fresh AppConfig must be a no-op (a key outside the tables drifted)")
    }

    // MARK: - Custom profile (sentinel — no settings changes)

    @Test func customProfileDoesNotChangePerStageSettings() {
        let model = makeViewModel()
        // Apply Music - Loud first so we have a known non-default state.
        model.applyFormatProfile("music_loud")
        model.config.advancedDynamicsEnabled = true
        let snapshotMultiband = model.config.multibandPresetID
        let snapshotIntensity = model.config.multibandIntensity
        let snapshotFinalStage = model.config.finalStagePresetID
        let snapshotPrimeBassEnabled = model.config.primeBassEnabled
        let snapshotPrimeBassID = model.config.primeBassPresetID
        let snapshotMonoBassFreq = model.config.monoBassFreqHz
        let snapshotClipperThreshold = model.config.compositeClipperThresholdDB
        let snapshotClipperCeiling = model.config.compositeClipperCeilingDB
        let snapshotFinalDrive = model.config.finalDriveDB
        let snapshotPEQ = model.config.parametricEQEnabled

        // Picking Custom must change ONLY the formatProfileID label.
        model.applyFormatProfile("custom")

        #expect(model.config.formatProfileID == "custom",
            "Custom selection must record the label")
        #expect(model.config.multibandPresetID == snapshotMultiband)
        #expect(model.config.multibandIntensity == snapshotIntensity)
        #expect(model.config.finalStagePresetID == snapshotFinalStage)
        #expect(model.config.primeBassEnabled == snapshotPrimeBassEnabled)
        #expect(model.config.primeBassPresetID == snapshotPrimeBassID)
        #expect(abs(model.config.monoBassFreqHz - snapshotMonoBassFreq) < 1e-9)
        #expect(abs(model.config.compositeClipperThresholdDB - snapshotClipperThreshold) < 1e-9)
        #expect(abs(model.config.compositeClipperCeilingDB - snapshotClipperCeiling) < 1e-9)
        #expect(abs(model.config.finalDriveDB - snapshotFinalDrive) < 1e-9)
        #expect(model.config.parametricEQEnabled == snapshotPEQ)
        #expect(model.config.advancedDynamicsEnabled == true,
            "Custom is a label: it must not reset the Levelling choice")
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
