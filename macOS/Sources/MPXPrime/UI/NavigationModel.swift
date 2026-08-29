// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Identifiable {
    case monitoring = "Monitoring"
    case processing = "Processing"
    case rds = "RDS"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .monitoring: return "waveform"
        case .processing: return "slider.horizontal.3"
        case .rds: return "dot.radiowaves.left.and.right"
        }
    }

    var detailTitle: String { rawValue }

    var detailSubtitle: String {
        switch self {
        case .monitoring:
            return "Overview and live status"
        case .processing:
            return "DSP controls and presets"
        case .rds:
            return "Program service and carrier settings"
        }
    }
}

enum ProcessingTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case formatProfile = "Profile"
    case core = "Core"
    case phaseRotator = "Phase Rot"
    case agc = "AGC"
    case parametricEQ = "PEQ"
    case multiband = "Multiband"
    case advancedDynamics = "Adv Dyn"
    case expander = "Expander"
    case mbLimiter = "MB Limiter"
    case widener = "Widener"
    case primeBass = "PrimeBass"
    case bassClipper = "Bass Clip"
    case dcClipper = "Audio Clip"
    case hfClipper = "HF Clip"
    case limiter = "Audio Limiter"
    case stereoCoder = "Stereo Coder"
    case compositeClipper = "Comp Clip"
    case bs412 = "BS.412"
    case finalStage = "Final Stage"

    /// Inverse of `Stage.legacyProcessingTab`. Cards in the
    /// Processing Overview grid use this to jump the unified
    /// `selectedStage` to the corresponding sidebar row when the
    /// chevron button is clicked.
    var stage: Stage {
        switch self {
        case .overview: return .processingOverview
        case .formatProfile: return .processingFormatProfile
        case .core: return .processingCore
        case .phaseRotator: return .processingPhaseRotator
        case .agc: return .processingAGC
        case .parametricEQ: return .processingParametricEQ
        case .multiband: return .processingMultiband
        case .advancedDynamics: return .processingAdvancedDynamics
        case .expander: return .processingExpander
        case .mbLimiter: return .processingMBLimiter
        case .widener: return .processingWidener
        case .primeBass: return .processingPrimeBass
        case .bassClipper: return .processingBassClipper
        case .dcClipper: return .processingDCClipper
        case .hfClipper: return .processingHFClipper
        case .limiter: return .processingLimiter
        case .stereoCoder: return .processingStereoCoder
        case .compositeClipper: return .processingCompositeClipper
        case .bs412: return .processingBS412
        case .finalStage: return .processingFinalStage
        }
    }

    /// Short paragraph explaining what the stage on this tab does and how
    /// it fits into the chain. Shown as a header block above the tab's
    /// controls — anchors the operator without forcing them to read
    /// documentation. Brief by design (1-3 sentences, ASCII-only).
    var helpText: String {
        switch self {
        case .overview:
            return "Bird's-eye view of every processing stage with its current state and one telling metric. Click a card's chevron to jump into its detail tab."
        case .formatProfile:
            return "Pick a station format to atomically apply matched multiband, final-stage, PrimeBass, widener, and composite-clipper settings. Per-stage knobs stay editable afterwards. Pick `Custom` to keep your manual tuning."
        case .core:
            return "Global engine controls: bypass, mono mode, input/output gains, pre-emphasis, audio HPF, program lowpass, HF trim. Most settings here are restart-required."
        case .phaseRotator:
            return "4-pole allpass chain that reduces waveform asymmetry — especially on voice — by 3-4 dB without changing tonal balance. Frees headroom for downstream dynamics stages."
        case .agc:
            return "Wideband Automatic Gain Control with optional K-weighted (BS.1770-style) detector and program-dependent release. Long-term level riding that brings quiet and loud sources to a similar perceived level before the multiband stage."
        case .parametricEQ:
            return "4-band parametric EQ (low shelf + 2 peaks + high shelf) applied in L/R domain before the multiband stage. Pre-multiband tonal shaping."
        case .multiband:
            return "Multiband compressor splitting L/R into 3 or 5 frequency bands (linear-phase FIR on TX path, LR4 IIR on monitor path), each with its own gain ride. Loudness lever and tonal control combined."
        case .advancedDynamics:
            return "Experimental single-stage leveler that replaces the AGC and Multiband stages with one fused 5-band stage, so leveling and density shaping can never fight. Set the sound you want (target, balance, density) - the stage adapts its own speed to the programme."
        case .expander:
            return "Per-band downward expander — pulls gain down when a band falls below threshold. Gates background noise floor while leaving programme content intact."
        case .mbLimiter:
            return "Per-band fast peak limiter sitting after the multiband compressor. Catches band-internal peaks before recombination, preserves the multiband target while controlling overshoots."
        case .widener:
            return "Post-multiband mid/side stereo image enhancement plus mono-bass control (sums L/R below the chosen cutoff). FM-safe — energy-normalised so mono compatibility is preserved."
        case .primeBass:
            return "Bass enhancement via MaxxBass-style harmonic synthesis plus dynamic envelope extension. Adds perceived bass while reducing true-peak LF amplitude — saves headroom downstream."
        case .bassClipper:
            return "4x oversampled clipper targeting LF transients before the chain. Useful when PrimeBass / multiband still leave kicks pushing into downstream limiters."
        case .dcClipper:
            return "8x oversampled distortion-cancelled clipper on the audio band. Cleans up audio-band peaks before pre-emphasis adds HF boost."
        case .hfClipper:
            return "Pre-emphasis-aware HF control, two stages after pre-emphasis. HF Limiter: gain-riding, removes part of the pre-emphasis boost only while an HF transient overshoots (no clipping distortion; on in Music - Loud). HF Clipper: waveshaper on the pre-emphasised high band -- denser, but it distorts cymbals and hi-hats; last resort, default off."
        case .limiter:
            return "Pre-encode L/R peak limiter — 4x oversampled true-peak, stereo-linked — with default-on look-ahead and an HF-subband transient detector. Catches HF transients that slip past everything upstream after pre-emphasis."
        case .bs412:
            return "ITU-R BS.412 rolling-average MPX power limiter for European regulatory compliance (DE / AT / CH / SE / CZ / SI). Slow gain ride over a ~60 s window. Off in NL, US, UK, FR, ES, IT and most other countries."
        case .stereoCoder:
            return "The pilot-locked stereo encoder: L+R plus L-R on the 38 kHz subcarrier, pilot and RDS injected after all peak control. Hosts the experimental SSB Stereo option, which leans the subcarrier toward single-sideband to reclaim composite headroom ahead of the clipper."
        case .compositeClipper:
            return "16x oversampled differential composite clipper on the assembled MPX composite. Protects pilot / stereo / RDS guard bands from clipper distortion via delta-based per-band substitution. Primary loudness lever."
        case .finalStage:
            return "Output gain, MPX deviation cap (75 kHz universal), final-MPX safety limiter with look-ahead, composite budget governor (keeps pilot / RDS injection constant), deviation telemetry."
        }
    }

    var id: String { rawValue }

    var resetButtonTitle: String {
        switch self {
        case .overview:
            return "Reset All Processing"
        case .formatProfile:
            return "Reset Format Profile"
        case .core:
            return "Reset Core Tab"
        case .agc:
            return "Reset AGC Tab"
        case .phaseRotator:
            return "Reset Phase Rotator Tab"
        case .parametricEQ:
            return "Reset PEQ Tab"
        case .primeBass:
            return "Reset PrimeBass Tab"
        case .multiband:
            return "Reset Multiband Tab"
        case .advancedDynamics:
            return "Reset Advanced Dynamics Tab"
        case .mbLimiter:
            return "Reset MB Limiter Tab"
        case .expander:
            return "Reset Expander Tab"
        case .bassClipper:
            return "Reset Bass Clipper Tab"
        case .dcClipper:
            return "Reset Audio Clipper Tab"
        case .hfClipper:
            return "Reset HF Clipper Tab"
        case .widener:
            return "Reset Widener Tab"
        case .limiter:
            return "Reset Audio Limiter Tab"
        case .bs412:
            return "Reset BS.412 Tab"
        case .stereoCoder:
            return "Reset Stereo Coder Tab"
        case .compositeClipper:
            return "Reset Composite Clipper Tab"
        case .finalStage:
            return "Reset Final Stage Tab"
        }
    }

    var resetStatusText: String {
        switch self {
        case .overview:
            return "Reset every processing tab to defaults"
        case .formatProfile:
            return "Reset format profile to default (Community Radio)"
        case .core:
            return "Reset processing core tab to defaults"
        case .agc:
            return "Reset AGC tab to defaults"
        case .phaseRotator:
            return "Reset phase rotator tab to defaults"
        case .parametricEQ:
            return "Reset parametric EQ tab to defaults"
        case .primeBass:
            return "Reset PrimeBass tab to defaults"
        case .multiband:
            return "Reset Multiband tab to defaults"
        case .advancedDynamics:
            return "Reset Advanced Dynamics tab to defaults"
        case .mbLimiter:
            return "Reset multiband limiter tab to defaults"
        case .expander:
            return "Reset expander tab to defaults"
        case .bassClipper:
            return "Reset bass clipper tab to defaults"
        case .dcClipper:
            return "Reset audio clipper tab to defaults"
        case .hfClipper:
            return "Reset HF clipper tab to defaults"
        case .widener:
            return "Reset Widener tab to defaults"
        case .limiter:
            return "Reset audio limiter tab to defaults"
        case .bs412:
            return "Reset BS.412 tab to defaults"
        case .stereoCoder:
            return "Reset stereo coder tab to defaults"
        case .compositeClipper:
            return "Reset composite clipper tab to defaults"
        case .finalStage:
            return "Reset Final Stage tab to defaults"
        }
    }
}

enum RDSTab: String, CaseIterable, Identifiable {
    case control = "Status"
    case program = "Program"
    case radiotext = "Radiotext"
    case longPS = "Long PS"
    case af = "AF"
    case schedule = "Schedule"
    case carrier = "Carrier"

    var id: String { rawValue }

    var resetButtonTitle: String {
        switch self {
        case .control: return "Reset Status Tab"
        case .program: return "Reset Program Tab"
        case .radiotext: return "Reset Radiotext Tab"
        case .longPS: return "Reset Long PS Tab"
        case .af: return "Reset AF Tab"
        case .schedule: return "Reset Schedule Tab"
        case .carrier: return "Reset Carrier Tab"
        }
    }

    var resetStatusText: String {
        switch self {
        case .control: return "Reset RDS status tab to defaults"
        case .program: return "Reset RDS program tab to defaults"
        case .radiotext: return "Reset RDS radiotext tab to defaults"
        case .longPS: return "Reset RDS long PS tab to defaults"
        case .af: return "Reset RDS AF tab to defaults"
        case .schedule: return "Reset RDS schedule tab to defaults"
        case .carrier: return "Reset RDS carrier tab to defaults"
        }
    }

    /// Short paragraph explaining what the controls on this tab cover.
    /// Mirrors the `ProcessingTab.helpText` pattern; shown via the shared
    /// `TabHelpBox` above the tab's controls so operators can anchor
    /// without leaving the screen for documentation.
    var helpText: String {
        switch self {
        case .control:
            return "Master enable for the RDS subcarrier plus a live snapshot of what's currently on air (PS, RT, PTYN, Long PS). All RDS data fields here apply live — no engine restart required."
        case .program:
            return "Programme identification: PI code (RDI/EBU-assigned, NL prefix `8`), PTY genre code, optional PTYN extended programme type name, ECC (`E3` for NL), LIC (`1D` for Dutch), plus 4 PS banks and the runtime TP / TA / MS / DI flags. All live-apply."
        case .radiotext:
            return "64-character RadioText (Group 2A) plus RT+ tagging (Group 3A + 11A) for now-playing metadata. Manual buffers cycle on a timer; dynamic mode expands `{title} / {artist} / {now_playing}` macros from the now-playing script. Spec: EN 50067 + TR 307."
        case .longPS:
            return "32-character Long PS via Group 15A (IEC 62106-2:2018). Receivers that decode 15A show the full name; legacy receivers ignore the group and keep using the 8-char PS bank. Pairs with the basic PS bank — don't replace, augment."
        case .af:
            return "Alternative Frequencies (AF). Method A: flat list of all frequencies in the network. Method B: pairs each alternative with the tuned frequency so receivers can group regional variants. Max 25 frequencies for Method A, 12 pairs for Method B (EN 50067 Sec 3.2.1.6.4)."
        case .schedule:
            return "Group sequence (which RDS groups go on air and in what order) plus scheduler policy (auto / standard / custom). Clock-Time enable (Group 4A, minute-aligned MJD) and timezone offset for CT broadcasts also live here."
        case .carrier:
            return "RDS subcarrier physical-layer settings: injection level as % of total FM deviation (2.7 % default = 2 kHz, ITU-R BS.450 spec range 1.3-10 %). Carrier is fixed at 57 kHz locked to 3x pilot per EN 50067 Sec 2.1.4. Restart required."
        }
    }
}

/// Unified flat selection used by the sidebar list.
/// One case per top-level + sub-tab from the legacy AppSection / ProcessingTab
/// / RDSTab enums. The view model derives the legacy enums from `selectedStage`
/// so existing per-tab views (which still bind to selectedProcessingTab /
/// selectedRDSTab internally for their reset buttons) keep working during the
/// phased migration. Eventually those legacy enums become removable.
enum Stage: String, CaseIterable, Identifiable {
    // Monitoring
    case monitoring

    // Processing
    case processingOverview
    case processingFormatProfile
    case processingCore
    case processingPhaseRotator
    case processingAGC
    case processingParametricEQ
    case processingMultiband
    case processingAdvancedDynamics
    case processingExpander
    case processingMBLimiter
    case processingWidener
    case processingPrimeBass
    case processingBassClipper
    case processingDCClipper
    case processingHFClipper
    case processingLimiter
    case processingStereoCoder
    case processingCompositeClipper
    case processingBS412
    case processingFinalStage

    // RDS — Control is the primary landing; the rest are detail tabs.
    case rdsControl
    case rdsProgram
    case rdsRadiotext
    case rdsLongPS
    case rdsAF
    case rdsSchedule
    case rdsCarrier

    // Tools
    case testTone
    case snapshots

    var id: String { rawValue }

    /// Sidebar group this stage belongs to.
    enum Group: String, CaseIterable {
        case monitoring = "Monitoring"
        case processing = "Processing"
        case rds = "RDS"
        case tools = "Tools"
    }

    var group: Group {
        switch self {
        case .monitoring:
            return .monitoring
        case .rdsControl, .rdsProgram, .rdsRadiotext, .rdsLongPS,
             .rdsAF, .rdsSchedule, .rdsCarrier:
            return .rds
        case .testTone, .snapshots:
            return .tools
        default:
            return .processing
        }
    }

    /// Stages that operate only in the composite domain and are therefore
    /// meaningless in processed-audio output mode (no pilot / subcarrier / RDS /
    /// composite): the whole RDS group plus the composite clipper, BS.412, and the
    /// Final Stage (final drive, MPX deviation, composite safety limiter, budget).
    /// The UI hides these when processed-audio output is selected. The Core tab
    /// stays (input gain, mono, pre-emphasis, output level all still apply).
    var hiddenInProcessedAudio: Bool {
        switch self {
        case .processingStereoCoder, .processingCompositeClipper, .processingBS412,
             .processingFinalStage:
            return true
        default:
            return group == .rds
        }
    }

    /// Sidebar row label.
    var label: String {
        switch self {
        case .monitoring: return "Monitoring"
        case .processingOverview: return "Overview"
        case .processingFormatProfile: return "Format Profile"
        case .processingCore: return "Core"
        case .processingAGC: return "AGC"
        case .processingPhaseRotator: return "Phase Rotator"
        case .processingParametricEQ: return "Parametric EQ"
        case .processingPrimeBass: return "PrimeBass"
        case .processingWidener: return "Stereo Widener"
        case .processingMultiband: return "Multiband"
        case .processingAdvancedDynamics: return "Advanced Dynamics"
        case .processingMBLimiter: return "MB Limiter"
        case .processingExpander: return "Expander"
        case .processingBassClipper: return "Bass Clipper"
        case .processingDCClipper: return "Audio Clipper"
        case .processingHFClipper: return "HF Limiter / Clipper"
        case .processingLimiter: return "Audio Limiter"
        case .processingBS412: return "BS.412"
        case .processingStereoCoder: return "Stereo Coder"
        case .processingCompositeClipper: return "Composite Clipper"
        case .processingFinalStage: return "Final Stage"
        case .rdsControl: return "Status"
        case .rdsProgram: return "Identity"
        case .rdsRadiotext: return "Radiotext"
        case .rdsLongPS: return "Long PS"
        case .rdsAF: return "Alt. Frequencies"
        case .rdsSchedule: return "Schedule"
        case .rdsCarrier: return "Subcarrier"
        case .testTone: return "Test Tone"
        case .snapshots: return "Presets"
        }
    }

    /// SF Symbols icon used in the sidebar row.
    var icon: String {
        switch self {
        case .monitoring: return "waveform"
        case .processingOverview: return "square.grid.2x2"
        case .processingFormatProfile: return "tag"
        case .processingCore: return "slider.horizontal.3"
        case .processingAGC: return "gauge.with.needle"
        case .processingPhaseRotator: return "arrow.triangle.2.circlepath"
        case .processingParametricEQ: return "dial.high"
        case .processingPrimeBass: return "waveform.path"
        case .processingWidener: return "rectangle.expand.vertical"
        case .processingMultiband: return "chart.bar.xaxis"
        case .processingAdvancedDynamics: return "wand.and.stars"
        case .processingMBLimiter: return "chart.bar.fill"
        case .processingExpander: return "arrow.up.right.and.arrow.down.left"
        case .processingBassClipper: return "speaker.wave.1"
        case .processingDCClipper: return "scissors"
        case .processingHFClipper: return "speaker.wave.3"
        case .processingLimiter: return "rectangle.compress.vertical"
        case .processingBS412: return "doc.badge.gearshape"
        case .processingStereoCoder: return "dot.radiowaves.left.and.right"
        case .processingCompositeClipper: return "rectangle.stack"
        case .processingFinalStage: return "flag.checkered"
        case .rdsControl: return "switch.2"
        case .rdsProgram: return "dot.radiowaves.left.and.right"
        case .rdsRadiotext: return "text.bubble"
        case .rdsLongPS: return "text.alignleft"
        case .rdsAF: return "list.dash"
        case .rdsSchedule: return "calendar.badge.clock"
        case .rdsCarrier: return "antenna.radiowaves.left.and.right"
        case .testTone: return "waveform.badge.plus"
        case .snapshots: return "bookmark.fill"
        }
    }

    /// Detail title shown in the content header (was `AppSection.detailTitle`).
    var detailTitle: String { label }

    /// Detail subtitle shown beneath the title.
    var detailSubtitle: String {
        switch self {
        case .monitoring: return "Overview and live status"
        case .processingOverview: return "DSP chain status at a glance"
        case .processingFormatProfile: return "Station Format selector (atomic per-format DSP bundle)"
        case .processingCore: return "Bypass, mono, gains, HPF, LPF, HF trim"
        case .processingAGC: return "Wideband AGC with K-weighting"
        case .processingPhaseRotator: return "Allpass phase rotator"
        case .processingParametricEQ: return "4-band parametric EQ"
        case .processingPrimeBass: return "Post-multiband bass and harmonic enhancement"
        case .processingWidener: return "Post-multiband stereo widening plus mono bass control"
        case .processingMultiband: return "3 / 5-band multiband compressor"
        case .processingAdvancedDynamics: return "Single-stage leveler (replaces AGC + Multiband)"
        case .processingMBLimiter: return "Per-band fast peak limiter"
        case .processingExpander: return "Per-band downward expander"
        case .processingBassClipper: return "Pre-clip the low band before the chain"
        case .processingDCClipper: return "Audio-band peak clipper"
        case .processingHFClipper: return "Pre-emphasis-aware HF clipper"
        case .processingLimiter: return "Pre-encode peak limiter on L/R audio (4x oversampled)"
        case .processingBS412: return "ITU-R BS.412 MPX power limiter"
        case .processingStereoCoder: return "Pilot-locked stereo encoder (SSB option)"
        case .processingCompositeClipper: return "16x oversampled composite clipper"
        case .processingFinalStage: return "Final drive, MPX safety, budget, deviation"
        case .rdsControl: return "Master enable + live snapshot of what's on air"
        case .rdsProgram: return "Identification: PI, PTY, PTYN, ECC, PS banks, runtime flags"
        case .rdsRadiotext: return "Radiotext + RT+ tagging"
        case .rdsLongPS: return "32-character Long PS (15A)"
        case .rdsAF: return "Alternative frequencies (AF)"
        case .rdsSchedule: return "Group sequence, scheduler policy, clock"
        case .rdsCarrier: return "Injection level, subcarrier frequency, pulse shaping"
        case .testTone: return "Sine, pink, or white — replaces audio input when enabled"
        case .snapshots: return "Named presets — save / recall the full configuration"
        }
    }

    /// Maps to the legacy AppSection enum so existing `selectedSection`-gated
    /// code (engine analysis capture, monitoring spectrum updates) keeps
    /// working without touching the audio path. Removable once the
    /// audio-thread side is decoupled.
    var legacySection: AppSection {
        switch group {
        case .monitoring: return .monitoring
        case .processing: return .processing
        case .rds: return .rds
        // Test Tone reads as Monitoring for the legacy section gate so
        // scope / spectrum analysis capture stays engaged while the
        // operator tunes a tone — the use case is observation of the
        // tone moving through the chain.
        case .tools: return .monitoring
        }
    }

    /// Maps to the legacy ProcessingTab enum (nil for non-processing stages).
    /// Used to drive the existing per-tab views and their reset buttons.
    var legacyProcessingTab: ProcessingTab? {
        switch self {
        case .processingOverview: return .overview
        case .processingFormatProfile: return .formatProfile
        case .processingCore: return .core
        case .processingAGC: return .agc
        case .processingPhaseRotator: return .phaseRotator
        case .processingParametricEQ: return .parametricEQ
        case .processingPrimeBass: return .primeBass
        case .processingWidener: return .widener
        case .processingMultiband: return .multiband
        case .processingAdvancedDynamics: return .advancedDynamics
        case .processingMBLimiter: return .mbLimiter
        case .processingExpander: return .expander
        case .processingBassClipper: return .bassClipper
        case .processingDCClipper: return .dcClipper
        case .processingHFClipper: return .hfClipper
        case .processingLimiter: return .limiter
        case .processingBS412: return .bs412
        case .processingStereoCoder: return .stereoCoder
        case .processingCompositeClipper: return .compositeClipper
        case .processingFinalStage: return .finalStage
        default: return nil
        }
    }

    /// Maps to the legacy RDSTab enum (nil for non-RDS stages).
    var legacyRDSTab: RDSTab? {
        switch self {
        case .rdsControl: return .control
        case .rdsProgram: return .program
        case .rdsRadiotext: return .radiotext
        case .rdsLongPS: return .longPS
        case .rdsAF: return .af
        case .rdsSchedule: return .schedule
        case .rdsCarrier: return .carrier
        default: return nil
        }
    }
}

struct PresetChoice: Identifiable {
    let id: String
    let title: String
}

enum MonitoringBufferHealth: String {
    case ok = "OK"
    case warn = "Warn"
    case bad = "Dropouts"
}

struct MonitoringStreamHealth {
    var isRunning: Bool = false
    var inputName: String = "None"
    var renderHz: Int = 0
    var inputHz: Int = 0
    var blockFrames: Int = 0
    var ringFrames: Int = 0
    var ringCapacity: Int = 0
    var overflowsRecent: Int = 0
    var underflowsRecent: Int = 0
    var overflowsTotal: Int = 0
    var underflowsTotal: Int = 0

    static let stopped = MonitoringStreamHealth()

    var ringFill: Double {
        guard ringCapacity > 0 else { return 0.0 }
        return Double(ringFrames) / Double(ringCapacity)
    }

    var dropoutsRecent: Int {
        overflowsRecent + underflowsRecent
    }

    var bufferHealth: MonitoringBufferHealth {
        guard isRunning else { return .ok }
        if dropoutsRecent >= 3 { return .bad }
        if dropoutsRecent > 0 { return .warn }
        // Time-based "buffer dangerously empty" warning. The input ring
        // capacity is intentionally oversized (~1 s) to absorb extreme
        // jitter; steady-state fill is ~100 ms / 6 % of capacity. The
        // useful threshold is "less than 20 ms of audio buffered" — past
        // that point, any callback that overruns its deadline will
        // underflow. Capacity-relative thresholds (e.g. < 15 %) trip
        // continuously at all healthy operating points and are noise.
        if inputHz > 0 {
            let twentyMsFrames = inputHz / 50
            if ringFrames < twentyMsFrames { return .warn }
        }
        return .ok
    }

    var rateSummary: String {
        if inputHz > 0, renderHz > 0, inputHz != renderHz {
            return "\(inputHz) -> \(renderHz) Hz"
        }
        let effective = max(renderHz, inputHz)
        return effective > 0 ? "\(effective) Hz" : "n/a"
    }

    var bufferSummary: String {
        guard isRunning else { return "n/a" }
        switch bufferHealth {
        case .ok:
            return MonitoringBufferHealth.ok.rawValue
        case .warn:
            return MonitoringBufferHealth.warn.rawValue
        case .bad:
            return "\(MonitoringBufferHealth.bad.rawValue) (\(dropoutsRecent))"
        }
    }

    var estimatedDelayMS: Double? {
        guard isRunning, renderHz > 0 else { return nil }
        let renderBlockMS = (Double(max(1, blockFrames)) / Double(renderHz)) * 1000.0
        if inputHz > 0 {
            return (Double(max(0, ringFrames)) / Double(inputHz)) * 1000.0 + renderBlockMS
        }
        return renderBlockMS
    }
}

struct PeakHoldState {
    var value: Float = 0.0
    var holdRemaining: Double = 0.0
}

struct AudioPeakHoldState {
    var db: Float = -120.0
    var holdRemaining: Double = 0.0
}

#endif  // os(macOS)
