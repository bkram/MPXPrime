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

// Sizes
private let kWindowWidth: CGFloat = 860
private let kWindowHeight: CGFloat = 440
private let kWindowMinWidth: CGFloat = 760
private let kWindowMinHeight: CGFloat = 380
// Six 64 pt meter strips (~444 pt) + card/window padding fit comfortably in
// ~560 pt; the prior 860/760 defaults left half the window empty (the meters
// are left-aligned, not stretched).
private let kLevelsWindowWidth: CGFloat = 560
private let kLevelsWindowHeight: CGFloat = 560
private let kLevelsWindowMinWidth: CGFloat = 480
private let kLevelsWindowMinHeight: CGFloat = 460
private let kMPXPrimeIconSymbol = "\u{1F3A7}"
private let kScopesWindowTitle = "Scopes"
private let kMPXSpectrumWindowTitle = "MPX Spectrum"
private let kAudioSpectrumWindowTitle = "Audio Spectrum"
private let kLevelsWindowTitle = "Levels"
// Window-frame autosave keys (UserDefaults).
private let kMainWindowAutosaveName = "MPXPrimeStudio.MainWindow"
private let kScopesWindowAutosaveName = "MPXPrimeStudio.ScopesWindow"
private let kSpectrumWindowAutosaveName = "MPXPrimeStudio.SpectrumWindow"
private let kPreMPXSpectrumWindowAutosaveName = "MPXPrimeStudio.PreMPXSpectrumWindow"
private let kLevelsWindowAutosaveName = "MPXPrimeStudio.LevelsWindow"
private let kAboutWindowAutosaveName = "MPXPrimeStudio.AboutWindow"
private let kHelpWindowAutosaveName = "MPXPrimeStudio.HelpWindow"
private let kSettingsWindowAutosaveName = "MPXPrimeStudio.SettingsWindow"
// Compile-time constant URL; literal is well-formed so the optional
// returned by URL(string:) is guaranteed non-nil.
private let kProjectURL = URL(string: "https://github.com/bkram/MPXPrime")!
private let kManualURL = URL(string: "https://github.com/bkram/MPXPrime/blob/main/docs/manual.md")!
private let kLicenseURL = URL(string: "https://github.com/bkram/MPXPrime/blob/main/LICENSE")!
private let kRestartRequiredSettingsListText =
    "Restart required for sample rate, block size, source mode, monitor output routing, input/output/monitor device changes, mono mode, pre-emphasis, pilot/sum/diff levels, program lowpass, and other encoder-structure changes."

private func makeMPXPrimeAppIcon(size: CGFloat = 512) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let bounds = NSRect(origin: .zero, size: image.size)
    let inset = size * 0.07
    let rect = bounds.insetBy(dx: inset, dy: inset)
    let radius = size * 0.22

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -(size * 0.015))
    shadow.set()

    let panelPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.45, blue: 0.63, alpha: 1.0),
        NSColor(calibratedRed: 0.04, green: 0.16, blue: 0.28, alpha: 1.0)
    ])?.draw(in: panelPath, angle: -90)

    NSGraphicsContext.current?.saveGraphicsState()
    panelPath.addClip()

    NSColor.white.withAlphaComponent(0.10).setStroke()
    let borderPath = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.006, dy: size * 0.006), xRadius: radius, yRadius: radius)
    borderPath.lineWidth = size * 0.012
    borderPath.stroke()

    let center = NSPoint(x: bounds.midX, y: bounds.midY)
    let symbolFont = NSFont(name: "Apple Color Emoji", size: size * 0.42)
        ?? NSFont.systemFont(ofSize: size * 0.42, weight: .black)
    let shadowStyle = NSShadow()
    shadowStyle.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadowStyle.shadowBlurRadius = size * 0.02
    shadowStyle.shadowOffset = NSSize(width: 0, height: -(size * 0.012))
    let symbolAttributes: [NSAttributedString.Key: Any] = [
        .font: symbolFont,
        .foregroundColor: NSColor(calibratedWhite: 0.98, alpha: 1.0),
        .shadow: shadowStyle
    ]
    let symbol = NSAttributedString(string: kMPXPrimeIconSymbol, attributes: symbolAttributes)
    let symbolSize = symbol.size()
    let symbolRect = NSRect(
        x: center.x - (symbolSize.width / 2),
        y: center.y - (symbolSize.height / 2) - (size * 0.03),
        width: symbolSize.width,
        height: symbolSize.height
    )
    symbol.draw(in: symbolRect)

    let waveform = NSBezierPath()
    let waveformColor = NSColor(calibratedRed: 0.34, green: 0.84, blue: 0.77, alpha: 0.95)
    let waveformLineWidth = size * 0.022
    let waveformY = rect.maxY - (size * 0.14)
    let waveformLeft = rect.minX + (size * 0.16)
    let waveformWidth = rect.width - (size * 0.32)
    waveform.move(to: NSPoint(x: waveformLeft, y: waveformY))
    waveform.curve(
        to: NSPoint(x: waveformLeft + (waveformWidth * 0.2), y: waveformY),
        controlPoint1: NSPoint(x: waveformLeft + (waveformWidth * 0.05), y: waveformY),
        controlPoint2: NSPoint(x: waveformLeft + (waveformWidth * 0.12), y: waveformY - (size * 0.035))
    )
    waveform.curve(
        to: NSPoint(x: waveformLeft + (waveformWidth * 0.4), y: waveformY),
        controlPoint1: NSPoint(x: waveformLeft + (waveformWidth * 0.28), y: waveformY + (size * 0.055)),
        controlPoint2: NSPoint(x: waveformLeft + (waveformWidth * 0.34), y: waveformY + (size * 0.01))
    )
    waveform.curve(
        to: NSPoint(x: waveformLeft + (waveformWidth * 0.62), y: waveformY),
        controlPoint1: NSPoint(x: waveformLeft + (waveformWidth * 0.47), y: waveformY - (size * 0.06)),
        controlPoint2: NSPoint(x: waveformLeft + (waveformWidth * 0.55), y: waveformY - (size * 0.015))
    )
    waveform.curve(
        to: NSPoint(x: waveformLeft + (waveformWidth * 0.8), y: waveformY),
        controlPoint1: NSPoint(x: waveformLeft + (waveformWidth * 0.69), y: waveformY + (size * 0.05)),
        controlPoint2: NSPoint(x: waveformLeft + (waveformWidth * 0.75), y: waveformY + (size * 0.015))
    )
    waveform.curve(
        to: NSPoint(x: waveformLeft + waveformWidth, y: waveformY),
        controlPoint1: NSPoint(x: waveformLeft + (waveformWidth * 0.88), y: waveformY - (size * 0.035)),
        controlPoint2: NSPoint(x: waveformLeft + (waveformWidth * 0.95), y: waveformY)
    )
    waveform.lineWidth = waveformLineWidth
    waveform.lineCapStyle = .round
    waveform.lineJoinStyle = .round
    waveformColor.setStroke()
    waveform.stroke()

    NSGraphicsContext.current?.restoreGraphicsState()
    image.unlockFocus()
    return image
}

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
    case expander = "Expander"
    case mbLimiter = "MB Limiter"
    case widener = "Widener"
    case primeBass = "PrimeBass"
    case bassClipper = "Bass Clip"
    case dcClipper = "Audio Clip"
    case hfClipper = "HF Clip"
    case limiter = "Audio Limiter"
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
        case .expander: return .processingExpander
        case .mbLimiter: return .processingMBLimiter
        case .widener: return .processingWidener
        case .primeBass: return .processingPrimeBass
        case .bassClipper: return .processingBassClipper
        case .dcClipper: return .processingDCClipper
        case .hfClipper: return .processingHFClipper
        case .limiter: return .processingLimiter
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
            return "Pre-emphasis-aware HF clipper on the high band of the pre-emphasized signal. Tames HF transients with a dedicated stage so the broadband limiter doesn't pull gain across the whole signal and dull it. De-emphasis-correct; default off."
        case .limiter:
            return "Pre-encode L/R peak limiter — 4x oversampled true-peak, stereo-linked — with default-on look-ahead and an HF-subband transient detector. Catches HF transients that slip past everything upstream after pre-emphasis."
        case .bs412:
            return "ITU-R BS.412 rolling-average MPX power limiter for European regulatory compliance (DE / AT / CH / SE / CZ / SI). Slow gain ride over a ~60 s window. Off in NL, US, UK, FR, ES, IT and most other countries."
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
    case processingExpander
    case processingMBLimiter
    case processingWidener
    case processingPrimeBass
    case processingBassClipper
    case processingDCClipper
    case processingHFClipper
    case processingLimiter
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
        case .processingCompositeClipper, .processingBS412, .processingFinalStage:
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
        case .processingMBLimiter: return "MB Limiter"
        case .processingExpander: return "Expander"
        case .processingBassClipper: return "Bass Clipper"
        case .processingDCClipper: return "Audio Clipper"
        case .processingHFClipper: return "HF Clipper"
        case .processingLimiter: return "Audio Limiter"
        case .processingBS412: return "BS.412"
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
        case .processingMBLimiter: return "chart.bar.fill"
        case .processingExpander: return "arrow.up.right.and.arrow.down.left"
        case .processingBassClipper: return "speaker.wave.1"
        case .processingDCClipper: return "scissors"
        case .processingHFClipper: return "speaker.wave.3"
        case .processingLimiter: return "rectangle.compress.vertical"
        case .processingBS412: return "doc.badge.gearshape"
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
        case .processingMBLimiter: return "Per-band fast peak limiter"
        case .processingExpander: return "Per-band downward expander"
        case .processingBassClipper: return "Pre-clip the low band before the chain"
        case .processingDCClipper: return "Audio-band peak clipper"
        case .processingHFClipper: return "Pre-emphasis-aware HF clipper"
        case .processingLimiter: return "Pre-encode peak limiter on L/R audio (4x oversampled)"
        case .processingBS412: return "ITU-R BS.412 MPX power limiter"
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
        case .processingMBLimiter: return .mbLimiter
        case .processingExpander: return .expander
        case .processingBassClipper: return .bassClipper
        case .processingDCClipper: return .dcClipper
        case .processingHFClipper: return .hfClipper
        case .processingLimiter: return .limiter
        case .processingBS412: return .bs412
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

/// One saved snapshot slot — name, save timestamp, and the configuration
/// captured at save time. The config is stored as the same INI text the
/// app already round-trips through `AppConfig.save(toINI:)` /
/// `load(fromINI:)`, embedded in JSON. INI keeps schema migrations
/// handled by the existing parser's defaults (missing keys fall back),
/// so future AppConfig additions don't break older snapshot files.
struct ConfigSnapshot: Identifiable, Codable {
    let id: UUID
    var name: String
    var savedAt: Date
    var configINIText: String
}

/// On-disk JSON envelope for `snapshots.json`. Wraps the slot array so
/// future top-level fields (schema version, app version recorded at
/// save, etc.) can be added without breaking old files.
struct SnapshotFile: Codable {
    var slots: [ConfigSnapshot?]
    /// The preset whose config is currently live (persisted so the "Loaded"
    /// marker survives relaunch). Optional with defaults so older files decode.
    var activeID: UUID?
    var activeModified: Bool?
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

private struct PeakHoldState {
    var value: Float = 0.0
    var holdRemaining: Double = 0.0
}

private struct AudioPeakHoldState {
    var db: Float = -120.0
    var holdRemaining: Double = 0.0
}

private struct FinalStagePreset {
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    private let configPath: String
    private let runSeconds: Double?
    private var window: NSWindow?
    private var model: MPXPrimeViewModel?
    private var scopesWindow: NSWindow?
    private var spectrumWindow: NSWindow?
    private var preMPXSpectrumWindow: NSWindow?
    private var levelsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(configPath: String, runSeconds: Double?) {
        self.configPath = configPath
        self.runSeconds = runSeconds
    }

    private func restoreFrame(for window: NSWindow, autosaveName: String) {
        window.setFrameAutosaveName(autosaveName)
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
    }

    private func revealWindow(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == window {
            sender.orderOut(nil)
            return false
        } else if sender == scopesWindow {
            model?.scopesWindowVisible = false
            sender.orderOut(nil)
            return false
        } else if sender == spectrumWindow {
            model?.spectrumWindowVisible = false
            sender.orderOut(nil)
            return false
        } else if sender == preMPXSpectrumWindow {
            model?.preMPXSpectrumWindowVisible = false
            sender.orderOut(nil)
            return false
        } else if sender == levelsWindow {
            model?.levelsWindowVisible = false
            sender.orderOut(nil)
            return false
        } else if sender == aboutWindow {
            sender.orderOut(nil)
            return false
        } else if sender == helpWindow {
            sender.orderOut(nil)
            return false
        } else if sender == settingsWindow {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        showMainWindow()
        return true
    }

    // MARK: - Visibility-driven monitor refresh rate

    @objc private func appBecameActive() {
        model?.setAppActive(true)
    }

    @objc private func appResignedActive() {
        model?.setAppActive(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard (notification.object as AnyObject?) === window else { return }
        model?.setMainWindowMinimized(true)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard (notification.object as AnyObject?) === window else { return }
        model?.setMainWindowMinimized(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        let visible = w.occlusionState.contains(.visible)
        model?.setMainWindowOccluded(!visible)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = makeMPXPrimeAppIcon()
        NSApp.activate(ignoringOtherApps: true)

        let vm = MPXPrimeViewModel(configPath: configPath)
        model = vm
        setupMainMenu()

        let root = RootView(model: vm)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.center()
        w.title = "MPX Prime Studio"
        w.titleVisibility = .visible
        w.minSize = NSSize(width: 900, height: 620)
        w.delegate = self
        // Host via contentViewController (not a bare contentView) so the
        // SwiftUI .toolbar content in RootView bridges to the window's
        // unified title-bar toolbar and NavigationSplitView's sidebar-collapse
        // toggle appears. Matches how the secondary windows are hosted.
        w.toolbarStyle = .unified
        let mainHost = NSHostingController(rootView: root)
        // Do NOT let the hosting controller drive the window size from the
        // SwiftUI content's ideal size (the default .preferredContentSize):
        // the tall NavigationSplitView would otherwise push the window past
        // the screen and the sidebar would scroll beyond the window. The
        // window manages its own frame; the content fills and scrolls within.
        mainHost.sizingOptions = []
        restoreFrame(for: w, autosaveName: kMainWindowAutosaveName)
        w.contentViewController = mainHost
        w.makeKeyAndOrderFront(nil)
        window = w

        vm.startMonitoringTimer()

        // Drop the meter / scope refresh rate when the app is inactive,
        // minimized, or fully occluded. The on-screen rate is restored
        // immediately when any of these flips back.
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appResignedActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        if vm.autoStartEnabled {
            // The Stop+Start watchdog that used to live here was a
            // workaround for AVAudioEngine's first-start failure on
            // non-default input devices. The input path now uses a
            // direct AUHAL audio unit (`InputAUHAL`) per TN2091,
            // which doesn't have that bug — auto-start delivers
            // frames immediately on the first try.
            DispatchQueue.main.async { [weak vm] in
                vm?.startOrStopTransport(forceStart: true)
            }
        }

        if let secs = runSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(applyPendingChanges) {
            menuItem.title = model?.runtimeApplyButtonTitle ?? "Apply Restart"
            return model?.runtimeApplyPending ?? false
        }
        if menuItem.action == #selector(toggleInspector) {
            menuItem.state = (model?.inspectorVisible ?? false) ? .on : .off
            return true
        }
        // Composite-domain windows are meaningless in processed-audio output;
        // disable them (and the RDS section jump). Use the Audio Spectrum window
        // for the processed L/R spectrum.
        if let action = menuItem.action, model?.processedAudioOutputActive == true {
            if action == #selector(showSpectrumWindow) || action == #selector(showScopesWindow)
                || action == #selector(goToRDS) {
                return false
            }
        }
        if let action = menuItem.action,
           action == #selector(goToMonitoring) || action == #selector(goToProcessing)
               || action == #selector(goToRDS) || action == #selector(goToTools) {
            let targetGroup: Stage.Group
            switch action {
            case #selector(goToMonitoring): targetGroup = .monitoring
            case #selector(goToProcessing): targetGroup = .processing
            case #selector(goToRDS): targetGroup = .rds
            default: targetGroup = .tools
            }
            menuItem.state = (model?.selectedStage.group == targetGroup) ? .on : .off
            return true
        }
        return true
    }

    private func setupMainMenu() {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "MPX Prime Studio"
        let mainMenu = NSMenu()

        // App Menu (unchanged)
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        let aboutItem = appMenu.addItem(
            withTitle: "About \(appName)", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = NSMenu(
            title: "Services")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File Menu
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(openConfig), keyEquivalent: "o")
        openItem.target = self
        let saveItem = fileMenu.addItem(withTitle: "Save", action: #selector(saveConfig), keyEquivalent: "s")
        saveItem.target = self
        let saveAsItem = fileMenu.addItem(withTitle: "Save As…", action: #selector(saveConfigAs), keyEquivalent: "S")
        saveAsItem.target = self
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit Menu — without these items the responder chain never routes
        // cut / copy / paste / select all to the focused text field, so those
        // keyboard shortcuts silently do nothing.
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        let dictationItem = editMenu.addItem(
            withTitle: "Start Dictation…",
            action: Selector(("startDictation:")),
            keyEquivalent: "")
        dictationItem.isEnabled = true
        let emojiItem = editMenu.addItem(
            withTitle: "Emoji & Symbols",
            action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
            keyEquivalent: " ")
        emojiItem.keyEquivalentModifierMask = [.control, .command]
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // View Menu — toggles for the right-pane Inspector and other
        // workspace-level visibility states. Standard ⌥⌘I shortcut for
        // inspector matches Pages, Keynote, Logic Pro, Final Cut.
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        let inspectorItem = viewMenu.addItem(
            withTitle: "Inspector",
            action: #selector(toggleInspector),
            keyEquivalent: "i")
        inspectorItem.target = self
        inspectorItem.keyEquivalentModifierMask = [.command, .option]

        viewMenu.addItem(NSMenuItem.separator())
        let testToneItem = viewMenu.addItem(
            withTitle: "Test Tone…",
            action: #selector(showTestToneTab),
            keyEquivalent: "t")
        testToneItem.target = self
        testToneItem.keyEquivalentModifierMask = [.command]

        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Go Menu — ⌘1-⌘4 jump to a sidebar section. Matches the
        // section-shortcut pattern in Mail, Music, Notes (sidebar-driven
        // macOS apps). Each item remembers the last sub-tab visited
        // in that group, so ⌘2 from RDS returns to the Processing
        // sub-tab the operator was last editing.
        let goItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        let goMenu = NSMenu(title: "Go")
        let goMonitoring = goMenu.addItem(
            withTitle: "Monitoring",
            action: #selector(goToMonitoring),
            keyEquivalent: "1")
        goMonitoring.target = self
        let goProcessing = goMenu.addItem(
            withTitle: "Processing",
            action: #selector(goToProcessing),
            keyEquivalent: "2")
        goProcessing.target = self
        let goRDS = goMenu.addItem(
            withTitle: "RDS",
            action: #selector(goToRDS),
            keyEquivalent: "3")
        goRDS.target = self
        let goTools = goMenu.addItem(
            withTitle: "Tools",
            action: #selector(goToTools),
            keyEquivalent: "4")
        goTools.target = self
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        // Control Menu
        let transportItem = NSMenuItem(title: "Control", action: nil, keyEquivalent: "")
        let transportMenu = NSMenu(title: "Control")

        // ⌘T is reserved for "New Tab" per macOS convention; use ⌘Return for
        // the transport toggle instead.
        let startStopItem = transportMenu.addItem(
            withTitle: "Start/Stop", action: #selector(toggleTransport), keyEquivalent: "\r"
        )
        startStopItem.target = self
        startStopItem.keyEquivalentModifierMask = [.command]
        let bypassItem = transportMenu.addItem(
            withTitle: "Bypass", action: #selector(toggleBypass), keyEquivalent: "b")
        bypassItem.target = self
        let resetPeaksItem = transportMenu.addItem(
            withTitle: "Reset Peaks", action: #selector(resetPeaks), keyEquivalent: "r")
        resetPeaksItem.target = self
        transportMenu.addItem(NSMenuItem.separator())
        let applyItem = transportMenu.addItem(
            withTitle: "Apply Restart", action: #selector(applyPendingChanges), keyEquivalent: "A")
        applyItem.target = self
        applyItem.keyEquivalentModifierMask = [.command, .shift]

        transportItem.submenu = transportMenu
        mainMenu.addItem(transportItem)

        // Window Menu
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")

        // No keyEquivalent: ⌘1 is reserved by the Go menu for "Monitoring".
        // Operators jump back to the main window via the Window menu or
        // by clicking on it; this entry just brings it forward when it
        // was hidden behind a detached window.
        let mainWindowItem = windowMenu.addItem(withTitle: "Main", action: #selector(showMainWindow), keyEquivalent: "")
        mainWindowItem.target = self
        let preMPXSpectrumItem = windowMenu.addItem(withTitle: kAudioSpectrumWindowTitle, action: #selector(showPreMPXSpectrumWindow), keyEquivalent: "7")
        preMPXSpectrumItem.target = self
        let spectrumItem = windowMenu.addItem(withTitle: kMPXSpectrumWindowTitle, action: #selector(showSpectrumWindow), keyEquivalent: "8")
        spectrumItem.target = self
        let levelsItem = windowMenu.addItem(withTitle: kLevelsWindowTitle, action: #selector(showLevelsWindow), keyEquivalent: "9")
        levelsItem.target = self
        // ⌘0 is reserved for "Actual Size" per macOS convention. Use ⇧⌘0 so
        // the numeric-window mnemonic is preserved without stepping on zoom.
        let scopesItem = windowMenu.addItem(withTitle: kScopesWindowTitle, action: #selector(showScopesWindow), keyEquivalent: "0")
        scopesItem.target = self
        scopesItem.keyEquivalentModifierMask = [.command, .shift]

        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")

        let openHelp = NSMenuItem(title: "MPX Prime Studio Help", action: #selector(showHelp), keyEquivalent: "/")
        openHelp.target = self
        openHelp.keyEquivalentModifierMask = [.command, .shift]
        helpMenu.addItem(openHelp)

        helpMenu.addItem(NSMenuItem.separator())

        let docs = NSMenuItem(title: "Online Documentation", action: #selector(openDocs), keyEquivalent: "")
        docs.target = self
        docs.isEnabled = true
        helpMenu.addItem(docs)

        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        if let existing = aboutWindow {
            revealWindow(existing)
            return
        }
        let aboutView = AboutSectionView()
        let hostingController = NSHostingController(rootView: aboutView)
        let w = NSWindow(contentViewController: hostingController)
        w.title = "About MPX Prime Studio"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 400, height: 560))
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kAboutWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        aboutWindow = w
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func showHelp() {
        if let existing = helpWindow {
            revealWindow(existing)
            return
        }
        let helpView = HelpWindowView()
        let hostingController = NSHostingController(rootView: helpView)
        let w = NSWindow(contentViewController: hostingController)
        w.title = "MPX Prime Studio Help"
        // Utility/documentation windows should not minimize (macOS HIG —
        // matches About / Settings styleMasks). Resizable so long help
        // text remains usable on smaller displays.
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 560, height: 560))
        w.minSize = NSSize(width: 520, height: 420)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kHelpWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        helpWindow = w
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func openDocs() {
        NSWorkspace.shared.open(kProjectURL)
    }

    @objc private func showSettings() {
        if let existing = settingsWindow {
            revealWindow(existing)
            return
        }
        guard let vm = model else { return }
        let settingsView = SettingsWindowView(model: vm)
        let hostingController = NSHostingController(rootView: settingsView)
        let w = NSWindow(contentViewController: hostingController)
        w.title = "Settings"
        // Settings windows should not minimize (macOS HIG). Keep resizable so
        // long device lists remain usable on small displays.
        w.styleMask = [.titled, .closable, .resizable]
        w.toolbarStyle = .unified
        w.setContentSize(NSSize(width: 780, height: 620))
        w.minSize = NSSize(width: 700, height: 520)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kSettingsWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        settingsWindow = w
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func toggleInspector() {
        guard let vm = model else { return }
        vm.inspectorVisible.toggle()
    }

    @objc private func showTestToneTab() {
        guard let vm = model else { return }
        vm.selectedStage = .testTone
        // Bring the main window forward so ⌘T from a detached
        // visualizer still feels right (the new tab is the focus).
        if let w = window { w.makeKeyAndOrderFront(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func toggleTransport() {
        model?.startOrStopTransport()
    }

    @objc private func toggleBypass() {
        model?.toggleBypass()
    }

    @objc private func resetPeaks() {
        model?.resetPeaks()
    }

    @objc private func goToMonitoring() { model?.goToGroup(.monitoring) }
    @objc private func goToProcessing() { model?.goToGroup(.processing) }
    @objc private func goToRDS() { model?.goToGroup(.rds) }
    @objc private func goToTools() { model?.goToGroup(.tools) }

    @objc private func saveConfig() {
        model?.saveCurrentConfig()
    }

    @objc private func applyPendingChanges() {
        model?.applyPendingRuntimeChanges()
    }

    @objc private func showMainWindow() {
        if let existing = window {
            revealWindow(existing)
            return
        }
        guard let vm = model else { return }
        let root = RootView(model: vm)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.center()
        w.title = "MPX Prime Studio"
        w.titleVisibility = .visible
        w.minSize = NSSize(width: 900, height: 620)
        w.delegate = self
        w.toolbarStyle = .unified
        let mainHost = NSHostingController(rootView: root)
        // See applicationDidFinishLaunching: keep the window sizing itself,
        // not driven by the SwiftUI content's ideal size.
        mainHost.sizingOptions = []
        restoreFrame(for: w, autosaveName: kMainWindowAutosaveName)
        w.contentViewController = mainHost
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc fileprivate func showScopesWindow() {
        // Composite scope is meaningless in processed-audio output.
        if model?.processedAudioOutputActive == true { return }
        if let existing = scopesWindow {
            revealWindow(existing)
            model?.scopesWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let scopesView = ScopesOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: scopesView)
        // Flexibly sized: the window drives the size and the SwiftUI content
        // fills it, so suppress the hosting controller's auto-added min /
        // intrinsic / max Auto Layout constraints. On a high-refresh window
        // this avoids per-update constraint recomputation piling up in AppKit's
        // layout engine -- a documented long-running SwiftUI-on-macOS slowdown.
        hostingController.sizingOptions = []
        let w = NSWindow(contentViewController: hostingController)
        w.title = kScopesWindowTitle
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: kWindowWidth, height: kWindowHeight))
        w.minSize = NSSize(width: kWindowMinWidth, height: kWindowMinHeight)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kScopesWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        scopesWindow = w
        model?.scopesWindowVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Close the composite-only auxiliary windows (MPX Spectrum, Scopes). Invoked
    /// when the engine (re)starts in processed-audio mode so a window left open
    /// from composite mode doesn't keep showing a now-meaningless view.
    @objc fileprivate func closeCompositeOnlyAuxWindows() {
        scopesWindow?.close()
        spectrumWindow?.close()
    }

    @objc fileprivate func showSpectrumWindow() {
        // The composite (MPX) spectrum is meaningless in processed-audio output;
        // the Audio Spectrum window shows the processed L/R spectrum instead.
        if model?.processedAudioOutputActive == true { return }
        if let existing = spectrumWindow {
            revealWindow(existing)
            model?.spectrumWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let spectrumView = SpectrumOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: spectrumView)
        hostingController.sizingOptions = []  // window drives size; avoid per-update constraint churn (see Scopes window)
        let w = NSWindow(contentViewController: hostingController)
        w.title = kMPXSpectrumWindowTitle
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: kWindowWidth, height: kWindowHeight))
        w.minSize = NSSize(width: kWindowMinWidth, height: kWindowMinHeight)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kSpectrumWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        spectrumWindow = w
        model?.spectrumWindowVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc fileprivate func showPreMPXSpectrumWindow() {
        if let existing = preMPXSpectrumWindow {
            revealWindow(existing)
            model?.preMPXSpectrumWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let spectrumView = PreMPXSpectrumOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: spectrumView)
        hostingController.sizingOptions = []  // window drives size; avoid per-update constraint churn (see Scopes window)
        let w = NSWindow(contentViewController: hostingController)
        w.title = kAudioSpectrumWindowTitle
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: kWindowWidth, height: kWindowHeight))
        w.minSize = NSSize(width: kWindowMinWidth, height: kWindowMinHeight)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kPreMPXSpectrumWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        preMPXSpectrumWindow = w
        model?.preMPXSpectrumWindowVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc fileprivate func showLevelsWindow() {
        if let existing = levelsWindow {
            revealWindow(existing)
            model?.levelsWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let levelsView = LevelsOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: levelsView)
        hostingController.sizingOptions = []  // window drives size; avoid per-update constraint churn (see Scopes window)
        let w = NSWindow(contentViewController: hostingController)
        w.title = kLevelsWindowTitle
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: kLevelsWindowWidth, height: kLevelsWindowHeight))
        w.minSize = NSSize(width: kLevelsWindowMinWidth, height: kLevelsWindowMinHeight)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kLevelsWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        levelsWindow = w
        model?.levelsWindowVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc fileprivate func openConfig() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = Self.iniContentTypes
        openPanel.message = "Choose a configuration file to open"
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false

        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            self?.model?.loadConfigFromFile(url.path)
        }
    }

    /// Accepted content types for INI config file dialogs. Falls back to
    /// `UTType.propertyList` if the system cannot resolve a UTType for the
    /// literal `ini` extension (avoids a force-unwrap crash on older systems).
    private static var iniContentTypes: [UTType] {
        if let ini = UTType(filenameExtension: "ini") {
            return [ini]
        }
        return [.propertyList, .plainText]
    }

    @objc private func saveConfigAs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = Self.iniContentTypes
        savePanel.message = "Save configuration as…"
        savePanel.nameFieldStringValue = "config.ini"

        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            self?.model?.saveConfigToFile(url.path)
        }
    }

}

@MainActor
final class MPXPrimeViewModel: ObservableObject {
    private struct RuntimeSnapshot {
        var config: AppConfig
        var sourceMode: String
        var monitorEnabled: Bool
        var processingBypass: Bool
        var inputGainDB: Double
        var selectedInputUID: String
        var selectedOutputUID: String
        var selectedMonitorUID: String
    }

    // Active = main window foreground/key, not minimized, not fully
    // occluded. Idle = app inactive / occluded / minimized. The idle
    // rate stays > 0 so the meter ballistics state remains warm and the
    // UI resumes immediately on bring-forward.
    //
    // Active rate held at 30 Hz: per-tick work in
    // `refreshMonitoringSnapshot` (5 String(format:) calls + 59
    // @Published writes + SwiftUI re-renders) runs on the main thread.
    // Pushing the timer to 60 Hz can preempt the audio render thread on
    // busy machines and cause input-ring / output-buffer drops.
    // Inline spectrum bumped 12 → 24 Hz for a visible smoothness win
    // without doubling main-thread cost; windowed visualizers stay at
    // 30 Hz which is comfortably smooth for the dedicated detached
    // panels.
    // GUI refresh profile is arch-tiered. SwiftUI scope/spectrum Path drawing is
    // main-thread bound, and older Intel Macs (every x86_64 host here) have far
    // lower per-core throughput than Apple Silicon, so the full-rate profile pegs
    // one core and the graphs lag (observed on an i7-9750H). The x86_64 slice
    // therefore runs a lighter profile (lower refresh rates + fewer inline spectrum
    // points); the arm64 slice keeps the original full-rate profile unchanged. This
    // is compile-time per universal-binary slice, so Apple Silicon carries zero
    // runtime cost or behaviour change.
    #if arch(x86_64)
    private static let monitoringRefreshHzActive: Double = 20.0
    private static let monitoringRefreshHzIdle: Double = 12.0
    private static let inlineMPXSpectrumRefreshHz: Double = 15.0
    private static let windowMPXSpectrumRefreshHz: Double = 20.0
    private static let windowPreMPXSpectrumRefreshHz: Double = 20.0
    private static let inlineMPXSpectrumBins: Int = 256
    private static let windowMPXSpectrumBins: Int = 384
    private static let preMPXSpectrumBins: Int = 128
    #else
    private static let monitoringRefreshHzActive: Double = 30.0
    // Idle rate (window occluded / app backgrounded / minimized). 20 Hz
    // keeps VU meters visibly responsive when glancing at the window from
    // another app while adjusting source levels. Well below the 60 Hz
    // preemption threshold for audio-thread safety.
    private static let monitoringRefreshHzIdle: Double = 20.0
    private static let inlineMPXSpectrumRefreshHz: Double = 24.0
    private static let windowMPXSpectrumRefreshHz: Double = 30.0
    private static let windowPreMPXSpectrumRefreshHz: Double = 30.0
    private static let inlineMPXSpectrumBins: Int = 384
    private static let windowMPXSpectrumBins: Int = 512
    private static let preMPXSpectrumBins: Int = 128
    #endif
    private static let meterAttackMS: Float = 18.0
    private static let meterReleaseMS: Float = 110.0
    private static let audioPeakMeterAttackMS: Float = 1.0
    private static let audioPeakMeterReleaseMS: Float = 180.0

    @Published var selectedSection: AppSection = .monitoring
    @Published var selectedProcessingTab: ProcessingTab = .overview
    @Published var selectedRDSTab: RDSTab = .control
    /// Phase 1 sidebar selection. `didSet` keeps the legacy enums in sync so
    /// the existing per-tab views (and any code branching on
    /// `selectedSection`) keep working without modification.
    @Published var selectedStage: Stage = .monitoring {
        didSet {
            if selectedSection != selectedStage.legacySection {
                selectedSection = selectedStage.legacySection
            }
            if let pt = selectedStage.legacyProcessingTab,
               selectedProcessingTab != pt {
                selectedProcessingTab = pt
            }
            if let rt = selectedStage.legacyRDSTab,
               selectedRDSTab != rt {
                selectedRDSTab = rt
            }
            lastStageInGroup[selectedStage.group] = selectedStage
        }
    }

    /// Whether processed-audio output mode is the selected output (drives UI
    /// gating of composite/RDS surfaces). Reflects the persisted config value.
    var processedAudioOutputActive: Bool { config.processedAudioOutput }

    /// A sidebar stage is hidden when processed-audio output is active and the
    /// stage only makes sense in the composite domain (RDS, composite clipper,
    /// BS.412). See `Stage.hiddenInProcessedAudio`.
    func isStageVisible(_ stage: Stage) -> Bool {
        !(processedAudioOutputActive && stage.hiddenInProcessedAudio)
    }

    /// If the current selection points at a stage hidden by the active output
    /// mode, snap back to the Processing overview. Called on engine (re)start so
    /// switching into processed-audio mode never leaves a stale RDS/composite pane.
    func normalizeSelectionForOutputMode() {
        if !isStageVisible(selectedStage) {
            selectedStage = .processingOverview
        }
    }
    /// Remembers the last visited stage per sidebar group so the
    /// ⌘1-⌘4 "Go to <Section>" shortcuts restore the sub-tab the user
    /// was last on in that group instead of always snapping to the
    /// group home. Seeded with each group's landing stage so a first
    /// jump lands somewhere sensible.
    private var lastStageInGroup: [Stage.Group: Stage] = [
        .monitoring: .monitoring,
        .processing: .processingOverview,
        .rds: .rdsControl,
        .tools: .testTone
    ]
    /// Whether a given sidebar stage has a "currently active" concept and,
    /// if so, whether it is on. Returns nil for stages with no single
    /// enable toggle (Monitoring, Overview, Core, Format Profile, Final
    /// Stage, Snapshots, RDS sub-tabs that inherit the master) — those
    /// rows never render an enabled-state dot. Mirrors Mail's pattern:
    /// only the section landing carries the badge.
    func isStageEnabled(_ stage: Stage) -> Bool? {
        switch stage {
        case .monitoring, .processingOverview, .processingFormatProfile,
             .processingCore, .processingFinalStage, .snapshots,
             .rdsProgram, .rdsRadiotext, .rdsLongPS, .rdsAF,
             .rdsSchedule, .rdsCarrier:
            return nil
        case .processingPhaseRotator: return config.phaseRotationEnabled
        case .processingAGC: return config.widebandAGCEnabled
        case .processingParametricEQ: return config.parametricEQEnabled
        case .processingMultiband: return config.multibandEnabled
        case .processingExpander: return config.downwardExpanderEnabled
        case .processingMBLimiter: return config.multibandLimiterEnabled
        case .processingWidener: return config.stereoWidenEnabled
        case .processingPrimeBass: return config.primeBassEnabled
        case .processingBassClipper: return config.bassClipperEnabled
        case .processingDCClipper: return config.dcClipperEnabled
        case .processingHFClipper: return config.hfClipperEnabled
        case .processingLimiter: return config.preEncodeAudioLimiterEnabled
        case .processingCompositeClipper: return config.compositeClipperEnabled
        case .processingBS412: return config.bs412Enabled
        case .rdsControl: return config.enRDS
        case .testTone: return config.sourceMode == "tone"
        }
    }

    /// Jump to the given sidebar group. If the user has visited a
    /// sub-tab in that group during this session, restore it;
    /// otherwise land on the group's home stage.
    func goToGroup(_ group: Stage.Group) {
        let target = lastStageInGroup[group] ?? {
            switch group {
            case .monitoring: return .monitoring
            case .processing: return .processingOverview
            case .rds: return .rdsControl
            case .tools: return .testTone
            }
        }()
        if selectedStage != target {
            selectedStage = target
        }
    }
    /// Phase 3 inspector visibility. Toggleable from View > Inspector.
    /// Defaults off so the redesign progressively reveals features —
    /// users who don't need the advanced cancel toggles or per-band
    /// detail panels never see the column.
    @Published var inspectorVisible: Bool = false
    /// Phase 4 active-band selector for the new Multiband editor —
    /// controls which band the per-band Threshold / Ratio / Attack /
    /// Release sliders re-target. 0 = Low, 1 = Mid, 2 = High.
    @Published var activeMultibandBand: Int = 1
    @Published var statusText: String = "Idle"
    /// Start-refusal message shown as an alert: statusText has no on-screen
    /// surface in Studio, and refusing to start MUST be visible (the user
    /// clicked Start and nothing began).
    @Published var startBlockedMessage: String?
    @Published var pendingRuntimeApply: Bool = false

    // Named snapshot slots — persistent operator-saved setups beyond
    // format profiles. Stored on disk as JSON alongside the INI; survive
    // app upgrades. 8 fixed slots; nil = empty. Operator names each save
    // ("Morning Show", "Saturday Night", "Live Sports").
    @Published var snapshots: [ConfigSnapshot?] = Array(repeating: nil, count: MPXPrimeViewModel.snapshotSlotCount)

    // Which snapshot's config is currently live (set on load + save), so the UI
    // can show which slot is active. nil = the live config came from the main
    // INI, not a snapshot. `activeSnapshotModified` flips true once any config
    // edit diverges from that snapshot.
    @Published var activeSnapshotID: UUID?
    @Published var activeSnapshotModified = false
    // While applying a loaded config (preset load / disk reload), the control
    // bindings fire onChange -> setConfigValue -> saveConfig, which would
    // immediately flip `activeSnapshotModified` true. That made a just-loaded
    // preset always read "edited since loaded". Suppress the flip for a brief
    // window after a programmatic load so only genuine user edits set it.
    private var suppressModifiedFlipUntil: TimeInterval = 0

    static let snapshotSlotCount: Int = 8

    /// Snapshot file path derived from the config file path. Sibling
    /// file with `.snapshots.json` suffix so each distinct config gets
    /// its own snapshot file — important for `--config` overrides and
    /// for test isolation (concurrent tests with unique temp config
    /// paths get isolated snapshot files, not a shared one in the
    /// directory).
    var snapshotsFilePath: String {
        configPath + ".snapshots.json"
    }

    @Published var sourceMode: String
    @Published var monitorEnabled: Bool
    @Published var processingBypass: Bool
    @Published var inputGainDB: Double

    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputUID: String = ""
    @Published var selectedOutputUID: String = ""
    @Published var selectedMonitorUID: String = ""

    @Published var isRunning: Bool = false
    @Published var isTransitioning: Bool = false
    var runtimeText: String { get { telemetry.runtimeText } set { telemetry.runtimeText = newValue } }
    // Live monitoring telemetry lives on its own observable so a metering
    // tick does not invalidate the whole view model. These forward to it;
    // writer code in the update methods is unchanged. See LiveTelemetry.
    let telemetry = LiveTelemetry()
    var inputRingText: String { get { telemetry.inputRingText } set { telemetry.inputRingText = newValue } }
    var inputBufferValue: Double { get { telemetry.inputBufferValue } set { telemetry.inputBufferValue = newValue } }
    var inputBufferMax: Double { get { telemetry.inputBufferMax } set { telemetry.inputBufferMax = newValue } }
    var inputBufferWarning: Double { get { telemetry.inputBufferWarning } set { telemetry.inputBufferWarning = newValue } }
    var inputBufferCritical: Double { get { telemetry.inputBufferCritical } set { telemetry.inputBufferCritical = newValue } }
    /// Low-passed (~10 s time constant) version of `inputBufferValue /
    /// inputBufferMax`. Used by the Monitoring buffer-fill bar so the
    /// display shows trend rather than tick-by-tick wobble; raw
    /// `inputBufferValue` keeps its 30 Hz cadence for any logic that
    /// needs the instantaneous reading.
    var bufferFillSmoothed: Double { get { telemetry.bufferFillSmoothed } set { telemetry.bufferFillSmoothed = newValue } }
    var streamHealth: MonitoringStreamHealth { get { telemetry.streamHealth } set { telemetry.streamHealth = newValue } }

    var inputLLevel: Double { get { telemetry.inputLLevel } set { telemetry.inputLLevel = newValue } }
    var inputRLevel: Double { get { telemetry.inputRLevel } set { telemetry.inputRLevel = newValue } }
    var agcOutputLLevel: Double { get { telemetry.agcOutputLLevel } set { telemetry.agcOutputLLevel = newValue } }
    var agcOutputRLevel: Double { get { telemetry.agcOutputRLevel } set { telemetry.agcOutputRLevel = newValue } }
    var outputLevel: Double { get { telemetry.outputLevel } set { telemetry.outputLevel = newValue } }
    var modulationLevel: Double { get { telemetry.modulationLevel } set { telemetry.modulationLevel = newValue } }
    var inputLPeakHoldLevel: Double { get { telemetry.inputLPeakHoldLevel } set { telemetry.inputLPeakHoldLevel = newValue } }
    var inputRPeakHoldLevel: Double { get { telemetry.inputRPeakHoldLevel } set { telemetry.inputRPeakHoldLevel = newValue } }
    var agcOutputLPeakHoldLevel: Double { get { telemetry.agcOutputLPeakHoldLevel } set { telemetry.agcOutputLPeakHoldLevel = newValue } }
    var agcOutputRPeakHoldLevel: Double { get { telemetry.agcOutputRPeakHoldLevel } set { telemetry.agcOutputRPeakHoldLevel = newValue } }
    var outputPeakHoldLevel: Double { get { telemetry.outputPeakHoldLevel } set { telemetry.outputPeakHoldLevel = newValue } }
    var modulationPeakHoldLevel: Double { get { telemetry.modulationPeakHoldLevel } set { telemetry.modulationPeakHoldLevel = newValue } }
    @Published var stickyPeaksEnabled: Bool = true
    @Published var meterPeakHoldSeconds: Double = 1.5
    @Published var meterPeakFallDBPerSecond: Double = 18.0

    var inputLText: String { get { telemetry.inputLText } set { telemetry.inputLText = newValue } }
    var inputRText: String { get { telemetry.inputRText } set { telemetry.inputRText = newValue } }
    var agcOutputLText: String { get { telemetry.agcOutputLText } set { telemetry.agcOutputLText = newValue } }
    var agcOutputRText: String { get { telemetry.agcOutputRText } set { telemetry.agcOutputRText = newValue } }
    var outputText: String { get { telemetry.outputText } set { telemetry.outputText = newValue } }
    var modulationText: String { get { telemetry.modulationText } set { telemetry.modulationText = newValue } }

    var limiterStateText: String { get { telemetry.limiterStateText } set { telemetry.limiterStateText = newValue } }
    var limiterDetailText: String { get { telemetry.limiterDetailText } set { telemetry.limiterDetailText = newValue } }
    var compositeBudgetStateText: String { get { telemetry.compositeBudgetStateText } set { telemetry.compositeBudgetStateText = newValue } }
    var compositeCalibrationText: String { get { telemetry.compositeCalibrationText } set { telemetry.compositeCalibrationText = newValue } }
    var estimatedDeviationPeakKHz: Float { get { telemetry.estimatedDeviationPeakKHz } set { telemetry.estimatedDeviationPeakKHz = newValue } }
    var pilotInjectionPercentValue: Float { get { telemetry.pilotInjectionPercentValue } set { telemetry.pilotInjectionPercentValue = newValue } }
    var rdsInjectionPercentValue: Float { get { telemetry.rdsInjectionPercentValue } set { telemetry.rdsInjectionPercentValue = newValue } }
    var audioCompositePeakLinear: Float { get { telemetry.audioCompositePeakLinear } set { telemetry.audioCompositePeakLinear = newValue } }
    var compositeBudgetMarginDBValue: Float { get { telemetry.compositeBudgetMarginDBValue } set { telemetry.compositeBudgetMarginDBValue = newValue } }
    /// Post-injection overshoot envelope (from `CompositeCalibrationStatus`).
    /// Non-zero ⇒ pilot/RDS subcarriers are clipping at the final
    /// ±1.0 clamp because audio + subcarrier × outputGain exceeds
    /// budget. UI surfaces this as an over-budget warning so the
    /// operator can reduce outputGain / pilot / RDS levels.
    var postInjectionOvershootValue: Float { get { telemetry.postInjectionOvershootValue } set { telemetry.postInjectionOvershootValue = newValue } }
    /// True when the composite budget governor has muted the audio
    /// path — outputGain × subcarrier reservation left no headroom.
    var compositeOverBudget: Bool { get { telemetry.compositeOverBudget } set { telemetry.compositeOverBudget = newValue } }
    var compositeClipperGainReductionDBValue: Float { get { telemetry.compositeClipperGainReductionDBValue } set { telemetry.compositeClipperGainReductionDBValue = newValue } }
    var compositeClipperLookaheadGainReductionDBValue: Float { get { telemetry.compositeClipperLookaheadGainReductionDBValue } set { telemetry.compositeClipperLookaheadGainReductionDBValue = newValue } }
    var preEncodeLimiterGainReductionDBValue: Float { get { telemetry.preEncodeLimiterGainReductionDBValue } set { telemetry.preEncodeLimiterGainReductionDBValue = newValue } }
    var safetyLimiterGainReductionDBValue: Float { get { telemetry.safetyLimiterGainReductionDBValue } set { telemetry.safetyLimiterGainReductionDBValue = newValue } }
    var stereoImageText: String { get { telemetry.stereoImageText } set { telemetry.stereoImageText = newValue } }
    var agcStateText: String { get { telemetry.agcStateText } set { telemetry.agcStateText = newValue } }
    var agcDetailText: String { get { telemetry.agcDetailText } set { telemetry.agcDetailText = newValue } }
    var multibandStateText: String { get { telemetry.multibandStateText } set { telemetry.multibandStateText = newValue } }
    var primeBassStateText: String { get { telemetry.primeBassStateText } set { telemetry.primeBassStateText = newValue } }
    var widenerStateText: String { get { telemetry.widenerStateText } set { telemetry.widenerStateText = newValue } }

    var rdsPS: String { get { telemetry.rdsPS } set { telemetry.rdsPS = newValue } }
    var rdsPI: String { get { telemetry.rdsPI } set { telemetry.rdsPI = newValue } }
    var rdsPTY: String { get { telemetry.rdsPTY } set { telemetry.rdsPTY = newValue } }
    var rdsPTYN: String { get { telemetry.rdsPTYN } set { telemetry.rdsPTYN = newValue } }
    var rdsAID: String { get { telemetry.rdsAID } set { telemetry.rdsAID = newValue } }
    var rdsLongPS: String { get { telemetry.rdsLongPS } set { telemetry.rdsLongPS = newValue } }
    var rdsRadiotext: String { get { telemetry.rdsRadiotext } set { telemetry.rdsRadiotext = newValue } }
    var rdsNowPlayingStatus: String { get { telemetry.rdsNowPlayingStatus } set { telemetry.rdsNowPlayingStatus = newValue } }

    var inputScopeLeft: [Float] { get { telemetry.inputScopeLeft } set { telemetry.inputScopeLeft = newValue } }
    var inputScopeRight: [Float] { get { telemetry.inputScopeRight } set { telemetry.inputScopeRight = newValue } }
    var outputScope: [Float] { get { telemetry.outputScope } set { telemetry.outputScope = newValue } }
    @Published var scopeTimebaseMS: Double = 10.0
    @Published var scopeAutoGainEnabled: Bool = true
    var mpxSpectrumDB: [Float] { get { telemetry.mpxSpectrumDB } set { telemetry.mpxSpectrumDB = newValue } }
    var mpxSpectrumMaxHz: Double { get { telemetry.mpxSpectrumMaxHz } set { telemetry.mpxSpectrumMaxHz = newValue } }
    var mpxSpectrumNyquistHz: Double { get { telemetry.mpxSpectrumNyquistHz } set { telemetry.mpxSpectrumNyquistHz = newValue } }
    @Published var scopesWindowVisible: Bool = false
    @Published var spectrumWindowVisible: Bool = false
    var preMPXSpectrumLeftDB: [Float] { get { telemetry.preMPXSpectrumLeftDB } set { telemetry.preMPXSpectrumLeftDB = newValue } }
    var preMPXSpectrumRightDB: [Float] { get { telemetry.preMPXSpectrumRightDB } set { telemetry.preMPXSpectrumRightDB = newValue } }
    var preMPXSpectrumMaxHz: Double { get { telemetry.preMPXSpectrumMaxHz } set { telemetry.preMPXSpectrumMaxHz = newValue } }
    var preMPXSpectrumNyquistHz: Double { get { telemetry.preMPXSpectrumNyquistHz } set { telemetry.preMPXSpectrumNyquistHz = newValue } }
    @Published var preMPXSpectrumWindowVisible: Bool = false
    @Published var levelsWindowVisible: Bool = false

    private let configPath: String
    private let nowPlayingState: NowPlayingState
    private let nowPlayingRunner: NowPlayingScriptRunner
    var config: AppConfig
    private var runningEngine: AudioOutputEngine?
    private var controlServerTask: Task<Void, Never>?
    private var activeRuntimeSnapshot: RuntimeSnapshot?
    private var monitorTimer: Timer?
    private var lastMonitorRefreshTime: TimeInterval?
    private var engineStartReference: TimeInterval?

    // Visibility state — drives the adaptive `monitorTimer` rate. The
    // timer fires at `monitoringRefreshHzActive` only when all three
    // are in the on-screen position; otherwise drops to
    // `monitoringRefreshHzIdle` so the smoothing state stays warm
    // without burning cycles when no pixels are being drawn.
    private var appIsActive: Bool = true
    private var mainWindowIsOccluded: Bool = false
    private var mainWindowIsMinimized: Bool = false
    private var lastAppliedRefreshHz: Double = 0.0

    private var desiredMonitoringRefreshHz: Double {
        let onScreen = appIsActive && !mainWindowIsOccluded && !mainWindowIsMinimized
        return onScreen ? Self.monitoringRefreshHzActive : Self.monitoringRefreshHzIdle
    }

    private var vuInputL: Float = 0.0
    private var vuInputR: Float = 0.0
    private var vuAGCOutputL: Float = 0.0
    private var vuAGCOutputR: Float = 0.0
    private var vuOutput: Float = 0.0
    private var vuModulation: Float = 0.0
    private var peakHoldInputL = AudioPeakHoldState()
    private var peakHoldInputR = AudioPeakHoldState()
    private var peakHoldAGCOutputL = AudioPeakHoldState()
    private var peakHoldAGCOutputR = AudioPeakHoldState()
    private var peakHoldOutput = AudioPeakHoldState()
    private var peakHoldModulation = PeakHoldState()
    private var limiterGRPeakHoldDB: Float = 0.0
    private var limiterGRPeakHoldRemaining: Double = 0.0

    private var smoothedInputScopeLeft: [Float] = Array(repeating: 0.0, count: 128)
    private var smoothedInputScopeRight: [Float] = Array(repeating: 0.0, count: 128)
    private var smoothedOutputScope: [Float] = Array(repeating: 0.0, count: 128)
    private var inputScopeLeftGain: Float = 1.0
    private var inputScopeRightGain: Float = 1.0
    private var outputScopeGain: Float = 1.0
    private var overflowHistory: [(time: TimeInterval, overflows: UInt64, underflows: UInt64)] = []
    private var lastOverflowTotal: UInt64 = 0
    private var lastUnderflowTotal: UInt64 = 0
    private var pendingConfigSnapshot: AppConfig?
    private var configSaveInFlight: Bool = false
    private var configWatchFD: Int32 = -1
    private var configWatchSource: DispatchSourceFileSystemObject?
    private var configReloadWorkItem: DispatchWorkItem?
    private var ignoreConfigReloadUntil: TimeInterval = 0.0
    private var lastSpectrumRefreshTime: TimeInterval?
    private var spectrumUpdateInFlight: Bool = false
    private var lastPreMPXSpectrumRefreshTime: TimeInterval?
    private var preMPXSpectrumUpdateInFlight: Bool = false
    private let spectrumQueue = DispatchQueue(label: "MPXPrime.MPXSpectrum", qos: .userInitiated)
    private let spectrumAnalyzer = MPXSpectrumAnalyzer()
    private let preMPXSpectrumAnalyzer = MPXSpectrumAnalyzer()
    private var spectrumInputScratch: [Float] = Array(repeating: 0.0, count: 4096)
    private var preMPXSpectrumLeftScratch: [Float] = Array(
        repeating: 0.0,
        count: AudioOutputEngine.preMPXSpectrumFrameCount
    )
    private var preMPXSpectrumRightScratch: [Float] = Array(
        repeating: 0.0,
        count: AudioOutputEngine.preMPXSpectrumFrameCount
    )

    init(configPath: String) {
        self.configPath = configPath
        let loadedConfig: AppConfig
        do {
            loadedConfig = try AppConfig.load(fromINI: configPath)
        } catch {
            loadedConfig = AppConfig()
            try? loadedConfig.save(toINI: configPath)
        }
        self.config = loadedConfig

        self.sourceMode = loadedConfig.sourceMode
        self.monitorEnabled = loadedConfig.monitorEnabled
        self.processingBypass = loadedConfig.processingBypass
        self.inputGainDB = loadedConfig.inputGainDB
        self.nowPlayingState = NowPlayingState()
        self.nowPlayingRunner = NowPlayingScriptRunner(state: self.nowPlayingState)
        self.nowPlayingRunner.setStatusHandler { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rdsNowPlayingStatus = status
                self.refreshMonitoringSnapshot()
            }
        }

        refreshDevices()
        nowPlayingRunner.updateConfig(loadedConfig)
        startConfigWatcher()
        loadSnapshotsFromDisk()
        refreshMonitoringSnapshot()
        startControlServerIfEnabled()
    }

    var autoStartEnabled: Bool { config.rdsAutoStart }

    var isBusy: Bool { isTransitioning }

    var configFilePath: String { configPath }

    var runtimeApplyPending: Bool { isRunning && pendingRuntimeApply }

    var runtimeApplyButtonTitle: String { "Apply Restart" }

    var runtimeApplyHintText: String {
        "Pending changes affect engine, routing, or encoder structure and require a restart to take effect."
    }

    var restartRequiredSettingsListText: String { kRestartRequiredSettingsListText }

    var ptyChoices: [(Int, String)] {
        Self.ptyNames(rbds: config.rdsPtyRBDS).enumerated().map { ($0.offset, $0.element) }
    }

    var primeBassPresetChoices: [PresetChoice] {
        PresetCatalog.primeBassPresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var widenerPresetChoices: [PresetChoice] {
        [PresetChoice(id: "custom", title: "Custom")]
            + PresetCatalog.widenerPresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var multibandPresetChoices: [PresetChoice] {
        PresetCatalog.multibandPresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var finalStagePresetChoices: [PresetChoice] {
        Self.finalStagePresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var rdsRows: [(String, String)] {
        [
            ("PS", rdsPS),
            ("PI", rdsPI),
            ("PTY", rdsPTY),
            ("PTYN", rdsPTYN),
            ("RT+ App ID", rdsAID),
            ("Long PS", rdsLongPS),
            ("Radiotext", rdsRadiotext),
            ("Now Playing", rdsNowPlayingStatus.replacingOccurrences(of: "Now Playing: ", with: ""))
        ]
    }

    func startMonitoringTimer() {
        applyMonitoringRefreshRate()
    }

    /// Recreate `monitorTimer` at the rate dictated by current visibility
    /// state. Called from `startMonitoringTimer()` and from each
    /// visibility-change setter; early-returns when the desired rate
    /// matches the currently-active rate to avoid timer-recreate churn
    /// on no-op state transitions.
    private func applyMonitoringRefreshRate() {
        let target = desiredMonitoringRefreshHz
        if target == lastAppliedRefreshHz, monitorTimer != nil {
            return
        }
        monitorTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / target, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMonitoringSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
        lastAppliedRefreshHz = target
        timer.fire()
    }

    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        applyMonitoringRefreshRate()
    }

    func setMainWindowOccluded(_ occluded: Bool) {
        guard mainWindowIsOccluded != occluded else { return }
        mainWindowIsOccluded = occluded
        applyMonitoringRefreshRate()
    }

    func setMainWindowMinimized(_ minimized: Bool) {
        guard mainWindowIsMinimized != minimized else { return }
        mainWindowIsMinimized = minimized
        applyMonitoringRefreshRate()
    }

    func shutdown() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        lastMonitorRefreshTime = nil
        nowPlayingRunner.stop()
        stopConfigWatcher()
        stopEngineIfNeeded()
    }

    func refreshDevices() {
        do {
            let devices = try AudioDevices.list()
            inputDevices = devices.filter { $0.hasInput }
            outputDevices = devices.filter { $0.hasOutput }
            selectedInputUID = selectUID(uid: config.inputDeviceUID, name: config.inputDeviceName, from: inputDevices)
            selectedOutputUID = selectUID(uid: config.outputDeviceUID, name: config.outputDeviceName, from: outputDevices)
            selectedMonitorUID = selectUID(uid: config.monitorDeviceUID, name: config.monitorDeviceName, from: outputDevices)
            warnAboutUnavailablePreferredDevices()
        } catch {
            statusText = "Device scan failed: \(error)"
            inputDevices = []
            outputDevices = []
            selectedInputUID = ""
            selectedOutputUID = ""
            selectedMonitorUID = ""
        }
    }

    /// Status note when a remembered device isn't present, so the user knows we
    /// kept their choice (and did NOT silently switch to a different device).
    private func warnAboutUnavailablePreferredDevices() {
        var missing: [String] = []
        if !selectedInputUID.isEmpty, !inputDevices.contains(where: { $0.uid == selectedInputUID }) {
            missing.append("input \"\(config.inputDeviceName ?? selectedInputUID)\"")
        }
        if !selectedOutputUID.isEmpty, !outputDevices.contains(where: { $0.uid == selectedOutputUID }) {
            missing.append("output \"\(config.outputDeviceName ?? selectedOutputUID)\"")
        }
        if monitorEnabled, !selectedMonitorUID.isEmpty,
           !outputDevices.contains(where: { $0.uid == selectedMonitorUID }) {
            missing.append("monitor \"\(config.monitorDeviceName ?? selectedMonitorUID)\"")
        }
        if !missing.isEmpty {
            statusText = "Preferred \(missing.joined(separator: ", ")) device not connected -- "
                + "selection kept; reconnect it or pick another."
        }
    }

    func persistBasicConfig() {
        config.sourceMode = sourceMode
        config.monitorEnabled = monitorEnabled
        config.processingBypass = processingBypass
        config.inputGainDB = inputGainDB
        config.inputDeviceUID = selectedInputUID.isEmpty ? nil : selectedInputUID
        config.outputDeviceUID = selectedOutputUID.isEmpty ? nil : selectedOutputUID
        config.monitorDeviceUID = selectedMonitorUID.isEmpty ? nil : selectedMonitorUID
        // Remember the name only while the device is actually present, so an
        // unplugged device keeps its last-known name for re-matching.
        if let d = inputDevices.first(where: { $0.uid == selectedInputUID }) { config.inputDeviceName = d.name }
        if let d = outputDevices.first(where: { $0.uid == selectedOutputUID }) { config.outputDeviceName = d.name }
        if let d = outputDevices.first(where: { $0.uid == selectedMonitorUID }) { config.monitorDeviceName = d.name }
        saveConfig(restartRequired: isRunning)
    }

    func applyPendingRuntimeChanges() {
        guard runtimeApplyPending else { return }
        pendingRuntimeApply = false
        restartEngineWithStatus("Config changes")
    }

    func value<T>(for keyPath: KeyPath<AppConfig, T>) -> T {
        config[keyPath: keyPath]
    }

    func setConfigValue<T>(
        _ keyPath: WritableKeyPath<AppConfig, T>,
        _ value: T,
        runtimeDisposition: RuntimeChangeDisposition = .restart
    ) {
        publishConfigChange()
        config[keyPath: keyPath] = value
        saveConfig(restartRequired: runtimeDisposition == .restart)
        switch runtimeDisposition {
        case .live:
            applyLiveRuntimeConfigIfRunning()
        case .liveRDS:
            applyLiveRDSConfigIfRunning()
        case .restart, .none:
            break
        }
        updateNowPlayingRunner()
    }

    func configBinding<T>(
        _ keyPath: WritableKeyPath<AppConfig, T>,
        runtimeDisposition: RuntimeChangeDisposition = .restart
    ) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.setConfigValue(keyPath, $0, runtimeDisposition: runtimeDisposition) }
        )
    }

    func ptyBinding() -> Binding<Int> {
        Binding(
            get: { self.config.rdsPTY },
            set: { self.setConfigValue(\.rdsPTY, max(0, min(31, $0)), runtimeDisposition: .liveRDS) }
        )
    }

    func piBinding() -> Binding<String> {
        Binding(
            get: { self.config.rdsPI },
            set: {
                self.setConfigValue(\.rdsPI, Self.sanitizeHex($0, width: 4), runtimeDisposition: .liveRDS)
            }
        )
    }

    func hexByteBinding(_ keyPath: WritableKeyPath<AppConfig, String>) -> Binding<String> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: {
                self.setConfigValue(keyPath, Self.sanitizeHex($0, width: 2), runtimeDisposition: .liveRDS)
            }
        )
    }

    /// RDS injection level expressed as % of total FM deviation. Industry
    /// convention is to talk about RDS as "4 %", "5 %" etc. (Inovonics,
    /// Audemat, DEVA, BW Broadcast displays all use %). The INI key
    /// `rds_level` stays in kHz per EN 50067 / IEC 62106-2 so existing
    /// configs are back-compat; the GUI just shows the user-friendly unit.
    /// Mapping: % = kHz / 75 * 100 (75 kHz is total FM deviation).
    func rdsLevelPercentBinding() -> Binding<Double> {
        Binding(
            get: { self.config.rdsLevel / 75.0 * 100.0 },
            set: { newPercent in
                let kHz = max(0.0, min(7.5, newPercent / 100.0 * 75.0))
                self.setConfigValue(\.rdsLevel, kHz, runtimeDisposition: .restart)
            }
        )
    }

    /// Pilot tone level expressed as % of total FM deviation. ITU-R
    /// BS.450 / FCC §73.322 / EN 50067 all specify 8-10 % deviation;
    /// pro processors display this in %. The INI key `pilot_level` stays
    /// as the linear amplitude fraction (0.0..0.12) for back-compat with
    /// the underlying audio math. Mapping: % = fraction * 100.
    func pilotLevelPercentBinding() -> Binding<Double> {
        Binding(
            get: { self.config.pilotLevel * 100.0 },
            set: { newPercent in
                let fraction = max(0.0, min(0.12, newPercent / 100.0))
                self.setConfigValue(\.pilotLevel, fraction, runtimeDisposition: .restart)
            }
        )
    }

    func oddTapBinding() -> Binding<Int> {
        Binding(
            get: { self.config.rdsGaussianTaps },
            set: { raw in
                let clamped = max(9, min(401, raw))
                let odd =
                    (clamped % 2 == 0) ? (clamped + 1 <= 401 ? clamped + 1 : clamped - 1) : clamped
                self.setConfigValue(\.rdsGaussianTaps, odd, runtimeDisposition: .restart)
            }
        )
    }

    func rtBufferTextBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { self.rtBufferText(at: index) },
            set: { self.setRTBufferText(at: index, text: $0) }
        )
    }

    func rtBufferEnabledBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { self.rtBufferEnabled(at: index) },
            set: { self.setRTBufferEnabled(at: index, enabled: $0) }
        )
    }

    func rtBufferLabel(_ index: Int) -> String {
        String(UnicodeScalar(65 + max(0, min(3, index))) ?? "A")
    }

    var enabledRTBufferIndices: [Int] {
        (0..<4).filter { index in
            rtBufferEnabled(at: index)
                && !rtBufferText(at: index).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func rtBufferText(at index: Int) -> String {
        switch index {
        case 0: return config.rdsRTA
        case 1: return config.rdsRTB
        case 2: return config.rdsRTC
        case 3: return config.rdsRTD
        default: return ""
        }
    }

    private func rtBufferEnabled(at index: Int) -> Bool {
        switch index {
        case 0: return config.rdsRTBufferAEnabled
        case 1: return config.rdsRTBufferBEnabled
        case 2: return config.rdsRTBufferCEnabled
        case 3: return config.rdsRTBufferDEnabled
        default: return false
        }
    }

    private func setRTBufferText(at index: Int, text: String) {
        publishConfigChange()
        switch index {
        case 0: config.rdsRTA = text
        case 1: config.rdsRTB = text
        case 2: config.rdsRTC = text
        case 3: config.rdsRTD = text
        default: break
        }
        saveConfig(restartRequired: false)
        applyLiveRDSConfigIfRunning()
    }

    private func setRTBufferEnabled(at index: Int, enabled: Bool) {
        publishConfigChange()
        switch index {
        case 0: config.rdsRTBufferAEnabled = enabled
        case 1: config.rdsRTBufferBEnabled = enabled
        case 2: config.rdsRTBufferCEnabled = enabled
        case 3: config.rdsRTBufferDEnabled = enabled
        default: break
        }
        let enabledBuffers = enabledRTBufferIndices
        if enabledBuffers.isEmpty {
            config.rdsRTActiveBuffer = 0
        } else if !enabledBuffers.contains(config.rdsRTActiveBuffer) {
            config.rdsRTActiveBuffer = enabledBuffers[0]
        }
        saveConfig(restartRequired: false)
        applyLiveRDSConfigIfRunning()
    }

    /// Apply a top-level "Station Format" profile. Atomic across the four
    /// per-stage preset systems (multiband / final-stage / PrimeBass /
    /// stereo widener) plus composite-clipper threshold/ceiling and final
    /// drive. Each per-stage apply call already routes through saveConfig
    /// + applyLiveRuntimeConfigIfRunning, so the chain is fully reconciled
    /// when this method returns.
    ///
    /// Per-stage knobs remain editable after a profile is applied; the
    /// stored `formatProfileID` is a cosmetic label (no "dirty" / modified
    /// indicator in v1 — the operator can re-pick the profile to restore
    /// its defaults).
    func applyFormatProfile(_ id: String) {
        guard let profile = Self.formatProfile(forID: id) else {
            statusText = "Unknown format profile: \(id)"
            return
        }
        publishConfigChange()
        config.formatProfileID = id

        // "Custom" sentinel: just record the label, leave per-stage
        // settings alone. Lets operators flag bespoke setups so the
        // picker stops showing whichever profile was last applied even
        // though knobs have drifted.
        if id == "custom" {
            saveConfig(restartRequired: false)
            statusText =
                isRunning
                ? "Format profile set to Custom (no settings changed)."
                : "Format profile set to Custom."
            return
        }

        applyMultibandPreset(id: profile.multibandPresetID, intensity: profile.multibandIntensity)
        applyFinalStagePreset(id: profile.finalStagePresetID)

        config.primeBassEnabled = profile.primeBassEnabled
        if profile.primeBassEnabled {
            applyPrimeBassPreset(id: profile.primeBassPresetID)
        } else {
            // Still record the per-stage preset ID so toggling PrimeBass
            // back on uses the format-appropriate flavour.
            config.primeBassPresetID = profile.primeBassPresetID
        }

        applyWidenerPreset(id: profile.widenerPresetID)

        config.compositeClipperThresholdDB = profile.compositeClipperThresholdDB
        config.compositeClipperCeilingDB = profile.compositeClipperCeilingDB
        config.finalDriveDB = profile.finalDriveDB

        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded format profile \(profile.title) live."
            : "Loaded format profile \(profile.title)."
    }

    func formatProfileBinding() -> Binding<String> {
        Binding(
            get: { self.config.formatProfileID },
            set: { self.applyFormatProfile($0) }
        )
    }

    // MARK: - A/B compare

    // MARK: - Named snapshots

    /// Load persisted snapshots from disk into the in-memory `snapshots`
    /// array. Called from init. Missing or corrupt file → silent reset
    /// to empty slots (operator can still save new ones).
    func loadSnapshotsFromDisk() {
        let path = snapshotsFilePath
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(SnapshotFile.self, from: data)
            // Defensive: pad/truncate to our slot count so future schema
            // changes don't break existing on-disk files.
            var slots: [ConfigSnapshot?] = Array(
                repeating: nil, count: Self.snapshotSlotCount)
            let count = min(file.slots.count, slots.count)
            for i in 0..<count { slots[i] = file.slots[i] }
            self.snapshots = slots
            // Restore which preset is active so the "Loaded" marker survives
            // relaunch. Drop it if the slot it pointed at is gone.
            if let id = file.activeID, slots.contains(where: { $0?.id == id }) {
                self.activeSnapshotID = id
                self.activeSnapshotModified = file.activeModified ?? false
            } else {
                self.activeSnapshotID = nil
                self.activeSnapshotModified = false
            }
        } catch {
            statusText = "Failed to load presets: \(error.localizedDescription)"
        }
    }

    /// Persist all slots to disk. JSON envelope wraps the per-slot
    /// `ConfigSnapshot` objects (which embed the config as INI text so
    /// schema migrations stay handled by the existing INI parser's
    /// defaults).
    func writeSnapshotsToDisk() {
        let file = SnapshotFile(
            slots: snapshots, activeID: activeSnapshotID, activeModified: activeSnapshotModified)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(
                to: URL(fileURLWithPath: snapshotsFilePath), options: [.atomic])
        } catch {
            statusText = "Failed to write presets: \(error.localizedDescription)"
        }
    }

    /// Capture the current config into slot `slot` with the given name
    /// (empty → "Preset N"). Writes the file immediately so a crash
    /// doesn't lose the operator's save.
    func saveSnapshot(slot: Int, name: String) {
        guard (0..<snapshots.count).contains(slot) else { return }
        publishConfigChange()
        do {
            let ini = try config.captureAsINIString()
            let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = ConfigSnapshot(
                id: UUID(),
                name: resolvedName.isEmpty ? "Preset \(slot + 1)" : resolvedName,
                savedAt: Date(),
                configINIText: ini
            )
            snapshots[slot] = saved
            // The just-saved slot now mirrors the live config exactly.
            activeSnapshotID = saved.id
            activeSnapshotModified = false
            writeSnapshotsToDisk()
            statusText = "Saved preset to slot \(slot + 1)."
        } catch {
            statusText = "Failed to save preset: \(error.localizedDescription)"
        }
    }

    /// Apply the snapshot in `slot` to the current config. Routes
    /// through `applyLoadedConfig` so live-apply / restart-required
    /// dispatching matches a normal disk load.
    func loadSnapshot(slot: Int) {
        guard (0..<snapshots.count).contains(slot),
              let snapshot = snapshots[slot] else { return }
        do {
            let loaded = try AppConfig.loadFromINIString(snapshot.configINIText)
            applyLoadedConfig(loaded, origin: .manual)
            activeSnapshotID = snapshot.id
            activeSnapshotModified = false
            // Persist the loaded config to the main INI so disk == live, and
            // record the active preset so the "Loaded" marker survives relaunch.
            enqueueConfigSave(snapshot: config)
            writeSnapshotsToDisk()
            statusText = "Loaded preset \"\(snapshot.name)\"."
        } catch {
            statusText = "Failed to load preset: \(error.localizedDescription)"
        }
    }

    /// Export the preset in `slot` to a file. The stored config IS a complete
    /// MPX Prime Studio INI, so the exported file doubles as a shareable config
    /// (loadable via --config or Import). Returns true on success.
    @discardableResult
    func exportSnapshot(slot: Int, to url: URL) -> Bool {
        guard (0..<snapshots.count).contains(slot), let snap = snapshots[slot] else { return false }
        do {
            try snap.configINIText.write(to: url, atomically: true, encoding: .utf8)
            statusText = "Exported preset \"\(snap.name)\" to \(url.lastPathComponent)."
            return true
        } catch {
            statusText = "Failed to export preset: \(error.localizedDescription)"
            return false
        }
    }

    /// Import an INI file into preset `slot`. Validates it parses, normalises it
    /// through the canonical writer, and names the preset from the filename.
    /// Populates the slot only (does not load it into the engine). Returns true
    /// on success.
    @discardableResult
    func importSnapshot(slot: Int, from url: URL) -> Bool {
        guard (0..<snapshots.count).contains(slot) else { return false }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try AppConfig.loadFromINIString(text)  // validate
            let canonical = try parsed.captureAsINIString()     // normalise
            let rawName = url.deletingPathExtension().lastPathComponent
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let imported = ConfigSnapshot(
                id: UUID(),
                name: name.isEmpty ? "Preset \(slot + 1)" : name,
                savedAt: Date(),
                configINIText: canonical)
            // Overwriting the active slot's content untethers the live config.
            if snapshots[slot]?.id == activeSnapshotID {
                activeSnapshotID = nil
                activeSnapshotModified = false
            }
            snapshots[slot] = imported
            writeSnapshotsToDisk()
            statusText = "Imported preset \"\(imported.name)\" into slot \(slot + 1)."
            return true
        } catch {
            statusText = "Failed to import preset: \(error.localizedDescription)"
            return false
        }
    }

    /// A filesystem-safe default filename for exporting the preset in `slot`.
    func exportFilename(slot: Int) -> String {
        let base = snapshots[slot]?.name ?? "Preset \(slot + 1)"
        let safe = base.map { "/\\:?%*|\"<>".contains($0) ? "-" : $0 }
        let trimmed = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "Preset \(slot + 1)" : trimmed) + ".ini"
    }

    /// Drop the snapshot in `slot` and persist the empty state.
    func clearSnapshot(slot: Int) {
        guard (0..<snapshots.count).contains(slot) else { return }
        if snapshots[slot]?.id == activeSnapshotID {
            activeSnapshotID = nil
            activeSnapshotModified = false
        }
        snapshots[slot] = nil
        writeSnapshotsToDisk()
        statusText = "Cleared preset slot \(slot + 1)."
    }

    /// Rename an existing snapshot in place (doesn't touch the stored
    /// config text — just the operator-facing label). Persists on
    /// every keystroke; the operator gets immediate save semantics
    /// without an explicit confirm button.
    func renameSnapshot(slot: Int, name: String) {
        guard (0..<snapshots.count).contains(slot),
              var snapshot = snapshots[slot] else { return }
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.name = resolvedName.isEmpty ? "Preset \(slot + 1)" : resolvedName
        snapshots[slot] = snapshot
        writeSnapshotsToDisk()
    }

    /// One-line description of the currently selected format profile,
    /// or a fallback string if the stored ID doesn't match any known
    /// profile (operator typed a custom value into INI).
    var currentFormatProfileSummary: String {
        Self.formatProfile(forID: config.formatProfileID)?.summary
            ?? "Custom (no matching format profile)."
    }

    func applyPrimeBassPreset(id: String) {
        // Parameter sets live in PresetCatalog (shared with the remote API).
        publishConfigChange()
        guard let title = PresetCatalog.applyPrimeBass(id: id, to: &config) else { return }
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded PrimeBass preset \(title) live."
            : "Loaded PrimeBass preset \(title)."
    }

    var currentWidenerPresetID: String {
        PresetCatalog.currentWidenerPresetID(of: config)
    }

    func applyWidenerPreset(id: String) {
        publishConfigChange()
        guard let title = PresetCatalog.applyWidener(id: id, to: &config) else { return }
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded image preset \(title) live."
            : "Loaded image preset \(title)."
    }

    func applyMultibandPreset(id: String, intensity: MultibandPresetIntensity) {
        publishConfigChange()
        guard let title = PresetCatalog.applyMultiband(id: id, intensity: intensity, to: &config)
        else { return }
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded Multiband preset \(title) (\(intensity.title)) live."
            : "Loaded Multiband preset \(title) (\(intensity.title))."
    }

    func applyFinalStagePreset(id: String) {
        guard let preset = Self.finalStagePresets.first(where: { $0.id == id }) else { return }
        publishConfigChange()
        config.finalStagePresetID = id
        config.widebandAGCEnabled = preset.agcEnabled
        config.widebandAGCTargetDB = preset.agcTargetDB
        config.widebandAGCAttackMS = preset.agcAttackMS
        config.widebandAGCReleaseMS = preset.agcReleaseMS
        config.widebandAGCMaxGainDB = preset.agcMaxGainDB
        config.widebandAGCMinGainDB = preset.agcMinGainDB
        config.finalDriveDB = preset.finalDriveDB
        config.preEncodeAudioLimiterEnabled = preset.preEncodeAudioLimiterEnabled
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded final-stage preset \(preset.title) live."
            : "Loaded final-stage preset \(preset.title)."
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)])
    }

    func reloadConfigFromDisk() {
        do {
            applyLoadedConfig(try AppConfig.load(fromINI: configPath), origin: .manual)
        } catch {
            statusText = "Config reload failed: \(error)"
        }
    }

    func resetToDefaults() {
        let savedSourceMode = sourceMode
        do {
            var defaults = AppConfig()
            defaults.sourceMode = savedSourceMode
            defaults.inputDeviceUID = selectedInputUID.isEmpty ? nil : selectedInputUID
            defaults.outputDeviceUID = selectedOutputUID.isEmpty ? nil : selectedOutputUID
            defaults.monitorEnabled = monitorEnabled
            defaults.monitorDeviceUID = selectedMonitorUID.isEmpty ? nil : selectedMonitorUID
            defaults.inputDeviceName = config.inputDeviceName
            defaults.outputDeviceName = config.outputDeviceName
            defaults.monitorDeviceName = config.monitorDeviceName
            try defaults.save(toINI: configPath)
            config = defaults
            sourceMode = config.sourceMode
            processingBypass = config.processingBypass
            inputGainDB = config.inputGainDB
            updateNowPlayingRunner()
            applyPendingRuntimeChanges()
            statusText = "Reset to defaults"
        } catch {
            statusText = "Reset failed: \(error)"
        }
    }

    func resetCurrentProcessingTabToDefaults() {
        publishConfigChange()
        let defaults = AppConfig()

        switch selectedProcessingTab {
        case .overview:
            // Overview has no detail parameters of its own — nothing to reset.
            return
        case .formatProfile:
            // Reset the format profile selector to the shipping default
            // (Community Radio); applies the matching per-stage settings
            // atomically through `applyFormatProfile`.
            applyFormatProfile(defaults.formatProfileID)
            return
        case .core:
            processingBypass = defaults.processingBypass
            inputGainDB = defaults.inputGainDB
            config.processingBypass = defaults.processingBypass
            config.inputGainDB = defaults.inputGainDB
            config.outputGainDB = defaults.outputGainDB
            config.monoMode = defaults.monoMode
            config.preemphasisUS = defaults.preemphasisUS
            config.hpfHz = defaults.hpfHz
            config.hfTrimDB = defaults.hfTrimDB
            config.hfTrimHz = defaults.hfTrimHz
            config.programLowpassHz = defaults.programLowpassHz
        case .agc:
            config.widebandAGCEnabled = defaults.widebandAGCEnabled
            config.widebandAGCTargetDB = defaults.widebandAGCTargetDB
            config.widebandAGCAttackMS = defaults.widebandAGCAttackMS
            config.widebandAGCReleaseMS = defaults.widebandAGCReleaseMS
            config.widebandAGCMaxGainDB = defaults.widebandAGCMaxGainDB
            config.widebandAGCMinGainDB = defaults.widebandAGCMinGainDB
        case .primeBass:
            config.primeBassEnabled = defaults.primeBassEnabled
            config.primeBassPresetID = defaults.primeBassPresetID
            config.primeBassAmount = defaults.primeBassAmount
            config.primeBassFreqHz = defaults.primeBassFreqHz
            config.primeBassHarmonics = defaults.primeBassHarmonics
            config.primeBassDrive = defaults.primeBassDrive
            config.primeBassDensity = defaults.primeBassDensity
            config.primeBassSubharmonicsEnabled = defaults.primeBassSubharmonicsEnabled
            config.primeBassSubharmonicsAmount = defaults.primeBassSubharmonicsAmount
        case .multiband:
            config.multibandEnabled = defaults.multibandEnabled
            config.multibandMode = defaults.multibandMode
            config.multibandPresetID = defaults.multibandPresetID
            config.multibandIntensity = defaults.multibandIntensity
            config.multibandX1Hz = defaults.multibandX1Hz
            config.multibandX2Hz = defaults.multibandX2Hz
            config.multibandX3Hz = defaults.multibandX3Hz
            config.multibandX4Hz = defaults.multibandX4Hz
            config.multibandLowThresholdDB = defaults.multibandLowThresholdDB
            config.multibandMidThresholdDB = defaults.multibandMidThresholdDB
            config.multibandHighThresholdDB = defaults.multibandHighThresholdDB
            config.multibandLowRatio = defaults.multibandLowRatio
            config.multibandMidRatio = defaults.multibandMidRatio
            config.multibandHighRatio = defaults.multibandHighRatio
            config.multibandLowAttackMS = defaults.multibandLowAttackMS
            config.multibandMidAttackMS = defaults.multibandMidAttackMS
            config.multibandHighAttackMS = defaults.multibandHighAttackMS
            config.multibandLowReleaseMS = defaults.multibandLowReleaseMS
            config.multibandMidReleaseMS = defaults.multibandMidReleaseMS
            config.multibandHighReleaseMS = defaults.multibandHighReleaseMS
            config.multibandKneeDB = defaults.multibandKneeDB
            config.multibandLinkStrength = defaults.multibandLinkStrength
            config.multibandReleaseProgramDependent = defaults.multibandReleaseProgramDependent
            config.multibandMakeupDB = defaults.multibandMakeupDB
        case .widener:
            config.stereoWidenEnabled = defaults.stereoWidenEnabled
            config.monoBassEnabled = defaults.monoBassEnabled
            config.monoBassFreqHz = defaults.monoBassFreqHz
            config.stereoWidenWidth = defaults.stereoWidenWidth
            config.stereoWidenCenter = defaults.stereoWidenCenter
            config.stereoWidenMix = defaults.stereoWidenMix
        case .limiter:
            config.preEncodeAudioLimiterEnabled = defaults.preEncodeAudioLimiterEnabled
            config.preEncodeThreshold = defaults.preEncodeThreshold
            config.preEncodeReleaseMS = defaults.preEncodeReleaseMS
            config.preEncodeLookaheadMS = defaults.preEncodeLookaheadMS
            config.preEncodeLookaheadHFOnly = defaults.preEncodeLookaheadHFOnly
            config.preEncodeLookaheadHFCutoffHz = defaults.preEncodeLookaheadHFCutoffHz
        case .finalStage:
            config.finalStagePresetID = defaults.finalStagePresetID
            config.finalDriveDB = defaults.finalDriveDB
            config.mpxDeviationKHz = defaults.mpxDeviationKHz
        case .phaseRotator:
            config.phaseRotationEnabled = defaults.phaseRotationEnabled
            config.phaseRotationFreqHz = defaults.phaseRotationFreqHz
        case .parametricEQ:
            config.parametricEQEnabled = defaults.parametricEQEnabled
            config.peqB1FreqHz = defaults.peqB1FreqHz
            config.peqB1GainDB = defaults.peqB1GainDB
            config.peqB2FreqHz = defaults.peqB2FreqHz
            config.peqB2GainDB = defaults.peqB2GainDB
            config.peqB2Q = defaults.peqB2Q
            config.peqB3FreqHz = defaults.peqB3FreqHz
            config.peqB3GainDB = defaults.peqB3GainDB
            config.peqB3Q = defaults.peqB3Q
            config.peqB4FreqHz = defaults.peqB4FreqHz
            config.peqB4GainDB = defaults.peqB4GainDB
        case .mbLimiter:
            config.multibandLimiterEnabled = defaults.multibandLimiterEnabled
            config.multibandLimiterThresholdDB = defaults.multibandLimiterThresholdDB
            config.multibandLimiterAttackMS = defaults.multibandLimiterAttackMS
            config.multibandLimiterReleaseMS = defaults.multibandLimiterReleaseMS
        case .expander:
            config.downwardExpanderEnabled = defaults.downwardExpanderEnabled
            config.expanderThresholdDB = defaults.expanderThresholdDB
            config.expanderRatio = defaults.expanderRatio
            config.expanderAttackMS = defaults.expanderAttackMS
            config.expanderReleaseMS = defaults.expanderReleaseMS
        case .bassClipper:
            config.bassClipperEnabled = defaults.bassClipperEnabled
            config.bassClipperCrossoverHz = defaults.bassClipperCrossoverHz
            config.bassClipperThresholdDB = defaults.bassClipperThresholdDB
            config.bassClipperDrive = defaults.bassClipperDrive
        case .dcClipper:
            config.dcClipperEnabled = defaults.dcClipperEnabled
            config.dcClipperCeilingDB = defaults.dcClipperCeilingDB
            config.dcClipperCancelFreqHz = defaults.dcClipperCancelFreqHz
        case .hfClipper:
            config.hfClipperEnabled = defaults.hfClipperEnabled
            config.hfClipperCrossoverHz = defaults.hfClipperCrossoverHz
            config.hfClipperThresholdDB = defaults.hfClipperThresholdDB
            config.hfClipperDrive = defaults.hfClipperDrive
        case .bs412:
            config.bs412Enabled = defaults.bs412Enabled
            config.bs412ThresholdDB = defaults.bs412ThresholdDB
            config.bs412WindowSeconds = defaults.bs412WindowSeconds
        case .compositeClipper:
            config.compositeClipperEnabled = defaults.compositeClipperEnabled
            config.compositeClipperThresholdDB = defaults.compositeClipperThresholdDB
            config.compositeClipperCeilingDB = defaults.compositeClipperCeilingDB
            config.compositeMultibandClipperEnabled = defaults.compositeMultibandClipperEnabled
        }

        let runtimeDisposition: RuntimeChangeDisposition
        switch selectedProcessingTab {
        case .core:
            runtimeDisposition = .restart
        case .overview, .formatProfile,
             .phaseRotator, .agc, .parametricEQ,
             .multiband, .mbLimiter, .expander,
             .widener, .primeBass,
             .bassClipper, .dcClipper, .hfClipper, .limiter,
             .compositeClipper, .bs412,
             .finalStage:
            runtimeDisposition = .live
        }

        saveConfig(restartRequired: runtimeDisposition == .restart)
        if runtimeDisposition == .restart {
            applyPendingRuntimeChanges()
        } else {
            applyLiveRuntimeConfigIfRunning()
        }
        statusText = selectedProcessingTab.resetStatusText
    }

    func resetCurrentRDSTabToDefaults() {
        publishConfigChange()
        let defaults = AppConfig()

        switch selectedRDSTab {
        case .control:
            // Control tab — operationally toggled state. Reset puts
            // master + flags back to library defaults.
            config.enRDS = defaults.enRDS
            config.rdsTP = defaults.rdsTP
            config.rdsTA = defaults.rdsTA
            config.rdsMS = defaults.rdsMS
            config.rdsDI_STEREO = defaults.rdsDI_STEREO
            config.rdsDI_HEAD = defaults.rdsDI_HEAD
            config.rdsDI_COMP = defaults.rdsDI_COMP
            config.rdsDI_DYN = defaults.rdsDI_DYN
        case .program:
            // enRDS lives on the Control tab; not reset here.
            config.rdsPI = defaults.rdsPI
            config.rdsECC = defaults.rdsECC
            config.rdsPTY = defaults.rdsPTY
            config.rdsPSA = defaults.rdsPSA
            config.rdsPSB = defaults.rdsPSB
            config.rdsPSC = defaults.rdsPSC
            config.rdsPSD = defaults.rdsPSD
            config.rdsPSActiveBank = defaults.rdsPSActiveBank
            config.rdsPSCentered = defaults.rdsPSCentered
            config.rdsEnablePTYN = defaults.rdsEnablePTYN
            config.rdsPTYN = defaults.rdsPTYN
            config.rdsPTYNCentered = defaults.rdsPTYNCentered
        case .radiotext:
            config.rdsRTText = defaults.rdsRTText
            config.rdsRTManualBuffers = defaults.rdsRTManualBuffers
            config.rdsRTCycleAB = defaults.rdsRTCycleAB
            config.rdsRTA = defaults.rdsRTA
            config.rdsRTB = defaults.rdsRTB
            config.rdsRTC = defaults.rdsRTC
            config.rdsRTD = defaults.rdsRTD
            config.rdsRTBufferAEnabled = defaults.rdsRTBufferAEnabled
            config.rdsRTBufferBEnabled = defaults.rdsRTBufferBEnabled
            config.rdsRTBufferCEnabled = defaults.rdsRTBufferCEnabled
            config.rdsRTBufferDEnabled = defaults.rdsRTBufferDEnabled
            config.rdsRTCR = defaults.rdsRTCR
            config.rdsRTCentered = defaults.rdsRTCentered
            config.rdsRTMode = defaults.rdsRTMode
            config.rdsRTCycle = defaults.rdsRTCycle
            config.rdsRTCycleTime = defaults.rdsRTCycleTime
            config.rdsRTActiveBuffer = defaults.rdsRTActiveBuffer
            config.rdsRTABCycleCount = defaults.rdsRTABCycleCount
            config.rdsEnableRTPlus = defaults.rdsEnableRTPlus
            config.rdsRTPlusFormatA = defaults.rdsRTPlusFormatA
            config.rdsRTPlusFormatB = defaults.rdsRTPlusFormatB
            config.rdsNowPlayingEnabled = defaults.rdsNowPlayingEnabled
            config.rdsNowPlayingScript = defaults.rdsNowPlayingScript
            config.rdsNowPlayingPollSeconds = defaults.rdsNowPlayingPollSeconds
            config.rdsNowPlayingTimeoutSeconds = defaults.rdsNowPlayingTimeoutSeconds
        case .longPS:
            config.rdsLongPS32 = defaults.rdsLongPS32
            config.rdsEnableLPS = defaults.rdsEnableLPS
            config.rdsLPSCentered = defaults.rdsLPSCentered
            config.rdsLPSCR = defaults.rdsLPSCR
        case .af:
            config.rdsEnableAF = defaults.rdsEnableAF
            config.rdsAFList = defaults.rdsAFList
            config.rdsAFMethod = defaults.rdsAFMethod
        case .schedule:
            config.rdsGroupSequence = defaults.rdsGroupSequence
            config.rdsSchedulerAuto = defaults.rdsSchedulerAuto
            config.rdsSchedulerStandard = defaults.rdsSchedulerStandard
            config.rdsSchedulerStandardLPS = defaults.rdsSchedulerStandardLPS
            config.rdsEnableCT = defaults.rdsEnableCT
            config.rdsEnableID = defaults.rdsEnableID
            config.rdsTZOffset = defaults.rdsTZOffset
            config.rdsLIC = defaults.rdsLIC
        case .carrier:
            config.rdsLevel = defaults.rdsLevel
            config.rdsGaussianEnabled = defaults.rdsGaussianEnabled
            config.rdsGaussianBWHZ = defaults.rdsGaussianBWHZ
            config.rdsGaussianTaps = defaults.rdsGaussianTaps
        }

        updateNowPlayingRunner()
        saveConfig(restartRequired: true)
        applyPendingRuntimeChanges()
        statusText = selectedRDSTab.resetStatusText
    }

    func loadConfigFromFile(_ path: String) {
        do {
            config = try AppConfig.load(fromINI: path)
            sourceMode = config.sourceMode
            monitorEnabled = config.monitorEnabled
            processingBypass = config.processingBypass
            inputGainDB = config.inputGainDB
            pendingRuntimeApply = false
            refreshDevices()
            updateNowPlayingRunner()
            statusText = "Config loaded: \(URL(fileURLWithPath: path).lastPathComponent)"
        } catch {
            statusText = "Config load failed: \(error)"
        }
    }

    func saveCurrentConfig() {
        saveConfig(restartRequired: false)
        statusText = "Config saved"
    }

    func saveConfigToFile(_ path: String) {
        do {
            try config.save(toINI: path)
            statusText = "Config saved: \(URL(fileURLWithPath: path).lastPathComponent)"
        } catch {
            statusText = "Config save failed: \(error)"
        }
    }

    func chooseNowPlayingScript() {
        let openPanel = NSOpenPanel()
        openPanel.message = "Choose a script to use for now playing metadata"
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose Script"
        if !config.rdsNowPlayingScript.isEmpty {
            let currentPath = NowPlayingFormatter.normalizeScriptPath(config.rdsNowPlayingScript)
            openPanel.directoryURL = URL(fileURLWithPath: (currentPath as NSString).deletingLastPathComponent)
            openPanel.nameFieldStringValue = URL(fileURLWithPath: currentPath).lastPathComponent
        }

        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            Task { @MainActor in
                self?.setConfigValue(\.rdsNowPlayingScript, url.path, runtimeDisposition: .none)
            }
        }
    }

    func startOrStopTransport(forceStart: Bool? = nil) {
        let shouldStart = forceStart ?? !isRunning
        if shouldStart {
            startEngine()
        } else {
            stopEngine()
        }
    }

    func toggleBypass() {
        processingBypass.toggle()
        persistBasicConfig()
        if isRunning {
            restartEngineWithStatus("Bypass updated")
        }
    }

    func resetPeaks() {
        clearPeakHolds()
        statusText = "Monitoring peaks reset"
    }

    func setInputGainLive(_ value: Double) {
        inputGainDB = value
        config.inputGainDB = value
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
    }

    /// Push the current `config.testTone*` and `config.sourceMode`
    /// values to the running engine via live-apply. Used by the Test
    /// Tone tab's bindings — every control there mutates the underlying
    /// AppConfig and then asks for the change to land on the running
    /// engine without restart. The view-model's own `sourceMode`
    /// mirror is updated first so `applyLiveRuntimeConfigIfRunning`'s
    /// override at line 2580 doesn't snap the runtime config back to
    /// the previous source.
    func applyLiveTestToneIfRunning() {
        sourceMode = config.sourceMode
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
    }

    // MARK: - Remote control (REST API surface; called via GUIControlBackend)

    /// Whole-config apply for the remote API -- setConfigValue's semantics at
    /// patch granularity: mutate config, sync the VM runtime mirrors, save,
    /// hot-apply the classified planes, refresh now-playing.
    func applyRemoteConfigPatch(_ patch: [String: String]) throws -> ConfigApplyResult {
        let (newConfig, outcomes, planes) = try ConfigPatch.apply(patch, to: config)
        publishConfigChange()
        config = newConfig
        // The live-apply overlay reads these VM mirrors; sync them so
        // remote changes to the mirrored keys actually land.
        sourceMode = newConfig.sourceMode
        monitorEnabled = newConfig.monitorEnabled
        inputGainDB = newConfig.inputGainDB
        saveConfig(restartRequired: planes.restartRequired)
        if planes.dspLive { applyLiveRuntimeConfigIfRunning() }
        if planes.rdsLive { applyLiveRDSConfigIfRunning() }
        updateNowPlayingRunner()
        statusText = "Remote control: applied \(patch.count) setting(s)"
        return ConfigApplyResult(
            outcomes: outcomes,
            appliedLive: (planes.dspLive || planes.rdsLive) && isRunning,
            restartPending: runtimeApplyPending
        )
    }

    func remoteStatus() -> ControlStatus {
        ControlStatus(
            running: isRunning,
            platform: "macOS (GUI)",
            version: AppConfig.appVersion,
            sampleRateHz: config.sampleRate,
            uptimeSeconds: nil,
            restartPending: runtimeApplyPending,
            sourceMode: config.sourceMode,
            outputMode: config.processedAudioOutput ? "processedAudio" : "mpxComposite",
            notes: statusText.isEmpty ? [] : [statusText]
        )
    }

    func remoteMeters() -> ControlMeters? {
        runningEngine?.controlMeters
    }

    func remoteDevices() -> ControlDevices {
        ControlDevices(
            inputs: inputDevices.map {
                ControlDevice(id: $0.uid, name: $0.name, canInput: true, canOutput: $0.hasOutput)
            },
            outputs: outputDevices.map {
                ControlDevice(id: $0.uid, name: $0.name, canInput: $0.hasInput, canOutput: true)
            },
            selectedInput: config.inputDeviceUID ?? "",
            selectedOutput: config.outputDeviceUID ?? "",
            note: "")
    }

    func remoteRDS() -> ControlRDS {
        let live = runningEngine?.currentRDSLiveSnapshot
        return ControlRDS(
            enabled: config.enRDS,
            pi: config.rdsPI,
            pty: config.rdsPTY,
            ta: config.rdsTA,
            tp: config.rdsTP,
            livePS: live?.ps,
            liveRT: live?.rt,
            livePTYN: live?.ptyn,
            liveLongPS: live?.longPS,
            configuredRT: config.rdsRTText,
            configuredPSActiveBank: config.rdsPSActiveBank
        )
    }

    func remoteTransport(_ action: TransportAction) -> ControlStatus {
        switch action {
        case .start: startOrStopTransport(forceStart: true)
        case .stop: startOrStopTransport(forceStart: false)
        case .restart: restartEngineWithStatus("Remote restart")
        }
        return remoteStatus()
    }

    func remotePresets() -> [String: [String]] {
        [
            "primebass": PresetCatalog.primeBassPresets.map(\.id),
            "widener": PresetCatalog.widenerPresets.map(\.id),
            "multiband": PresetCatalog.multibandPresets.map(\.id),
            "format_profile": Self.formatProfiles.map(\.id)
        ]
    }

    func remoteApplyPreset(kind: String, id: String, intensity: Double?) throws {
        switch kind.lowercased() {
        case "primebass":
            guard PresetCatalog.primeBassPresets.contains(where: { $0.id == id }) else {
                throw ControlError.invalidRequest("unknown primebass preset '\(id)'")
            }
            applyPrimeBassPreset(id: id)
        case "widener":
            guard PresetCatalog.widenerPresets.contains(where: { $0.id == id }) else {
                throw ControlError.invalidRequest("unknown widener preset '\(id)'")
            }
            applyWidenerPreset(id: id)
        case "multiband":
            guard PresetCatalog.multibandPresets.contains(where: { $0.id == id }) else {
                throw ControlError.invalidRequest("unknown multiband preset '\(id)'")
            }
            let level: MultibandPresetIntensity
            switch intensity {
            case .some(let v) where v < 0.75: level = .light
            case .some(let v) where v > 1.25: level = .heavy
            default: level = .normal
            }
            applyMultibandPreset(id: id, intensity: level)
        case "format_profile":
            guard Self.formatProfile(forID: id) != nil else {
                throw ControlError.invalidRequest("unknown format profile '\(id)'")
            }
            applyFormatProfile(id)
        default:
            throw ControlError.invalidRequest("unknown preset kind '\(kind)'")
        }
    }

    /// Start the control server once at launch when [CONTROL] enables it.
    /// Settings changes take effect at the next app launch (documented in
    /// the Settings card).
    func startControlServerIfEnabled() {
        guard config.controlEnabled, controlServerTask == nil else { return }
        let settings = ControlServerSettings(config: config)
        let backend = GUIControlBackend(vm: self)
        statusText = "Remote control: http://\(settings.host):\(settings.port)/"
        controlServerTask = Task {
            do {
                try await ControlServer.run(backend: backend, settings: settings)
            } catch {
                await MainActor.run {
                    self.statusText = "Remote control server failed: \(error)"
                }
            }
        }
    }

    private func applyLiveRuntimeConfigIfRunning() {
        guard isRunning, let runningEngine else { return }
        var runtimeConfig = config
        runtimeConfig.sourceMode = sourceMode
        runtimeConfig.monitorEnabled = monitorEnabled
        runtimeConfig.processingBypass = processingBypass
        runtimeConfig.inputGainDB = inputGainDB
        runningEngine.applyRuntimeConfig(runtimeConfig)
        pendingRuntimeApply = false
        statusText = "Live DSP parameters applied"
    }

    private func applyLiveRDSConfigIfRunning() {
        guard isRunning, let runningEngine else { return }
        runningEngine.applyRDSRuntimeConfig(config)
        pendingRuntimeApply = false
        statusText = "Live RDS text parameters applied"
    }

    private func captureRuntimeSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            config: config,
            sourceMode: sourceMode,
            monitorEnabled: monitorEnabled,
            processingBypass: processingBypass,
            inputGainDB: inputGainDB,
            selectedInputUID: selectedInputUID,
            selectedOutputUID: selectedOutputUID,
            selectedMonitorUID: selectedMonitorUID
        )
    }

    private func restoreRuntimeSnapshot(_ snapshot: RuntimeSnapshot) {
        config = snapshot.config
        sourceMode = snapshot.sourceMode
        monitorEnabled = snapshot.monitorEnabled
        processingBypass = snapshot.processingBypass
        inputGainDB = snapshot.inputGainDB
        selectedInputUID = snapshot.selectedInputUID
        selectedOutputUID = snapshot.selectedOutputUID
        selectedMonitorUID = snapshot.selectedMonitorUID
        updateNowPlayingRunner()
    }

    private func restartEngineWithStatus(_ status: String) {
        let wasRunning = isRunning
        let desiredSnapshot = captureRuntimeSnapshot()
        let fallbackSnapshot = activeRuntimeSnapshot
        stopEngine()
        if wasRunning {
            startEngine()
            if isRunning {
                statusText = "\(status) and applied"
                return
            }
            if let fallbackSnapshot {
                restoreRuntimeSnapshot(fallbackSnapshot)
                startEngine()
                if isRunning {
                    activeRuntimeSnapshot = fallbackSnapshot
                    restoreRuntimeSnapshot(desiredSnapshot)
                    pendingRuntimeApply = true
                    statusText = "\(status) failed; previous runtime restored. Pending changes kept."
                    return
                }
            }
            statusText = "\(status) failed; output remains stopped."
        }
    }

    private func startEngine() {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        stopEngineIfNeeded()
        persistBasicConfig()

        var runConfig = config
        runConfig.sourceMode = sourceMode
        runConfig.monitorEnabled = monitorEnabled
        runConfig.processingBypass = processingBypass
        runConfig.inputGainDB = inputGainDB

        let inputID: AudioDeviceID? = {
            guard runConfig.sourceMode.lowercased() == "input" else { return nil }
            return inputDevices.first(where: { $0.uid == selectedInputUID })?.id
        }()

        // Processed-audio output takes precedence over the decoded-MPX monitor
        // (the monitor is meaningless when no composite is generated). It uses the
        // main output device, not the monitor device.
        let processedAudio = runConfig.processedAudioOutput
        let useMonitor = monitorEnabled && !processedAudio
        let selectedOutUID = useMonitor ? selectedMonitorUID : selectedOutputUID
        let outputID: AudioDeviceID? = outputDevices.first(where: { $0.uid == selectedOutUID })?.id
        let outputMode: AudioOutputMode =
            processedAudio ? .processedAudio : (useMonitor ? .monitorAudio : .mpxComposite)

        // REFUSE to start when a PREFERRED device is unplugged, instead of
        // silently streaming to whatever the OS default happens to be (a
        // broadcast chain must never swap its transmitter feed unannounced;
        // matches the keep-the-selection convention of selectUID / the
        // device-scan warning). An empty UID (no preference ever chosen)
        // keeps the default-device behavior.
        var missingAtStart: [String] = []
        if runConfig.sourceMode.lowercased() == "input",
           !selectedInputUID.isEmpty, inputID == nil {
            missingAtStart.append("input \"\(config.inputDeviceName ?? selectedInputUID)\"")
        }
        if !selectedOutUID.isEmpty, outputID == nil {
            let roleName = useMonitor ? "monitor" : "output"
            let name = useMonitor
                ? (config.monitorDeviceName ?? selectedOutUID)
                : (config.outputDeviceName ?? selectedOutUID)
            missingAtStart.append("\(roleName) \"\(name)\"")
        }
        if !missingAtStart.isEmpty {
            let list = missingAtStart.joined(separator: ", ")
            statusText = "Not started: preferred \(list) device not connected -- "
                + "reconnect it or pick another device."
            startBlockedMessage = "The preferred \(list) device is not connected.\n\n"
                + "MPX Prime Studio will not silently use a different device: "
                + "reconnect the device, or choose another one in Settings, "
                + "then press Start again."
            isRunning = false
            return
        }

        let generator = MPXGenerator(
            config: runConfig,
            sampleRate: runConfig.sampleRate,
            nowPlayingState: nowPlayingState
        )
        let engine = AudioOutputEngine(
            generator: generator,
            config: runConfig,
            inputDeviceID: inputID,
            outputDeviceID: outputID,
            outputMode: outputMode
        )
        overflowHistory.removeAll(keepingCapacity: true)
        lastOverflowTotal = 0
        lastUnderflowTotal = 0
        clearPeakHolds()

        do {
            try engine.start()
            runningEngine = engine
            isRunning = true
            pendingRuntimeApply = false
            normalizeSelectionForOutputMode()
            if runConfig.processedAudioOutput {
                NSApp.sendAction(#selector(AppDelegate.closeCompositeOnlyAuxWindows), to: nil, from: nil)
            }
            activeRuntimeSnapshot = captureRuntimeSnapshot()
            engineStartReference = Date().timeIntervalSinceReferenceDate
            let mode = processedAudio ? "processed-audio" : (useMonitor ? "monitor" : "output")
            var line =
                "Running source=\(runConfig.sourceMode) mode=\(mode) "
                + "render=\(Int(engine.renderSampleRate))Hz hw=\(Int(engine.hardwareSampleRate))Hz"
            if let note = engine.deviceRoutingNote {
                line += " (\(note))"
            }
            statusText = line
            refreshMonitoringSnapshot()
        } catch AudioEngineError.inputPermissionDenied {
            statusText =
                "Microphone access denied. Open System Settings > Privacy & Security > Microphone "
                + "and enable MPX Prime, then press Start again."
            runningEngine = nil
            isRunning = false
        } catch {
            statusText = "Start failed: \(error)"
            runningEngine = nil
            isRunning = false
        }
    }

    private func stopEngine() {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        stopEngineIfNeeded()
        isRunning = false
        pendingRuntimeApply = false
        engineStartReference = nil
        overflowHistory.removeAll(keepingCapacity: true)
        lastOverflowTotal = 0
        lastUnderflowTotal = 0
        statusText = "Stopped"
        refreshMonitoringSnapshot()
    }

    private func stopEngineIfNeeded() {
        if let engine = runningEngine {
            engine.stop()
            runningEngine = nil
        }
    }

    /// Assign only when the value actually changed, so the slow-moving
    /// readout strings refreshed every monitor tick (20-30 Hz) don't fire
    /// objectWillChange when nothing moved -- Combine does not diff Equatable
    /// @Published values, so an unchanged write still invalidates every
    /// observing view. KeyPath-based rather than inout: an inout helper would
    /// write back through the @Published setter on every call and defeat the
    /// guard.
    @inline(__always)
    private func assignIfChanged<T: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<MPXPrimeViewModel, T>, _ value: T
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func refreshMonitoringSnapshot() {
        let now = Date().timeIntervalSinceReferenceDate
        let activeHz = desiredMonitoringRefreshHz
        let minRefreshInterval = 1.0 / activeHz
        if let last = lastMonitorRefreshTime, (now - last) < minRefreshInterval {
            return
        }

        // dt clamp for meter ballistics — independent of the active timer
        // rate. Lower bound is 1/120 s (8.3 ms) so a hypothetical 120 Hz
        // tick can't push smoothing below the per-step floor; upper bound
        // is 250 ms so a long pause (e.g. app backgrounded) doesn't make
        // the next on-screen tick look like an instantaneous jump.
        let fallbackInterval = 1.0 / activeHz
        let dt = max(
            1.0 / 120.0,
            min(0.25, now - (lastMonitorRefreshTime ?? (now - fallbackInterval)))
        )
        lastMonitorRefreshTime = now

        var inputPeak: Float = 0.0
        var outputPeak: Float = 0.0
        var deviationKHz: Float = 0.0
        var currentInputLeftPeak: Float = 0.0
        var currentInputRightPeak: Float = 0.0
        var currentAGCOutputLeftPeak: Float = 0.0
        var currentAGCOutputRightPeak: Float = 0.0
        var currentOutputPeak: Float = 0.0
        var liveInputLeftPeak: Float = 0.0
        var liveInputRightPeak: Float = 0.0
        var liveAGCOutputLeftPeak: Float = 0.0
        var liveAGCOutputRightPeak: Float = 0.0
        var liveOutputPeak: Float = 0.0
        var liveDeviationKHz: Float = 0.0
        var hasCapture = false
        var agcDetectorDB: Float = -120.0
        var agcGainDB: Float = 0.0
        var agcGateActive: Bool = false
        var compositeClipperGainReductionDB: Float = 0.0
        var compositeClipperLookaheadGainReductionDB: Float = 0.0
        var preEncodeAudioLimiterGainReductionDB: Float = 0.0
        var mpxSafetyLimiterGainReductionDB: Float = 0.0
        var pilotInjectionPercent: Float = 0.0
        var rdsInjectionPercent: Float = 0.0
        var audioCompositePeak: Float = 0.0
        var compositeBudgetMarginDB: Float = 0.0
        var postInjectionOvershoot: Float = 0.0
        var compositeOverBudget: Bool = false
        var outputStereoCorrelation: Float = 1.0
        var outputSideToMidRatio: Float = 0.0
        var health = MonitoringStreamHealth.stopped

        if let engine = runningEngine {
            updateEngineAnalysisCapture(engine: engine)
            let cap = engine.captureStats
            var runtime =
                "Running · Render \(Int(engine.renderSampleRate)) Hz · Hardware \(Int(engine.hardwareSampleRate)) Hz"
            if let inRate = engine.inputSampleRate {
                runtime += " · Input \(Int(inRate)) Hz"
            }
            runtime += " · Source \(engine.sourceDescription)"
            runtime += " · Applies \(engine.liveRuntimeApplyCount)"
            runtime += " · Skipped \(engine.skippedRuntimeApplyCount)"
            if let transport = engine.transportSnapshot {
                runtime += String(
                    format: " · Path %@ step %.4fx trim %.4f",
                    transport.resampleMode,
                    transport.sampleStep,
                    transport.ratioTrim
                )
            }
            runtimeText = runtime
            health.isRunning = true
            health.inputName =
                sourceMode.lowercased() == "tone"
                ? "Tone Generator"
                : (inputDevices.first(where: { $0.uid == selectedInputUID })?.name.ifEmpty("None")
                    ?? "None")
            health.renderHz = Int(engine.renderSampleRate.rounded())
            health.inputHz = Int((engine.inputSampleRate ?? 0).rounded())
            health.blockFrames = engine.blockSize

            if let stats = engine.inputStats {
                if let transport = engine.transportSnapshot {
                    inputRingText = String(
                        format: "Input Ring: %d frames buffered · Prime %d · Target %d · Overflows %llu · Underflows %llu · %@ %.4fx trim %.4f",
                        stats.bufferedFrames,
                        engine.inputPrimeFrames,
                        engine.inputTargetFrames,
                        stats.overflows,
                        stats.underflows,
                        transport.resampleMode,
                        transport.sampleStep,
                        transport.ratioTrim
                    )
                } else {
                    inputRingText =
                        "Input Ring: \(stats.bufferedFrames) frames buffered · Prime \(engine.inputPrimeFrames) · Target \(engine.inputTargetFrames) · Overflows \(stats.overflows) · Underflows \(stats.underflows)"
                }
                let target = max(1, engine.inputTargetFrames)
                inputBufferMax = Double(target * 2)
                inputBufferWarning = Double(target)
                inputBufferCritical = Double(target * 3 / 2)
                inputBufferValue = Double(stats.bufferedFrames)

                // Low-pass the displayed buffer fill (~10 s time
                // constant) so the Monitoring bar shows trend, not
                // tick-by-tick jitter. The buffer normally sits within
                // a few frames of target; operators care about
                // "trending up / down / steady," not the millisecond-
                // level wobble. Raw `inputBufferValue` is still
                // updated above and the delay text (`delayText`)
                // shows the instantaneous reading for any operator
                // who needs it. Cost of the longer τ: a real buffer
                // drop takes ~10 s to fully reflect on the bar; an
                // underflow event would also show up in `Dropouts`
                // tile much sooner, so this is OK.
                let rawFill = Double(stats.bufferedFrames) / max(1.0, inputBufferMax)
                let alpha = max(0.0, min(1.0, dt / (dt + 10.0)))
                bufferFillSmoothed =
                    (1.0 - alpha) * bufferFillSmoothed + alpha * rawFill

                let deltaOverflows =
                    stats.overflows >= lastOverflowTotal ? (stats.overflows - lastOverflowTotal) : 0
                let deltaUnderflows =
                    stats.underflows >= lastUnderflowTotal
                    ? (stats.underflows - lastUnderflowTotal) : 0
                lastOverflowTotal = stats.overflows
                lastUnderflowTotal = stats.underflows
                if deltaOverflows > 0 || deltaUnderflows > 0 {
                    overflowHistory.append((now, deltaOverflows, deltaUnderflows))
                }
                overflowHistory.removeAll { now - $0.time > 10.0 }

                health.ringFrames = stats.bufferedFrames
                health.ringCapacity = target * 2
                let recentOverflows = overflowHistory.reduce(UInt64(0)) { $0 + $1.overflows }
                let recentUnderflows = overflowHistory.reduce(UInt64(0)) { $0 + $1.underflows }
                health.overflowsRecent = Int(min(UInt64(Int.max), recentOverflows))
                health.underflowsRecent = Int(min(UInt64(Int.max), recentUnderflows))
                health.overflowsTotal = Int(min(UInt64(Int.max), stats.overflows))
                health.underflowsTotal = Int(min(UInt64(Int.max), stats.underflows))
            } else {
                inputRingText =
                    "Input Ring: inactive (tone source) · Capture callbacks \(cap.callbacks)"
                inputBufferValue = 0
                inputBufferMax = 1
                inputBufferWarning = 0.7
                inputBufferCritical = 0.9
                overflowHistory.removeAll(keepingCapacity: true)
                lastOverflowTotal = 0
                lastUnderflowTotal = 0
            }

            let meters = engine.meters
            hasCapture = cap.callbacks > 0
            inputPeak = hasCapture ? meters.inputPeak : meters.outputPeak
            outputPeak = meters.outputPeak
            deviationKHz = meters.deviationKHzPeak
            currentInputLeftPeak = hasCapture ? meters.inputLeftPeak : meters.outputPeak
            currentInputRightPeak = hasCapture ? meters.inputRightPeak : meters.outputPeak
            currentAGCOutputLeftPeak = meters.postAGCLeftPeak
            currentAGCOutputRightPeak = meters.postAGCRightPeak
            currentOutputPeak = meters.outputPeak
            liveInputLeftPeak = hasCapture ? meters.liveInputLeftPeak : meters.liveOutputPeak
            liveInputRightPeak = hasCapture ? meters.liveInputRightPeak : meters.liveOutputPeak
            liveAGCOutputLeftPeak = meters.livePostAGCLeftPeak
            liveAGCOutputRightPeak = meters.livePostAGCRightPeak
            liveOutputPeak = meters.liveOutputPeak
            liveDeviationKHz = meters.liveDeviationKHzPeak
            agcDetectorDB = meters.agcDetectorDB
            agcGainDB = meters.agcGainDB
            agcGateActive = meters.agcGateActive
            compositeClipperGainReductionDB = meters.compositeClipperGainReductionDB
            compositeClipperLookaheadGainReductionDB = meters.compositeClipperLookaheadGainReductionDB
            preEncodeAudioLimiterGainReductionDB = meters.preEncodeAudioLimiterGainReductionDB
            mpxSafetyLimiterGainReductionDB = meters.mpxSafetyLimiterGainReductionDB
            pilotInjectionPercent = meters.pilotInjectionPercent
            rdsInjectionPercent = meters.rdsInjectionPercent
            audioCompositePeak = meters.audioCompositePeak
            compositeBudgetMarginDB = meters.compositeBudgetMarginDB
            postInjectionOvershoot = meters.postInjectionOvershoot
            compositeOverBudget = meters.compositeOverBudget
            outputStereoCorrelation = meters.outputStereoCorrelation
            outputSideToMidRatio = meters.outputSideToMidRatio

            if engineStartReference == nil {
                engineStartReference = now
            }

            let scopesVisible = selectedSection == .monitoring || scopesWindowVisible
            if scopesVisible {
                updateScopes(engine: engine, inputPeak: inputPeak, outputPeak: outputPeak)
            }
            if selectedSection == .monitoring || spectrumWindowVisible {
                updateMPXSpectrum(engine: engine, now: now)
            }
            if preMPXSpectrumWindowVisible {
                updatePreMPXSpectrum(engine: engine, now: now)
            }
        } else {
            runtimeText = "Not running"
            inputRingText = "Input Ring: n/a"
            inputBufferValue = 0
            inputBufferMax = 1
            inputBufferWarning = 0.7
            inputBufferCritical = 0.9
            bufferFillSmoothed = 0.0
            engineStartReference = nil
            lastMonitorRefreshTime = now
            inputScopeLeft = Array(repeating: 0.0, count: 128)
            inputScopeRight = Array(repeating: 0.0, count: 128)
            outputScope = Array(repeating: 0.0, count: 128)
            smoothedInputScopeLeft = Array(repeating: 0.0, count: 128)
            smoothedInputScopeRight = Array(repeating: 0.0, count: 128)
            smoothedOutputScope = Array(repeating: 0.0, count: 128)
            inputScopeLeftGain = 1.0
            inputScopeRightGain = 1.0
            outputScopeGain = 1.0
            mpxSpectrumDB = Array(repeating: -100.0, count: Self.windowMPXSpectrumBins)
            mpxSpectrumMaxHz = 92_000.0
            mpxSpectrumNyquistHz = 0.0
            preMPXSpectrumLeftDB = Array(repeating: -100.0, count: Self.preMPXSpectrumBins)
            preMPXSpectrumRightDB = Array(repeating: -100.0, count: Self.preMPXSpectrumBins)
            preMPXSpectrumMaxHz = 16_000.0
            preMPXSpectrumNyquistHz = 0.0
            lastSpectrumRefreshTime = nil
            spectrumUpdateInFlight = false
            lastPreMPXSpectrumRefreshTime = nil
            preMPXSpectrumUpdateInFlight = false
            vuInputL = 0.0
            vuInputR = 0.0
            vuAGCOutputL = 0.0
            vuAGCOutputR = 0.0
            vuOutput = 0.0
            vuModulation = 0.0
            clearPeakHolds()
            limiterDetailText = String(
                format: "Drive %.1f dB • GR 0.0 dB • Max 0.0 dB • Safe 0.0 dB • Peak %@",
                config.finalDriveDB,
                Self.dbfsString(0.0)
            )
            compositeBudgetStateText = "Off"
            compositeCalibrationText = "Pilot 0.0% • RDS 0.0% • Audio -inf dBFS • Margin 0.0 dB"
            estimatedDeviationPeakKHz = 0.0
            pilotInjectionPercentValue = 0.0
            rdsInjectionPercentValue = 0.0
            audioCompositePeakLinear = 0.0
            compositeBudgetMarginDBValue = 0.0
            postInjectionOvershootValue = 0.0
            compositeOverBudget = false
            compositeClipperGainReductionDBValue = 0.0
            compositeClipperLookaheadGainReductionDBValue = 0.0
            preEncodeLimiterGainReductionDBValue = 0.0
            safetyLimiterGainReductionDBValue = 0.0
            stereoImageText = "Corr +1.00 • Side 0.00x"
            widenerStateText = "Off"
            overflowHistory.removeAll(keepingCapacity: true)
            lastOverflowTotal = 0
            lastUnderflowTotal = 0
        }
        streamHealth = health

        let modulationNorm = max(0.0, min(1.0, deviationKHz / 100.0))
        let inputLTarget = Self.levelMeterScale(currentInputLeftPeak)
        let inputRTarget = Self.levelMeterScale(currentInputRightPeak)
        let agcOutputLTarget = Self.levelMeterScale(currentAGCOutputLeftPeak)
        let agcOutputRTarget = Self.levelMeterScale(currentAGCOutputRightPeak)
        let outputTarget = Self.levelMeterScale(currentOutputPeak)
        let modulationTarget = modulationNorm

        vuInputL = smoothPeakProgramMeter(
            current: vuInputL,
            target: inputLTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuInputR = smoothPeakProgramMeter(
            current: vuInputR,
            target: inputRTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuAGCOutputL = smoothPeakProgramMeter(
            current: vuAGCOutputL,
            target: agcOutputLTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuAGCOutputR = smoothPeakProgramMeter(
            current: vuAGCOutputR,
            target: agcOutputRTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuOutput = smoothPeakProgramMeter(
            current: vuOutput,
            target: outputTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuModulation = smoothMeter(
            current: vuModulation,
            target: modulationTarget,
            dt: dt,
            attackMS: Self.meterAttackMS,
            releaseMS: Self.meterReleaseMS
        )

        inputLLevel = Double(max(0.0, min(1.0, vuInputL)))
        inputRLevel = Double(max(0.0, min(1.0, vuInputR)))
        agcOutputLLevel = Double(max(0.0, min(1.0, vuAGCOutputL)))
        agcOutputRLevel = Double(max(0.0, min(1.0, vuAGCOutputR)))
        outputLevel = Double(max(0.0, min(1.0, vuOutput)))
        modulationLevel = Double(max(0.0, min(1.0, vuModulation)))

        let inputLPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveInputLeftPeak,
            state: &peakHoldInputL,
            dt: dt
        )
        let inputRPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveInputRightPeak,
            state: &peakHoldInputR,
            dt: dt
        )
        let agcOutputLPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveAGCOutputLeftPeak,
            state: &peakHoldAGCOutputL,
            dt: dt
        )
        let agcOutputRPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveAGCOutputRightPeak,
            state: &peakHoldAGCOutputR,
            dt: dt
        )
        let outputPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveOutputPeak,
            state: &peakHoldOutput,
            dt: dt
        )
        inputLPeakHoldLevel = Double(Self.levelMeterScale(dbfs: inputLPeakHoldDB))
        inputRPeakHoldLevel = Double(Self.levelMeterScale(dbfs: inputRPeakHoldDB))
        agcOutputLPeakHoldLevel = Double(Self.levelMeterScale(dbfs: agcOutputLPeakHoldDB))
        agcOutputRPeakHoldLevel = Double(Self.levelMeterScale(dbfs: agcOutputRPeakHoldDB))
        outputPeakHoldLevel = Double(Self.levelMeterScale(dbfs: outputPeakHoldDB))
        modulationPeakHoldLevel = Double(
            updatePeakHold(
                livePeak: max(0.0, min(1.0, liveDeviationKHz / 100.0)),
                state: &peakHoldModulation,
                dt: dt
            ))
        let limiterGRPeakHold = updateLimiterGRPeakHold(
            liveValueDB: preEncodeAudioLimiterGainReductionDB,
            dt: dt
        )

        inputLText = Self.peakMeterString(currentPeak: currentInputLeftPeak, peakHoldDB: inputLPeakHoldDB)
        inputRText = Self.peakMeterString(currentPeak: currentInputRightPeak, peakHoldDB: inputRPeakHoldDB)
        agcOutputLText = Self.peakMeterString(currentPeak: currentAGCOutputLeftPeak, peakHoldDB: agcOutputLPeakHoldDB)
        agcOutputRText = Self.peakMeterString(currentPeak: currentAGCOutputRightPeak, peakHoldDB: agcOutputRPeakHoldDB)
        outputText = Self.peakMeterString(currentPeak: currentOutputPeak, peakHoldDB: outputPeakHoldDB)
        modulationText = String(format: "%5.1f kHz", deviationKHz)
        estimatedDeviationPeakKHz = deviationKHz
        pilotInjectionPercentValue = pilotInjectionPercent
        rdsInjectionPercentValue = rdsInjectionPercent
        audioCompositePeakLinear = audioCompositePeak
        compositeBudgetMarginDBValue = compositeBudgetMarginDB
        postInjectionOvershootValue = postInjectionOvershoot
        self.compositeOverBudget = compositeOverBudget
        compositeClipperGainReductionDBValue = compositeClipperGainReductionDB
        compositeClipperLookaheadGainReductionDBValue = compositeClipperLookaheadGainReductionDB
        preEncodeLimiterGainReductionDBValue = preEncodeAudioLimiterGainReductionDB
        safetyLimiterGainReductionDBValue = mpxSafetyLimiterGainReductionDB

        let limiterState =
            config.preEncodeAudioLimiterEnabled
            ? (preEncodeAudioLimiterGainReductionDB >= 0.2 ? "Active" : "Idle") : "Off"
        assignIfChanged(\.limiterStateText, limiterState)
        assignIfChanged(\.limiterDetailText, String(
            format: "Drive %.1f dB • Pre-Enc GR %.1f dB • Max %.1f dB • Safe %.1f dB • Peak %@",
            config.finalDriveDB,
            preEncodeAudioLimiterGainReductionDB,
            limiterGRPeakHold,
            mpxSafetyLimiterGainReductionDB,
            Self.dbfsString(outputPeak)
        ))
        let compositeBudgetState: String
        if !isRunning {
            compositeBudgetState = "Off"
        } else if compositeBudgetMarginDB >= 3.0 {
            compositeBudgetState = "Safe"
        } else if compositeBudgetMarginDB >= 1.0 {
            compositeBudgetState = "Tight"
        } else {
            compositeBudgetState = "Risk"
        }
        assignIfChanged(\.compositeBudgetStateText, compositeBudgetState)
        assignIfChanged(\.compositeCalibrationText, String(
            format: "Pilot %.1f%% • RDS %.1f%% • Audio %@ • Margin %.1f dB",
            pilotInjectionPercent,
            rdsInjectionPercent,
            Self.dbfsString(audioCompositePeak),
            compositeBudgetMarginDB
        ))
        assignIfChanged(\.stereoImageText, String(
            format: "Corr %@%.2f • Side %.2fx",
            outputStereoCorrelation >= 0 ? "+" : "",
            outputStereoCorrelation,
            outputSideToMidRatio
        ))
        let agcState: String
        if config.widebandAGCEnabled && !processingBypass {
            agcState = agcGateActive ? "Gate" : "On"
        } else {
            agcState = "Off"
        }
        assignIfChanged(\.agcStateText, agcState)
        assignIfChanged(\.agcDetailText, String(
            format: "Detector %.1f dB • Gain %.1f dB",
            agcDetectorDB,
            agcGainDB
        ) + (agcGateActive ? " • Gate" : ""))
        assignIfChanged(\.multibandStateText, config.multibandEnabled ? "On" : "Off")
        assignIfChanged(\.primeBassStateText, config.primeBassEnabled ? "On" : "Off")
        let widenerState: String
        if !config.stereoWidenEnabled || config.monoMode {
            widenerState = "Off"
        } else if outputStereoCorrelation < 0.0 || outputSideToMidRatio > 0.85 {
            widenerState = "Risk"
        } else if outputStereoCorrelation < 0.30 || outputSideToMidRatio > 0.55 {
            widenerState = "Wide"
        } else {
            widenerState = "Safe"
        }
        assignIfChanged(\.widenerStateText, widenerState)

        let elapsed = max(0.0, now - (engineStartReference ?? now))
        updateRDSFields(elapsed: elapsed)
    }

    private func updateEngineAnalysisCapture(engine: AudioOutputEngine) {
        let scopesVisible = selectedSection == .monitoring || scopesWindowVisible
        let inputHistoryVisible = scopesVisible || preMPXSpectrumWindowVisible
        let outputHistoryVisible = scopesVisible || spectrumWindowVisible
        engine.setAnalysisCapture(
            inputScope: inputHistoryVisible,
            outputHistory: outputHistoryVisible,
            preMPXHistory: preMPXSpectrumWindowVisible,
            outputImageMetrics: selectedSection == .monitoring
        )
    }

    private func updateScopes(engine: AudioOutputEngine, inputPeak: Float, outputPeak: Float) {
        let snapshot = engine.scopeSnapshot(windowMS: scopeTimebaseMS)
        if snapshot.inputLeft.isEmpty || snapshot.inputRight.isEmpty || snapshot.output.isEmpty {
            inputScopeLeft = Array(repeating: 0.0, count: 128)
            inputScopeRight = Array(repeating: 0.0, count: 128)
            outputScope = Array(repeating: 0.0, count: 128)
            smoothedInputScopeLeft = inputScopeLeft
            smoothedInputScopeRight = inputScopeRight
            smoothedOutputScope = outputScope
            inputScopeLeftGain = 1.0
            inputScopeRightGain = 1.0
            outputScopeGain = 1.0
            return
        }

        inputScopeLeft = smoothedScopeSamples(
            snapshot.inputLeft,
            fallbackPeak: inputPeak,
            previous: &smoothedInputScopeLeft,
            gainState: &inputScopeLeftGain,
            autoGain: scopeAutoGainEnabled
        )
        inputScopeRight = smoothedScopeSamples(
            snapshot.inputRight,
            fallbackPeak: inputPeak,
            previous: &smoothedInputScopeRight,
            gainState: &inputScopeRightGain,
            autoGain: scopeAutoGainEnabled
        )
        outputScope = smoothedScopeSamples(
            snapshot.output,
            fallbackPeak: outputPeak,
            previous: &smoothedOutputScope,
            gainState: &outputScopeGain,
            autoGain: scopeAutoGainEnabled
        )
    }

    private func updateMPXSpectrum(engine: AudioOutputEngine, now: TimeInterval) {
        let refreshHz =
            spectrumWindowVisible ? Self.windowMPXSpectrumRefreshHz : Self.inlineMPXSpectrumRefreshHz
        let refreshInterval = 1.0 / refreshHz
        if let last = lastSpectrumRefreshTime, (now - last) < refreshInterval {
            return
        }
        guard !spectrumUpdateInFlight else { return }
        lastSpectrumRefreshTime = now
        spectrumUpdateInFlight = true
        let raw = engine.outputSignalWindow(into: &spectrumInputScratch, frameCount: 4096)
        let sampleRate = raw.sampleRate
        let validCount = raw.count

        let maxDisplayHz: Double = config.fftWindow96kHz ? 96_000.0 : 60_000.0
        let displayBins =
            spectrumWindowVisible ? Self.windowMPXSpectrumBins : Self.inlineMPXSpectrumBins
        let analyzer = spectrumAnalyzer
        let samples = spectrumInputScratch
        spectrumQueue.async { [weak self] in
            let spectrum = analyzer.compute(
                samples: samples,
                validCount: validCount,
                sampleRate: sampleRate,
                displayBins: displayBins,
                maxDisplayHz: maxDisplayHz
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.mpxSpectrumDB = spectrum.dbBins
                self.mpxSpectrumMaxHz = spectrum.maxHz
                self.mpxSpectrumNyquistHz = spectrum.nyquistHz
                self.spectrumUpdateInFlight = false
            }
        }
    }

    private func updatePreMPXSpectrum(engine: AudioOutputEngine, now: TimeInterval) {
        let refreshInterval = 1.0 / Self.windowPreMPXSpectrumRefreshHz
        if let last = lastPreMPXSpectrumRefreshTime, (now - last) < refreshInterval {
            return
        }
        guard !preMPXSpectrumUpdateInFlight else { return }
        lastPreMPXSpectrumRefreshTime = now
        preMPXSpectrumUpdateInFlight = true
        let raw = engine.inputStereoWindow(
            intoLeft: &preMPXSpectrumLeftScratch,
            right: &preMPXSpectrumRightScratch,
            frameCount: AudioOutputEngine.preMPXSpectrumFrameCount
        )
        let sampleRate = raw.sampleRate
        let validCount = raw.count
        let leftSamples = preMPXSpectrumLeftScratch
        let rightSamples = preMPXSpectrumRightScratch
        let displayBins = Self.preMPXSpectrumBins
        let analyzer = preMPXSpectrumAnalyzer
        spectrumQueue.async { [weak self] in
            let maxDisplayHz = min(16_000.0, sampleRate * 0.5)
            let leftSpectrum = analyzer.compute(
                samples: leftSamples,
                validCount: validCount,
                sampleRate: sampleRate,
                displayBins: displayBins,
                maxDisplayHz: maxDisplayHz
            )
            let rightSpectrum = analyzer.compute(
                samples: rightSamples,
                validCount: validCount,
                sampleRate: sampleRate,
                displayBins: displayBins,
                maxDisplayHz: maxDisplayHz
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.preMPXSpectrumLeftDB = leftSpectrum.dbBins
                self.preMPXSpectrumRightDB = rightSpectrum.dbBins
                self.preMPXSpectrumMaxHz = leftSpectrum.maxHz
                self.preMPXSpectrumNyquistHz = leftSpectrum.nyquistHz
                self.preMPXSpectrumUpdateInFlight = false
            }
        }
    }

    private func smoothedScopeSamples(
        _ samples: [Float],
        fallbackPeak: Float,
        previous: inout [Float],
        gainState: inout Float,
        autoGain: Bool
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        if previous.count != samples.count {
            previous = Array(repeating: 0.0, count: samples.count)
        }

        let targetScale: Float
        if autoGain {
            let measuredPeak = samples.reduce(Float(0.0)) { current, value in
                max(current, fabsf(value.isFinite ? value : 0.0))
            }
            let fallback = fallbackPeak.isFinite ? max(0.0, min(2.0, fallbackPeak)) : 0.0
            // Target ~85% vertical utilization with bounded auto-gain.
            let referencePeak = max(0.01, min(1.2, max(measuredPeak, fallback * 0.55)))
            targetScale = min(8.0, max(1.0, 0.85 / referencePeak))
        } else {
            targetScale = 1.0
        }
        gainState = (gainState * 0.82) + (targetScale * 0.18)

        var smoothed = previous
        for i in samples.indices {
            let raw = samples[i].isFinite ? samples[i] : 0.0
            var sample = max(-1.2, min(1.2, raw)) * gainState
            if autoGain, fabsf(sample) < 0.0015 {
                sample *= 0.7
            }
            sample = max(-1.0, min(1.0, sample))
            smoothed[i] = (smoothed[i] * 0.62) + (sample * 0.38)
        }
        if smoothed.count > 2 {
            var spatial = smoothed
            for i in 1..<(smoothed.count - 1) {
                spatial[i] =
                    (smoothed[i - 1] * 0.12) + (smoothed[i] * 0.76) + (smoothed[i + 1] * 0.12)
            }
            smoothed = spatial
        }
        previous = smoothed
        return smoothed
    }

    private func updateRDSFields(elapsed: Double) {
        // Prefer the live snapshot from the running RDS coder when available,
        // so what's shown is exactly what's being transmitted (including PS
        // scroll windows, Nt: advance, now-playing macro resolution). Fall
        // back to the config-derived preview when the engine is offline.
        let live = runningEngine?.currentRDSLiveSnapshot

        if let live, !live.ps.isEmpty {
            assignIfChanged(\.rdsPS, live.ps)
        } else {
            assignIfChanged(\.rdsPS, Self.currentTimedDisplayText(config.activePSBankText, elapsed: elapsed).ifEmpty("-"))
        }
        assignIfChanged(\.rdsPI, config.rdsPI)
        assignIfChanged(\.rdsPTY, Self.ptyName(for: config.rdsPTY, rbds: config.rdsPtyRBDS))
        if let live, !live.ptyn.isEmpty {
            assignIfChanged(\.rdsPTYN, live.ptyn)
        } else {
            assignIfChanged(\.rdsPTYN, Self.currentTimedDisplayText(config.rdsPTYN, elapsed: elapsed).ifEmpty("-"))
        }
        assignIfChanged(\.rdsAID, config.rdsEnableRTPlus ? "AID: 4BD7 (GROUP 11A)" : "AID: OFF")
        if let live, !live.longPS.isEmpty {
            assignIfChanged(\.rdsLongPS, live.longPS)
        } else {
            assignIfChanged(\.rdsLongPS, Self.currentTimedDisplayText(config.rdsLongPS32, elapsed: elapsed).ifEmpty("-"))
        }
        if let live, !live.rt.isEmpty {
            // Trim trailing CR terminator (0x0D) that prepareRTFrame appends
            // for the 2A "end of text" marker so the on-screen readout is clean.
            assignIfChanged(\.rdsRadiotext, live.rt
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .ifEmpty("-"))
        } else {
            assignIfChanged(\.rdsRadiotext, currentRTText(elapsed: elapsed).ifEmpty("-"))
        }
    }

    private func currentRTText(elapsed: Double) -> String {
        let nowPlayingSnapshot = nowPlayingState.currentSnapshot()
        let enabledBuffers = enabledRTBufferIndices
        let text: String
        if !enabledBuffers.isEmpty {
            var sequence: [(duration: Double, text: String)] = []
            for index in enabledBuffers {
                let raw = rtBufferText(at: index)
                let expanded = NowPlayingFormatter.expandTemplate(raw, snapshot: nowPlayingSnapshot)
                sequence.append(
                    contentsOf: Self.parseRTBufferDisplaySequence(
                        expanded,
                        defaultDuration: max(1.0, config.rdsRTCycleTime)
                    )
                )
            }
            text = Self.currentTimedDisplayText(sequence: sequence, elapsed: elapsed)
        } else {
            let expanded = NowPlayingFormatter.expandTemplate(config.rdsRTText, snapshot: nowPlayingSnapshot)
            text = Self.currentTimedDisplayText(expanded, elapsed: elapsed)
        }
        let width = config.rdsRTMode.uppercased() == "2B" ? 32 : 64
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= width {
            return trimmed
        }
        return String(trimmed.prefix(width))
    }

    private static func currentTimedDisplayText(_ raw: String, elapsed: Double) -> String {
        let seq = parseTimedDisplaySequence(raw)
        return currentTimedDisplayText(sequence: seq, elapsed: elapsed)
    }

    private static func currentTimedDisplayText(
        sequence seq: [(duration: Double, text: String)],
        elapsed: Double
    ) -> String {
        guard !seq.isEmpty else { return "" }
        if seq.count == 1 {
            return seq[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let total = seq.reduce(0.0) { $0 + max(0.1, $1.duration) }
        let t = elapsed.truncatingRemainder(dividingBy: total)
        var acc: Double = 0.0
        for item in seq {
            acc += max(0.1, item.duration)
            if t <= acc {
                return item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return seq.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func parseRTBufferDisplaySequence(
        _ raw: String,
        defaultDuration: Double
    ) -> [(duration: Double, text: String)] {
        let sequence = parseTimedDisplaySequence(raw)
        guard !containsTimedDisplayCommand(raw) else { return sequence }
        let duration = max(0.1, defaultDuration)
        return sequence.map { (duration, $0.text) }
    }

    private static func containsTimedDisplayCommand(_ raw: String) -> Bool {
        raw.range(of: #"(^|[\s/])\d+(?:\.\d+)?s:"#, options: .regularExpression) != nil
    }

    private static let timedPrefixRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^([0-9]+(?:\.[0-9]+)?)s:"#, options: [])
    private static let timedTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"([0-9]+(?:\.[0-9]+)?)s:"#, options: [])

    private static func parseTimedDisplaySequence(_ raw: String) -> [(
        duration: Double, text: String
    )] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [(10.0, "")]
        }

        let slashParts = trimmed.split(separator: "/").map(String.init)
        if slashParts.count > 1 {
            var out: [(Double, String)] = []
            let prefixRegex = timedPrefixRegex
            for part in slashParts {
                let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if p.isEmpty { continue }
                if let prefixRegex {
                    let ns = p as NSString
                    if let match = prefixRegex.firstMatch(
                        in: p, options: [], range: NSRange(location: 0, length: ns.length)),
                        match.range.location == 0 {
                        let dur = Double(ns.substring(with: match.range(at: 1))) ?? 2.5
                        let textStart = match.range.location + match.range.length
                        let text = textStart < ns.length ? ns.substring(from: textStart) : ""
                        out.append((dur, text))
                        continue
                    }
                }
                out.append((2.5, p))
            }
            return out.isEmpty ? [(10.0, trimmed)] : out
        }

        if let tokenRegex = timedTokenRegex {
            let ns = trimmed as NSString
            let matches = tokenRegex.matches(
                in: trimmed, options: [], range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty, matches[0].range.location == 0 {
                var out: [(Double, String)] = []
                for (idx, match) in matches.enumerated() {
                    let durRange = match.range(at: 1)
                    let duration = Double(ns.substring(with: durRange)) ?? 2.5
                    let textStart = match.range.location + match.range.length
                    let textEnd =
                        (idx + 1 < matches.count) ? matches[idx + 1].range.location : ns.length
                    let textRange = NSRange(
                        location: textStart, length: max(0, textEnd - textStart))
                    let text = ns.substring(with: textRange).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    out.append((duration, text))
                }
                if !out.isEmpty {
                    return out
                }
            }
        }

        return [(10.0, trimmed)]
    }

    // Europe (RDS, EN 50067 / IEC 62106) PTY 0..31.
    private static let ptyNamesRDS: [String] = [
        "None", "News", "Current Affairs", "Information", "Sport", "Education", "Drama", "Culture",
        "Science", "Varied", "Pop Music", "Rock Music", "Easy Music", "Light Classical",
        "Serious Classical",
        "Other Music", "Weather", "Finance", "Children's", "Social Affairs", "Religion", "Phone-In",
        "Travel", "Leisure", "Jazz", "Country", "National Music", "Oldies", "Folk Music",
        "Documentary",
        "Alarm Test", "Alarm"
    ]

    // North America (RBDS, NRSC-4-B) PTY 0..31. Same 5-bit code as RDS, but
    // receivers in the US / Canada / Mexico / South Korea label it from this
    // table. Selected via the PTY region toggle (config.rdsPtyRBDS).
    private static let ptyNamesRBDS: [String] = [
        "None", "News", "Information", "Sports", "Talk", "Rock", "Classic Rock",
        "Adult Hits", "Soft Rock", "Top 40", "Country", "Oldies", "Soft", "Nostalgia", "Jazz",
        "Classical", "Rhythm and Blues", "Soft R&B", "Language", "Religious Music",
        "Religious Talk", "Personality", "Public", "College", "Spanish Talk", "Spanish Music",
        "Hip-Hop", "Unassigned", "Unassigned", "Weather", "Emergency Test", "Emergency"
    ]

    static func ptyNames(rbds: Bool) -> [String] { rbds ? ptyNamesRBDS : ptyNamesRDS }

    private static let finalStagePresets: [FinalStagePreset] = [
        .init(
            id: "balanced",
            title: "Balanced Music",
            agcEnabled: true,
            agcTargetDB: -16.0,
            agcAttackMS: 80.0,
            agcReleaseMS: 1200.0,
            agcMaxGainDB: 12.0,
            agcMinGainDB: -12.0,
            finalDriveDB: 6.0,
            preEncodeAudioLimiterEnabled: true
        ),
        .init(
            id: "chr",
            title: "CHR / Dance",
            agcEnabled: true,
            agcTargetDB: -15.0,
            agcAttackMS: 55.0,
            agcReleaseMS: 900.0,
            agcMaxGainDB: 10.0,
            agcMinGainDB: -9.0,
            finalDriveDB: 8.0,
            preEncodeAudioLimiterEnabled: true
        ),
        .init(
            id: "punchy",
            title: "Punchy Music",
            agcEnabled: true,
            agcTargetDB: -15.0,
            agcAttackMS: 60.0,
            agcReleaseMS: 1000.0,
            agcMaxGainDB: 11.0,
            agcMinGainDB: -10.0,
            finalDriveDB: 7.5,
            preEncodeAudioLimiterEnabled: true
        ),
        .init(
            id: "speech",
            title: "Speech / Talk",
            agcEnabled: true,
            agcTargetDB: -14.0,
            agcAttackMS: 45.0,
            agcReleaseMS: 750.0,
            agcMaxGainDB: 10.0,
            agcMinGainDB: -8.0,
            finalDriveDB: 4.5,
            preEncodeAudioLimiterEnabled: true
        )
    ]

    // MARK: - Format Profiles (top-level "Station Format" selector)

    /// A `FormatProfile` is a top-level "Station Format" bundle that
    /// atomically wires multiband / final-stage / PrimeBass / stereo
    /// widener / composite-clipper settings to a coherent target for one
    /// programming format. The operator picks once; downstream stages all
    /// receive matching settings. Per-stage knobs remain editable; the
    /// profile selection stays as a cosmetic label until the operator
    /// picks a different one.
    ///
    /// All `*PresetID` fields reference existing per-stage preset IDs —
    /// the profile system is a wrapper over the existing per-stage
    /// preset infrastructure, not a parallel one.
    struct FormatProfile: Identifiable {
        let id: String
        let title: String
        let summary: String
        let multibandPresetID: String
        let multibandIntensity: MultibandPresetIntensity
        let finalStagePresetID: String
        let primeBassEnabled: Bool
        let primeBassPresetID: String      // ignored when primeBassEnabled == false
        let widenerPresetID: String
        let compositeClipperThresholdDB: Double
        let compositeClipperCeilingDB: Double
        let finalDriveDB: Double
    }

    static let formatProfiles: [FormatProfile] = [
        // "Custom" is a sentinel — selecting it just records the label
        // and leaves every per-stage setting alone. Use this after
        // hand-tuning to flag "my settings are bespoke, don't auto-apply
        // a format default if I re-pick this entry from the menu." The
        // sentinel preset IDs below are placeholders; the apply path
        // short-circuits on `id == "custom"` and never reads them.
        FormatProfile(
            id: "custom",
            title: "Custom",
            summary: "Your manually-tuned settings — picking this leaves everything as you set it.",
            multibandPresetID: "5_ac",
            multibandIntensity: .normal,
            finalStagePresetID: "balanced",
            primeBassEnabled: false,
            primeBassPresetID: "ac",
            widenerPresetID: "safe_fm",
            compositeClipperThresholdDB: -1.0,
            compositeClipperCeilingDB: -0.3,
            finalDriveDB: 6.0
        ),
        FormatProfile(
            id: "community_radio",
            title: "Community Radio",
            summary: "Conservative LPFM / community-radio default — clean output, low loudness, broad source compatibility.",
            multibandPresetID: "5_ac",
            multibandIntensity: .light,
            finalStagePresetID: "balanced",
            primeBassEnabled: false,
            primeBassPresetID: "ac",
            widenerPresetID: "safe_fm",
            compositeClipperThresholdDB: -1.0,
            compositeClipperCeilingDB: -0.3,
            finalDriveDB: 4.0
        ),
        FormatProfile(
            id: "pop_ac",
            title: "Pop / Adult Contemporary",
            summary: "Mainstream music — balanced multiband, gentle PrimeBass, open widener, moderate drive.",
            multibandPresetID: "5_ac",
            multibandIntensity: .normal,
            finalStagePresetID: "balanced",
            primeBassEnabled: true,
            primeBassPresetID: "ac",
            widenerPresetID: "open_music",
            compositeClipperThresholdDB: -1.0,
            compositeClipperCeilingDB: -0.3,
            finalDriveDB: 6.0
        ),
        FormatProfile(
            id: "chr_top40",
            title: "CHR / Top 40",
            summary: "Modern hits — bright multiband, hot drive, wide stereo image, competitive loudness.",
            multibandPresetID: "5_chr",
            multibandIntensity: .normal,
            finalStagePresetID: "chr",
            primeBassEnabled: true,
            primeBassPresetID: "chr",
            widenerPresetID: "wide_chr",
            compositeClipperThresholdDB: -0.8,
            compositeClipperCeilingDB: -0.2,
            finalDriveDB: 8.0
        ),
        FormatProfile(
            id: "rock",
            title: "Rock",
            summary: "Punchy multiband, rock-tuned PrimeBass, open widener — preserves transient impact.",
            multibandPresetID: "5_rock",
            multibandIntensity: .normal,
            finalStagePresetID: "punchy",
            primeBassEnabled: true,
            primeBassPresetID: "rock",
            widenerPresetID: "open_music",
            compositeClipperThresholdDB: -1.0,
            compositeClipperCeilingDB: -0.3,
            finalDriveDB: 7.0
        ),
        FormatProfile(
            id: "edm_dance",
            title: "EDM / Dance",
            summary: "Heavy multiband, hot drive, deep bass, wide image — peak loudness for dance formats.",
            multibandPresetID: "5_dance",
            multibandIntensity: .heavy,
            finalStagePresetID: "chr",
            primeBassEnabled: true,
            primeBassPresetID: "chr",
            widenerPresetID: "wide_chr",
            compositeClipperThresholdDB: -0.7,
            compositeClipperCeilingDB: -0.2,
            finalDriveDB: 9.0
        ),
        FormatProfile(
            id: "urban_hiphop",
            title: "Urban / Hip-Hop",
            summary: "Deep low end, urban-tuned PrimeBass, hot drive — bass-forward urban contemporary.",
            multibandPresetID: "5_urban",
            multibandIntensity: .normal,
            finalStagePresetID: "chr",
            primeBassEnabled: true,
            primeBassPresetID: "urban",
            widenerPresetID: "open_music",
            compositeClipperThresholdDB: -0.8,
            compositeClipperCeilingDB: -0.2,
            finalDriveDB: 8.0
        ),
        FormatProfile(
            id: "jazz_classical",
            title: "Jazz / Classical",
            summary: "Dynamic-preserving — light multiband, no PrimeBass, safe widener, conservative drive.",
            multibandPresetID: "5_classic",
            multibandIntensity: .light,
            finalStagePresetID: "balanced",
            primeBassEnabled: false,
            primeBassPresetID: "ac",
            widenerPresetID: "safe_fm",
            compositeClipperThresholdDB: -1.2,
            compositeClipperCeilingDB: -0.4,
            finalDriveDB: 3.0
        ),
        FormatProfile(
            id: "news_talk",
            title: "News / Talk",
            summary: "Speech-optimized multiband + final-stage, no PrimeBass, safe widener, low drive.",
            multibandPresetID: "5_talk",
            multibandIntensity: .light,
            finalStagePresetID: "speech",
            primeBassEnabled: false,
            primeBassPresetID: "talk",
            widenerPresetID: "safe_fm",
            compositeClipperThresholdDB: -1.0,
            compositeClipperCeilingDB: -0.3,
            finalDriveDB: 4.5
        )
    ]

    static func formatProfile(forID id: String) -> FormatProfile? {
        formatProfiles.first(where: { $0.id == id })
    }

    private static func ptyName(for pty: Int, rbds: Bool) -> String {
        let names = ptyNames(rbds: rbds)
        if names.indices.contains(pty) {
            return names[pty]
        }
        return names[0]
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    private static func approxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func sanitizeHex(_ raw: String, width: Int) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let filtered = upper.filter { ch in
            switch ch {
            case "0"..."9", "A"..."F":
                return true
            default:
                return false
            }
        }
        if filtered.isEmpty {
            return String(repeating: "0", count: width)
        }
        if filtered.count >= width {
            return String(filtered.suffix(width))
        }
        return String(repeating: "0", count: width - filtered.count) + filtered
    }

    private func saveConfig(restartRequired: Bool) {
        // Any user edit diverges the live config from the loaded preset. Persist
        // the flip once (not per keystroke) so "Loaded - edited" survives relaunch.
        // Skip flips that are just the fallout of a programmatic load settling.
        if activeSnapshotID != nil, !activeSnapshotModified,
           Date().timeIntervalSinceReferenceDate >= suppressModifiedFlipUntil {
            activeSnapshotModified = true
            writeSnapshotsToDisk()
        }
        enqueueConfigSave(snapshot: config)
        if restartRequired && isRunning {
            if !pendingRuntimeApply {
                statusText = "Restart required for engine, routing, or encoder-structure changes. Use Apply Restart in Monitoring."
            }
            pendingRuntimeApply = true
        }
    }

    private func updateNowPlayingRunner() {
        nowPlayingRunner.updateConfig(config)
    }

    enum ConfigReloadOrigin {
        case manual
        case external
    }

    enum RuntimeChangeDisposition {
        /// Setting requires the engine to be stopped and restarted to take effect.
        case restart
        /// Setting flows through the DSP runtime config and applies live.
        case live
        /// Setting flows through the RDS runtime config and applies live.
        case liveRDS
        /// Setting takes effect via a side channel (e.g. Now Playing
        /// script reload) that doesn't need either runtime apply.
        case none
    }

    func applyLoadedConfig(_ loadedConfig: AppConfig, origin: ConfigReloadOrigin) {
        // The wholesale config swap + mirror-property writes below make the
        // control bindings fire onChange asynchronously; ignore the resulting
        // saveConfig "modified" flips until they settle (see saveConfig).
        suppressModifiedFlipUntil = Date().timeIntervalSinceReferenceDate + 0.6
        config = loadedConfig
        sourceMode = config.sourceMode
        monitorEnabled = config.monitorEnabled
        processingBypass = config.processingBypass
        inputGainDB = config.inputGainDB
        refreshDevices()
        updateNowPlayingRunner()

        if isRunning {
            pendingRuntimeApply = true
            statusText =
                origin == .external
                ? "Config changed on disk. Restart-required changes are pending; use Apply Restart in Monitoring."
                : "Config reloaded. Restart-required changes are pending; use Apply Restart in Monitoring."
        } else {
            pendingRuntimeApply = false
            statusText = origin == .external ? "Config reloaded from disk" : "Config reloaded"
        }
    }

    private func startConfigWatcher() {
        stopConfigWatcher()
        let directory = (configPath as NSString).deletingLastPathComponent
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        configWatchFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleExternalConfigReloadIfNeeded()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.configWatchFD >= 0 {
                close(self.configWatchFD)
                self.configWatchFD = -1
            }
        }
        configWatchSource = source
        source.resume()
    }

    private func stopConfigWatcher() {
        configReloadWorkItem?.cancel()
        configReloadWorkItem = nil
        configWatchSource?.cancel()
        configWatchSource = nil
        if configWatchFD >= 0 {
            close(configWatchFD)
            configWatchFD = -1
        }
    }

    private func scheduleExternalConfigReloadIfNeeded() {
        let now = Date().timeIntervalSinceReferenceDate
        if now < ignoreConfigReloadUntil {
            return
        }
        configReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            if now < self.ignoreConfigReloadUntil {
                return
            }
            do {
                try self.applyExternalConfigReloadIfChanged()
            } catch {
                self.statusText = "Config reload failed: \(error)"
            }
        }
        configReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func applyExternalConfigReloadIfChanged() throws {
        let loaded = try AppConfig.load(fromINI: configPath)
        applyLoadedConfig(loaded, origin: .external)
    }

    private func publishConfigChange() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func enqueueConfigSave(snapshot: AppConfig) {
        pendingConfigSnapshot = snapshot
        guard !configSaveInFlight else { return }
        configSaveInFlight = true
        processPendingConfigSave()
    }

    private func processPendingConfigSave() {
        guard let snapshot = pendingConfigSnapshot else {
            configSaveInFlight = false
            return
        }
        pendingConfigSnapshot = nil
        let path = configPath

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var saveError: Error?
            do {
                try snapshot.save(toINI: path)
            } catch {
                saveError = error
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if let saveError {
                    self.statusText = "Config save failed: \(saveError)"
                } else {
                    self.ignoreConfigReloadUntil = Date().timeIntervalSinceReferenceDate + 0.75
                }
                self.processPendingConfigSave()
            }
        }
    }

    /// Resolve which device UID to select, preferring stability over convenience:
    /// 1. exact UID match; 2. same device on a different port (UID changed, name
    /// matches) -> adopt its new UID; 3. a device WAS chosen but isn't connected
    /// -> keep the preference so it reconnects (do NOT silently switch to another
    /// device); 4. only with no prior preference at all, default to the first.
    private func selectUID(uid: String?, name: String?, from devices: [AudioDevice]) -> String {
        if let uid, !uid.isEmpty, devices.contains(where: { $0.uid == uid }) {
            return uid
        }
        if let name, !name.isEmpty, let byName = devices.first(where: { $0.name == name }) {
            return byName.uid
        }
        if let uid, !uid.isEmpty {
            return uid   // remembered device is unplugged -- keep it, don't substitute
        }
        return devices.first?.uid ?? ""
    }

    private func clearPeakHolds() {
        peakHoldInputL = AudioPeakHoldState()
        peakHoldInputR = AudioPeakHoldState()
        peakHoldAGCOutputL = AudioPeakHoldState()
        peakHoldAGCOutputR = AudioPeakHoldState()
        peakHoldOutput = AudioPeakHoldState()
        peakHoldModulation = PeakHoldState()
        limiterGRPeakHoldDB = 0.0
        limiterGRPeakHoldRemaining = 0.0
        inputLPeakHoldLevel = 0.0
        inputRPeakHoldLevel = 0.0
        agcOutputLPeakHoldLevel = 0.0
        agcOutputRPeakHoldLevel = 0.0
        outputPeakHoldLevel = 0.0
        modulationPeakHoldLevel = 0.0
    }

    private func updatePeakHold(livePeak: Float, state: inout PeakHoldState, dt: Double) -> Float {
        let live = max(0.0, min(1.0, livePeak.isFinite ? livePeak : 0.0))
        if !stickyPeaksEnabled {
            state.value = live
            state.holdRemaining = 0.0
            return live
        }
        if live >= state.value {
            state.value = live
            state.holdRemaining = max(0.0, meterPeakHoldSeconds)
            return state.value
        }
        if state.holdRemaining > 0.0 {
            state.holdRemaining = max(0.0, state.holdRemaining - dt)
            return state.value
        }
        let fallRate = max(1.0, meterPeakFallDBPerSecond)
        let fallFactor = powf(10.0, Float(-(fallRate * dt) / 20.0))
        state.value = max(live, state.value * fallFactor)
        if state.value < 1e-6 {
            state.value = 0.0
        }
        return state.value
    }

    private func updateAudioPeakHold(
        livePeakLinear: Float,
        state: inout AudioPeakHoldState,
        dt: Double
    ) -> Float {
        let liveDB = Self.dbfsValue(livePeakLinear)
        if !stickyPeaksEnabled {
            state.db = liveDB
            state.holdRemaining = 0.0
            return liveDB
        }
        if liveDB >= state.db {
            state.db = liveDB
            state.holdRemaining = max(0.0, meterPeakHoldSeconds)
            return state.db
        }
        if state.holdRemaining > 0.0 {
            state.holdRemaining = max(0.0, state.holdRemaining - dt)
            return state.db
        }
        let fallRate = max(1.0, meterPeakFallDBPerSecond)
        state.db = max(liveDB, state.db - Float(fallRate * dt))
        return state.db
    }

    private func updateLimiterGRPeakHold(liveValueDB: Float, dt: Double) -> Float {
        let live = max(0.0, liveValueDB.isFinite ? liveValueDB : 0.0)
        if !stickyPeaksEnabled {
            limiterGRPeakHoldDB = live
            limiterGRPeakHoldRemaining = 0.0
            return live
        }
        if live >= limiterGRPeakHoldDB {
            limiterGRPeakHoldDB = live
            limiterGRPeakHoldRemaining = max(0.0, meterPeakHoldSeconds)
            return limiterGRPeakHoldDB
        }
        if limiterGRPeakHoldRemaining > 0.0 {
            limiterGRPeakHoldRemaining = max(0.0, limiterGRPeakHoldRemaining - dt)
            return limiterGRPeakHoldDB
        }
        let fallRate = max(1.0, meterPeakFallDBPerSecond)
        limiterGRPeakHoldDB = max(live, limiterGRPeakHoldDB - Float(fallRate * dt))
        if limiterGRPeakHoldDB < 0.01 {
            limiterGRPeakHoldDB = 0.0
        }
        return limiterGRPeakHoldDB
    }

    private func smoothMeter(
        current: Float, target: Float, dt: Double, attackMS: Float, releaseMS: Float
    ) -> Float {
        let clampedTarget = max(0.0, min(1.0, target.isFinite ? target : 0.0))
        let tauMS = clampedTarget >= current ? max(1.0, attackMS) : max(5.0, releaseMS)
        let alpha = 1.0 - exp(-dt / (Double(tauMS) * 0.001))
        return current + ((clampedTarget - current) * Float(alpha))
    }

    private func smoothPeakProgramMeter(
        current: Float,
        target: Float,
        dt: Double,
        releaseMS: Float
    ) -> Float {
        // Peak-program ballistics: fixed fast attack, configurable release.
        // smoothMeter() already selects attack-vs-release internally from the
        // rising/falling direction and clamps the target, so this is a thin
        // wrapper that pins the attack to the peak-meter constant. (The prior
        // if/else had two identical branches.)
        smoothMeter(
            current: current,
            target: target,
            dt: dt,
            attackMS: Self.audioPeakMeterAttackMS,
            releaseMS: releaseMS
        )
    }

    private static func dbfsValue(_ linear: Float) -> Float {
        guard linear.isFinite, linear > 1e-9 else { return -120.0 }
        return 20.0 * log10f(linear)
    }

    private static func levelMeterScale(dbfs db: Float) -> Float {
        let floorDB: Float = -36.0
        let norm = max(0.0, min(1.0, (db - floorDB) / -floorDB))
        return norm
    }

    private static func levelMeterScale(_ linear: Float) -> Float {
        levelMeterScale(dbfs: dbfsValue(linear))
    }

    private static func dbfsString(_ linear: Float) -> String {
        // Right-justified to a constant 6-char numeric field so the
        // monospaced readout never changes width as the value moves between
        // 1/2/3-digit magnitudes ("-6.2" vs "-12.4" vs "-120.0") -- avoids
        // the layout jitter that variable-length numbers cause.
        guard linear > 1e-9 else { return "  -inf dBFS" }
        let db = 20.0 * log10(Double(linear))
        return String(format: "%6.1f dBFS", db)
    }

    private static func meterMetaString(rms: Float, peak: Float, peakHoldDB: Float? = nil) -> String {
        let rmsString = dbfsString(rms)
        let displayPeakDB: Double
        if let peakHold = peakHoldDB {
            displayPeakDB = Double(peakHold)
        } else {
            displayPeakDB = peak > 1e-9 ? (20.0 * log10(Double(peak))) : -120.0
        }
        return "\(rmsString)   \(String(format: "%6.1f", displayPeakDB)) pk"
    }

    private static func peakMeterString(currentPeak: Float, peakHoldDB: Float? = nil) -> String {
        let currentString = dbfsString(currentPeak)
        guard let peakHoldDB else { return currentString }
        return "\(currentString)   \(String(format: "%6.1f", peakHoldDB)) pk"
    }

    private static func lufsString(_ value: Float) -> String {
        guard value.isFinite, value > -119.5 else { return "—" }
        return String(format: "%.1f LUFS", value)
    }
}

extension String {
    fileprivate func ifEmpty(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Strip the trailing "   N.N pk" suffix produced by `peakMeterString`
    /// so the vertical meter strip only renders the current value. The
    /// peak-hold position is already shown as the white tick on the strip,
    /// so duplicating it as text only adds clutter and overflows the
    /// 58 pt column.
    fileprivate var meterCurrentOnly: String {
        // The current value ends at its unit suffix; split there so leading
        // field-padding spaces in the value (now right-justified to a fixed
        // width) aren't mistaken for the "   " peak separator.
        if let r = range(of: " dBFS") { return String(self[..<r.upperBound]) }
        if let r = range(of: " LUFS") { return String(self[..<r.upperBound]) }
        if let r = range(of: "   ") { return String(self[..<r.lowerBound]) }
        return self
    }
}

private struct RootView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // NavigationSplitView gives the standard macOS collapsible sidebar
        // (toggle auto-provided in the toolbar, plus View > Toggle Sidebar /
        // Cmd-Ctrl-S). Minimum 220 pt fits the longest label ("Composite
        // Clipper") with icon + padding without truncation.
        NavigationSplitView {
            StageSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            StageContentView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .alert("Cannot Start",
                       isPresented: Binding(
                           get: { model.startBlockedMessage != nil },
                           set: { if !$0 { model.startBlockedMessage = nil } })) {
                    Button("OK", role: .cancel) { model.startBlockedMessage = nil }
                } message: {
                    Text(model.startBlockedMessage ?? "")
                }
                // Always-visible broadcast status header (transport / peaks /
                // deviation / GR / budget / injections). On the detail column
                // so the sidebar runs full height under the title bar, the
                // standard macOS sidebar layout. It still spans every stage
                // because the detail hosts them all.
                .safeAreaInset(edge: .top, spacing: 0) {
                    BroadcastStatusBar(model: model)
                }
                .inspector(isPresented: $model.inspectorVisible) {
                    StageInspector(model: model)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
        }
        .toolbar {
            // Frequently used commands belong in the toolbar (HIG). The
            // sidebar-collapse toggle is added automatically by
            // NavigationSplitView at the leading edge.
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.startOrStopTransport()
                } label: {
                    Label(model.isRunning ? "Stop" : "Start",
                          systemImage: model.isRunning ? "stop.fill" : "play.fill")
                }
                .help(model.isRunning
                      ? "Stop the encoder (Command-Return)"
                      : "Start the encoder (Command-Return)")

                Button {
                    model.toggleBypass()
                } label: {
                    Label("Bypass",
                          systemImage: model.processingBypass ? "waveform.slash" : "waveform")
                }
                .help("Toggle processing bypass (Command-B)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.openConfig), to: nil, from: nil)
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a configuration file (Command-O)")

                Button {
                    model.saveCurrentConfig()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .help("Save the current configuration (Command-S)")

                // Composite scope is meaningless without an MPX composite.
                if !model.processedAudioOutputActive {
                    Button {
                        NSApp.sendAction(#selector(AppDelegate.showScopesWindow), to: nil, from: nil)
                    } label: {
                        Label("Scopes", systemImage: "waveform.path")
                    }
                    .help("Open the Scopes window")
                }

                // In processed-audio mode the MPX spectrum is meaningless; the
                // Spectrum button opens the Audio (pre-MPX) spectrum instead.
                Button {
                    if model.processedAudioOutputActive {
                        NSApp.sendAction(#selector(AppDelegate.showPreMPXSpectrumWindow), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(#selector(AppDelegate.showSpectrumWindow), to: nil, from: nil)
                    }
                } label: {
                    Label("Spectrum", systemImage: "chart.bar.xaxis")
                }
                .help(model.processedAudioOutputActive ? "Open the Audio Spectrum window" : "Open the MPX Spectrum window")

                Button {
                    NSApp.sendAction(#selector(AppDelegate.showLevelsWindow), to: nil, from: nil)
                } label: {
                    Label("Levels", systemImage: "slider.vertical.3")
                }
                .help("Open the Levels window")
            }
        }
    }
}

/// Sidebar grouping every stage by its top-level group (Monitoring,
/// Processing, RDS). Selecting a row updates `model.selectedStage`, which
/// propagates to the legacy enums so existing per-tab content code keeps
/// working unchanged.
private struct StageSidebar: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        List(selection: $model.selectedStage) {
            ForEach(Stage.Group.allCases, id: \.rawValue) { group in
                // Processed-audio output hides the RDS group and the
                // composite-domain Processing stages (composite clipper, BS.412).
                let stages = Stage.allCases.filter { $0.group == group && model.isStageVisible($0) }
                if !stages.isEmpty {
                    Section(group.rawValue) {
                        ForEach(stages) { stage in
                            StageSidebarRow(model: model, stage: stage)
                                .tag(stage)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// One sidebar row. Renders the existing Label (icon + text) and, when
/// the stage has an enable toggle that is currently on, a small accent
/// dot on the trailing edge — matches Mail's unread-count / Slack's
/// online-status idiom: filled when on, nothing when off, no badge at
/// all for stages with no enable concept (Monitoring, Overview, Core,
/// Final Stage, RDS sub-tabs, Snapshots).
private struct StageSidebarRow: View {
    @ObservedObject var model: MPXPrimeViewModel
    let stage: Stage

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(stage.label)
            } icon: {
                // Decorative — the adjacent Text(stage.label)
                // already conveys the row identity to VoiceOver.
                Image(systemName: stage.icon)
                    .accessibilityHidden(true)
                    // Explicit `.tint` foreground on the *icon only* —
                    // keeps text in the default sidebar foreground
                    // (white in dark mode) while icons pick up the
                    // system accent. Hierarchical layering gives the
                    // 3-level tonal depth Apple's first-party sidebars
                    // use (Music.app, Mail.app).
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            }
            Spacer(minLength: 0)
            if model.isStageEnabled(stage) == true {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Enabled")
                    .help("Enabled")
            }
        }
    }
}

/// Content column for the currently-selected stage. Each stage renders its
/// own scroll view + content; for Processing and RDS stages the per-tab view
/// is the same one the legacy segmented-picker section used, plus the
/// per-tab reset button. Monitoring stays as a single dashboard.
private struct StageContentView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // If the selection is hidden by the active output mode (e.g. an RDS or
        // composite stage while processed-audio output is on), display the
        // Processing overview instead of a stale pane.
        let stage = model.isStageVisible(model.selectedStage) ? model.selectedStage : .processingOverview
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(stage.detailTitle)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.top, 16)
            .padding(.horizontal, 22)
            .padding(.bottom, 8)

            Text(stage.detailSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)

            Group {
                if stage == .monitoring {
                    MonitoringDashboardView(model: model)
                } else if stage == .testTone {
                    TestToneView(model: model)
                } else if stage == .snapshots {
                    SnapshotsView(model: model)
                } else if !model.isStageVisible(model.selectedStage) {
                    ProcessingOverviewGrid(model: model)
                } else if stage.legacyProcessingTab != nil {
                    StageProcessingContent(model: model)
                } else if stage.legacyRDSTab != nil {
                    StageRDSContent(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Content for a Processing stage selection. Hosts the existing per-tab
/// view plus the per-tab reset button. The legacy segmented Picker is
/// gone — sidebar selection drives `selectedProcessingTab` via the
/// `selectedStage.didSet` sync. A read-only signal-flow chip strip sits
/// at the top as alternate navigation (Wheatstone-style block-diagram
/// hint without the editor cost).
private struct StageProcessingContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedStage != .processingOverview {
                // Cap to the same 1120 pt width as the content column
                // below so the strip sits horizontally centered over its
                // content. Default `.frame(maxWidth:)` alignment is
                // `.center`, so no extra alignment argument needed.
                SignalFlowStrip(model: model)
                    .frame(maxWidth: 1120)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.selectedProcessingTab {
                    case .overview:
                        ProcessingOverviewGrid(model: model)
                    case .formatProfile:
                        ProcessingFormatProfileTab(model: model)
                    case .core:
                        ProcessingCoreTab(model: model)
                    case .agc:
                        ProcessingAGCTab(model: model)
                    case .phaseRotator:
                        ProcessingPhaseRotatorTab(model: model)
                    case .parametricEQ:
                        ProcessingParametricEQTab(model: model)
                    case .primeBass:
                        ProcessingPrimeBassTab(model: model)
                    case .multiband:
                        ProcessingMultibandTab(model: model)
                    case .mbLimiter:
                        ProcessingMultibandLimiterTab(model: model)
                    case .expander:
                        ProcessingExpanderTab(model: model)
                    case .bassClipper:
                        ProcessingBassClipperTab(model: model)
                    case .dcClipper:
                        ProcessingDCClipperTab(model: model)
                    case .hfClipper:
                        ProcessingHFClipperTab(model: model)
                    case .widener:
                        ProcessingWidenerTab(model: model)
                    case .limiter:
                        ProcessingLimiterTab(model: model)
                    case .bs412:
                        ProcessingBS412Tab(model: model)
                    case .compositeClipper:
                        ProcessingCompositeClipperTab(model: model)
                    case .finalStage:
                        ProcessingFinalStageTab(model: model)
                    }

                    if model.selectedProcessingTab != .overview {
                        HStack {
                            Spacer()
                            Button(model.selectedProcessingTab.resetButtonTitle) {
                                model.resetCurrentProcessingTabToDefaults()
                            }
                            .buttonStyle(.bordered)
                        }

                        // Tab help text as a footer block below the
                        // controls and the Reset action — matches
                        // System Settings / Xcode "explanation under
                        // the controls" idiom rather than competing
                        // with the controls visually at the top of
                        // the tab.
                        TabHelpBox(text: model.selectedProcessingTab.helpText)
                    }
                }
                .padding(20)
                .frame(maxWidth: 1120, alignment: .topLeading)
            }
        }
    }
}

/// Content for an RDS stage selection.
private struct StageRDSContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.selectedRDSTab {
                case .control:
                    RDSStatusTab(model: model)
                case .program:
                    RDSProgramTab(model: model)
                case .radiotext:
                    RDSRadiotextTab(model: model)
                case .longPS:
                    RDSLongPSTab(model: model)
                case .af:
                    RDSAFTab(model: model)
                case .schedule:
                    RDSScheduleTab(model: model)
                case .carrier:
                    RDSCarrierTab(model: model)
                }

                HStack {
                    Spacer()
                    Button(model.selectedRDSTab.resetButtonTitle) {
                        model.resetCurrentRDSTabToDefaults()
                    }
                    .buttonStyle(.bordered)
                }

                // Footer help block — same pattern as Processing tabs.
                // Sits below the controls and the Reset action so it
                // reads as explanatory text rather than competing with
                // the controls at the top of the view.
                TabHelpBox(text: model.selectedRDSTab.helpText)
            }
            .padding(20)
            .frame(maxWidth: 1120, alignment: .topLeading)
        }
    }
}

enum CardStyle {
    /// Standard broadcast panel — used for parameter controls, general
    /// status blocks, RDS config. Uses the window control-background
    /// surface.
    case standard
    /// Meter / readout plate — slightly darker surface so heat-mapped
    /// bars and LED dots pop. Used for metering cards and RDS live
    /// snapshots where the content is dense numeric readout.
    case meter
}

private struct Card<Content: View>: View {
    let title: String
    let style: CardStyle
    @ViewBuilder var content: Content

    init(title: String, style: CardStyle = .standard, @ViewBuilder content: () -> Content) {
        self.title = title
        self.style = style
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: BroadcastStyle.cardSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(surface)
            .overlay(
                RoundedRectangle(cornerRadius: BroadcastStyle.panelCornerRadius)
                    .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelCornerRadius))
        }
    }

    private var surface: Color {
        switch style {
        case .standard: return BroadcastStyle.panelSurface
        case .meter:    return BroadcastStyle.meterSurface
        }
    }

    private var padding: CGFloat {
        switch style {
        case .standard: return BroadcastStyle.cardPadding
        case .meter:    return BroadcastStyle.meterCardPadding
        }
    }
}

/// Test Tone tab — a first-class sidebar stage that drives the
/// engine's tone source. Enable replaces the audio input live; the
/// rest of the chain (AGC, multiband, clippers, encoder, BS.412)
/// processes the tone normally so operators can observe response at
/// calibrated input levels (default -20 dBFS, broadcast line
/// reference). Three signal types — sine for level / separation /
/// encoder-bandwidth tests, pink and white noise for broadband
/// response checks. Stereo modes cover the operator's diagnostic
/// needs (mono / L=-R / L-only / R-only).
///
/// All controls are live-applicable via the existing RuntimeConfig
/// path; no engine restart required when toggling enable, type,
/// mode, frequency, or level.
/// Named-snapshot manager. 8 fixed slots saved to `<configPath>.snapshots.json`
/// alongside the INI. Each slot row: name field + Save (capture current
/// config into this slot, overwrites) + Load (apply this slot's config
/// to the live engine) + Clear (delete this slot). The saved-at
/// timestamp reads "saved <date>" once the slot is occupied.
///
/// Snapshots are heavier than format profiles (full config capture vs
/// per-stage preset bundle) and meant for "Saturday Night vs Morning
/// Show" type setups operators want to flip between without recomposing
/// every stage by hand.
private struct SnapshotsView: View {
    @ObservedObject var model: MPXPrimeViewModel

    private var activePresetName: String? {
        guard let id = model.activeSnapshotID else { return nil }
        return model.snapshots.compactMap { $0 }.first { $0.id == id }?.name
    }

    /// Unmissable summary of which preset is live (or that the config is custom).
    @ViewBuilder private var activePresetBanner: some View {
        let modified = model.activeSnapshotModified
        HStack(spacing: 8) {
            if let name = activePresetName {
                Image(systemName: modified ? "pencil.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(modified ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                Text(modified ? "Active preset: \(name)  (edited since loaded)"
                              : "Active preset: \(name)")
                    .fontWeight(.semibold)
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No preset loaded - the live configuration isn't tied to a saved preset.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(activePresetName == nil
                      ? Color.secondary.opacity(0.08)
                      : (modified ? Color.orange : Color.accentColor).opacity(0.12))
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Presets") {
                    VStack(alignment: .leading, spacing: 10) {
                        activePresetBanner
                        ForEach(0..<MPXPrimeViewModel.snapshotSlotCount, id: \.self) { slot in
                            SnapshotSlotRow(model: model, slot: slot)
                            if slot < MPXPrimeViewModel.snapshotSlotCount - 1 {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }

                TabHelpBox(text: "Eight named presets capturing the full configuration. Save the current setup into a slot, load it back later — survives app restart. Heavier than Format Profiles: a preset captures every per-stage setting and RDS field, not just the DSP bundle.")
            }
            .padding(20)
            .frame(maxWidth: 1120, alignment: .topLeading)
        }
    }
}

private struct SnapshotSlotRow: View {
    @ObservedObject var model: MPXPrimeViewModel
    let slot: Int
    @State private var draftName: String = ""
    @State private var confirmingClear = false
    @FocusState private var nameFieldFocused: Bool

    private var snapshot: ConfigSnapshot? { model.snapshots[slot] }

    /// This slot holds the snapshot whose config is currently live.
    private var isActive: Bool { snapshot != nil && snapshot?.id == model.activeSnapshotID }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(slot + 1).")
                .font(.system(.callout, design: .monospaced))
                .fontWeight(isActive ? .bold : .regular)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Preset \(slot + 1)", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
                    .focused($nameFieldFocused)
                    // Enter commits (creates an empty slot or renames a saved
                    // one); losing focus commits a rename so a typed name is
                    // never silently lost.
                    .onSubmit { commitName(allowCreate: true) }
                    .onChange(of: nameFieldFocused) { _, focused in
                        if !focused { commitName(allowCreate: false) }
                    }

                HStack(spacing: 6) {
                    if isActive {
                        Label(
                            model.activeSnapshotModified ? "Loaded - edited" : "Loaded",
                            systemImage: model.activeSnapshotModified
                                ? "pencil.circle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(model.activeSnapshotModified ? Color.orange : Color.accentColor)
                    }
                    if let snap = snapshot {
                        Text("saved \(Self.relativeDateString(snap.savedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("empty")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button("Save") {
                    // Capture the current full config into this slot under the
                    // field's name (saveSnapshot trims + defaults when empty).
                    // Do NOT clear draftName -- the name stays visible, and the
                    // onChange(of: snapshot?.name) sync keeps the field correct.
                    model.saveSnapshot(slot: slot, name: draftName)
                }
                .help("Capture the current full configuration into this slot. Overwrites any existing preset here.")

                Button("Import...") {
                    importPreset()
                }
                .help("Load a preset from an MPX Prime Studio .ini file into this slot (overwrites). Does not apply it -- use Load for that.")

                Button("Load") {
                    model.loadSnapshot(slot: slot)
                }
                .disabled(snapshot == nil)
                .help("Apply this slot's saved configuration to the live engine. Restart-required fields surface a pending-apply prompt.")

                Button("Export...") {
                    exportPreset()
                }
                .disabled(snapshot == nil)
                .help("Save this preset to a file (a standard MPX Prime Studio .ini you can share or load with --config).")

                Button("Clear", role: .destructive) {
                    confirmingClear = true
                }
                .disabled(snapshot == nil)
                .help("Delete this slot. Cannot be undone.")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .onAppear {
            draftName = snapshot?.name ?? ""
        }
        // Keep the field in sync when the slot's stored name changes underneath
        // (loaded from disk, renamed, saved, cleared) -- but never clobber the
        // user's in-progress typing.
        .onChange(of: snapshot?.name) { _, newName in
            if !nameFieldFocused { draftName = newName ?? "" }
        }
        // Deleting a saved slot is irreversible -- confirm first (HIG: confirm
        // destructive actions that can't be undone).
        .confirmationDialog(
            "Clear preset \(slot + 1)?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Preset", role: .destructive) {
                model.clearSnapshot(slot: slot)
                draftName = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(snapshot?.name ?? "Preset \(slot + 1)")\" will be deleted. This cannot be undone.")
        }
    }

    /// Persist the edited name. For a saved slot, rename it (on Enter or focus
    /// loss) when the text actually changed. For an empty slot, only Enter
    /// (`allowCreate`) creates the snapshot -- clicking away must not silently
    /// save a slot the user never asked for.
    /// Prompt for an INI file and import it into this slot.
    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Preset"
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            model.importSnapshot(slot: slot, from: url)
        }
    }

    /// Prompt for a destination and write the preset's config there.
    private func exportPreset() {
        guard snapshot != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.exportFilename(slot: slot)
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .data]
        panel.canCreateDirectories = true
        panel.title = "Export Preset"
        panel.prompt = "Export"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportSnapshot(slot: slot, to: url)
        }
    }

    private func commitName(allowCreate: Bool) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = snapshot {
            if !trimmed.isEmpty, trimmed != existing.name {
                model.renameSnapshot(slot: slot, name: trimmed)
            }
        } else if allowCreate, !trimmed.isEmpty {
            model.saveSnapshot(slot: slot, name: trimmed)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static func relativeDateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

private struct TestToneView: View {
    @ObservedObject var model: MPXPrimeViewModel

    private static let frequencyPresets: [Double] = [
        50, 100, 400, 1_000, 5_000, 10_000, 12_000, 15_000
    ]

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { model.config.sourceMode.lowercased() == "tone" },
            set: {
                model.config.sourceMode = $0 ? "tone" : "input"
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    private var typeBinding: Binding<String> {
        Binding(
            get: { model.config.testToneType.lowercased() },
            set: {
                model.config.testToneType = $0
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { model.config.testToneMode.lowercased() },
            set: {
                model.config.testToneMode = $0
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    private var freqBinding: Binding<Double> {
        Binding(
            get: { model.config.testToneFreq },
            set: {
                model.config.testToneFreq = $0
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    private var levelBinding: Binding<Double> {
        Binding(
            get: { model.config.testToneLevelDB },
            set: {
                model.config.testToneLevelDB = $0
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                enableCard
                signalCard
                if typeBinding.wrappedValue == "sine" {
                    frequencyCard
                }
                levelCard
                statusCard

                TabHelpBox(text: "Internal signal generator that replaces the audio input. Sine for level / separation / encoder-bandwidth tests; pink and white noise for broadband response checks. Four stereo modes (mono / L=-R / left-only / right-only) cover common diagnostic needs. The rest of the chain (AGC, multiband, clippers, BS.412, encoder) processes the tone normally so you can observe each stage's response at calibrated input levels.")
            }
            .padding(20)
            .frame(maxWidth: 1120, alignment: .topLeading)
        }
    }

    // MARK: - Cards

    private var enableCard: some View {
        Card(title: "Test Tone Source") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: isEnabled) {
                    Text("Enable Test Tone").font(.body)
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var signalCard: some View {
        Card(title: "Signal") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Type") {
                    Picker("Type", selection: typeBinding) {
                        Text("Sine").tag("sine")
                        Text("Pink").tag("pink")
                        Text("White").tag("white")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }

                LabeledContent("Stereo mode") {
                    Picker("Stereo mode", selection: modeBinding) {
                        Text("Mono").tag("mono")
                        Text("L=-R").tag("stereo")
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)
                }
            }
        }
    }

    private var frequencyCard: some View {
        Card(title: "Frequency") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Frequency (Hz)") {
                    TextField(
                        "Frequency",
                        value: freqBinding,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .labelsHidden()
                }

                HStack(spacing: 8) {
                    Text("Presets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Self.frequencyPresets, id: \.self) { freq in
                        let isActive = abs(freqBinding.wrappedValue - freq) < 0.5
                        Button(presetLabel(for: freq)) {
                            freqBinding.wrappedValue = freq
                        }
                        .buttonStyle(.bordered)
                        // Tint the preset matching the current frequency so the
                        // active selection is visible at a glance.
                        .tint(isActive ? BroadcastStyle.accent : nil)
                    }
                }
            }
        }
    }

    private var levelCard: some View {
        Card(title: "Output Level") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent {
                    Slider(
                        value: levelBinding,
                        in: -60.0 ... 0.0,
                        step: 0.5
                    )
                    .accessibilityLabel("Output level")
                    .accessibilityValue(
                        Text(String(format: "%+0.1f dBFS", model.config.testToneLevelDB)))
                } label: {
                    Text(String(format: "%+0.1f dBFS", model.config.testToneLevelDB))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 96, alignment: .leading)
                }
                Text(
                    "Default -20 dBFS matches broadcast line-level reference. "
                    + "Tone enters the chain pre-AGC, so the input meter on "
                    + "the Monitoring tab will read the configured level "
                    + "(modulo the chain's response to the signal)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        Card(title: "Status") {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Source").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(isEnabled.wrappedValue ? "Tone (active)" : "Input (test tone disabled)")
                            .font(BroadcastStyle.valueReadout)
                            .foregroundStyle(isEnabled.wrappedValue ? BroadcastStyle.safeGreen : .primary)
                    }
                    GridRow {
                        Text("Type").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(typeBinding.wrappedValue.capitalized).font(BroadcastStyle.valueReadout)
                    }
                    GridRow {
                        Text("Mode").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(modeLabel(modeBinding.wrappedValue)).font(BroadcastStyle.valueReadout)
                    }
                    if typeBinding.wrappedValue == "sine" {
                        GridRow {
                            Text("Frequency").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(String(format: "%.1f Hz", model.config.testToneFreq))
                                .font(BroadcastStyle.valueReadout)
                                .monospacedDigit()
                        }
                    }
                    GridRow {
                        Text("Level").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(String(format: "%+0.1f dBFS", model.config.testToneLevelDB))
                            .font(BroadcastStyle.valueReadout)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func presetLabel(for freq: Double) -> String {
        if freq >= 1_000 {
            let kHz = freq / 1_000.0
            if kHz == kHz.rounded() {
                return "\(Int(kHz))k"
            } else {
                return String(format: "%.1fk", kHz)
            }
        }
        return "\(Int(freq))"
    }

    private func modeLabel(_ mode: String) -> String {
        switch mode {
        case "stereo": return "Stereo (L=-R)"
        case "left":   return "Left only"
        case "right":  return "Right only"
        default:       return "Mono"
        }
    }
}

private struct MonitoringDashboardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                transportPanel
                metricsPanels
                chainPanel
                // No RDS in processed-audio output (no subcarrier carries it).
                if !model.processedAudioOutputActive {
                    rdsPanel
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Three side-by-side cards with the live broadcast metrics
    /// (previously crammed into the persistent top status strip):
    /// MPX peak / deviation / modulation, headroom across the peak-
    /// control stages, and subcarrier injection levels. Card layout
    /// matches the rdsPanel grid pattern (uppercase secondary label
    /// in the left column, monospaced value on the right). Wraps to
    /// stacked layout on narrow windows via `ViewThatFits`.
    private var metricsPanels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                mpxPanel.frame(maxWidth: .infinity)
                headroomPanel.frame(maxWidth: .infinity)
                // Pilot/RDS injection is composite-only; in processed-audio the
                // panel would be all N/A, so omit it.
                if !model.processedAudioOutputActive {
                    subcarriersPanel.frame(maxWidth: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                mpxPanel
                headroomPanel
                if !model.processedAudioOutputActive {
                    subcarriersPanel
                }
            }
        }
    }

    private var mpxPanel: some View {
        // In processed-audio mode there is no composite: deviation / modulation /
        // audio-composite peak are all meaningless. Show the output level and the
        // (still-valid) stereo image instead.
        Card(title: model.processedAudioOutputActive ? "Output" : "MPX") {
            LiveObservationView(telemetry: model.telemetry) { _ in
                if model.processedAudioOutputActive {
                    metricsGrid([
                        ("OUTPUT", model.outputText.ifEmpty("—")),
                        ("STEREO IMAGE", model.stereoImageText)
                    ])
                } else {
                    metricsGrid([
                        ("OUTPUT", model.outputText.ifEmpty("—")),
                        ("AUDIO COMPOSITE", audioCompositeText),
                        ("DEVIATION", String(format: "%5.1f kHz", model.estimatedDeviationPeakKHz)),
                        ("MODULATION", modulationText)
                    ])
                }
            }
        }
    }

    private var headroomPanel: some View {
        // Composite clipper / safety limiter / BS.412 don't run in processed-audio
        // output — only the pre-encode limiter does.
        Card(title: "Headroom") {
            LiveObservationView(telemetry: model.telemetry) { _ in
                if model.processedAudioOutputActive {
                    metricsGrid([
                        ("PRE-ENCODE GR", grText(model.preEncodeLimiterGainReductionDBValue))
                    ])
                } else {
                    metricsGrid([
                        ("PRE-ENCODE GR", grText(model.preEncodeLimiterGainReductionDBValue)),
                        ("COMPOSITE GR", grText(model.compositeClipperGainReductionDBValue)),
                        ("SAFETY GR", grText(model.safetyLimiterGainReductionDBValue)),
                        ("BS.412 BUDGET", budgetText)
                    ])
                }
            }
        }
    }

    private var subcarriersPanel: some View {
        Card(title: "Subcarriers") {
            LiveObservationView(telemetry: model.telemetry) { _ in
                metricsGrid([
                    ("PILOT", String(format: "%5.1f%%", model.pilotInjectionPercentValue)),
                    ("RDS", String(format: "%5.1f%%", model.rdsInjectionPercentValue)),
                    ("STEREO IMAGE", model.stereoImageText)
                ])
            }
        }
    }

    private func metricsGrid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .font(BroadcastStyle.scaleLabel)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(row.1)
                        .font(BroadcastStyle.valueReadout)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Audio-composite peak in dBFS. Linear-to-dBFS with a -120 dBFS
    /// floor so the readout settles to a fixed string when silent
    /// rather than reading "-inf".
    private var audioCompositeText: String {
        let v = Double(model.audioCompositePeakLinear)
        guard v > 1e-6 else { return "-120.0 dBFS" }
        return String(format: "%6.1f dBFS", 20.0 * log10(v))
    }

    /// Modulation percentage: peak deviation as a fraction of the
    /// configured target. References `mpx_deviation_khz` from config
    /// (not the 75 kHz regulatory line) — operators with custom
    /// deviation targets read 100% at their chosen setpoint.
    private var modulationText: String {
        let peak = Double(model.estimatedDeviationPeakKHz)
        let target = max(1.0, model.config.mpxDeviationKHz)
        return String(format: "%6.1f%%", (peak / target) * 100.0)
    }

    /// Budget margin + state. ON shown in tail when BS.412 is engaged;
    /// otherwise the numeric value alone (so OFF reads "+0.0 dB" with
    /// no implication that BS.412 is active).
    private var budgetText: String {
        let margin = Double(model.compositeBudgetMarginDBValue)
        let state = model.compositeBudgetStateText
        let core = String(format: "%+5.1f dB", margin)
        return state.isEmpty || state == "Off" ? core : "\(core) · \(state)"
    }

    private func grText(_ valueDB: Float) -> String {
        // 5-char numeric field (covers " 0.0".."16.0", and "-NN.N") so the GR
        // readout stays a constant width as gain reduction varies.
        let db = Double(valueDB)
        return String(format: "%5.1f dB", db < 0.05 ? 0.0 : db)
    }

    // MARK: - Panel A: Transport + Devices

    private var transportPanel: some View {
        Card(title: "Transport") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        model.startOrStopTransport()
                    } label: {
                        HStack {
                            // Decorative — the adjacent "Start" / "Stop"
                            // text conveys the action to VoiceOver.
                            Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                                .accessibilityHidden(true)
                            Text(model.isRunning ? "Stop" : "Start")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .keyboardShortcut(.return, modifiers: [.command])

                    Button {
                        model.toggleBypass()
                    } label: {
                        HStack {
                            // Decorative — the adjacent "Bypass On / Off"
                            // text conveys the action to VoiceOver.
                            Image(systemName: model.processingBypass ? "bolt.slash.fill" : "bolt.fill")
                                .accessibilityHidden(true)
                            Text(model.processingBypass ? "Bypass On" : "Bypass Off")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                    .keyboardShortcut("b", modifiers: [.command])
                }

                FlowStatusRow(items: [
                    ("Source", inputName, model.isRunning ? .green : .secondary.opacity(0.75)),
                    ("Output", outputName, model.isRunning ? .green : .secondary.opacity(0.75)),
                    ("Monitor", monitorChipText, model.monitorEnabled ? .green : .secondary.opacity(0.75))
                ])

                // Input levels — visible here so the operator can
                // adjust source gain without leaving the dashboard.
                // Same data the BroadcastStatusBar shows numerically,
                // but rendered as proper L/R meter bars with peak hold.
                inputLevelsTile

                HStack(alignment: .top, spacing: 12) {
                    streamTile
                    bufferTile
                    dropoutsTile
                }
            }
        }
    }

    private var inputLevelsTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input")
                    .font(BroadcastStyle.chipLabel)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("Adjust source level so peaks sit between -6 and -3 dBFS")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            LiveObservationView(telemetry: model.telemetry) { t in
                VStack(alignment: .leading, spacing: 6) {
                    MeterRow(
                        label: "L",
                        valueText: t.inputLText.meterCurrentOnly,
                        level: t.inputLLevel,
                        peakLevel: t.inputLPeakHoldLevel,
                        scaleStyle: .dbfs
                    )
                    MeterRow(
                        label: "R",
                        valueText: t.inputRText.meterCurrentOnly,
                        level: t.inputRLevel,
                        peakLevel: t.inputRPeakHoldLevel,
                        scaleStyle: .dbfs
                    )
                }
            }
        }
        .padding(10)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
    }

    private var streamTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stream")
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            LiveObservationView(telemetry: model.telemetry) { _ in
                Text(streamRateText)
                    .font(BroadcastStyle.valueReadout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
    }

    private var bufferTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Buffer")
                    .font(BroadcastStyle.chipLabel)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                LiveObservationView(telemetry: model.telemetry) { _ in
                    Text(delayText)
                        .font(BroadcastStyle.valueReadout)
                        .foregroundStyle(.secondary)
                }
            }
            LiveObservationView(telemetry: model.telemetry) { _ in
                ProgressView(value: bufferFill)
                    .progressViewStyle(.linear)
                    .tint(bufferTint)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
    }

    private var dropoutsTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dropouts (10 s)")
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            LiveObservationView(telemetry: model.telemetry) { t in
                HStack(spacing: 12) {
                    dropoutPill(label: "OVR", count: t.streamHealth.overflowsRecent)
                    dropoutPill(label: "UND", count: t.streamHealth.underflowsRecent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        .help("Cumulative totals: \(model.streamHealth.overflowsTotal) overflows / \(model.streamHealth.underflowsTotal) underflows since engine start.")
    }

    private func dropoutPill(label: String, count: Int) -> some View {
        let tint: Color = count == 0
            ? BroadcastStyle.safeGreen
            : (count < 3 ? BroadcastStyle.tightAmber : BroadcastStyle.overRed)
        // Distinct symbol per state so the cue is shape + colour, not colour
        // alone (WCAG 2.1 / Differentiate-Without-Color).
        let symbol = count == 0
            ? "checkmark.circle.fill"
            : (count < 3 ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
        let state = count == 0 ? "ok" : (count < 3 ? "warning" : "error")
        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(label)
                .font(BroadcastStyle.scaleLabel)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(BroadcastStyle.valueReadout)
        }
        // Symbol + colour carry the state visually; mirror it in words for
        // VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(count), \(state)")
    }

    // MARK: - Panel B: DSP chain (3-pill context strip + 13-stage grid)

    private var chainPanel: some View {
        Card(title: "Signal Chain") {
            VStack(alignment: .leading, spacing: 12) {
                LiveObservationView(telemetry: model.telemetry) { _ in
                    FlowStatusRow(items: [
                        ("AGC", agcPillText, agcDotColor),
                        ("Stereo", stereoPillText, .secondary.opacity(0.75)),
                        ("Pre-Lim GR", preLimText, preLimDotColor)
                    ])
                }

                ProcessingOverviewGrid(model: model, embedded: true)
            }
        }
    }

    // MARK: - Panel C: RDS

    private var rdsPanel: some View {
        Card(title: "RDS") {
            LiveObservationView(telemetry: model.telemetry) { _ in
              VStack(alignment: .leading, spacing: 10) {
                FlowStatusRow(items: [
                    ("PS", model.rdsPS.ifEmpty("—"), .secondary.opacity(0.75)),
                    ("PI", model.rdsPI.ifEmpty("—"), .secondary.opacity(0.75)),
                    ("PTY", model.rdsPTY.ifEmpty("—"), .secondary.opacity(0.75))
                ])

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(rdsRowsFiltered, id: \.0) { row in
                        GridRow {
                            Text(row.0)
                                .font(BroadcastStyle.scaleLabel)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(row.1)
                                .font(BroadcastStyle.valueReadout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
              }
            }
        }
    }

    // MARK: - Computed values

    private var inputName: String {
        guard !model.selectedInputUID.isEmpty else { return "—" }
        return model.inputDevices.first(where: { $0.uid == model.selectedInputUID })?.name ?? "—"
    }

    private var outputName: String {
        guard !model.selectedOutputUID.isEmpty else { return "—" }
        return model.outputDevices.first(where: { $0.uid == model.selectedOutputUID })?.name ?? "—"
    }

    private var monitorName: String {
        guard model.monitorEnabled, !model.selectedMonitorUID.isEmpty else { return "—" }
        return model.outputDevices.first(where: { $0.uid == model.selectedMonitorUID })?.name ?? "—"
    }

    private var monitorChipText: String {
        if !model.monitorEnabled { return "Off" }
        return monitorName
    }

    private var streamRateText: String {
        let h = model.streamHealth
        if h.inputHz > 0, h.renderHz > 0, h.inputHz != h.renderHz {
            return "\(h.inputHz) → \(h.renderHz) Hz · block \(h.blockFrames)"
        }
        let effective = max(h.renderHz, h.inputHz)
        if effective > 0 {
            return "\(effective) Hz · block \(h.blockFrames)"
        }
        return "—"
    }

    private var bufferFill: Double {
        // Display the low-passed buffer fill (~10 s time constant) so
        // the bar shows trend rather than tick-by-tick wobble. The
        // underlying `streamHealth.ringFill` and `inputBufferValue`
        // still update at full rate for any caller that needs the
        // instantaneous reading; a real underflow surfaces in the
        // `Dropouts` tile within one tick.
        max(0.0, min(1.0, model.bufferFillSmoothed))
    }

    private var bufferTint: Color {
        guard model.streamHealth.isRunning else { return .secondary }
        switch model.streamHealth.bufferHealth {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }

    private var delayText: String {
        guard let delayMS = model.streamHealth.estimatedDelayMS else { return "—" }
        if delayMS >= 100.0 { return String(format: "%.0f ms", delayMS) }
        if delayMS >= 10.0 { return String(format: "%.1f ms", delayMS) }
        return String(format: "%.2f ms", delayMS)
    }

    private var agcPillText: String {
        // Detector + gain on one line, parsed from the existing
        // `agcDetailText` ("Detector X dB • Gain Y dB").
        let detector = parseDetail(model.agcDetailText, key: "Detector") ?? "—"
        let gain = parseDetail(model.agcDetailText, key: "Gain") ?? "—"
        return "\(detector) → \(gain)"
    }

    private var agcDotColor: Color {
        switch model.agcStateText.lowercased() {
        case "off": return .secondary.opacity(0.75)
        case "gate": return .orange
        default: return .green
        }
    }

    private var stereoPillText: String {
        // "Corr +X.XX • Side Y.YYx" from stereoImageText.
        let corr = parseDetail(model.stereoImageText, key: "Corr") ?? "—"
        let side = parseDetail(model.stereoImageText, key: "Side") ?? "—"
        return "\(corr) · \(side)"
    }

    private var preLimText: String {
        String(format: "%5.1f dB", Double(model.preEncodeLimiterGainReductionDBValue))
    }

    private var preLimDotColor: Color {
        let gr = Double(model.preEncodeLimiterGainReductionDBValue)
        if gr < 0.5 { return .green }
        if gr < 3.0 { return .orange }
        return .red
    }

    /// Drop empty / placeholder RDS rows so the table doesn't render
    /// "PTYN: —" or "Long PS: —" lines that just clutter the panel.
    private var rdsRowsFiltered: [(String, String)] {
        model.rdsRows.filter { _, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "—"
        }
    }

    /// Pull a single value out of a "Key1 V1 • Key2 V2" detail string.
    private func parseDetail(_ text: String, key: String) -> String? {
        let parts = text.split(separator: "•")
        for p in parts {
            let trimmed = p.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key) {
                return trimmed.replacingOccurrences(of: "\(key) ", with: "")
            }
        }
        return nil
    }
}

private struct DashboardMetricGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            content
        }
    }
}

private struct FlowStatusRow: View {
    let items: [(title: String, value: String, color: Color)]

    var body: some View {
        ViewThatFits(in: .vertical) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    DSPStatusPill(title: item.title, value: item.value, color: item.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    DSPStatusPill(title: item.title, value: item.value, color: item.color)
                }
            }
        }
    }
}

private struct DSPStatusPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            BroadcastStyle.ledHalo(for: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(BroadcastStyle.chipLabel)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(BroadcastStyle.chipValue)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BroadcastStyle.meterSurface.opacity(0.70))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        // Read as one item ("AGC, On") instead of LED + two text fragments.
        // The value text already states the status word, so it is not
        // color-only; this only fixes the fragmentation.
        .accessibilityElement(children: .combine)
    }
}

private struct DSPMetricGroupCard: View {
    let title: String
    let subtitle: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        Text(rows[i].0)
                            .font(BroadcastStyle.scaleLabel)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(rows[i].1)
                            .font(BroadcastStyle.valueReadout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
    }
}

private struct DSPStateIndicator: View {
    let title: String
    let dotColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("\(title):")
                .foregroundStyle(.secondary)
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
    }
}

private struct RuntimeCardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Runtime") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("State") {
                    Text(model.isRunning ? "Running" : "Not running")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Source") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.sourceMode },
                            set: {
                                model.sourceMode = $0
                                model.persistBasicConfig()
                            }
                        )
                    ) {
                        Text("input").tag("input")
                        Text("tone").tag("tone")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                LabeledContent("Input") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.selectedInputUID },
                            set: {
                                model.selectedInputUID = $0
                                model.persistBasicConfig()
                            }
                        )
                    ) {
                        ForEach(model.inputDevices, id: \.uid) { d in
                            Text(d.name).tag(d.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                LabeledContent("Output") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.selectedOutputUID },
                            set: {
                                model.selectedOutputUID = $0
                                model.persistBasicConfig()
                            }
                        )
                    ) {
                        ForEach(model.outputDevices, id: \.uid) { d in
                            Text(d.name).tag(d.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Toggle(
                    "Enable Monitor Output",
                    isOn: Binding(
                        get: { model.monitorEnabled },
                        set: {
                            model.monitorEnabled = $0
                            model.persistBasicConfig()
                        }
                    ))

                if model.monitorEnabled {
                    LabeledContent("Monitor Output Device (Decoded MPX Simulation)") {
                        Picker(
                            "",
                            selection: Binding(
                                get: { model.selectedMonitorUID },
                                set: {
                                    model.selectedMonitorUID = $0
                                    model.persistBasicConfig()
                                }
                            )
                        ) {
                            ForEach(model.outputDevices, id: \.uid) { d in
                                Text(d.name).tag(d.uid)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityLabel("Monitor output device decoded MPX simulation")
                    }
                }

                Divider()
                LiveObservationView(telemetry: model.telemetry) { _ in
                    Text(model.runtimeText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LiveObservationView(telemetry: model.telemetry) { _ in
                    ProgressView(value: model.inputBufferValue, total: max(1.0, model.inputBufferMax))
                        .tint(
                            model.inputBufferValue >= model.inputBufferCritical
                                ? .red
                                : (model.inputBufferValue >= model.inputBufferWarning
                                    ? .yellow : .green))
                }
                LiveObservationView(telemetry: model.telemetry) { _ in
                    Text(model.inputRingText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.regular)
        }
    }
}

/// Terminal-style monospaced plate showing what's actually going out on
/// the air right now — PS window, Radiotext, PTYN, Long PS, plus the PI
/// / PTY / AID chips. Reads from `model.rdsRows`, which is sourced from
/// the running coder's live snapshot via `updateRDSFields`.
private struct RDSLivePreviewPlate: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.rdsRows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0.uppercased())
                        .font(BroadcastStyle.chipLabel)
                        .foregroundStyle(.secondary)
                        .frame(width: 68, alignment: .leading)
                    Text(row.1)
                        .font(BroadcastStyle.valueReadout)
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(BroadcastStyle.panelSurface.opacity(0.70))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
    }
}

struct LevelsCardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Levels", style: .meter) {
            LiveObservationView(telemetry: model.telemetry) { _ in
              HStack(alignment: .center, spacing: 12) {
                VerticalMeterStrip(
                    label: "IN L",
                    valueText: model.inputLText.meterCurrentOnly,
                    level: model.inputLLevel,
                    peakLevel: model.inputLPeakHoldLevel,
                    scale: .dbfs
                )
                VerticalMeterStrip(
                    label: "IN R",
                    valueText: model.inputRText.meterCurrentOnly,
                    level: model.inputRLevel,
                    peakLevel: model.inputRPeakHoldLevel,
                    scale: .dbfs
                )
                VerticalMeterStrip(
                    label: "AGC L",
                    valueText: model.agcOutputLText.meterCurrentOnly,
                    level: model.agcOutputLLevel,
                    peakLevel: model.agcOutputLPeakHoldLevel,
                    scale: .dbfs
                )
                VerticalMeterStrip(
                    label: "AGC R",
                    valueText: model.agcOutputRText.meterCurrentOnly,
                    level: model.agcOutputRLevel,
                    peakLevel: model.agcOutputRPeakHoldLevel,
                    scale: .dbfs
                )
                VerticalMeterStrip(
                    label: model.processedAudioOutputActive ? "OUT" : "MPX",
                    valueText: model.outputText.meterCurrentOnly,
                    level: model.outputLevel,
                    peakLevel: model.outputPeakHoldLevel,
                    scale: .dbfs
                )
                // Modulation/deviation is a composite-domain quantity. In
                // processed-audio output there is no FM composite, so the MOD
                // (kHz deviation) meter is meaningless — hide it.
                if !model.processedAudioOutputActive {
                    VerticalMeterStrip(
                        label: "MOD",
                        valueText: model.modulationText,
                        level: model.modulationLevel,
                        peakLevel: model.modulationPeakHoldLevel,
                        scale: .modulationKHz(fullScale: 100, limit: model.config.mpxDeviationKHz)
                    )
                }
                // GR + SAFE removed in 0.30 — peak-control gain-reduction
                // data is already surfaced by the Monitoring tab's Headroom
                // card (PRE-ENCODE / COMPOSITE / SAFETY GR + BS.412 budget)
                // and per-stage in the Signal Chain strip. The detached
                // Levels window is now purely VU-style level metering.
                Spacer(minLength: 0)
              }
              .frame(height: 340)
              // Group the strips under one named VoiceOver container so the
              // cluster is announced as a unit ("Level meters, …") and the
              // user can navigate into the individual strips for readings,
              // instead of landing on disconnected strips with no context.
              .accessibilityElement(children: .contain)
              .accessibilityLabel(
                model.processedAudioOutputActive
                    ? "Level meters: input L and R, AGC output L and R, output"
                    : "Level meters: input L and R, AGC output L and R, MPX output, modulation")
            }
        }
    }
}

private struct MeterRow: View {
    enum ScaleStyle: Equatable {
        case dbfs
        case modulation100kHz(limitKHz: Double)
        case none
    }

    let label: String
    let valueText: String
    let level: Double
    let peakLevel: Double?
    let scaleStyle: ScaleStyle

    init(
        label: String, valueText: String, level: Double, peakLevel: Double? = nil,
        showsDBScale: Bool = false,
        scaleStyle: ScaleStyle? = nil
    ) {
        self.label = label
        self.valueText = valueText
        self.level = level
        self.peakLevel = peakLevel
        if let scaleStyle {
            self.scaleStyle = scaleStyle
        } else {
            self.scaleStyle = showsDBScale ? .dbfs : .none
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    // Fixed footprint so a per-tick value change (e.g.
                    // "-6.2 dB" -> "-12.4 dB") repaints in place instead of
                    // resizing and re-solving the enclosing stack layout.
                    .frame(width: 68, alignment: .trailing)
            }
            MeterBar(level: level, peakLevel: peakLevel, scaleStyle: scaleStyle)
        }
        .font(.callout)
        // Collapse the label / readout / bar into one VoiceOver element so it
        // announces "<name>, <value>" rather than two stray text fragments
        // with a meaningless bar in between.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
    }
}

private struct MeterBar: View {
    let level: Double
    let peakLevel: Double?
    let scaleStyle: MeterRow.ScaleStyle

    private struct ScaleTick: Identifiable {
        let position: Double
        let label: String

        var id: String { "\(label)-\(position)" }
    }

    private static func dbfsScalePosition(_ db: Double) -> Double {
        let floorDB = -36.0
        let clampedDB = min(0.0, max(floorDB, db))
        let norm = max(0.0, min(1.0, (clampedDB - floorDB) / -floorDB))
        return norm
    }

    private var scaleTicks: [ScaleTick] {
        switch scaleStyle {
        case .dbfs:
            return [
                ScaleTick(position: Self.dbfsScalePosition(-36.0), label: "-36"),
                ScaleTick(position: Self.dbfsScalePosition(-24.0), label: "-24"),
                ScaleTick(position: Self.dbfsScalePosition(-12.0), label: "-12"),
                ScaleTick(position: Self.dbfsScalePosition(-6.0), label: "-6"),
                ScaleTick(position: Self.dbfsScalePosition(-3.0), label: "-3"),
                ScaleTick(position: Self.dbfsScalePosition(0.0), label: "0 dBFS")
            ]
        case .modulation100kHz:
            return [
                ScaleTick(position: 0.0, label: "0"),
                ScaleTick(position: 0.25, label: "25"),
                ScaleTick(position: 0.5, label: "50"),
                ScaleTick(position: 0.75, label: "75"),
                ScaleTick(position: 1.0, label: "100 kHz")
            ]
        case .none:
            return []
        }
    }

    private var meterTint: Color {
        switch scaleStyle {
        case .modulation100kHz(let limitKHz):
            return BroadcastStyle.tint(forLevel: level, limitNorm: limitKHz / 100.0)
        case .dbfs, .none:
            return BroadcastStyle.tint(forLevel: level)
        }
    }

    private var targetLevel: Double? {
        switch scaleStyle {
        case .modulation100kHz(let limitKHz):
            return max(0.0, min(1.0, limitKHz / 100.0))
        case .dbfs, .none:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Drawn in a Canvas, not laid-out subviews: the fill width / peak / target
            // change every frame, and a `.frame(width:)` tracking the level would
            // re-run Auto Layout on every update at the refresh rate (the cause of the
            // long-run GUI stall). A Canvas just repaints.
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let radius: CGFloat = 3
                let track = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                                 cornerRadius: radius, style: .continuous)
                ctx.fill(track, with: .color(Color.secondary.opacity(0.18)))
                for tick in scaleTicks {
                    let x = tick.position * w
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)),
                             with: .color(Color.primary.opacity(0.15)))
                }
                let fw = max(0.0, min(1.0, level)) * w
                if fw > 0.5 {
                    ctx.fill(
                        Path(roundedRect: CGRect(x: 0, y: 0, width: fw, height: h),
                             cornerRadius: radius, style: .continuous),
                        with: .color(meterTint.opacity(0.75)))
                }
                if let target = targetLevel {
                    let x = min(max(0.0, (max(0.0, min(1.0, target)) * w) - 1.0), max(0.0, w - 2.0))
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: h)),
                             with: .color(Color.accentColor.opacity(0.95)))
                }
                if let peak = peakLevel {
                    let x = min(max(0.0, (max(0.0, min(1.0, peak)) * w) - 1.0), max(0.0, w - 2.0))
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: h)),
                             with: .color(Color.primary.opacity(0.98)))
                }
            }
            .frame(height: 14)
            if scaleStyle != .none {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        ForEach(scaleTicks) { tick in
                            Text(tick.label)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .position(
                                    x: min(
                                        max(12.0, tick.position * geo.size.width),
                                        max(12.0, geo.size.width - 24.0)
                                    ),
                                    y: 7.0
                                )
                        }
                    }
                }
                .frame(height: 14)
            }
        }
        .transaction { txn in
            txn.animation = nil
        }
    }
}

private struct MonitoringWindowHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bar-style 1/3-octave RTA visualization. Used for the Audio Spectrum
/// window — more representative of how pro broadcast processors
/// (Optimod / Omnia / Stereotool) show audio program spectrum than a
/// line/area FFT plot. Same underlying `dbBins` source as
/// `MPXSpectrumView`; this view just remaps to ISO 1/3-octave bands and
/// renders each as a gradient-filled bar.
struct AudioBarSpectrumView: View {
    let dbBins: [Float]
    let maxHz: Double
    let nyquistHz: Double

    private let dbMin: Float = -100.0
    private let dbMax: Float = 0.0

    /// ISO 1/3-octave center frequencies (Hz). Covers the FM audio
    /// program band; bands above the actual display Nyquist are filtered
    /// out at render time.
    private static let isoCenters: [Double] = [
        31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250,
        315, 400, 500, 630, 800, 1_000, 1_250, 1_600, 2_000, 2_500,
        3_150, 4_000, 5_000, 6_300, 8_000, 10_000, 12_500, 16_000
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius),
                    with: .color(.black.opacity(0.30))
                )
                let leftAxisWidth: CGFloat = 42
                let rightAxisWidth: CGFloat = 42
                let topInset: CGFloat = 8
                let bottomInset: CGFloat = 20
                let plotRect = CGRect(
                    x: leftAxisWidth,
                    y: topInset,
                    width: max(10, size.width - leftAxisWidth - rightAxisWidth),
                    height: max(10, size.height - topInset - bottomInset)
                )

                // dB grid + border.
                var grid = Path()
                for db in stride(from: -100, through: 0, by: 10) {
                    let y = yPosition(forDB: Float(db), in: plotRect)
                    grid.move(to: CGPoint(x: plotRect.minX, y: y))
                    grid.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.18)), lineWidth: 0.9)
                context.stroke(
                    Path(plotRect),
                    with: .color(.white.opacity(0.40)),
                    lineWidth: 1.0
                )

                // dB axis labels (both sides).
                for db in stride(from: -100, through: 0, by: 10) {
                    let y = yPosition(forDB: Float(db), in: plotRect)
                    let label = db == 0 ? "0 dB" : "\(db) dB"
                    let text = Text(label)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                    context.draw(text, at: CGPoint(x: 18, y: y))
                    context.draw(text, at: CGPoint(x: size.width - 18, y: y))
                }

                // Filter ISO bands by display Nyquist so we don't draw
                // bars whose center is beyond the actual analyzed range.
                // Inclusive comparison: a 16 kHz band at exactly maxHz
                // still shows — the upper half of its 1/3-octave window
                // extends past maxHz but its lower half (14.25-16 kHz)
                // has valid FFT data and the bar reflects that energy.
                let displayMaxHz = max(1_000.0, maxHz)
                let nyquist = nyquistHz > 0 ? min(nyquistHz, displayMaxHz) : displayMaxHz
                let usableCenters = Self.isoCenters.filter { $0 <= nyquist }
                guard !usableCenters.isEmpty, dbBins.count > 1 else { return }

                let barCount = usableCenters.count
                let interBarGap: CGFloat = max(1.0, plotRect.width * 0.004)
                let barWidth = max(
                    2.0,
                    (plotRect.width - interBarGap * CGFloat(barCount - 1)) / CGFloat(barCount)
                )

                // For each ISO band, pull max of FFT bins falling in
                // [center * 2^(-1/6), center * 2^(1/6)] — standard
                // 1/3-octave window.
                let binCount = dbBins.count
                let oneSixthOctave = pow(2.0, 1.0 / 6.0)

                let gradient = Gradient(colors: [
                    Color.red.opacity(0.88),
                    Color.yellow.opacity(0.80),
                    Color.green.opacity(0.74),
                    Color.cyan.opacity(0.62),
                    Color.blue.opacity(0.55)
                ])

                for (i, center) in usableCenters.enumerated() {
                    let lowHz = center / oneSixthOctave
                    let highHz = center * oneSixthOctave
                    let lowBin = max(
                        0,
                        min(binCount - 1, Int((lowHz / displayMaxHz) * Double(binCount - 1)))
                    )
                    let highBin = max(
                        lowBin,
                        min(
                            binCount - 1,
                            Int(ceil((highHz / displayMaxHz) * Double(binCount - 1)))
                        )
                    )
                    var maxDB: Float = -100.0
                    for b in lowBin...highBin where dbBins[b] > maxDB {
                        maxDB = dbBins[b]
                    }
                    // Floor for visual readability — a 1-pixel sliver at
                    // -100 is invisible; cap at -98 so very-quiet bands
                    // still show a faint base.
                    maxDB = max(-98.0, maxDB)

                    let xLeft = plotRect.minX + CGFloat(i) * (barWidth + interBarGap)
                    let yTop = yPosition(forDB: maxDB, in: plotRect)
                    let barRect = CGRect(
                        x: xLeft,
                        y: yTop,
                        width: barWidth,
                        height: max(0, plotRect.maxY - yTop)
                    )
                    context.fill(
                        Path(
                            roundedRect: barRect,
                            cornerRadius: max(1.0, min(3.5, barWidth * 0.18))
                        ),
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: barRect.midX, y: plotRect.minY),
                            endPoint: CGPoint(x: barRect.midX, y: plotRect.maxY)
                        )
                    )
                }

                // Decade labels along the X-axis at 100 Hz, 1 kHz, 10 kHz,
                // plus a 16 kHz marker at the audio-program ceiling.
                let decadeLabels: [(Double, String)] = [
                    (100, "100 Hz"),
                    (1_000, "1 kHz"),
                    (10_000, "10 kHz"),
                    (16_000, "16 kHz")
                ]
                for (decadeHz, label) in decadeLabels where decadeHz <= nyquist {
                    if let idx = usableCenters.firstIndex(where: { abs($0 - decadeHz) < 0.5 }) {
                        let xCenter =
                            plotRect.minX
                            + CGFloat(idx) * (barWidth + interBarGap)
                            + barWidth * 0.5
                        let text = Text(label)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                        context.draw(text, at: CGPoint(x: xCenter, y: plotRect.maxY + 12))
                    }
                }
            }
            .frame(minHeight: 190, idealHeight: 220)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: BroadcastStyle.panelInsetCornerRadius,
                    style: .continuous
                )
            )

            HStack(spacing: 14) {
                Text("RTA: 1/3-octave (ISO) bars, log frequency, max in band")
                Spacer()
                if nyquistHz > 0.0, nyquistHz < maxHz {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: 6, height: 6)
                        Text("Nyquist \(Int((nyquistHz / 1000.0).rounded())) kHz")
                    }
                }
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
        }
        // Discrete updates — no implicit interpolation between frames
        // (matches the line spectrum's transaction modifier; prevents
        // animation queue buildup at 30 Hz refresh).
        .transaction { txn in
            txn.animation = nil
        }
        // Canvas content is invisible to VoiceOver; name the region.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio spectrum, one-third octave RTA")
        .accessibilityAddTraits(.isImage)
    }

    private func yPosition(forDB db: Float, in rect: CGRect) -> CGFloat {
        let clamped = max(dbMin, min(dbMax, db))
        let norm = (clamped - dbMin) / (dbMax - dbMin)
        return rect.minY + (1.0 - CGFloat(norm)) * rect.height
    }
}

private struct KeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0)
                        .foregroundStyle(.secondary)
                    Text(rows[i].1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.callout)
    }
}

/// One-paragraph help block shown at the top of each Processing detail
/// tab (everything except the Overview grid). Intentionally muted /
/// secondary styling so it reads as documentation rather than a control;
/// stays out of the way once the operator knows the stage but is there
/// when they need to anchor.
private struct TabHelpBox: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Decorative info-icon — the Text alongside it carries the
            // entire content to VoiceOver. Hide the icon from the
            // accessibility tree so screen readers don't announce
            // "info circle" before every tab help block.
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }
}

/// Dedicated tab hosting the top-level Station Format picker. Moved out
/// of the Processing → Overview grid so the grid stays focused on per-
/// stage status; the format selector gets its own breathing room and
/// can show the full per-profile summary plus the standard tab help
/// box without crowding the dashboard.
private struct ProcessingFormatProfileTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Station Format") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Profile")
                        .foregroundStyle(.secondary)
                    Picker("Station Format", selection: model.formatProfileBinding()) {
                        ForEach(MPXPrimeViewModel.formatProfiles) { profile in
                            Text(profile.title).tag(profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Spacer()
                }
                Text(model.currentFormatProfileSummary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProcessingCoreTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Card(title: "Core Processing") {
            Toggle("Bypass Processing", isOn: Binding(
                get: { model.processingBypass },
                set: { _ in model.toggleBypass() }
            ))
            Toggle("Mono Mode", isOn: model.configBinding(\.monoMode))
            Text(model.processedAudioOutputActive
                ? "Mono Mode sums L+R to mono. The full DSP chain still runs; the processed output is identical on both channels."
                : "Mono Mode transmits true mono composite. The full DSP chain (AGC, multiband, clippers, limiters) still runs; only the 19 kHz pilot, 38 kHz stereo subcarrier, and RDS are suppressed at composite assembly.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Pre-emphasis", selection: model.configBinding(\.preemphasisUS)) {
                Text("Off").tag(0)
                Text("50 us").tag(50)
                Text("75 us").tag(75)
            }
            .pickerStyle(.segmented)
            DoubleSliderRow(title: "Input Gain", value: Binding(
                get: { model.inputGainDB },
                set: {
                    model.setInputGainLive($0)
                }
            ), range: -24...24, format: "%.1f dB",
            tooltip: "Pre-chain trim on the L/R input. Use to land your typical source peaks around -6 to -3 dBFS on the input meters. NOT the loudness knob — use AGC target + final drive + composite clipper drive for that.")
            DoubleSliderRow(
                title: model.processedAudioOutputActive ? "Output Level" : "MPX Output Level",
                value: model.configBinding(\.outputGainDB, runtimeDisposition: .live),
                range: -18...18,
                format: "%.1f dB",
                tooltip: model.processedAudioOutputActive
                    ? "Output level trim for the processed stereo L/R feed. The pre-encode limiter ceiling is normalized to ~0 dBFS at 0 dB; lower it to match your external coder's input reference, raise it for a hotter feed."
                    : "Final post-chain gain trim on the composite output before the audio device. Use for calibration into the exciter's MPX input — set so the exciter's deviation meter reads the licensed peak. Doesn't add loudness; the chain already drives the composite to 100% modulation."
            )
            Text(model.processedAudioOutputActive
                ? "Output Level sets the processed stereo line level into your external coder."
                : "Use MPX Output Level for final transmit/output calibration. Do not use AGC target as the main loudness knob.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DoubleSliderRow(title: "HPF", value: model.configBinding(\.hpfHz), range: 10...180, format: "%.0f Hz",
                tooltip: "High-pass filter cutoff on the L/R input. Removes DC, rumble, and very-low-end energy that would otherwise eat headroom downstream. 30 Hz is the ITU-R BS.450 audio-bandwidth lower bound; raise to 50-80 Hz for ground-loop or rumble-heavy sources.")
            DoubleSliderRow(title: "HF Trim", value: model.configBinding(\.hfTrimDB), range: -12...12, format: "%.1f dB",
                tooltip: "Pre-multiband shelf cut/boost at HF Trim Freq. Negative values tame harsh sources before they hit the multiband; positive values brighten dull material. Apply sparingly — global tonal shaping is the Parametric EQ stage's job.")
            DoubleSliderRow(title: "HF Trim Freq", value: model.configBinding(\.hfTrimHz), range: 1_000...12_000, format: "%.0f Hz",
                tooltip: "Centre frequency for the HF Trim shelf above. 4 kHz default targets vocal presence and cymbal sheen.")
            DoubleSliderRow(title: "Program Lowpass", value: model.configBinding(\.programLowpassHz), range: 8_000...16_000, format: "%.0f Hz",
                tooltip: model.processedAudioOutputActive
                    ? "Audio-bandwidth lowpass on the L/R output. ITU-R BS.450 specifies 30 Hz - 15 kHz for FM; 16 kHz default. This band-limits the feed to your external coder. Lower for narrower bandwidth (talk)."
                    : "Audio-bandwidth lowpass applied before stereo encoding. ITU-R BS.450 specifies 30 Hz - 15 kHz for FM stereo; 16 kHz default leaves room for the encoder FIR rolloff into the 17-19 kHz pilot guard. Lower for narrower bandwidth (talk, AM-style), higher only if your modulator FIR can cope.")
        }
        Card(title: "Engine — Filters") {
            Toggle("Encoder Lowpass: linear-phase FIR", isOn: model.configBinding(\.encoderFIREnabled))
                .help("Audio-bandwidth (15 kHz) lowpass. On (default): Kaiser-windowed linear-phase FIR, >80 dB stop-band, ~1.67 ms latency at 192 kHz. Off: 12th-order Butterworth cascade, ~0.2 ms latency, ~40 dB stop-band. Monitor mode always uses Butterworth. Restart-required.")
            Toggle("Multiband Crossovers: linear-phase FIR", isOn: model.configBinding(\.multibandFIREnabled))
                .help("Multiband splitters. On (default): Kaiser-windowed FIR splitters, sum-to-flat at -155 dB, all bands share group delay (no transient smear / inter-band pumping), ~5.3 ms latency at 192 kHz. Off: IIR Linkwitz-Riley 4th-order cascade, low latency but with the IIR-LR4 phase artefacts. Monitor mode always uses LR4. Restart-required.")
            Text(model.processedAudioOutputActive
                ? "Both filters apply to the processed L/R output (the encoder lowpass is the 15 kHz band-limit). Restart engine to apply."
                : "Both toggles affect the transmit (composite) path. Restart engine to apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
      }
    }
}

private struct ProcessingAGCTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Wideband AGC") {
            Toggle("Enable Wideband AGC", isOn: model.configBinding(\.widebandAGCEnabled, runtimeDisposition: .live))
            DoubleSliderRow(title: "Platform Target", value: model.configBinding(\.widebandAGCTargetDB, runtimeDisposition: .live), range: -36 ... -6, format: "%.1f dB",
                tooltip: "Target average level the AGC drives toward. Lower = more gain reduction on loud program; higher = less AGC action. Not the final loudness target.")
            DoubleSliderRow(title: "Attack", value: model.configBinding(\.widebandAGCAttackMS, runtimeDisposition: .live), range: 1...150, format: "%.1f ms",
                tooltip: "How quickly the AGC pulls gain down when the signal exceeds the target. Faster = tighter control but more pumping on transients.")
            DoubleSliderRow(title: "Release", value: model.configBinding(\.widebandAGCReleaseMS, runtimeDisposition: .live), range: 40...5000, format: "%.1f ms",
                tooltip: "How quickly the AGC restores gain when the signal drops below target. Slower = smoother, less noise pumping during quiet passages. Range extended to 5 s for true platform-leveling.")
            DoubleSliderRow(title: "Max Gain", value: model.configBinding(\.widebandAGCMaxGainDB, runtimeDisposition: .live), range: 0...24, format: "%.1f dB",
                tooltip: "Upper limit on how much gain the AGC will add to quiet material. Too high lifts noise and hiss during silences.")
            DoubleSliderRow(title: "Min Gain", value: model.configBinding(\.widebandAGCMinGainDB, runtimeDisposition: .live), range: -24...0, format: "%.1f dB",
                tooltip: "Lower limit on how much the AGC will attenuate loud material before downstream stages take over.")
            Toggle("K-Weighted Detector", isOn: model.configBinding(\.widebandAGCKWeightingEnabled, runtimeDisposition: .live))
                .help("BS.1770-flavoured pre-filter on the detector sidechain (HPF ~38 Hz + high-shelf +4 dB @ ~1.5 kHz). Tracks perceived loudness instead of flat RMS — bass rumble no longer pulls the AGC down unfairly; bright content reads hotter. Audio path is untouched. Default on.")
            Toggle("Program-Dependent Release", isOn: model.configBinding(\.widebandAGCReleaseProgramDependent, runtimeDisposition: .live))
                .help("Slow release up to 3x on busy program (dense voice, music with many transients), speed back to the configured rate on flat program. Reduces pumping without forcing slow defaults. Default on.")
            Toggle("Bass-Desensitised Sidechain", isOn: model.configBinding(\.widebandAGCBassDesensitizeEnabled, runtimeDisposition: .live))
                .help("Low-shelf-cuts the LF band out of the detector sidechain so a kick / heavy bass line can't drive the loudness reading and pump the whole chain (US 4,249,042 + US 3,790,896: also recovers fast from brief reductions). Audio path is untouched. Trade-off: very bass-heavy program reads quieter, so the AGC adds more gain. Default off.")
            Text("Wideband AGC should establish a stable average level platform. It is not the final loudness stage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProcessingPrimeBassTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "PrimeBass") {
            Picker("Preset", selection: Binding(
                get: { self.model.config.primeBassPresetID },
                set: { newValue in
                    self.model.config.primeBassPresetID = newValue
                    self.model.applyPrimeBassPreset(id: newValue)
                }
            )) {
                ForEach(model.primeBassPresetChoices) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            Toggle("Enable PrimeBass", isOn: model.configBinding(\.primeBassEnabled, runtimeDisposition: .live))
            DoubleSliderRow(title: "Amount", value: model.configBinding(\.primeBassAmount, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Overall strength of the low-band enhancement. Higher values emphasize bass; too high introduces pumping and obvious low-frequency coloration.")
            DoubleSliderRow(title: "Frequency", value: model.configBinding(\.primeBassFreqHz, runtimeDisposition: .live), range: 40...180, format: "%.1f Hz",
                tooltip: "Corner frequency of the low-band enhancement. Lower frequencies emphasize sub-bass, higher frequencies emphasize upper bass.")
            DoubleSliderRow(title: "Harmonics", value: model.configBinding(\.primeBassHarmonics, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Adds restrained harmonic overtones so bass remains audible on small speakers that can't reproduce the fundamental.")
            DoubleSliderRow(title: "Drive", value: model.configBinding(\.primeBassDrive, runtimeDisposition: .live), range: 0.2...2.0, format: "%.2f",
                tooltip: "Input level into the nonlinear enhancement stage. Higher drive increases harmonics intensity and perceived density.")
            DoubleSliderRow(title: "Density", value: model.configBinding(\.primeBassDensity, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Smoothing of the enhancement envelope. Higher density reduces attack transients in the low band for a more sustained feel.")
            Toggle("Enable Subharmonics", isOn: model.configBinding(\.primeBassSubharmonicsEnabled, runtimeDisposition: .live))
            DoubleSliderRow(title: "Subharmonics", value: model.configBinding(\.primeBassSubharmonicsAmount, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Synthesizes an octave-below reinforcement for fundamentals. Use sparingly — easily over-emphasizes sub-40 Hz content.")
                .disabled(!model.config.primeBassSubharmonicsEnabled)
        }
    }
}

private struct ProcessingMultibandTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Multiband Dynamics") {
            // Preset / intensity / enable / mode — common to all bands.
            Picker("Preset", selection: Binding(
                get: { self.model.config.multibandPresetID },
                set: { newValue in
                    let intensity = MultibandPresetIntensity(rawValue: self.model.config.multibandIntensity) ?? .normal
                    self.model.config.multibandPresetID = newValue
                    self.model.applyMultibandPreset(id: newValue, intensity: intensity)
                }
            )) {
                ForEach(model.multibandPresetChoices) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            Picker("Intensity", selection: Binding(
                get: { MultibandPresetIntensity(rawValue: self.model.config.multibandIntensity) ?? .normal },
                set: { newValue in
                    self.model.config.multibandIntensity = newValue.rawValue
                    self.model.applyMultibandPreset(id: self.model.config.multibandPresetID, intensity: newValue)
                }
            )) {
                ForEach(MultibandPresetIntensity.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Enable Multiband", isOn: model.configBinding(\.multibandEnabled, runtimeDisposition: .live))
            Picker("Mode", selection: model.configBinding(\.multibandMode, runtimeDisposition: .live)) {
                Text("2-band").tag(2)
                Text("3-band").tag(3)
                Text("5-band").tag(5)
            }

            Divider().padding(.vertical, 6)

            // Per-band detail editor — replaces the previous 12-slider
            // Low/Mid/High wall with an active-band picker that
            // re-targets a single set of controls. Visible widget count
            // drops from 12 to 4 (plus the picker). The non-active
            // bands' values aren't lost — switching the picker just
            // re-binds the controls.
            Picker("Active Band", selection: $model.activeMultibandBand) {
                Text("Low").tag(0)
                Text("Mid").tag(1)
                Text("High").tag(2)
            }
            .pickerStyle(.segmented)

            switch model.activeMultibandBand {
            case 0:
                DoubleSliderRow(title: "Threshold", value: model.configBinding(\.multibandLowThresholdDB, runtimeDisposition: .live), range: (-40)...(-6), format: "%.1f dB",
                    tooltip: "Low band compression threshold. Material above this level is attenuated by the ratio.")
                DoubleSliderRow(title: "Ratio", value: model.configBinding(\.multibandLowRatio, runtimeDisposition: .live), range: 1...8, format: "%.2f",
                    tooltip: "Low band compression ratio. 1:1 = no compression; higher ratios flatten dynamics more aggressively.")
                DoubleSliderRow(title: "Attack", value: model.configBinding(\.multibandLowAttackMS, runtimeDisposition: .live), range: 1...120, format: "%.1f ms",
                    tooltip: "Low band attack time. Slow attacks preserve transients; fast attacks tighten the low end.")
                DoubleSliderRow(title: "Release", value: model.configBinding(\.multibandLowReleaseMS, runtimeDisposition: .live), range: 40...1200, format: "%.0f ms",
                    tooltip: "Low band release time. Longer release prevents bass pumping at the cost of average-level recovery speed.")
            case 2:
                DoubleSliderRow(title: "Threshold", value: model.configBinding(\.multibandHighThresholdDB, runtimeDisposition: .live), range: (-40)...(-6), format: "%.1f dB",
                    tooltip: "High band compression threshold. Material above this level is attenuated by the ratio.")
                DoubleSliderRow(title: "Ratio", value: model.configBinding(\.multibandHighRatio, runtimeDisposition: .live), range: 1...8, format: "%.2f",
                    tooltip: "High band compression ratio. Controls sibilance and cymbal energy.")
                DoubleSliderRow(title: "Attack", value: model.configBinding(\.multibandHighAttackMS, runtimeDisposition: .live), range: 1...120, format: "%.1f ms",
                    tooltip: "High band attack time. Fast attack tames sibilance; slow attack preserves air.")
                DoubleSliderRow(title: "Release", value: model.configBinding(\.multibandHighReleaseMS, runtimeDisposition: .live), range: 40...1200, format: "%.0f ms",
                    tooltip: "High band release time. Shorter release brightens; longer release keeps the top smooth.")
            default:
                DoubleSliderRow(title: "Threshold", value: model.configBinding(\.multibandMidThresholdDB, runtimeDisposition: .live), range: (-40)...(-6), format: "%.1f dB",
                    tooltip: "Mid band compression threshold. Material above this level is attenuated by the ratio.")
                DoubleSliderRow(title: "Ratio", value: model.configBinding(\.multibandMidRatio, runtimeDisposition: .live), range: 1...8, format: "%.2f",
                    tooltip: "Mid band compression ratio. Vocals and leads live here — moderate values (2:1 - 4:1) are typical.")
                DoubleSliderRow(title: "Attack", value: model.configBinding(\.multibandMidAttackMS, runtimeDisposition: .live), range: 1...120, format: "%.1f ms",
                    tooltip: "Mid band attack time. Slower values preserve vocal consonants; faster values increase density.")
                DoubleSliderRow(title: "Release", value: model.configBinding(\.multibandMidReleaseMS, runtimeDisposition: .live), range: 40...1200, format: "%.0f ms",
                    tooltip: "Mid band release time. Typical vocal release; shorter = more density, longer = more transparent.")
            }

            Divider().padding(.vertical, 6)

            // Output / common — apply across all bands.
            DoubleSliderRow(title: "Makeup", value: model.configBinding(\.multibandMakeupDB, runtimeDisposition: .live), range: -12...18, format: "%.1f dB",
                tooltip: "Overall gain applied after multiband processing. Set to offset average level loss from compression; not a loudness control.")
            DoubleSliderRow(title: "Knee", value: model.configBinding(\.multibandKneeDB, runtimeDisposition: .live), range: 0...12, format: "%.1f dB",
                tooltip: "Width of the soft transition around each band's threshold. Larger knee = gentler onset of compression.")
            DoubleSliderRow(title: "Link", value: model.configBinding(\.multibandLinkStrength, runtimeDisposition: .live), range: 0...1, format: "%.2f",
                tooltip: "How much gain reduction is shared across bands. 0 = independent (dense), 1 = linked (preserves spectral balance).")
            Toggle("Program-dependent Release", isOn: model.configBinding(\.multibandReleaseProgramDependent, runtimeDisposition: .live))
            Toggle("Transient-aware Attack", isOn: model.configBinding(\.multibandTransientAwareAttackEnabled, runtimeDisposition: .live))
                .help("Uses a peak/RMS hybrid detector and briefly slows attack on percussive fronts so kicks and snares are not over-squashed.")
            Toggle("Inter-band Coupling", isOn: model.configBinding(\.multibandInterBandCouplingEnabled, runtimeDisposition: .live))
                .help("Experimental: low-band gain reduction gently lowers upper-band thresholds so bass-heavy passages stay tonally glued.")

            // Crossovers — operator-rare; collapsed by default. Once
            // the FabFilter-style spectrum-with-drag-handles editor
            // ships, this group disappears entirely.
            DisclosureGroup("Crossovers") {
                DoubleSliderRow(title: "X1 (Low / Low-Mid)", value: model.configBinding(\.multibandX1Hz, runtimeDisposition: .live), range: 30...300, format: "%.0f Hz",
                    tooltip: "Low / Low-Mid crossover frequency. Separates kick/bass from low-mid body.")
                DoubleSliderRow(title: "X2 (Low-Mid / Mid)", value: model.configBinding(\.multibandX2Hz, runtimeDisposition: .live), range: 120...1200, format: "%.0f Hz",
                    tooltip: "Low-Mid / Mid crossover frequency. Separates body from upper-vocal and presence region.")
                DoubleSliderRow(title: "X3 (Mid / High-Mid)", value: model.configBinding(\.multibandX3Hz, runtimeDisposition: .live), range: 600...4000, format: "%.0f Hz",
                    tooltip: "Mid / High-Mid crossover frequency. Separates vocal presence from upper consonants and sibilance.")
                DoubleSliderRow(title: "X4 (High-Mid / High)", value: model.configBinding(\.multibandX4Hz, runtimeDisposition: .live), range: 2500...12000, format: "%.0f Hz",
                    tooltip: "High-Mid / High crossover frequency. Separates sibilance region from air / top-end.")
            }
        }
    }
}

private struct ProcessingWidenerTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Stereo Widener") {
            Picker("Preset", selection: Binding(
                get: { self.model.currentWidenerPresetID },
                set: { newValue in
                    guard newValue != "custom" else { return }
                    self.model.applyWidenerPreset(id: newValue)
                }
            )) {
                ForEach(model.widenerPresetChoices) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            Toggle("Enable Stereo Widener", isOn: model.configBinding(\.stereoWidenEnabled, runtimeDisposition: .live))
            Toggle("Mono Bass", isOn: model.configBinding(\.monoBassEnabled, runtimeDisposition: .live))
            DoubleSliderRow(
                title: "Bass Mono Freq",
                value: model.configBinding(\.monoBassFreqHz, runtimeDisposition: .live),
                range: 70...220,
                format: "%.0f Hz",
                tooltip: "Below this frequency, L and R side energy is summed to mono. Improves FM mono compatibility and sub-bass deviation behavior."
            )
            .disabled(!model.config.monoBassEnabled)
            DoubleSliderRow(title: "Width", value: model.configBinding(\.stereoWidenWidth, runtimeDisposition: .live), range: 0...1, format: "%.2f",
                tooltip: "Amount of upper-band side-channel expansion. 0 = mono-safe, 1 = maximum widening (risks over-modulation and FM noise in weak signal areas).")
            DoubleSliderRow(title: "Center", value: model.configBinding(\.stereoWidenCenter, runtimeDisposition: .live), range: 0...1, format: "%.2f",
                tooltip: "Preservation of the center image during widening. Higher = keeps vocals and lead instruments anchored in the phantom center.")
            DoubleSliderRow(title: "Mix", value: model.configBinding(\.stereoWidenMix, runtimeDisposition: .live), range: 0...1, format: "%.2f",
                tooltip: "Wet/dry blend of the widened signal. 1.0 = fully processed, 0.0 = bypass. Lower values reduce any unintended coloration.")
            Text("Start with Safe FM, then move to Open Music only if mono compatibility and verifier output stay clean.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProcessingLimiterTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Audio Limiter") {
            Toggle("Enable Pre-Encode Limiter", isOn: model.configBinding(\.preEncodeAudioLimiterEnabled, runtimeDisposition: .live))
            let disabled = !model.config.preEncodeAudioLimiterEnabled
            DoubleSliderRow(
                title: "Threshold",
                value: model.configBinding(\.preEncodeThreshold, runtimeDisposition: .live),
                range: 0.5...0.999,
                format: "%.3f",
                tooltip: "Linear ceiling for the 4x oversampled true-peak limiter (0.5..0.999). 0.95 = -0.45 dBFS, 0.85 = -1.41 dBFS. Lower = more headroom for downstream stages, more limiting on peaks."
            ).disabled(disabled)
            DoubleSliderRow(
                title: "Release",
                value: model.configBinding(\.preEncodeReleaseMS, runtimeDisposition: .live),
                range: 10...200,
                format: "%.0f ms",
                tooltip: "Release time of the limiter envelope. Faster (lower ms) recovers loudness quicker but may pump; slower is cleaner but holds gain reduction longer."
            ).disabled(disabled)
            DoubleSliderRow(
                title: "Look-ahead",
                value: model.configBinding(\.preEncodeLookaheadMS, runtimeDisposition: .restart),
                range: 0...5,
                format: "%.2f ms",
                tooltip: "Look-ahead time so the limiter's gain ramp engages before the peak reaches the gain stage. 0 ms = feedback-only behavior. 1-2 ms recommended for cleaner HF transient handling on pre-emphasized content (cymbals, sibilance, percussion edges). Adds equivalent latency to the chain. Restart-required.",
                restartRequired: true
            ).disabled(disabled)
            DisclosureGroup("Advanced") {
                Toggle(
                    "Reduce Clipping Distortion",
                    isOn: model.configBinding(\.preEncodeBandlimitedResidualEnabled, runtimeDisposition: .live)
                )
                .help("Shapes the limiter's clipping residual to suppress aliasing and intermodulation, instead of the classic soft ceiling. Experimental; off keeps the current behavior.")
                .disabled(disabled)
                Toggle(isOn: model.configBinding(\.preEncodeLookaheadHFOnly, runtimeDisposition: .restart)) {
                    HStack(spacing: 6) {
                        Text("High-Frequency Transient Look-ahead")
                        RestartBadge()
                    }
                }
                .help("Engages look-ahead only on high-frequency transients (where pre-emphasis concentrates peaks), leaving low-frequency punch untouched. Requires Look-ahead above 0. Restart-required.")
                .disabled(disabled || model.config.preEncodeLookaheadMS <= 0.0)
                DoubleSliderRow(
                    title: "HF Detector Cutoff",
                    value: model.configBinding(\.preEncodeLookaheadHFCutoffHz, runtimeDisposition: .restart),
                    range: 1_000...12_000,
                    format: "%.0f Hz",
                    tooltip: "High-pass cutoff for the HF transient look-ahead detector. 4 kHz default; lower (2-3 kHz) catches more vocal sibilance, higher (6-8 kHz) targets cymbals / hi-hats only. Restart-required.",
                    restartRequired: true
                ).disabled(disabled || !model.config.preEncodeLookaheadHFOnly || model.config.preEncodeLookaheadMS <= 0.0)
            }
            .disabled(disabled)
        }
    }
}

private struct ProcessingFinalStageTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Card(title: "Final Stage") {
            Picker("Broadcast Preset", selection: Binding(
                get: { self.model.config.finalStagePresetID },
                set: { newValue in
                    self.model.config.finalStagePresetID = newValue
                    self.model.applyFinalStagePreset(id: newValue)
                }
            )) {
                ForEach(model.finalStagePresetChoices) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            DoubleSliderRow(
                title: "Final Drive",
                value: model.configBinding(\.finalDriveDB, runtimeDisposition: .live),
                range: 0...12,
                format: "%.1f dB",
                tooltip: "Drive into the composite clipper. The primary loudness control. Higher drive = hotter, more clipping; sustained high attenuation means too hot."
            )
            DoubleSliderRow(title: "Composite Deviation", value: model.configBinding(\.mpxDeviationKHz, runtimeDisposition: .live), range: 40...90, format: "%.1f kHz",
                tooltip: "Target peak FM deviation. 75 kHz = ITU-R BS.450 / US FM; 50 kHz = some European reduced-deviation mandates.")
            Text("Broadcast Preset updates AGC platform and final-stage drive together. Final Drive feeds the composite clipper before MPX Output Level calibration. Composite Deviation sets the peak target for the final FM modulator.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Card(title: "Final-MPX Safety Limiter") {
            Toggle("Enable Safety Limiter", isOn: model.configBinding(\.limitMPX))
                .help("Look-ahead peak limiter on the final MPX (audio composite + safety net). Pilot and RDS bypass this stage to keep subcarriers at constant amplitude. Restart-required.")
            let disabled = !model.config.limitMPX
            DisclosureGroup("Advanced") {
                DoubleSliderRow(title: "Threshold", value: model.configBinding(\.limitThreshold), range: 0.5...0.999, format: "%.3f",
                    tooltip: "Linear ceiling for the safety limiter (0.5..0.999). 0.98 = -0.18 dBFS. Below this the limiter doesn't engage; above it the look-ahead reduces gain to keep peaks under the ceiling.").disabled(disabled)
                Toggle("Enable Look-Ahead", isOn: model.configBinding(\.limitLookaheadEnabled))
                    .help("Look-ahead delay so the limiter sees future peaks and applies gain reduction smoothly before the peak arrives. Off makes the limiter purely reactive (more overshoot).")
                    .disabled(disabled)
                DoubleSliderRow(title: "Look-Ahead", value: model.configBinding(\.limitLookaheadMS), range: 0...20, format: "%.1f ms",
                    tooltip: "How far ahead the limiter looks before responding. 5 ms is standard; longer = smoother gain reduction at the cost of latency.").disabled(disabled || !model.config.limitLookaheadEnabled)
            }
            .disabled(disabled)
        }
      }
    }
}

private struct ProcessingPhaseRotatorTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Phase Rotator") {
            Toggle("Enable Phase Rotator", isOn: model.configBinding(\.phaseRotationEnabled, runtimeDisposition: .live))
            DoubleSliderRow(
                title: "Frequency",
                value: model.configBinding(\.phaseRotationFreqHz, runtimeDisposition: .live),
                range: 50...500,
                format: "%.1f Hz",
                tooltip: "Center frequency of the 4-pole allpass chain. 200 Hz is typical; lower values target male voice, higher values target female voice."
            )
            .disabled(!model.config.phaseRotationEnabled)
            Text("4-pole allpass chain reduces waveform asymmetry (especially voice) by 3\u{2013}4 dB, giving free headroom to downstream dynamics stages.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProcessingParametricEQTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Parametric EQ") {
            Toggle("Enable Parametric EQ", isOn: model.configBinding(\.parametricEQEnabled, runtimeDisposition: .live))
            let disabled = !model.config.parametricEQEnabled

            Text("Band 1 \u{2014} Low Shelf").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            DoubleSliderRow(title: "Freq", value: model.configBinding(\.peqB1FreqHz, runtimeDisposition: .live), range: 20...500, format: "%.0f Hz",
                tooltip: "Low shelf corner frequency. Content below this frequency is boost/cut by the shelf gain.").disabled(disabled)
            DoubleSliderRow(title: "Gain", value: model.configBinding(\.peqB1GainDB, runtimeDisposition: .live), range: -12...12, format: "%.1f dB",
                tooltip: "Boost or cut applied below the shelf frequency. Positive adds warmth; negative tightens bass.").disabled(disabled)

            Text("Band 2 \u{2014} Peaking").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            DoubleSliderRow(title: "Freq", value: model.configBinding(\.peqB2FreqHz, runtimeDisposition: .live), range: 100...5000, format: "%.0f Hz",
                tooltip: "Center frequency of this peaking band.").disabled(disabled)
            DoubleSliderRow(title: "Gain", value: model.configBinding(\.peqB2GainDB, runtimeDisposition: .live), range: -12...12, format: "%.1f dB",
                tooltip: "Boost or cut at the center frequency.").disabled(disabled)
            DoubleSliderRow(title: "Q", value: model.configBinding(\.peqB2Q, runtimeDisposition: .live), range: 0.1...10, format: "%.2f",
                tooltip: "Bandwidth of the peaking filter. Low Q = broad / musical; high Q = narrow / surgical.").disabled(disabled)

            Text("Band 3 \u{2014} Peaking").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            DoubleSliderRow(title: "Freq", value: model.configBinding(\.peqB3FreqHz, runtimeDisposition: .live), range: 500...12000, format: "%.0f Hz",
                tooltip: "Center frequency of this peaking band.").disabled(disabled)
            DoubleSliderRow(title: "Gain", value: model.configBinding(\.peqB3GainDB, runtimeDisposition: .live), range: -12...12, format: "%.1f dB",
                tooltip: "Boost or cut at the center frequency.").disabled(disabled)
            DoubleSliderRow(title: "Q", value: model.configBinding(\.peqB3Q, runtimeDisposition: .live), range: 0.1...10, format: "%.2f",
                tooltip: "Bandwidth of the peaking filter. Low Q = broad / musical; high Q = narrow / surgical.").disabled(disabled)

            Text("Band 4 \u{2014} High Shelf").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            DoubleSliderRow(title: "Freq", value: model.configBinding(\.peqB4FreqHz, runtimeDisposition: .live), range: 1000...16000, format: "%.0f Hz",
                tooltip: "High shelf corner frequency. Content above this frequency is boost/cut by the shelf gain.").disabled(disabled)
            DoubleSliderRow(title: "Gain", value: model.configBinding(\.peqB4GainDB, runtimeDisposition: .live), range: -12...12, format: "%.1f dB",
                tooltip: "Boost or cut applied above the shelf frequency. Positive adds air; negative dulls harshness.").disabled(disabled)
        }
    }
}

private struct ProcessingMultibandLimiterTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Multiband Limiter") {
            Toggle("Enable Multiband Limiter", isOn: model.configBinding(\.multibandLimiterEnabled, runtimeDisposition: .live))
            DoubleSliderRow(
                title: "Threshold",
                value: model.configBinding(\.multibandLimiterThresholdDB, runtimeDisposition: .live),
                range: -20...0,
                format: "%.1f dB",
                tooltip: "Per-band brick-wall limit threshold. Instantaneous peaks above this level are clipped regardless of the compressor ratio."
            )
            .disabled(!model.config.multibandLimiterEnabled)
            DoubleSliderRow(
                title: "Attack",
                value: model.configBinding(\.multibandLimiterAttackMS, runtimeDisposition: .live),
                range: 0.01...10,
                format: "%.2f ms",
                tooltip: "Limiter attack in ms. Sub-ms attack catches fast transients cleanly at the cost of some distortion."
            )
            .disabled(!model.config.multibandLimiterEnabled)
            DoubleSliderRow(
                title: "Release",
                value: model.configBinding(\.multibandLimiterReleaseMS, runtimeDisposition: .live),
                range: 10...500,
                format: "%.1f ms",
                tooltip: "Limiter release in ms. Short release = more density; long release = more transparent."
            )
            .disabled(!model.config.multibandLimiterEnabled)
        }
    }
}

private struct ProcessingExpanderTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Downward Expander") {
            Toggle("Enable Expander", isOn: model.configBinding(\.downwardExpanderEnabled, runtimeDisposition: .live))
            let disabled = !model.config.downwardExpanderEnabled
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.expanderThresholdDB, runtimeDisposition: .live), range: -60...(-20), format: "%.1f dB",
                tooltip: "Level below which gain starts to reduce. Set just above the noise floor of the program material.").disabled(disabled)
            DoubleSliderRow(title: "Ratio", value: model.configBinding(\.expanderRatio, runtimeDisposition: .live), range: 1...8, format: "%.1f:1",
                tooltip: "Gain reduction ratio below threshold. Higher ratio = deeper attenuation of quiet material.").disabled(disabled)
            DoubleSliderRow(title: "Attack", value: model.configBinding(\.expanderAttackMS, runtimeDisposition: .live), range: 0.1...100, format: "%.1f ms",
                tooltip: "Time to re-open the gate once program re-exceeds the threshold. Fast attack preserves initial transients.").disabled(disabled)
            DoubleSliderRow(title: "Release", value: model.configBinding(\.expanderReleaseMS, runtimeDisposition: .live), range: 10...2000, format: "%.0f ms",
                tooltip: "Time to close the gate once program falls below the threshold. Longer release avoids chattering on sustained-but-quiet sources.").disabled(disabled)
        }
    }
}

private struct ProcessingBassClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Bass Clipper") {
            Toggle("Enable Bass Clipper", isOn: model.configBinding(\.bassClipperEnabled, runtimeDisposition: .live))
            let disabled = !model.config.bassClipperEnabled
            DoubleSliderRow(title: "Crossover", value: model.configBinding(\.bassClipperCrossoverHz, runtimeDisposition: .live), range: 60...300, format: "%.0f Hz",
                tooltip: "Crossover frequency isolating the low band for clipping. Content below this is clipped independently; above passes unmodified.").disabled(disabled)
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.bassClipperThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Clipping threshold for the low band. Lower = more aggressive bass clipping, reducing bass-induced IMD in downstream stages.").disabled(disabled)
            DoubleSliderRow(title: "Drive", value: model.configBinding(\.bassClipperDrive, runtimeDisposition: .live), range: 0.5...3, format: "%.2f",
                tooltip: "Pre-clipping gain applied to the low band. Higher drive increases density but also clipping distortion.").disabled(disabled)
        }
    }
}

private struct ProcessingHFClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "HF Clipper") {
            Toggle("Enable HF Clipper", isOn: model.configBinding(\.hfClipperEnabled, runtimeDisposition: .live))
            let disabled = !model.config.hfClipperEnabled
            DoubleSliderRow(title: "Crossover", value: model.configBinding(\.hfClipperCrossoverHz, runtimeDisposition: .live), range: 3000...8000, format: "%.0f Hz",
                tooltip: "Crossover frequency isolating the high band for clipping. Content above this is clipped; below passes unmodified.").disabled(disabled)
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.hfClipperThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Clipping threshold for the high band. Lower = more aggressive HF clipping, offloading HF transients from the broadband limiter.").disabled(disabled)
            DoubleSliderRow(title: "Drive", value: model.configBinding(\.hfClipperDrive, runtimeDisposition: .live), range: 0.5...3, format: "%.2f",
                tooltip: "Pre-clipping gain on the high band. Higher drive increases HF density but also clipping distortion.").disabled(disabled)
        }
    }
}

private struct ProcessingDCClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Audio Clipper") {
            Toggle("Enable Audio Clipper", isOn: model.configBinding(\.dcClipperEnabled, runtimeDisposition: .live))
            let disabled = !model.config.dcClipperEnabled
            DoubleSliderRow(title: "Ceiling", value: model.configBinding(\.dcClipperCeilingDB, runtimeDisposition: .live), range: -6...0, format: "%.1f dB",
                tooltip: "Clipping ceiling for the distortion-cancelled clipper. Lower ceiling = more audible density but more clipping artifacts.").disabled(disabled)
            DoubleSliderRow(title: "Cancel Freq", value: model.configBinding(\.dcClipperCancelFreqHz, runtimeDisposition: .live), range: 500...4000, format: "%.0f Hz",
                tooltip: "Cutoff of the LF error-extraction filter. Clipping distortion below this frequency is subtracted; above, it is left for masking.").disabled(disabled)
        }
    }
}

private struct ProcessingBS412Tab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "BS.412 MPX Power Limiter") {
            Toggle("Enable BS.412", isOn: model.configBinding(\.bs412Enabled, runtimeDisposition: .live))
            let disabled = !model.config.bs412Enabled
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.bs412ThresholdDB, runtimeDisposition: .live), range: -20...0, format: "%.1f dB",
                tooltip: "MPX average-power ceiling per ITU-R BS.412. Required for EU regulatory compliance (DE, AT, CH, SE, CZ, SI, etc).").disabled(disabled)
            DoubleSliderRow(title: "Window", value: model.configBinding(\.bs412WindowSeconds, runtimeDisposition: .live), range: 30...90, format: "%.0f s",
                tooltip: "Rolling averaging window for BS.412 power measurement. 60 s is the regulatory default; values outside ~30-90 s stop being BS.412 and become a generic AGC.").disabled(disabled)
        }
    }
}

private struct ProcessingCompositeClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Composite Clipper") {
            Toggle("Enable Composite Clipper", isOn: model.configBinding(\.compositeClipperEnabled, runtimeDisposition: .live))
            let disabled = !model.config.compositeClipperEnabled
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.compositeClipperThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Onset of composite-level soft clipping on the audio composite (not pilot/RDS). Primary loudness lever when engaged.").disabled(disabled)
            DoubleSliderRow(title: "Ceiling", value: model.configBinding(\.compositeClipperCeilingDB, runtimeDisposition: .live), range: -6...0, format: "%.1f dB",
                tooltip: "Maximum output level after composite clipping. Must stay below 0 dBFS to leave headroom for pilot/RDS injection.").disabled(disabled)
            DoubleSliderRow(title: "Look-ahead", value: model.configBinding(\.compositeClipperLookaheadMS, runtimeDisposition: .live), range: 0...5, format: "%.1f ms",
                tooltip: "Predictive peak shaving. 0.0 disables; 2.0 ms = recommended preset. Sliding-window-max detector + half-cosine attack + 200 Hz smoother bound overshoots tighter than the soft-clip alone, at the cost of N ms added chain latency. Hardcoded internals: 1.5 ms attack, 80 ms release, 200 Hz smoothing.").disabled(disabled)
            LabeledContent("Look-ahead GR") {
                LiveObservationView(telemetry: model.telemetry) { t in
                    Text(String(format: "%5.1f dB", Double(t.compositeClipperLookaheadGainReductionDBValue)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Subcarrier Protection")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle("Protect Audio Highs", isOn: model.configBinding(\.compositeClipperCancelAudio, runtimeDisposition: .live))
                .help("Off (default): full clipping in the audio band for maximum loudness. On: subtracts in-band clip residual to keep highs cleaner, at the cost of some peak control / loudness. Enable when high-frequency harshness is the bigger concern.")
                .disabled(disabled)
            Toggle("Protect Stereo Pilot", isOn: model.configBinding(\.compositeClipperCancelPilot, runtimeDisposition: .live))
                .help("Removes clipping distortion from the 19 kHz pilot region so the receiver decodes stereo cleanly. Leave on except for diagnostic A/B.")
                .disabled(disabled)
            Toggle("Protect Stereo Subcarrier", isOn: model.configBinding(\.compositeClipperCancelStereo, runtimeDisposition: .live))
                .help("Removes clipping distortion from the 38 kHz L-R subcarrier so stereo separation is preserved. Leave on except for diagnostic A/B.")
                .disabled(disabled)
            Toggle("Protect RDS", isOn: model.configBinding(\.compositeClipperCancelRDS, runtimeDisposition: .live))
                .help("Removes clipping distortion from the 57 kHz RDS region so receivers don't see clipper noise summed with the RDS subcarrier. Leave on except for diagnostic A/B.")
                .disabled(disabled)
            Text("Tip: leave the composite clipper off when loudness isn't critical -- it trades peak control for stereo image and HF cleanliness. If you do enable it, turning on \"Protect Audio Highs\" recovers HF detail at the cost of some loudness.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup("Experimental") {
                Toggle("Multiband Composite Clipping", isOn: model.configBinding(\.compositeMultibandClipperEnabled, runtimeDisposition: .live))
                    .help("Experimental, off by default. Additional loudness stage after the broadband composite clipper: splits the audio composite into low / mid / high bands, clips them independently, then recombines before pilot/RDS injection.")
            }
        }
    }
}

private struct LevelsOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MonitoringWindowHeader(
                    title: kLevelsWindowTitle,
                    subtitle: "Input, post-AGC, and output meters."
                )
                LevelsCardView(model: model)
            }
            .padding(20)
        }
    }
}

private struct SystemSettingsSectionContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    private let sampleRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    private let blockSizes: [Int] = [512, 1024, 2048, 4096, 8192]

    var body: some View {
        Group {
            Picker("Sample Rate", selection: model.configBinding(\.sampleRate)) {
                ForEach(sampleRates, id: \.self) { rate in
                    Text("\(Int(rate)) Hz").tag(rate)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isRunning)

            Picker("Block Size", selection: model.configBinding(\.blockSize)) {
                ForEach(blockSizes, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }
            .pickerStyle(.menu)

            Toggle(
                "Auto Start at Launch",
                isOn: model.configBinding(\.rdsAutoStart, runtimeDisposition: .none))

            // Mono Mode lives in the sidebar footer. Pilot Level is the
            // only stereo-encoder-structure parameter exposed here.
            // Sum/diff matrix gains are spec-fixed (M=(L+R)/2, S=(L-R)/2
            // per ITU-R BS.450 / EN 50067) and not user-configurable;
            // INI keys `sum_level` / `diff_level` remain for lab/debug use.
            // Pilot Level range follows ITU-R BS.450-4 / FCC 73.322 (8-10%
            // deviation); slider permits 0-12% for headroom and 0 = mute.
            // Pilot is a composite-only subcarrier; no pilot in processed-audio output.
            if !model.processedAudioOutputActive {
                DoubleSliderRow(
                    title: "Pilot Level", value: model.pilotLevelPercentBinding(),
                    range: 0...12, format: "%.1f %%",
                    restartRequired: true)
                .disabled(model.config.monoMode)
            }

            InlineRestartRequiredNote(
                text: model.processedAudioOutputActive
                    ? "Sample rate, block size, output mode, pre-emphasis, program lowpass, and other encoder-structure changes."
                    : "Sample rate, block size, mono mode, pre-emphasis, pilot level, program lowpass, and other encoder-structure changes."
            )
        }
    }
}

private struct InterfacesSettingsSectionContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Group {
            Picker(
                "Input Device",
                selection: Binding(
                    get: { model.selectedInputUID },
                    set: {
                        model.selectedInputUID = $0
                        model.persistBasicConfig()
                    }
                )
            ) {
                if model.inputDevices.isEmpty {
                    Text("No input devices").tag("")
                } else {
                    ForEach(model.inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
            .pickerStyle(.menu)

                Picker(
                    "MPX Output Device",
                    selection: Binding(
                    get: { model.selectedOutputUID },
                    set: {
                        model.selectedOutputUID = $0
                        model.persistBasicConfig()
                    }
                )
            ) {
                if model.outputDevices.isEmpty {
                    Text("No output devices").tag("")
                } else {
                    ForEach(model.outputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
            .pickerStyle(.menu)

            Picker(
                "Monitor Output Device (Decoded MPX Simulation)",
                selection: Binding(
                    get: { model.selectedMonitorUID },
                    set: {
                        model.selectedMonitorUID = $0
                        model.persistBasicConfig()
                    }
                )
            ) {
                if model.outputDevices.isEmpty {
                    Text("No output devices").tag("")
                } else {
                    ForEach(model.outputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
            .pickerStyle(.menu)

            Toggle(
                "Enable Monitor Output",
                isOn: Binding(
                    get: { model.monitorEnabled },
                    set: {
                        model.monitorEnabled = $0
                        model.persistBasicConfig()
                    }
                ))

            Text("When Enable Monitor Output is on, this device is used for decoded MPX monitoring.")
                .font(.caption)
                .foregroundStyle(.secondary)

            InlineRestartRequiredNote(
                text: "Source mode, monitor output routing, and input/output/monitor device changes."
            )
        }
    }
}

private struct RDSProgramTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Program Service") {
            PSBankRow(letter: "A", model: model, path: \.rdsPSA)
            PSBankRow(letter: "B", model: model, path: \.rdsPSB)
            PSBankRow(letter: "C", model: model, path: \.rdsPSC)
            PSBankRow(letter: "D", model: model, path: \.rdsPSD)
            Picker("Program Type (PTY)", selection: model.ptyBinding()) {
                ForEach(model.ptyChoices, id: \.0) { pty in
                    Text("\(pty.0) · \(pty.1)").tag(pty.0)
                }
            }
            DisclosureGroup("PS Display") {
                Toggle("Center PS", isOn: model.configBinding(\.rdsPSCentered, runtimeDisposition: .liveRDS))
                DoubleSliderRow(
                    title: "PS Frame",
                    value: model.configBinding(\.rdsPSFrameSeconds, runtimeDisposition: .liveRDS),
                    range: 0.5...10.0,
                    format: "%.1f s")
                .help("Default seconds each PS chunk is shown when the source has no explicit Ns: timing marker. Typical broadcast cadence is 3 s. Per-segment markers like 4s:NEWS still override this.")
                Toggle("Enable PTYN", isOn: model.configBinding(\.rdsEnablePTYN, runtimeDisposition: .liveRDS))
                RDSCountedField(placeholder: "PTYN", text: model.configBinding(\.rdsPTYN, runtimeDisposition: .liveRDS), maxChars: 8)
                Toggle("Center PTYN", isOn: model.configBinding(\.rdsPTYNCentered, runtimeDisposition: .liveRDS))
            }
            DisclosureGroup("Station Identity") {
                LabeledContent("PI Code") {
                    HexCodeField(text: model.piBinding(), placeholder: "0000", width: 72)
                }
                .help("Program Identification: the unique 16-bit hex station ID a receiver uses to recognize this station and follow it across alternative frequencies (AF). Assigned by your national broadcast authority; in RBDS it is derived from the call sign.")
                LabeledContent("ECC") {
                    HexCodeField(text: model.hexByteBinding(\.rdsECC), placeholder: "E3", width: 54)
                }
                .help("Extended Country Code: one hex byte that, combined with the PI country nibble, uniquely identifies the country. Lets receivers distinguish countries that share a PI prefix. Default E3 is the Netherlands; set the value for your country (e.g. E0 Italy, E1 UK/France, E2 Spain).")
                LabeledContent("LIC") {
                    HexCodeField(text: model.hexByteBinding(\.rdsLIC), placeholder: "1D", width: 54)
                }
                .help("Language Identification Code: one hex byte naming the programme language, sent in Group 1A alongside the ECC. Independent of country. Default 1D is Dutch; e.g. 15 Italian, 09 English, 0F French, 08 German, 0A Spanish.")
                Toggle("Enable PIN (1A)", isOn: model.configBinding(\.rdsEnablePIN, runtimeDisposition: .liveRDS))
                    .help("Programme Item Number, Group 1A block 4: the scheduled start (day-of-month / hour / minute) of the current programme item. Legacy -- rarely decoded by modern receivers; off transmits 0.")
                if model.config.rdsEnablePIN {
                    HStack(spacing: 14) {
                        Stepper("Day \(model.config.rdsPINDay)",
                                value: model.configBinding(\.rdsPINDay, runtimeDisposition: .liveRDS), in: 1...31)
                        Stepper("Hour \(model.config.rdsPINHour)",
                                value: model.configBinding(\.rdsPINHour, runtimeDisposition: .liveRDS), in: 0...23)
                        Stepper("Min \(model.config.rdsPINMinute)",
                                value: model.configBinding(\.rdsPINMinute, runtimeDisposition: .liveRDS), in: 0...59)
                    }
                    .font(.callout)
                }
                Picker("PTY Region", selection: model.configBinding(\.rdsPtyRBDS, runtimeDisposition: .none)) {
                    Text("Europe (RDS)").tag(false)
                    Text("USA (RBDS)").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Selects which genre table labels the PTY code above. The transmitted 5-bit PTY value is identical either way -- Europe (RDS, EN 50067) and North America (RBDS, NRSC-4) just name the same code differently, and receivers pick the table by region. Same number, different genre: e.g. 10 reads as Pop Music on RDS but Country on RBDS.")
            }
        }

        // Per-program operational flags. Live-applied; UECP MEC 0x0E
        // (TA) flips edge-triggered during a traffic announcement.
        // Commercial RDS encoder convention (P164, SmartGen, Audemat,
        // every UECP encoder) places these alongside PI / PS / PTY in
        // the Basic/Identity tab — they describe "what this station is
        // broadcasting right now", not encoder control.
        Card(title: "Runtime Flags") {
            LazyVGrid(columns: [
                GridItem(.flexible(minimum: 100)),
                GridItem(.flexible(minimum: 100)),
                GridItem(.flexible(minimum: 100))
            ], alignment: .leading, spacing: 8) {
                Toggle("TP", isOn: model.configBinding(\.rdsTP, runtimeDisposition: .liveRDS))
                    .help("Traffic Program: this station carries traffic announcements from time to time.")
                Toggle("TA", isOn: model.configBinding(\.rdsTA, runtimeDisposition: .liveRDS))
                    .help("Traffic Announcement: flip on for the duration of a traffic bulletin so TA-enabled receivers switch to it, then flip off.")
                Toggle("MS", isOn: model.configBinding(\.rdsMS, runtimeDisposition: .liveRDS))
                    .help("Music / Speech: tells receivers whether the current program is music (on) or speech (off).")
            }
            .toggleStyle(.switch)
            DisclosureGroup("Decoder Info (DI)") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("DI Stereo", isOn: model.configBinding(\.rdsDI_STEREO, runtimeDisposition: .liveRDS))
                        .help("Decoder Identification: tells receivers the broadcast is stereo (off = mono). Set this to match the actual program.")
                    Toggle("DI Head", isOn: model.configBinding(\.rdsDI_HEAD, runtimeDisposition: .liveRDS))
                        .help("Decoder Identification: signals artificial-head (binaural) audio. Leave off for normal stereo program.")
                    Toggle("DI Comp", isOn: model.configBinding(\.rdsDI_COMP, runtimeDisposition: .liveRDS))
                        .help("Decoder Identification: signals the audio is compressed/companded (an obsolete noise-reduction scheme). Leave off for normal program.")
                    Toggle("DI Dyn PTY", isOn: model.configBinding(\.rdsDI_DYN, runtimeDisposition: .liveRDS))
                        .help("Decoder Identification: marks the Program Type as dynamically changing (varies through the broadcast) rather than fixed for the station.")
                }
                .toggleStyle(.switch)
            }
            Text("Per-program flags. Applied live without restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PSBankRow: View {
    let letter: String
    @ObservedObject var model: MPXPrimeViewModel
    let path: WritableKeyPath<AppConfig, String>

    var body: some View {
        let isActive = model.config.rdsPSActiveBank.uppercased() == letter
        HStack(spacing: 10) {
            Button {
                model.setConfigValue(\.rdsPSActiveBank, letter, runtimeDisposition: .liveRDS)
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive ? "PS bank \(letter) active" : "Activate PS bank \(letter)")
            .help("Make PS \(letter) the active bank")

            Text("PS \(letter)")
                .frame(width: 40, alignment: .leading)
                .font(.callout.monospaced())
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

            RDSCountedField(placeholder: "", text: model.configBinding(path, runtimeDisposition: .liveRDS), maxChars: 8)
        }
    }
}

/// RDS text entry with a live character counter. RDS fields have hard
/// length limits (PS 8, PTYN 8, Long PS 32, RadioText 64); past the limit
/// the encoder silently truncates. The trailing `n/max` counter turns amber
/// once the field reaches the limit so the operator sees it before air.
private struct RDSCountedField: View {
    let placeholder: String
    let text: Binding<String>
    let maxChars: Int

    var body: some View {
        let count = text.wrappedValue.count
        let atLimit = count >= maxChars
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            Text("\(count)/\(maxChars)")
                .font(BroadcastStyle.scaleLabel)
                .monospacedDigit()
                .foregroundStyle(atLimit ? BroadcastStyle.tightAmber : .secondary)
                .accessibilityLabel("\(count) of \(maxChars) characters")
        }
    }
}

private struct HexCodeField: View {
    let text: Binding<String>
    let placeholder: String
    let width: CGFloat

    var body: some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.tertiary))
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width)
            .background(BroadcastStyle.meterSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(BroadcastStyle.panelBorder, lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .textSelection(.enabled)
    }
}

private struct RDSRadiotextTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Radiotext & RT+") {
            RDSCountedField(placeholder: "Single Radiotext", text: model.configBinding(\.rdsRTText, runtimeDisposition: .liveRDS), maxChars: 64)
            Text("Used when no RT buffer entries are checked.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("RT Buffers")
                    .font(.headline)
                Text("Checked messages are active. If multiple are checked, they rotate in order using Cycle Time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        Toggle(
                            "Msg \(index + 1)",
                            isOn: model.rtBufferEnabledBinding(index)
                        )
                        .toggleStyle(.checkbox)
                        .frame(width: 72, alignment: .leading)
                        TextField(
                            "Radiotext message \(index + 1)",
                            text: model.rtBufferTextBinding(index)
                        )
                    }
                }
                if model.enabledRTBufferIndices.isEmpty {
                    Text("No checked RT messages. Legacy single-field Radiotext will be used until you enable one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            Picker("RT Mode", selection: model.configBinding(\.rdsRTMode, runtimeDisposition: .liveRDS)) {
                Text("2A (64 chars)").tag("2A")
                Text("2B (32 chars)").tag("2B")
            }
            .pickerStyle(.segmented)
            DoubleSliderRow(
                title: "Cycle Time", value: model.configBinding(\.rdsRTCycleTime, runtimeDisposition: .liveRDS),
                range: 1...20, format: "%.1f s")
            Toggle("Center RT", isOn: model.configBinding(\.rdsRTCentered, runtimeDisposition: .liveRDS))
            Toggle("Append CR", isOn: model.configBinding(\.rdsRTCR, runtimeDisposition: .liveRDS))
            Toggle("Enable RT+", isOn: model.configBinding(\.rdsEnableRTPlus, runtimeDisposition: .liveRDS))
            Text(
                "RT+ tags the song inside the RadioText -- by the RDS standard it cannot send "
                + "Artist/Title unless that text is actually in an RT message. To show Artist/Title "
                + "on receivers: (1) enable the Now Playing Script below, and (2) put "
                + "\"{artist} - {title}\" (or {now_playing}) in the Single Radiotext field or one of "
                + "the RT Buffer messages above. RT+ receivers then show Artist and Title in their "
                + "own fields (and cache them while other messages scroll). Tip: keep always-on "
                + "station identity in PS / Long PS, not RadioText."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            Toggle(
                "Enable Now Playing Script",
                isOn: model.configBinding(\.rdsNowPlayingEnabled, runtimeDisposition: .none))
            LabeledContent("Script Path") {
                HStack(spacing: 8) {
                    TextField(
                        "",
                        text: model.configBinding(\.rdsNowPlayingScript, runtimeDisposition: .none)
                    )
                    Button("Browse") {
                        model.chooseNowPlayingScript()
                    }
                    .buttonStyle(.bordered)
                }
            }
            DoubleSliderRow(
                title: "Poll Interval",
                value: model.configBinding(\.rdsNowPlayingPollSeconds, runtimeDisposition: .none),
                range: 1...60,
                format: "%.1f s"
            )
            DoubleSliderRow(
                title: "Script Timeout",
                value: model.configBinding(\.rdsNowPlayingTimeoutSeconds, runtimeDisposition: .none),
                range: 0.2...10,
                format: "%.1f s"
            )
            Text("Macros: {now_playing}, {artist}, {title}, {display}, {date}, {time}")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.value(for: \.rdsNowPlayingEnabled) {
                Text("The now-playing script fills the {artist} / {title} macros; RT+ tags them wherever they appear in your RadioText (Single Radiotext or an RT Buffer).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("RT+ Format A", text: model.configBinding(\.rdsRTPlusFormatA, runtimeDisposition: .liveRDS))
                TextField("RT+ Format B", text: model.configBinding(\.rdsRTPlusFormatB, runtimeDisposition: .liveRDS))
            }
            LiveObservationView(telemetry: model.telemetry) { t in
                Text(t.rdsNowPlayingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RDSLongPSTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Long PS") {
            Toggle("Enable Long PS (15A)", isOn: model.configBinding(\.rdsEnableLPS, runtimeDisposition: .liveRDS))
            RDSCountedField(placeholder: "Long PS Text", text: model.configBinding(\.rdsLongPS32, runtimeDisposition: .liveRDS), maxChars: 32)
            Toggle("Center Long PS", isOn: model.configBinding(\.rdsLPSCentered, runtimeDisposition: .liveRDS))
            Toggle("Append CR", isOn: model.configBinding(\.rdsLPSCR, runtimeDisposition: .liveRDS))
        }
    }
}

private struct RDSCarrierTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // Physical-layer settings for the 57 kHz subcarrier:
        // amplitude (injection level), frequency, and Gaussian shaping.
        // All restart-required; live-apply RDS data lives on the
        // Identity / Radiotext / Schedule tabs.
        Card(title: "Subcarrier") {
            DoubleSliderRow(
                title: "Injection Level",
                value: model.rdsLevelPercentBinding(),
                range: 0...10, format: "%.1f %%",
                restartRequired: true)
            Text("RDS subcarrier pulse shaping (enable / bandwidth / taps) is tuned at the defaults (on, 2400 Hz, 81 taps) and not exposed in the GUI — power users can adjust via INI keys `rds_gaussian_enabled` / `rds_gaussian_bw_hz` / `rds_gaussian_taps`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Group scheduling, scheduler policy, clock-time (4A) settings.
/// Splits out from the legacy Carrier tab so physical-layer (which
/// requires restart) and group-sequence policy (live-applied via
/// RDSRuntimeConfig) are clearly separated.
private struct RDSScheduleTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    // Automatic (recommended) vs Custom. Automatic uses the standard
    // IEC 62106 schedule, auto-derived from the enabled RDS features; Custom
    // uses the manual group sequence. Mapped onto the existing scheduler
    // flags so existing INIs keep working unchanged -- the manual sequence is
    // active only when both Standard and Auto are off.
    private var useCustomSequence: Binding<Bool> {
        Binding(
            get: { !model.config.rdsSchedulerStandard && !model.config.rdsSchedulerAuto },
            set: { custom in
                model.setConfigValue(\.rdsSchedulerStandard, !custom, runtimeDisposition: .liveRDS)
                model.setConfigValue(\.rdsSchedulerAuto, !custom, runtimeDisposition: .liveRDS)
            }
        )
    }

    var body: some View {
        Card(title: "Group Schedule") {
            Toggle("Custom group sequence", isOn: useCustomSequence)
                .help("Off (recommended): MPX Prime schedules RDS groups automatically at IEC 62106 group rates, derived from the features you enable (PS, RadioText, RT+, Clock-Time, AF, PTYN, Long PS). On: transmit exactly the group list you specify.")
            if useCustomSequence.wrappedValue {
                TextField(
                    "Group Sequence",
                    text: model.configBinding(\.rdsGroupSequence, runtimeDisposition: .liveRDS))
                    .textFieldStyle(.roundedBorder)
                Text("Space-separated groups, e.g. 0A 0A 2A 3A 11A. Advanced override -- you are responsible for including every group your enabled features need.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Automatic (recommended): the group mix follows IEC 62106 group rates and updates as you enable RDS features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Card(title: "Clock Time (4A)") {
            Toggle("Enable CT (4A)", isOn: model.configBinding(\.rdsEnableCT, runtimeDisposition: .liveRDS))
            Toggle("Enable ID (1A)", isOn: model.configBinding(\.rdsEnableID, runtimeDisposition: .liveRDS))
            DoubleSliderRow(
                title: "Clock Offset",
                value: model.configBinding(\.rdsTZOffset, runtimeDisposition: .liveRDS),
                range: -12...14, format: "%.1f h")
        }
    }
}

/// Alternative Frequencies (AF). Split out from the legacy Flags tab
/// because UECP makes AF a peer of PS (its own MEC), not a Flags
/// sibling. Method A vs B + comma-separated frequency list.
private struct RDSAFTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Alternative Frequencies") {
            Toggle(
                "Enable AF",
                isOn: model.configBinding(\.rdsEnableAF, runtimeDisposition: .liveRDS))
            HStack(spacing: 12) {
                Picker(
                    "AF Method",
                    selection: model.configBinding(\.rdsAFMethod, runtimeDisposition: .liveRDS)
                ) {
                    Text("Method A").tag("A")
                    Text("Method B").tag("B")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                TextField(
                    "AF List",
                    text: model.configBinding(\.rdsAFList, runtimeDisposition: .liveRDS)
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }
}

/// Status-first dashboard for the RDS subsystem. Operationally the
/// landing page: master Enable, current modulation %, live PI / PS /
/// RT readout, and operator toggles for TP / TA / MS / DI flags +
/// RT+ Item Toggle / Item Running. Detail tabs handle setup; this
/// tab handles "is it working right now".
private struct RDSStatusTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // Master kill switch + live monitoring view. Commercial
        // RDS-encoder convention (DEVA SmartGen, RDS Manager,
        // Audemat) calls this tab "Status". Per-program flags now
        // live on Identity; subcarrier injection now lives on
        // Subcarrier.
        Card(title: "Master") {
            Toggle(
                "Enable RDS",
                isOn: model.configBinding(\.enRDS, runtimeDisposition: .liveRDS))
            Text("Master enable applies live. Subcarrier-physical-layer settings (injection level, frequency, pulse shaping) live on the Subcarrier tab and require a transport restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Card(title: "Snapshot", style: .meter) {
            RDSLivePreviewPlate(model: model)
        }
    }
}

/// Output-mode selector: FM composite (default) vs processed stereo audio for
/// feeding an external stereo coder. Restart-required. When processed-audio is
/// selected, the composite clipper / BS.412 / RDS surfaces are hidden elsewhere
/// in the UI, and the pre-emphasis-ownership guidance below becomes critical.
private struct OutputModeSettingsSectionContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Picker(
            selection: model.configBinding(\.processedAudioOutput, runtimeDisposition: .restart)
        ) {
            Text("MPX Composite").tag(false)
            Text("Processed Audio").tag(true)
        } label: {
            HStack(spacing: 6) {
                Text("Output")
                RestartBadge()
            }
        }
        .pickerStyle(.segmented)
        .help("MPX Composite: the FM multiplex (pilot + stereo + RDS) for a transmitter / exciter that accepts composite. Processed Audio: processed stereo L/R for an external stereo coder + RDS encoder. Restart required.")

        if model.processedAudioOutputActive {
            Text("Emitting processed stereo L/R for an external stereo coder. The composite clipper, BS.412, pilot, and RDS are bypassed and hidden. Recommended output: 48 kHz / 24-bit.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Pre-emphasis", selection: model.configBinding(\.preemphasisUS)) {
                Text("Off (coder applies it)").tag(0)
                Text("50 us (EU)").tag(50)
                Text("75 us (US)").tag(75)
            }
            .pickerStyle(.segmented)
            Text("Exactly one device may apply pre-emphasis. If your stereo coder has none (or it is switched off), pick 50/75 us here so MPX Prime applies it. If the coder applies pre-emphasis, pick Off. Never both \u{2014} two stages in series over-deviate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("External coder has its own clipper",
                   isOn: model.configBinding(\.processedAudioCoderHasClipper, runtimeDisposition: .live))
                .help("Same one-stage rule as pre-emphasis, for clipping. Leave ON if your stereo coder clips/limits its own input. Turn OFF only if it does not \u{2014} then MPX Prime adds a final loudness clipper so the feed is denser. Two clippers in series sound harsh.")

            if !model.config.processedAudioCoderHasClipper {
                DoubleSliderRow(
                    title: "Final Clipper Drive",
                    value: model.configBinding(\.processedAudioFinalClipDriveDB, runtimeDisposition: .live),
                    range: 0...12,
                    format: "%.1f dB",
                    tooltip: "How hard the processed L/R is driven into MPX Prime's final loudness clipper. More drive = louder/denser but more clipping character. Start low and listen on a receiver.")
                Text("MPX Prime is applying a final loudness clipper to the processed-audio feed. Make sure your external coder is NOT also clipping the input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Form {
            Section("Configuration") {
                LabeledContent("Path") {
                    Text(model.configFilePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Button("Reveal Config") { model.revealConfigInFinder() }
                        .buttonStyle(.bordered)
                    Button("Reload Config") { model.reloadConfigFromDisk() }
                        .buttonStyle(.bordered)
                    Button("Refresh Devices") { model.refreshDevices() }
                        .buttonStyle(.bordered)
                }
            }

            Section("Interfaces") {
                InterfacesSettingsSectionContent(model: model)
            }

            Section("Output Mode") {
                OutputModeSettingsSectionContent(model: model)
            }

            Section("Audio Engine") {
                SystemSettingsSectionContent(model: model)
            }

            Section("Spectrum") {
                Toggle("96 kHz Window", isOn: model.configBinding(\.fftWindow96kHz))
                Text("When enabled, shows full 96 kHz spectrum. When disabled, shows the 60 kHz FM band.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remote Control") {
                Toggle(
                    "Enable REST API + Web Dashboard",
                    isOn: model.configBinding(\.controlEnabled, runtimeDisposition: .none)
                )
                .help("Serves a control API and web dashboard over HTTP. Applied at the next app launch.")
                LabeledContent("Address") {
                    TextField(
                        "127.0.0.1",
                        text: model.configBinding(\.controlBind, runtimeDisposition: .none)
                    )
                    .frame(maxWidth: 180)
                    .help("Interface to listen on. 127.0.0.1 = this Mac only; 0.0.0.0 = all interfaces (requires an API key).")
                }
                LabeledContent("Port") {
                    TextField(
                        "8737",
                        value: model.configBinding(\.controlPort, runtimeDisposition: .none),
                        format: .number.grouping(.never)
                    )
                    .frame(maxWidth: 100)
                    .help("TCP port for the control server (default 8737).")
                }
                LabeledContent("API Key") {
                    TextField(
                        "required for non-local access",
                        text: model.configBinding(\.controlAPIKey, runtimeDisposition: .none)
                    )
                    .frame(maxWidth: 260)
                    .help("Clients send this as 'Authorization: Bearer <key>' or 'X-API-Key'. Mandatory when the address is not 127.0.0.1; the server refuses to start remote-exposed without one.")
                }
                Text("Changes take effect at the next app launch. For access beyond the local network, front with a TLS reverse proxy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 920, alignment: .topLeading)
        .padding(.horizontal, 10)
        .controlSize(.small)
    }
}

private struct SettingsWindowView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingsSectionView(model: model)
            .navigationTitle("Settings")
    }
}

private enum HelpTopic: String, CaseIterable, Identifiable {
    case inputLevels = "Input Levels"
    case rdsText = "RDS Text Format"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .inputLevels: return "waveform.path.ecg"
        case .rdsText: return "dot.radiowaves.left.and.right"
        }
    }
}

private struct HelpWindowView: View {
    @State private var selection: HelpTopic = .inputLevels

    var body: some View {
        HSplitView {
            List(HelpTopic.allCases, selection: $selection) { topic in
                Label(topic.rawValue, systemImage: topic.icon)
                    .symbolRenderingMode(.hierarchical)
                    .tag(topic)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(selection.rawValue)
                        .font(.title3.weight(.semibold))
                    switch selection {
                    case .inputLevels:
                        HelpInputLevelsView()
                    case .rdsText:
                        HelpRDSTextView()
                    }
                }
                .padding(20)
                .frame(maxWidth: 860, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private func CodeBlock(_ text: String) -> some View {
    Text(text)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
}

private struct InlineRestartRequiredNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Restart Required")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}

private struct HelpInputLevelsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended operating targets for the current MPX Prime FM chain. Feed it clean, consistent program audio and let the processor create the final density.")
                .foregroundStyle(.secondary)
                .font(.callout)

            GroupBox {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Normal Peaks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("-6 to -3 dBFS")
                            .font(.body.weight(.semibold))
                    }
                    Divider().frame(height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Occasional Peaks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("up to -2 dBFS")
                            .font(.body.weight(.semibold))
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Text("Notes")
                .font(.headline)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("• US nominal input alignment: around -20 dBFS")
                Text("• Europe (EBU R68) style alignment: around -18 dBFS")
                Text("• Do not hold the source at -2 dBFS all the time")
                Text("• If the input already looks slammed, back it down and let the chain work")
                Text("• Wideband AGC is a platform leveler, not the final loudness stage")
                Text("• Final Drive is the main loudness control before the composite clipper")
                Text("• MPX Output Level is for final exciter or interface calibration")
                Text("• Levels are peak safety meters — judge loudness on a real receiver, not on the screen")
                Text("If you hit 0 dBFS, reduce input gain or Final Drive and re-check pre-emphasis behavior.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            Text("Restart-Required Settings")
                .font(.headline)
                .padding(.top, 4)

            InlineRestartRequiredNote(text: kRestartRequiredSettingsListText)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 860, alignment: .leading)
    }
}

private struct HelpRDSTextView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stereotool-compatible RDS text grammar for PS, Radiotext, PTYN, and Long PS. Existing Stereotool presets should load without modification.")
                .foregroundStyle(.secondary)
                .font(.callout)

            Text("Quick start")
                .font(.headline)
                .padding(.top, 4)

            CodeBlock("10s:First/10s:Second")

            Text("Shows \"First\" for 10 seconds, then \"Second\" for 10 seconds, repeating.")
                .foregroundStyle(.secondary)
                .font(.callout)

            // MARK: Timing

            Text("Timing prefixes")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `Ns:Text` — show `Text` for `N` seconds. Fractional accepted: `1.5s:Text`")
                Text("• `Nt:Text` — transmit-count. Show `Text` for `N` full transmissions of the field, then advance. Useful when you want the receiver to see the message a known number of times rather than for a fixed wall-clock duration.")
                Text("• Untimed text that fits in one chunk holds for 10 s before repeating.")
                Text("• Untimed text that splits into multiple chunks rotates at a default per-chunk duration. For PS, the default is the **PS Frame** slider in the RDS tab (default 3 s); for Radiotext / PTYN / Long PS, the default is 2.5 s.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            CodeBlock("""
1.5s:Short segment
3t:Transmit me three times/5s:Then this for 5 seconds
""")

            // MARK: Separators

            Text("Segment separators")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `/` separates segments at the top level. Escape as `\\/` to transmit a literal slash.")
                Text("• Inline whitespace-separated timed tokens also work: `1s:A 2s:B 3s:C` reads as three segments.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            // MARK: Scroll

            Text("Scrolling (PS only)")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `<Text` scrolls left, `>Text` scrolls right. Each marker advances by one character per full PS transmission.")
                Text("• Repeat the marker for faster scroll: `<<Text` moves two chars per tick, `<<<Text` three.")
                Text("• Scroll markers are parser-level only on Radiotext — RT transmits too slowly (~5.8 s per cycle) for scrolling to be useful.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            CodeBlock("<<MPX PRIME - FM BROADCAST ENCODER")

            // MARK: Escapes

            Text("Escaping special characters")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `\\<`  `\\>`  `\\|`  `\\:`  `\\/`  `\\\\` — transmit the special char literally instead of treating it as a marker.")
                Text("• `||` is accepted for Stereotool compatibility but is a no-op: word-wrap is always on.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            CodeBlock("Visit us\\: https\\://example.com/10s:Alt text")

            // MARK: External content

            Text("External content")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• `\\R\"path\"` — load file, force uppercase.")
                Text("• `\\r\"path\"` — load file, preserve case.")
                Text("• `\\F\"path\"` / `\\f\"path\"` — Stereotool-compatible aliases for `\\R` / `\\r`.")
                Text("• `\\w\"url\"` — fetch text from a URL. MPX Prime extension, not in Stereotool.")
                Text("File content re-enters the parser, so timing markers inside a loaded file are honored.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            // MARK: Now Playing

            Text("Now Playing macros (Radiotext)")
                .font(.headline)
                .padding(.top, 8)

            CodeBlock("""
Now: {now_playing}
{artist} - {title}
{title}
{date} {time}
""")

            VStack(alignment: .leading, spacing: 6) {
                Text("• `{now_playing}` and `{display}` use the script display text")
                Text("• `{artist}` and `{title}` are preferred for RT+ tagging")
                Text("• When the now-playing script is enabled, RT+ tags are derived from structured script output automatically")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            // MARK: Field limits

            Text("Field widths and transmission cadence")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("• PS is 8 chars wide. One full PS transmission = 4 group-0 blocks.")
                Text("• Radiotext 2A is 64 chars wide (16 segments); 2B is 32 chars (16 segments).")
                Text("• PTYN is 8 chars wide (2 segments).")
                Text("• Long PS is 32 chars wide (8 segments).")
                Text("• Overlong text is word-wrapped and cycled; chunks inherit their segment's timing.")
                Text("• In Mono Mode pilot and RDS are suppressed — transmitted RDS text is disabled until Mono Mode is turned off.")
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            // MARK: Examples

            Text("More examples")
                .font(.headline)
                .padding(.top, 8)

            CodeBlock("""
5s:MPX Prime - 5s:FM Coder
20s:Station Name/10s:Now Playing
8s:Tune to 88.5/8s:My Frequency
1.5s:Short/2t:Repeat Twice
<<MARQUEE TEXT
10s:Now\\: {artist} - {title}
\\R"~/Documents/station_name.txt"/10s:Static segment
""")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 860, alignment: .leading)
    }
}

/// macOS-style About panel (cf. Music.app / Final Cut): app icon, name,
/// a confident one-line description, version, then a compact highlight of
/// what the processor actually does — it ships a patent-grade chain, full
/// RDS, and a verification harness, so the About should say so rather than
/// undersell it. The full disclaimer is NOT restated here: README.md
/// (intended-use / not-certified) and LICENSE (GPL-3.0, no warranty) are
/// the single source of truth; the panel shows README's canonical key
/// phrase plus links to both.
private struct AboutSectionView: View {
    private var appIcon: NSImage? {
        if let icon = NSApp?.applicationIconImage, icon.size.width > 0 {
            return icon
        }
        return NSImage(named: NSImage.applicationIconName)
    }

    private struct Capability: Identifiable {
        let symbol: String
        let text: String
        var id: String { symbol }
    }

    private let capabilities: [Capability] = [
        Capability(
            symbol: "dot.radiowaves.right",
            text: "True FM stereo encoding — constant-amplitude pilot with post-clipper subcarrier injection"),
        Capability(
            symbol: "slider.horizontal.3",
            text: "Linear-phase multiband, look-ahead limiting, PrimeBass enhancement, pre-emphasis-aware HF clipping"),
        Capability(
            symbol: "waveform",
            text: "Differential composite clipper with cross-domain IM cancellation and BS.412 MPX-power control"),
        Capability(
            symbol: "antenna.radiowaves.left.and.right",
            text: "Full RDS encoder — PS, RadioText, RT+, AF, CT, PTY and Long PS, all live-apply"),
        Capability(
            symbol: "chart.bar.xaxis",
            text: "Real-time meters, scope and spectrum, plus offline receiver-model verification")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 12) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 4) {
                    Text("MPX Prime Studio")
                        .font(.title.weight(.semibold))
                    Text("Professional FM stereo processing and RDS encoding — free and open source")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Version \(AppConfig.appVersion) · GPL-3.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(capabilities) { cap in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: cap.symbol)
                                .font(.callout)
                                .foregroundStyle(.tint)
                                .frame(width: 20, alignment: .center)
                                .accessibilityHidden(true)
                            Text(cap.text)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

                HStack(spacing: 18) {
                    Link("View on GitHub", destination: kProjectURL)
                    Link("User Manual", destination: kManualURL)
                    Link("License", destination: kLicenseURL)
                }
                .font(.callout)

                // Single source of truth for the full disclaimer is README.md
                // (intended-use / not-certified) + LICENSE (GPL-3.0, no
                // warranty). The About only carries README's canonical key
                // phrase plus pointers — do not restate the full text here.
                Text("Experimental and not certified — no conformity or compliance is promised. See the README for intended use and the GPL-3.0 license for terms (provided without warranty).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                Text("Copyright © 2026 Bkram Developments")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct PendingApplyCard: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // Empty view — never shown
        EmptyView()

        // Or completely remove the if and Card, leaving just:
        // EmptyView()
    }
    //     if model.runtimeApplyPending {
    //         Card(title: "Apply Pending") {
    //             HStack {
    //                 Text("Changes were saved. Restart runtime to apply them to audio output.")
    //                     .foregroundStyle(.secondary)
    //                 Spacer()
    //                 Button("Apply Now") {
    //                     model.applyPendingRuntimeChanges()
    //                 }
    //                 .buttonStyle(.borderedProminent)
    //             }
    //         }
    //         .hidden()
    //     }
}

// Conditional `.help()` so an empty/nil tooltip does not clear tooltips set
// elsewhere in the subtree — SwiftUI interprets `.help("")` as "remove help".
private struct TooltipIfPresent: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text = text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

/// Compact "restart-required" affordance. Sits next to a control whose
/// change does not apply live (the engine must stop/restart). Matches the
/// pending-restart status chip's icon so the two read as the same concept.
/// Module-visible so the stage inspector can reuse it.
struct RestartBadge: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.caption2)
            .foregroundStyle(BroadcastStyle.tightAmber)
            .help("Restart-required: this setting takes effect only after the engine restarts (use Apply Restart). Changing it while running marks a pending restart in the header.")
            .accessibilityLabel("Restart required")
    }
}

private struct DoubleSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var accessibilityLabel: String?
    var tooltip: String?
    var restartRequired: Bool = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Slider(value: $value, in: range)
                    .controlSize(.small)
                    .accessibilityLabel(accessibilityLabel ?? title)
                    // VoiceOver otherwise reads the slider as a bare 0-100%;
                    // surface the real unit-bearing readout instead.
                    .accessibilityValue(Text(String(format: format, value)))
                Text(String(format: format, value))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
            // Attach on the interactive HStack so hovering the slider /
            // readout fires the tooltip reliably (LabeledContent alone does
            // not always forward `.help()` to its content on macOS 15).
            .contentShape(Rectangle())
            .modifier(TooltipIfPresent(text: tooltip))
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if restartRequired { RestartBadge() }
            }
        }
        .contentShape(Rectangle())
        .modifier(TooltipIfPresent(text: tooltip))
    }
}

private struct IntStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let format: String
    var tooltip: String?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                    // labelsHidden() drops the visual label; restore an
                    // explicit name + the unit-bearing value for VoiceOver.
                    .accessibilityLabel(title)
                    .accessibilityValue(Text(String(format: format, value)))
                Text(String(format: format, value))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 180, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .modifier(TooltipIfPresent(text: tooltip))
        }
        .contentShape(Rectangle())
        .modifier(TooltipIfPresent(text: tooltip))
    }
}

struct ScopesOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel
    private let scopeTimebasesMS: [Double] = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0]

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                MonitoringWindowHeader(
                    title: kScopesWindowTitle,
                    subtitle: "Stereo input and MPX output waveforms."
                )
                Spacer(minLength: 16)
                LabeledContent("Window") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.scopeTimebaseMS },
                            set: { model.scopeTimebaseMS = $0 }
                        )
                    ) {
                        ForEach(scopeTimebasesMS, id: \.self) { ms in
                            Text("\(Int(ms)) ms").tag(ms)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Toggle(
                    "Auto Gain",
                    isOn: Binding(
                        get: { model.scopeAutoGainEnabled },
                        set: { model.scopeAutoGainEnabled = $0 }
                    )
                )
                .toggleStyle(.switch)
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stereo Input").font(.subheadline).foregroundStyle(.secondary)
                    LiveObservationView(telemetry: model.telemetry) { t in
                        ScopeView(samples: t.inputScopeLeft, secondarySamples: t.inputScopeRight)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("MPX Output").font(.subheadline).foregroundStyle(.secondary)
                    LiveObservationView(telemetry: model.telemetry) { t in
                        ScopeView(samples: t.outputScope)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(
                model.scopeAutoGainEnabled ? "Auto gain enabled." : "Fixed vertical scale: ±1.0"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom)
        }
        .padding()
    }
}

struct SpectrumOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(spacing: 16) {
            MonitoringWindowHeader(
                title: kMPXSpectrumWindowTitle,
                subtitle: "Composite spectrum after stereo encoding."
            )
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                LiveObservationView(telemetry: model.telemetry) { t in
                    MPXSpectrumView(
                        dbBins: t.mpxSpectrumDB,
                        maxHz: t.mpxSpectrumMaxHz,
                        nyquistHz: t.mpxSpectrumNyquistHz,
                        showBandLabels: true
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
        .frame(minWidth: 600, minHeight: 300)
    }
}

struct PreMPXSpectrumOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MonitoringWindowHeader(
                title: kAudioSpectrumWindowTitle,
                subtitle: "Raw stereo input spectrum before processing."
            )

            LiveObservationView(telemetry: model.telemetry) { t in
                StereoPreMPXSpectrumView(
                    leftBins: t.preMPXSpectrumLeftDB,
                    rightBins: t.preMPXSpectrumRightDB,
                    maxHz: t.preMPXSpectrumMaxHz,
                    nyquistHz: t.preMPXSpectrumNyquistHz
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 300)
    }
}

private struct StereoPreMPXSpectrumView: View {
    let leftBins: [Float]
    let rightBins: [Float]
    let maxHz: Double
    let nyquistHz: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                AudioBarSpectrumView(
                    dbBins: leftBins,
                    maxHz: maxHz,
                    nyquistHz: nyquistHz
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                AudioBarSpectrumView(
                    dbBins: rightBins,
                    maxHz: maxHz,
                    nyquistHz: nyquistHz
                )
            }

            HStack {
                Spacer()
                Text("Tap: raw stereo input before processing")
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
        }
    }
}

#endif  // os(macOS)
