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

/// Coarse engine-side gate for metering and analysis capture: which kind of
/// page is on screen. Not shown to the operator (the sidebar shows `Stage`).
enum AppSection: String, CaseIterable, Identifiable {
    case monitoring
    case processing
    case rds

    var id: String { rawValue }
}

/// The Sound pages, keyed by the dashboard's page id. Every operator-facing
/// string (title, reset button, help) comes from `Stage`, the one name table;
/// this enum only selects which page view to draw.
enum ProcessingTab: String, CaseIterable, Identifiable {
    case overview
    case core
    case phaseRotator
    case agc
    case parametricEQ
    case multiband
    case advancedDynamics = "advanced_dynamics"
    case expander
    case mbLimiter
    case primeBass
    case bassClipper
    case dcClipper
    case hfLimiter
    case limiter
    case stereoCoder
    case compositeClipper
    case bs412
    case finalStage

    var id: String { rawValue }

    /// Inverse of `Stage.legacyProcessingTab`. Cards in the Sound Overview
    /// grid use this to jump the sidebar selection to the stage's page.
    var stage: Stage {
        switch self {
        case .overview: return .processingOverview
        case .core: return .processingCore
        case .phaseRotator: return .processingPhaseRotator
        case .agc: return .processingAGC
        case .parametricEQ: return .processingParametricEQ
        case .multiband: return .processingMultiband
        case .advancedDynamics: return .processingAdvancedDynamics
        case .expander: return .processingExpander
        case .mbLimiter: return .processingMBLimiter
        case .primeBass: return .processingPrimeBass
        case .bassClipper: return .processingBassClipper
        case .dcClipper: return .processingDCClipper
        case .hfLimiter: return .processingHFLimiter
        case .limiter: return .processingLimiter
        case .stereoCoder: return .processingStereoCoder
        case .compositeClipper: return .processingCompositeClipper
        case .bs412: return .processingBS412
        case .finalStage: return .processingFinalStage
        }
    }

    var helpText: String { stage.helpText }
    var resetButtonTitle: String { stage.resetButtonTitle }
    var resetStatusText: String { stage.resetStatusText }
}

/// The RDS pages, keyed by the dashboard's page id. Strings come from
/// `Stage`, as for `ProcessingTab`.
enum RDSTab: String, CaseIterable, Identifiable {
    case control = "rdsStatus"
    case program = "rdsIdentity"
    case radiotext = "rdsRadiotext"
    case af = "rdsAF"
    case schedule = "rdsSchedule"
    case carrier = "rdsSubcarrier"

    var id: String { rawValue }

    var stage: Stage {
        switch self {
        case .control: return .rdsControl
        case .program: return .rdsProgram
        case .radiotext: return .rdsRadiotext
        case .af: return .rdsAF
        case .schedule: return .rdsSchedule
        case .carrier: return .rdsCarrier
        }
    }

    var helpText: String { stage.helpText }
    var resetButtonTitle: String { stage.resetButtonTitle }
    var resetStatusText: String { stage.resetStatusText }

    /// Only the subcarrier's physical layer (`rds_level`) needs an engine
    /// restart; every other RDS page's keys apply live.
    var resetNeedsRestart: Bool { self == .carrier }
}

/// Unified flat selection used by the sidebar list, and THE name table: a
/// page's sidebar label is its master name, and the page title, the reset
/// button, the Overview card, the signal-flow chip, the help box and the web
/// dashboard's page (`schema.json`, held equal by `LayoutNameTableTests`) all
/// derive from the tables below. Never spell a stage's name anywhere else.
enum Stage: String, CaseIterable, Identifiable {
    // On Air
    case monitoring

    // Setup
    case audioIO

    // Sound
    case processingOverview
    case processingCore
    case processingPhaseRotator
    case processingAGC
    case processingParametricEQ
    case processingMultiband
    case processingAdvancedDynamics
    case processingExpander
    case processingMBLimiter
    case processingPrimeBass
    case processingBassClipper
    case processingDCClipper
    case processingHFLimiter
    case processingLimiter
    case processingStereoCoder
    case processingCompositeClipper
    case processingBS412
    case processingFinalStage

    // RDS -- Status is the landing page.
    case rdsControl
    case rdsProgram
    case rdsRadiotext
    case rdsAF
    case rdsSchedule
    case rdsCarrier

    // Setup (Test Tone) and Presets and System
    case testTone
    case snapshots

    var id: String { rawValue }

    /// Sidebar section this stage belongs to -- the operator-facing taxonomy
    /// shared with the web dashboard (`NavigationSection` in
    /// Control/StageApplicability.swift is the one table; this enum is its
    /// GUI face and `title` reads from it).
    enum Group: String, CaseIterable {
        case onAir, setup, sound, rds, system

        var section: NavigationSection {
            switch self {
            case .onAir: return .onAir
            case .setup: return .setup
            case .sound: return .sound
            case .rds: return .rds
            case .system: return .system
            }
        }

        var title: String { section.title }
    }

    var group: Group {
        switch self {
        case .monitoring:
            return .onAir
        case .audioIO, .testTone:
            return .setup
        case .rdsControl, .rdsProgram, .rdsRadiotext,
             .rdsAF, .rdsSchedule, .rdsCarrier:
            return .rds
        case .snapshots:
            return .system
        default:
            return .sound
        }
    }

    /// The dashboard's page id for this stage (`schema.json`), so both front
    /// ends name the same page the same way.
    var schemaPageID: String {
        if let tab = legacyProcessingTab { return tab.rawValue }
        if let tab = legacyRDSTab { return tab.rawValue }
        switch self {
        case .monitoring: return "monitoring"
        case .audioIO: return "interfaces"
        case .testTone: return "testTone"
        case .snapshots: return "presets"
        default: return rawValue
        }
    }

    /// The Sound stage for a dashboard page id, so the sidebar can lay the
    /// Sound section out from `StageGroup.pageIDs` -- the same order the
    /// dashboard shows.
    static func stage(forSchemaPage id: String) -> Stage? {
        ProcessingTab(rawValue: id)?.stage
    }

    /// The Sound section's rows in dashboard order: landing pages, then each
    /// `StageGroup` with its stages (de-duplicated where two dashboard pages
    /// share one GUI page).
    static var soundGroups: [(group: StageGroup, stages: [Stage])] {
        StageGroup.allCases.map { g in
            var seen: Set<Stage> = []
            let stages = g.pageIDs.compactMap(stage(forSchemaPage:)).filter { seen.insert($0).inserted }
            return (g, stages)
        }
    }
    static var soundLandingStages: [Stage] { StageGroup.soundLandingPageIDs.compactMap(stage(forSchemaPage:)) }

    /// The part of the chain this sidebar stage configures, or nil when the
    /// stage applies in every operating mode. The applicability rules live in
    /// `ChainFeature` -- one table for the GUI, the dashboard and the engine.
    var chainFeature: ChainFeature? {
        switch self {
        case .processingStereoCoder: return .stereoCoder
        case .processingCompositeClipper: return .compositeClipper
        case .processingBS412: return .bs412
        case .processingFinalStage: return .finalStage
        case .processingHFLimiter: return .hfLimiter
        default: return group == .rds ? .rds : nil
        }
    }

    /// Does this stage configure anything that has a function in `mode`?
    func applies(in mode: AppConfig.OperatingMode) -> Bool {
        chainFeature?.applies(in: mode) ?? true
    }

    /// The levelling engine this stage belongs to, or nil for a stage every
    /// engine shows. The ownership table is `LevellingEngine.pageIDs` in
    /// Control/StageApplicability.swift (shared with the dashboard); this is
    /// its GUI face, keyed by the dashboard page id the stage answers to.
    var levellingEngine: LevellingEngine? {
        LevellingEngine.engine(forPage: schemaPageID)
    }

    /// Master name: sidebar row, page title, Overview card, reset button and
    /// the dashboard's page title.
    var label: String {
        switch self {
        case .monitoring: return "Monitoring"
        case .audioIO: return "Audio I/O"
        case .processingOverview: return "Overview"
        case .processingCore: return "Basics"
        case .processingAGC: return "AGC"
        case .processingPhaseRotator: return "Phase Rotator"
        case .processingParametricEQ: return "Parametric EQ"
        case .processingPrimeBass: return "PrimeBass"
        case .processingMultiband: return "Multiband"
        case .processingAdvancedDynamics: return "Advanced Dynamics"
        case .processingMBLimiter: return "Band Limiter"
        case .processingExpander: return "Expander"
        case .processingBassClipper: return "Bass Clipper"
        case .processingDCClipper: return "Audio Clipper"
        case .processingHFLimiter: return "HF Limiter"
        case .processingLimiter: return "Audio Limiter"
        case .processingBS412: return "BS.412"
        case .processingStereoCoder: return "Stereo Coder"
        case .processingCompositeClipper: return "Composite Clipper"
        case .processingFinalStage: return "Loudness and Output"
        case .rdsControl: return "Status"
        case .rdsProgram: return "Identity"
        case .rdsRadiotext: return "Radiotext"
        case .rdsAF: return "Alt. Frequencies"
        case .rdsSchedule: return "Schedule"
        case .rdsCarrier: return "Subcarrier"
        case .testTone: return "Test Tone"
        case .snapshots: return "Presets"
        }
    }

    /// The short form for the signal-flow strip (app) and the chain pills
    /// (dashboard), or nil for a stage the strip does not draw: the Expander
    /// and the Band Limiter run per band INSIDE the multiband stage.
    var chipLabel: String? {
        switch self {
        case .processingCore: return "Basics"
        case .processingPhaseRotator: return "Phase"
        case .processingAGC: return "AGC"
        case .processingParametricEQ: return "EQ"
        case .processingMultiband: return "Multiband"
        case .processingAdvancedDynamics: return "Adv Dyn"
        case .processingPrimeBass: return "PrimeBass"
        case .processingBassClipper: return "Bass Clip"
        case .processingDCClipper: return "Audio Clip"
        case .processingHFLimiter: return "HF Lim"
        case .processingLimiter: return "Audio Lim"
        case .processingStereoCoder: return "Coder"
        case .processingCompositeClipper: return "Comp Clip"
        case .processingBS412: return "BS.412"
        case .processingFinalStage: return "Output"
        default: return nil
        }
    }

    /// The stages the signal-flow strip draws, in chain order (the order
    /// `MPXGenerator.processProgramStereo` runs them, then the composite).
    static let signalChain: [Stage] = [
        .processingCore,
        .processingPhaseRotator,
        .processingAGC,
        .processingParametricEQ,
        .processingMultiband,
        .processingAdvancedDynamics,
        .processingPrimeBass,
        .processingBassClipper,
        .processingDCClipper,
        .processingHFLimiter,
        .processingLimiter,
        .processingStereoCoder,
        .processingCompositeClipper,
        .processingBS412,
        .processingFinalStage
    ]

    /// SF Symbols icon used in the sidebar row.
    var icon: String {
        switch self {
        case .monitoring: return "waveform"
        case .audioIO: return "cable.connector.horizontal"
        case .processingOverview: return "square.grid.2x2"
        case .processingCore: return "slider.horizontal.3"
        case .processingAGC: return "gauge.with.needle"
        case .processingPhaseRotator: return "arrow.triangle.2.circlepath"
        case .processingParametricEQ: return "dial.high"
        case .processingPrimeBass: return "waveform.path"
        case .processingMultiband: return "chart.bar.xaxis"
        case .processingAdvancedDynamics: return "wand.and.stars"
        case .processingMBLimiter: return "chart.bar.fill"
        case .processingExpander: return "arrow.up.right.and.arrow.down.left"
        case .processingBassClipper: return "speaker.wave.1"
        case .processingDCClipper: return "scissors"
        case .processingHFLimiter: return "speaker.wave.3"
        case .processingLimiter: return "rectangle.compress.vertical"
        case .processingBS412: return "doc.badge.gearshape"
        case .processingStereoCoder: return "dot.radiowaves.left.and.right"
        case .processingCompositeClipper: return "rectangle.stack"
        case .processingFinalStage: return "flag.checkered"
        case .rdsControl: return "switch.2"
        case .rdsProgram: return "dot.radiowaves.left.and.right"
        case .rdsRadiotext: return "text.bubble"
        case .rdsAF: return "list.dash"
        case .rdsSchedule: return "calendar.badge.clock"
        case .rdsCarrier: return "antenna.radiowaves.left.and.right"
        case .testTone: return "waveform.badge.plus"
        case .snapshots: return "bookmark.fill"
        }
    }

    /// Page title in the content header: the sidebar label, exactly.
    var detailTitle: String { label }

    /// One plain sentence under the page title saying what the page is for
    /// (also the dashboard page's `sub`).
    var detailSubtitle: String {
        switch self {
        case .monitoring: return "Live levels, headroom and stream health."
        case .audioIO: return "Operating mode, devices and level calibration."
        case .processingOverview: return "Format profile, levelling engine and every stage at a glance."
        case .processingCore: return "Mono, input filters and HF trim."
        case .processingAGC: return "Slow wideband levelling ahead of the multiband."
        case .processingPhaseRotator: return "Makes voice waveforms more symmetrical."
        case .processingParametricEQ: return "Four-band tone shaping ahead of the dynamics."
        case .processingPrimeBass: return "Bass enhancement and mono bass."
        case .processingMultiband: return "3-band or 5-band compressor."
        case .processingAdvancedDynamics: return "Single-stage leveller that replaces AGC and Multiband."
        case .processingMBLimiter: return "Per-band peak limiter after the multiband."
        case .processingExpander: return "Per-band downward expander."
        case .processingBassClipper: return "Clips low-frequency peaks."
        case .processingDCClipper: return "Clips audio-band peaks before pre-emphasis."
        case .processingHFLimiter: return "Controls high frequencies after pre-emphasis."
        case .processingLimiter: return "True-peak limiter ahead of the stereo coder."
        case .processingBS412: return "ITU-R BS.412 multiplex power limiter."
        case .processingStereoCoder: return "Pilot-locked stereo encoder with an SSB option."
        case .processingCompositeClipper: return "Clips the composite while protecting pilot, stereo and RDS."
        case .processingFinalStage: return "Final drive, broadcast preset and safety limiter."
        case .rdsControl: return "Turn RDS on and see what is on air."
        case .rdsProgram: return "Station code, programme type and station name."
        case .rdsRadiotext: return "Radiotext messages, RT+ and now playing."
        case .rdsAF: return "Other frequencies that carry this programme."
        case .rdsSchedule: return "Group sequence and clock time."
        case .rdsCarrier: return "RDS injection level."
        case .testTone: return "Line-up tone that replaces the input."
        case .snapshots: return "Eight slots that save and recall the whole sound."
        }
    }

    /// What the page is for, shown in the `TabHelpBox` at the bottom of every
    /// page (and as the dashboard page's `help`). One source: never restate
    /// it in a card caption. Mechanism and standards go in control tooltips.
    var helpText: String {
        switch self {
        case .monitoring:
            return "Everything on air at a glance: levels, modulation, gain reduction, subcarriers and stream health. The Levels, Spectrum and Scopes windows show the same signals larger."
        case .audioIO:
            return "Choose the operating mode, the input and output devices and the listening monitor, then calibrate the levels. Input Gain, Output Level and Line Output are rig calibration, remembered per device: profiles, presets and page resets never change them. Device, channel, sample-rate and block-size changes restart the engine."
        case .processingOverview:
            return "Pick the station's Format Profile and the levelling engine, then check every stage at a glance. Click a card to open its page; the switch on a card turns the stage on or off."
        case .processingCore:
            return "Basic programme conditioning ahead of the dynamics: mono mode, the input high-pass filter, the programme lowpass and an HF trim shelf. Bypass is in the toolbar; pre-emphasis is on Audio I/O."
        case .processingPhaseRotator:
            return "An all-pass phase rotator that makes asymmetrical waveforms, voice especially, more symmetrical without changing the tonal balance. That frees 3 to 4 dB of headroom for the dynamics stages that follow."
        case .processingAGC:
            return "Wideband automatic gain control: rides the long-term level so quiet and loud sources reach the multiband at a similar loudness. It sets the platform; it is not the final loudness stage."
        case .processingParametricEQ:
            return "Four-band parametric EQ (low shelf, two peaking bands, high shelf) on left and right, ahead of the multiband. Use it for station-wide tonal shaping."
        case .processingMultiband:
            return "Multiband compressor that splits the programme into 3 or 5 bands, each with its own gain ride. It is the main control for loudness and tonal density."
        case .processingAdvancedDynamics:
            return "A single-stage leveller that replaces both the AGC and the multiband compressor with one 5-band stage, so levelling and density shaping never fight. Set the sound you want (target, balance, density); the stage adapts its own speed to the programme."
        case .processingExpander:
            return "Per-band downward expander: lowers the gain when a band falls below the threshold, so background noise is not lifted while programme material passes untouched."
        case .processingMBLimiter:
            return "Fast per-band peak limiter after the multiband compressor. It catches peaks inside each band before the bands are recombined, so the multiband can be driven harder without overshoot."
        case .processingPrimeBass:
            return "PrimeBass adds perceived bass through harmonic synthesis while lowering the true low-frequency peak, which saves headroom downstream. Mono Bass sums left and right below a chosen frequency so sub-bass side energy cannot waste deviation or upset mono compatibility."
        case .processingBassClipper:
            return "Oversampled clipper on the low band, after PrimeBass. Use it when kick drums and bass lines still push into the limiters that follow."
        case .processingDCClipper:
            return "Oversampled audio-band clipper with distortion cancellation. It cleans up audio peaks before pre-emphasis adds its high-frequency boost."
        case .processingHFLimiter:
            return "Rides only the pre-emphasis boost: when a cymbal or hi-hat overshoots after pre-emphasis, it briefly loses part of its boost instead of the Audio Limiter pulling the whole mix down. Gain-riding, so it adds no clipping distortion. The top octave above 13 kHz has its own, tighter threshold."
        case .processingLimiter:
            return "Oversampled true-peak limiter on left and right, linked, with look-ahead and a high-frequency transient detector. It catches the peaks that get past every stage upstream before the audio is encoded."
        case .processingBS412:
            return "Holds the average multiplex power over any 60 seconds at or below the ITU-R BS.412 limit. A standards implementation for regulators that enforce BS.412; leave it off where it does not apply."
        case .processingStereoCoder:
            return "The stereo encoder: L+R plus L-R on the 38 kHz subcarrier, with the pilot and RDS added after all peak control. Stereo encoding is always on; the optional SSB mode leans the subcarrier towards single sideband to reclaim composite headroom ahead of the clipper."
        case .processingCompositeClipper:
            return "Oversampled clipper on the assembled composite and the main loudness control in MPX Output. It keeps clipping distortion out of the pilot, the stereo subcarrier and the RDS band so receivers decode cleanly."
        case .processingFinalStage:
            return "Final Drive sets how hard the audio hits the composite clipper: the primary loudness control. The Broadcast Preset sets the AGC target and Final Drive together. The safety limiter on the final multiplex catches what remains while pilot and RDS stay at a constant level. Deviation and output level are on Audio I/O."
        case .rdsControl:
            return "Turns the RDS subcarrier on or off and shows what is on air now. TA, TP and MS are the switches an operator changes during the day. Every RDS setting applies live."
        case .rdsProgram:
            return "Who the station is: the PI code from your broadcasting authority, the programme type (PTY), the extended country code (ECC), four 8-character station names (PS) and the 32-character Long PS. Language, PIN, PTYN and decoder information are under Advanced. Everything applies live."
        case .rdsRadiotext:
            return "Up to 64 characters of Radiotext, with RT+ tags so receivers can show artist and title. Manual messages rotate on a timer; the now-playing script fills the {artist} and {title} macros."
        case .rdsAF:
            return "Alternative frequencies let a receiver move to a stronger transmitter carrying the same programme. Method A lists every frequency in the network (up to 25); Method B pairs each alternative with the tuned frequency (up to 12 pairs)."
        case .rdsSchedule:
            return "Which RDS groups go on air and how often, and the clock time (CT) with its time zone. Automatic scheduling follows the standard group rates for the features you enable."
        case .rdsCarrier:
            return "How much deviation the 57 kHz RDS subcarrier takes. 2.0 kHz is typical; the subcarrier is locked to three times the pilot. A change applies after an engine restart."
        case .testTone:
            return "A line-up generator for calibrating levels and deviation. While it is on, the tone replaces the input and bypasses the processing chain, so its level arrives at the output unchanged."
        case .snapshots:
            return "Save the current settings to one of eight slots and load them back later. Devices, level calibration and the operating mode stay as installed."
        }
    }

    /// Pages with settings of their own to put back. Monitoring shows only,
    /// Audio I/O is rig calibration (never reset by a page button), Presets
    /// holds slots and the Overview's choices each have their own control.
    var hasReset: Bool {
        switch self {
        case .monitoring, .audioIO, .processingOverview, .snapshots: return false
        default: return true
        }
    }

    var resetButtonTitle: String { "Reset \(label)" }
    var resetStatusText: String { "\(label) reset to defaults" }

    /// Maps to the legacy AppSection enum so existing `selectedSection`-gated
    /// code (engine analysis capture, monitoring spectrum updates) keeps
    /// working without touching the audio path. Removable once the
    /// audio-thread side is decoupled.
    var legacySection: AppSection {
        switch group {
        case .onAir: return .monitoring
        // Setup (Audio I/O, Test Tone) shows live input meters and the tone
        // moving through the chain, so the legacy section gate keeps
        // metering / analysis capture engaged; so does Presets and System.
        case .setup, .system: return .monitoring
        case .sound: return .processing
        case .rds: return .rds
        }
    }

    /// Maps to the ProcessingTab enum (nil for non-Sound stages).
    var legacyProcessingTab: ProcessingTab? {
        ProcessingTab.allCases.first { $0.stage == self }
    }

    /// Maps to the RDSTab enum (nil for non-RDS stages).
    var legacyRDSTab: RDSTab? {
        RDSTab.allCases.first { $0.stage == self }
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

struct MonitoringStreamHealth: Equatable {
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
        // useful threshold is "less than 20 ms of audio buffered" -- past
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
