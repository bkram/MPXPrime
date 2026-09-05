import Foundation

// Sub-effect preset catalog: PrimeBass / multiband / final-stage / format-profile tables
// and their pure apply-to-config logic. Extracted from the GUI view model
// (SwiftUIControlApp.swift) so the remote-control API can apply presets on
// the headless runtimes (macOS --nogui and the Linux CLI) with the exact
// same parameter sets the GUI uses. The GUI's apply* methods are thin
// wrappers over these functions (save/live-apply/status stay in the VM).
//
// Format profiles remain GUI-side: they chain final-stage presets and other
// profile state that has not been extracted yet.

struct PrimeBassPreset {
    let id: String
    let title: String
    let enabled: Bool
    let amount: Double
    let freqHz: Double
    let harmonics: Double
    let drive: Double
    let density: Double
    let subharmonicsEnabled: Bool
    let subharmonicsAmount: Double
}

struct MultibandPreset {
    let id: String
    let title: String
    let mode: Int
    let lowHz: Double?
    let highHz: Double?
    let x1Hz: Double?
    let x2Hz: Double?
    let x3Hz: Double?
    let x4Hz: Double?
    let lowThresholdDB: Double
    let lowRatio: Double
    let lowAttackMS: Double
    let lowReleaseMS: Double
    let midThresholdDB: Double
    let midRatio: Double
    let midAttackMS: Double
    let midReleaseMS: Double
    let highThresholdDB: Double
    let highRatio: Double
    let highAttackMS: Double
    let highReleaseMS: Double
    let kneeDB: Double
    let linkStrength: Double
    let releaseProgramDependent: Bool
}

enum MultibandPresetIntensity: String, CaseIterable, Identifiable {
    case light
    case normal
    case heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .normal: return "Normal"
        case .heavy: return "Heavy"
        }
    }

    var thresholdDbOffset: Double {
        switch self {
        case .light: return 1.5
        case .normal: return 0.0
        case .heavy: return -1.5
        }
    }

    var ratioMul: Double {
        switch self {
        case .light: return 0.9
        case .normal: return 1.0
        case .heavy: return 1.12
        }
    }

    var attackMul: Double {
        switch self {
        case .light: return 1.2
        case .normal: return 1.0
        case .heavy: return 0.88
        }
    }

    var releaseMul: Double {
        switch self {
        case .light: return 1.15
        case .normal: return 1.0
        case .heavy: return 0.9
        }
    }
}

enum PresetCatalog {
    static let primeBassPresets: [PrimeBassPreset] = [
        .init(
            id: "chr", title: "CHR/EDM", enabled: true, amount: 0.34, freqHz: 78, harmonics: 0.28,
            drive: 0.92, density: 0.56, subharmonicsEnabled: true, subharmonicsAmount: 0.16),
        .init(
            id: "urban", title: "Urban", enabled: true, amount: 0.32, freqHz: 74, harmonics: 0.24,
            drive: 0.88, density: 0.54, subharmonicsEnabled: true, subharmonicsAmount: 0.14),
        .init(
            id: "rock", title: "Rock", enabled: true, amount: 0.24, freqHz: 90, harmonics: 0.16,
            drive: 0.76, density: 0.44, subharmonicsEnabled: false, subharmonicsAmount: 0.08),
        .init(
            id: "ac", title: "AC/Pop", enabled: true, amount: 0.18, freqHz: 100, harmonics: 0.10,
            drive: 0.68, density: 0.36, subharmonicsEnabled: false, subharmonicsAmount: 0.06),
        .init(
            id: "talk", title: "Talk", enabled: true, amount: 0.08, freqHz: 120, harmonics: 0.04,
            drive: 0.48, density: 0.22, subharmonicsEnabled: false, subharmonicsAmount: 0.0)
    ]

    static let multibandPresets: [MultibandPreset] = [
        .init(
            id: "3_chr", title: "3B CHR/EDM", mode: 3, lowHz: 290, highHz: 2500, x1Hz: nil,
            x2Hz: nil, x3Hz: nil, x4Hz: nil, lowThresholdDB: -23, lowRatio: 2.3, lowAttackMS: 20,
            lowReleaseMS: 310, midThresholdDB: -21, midRatio: 2.0, midAttackMS: 14,
            midReleaseMS: 235, highThresholdDB: -19, highRatio: 1.6, highAttackMS: 8,
            highReleaseMS: 165, kneeDB: 2.4, linkStrength: 0.42, releaseProgramDependent: true),
        .init(
            id: "3_rock", title: "3B Rock", mode: 3, lowHz: 310, highHz: 2550, x1Hz: nil, x2Hz: nil,
            x3Hz: nil, x4Hz: nil, lowThresholdDB: -21, lowRatio: 2.1, lowAttackMS: 22,
            lowReleaseMS: 325, midThresholdDB: -19, midRatio: 1.9, midAttackMS: 14,
            midReleaseMS: 245, highThresholdDB: -18, highRatio: 1.55, highAttackMS: 9,
            highReleaseMS: 175, kneeDB: 2.5, linkStrength: 0.44, releaseProgramDependent: true),
        .init(
            id: "3_ac", title: "3B AC/Pop", mode: 3, lowHz: 320, highHz: 2650, x1Hz: nil, x2Hz: nil,
            x3Hz: nil, x4Hz: nil, lowThresholdDB: -19, lowRatio: 1.9, lowAttackMS: 24,
            lowReleaseMS: 340, midThresholdDB: -17, midRatio: 1.7, midAttackMS: 16,
            midReleaseMS: 260, highThresholdDB: -16, highRatio: 1.4, highAttackMS: 10,
            highReleaseMS: 190, kneeDB: 3.0, linkStrength: 0.48, releaseProgramDependent: true),
        .init(
            id: "3_country", title: "3B Country", mode: 3, lowHz: 300, highHz: 2450, x1Hz: nil,
            x2Hz: nil, x3Hz: nil, x4Hz: nil, lowThresholdDB: -21, lowRatio: 2.2, lowAttackMS: 22,
            lowReleaseMS: 320, midThresholdDB: -19, midRatio: 1.9, midAttackMS: 15,
            midReleaseMS: 250, highThresholdDB: -17, highRatio: 1.5, highAttackMS: 10,
            highReleaseMS: 185, kneeDB: 2.6, linkStrength: 0.42, releaseProgramDependent: true),
        .init(
            id: "3_talk", title: "3B Talk", mode: 3, lowHz: 360, highHz: 3200, x1Hz: nil, x2Hz: nil,
            x3Hz: nil, x4Hz: nil, lowThresholdDB: -15, lowRatio: 1.5, lowAttackMS: 36,
            lowReleaseMS: 440, midThresholdDB: -14, midRatio: 1.4, midAttackMS: 30,
            midReleaseMS: 360, highThresholdDB: -13, highRatio: 1.22, highAttackMS: 20,
            highReleaseMS: 290, kneeDB: 4.0, linkStrength: 0.62, releaseProgramDependent: true),
        .init(
            id: "3_urban", title: "3B Urban", mode: 3, lowHz: 250, highHz: 2200, x1Hz: nil,
            x2Hz: nil, x3Hz: nil, x4Hz: nil, lowThresholdDB: -24, lowRatio: 2.7, lowAttackMS: 16,
            lowReleaseMS: 280, midThresholdDB: -22, midRatio: 2.4, midAttackMS: 11,
            midReleaseMS: 210, highThresholdDB: -20, highRatio: 1.9, highAttackMS: 6,
            highReleaseMS: 145, kneeDB: 2.1, linkStrength: 0.38, releaseProgramDependent: true),
        .init(
            id: "3_dance", title: "3B Dance", mode: 3, lowHz: 240, highHz: 2100, x1Hz: nil,
            x2Hz: nil, x3Hz: nil, x4Hz: nil, lowThresholdDB: -26, lowRatio: 2.9, lowAttackMS: 14,
            lowReleaseMS: 260, midThresholdDB: -24, midRatio: 2.6, midAttackMS: 10,
            midReleaseMS: 200, highThresholdDB: -22, highRatio: 2.0, highAttackMS: 5,
            highReleaseMS: 135, kneeDB: 1.9, linkStrength: 0.34, releaseProgramDependent: true),
        // Italo / disco / synthwave pump. Tempo-synced low-band release
        // (~60 ms = 12% of a 120-BPM quarter note) gives audible kick-driven
        // ducking; bright high band stays glossy. Tighter linkStrength widens
        // the bass image.
        .init(
            id: "3_italo", title: "3B Italo / Pump", mode: 3, lowHz: 240, highHz: 2100,
            x1Hz: nil, x2Hz: nil, x3Hz: nil, x4Hz: nil,
            lowThresholdDB: -28, lowRatio: 3.6, lowAttackMS: 6,
            lowReleaseMS: 60,
            midThresholdDB: -23, midRatio: 2.2, midAttackMS: 10,
            midReleaseMS: 130,
            highThresholdDB: -18, highRatio: 1.3, highAttackMS: 4,
            highReleaseMS: 100,
            kneeDB: 1.5, linkStrength: 0.30, releaseProgramDependent: true),
        .init(
            id: "3_news", title: "3B News", mode: 3, lowHz: 360, highHz: 3200, x1Hz: nil, x2Hz: nil,
            x3Hz: nil, x4Hz: nil, lowThresholdDB: -15, lowRatio: 1.4, lowAttackMS: 38,
            lowReleaseMS: 480, midThresholdDB: -14, midRatio: 1.35, midAttackMS: 30,
            midReleaseMS: 390, highThresholdDB: -13, highRatio: 1.25, highAttackMS: 22,
            highReleaseMS: 320, kneeDB: 4.0, linkStrength: 0.62, releaseProgramDependent: true),
        .init(
            id: "3_jazz", title: "3B Jazz", mode: 3, lowHz: 330, highHz: 2800, x1Hz: nil, x2Hz: nil,
            x3Hz: nil, x4Hz: nil, lowThresholdDB: -18, lowRatio: 1.7, lowAttackMS: 30,
            lowReleaseMS: 420, midThresholdDB: -17, midRatio: 1.55, midAttackMS: 24,
            midReleaseMS: 330, highThresholdDB: -16, highRatio: 1.35, highAttackMS: 16,
            highReleaseMS: 250, kneeDB: 3.2, linkStrength: 0.52, releaseProgramDependent: true),
        .init(
            id: "3_classic", title: "3B Classical", mode: 3, lowHz: 360, highHz: 3400, x1Hz: nil,
            x2Hz: nil, x3Hz: nil, x4Hz: nil, lowThresholdDB: -14, lowRatio: 1.35, lowAttackMS: 42,
            lowReleaseMS: 520, midThresholdDB: -13, midRatio: 1.3, midAttackMS: 36,
            midReleaseMS: 430, highThresholdDB: -12, highRatio: 1.2, highAttackMS: 26,
            highReleaseMS: 340, kneeDB: 4.6, linkStrength: 0.66, releaseProgramDependent: true),
        .init(
            id: "5_chr", title: "5B CHR/EDM", mode: 5, lowHz: nil, highHz: nil, x1Hz: 90, x2Hz: 320,
            x3Hz: 1600, x4Hz: 6200, lowThresholdDB: -23, lowRatio: 2.25, lowAttackMS: 20,
            lowReleaseMS: 320, midThresholdDB: -21, midRatio: 1.9, midAttackMS: 13,
            midReleaseMS: 240, highThresholdDB: -19, highRatio: 1.6, highAttackMS: 8,
            highReleaseMS: 180, kneeDB: 2.6, linkStrength: 0.48, releaseProgramDependent: true),
        .init(
            id: "5_rock", title: "5B Rock", mode: 5, lowHz: nil, highHz: nil, x1Hz: 90, x2Hz: 340,
            x3Hz: 1550, x4Hz: 6100, lowThresholdDB: -21, lowRatio: 2.1, lowAttackMS: 20,
            lowReleaseMS: 320, midThresholdDB: -19, midRatio: 1.85, midAttackMS: 13,
            midReleaseMS: 240, highThresholdDB: -18, highRatio: 1.55, highAttackMS: 8,
            highReleaseMS: 175, kneeDB: 2.5, linkStrength: 0.46, releaseProgramDependent: true),
        .init(
            id: "5_ac", title: "5B AC/Pop", mode: 5, lowHz: nil, highHz: nil, x1Hz: 90, x2Hz: 350,
            x3Hz: 1800, x4Hz: 6800, lowThresholdDB: -17.5, lowRatio: 1.75, lowAttackMS: 28,
            lowReleaseMS: 375, midThresholdDB: -16.0, midRatio: 1.55, midAttackMS: 19,
            midReleaseMS: 300, highThresholdDB: -14.5, highRatio: 1.28, highAttackMS: 13,
            highReleaseMS: 225, kneeDB: 3.6, linkStrength: 0.52, releaseProgramDependent: true),
        .init(
            id: "5_classic", title: "5B Classical/Jazz", mode: 5, lowHz: nil, highHz: nil, x1Hz: 90,
            x2Hz: 360, x3Hz: 1700, x4Hz: 6500, lowThresholdDB: -17, lowRatio: 1.5, lowAttackMS: 36,
            lowReleaseMS: 450, midThresholdDB: -16, midRatio: 1.4, midAttackMS: 30,
            midReleaseMS: 360, highThresholdDB: -15, highRatio: 1.25, highAttackMS: 20,
            highReleaseMS: 280, kneeDB: 4.5, linkStrength: 0.60, releaseProgramDependent: true),
        .init(
            id: "5_talk", title: "5B Talk", mode: 5, lowHz: nil, highHz: nil, x1Hz: 110, x2Hz: 420,
            x3Hz: 2200, x4Hz: 7600, lowThresholdDB: -12.5, lowRatio: 1.24, lowAttackMS: 48,
            lowReleaseMS: 560, midThresholdDB: -11.8, midRatio: 1.18, midAttackMS: 40,
            midReleaseMS: 450, highThresholdDB: -11.2, highRatio: 1.08, highAttackMS: 30,
            highReleaseMS: 360, kneeDB: 5.2, linkStrength: 0.46, releaseProgramDependent: true),
        .init(
            id: "5_urban", title: "5B Urban", mode: 5, lowHz: nil, highHz: nil, x1Hz: 85, x2Hz: 300,
            x3Hz: 1300, x4Hz: 5400, lowThresholdDB: -23, lowRatio: 2.3, lowAttackMS: 18,
            lowReleaseMS: 295, midThresholdDB: -21, midRatio: 2.0, midAttackMS: 12,
            midReleaseMS: 220, highThresholdDB: -19, highRatio: 1.7, highAttackMS: 7,
            highReleaseMS: 155, kneeDB: 2.2, linkStrength: 0.42, releaseProgramDependent: true),
        .init(
            id: "5_dance", title: "5B Dance", mode: 5, lowHz: nil, highHz: nil, x1Hz: 80, x2Hz: 290,
            x3Hz: 1200, x4Hz: 5000, lowThresholdDB: -24, lowRatio: 2.5, lowAttackMS: 16,
            lowReleaseMS: 285, midThresholdDB: -22, midRatio: 2.1, midAttackMS: 11,
            midReleaseMS: 215, highThresholdDB: -20, highRatio: 1.75, highAttackMS: 6,
            highReleaseMS: 150, kneeDB: 2.0, linkStrength: 0.40, releaseProgramDependent: true),
        // Italo / disco / synthwave pump. The 5-band variant linearly
        // interpolates band 2 from low+mid, so the low values are pushed
        // hard to make band 2 (the kick band, 80–280 Hz) aggressive enough
        // for audible pump. Resulting band 2: ~-26.5 dB, 3.1:1, 8 ms / 90 ms
        // — at 120 BPM that release is ~18% of a quarter note, plenty of
        // ducking. High band stays light (1.3:1) so cymbals/synths sparkle.
        .init(
            id: "5_italo", title: "5B Italo / Pump", mode: 5, lowHz: nil, highHz: nil,
            x1Hz: 80, x2Hz: 280, x3Hz: 1200, x4Hz: 5000,
            lowThresholdDB: -30, lowRatio: 4.0, lowAttackMS: 5,
            lowReleaseMS: 50,
            midThresholdDB: -23, midRatio: 2.2, midAttackMS: 10,
            midReleaseMS: 130,
            highThresholdDB: -18, highRatio: 1.3, highAttackMS: 4,
            highReleaseMS: 100,
            kneeDB: 1.5, linkStrength: 0.30, releaseProgramDependent: true),
        .init(
            id: "5_news", title: "5B News", mode: 5, lowHz: nil, highHz: nil, x1Hz: 110, x2Hz: 450,
            x3Hz: 2100, x4Hz: 7600, lowThresholdDB: -15, lowRatio: 1.4, lowAttackMS: 40,
            lowReleaseMS: 500, midThresholdDB: -14, midRatio: 1.35, midAttackMS: 34,
            midReleaseMS: 400, highThresholdDB: -13, highRatio: 1.25, highAttackMS: 24,
            highReleaseMS: 320, kneeDB: 4.3, linkStrength: 0.64, releaseProgramDependent: true),
        .init(
            id: "5_jazz", title: "5B Jazz", mode: 5, lowHz: nil, highHz: nil, x1Hz: 95, x2Hz: 360,
            x3Hz: 1600, x4Hz: 6200, lowThresholdDB: -18, lowRatio: 1.65, lowAttackMS: 32,
            lowReleaseMS: 430, midThresholdDB: -17, midRatio: 1.5, midAttackMS: 26,
            midReleaseMS: 340, highThresholdDB: -16, highRatio: 1.35, highAttackMS: 17,
            highReleaseMS: 260, kneeDB: 3.4, linkStrength: 0.54, releaseProgramDependent: true),
        .init(
            id: "5_oldies", title: "5B Oldies", mode: 5, lowHz: nil, highHz: nil, x1Hz: 90,
            x2Hz: 340, x3Hz: 1450, x4Hz: 5600, lowThresholdDB: -20, lowRatio: 1.8, lowAttackMS: 26,
            lowReleaseMS: 360, midThresholdDB: -18, midRatio: 1.7, midAttackMS: 18,
            midReleaseMS: 280, highThresholdDB: -17, highRatio: 1.45, highAttackMS: 11,
            highReleaseMS: 210, kneeDB: 3.0, linkStrength: 0.48, releaseProgramDependent: true)
    ]

    private static func clamp(_ v: Double, min lo: Double, max hi: Double) -> Double {
        Swift.min(hi, Swift.max(lo, v))
    }

    static func approxEqual(_ a: Double, _ b: Double, tolerance: Double = 0.0001) -> Bool {
        abs(a - b) <= tolerance
    }

    /// Apply the PrimeBass preset `id`; returns its title, or nil for an
    /// unknown id (config untouched).
    @discardableResult
    static func applyPrimeBass(id: String, to config: inout AppConfig) -> String? {
        guard let preset = primeBassPresets.first(where: { $0.id == id }) else { return nil }
        config.primeBassEnabled = preset.enabled
        config.primeBassPresetID = id
        config.primeBassAmount = preset.amount
        config.primeBassFreqHz = preset.freqHz
        config.primeBassHarmonics = preset.harmonics
        config.primeBassDrive = preset.drive
        config.primeBassDensity = preset.density
        config.primeBassSubharmonicsEnabled = preset.subharmonicsEnabled
        config.primeBassSubharmonicsAmount = preset.subharmonicsAmount
        return preset.title
    }

    @discardableResult
    static func applyMultiband(
        id: String, intensity: MultibandPresetIntensity, to config: inout AppConfig
    ) -> String? {
        guard let preset = multibandPresets.first(where: { $0.id == id }) else { return nil }

        config.multibandEnabled = true
        config.multibandMode = preset.mode
        config.multibandPresetID = id
        config.multibandIntensity = intensity.rawValue

        if let lowHz = preset.lowHz {
            config.multibandLowHz = lowHz
            config.multibandX1Hz = lowHz
        }
        if let highHz = preset.highHz {
            config.multibandHighHz = highHz
            config.multibandX2Hz = highHz
        }
        if let x1Hz = preset.x1Hz { config.multibandX1Hz = x1Hz }
        if let x2Hz = preset.x2Hz { config.multibandX2Hz = x2Hz }
        if let x3Hz = preset.x3Hz { config.multibandX3Hz = x3Hz }
        if let x4Hz = preset.x4Hz { config.multibandX4Hz = x4Hz }

        config.multibandLowThresholdDB = clamp(
            preset.lowThresholdDB + intensity.thresholdDbOffset, min: -36.0, max: -6.0)
        config.multibandMidThresholdDB = clamp(
            preset.midThresholdDB + intensity.thresholdDbOffset, min: -36.0, max: -6.0)
        config.multibandHighThresholdDB = clamp(
            preset.highThresholdDB + intensity.thresholdDbOffset, min: -36.0, max: -6.0)

        config.multibandLowRatio = clamp(preset.lowRatio * intensity.ratioMul, min: 1.0, max: 4.0)
        config.multibandMidRatio = clamp(preset.midRatio * intensity.ratioMul, min: 1.0, max: 4.0)
        config.multibandHighRatio = clamp(preset.highRatio * intensity.ratioMul, min: 1.0, max: 4.0)

        config.multibandLowAttackMS = clamp(
            preset.lowAttackMS * intensity.attackMul, min: 1.0, max: 200.0)
        config.multibandMidAttackMS = clamp(
            preset.midAttackMS * intensity.attackMul, min: 1.0, max: 200.0)
        config.multibandHighAttackMS = clamp(
            preset.highAttackMS * intensity.attackMul, min: 1.0, max: 200.0)

        config.multibandLowReleaseMS = clamp(
            preset.lowReleaseMS * intensity.releaseMul, min: 50.0, max: 1000.0)
        config.multibandMidReleaseMS = clamp(
            preset.midReleaseMS * intensity.releaseMul, min: 50.0, max: 1000.0)
        config.multibandHighReleaseMS = clamp(
            preset.highReleaseMS * intensity.releaseMul, min: 50.0, max: 1000.0)

        config.multibandKneeDB = preset.kneeDB
        config.multibandLinkStrength = preset.linkStrength
        config.multibandReleaseProgramDependent = preset.releaseProgramDependent
        return preset.title
    }

    // MARK: - Final-stage presets (Broadcast Preset picker)

    /// AGC + drive + pre-encode-limiter bundle. Moved here from the view
    /// model so the headless backend can apply it (preset kind "finalstage")
    /// -- the GUI's picker wraps this the same way the other kinds do.
    struct FinalStagePreset: Identifiable {
        let id: String
        let title: String
        let agcEnabled: Bool
        let agcTargetDB: Double
        let agcAttackMS: Double
        let agcReleaseMS: Double
        let agcMaxGainDB: Double
        let agcMinGainDB: Double
        let finalDriveDB: Double
        let preEncodeAudioLimiterEnabled: Bool
    }

    // AGC attack 100-200 ms (0.45, chain review B1): the wideband AGC is a
    // gain rider; peaks belong to the limiter. The 45-80 ms values it had
    // ducked whole-program level on drum hits (Orban WP "hole punching").
    static let finalStagePresets: [FinalStagePreset] = [
        .init(id: "balanced", title: "Balanced Music",
              agcEnabled: true, agcTargetDB: -16.0, agcAttackMS: 200.0,
              agcReleaseMS: 1200.0, agcMaxGainDB: 12.0, agcMinGainDB: -12.0,
              finalDriveDB: 6.0, preEncodeAudioLimiterEnabled: true),
        .init(id: "chr", title: "CHR / Dance",
              agcEnabled: true, agcTargetDB: -15.0, agcAttackMS: 150.0,
              agcReleaseMS: 900.0, agcMaxGainDB: 10.0, agcMinGainDB: -9.0,
              finalDriveDB: 8.0, preEncodeAudioLimiterEnabled: true),
        .init(id: "punchy", title: "Punchy Music",
              agcEnabled: true, agcTargetDB: -15.0, agcAttackMS: 150.0,
              agcReleaseMS: 1000.0, agcMaxGainDB: 11.0, agcMinGainDB: -10.0,
              finalDriveDB: 7.5, preEncodeAudioLimiterEnabled: true),
        .init(id: "speech", title: "Speech / Talk",
              agcEnabled: true, agcTargetDB: -14.0, agcAttackMS: 100.0,
              agcReleaseMS: 750.0, agcMaxGainDB: 10.0, agcMinGainDB: -8.0,
              finalDriveDB: 4.5, preEncodeAudioLimiterEnabled: true)
    ]

    static func applyFinalStage(id: String, to config: inout AppConfig) -> String? {
        guard let preset = finalStagePresets.first(where: { $0.id == id }) else { return nil }
        config.finalStagePresetID = id
        config.widebandAGCEnabled = preset.agcEnabled
        config.widebandAGCTargetDB = preset.agcTargetDB
        config.widebandAGCAttackMS = preset.agcAttackMS
        config.widebandAGCReleaseMS = preset.agcReleaseMS
        config.widebandAGCMaxGainDB = preset.agcMaxGainDB
        config.widebandAGCMinGainDB = preset.agcMinGainDB
        config.finalDriveDB = preset.finalDriveDB
        config.preEncodeAudioLimiterEnabled = preset.preEncodeAudioLimiterEnabled
        return preset.title
    }

    // MARK: - Format profiles (top-level "Station Format" bundle)

    /// Atomically wires multiband / final-stage / PrimeBass / mono bass /
    /// composite-clipper settings to one programming format, as a wrapper
    /// over the per-stage preset tables above. Moved here from the view
    /// model so BOTH backends serve preset kind "format_profile" -- before
    /// this a headless (Linux) box could not apply a station format at all.
    struct FormatProfile: Identifiable {
        let id: String
        let title: String
        let summary: String
        let multibandPresetID: String
        let multibandIntensity: MultibandPresetIntensity
        let finalStagePresetID: String
        let primeBassEnabled: Bool
        let primeBassPresetID: String      // recorded even when disabled
        /// Mono-bass crossover for the profile's image policy. Mono bass is
        /// on in every shipped profile; the stereo widener was removed in 0.50.
        let monoBassFreqHz: Double
        let compositeClipperThresholdDB: Double
        let compositeClipperCeilingDB: Double
        let finalDriveDB: Double
        // Gain structure -- a profile owns the FULL chain state so one click
        // is a guaranteed-sane sound (2026-08 rework: the old 8 profiles only
        // set the "color" and left broken level structures broken).
        let agcEnabled: Bool
        let agcTargetDB: Double
        let preEncodeLimiterEnabled: Bool
        let preEncodeThreshold: Double
        let limitMPX: Bool
        let compositeClipperEnabled: Bool
        let compositeClipperLookaheadMS: Double
        let hfClipperEnabled: Bool
        let hfLimiterEnabled: Bool
        let bassClipperEnabled: Bool
        let phaseRotationEnabled: Bool
    }

    static let formatProfiles: [FormatProfile] = [
        // "Custom" sentinel: records the label, changes nothing (operators
        // flag bespoke setups; the apply short-circuits on it).
        .init(id: "custom", title: "Custom",
              summary: "Your manually-tuned settings — picking this leaves everything as you set it.",
              multibandPresetID: "5_ac", multibandIntensity: .normal,
              finalStagePresetID: "balanced", primeBassEnabled: false,
              primeBassPresetID: "ac", monoBassFreqHz: 140.0,
              compositeClipperThresholdDB: -1.0, compositeClipperCeilingDB: -0.3,
              finalDriveDB: 6.0,
              agcEnabled: true, agcTargetDB: -16.0,
              preEncodeLimiterEnabled: true, preEncodeThreshold: 0.88,
              limitMPX: true, compositeClipperEnabled: true,
              compositeClipperLookaheadMS: 2.0,
              hfClipperEnabled: false, hfLimiterEnabled: true, bassClipperEnabled: false,
              phaseRotationEnabled: false),
        .init(id: "music_clean", title: "Music — Clean",
              summary: "The default: transparent leveling, honest peaks, low clipper work. For stations that value fidelity over loudness.",
              multibandPresetID: "5_ac", multibandIntensity: .normal,
              finalStagePresetID: "balanced", primeBassEnabled: false,
              primeBassPresetID: "ac", monoBassFreqHz: 140.0,
              compositeClipperThresholdDB: -1.0, compositeClipperCeilingDB: -0.3,
              finalDriveDB: 4.0,
              agcEnabled: true, agcTargetDB: -16.0,
              preEncodeLimiterEnabled: true, preEncodeThreshold: 0.90,
              limitMPX: true, compositeClipperEnabled: true,
              compositeClipperLookaheadMS: 2.0,
              hfClipperEnabled: false, hfLimiterEnabled: true, bassClipperEnabled: false,
              phaseRotationEnabled: false),
        .init(id: "music_loud", title: "Music — Loud",
              summary: "Competitive loudness: hot drive into the composite clipper, HF limiter + bass clipper on, PrimeBass, mono bass at 115 Hz.",
              multibandPresetID: "5_chr", multibandIntensity: .normal,
              finalStagePresetID: "chr", primeBassEnabled: true,
              primeBassPresetID: "chr", monoBassFreqHz: 115.0,
              compositeClipperThresholdDB: -0.8, compositeClipperCeilingDB: -0.2,
              finalDriveDB: 8.0,
              agcEnabled: true, agcTargetDB: -15.0,
              preEncodeLimiterEnabled: true, preEncodeThreshold: 0.85,
              limitMPX: true, compositeClipperEnabled: true,
              compositeClipperLookaheadMS: 2.0,
              hfClipperEnabled: false, hfLimiterEnabled: true, bassClipperEnabled: true,
              phaseRotationEnabled: false),
        .init(id: "speech", title: "Speech / Talk",
              summary: "Voice-optimized: phase rotator for waveform symmetry, speech multiband + final stage, conservative drive.",
              multibandPresetID: "5_talk", multibandIntensity: .light,
              finalStagePresetID: "speech", primeBassEnabled: false,
              primeBassPresetID: "talk", monoBassFreqHz: 140.0,
              compositeClipperThresholdDB: -1.0, compositeClipperCeilingDB: -0.3,
              finalDriveDB: 4.5,
              agcEnabled: true, agcTargetDB: -16.0,
              preEncodeLimiterEnabled: true, preEncodeThreshold: 0.88,
              limitMPX: true, compositeClipperEnabled: true,
              compositeClipperLookaheadMS: 2.0,
              hfClipperEnabled: false, hfLimiterEnabled: true, bassClipperEnabled: false,
              phaseRotationEnabled: true),
        .init(id: "classical_wide", title: "Classical / Wide Dynamics",
              summary: "Dynamic-preserving: gentle slow AGC, light multiband, minimal clipper work, no enhancement.",
              multibandPresetID: "5_classic", multibandIntensity: .light,
              finalStagePresetID: "balanced", primeBassEnabled: false,
              primeBassPresetID: "ac", monoBassFreqHz: 140.0,
              compositeClipperThresholdDB: -1.2, compositeClipperCeilingDB: -0.4,
              finalDriveDB: 3.0,
              agcEnabled: true, agcTargetDB: -18.0,
              preEncodeLimiterEnabled: true, preEncodeThreshold: 0.92,
              limitMPX: true, compositeClipperEnabled: true,
              compositeClipperLookaheadMS: 2.0,
              hfClipperEnabled: false, hfLimiterEnabled: true, bassClipperEnabled: false,
              phaseRotationEnabled: false)
    ]

    static func formatProfile(forID id: String) -> FormatProfile? {
        formatProfiles.first(where: { $0.id == id })
    }

    /// Apply a format profile's full fan-out to `config`. ORDER MATTERS and
    /// mirrors the GUI's historical sequence: the final-stage preset sets
    /// `finalDriveDB`, then the profile's own drive overrides it.
    static func applyFormatProfile(id: String, to config: inout AppConfig) -> String? {
        guard let profile = formatProfile(forID: id) else { return nil }
        config.formatProfileID = id
        if id == "custom" { return profile.title }  // sentinel: label only

        _ = applyMultiband(
            id: profile.multibandPresetID,
            intensity: profile.multibandIntensity, to: &config)
        _ = applyFinalStage(id: profile.finalStagePresetID, to: &config)

        config.primeBassEnabled = profile.primeBassEnabled
        if profile.primeBassEnabled {
            _ = applyPrimeBass(id: profile.primeBassPresetID, to: &config)
        } else {
            // Record the flavour so toggling PrimeBass back on uses the
            // format-appropriate preset.
            config.primeBassPresetID = profile.primeBassPresetID
        }

        config.monoBassEnabled = true
        config.monoBassFreqHz = profile.monoBassFreqHz

        config.compositeClipperThresholdDB = profile.compositeClipperThresholdDB
        config.compositeClipperCeilingDB = profile.compositeClipperCeilingDB
        config.finalDriveDB = profile.finalDriveDB
        // Gain structure (2026-08 rework): the profile owns the full chain
        // state so a profile pick can never leave the safety soft-clips as
        // the de-facto peak controller.
        config.widebandAGCEnabled = profile.agcEnabled
        config.widebandAGCTargetDB = profile.agcTargetDB
        config.preEncodeAudioLimiterEnabled = profile.preEncodeLimiterEnabled
        config.preEncodeThreshold = profile.preEncodeThreshold
        config.limitMPX = profile.limitMPX
        config.compositeClipperEnabled = profile.compositeClipperEnabled
        config.compositeClipperLookaheadMS = profile.compositeClipperLookaheadMS
        config.hfClipperEnabled = profile.hfClipperEnabled
        config.hfLimiterEnabled = profile.hfLimiterEnabled
        config.bassClipperEnabled = profile.bassClipperEnabled
        config.phaseRotationEnabled = profile.phaseRotationEnabled
        return profile.title
    }
}
