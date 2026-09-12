import Foundation

/// Which parts of the chain exist in which operating mode -- ONE table, read by
/// the engine, the native GUI, the web dashboard's schema and the tests.
///
/// The operator's rule (2026-09-05): "for each DSP check if it has a function
/// in the current modus operandi", and do not show a control that has none.
/// Before this table each surface answered that question for itself: the GUI
/// hid four stages through `Stage.hiddenInProcessedAudio`, the dashboard
/// duplicated the same list in JavaScript, the digital target hid three more
/// controls with hand-written `if !digital` checks, and the runtime side
/// services (RDS, the Now Playing poller) were not gated at all -- a
/// processed-audio box kept an RDS encoder running into a composite nobody
/// generated and polled a metadata script for it.
///
/// A feature absent from a mode must be BOTH invisible in the interfaces and
/// inert in the engine. `ModeGatingTests` pins that pairing.
/// The dashboard's and the GUI sidebar's top-level sections, in order --
/// named for what the operator is DOING, not for how the engine is built
/// (roadmap "Web dashboard taxonomy and navigation", 0.60). `schema.json`
/// `model.sections` mirrors this table and `ControlSchemaTests` holds the two
/// together; the GUI's `Stage.Group` maps onto it.
enum NavigationSection: String, CaseIterable, Sendable {
    case onAir, setup, sound, rds, system

    var title: String {
        switch self {
        case .onAir: return "On Air"
        case .setup: return "Setup"
        case .sound: return "Sound"
        case .rds: return "RDS"
        case .system: return "Presets and System"
        }
    }
}

/// How the Sound section groups the stage pages: by what the stage does to
/// the signal, in signal order. `pageIDs` are the dashboard's stage page ids
/// (the GUI maps them to `Stage` cases; its combined HF page answers to both
/// `hfLimiter` and `hfClipper`). One stage id appears in exactly one group.
enum StageGroup: String, CaseIterable, Sendable {
    case input, levelling, tone, dynamics, peakControl, transmission

    var title: String {
        switch self {
        case .input: return "Input"
        case .levelling: return "Levelling"
        case .tone: return "Tone"
        case .dynamics: return "Dynamics"
        case .peakControl: return "Peak control"
        case .transmission: return "Transmission"
        }
    }

    var pageIDs: [String] {
        switch self {
        case .input: return ["core", "phaseRotator", "expander"]
        case .levelling: return ["agc", "advanced_dynamics"]
        case .tone: return ["parametricEQ", "primeBass"]
        case .dynamics: return ["multiband", "mbLimiter"]
        case .peakControl: return ["bassClipper", "dcClipper", "hfLimiter", "hfClipper", "limiter"]
        case .transmission: return ["stereoCoder", "compositeClipper", "bs412", "finalStage"]
        }
    }

    /// The Sound section's own pages ahead of the groups: the landing grid and
    /// the Format Profile ("start here").
    static let soundLandingPageIDs = ["overview", "profile"]
}

/// The controls each stage page folds into its collapsed **Advanced** group:
/// time constants, topology choices, set-once protections. Both front ends
/// fold the same keys -- the dashboard reads the `advanced` flag that
/// `schema.json` carries per widget (`ControlSchemaTests` holds that flag set
/// equal to this list), the GUI tabs wrap the matching rows in
/// `DisclosureGroup("Advanced")` by hand and this is the list they follow.
/// Two disclosure levels at most: page, then Advanced. What stays OUT of the
/// group is what an operator moves while listening: enables, thresholds,
/// ratios, ceilings, drives, targets, balances.
enum AdvancedControls {
    static let keys: Set<String> = [
        "advanced_dynamics_max_gain_db",
        "advanced_dynamics_speed",
        "bass_clipper_crossover_hz",
        "dc_clipper_cancel_freq_hz",
        "expander_attack_ms",
        "expander_release_ms",
        "hf_clipper_crossover_hz",
        "hf_limiter_attack_ms",
        "hf_limiter_max_reduction_db",
        "hf_limiter_release_ms",
        "hf_trim_db",
        "hf_trim_hz",
        "limit_lookahead_enabled",
        "limit_lookahead_ms",
        "limit_threshold",
        "mpx_clipper_cancel_audio",
        "mpx_clipper_cancel_pilot",
        "mpx_clipper_cancel_rds",
        "mpx_clipper_lookahead_ms",
        "mpx_clipper_stereo_guard",
        "mpx_ssb_stereo_amount",
        "multiband_high_attack_ms",
        "multiband_high_release_ms",
        "multiband_inter_band_coupling_enabled",
        "multiband_knee_db",
        "multiband_limiter_attack_ms",
        "multiband_limiter_release_ms",
        "multiband_link_strength",
        "multiband_low_attack_ms",
        "multiband_low_release_ms",
        "multiband_mid_attack_ms",
        "multiband_mid_release_ms",
        "multiband_release_program_dependent",
        "multiband_transient_aware_attack_enabled",
        "pre_encode_bandlimited_residual_enabled",
        "pre_encode_lookahead_hf_cutoff_hz",
        "pre_encode_lookahead_hf_only",
        "primebass_density",
        "primebass_drive",
        "primebass_harmonics",
        "primebass_subharmonics_amount",
        "primebass_subharmonics_enabled",
        "program_lowpass_hz",
        "wideband_agc_attack_ms",
        "wideband_agc_bass_desensitize",
        "wideband_agc_k_weighting",
        "wideband_agc_max_gain_db",
        "wideband_agc_min_gain_db",
        "wideband_agc_release_ms",
        "wideband_agc_release_program_dependent"
    ]
}

/// The Headroom card's rows, in display order, and the modes that show each.
/// ONE table, read by the GUI card, so a readout cannot be dropped in a mode
/// the web dashboard shows it in: 0.60 added the Bad Input counter to the
/// card's composite branch only, and FM / HD / AM operators on the Mac could
/// not see a fault the ingress guard was counting in every mode.
enum HeadroomReadout: String, CaseIterable, Sendable {
    case preEncodeGR
    case compositeGR
    case safetyGR
    case safetyClip
    case bs412Budget
    case mpxPower
    case bs412GR
    case badInput

    /// Does this readout mean anything in `mode`?
    func applies(in mode: AppConfig.OperatingMode) -> Bool {
        switch self {
        case .preEncodeGR, .badInput:
            // The pre-encode limiter runs in every mode, and the ingress
            // guard counts non-finite samples in every mode.
            return true
        case .compositeGR:
            return ChainFeature.compositeClipper.applies(in: mode)
        case .safetyGR, .safetyClip, .bs412Budget:
            return ChainFeature.finalStage.applies(in: mode)
        case .mpxPower, .bs412GR:
            return ChainFeature.bs412.applies(in: mode)
        }
    }

    static func visible(in mode: AppConfig.OperatingMode) -> [HeadroomReadout] {
        allCases.filter { $0.applies(in: mode) }
    }
}

enum ChainFeature: String, CaseIterable, Sendable {
    /// Stereo encoding itself: pilot, 38 kHz subcarrier, SSB leaning, mono mode.
    case stereoCoder
    /// Composite clipper (and its guard bands).
    case compositeClipper
    /// BS.412 multiplex-power limiter.
    case bs412
    /// Final MPX limiter, safety shaper, budget governor, MPX line output.
    case finalStage
    /// RDS: the encoder, every RDS control, and the Now Playing metadata poller.
    case rds
    /// The operator's listening output. A second device running alongside the
    /// transmitter feed, in EVERY mode -- it plays the decoded composite under
    /// `mpx` and the processed programme (de-emphasised where the chain
    /// emphasised it) under the audio modes.
    case monitorPath
    /// Pre-emphasis as an operator choice (50 / 75 us).
    case preemphasis
    /// Stereo-image protection ahead of an FM modulator.
    case stereoImage
    /// The digital true-peak ceiling.
    case digitalCeiling
    /// The optional loudness clipper for a coder that has none of its own.
    case coderFinalClipper
    /// AM-specific shaping: mono sum, NRSC pre-emphasis and band limit,
    /// asymmetric positive-peak headroom.
    case amShaping
    /// Anything that acts on the DIFFERENCE between the channels: Mono Mode,
    /// Mono Bass, the multiband stereo link.
    case stereoProgram
    /// The HF limiter, which rides the pre-emphasis BOOST (`out = flat + g *
    /// boost`). Where nothing pre-emphasises, boost is zero and the stage is
    /// an identity whatever its settings say.
    case hfLimiter

    /// Does this part of the chain do anything in `mode`?
    func applies(in mode: AppConfig.OperatingMode) -> Bool {
        switch self {
        case .stereoCoder, .compositeClipper, .bs412, .finalStage, .rds:
            // Everything downstream of stereo encoding exists only where a
            // composite is generated.
            return mode == .mpx
        case .monitorPath:
            // Listening is not a property of the output shape: an operator
            // wants to hear the programme in every mode, without tuning a
            // receiver to the transmitter.
            return true
        case .preemphasis:
            // FM and AM both pre-emphasise (AM on the NRSC curve, fixed);
            // a codec must never be fed a pre-emphasised signal.
            return mode == .mpx || mode == .fm
        case .stereoImage:
            // Protects an FM modulator from side-channel overshoot; a digital
            // carrier has neither deviation nor multipath, and AM is mono.
            return mode == .mpx || mode == .fm
        case .digitalCeiling:
            return mode == .hd
        case .coderFinalClipper:
            // Only where the next box is an FM stereo coder that may have no
            // clipper of its own. Clipping into a codec costs quality, and AM
            // has its own asymmetric peak control.
            return mode == .fm
        case .amShaping:
            return mode == .am
        case .stereoProgram:
            // AM sums L+R ahead of the chain, so every stage downstream sees
            // one signal on both channels and these controls do nothing.
            return mode != .am
        case .hfLimiter:
            // AM pre-emphasises on the NRSC curve, so the ride still has
            // something to ride; the digital target is deliberately flat.
            return mode != .hd
        }
    }

    /// The modes this feature exists in, as the dashboard schema spells them.
    var modes: [String] {
        AppConfig.OperatingMode.allCases.filter { applies(in: $0) }.map(\.rawValue)
    }
}
