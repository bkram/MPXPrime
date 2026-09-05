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
    /// The decoded-MPX monitor (a listening switch, not an output mode).
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

    /// Does this part of the chain do anything in `mode`?
    func applies(in mode: AppConfig.OperatingMode) -> Bool {
        switch self {
        case .stereoCoder, .compositeClipper, .bs412, .finalStage, .rds, .monitorPath:
            // Everything downstream of stereo encoding exists only where a
            // composite is generated.
            return mode == .mpx
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
        }
    }

    /// The modes this feature exists in, as the dashboard schema spells them.
    var modes: [String] {
        AppConfig.OperatingMode.allCases.filter { applies(in: $0) }.map(\.rawValue)
    }
}
