import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Sizes
private let kWindowWidth: CGFloat = 860
private let kWindowHeight: CGFloat = 440
private let kWindowMinWidth: CGFloat = 760
private let kWindowMinHeight: CGFloat = 380
private let kLevelsWindowWidth: CGFloat = 860
private let kLevelsWindowHeight: CGFloat = 560
private let kLevelsWindowMinWidth: CGFloat = 760
private let kLevelsWindowMinHeight: CGFloat = 500
private let kMPXPrimeIconSymbol = "\u{1F3A7}"
private let kScopesWindowTitle = "Scopes"
private let kMPXSpectrumWindowTitle = "MPX Spectrum"
private let kAudioSpectrumWindowTitle = "Audio Spectrum"
private let kLevelsWindowTitle = "Levels"
private let kMainWindowAutosaveName = "MPXPrime.MainWindow"
private let kScopesWindowAutosaveName = "MPXPrime.ScopesWindow"
private let kSpectrumWindowAutosaveName = "MPXPrime.SpectrumWindow"
private let kPreMPXSpectrumWindowAutosaveName = "MPXPrime.PreMPXSpectrumWindow"
private let kLevelsWindowAutosaveName = "MPXPrime.LevelsWindow"
private let kAboutWindowAutosaveName = "MPXPrime.AboutWindow"
private let kHelpWindowAutosaveName = "MPXPrime.HelpWindow"
private let kSettingsWindowAutosaveName = "MPXPrime.SettingsWindow"
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
        NSColor(calibratedRed: 0.04, green: 0.16, blue: 0.28, alpha: 1.0),
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
        .shadow: shadowStyle,
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
    case dcClipper = "DC Clipper"
    case limiter = "Audio Limiter"
    case compositeClipper = "Comp Clip"
    case bs412 = "BS.412"
    case finalStage = "Final Stage"

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
            return "Bass enhancement via MaxxBass-style harmonic synthesis (US 5,930,373, expired) plus dynamic envelope extension (US 5,359,665). Adds perceived bass while reducing true-peak LF amplitude — saves headroom downstream."
        case .bassClipper:
            return "4x oversampled clipper targeting LF transients before the chain. Useful when PrimeBass / multiband still leave kicks pushing into downstream limiters."
        case .dcClipper:
            return "8x oversampled distortion-cancelled clipper on the audio band (Orban US 4,460,871 / US 5,737,434, expired). Cleans up audio-band peaks before pre-emphasis adds HF boost."
        case .limiter:
            return "Pre-encode L/R peak limiter — 4x oversampled true-peak, stereo-linked — with default-on look-ahead and Dolby HF-subband detector (US 5,579,404, expired 2013). Catches HF transients that slip past everything upstream after pre-emphasis."
        case .bs412:
            return "ITU-R BS.412 rolling-average MPX power limiter for European regulatory compliance (DE / AT / CH / SE / CZ / SI). Slow gain ride over a ~60 s window. Off in NL, US, UK, FR, ES, IT and most other countries."
        case .compositeClipper:
            return "16x oversampled differential composite clipper (Orban US 6,337,999, expired 2022) on the assembled MPX composite. Protects pilot / stereo / RDS guard bands from clipper IM via delta-based per-band substitution. Primary loudness lever."
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
            return "Reset DC Clipper Tab"
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
            return "Reset DC clipper tab to defaults"
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

/// Unified flat selection used by the new NavigationSplitView sidebar.
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
        case .processingDCClipper: return "DC Clipper"
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
        case .snapshots: return "Snapshots"
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
        case .processingDCClipper: return "Distortion-cancelled audio clipper"
        case .processingLimiter: return "Pre-encode peak limiter on L/R audio (4x oversampled)"
        case .processingBS412: return "ITU-R BS.412 MPX power limiter"
        case .processingCompositeClipper: return "8x oversampled composite clipper"
        case .processingFinalStage: return "Final drive, MPX safety, budget, deviation"
        case .rdsControl: return "Master enable + live snapshot of what's on air"
        case .rdsProgram: return "Identification: PI, PTY, PTYN, ECC, PS banks, runtime flags"
        case .rdsRadiotext: return "Radiotext + RT+ tagging"
        case .rdsLongPS: return "32-character Long PS (15A)"
        case .rdsAF: return "Alternative frequencies (AF)"
        case .rdsSchedule: return "Group sequence, scheduler policy, clock"
        case .rdsCarrier: return "Injection level, subcarrier frequency, Gaussian shaping"
        case .testTone: return "Sine, pink, or white — replaces audio input when enabled"
        case .snapshots: return "Named save / recall slots for the full configuration"
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

private final class MPXSpectrumAnalyzer: @unchecked Sendable {
    private var fftSetup: FFTSetup?
    private var fftLog2: vDSP_Length = 0
    private var window: [Float] = []
    private var signal: [Float] = []
    private var windowed: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var magnitudesSq: [Float] = []
    private var spectrumDB: [Float] = []
    private var mapped: [Float] = []

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func compute(
        samples: [Float],
        validCount: Int,
        sampleRate: Double,
        displayBins: Int,
        maxDisplayHz: Double
    ) -> (dbBins: [Float], maxHz: Double, nyquistHz: Double) {
        let safeBins = max(64, displayBins)
        let nyquist = max(1_000.0, sampleRate * 0.5)
        let maxHz = max(1_000.0, maxDisplayHz)
        let sampleCount = min(samples.count, max(0, validCount))
        guard sampleCount >= 256 else {
            return (Array(repeating: -100.0, count: safeBins), maxHz, nyquist)
        }

        let maxFFTSize = min(sampleCount, 8192)
        let log2n = Int(floor(log2(Double(maxFFTSize))))
        let n = max(256, 1 << log2n)
        prepareBuffers(fftSize: n, displayBins: safeBins)

        signal.withUnsafeMutableBufferPointer { buffer in
            samples.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress, let destinationBase = buffer.baseAddress else { return }
                let start = sampleCount - n
                destinationBase.update(from: sourceBase.advanced(by: start), count: n)
            }
        }

        var mean: Float = 0.0
        vDSP_meanv(signal, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        vDSP_vsadd(signal, 1, &negMean, &signal, 1, vDSP_Length(n))
        vDSP_vmul(signal, 1, window, 1, &windowed, 1, vDSP_Length(n))

        guard let fftSetup else {
            return (Array(repeating: -100.0, count: safeBins), maxHz, nyquist)
        }

        real.withUnsafeMutableBufferPointer { realBP in
            imag.withUnsafeMutableBufferPointer { imagBP in
                var split = DSPSplitComplex(realp: realBP.baseAddress!, imagp: imagBP.baseAddress!)
                windowed.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexSrc in
                        vDSP_ctoz(complexSrc, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2, FFTDirection(FFT_FORWARD))
                // Apple's real-input FFT packs DC into split.realp[0]
                // and Nyquist into split.imagp[0] to save one slot.
                // Without untangling them, vDSP_zvmags would compute
                // magnitudesSq[0] = DC² + Nyquist² and the leftmost
                // display bin would render Nyquist energy (because we
                // already remove DC pre-FFT via vDSP_meanv + vDSP_vsadd).
                // Zero the Nyquist slot before the magnitude pass so
                // bin 0 holds clean DC². Nyquist is ignored for display
                // — the highest visible bin is at index n/2-1, just
                // below Nyquist.
                imagBP[0] = 0
                vDSP_zvmags(&split, 1, &magnitudesSq, 1, vDSP_Length(n / 2))
            }
        }

        // Calibrated amplitude: divide by N (FFT length) to undo the
        // un-normalised forward transform, then divide by the window's
        // coherent gain so a 0 dBFS sine through a Hann window reads as
        // 0 dB on the display. vDSP_HANN_NORM produces a normalised
        // Hann window with sum = N/2, i.e. coherent gain = 0.5. The
        // factor of 2 on non-DC bins accounts for the one-sided
        // spectrum (energy from the conjugate bin).
        let invN = 1.0 / Float(n)
        let hannCG: Float = 0.5
        let cgScale = invN / hannCG
        if !magnitudesSq.isEmpty {
            let dcAmp = sqrtf(max(0.0, magnitudesSq[0])) * cgScale
            spectrumDB[0] = max(-100.0, min(0.0, 20.0 * log10f(max(1e-9, dcAmp))))
        }
        if magnitudesSq.count > 1 {
            for k in 1..<magnitudesSq.count {
                let amp = (2.0 * sqrtf(max(0.0, magnitudesSq[k]))) * cgScale
                spectrumDB[k] = max(-100.0, min(0.0, 20.0 * log10f(max(1e-9, amp))))
            }
        }

        let sourceCount = max(1, spectrumDB.count)
        for i in 0..<safeBins {
            let ratio = safeBins > 1 ? (Double(i) / Double(safeBins - 1)) : 0.0
            let freq = ratio * maxHz
            if freq > nyquist {
                mapped[i] = -100.0
                continue
            }
            let srcPos = (freq / nyquist) * Double(sourceCount - 1)
            let i0 = max(0, min(sourceCount - 1, Int(srcPos.rounded(.down))))
            let i1 = max(0, min(sourceCount - 1, i0 + 1))
            let frac = Float(srcPos - Double(i0))
            let a = spectrumDB[i0]
            let b = spectrumDB[i1]
            mapped[i] = a + ((b - a) * frac)
        }
        return (mapped, maxHz, nyquist)
    }

    private func prepareBuffers(fftSize: Int, displayBins: Int) {
        let requiredLog2 = vDSP_Length(log2(Double(fftSize)))
        if fftLog2 != requiredLog2 || fftSetup == nil {
            if let fftSetup {
                vDSP_destroy_fftsetup(fftSetup)
            }
            fftSetup = vDSP_create_fftsetup(requiredLog2, FFTRadix(kFFTRadix2))
            fftLog2 = requiredLog2
        }

        if window.count != fftSize {
            window = Array(repeating: 0.0, count: fftSize)
            signal = Array(repeating: 0.0, count: fftSize)
            windowed = Array(repeating: 0.0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        }

        let halfSize = fftSize / 2
        if real.count != halfSize {
            real = Array(repeating: 0.0, count: halfSize)
            imag = Array(repeating: 0.0, count: halfSize)
            magnitudesSq = Array(repeating: 0.0, count: halfSize)
            spectrumDB = Array(repeating: -100.0, count: halfSize)
        }

        if mapped.count != displayBins {
            mapped = Array(repeating: -100.0, count: displayBins)
        }
    }
}

private struct PrimeBassPreset {
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

private struct WidenerPreset {
    let id: String
    let title: String
    let stereoWidenEnabled: Bool
    let monoBassEnabled: Bool
    let monoBassFreqHz: Double
    let width: Double
    let center: Double
    let mix: Double
}

private struct MultibandPreset {
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
        let host = NSHostingView(rootView: root)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.center()
        w.title = "MPX Prime"
        w.titleVisibility = .visible
        w.minSize = NSSize(width: 900, height: 620)
        w.delegate = self
        restoreFrame(for: w, autosaveName: kMainWindowAutosaveName)
        w.contentView = host
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
        return true
    }

    private func setupMainMenu() {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "MPX Prime"
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
        
        let mainWindowItem = windowMenu.addItem(withTitle: "Main", action: #selector(showMainWindow), keyEquivalent: "1")
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
        
        let openHelp = NSMenuItem(title: "MPX Prime Help", action: #selector(showHelp), keyEquivalent: "/")
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
        w.title = "About MPX Prime"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 360, height: 460))
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
        w.title = "MPX Prime Help"
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
        NSWorkspace.shared.open(URL(string: "https://github.com/bkram/MPXPrime")!)
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
        let host = NSHostingView(rootView: root)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.center()
        w.title = "MPX Prime"
        w.titleVisibility = .visible
        w.minSize = NSSize(width: 900, height: 620)
        w.delegate = self
        restoreFrame(for: w, autosaveName: kMainWindowAutosaveName)
        w.contentView = host
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc fileprivate func showScopesWindow() {
        if let existing = scopesWindow {
            revealWindow(existing)
            model?.scopesWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let scopesView = ScopesOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: scopesView)
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

    @objc fileprivate func showSpectrumWindow() {
        if let existing = spectrumWindow {
            revealWindow(existing)
            model?.spectrumWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let spectrumView = SpectrumOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: spectrumView)
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

    @objc private func showPreMPXSpectrumWindow() {
        if let existing = preMPXSpectrumWindow {
            revealWindow(existing)
            model?.preMPXSpectrumWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let spectrumView = PreMPXSpectrumOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: spectrumView)
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

    @objc private func showLevelsWindow() {
        if let existing = levelsWindow {
            revealWindow(existing)
            model?.levelsWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let levelsView = LevelsOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: levelsView)
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

    @objc private func openConfig() {
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
               selectedProcessingTab != pt
            {
                selectedProcessingTab = pt
            }
            if let rt = selectedStage.legacyRDSTab,
               selectedRDSTab != rt
            {
                selectedRDSTab = rt
            }
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
    @Published var pendingRuntimeApply: Bool = false

    // Named snapshot slots — persistent operator-saved setups beyond
    // format profiles. Stored on disk as JSON alongside the INI; survive
    // app upgrades. 8 fixed slots; nil = empty. Operator names each save
    // ("Morning Show", "Saturday Night", "Live Sports").
    @Published var snapshots: [ConfigSnapshot?] = Array(repeating: nil, count: MPXPrimeViewModel.snapshotSlotCount)

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

    // A/B compare workspace. In-memory only — not persisted across app
    // launches. Operator captures the current config to slot A, tunes,
    // captures to slot B, then taps the swap to alternate between them
    // while listening. Pro workflow standard (Optimod / Stereotool / Omnia
    // all have this). Tweaks while a slot is loaded are EPHEMERAL — the
    // operator must re-capture to save changes into a slot. Swap restores
    // the captured snapshot wholesale.
    @Published var compareSlotA: AppConfig? = nil
    @Published var compareSlotB: AppConfig? = nil
    /// Identifies which slot is currently loaded, "a" or "b", or nil if
    /// neither was ever captured. After the most recent capture the
    /// captured slot is the active one; after a swap the just-loaded
    /// slot becomes active.
    @Published var compareActiveSlot: String? = nil

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
    @Published var runtimeText: String = "Not running"
    @Published var inputRingText: String = "Input ring: n/a"
    @Published var inputBufferValue: Double = 0.0
    @Published var inputBufferMax: Double = 1.0
    @Published var inputBufferWarning: Double = 0.7
    @Published var inputBufferCritical: Double = 0.9
    /// Low-passed (~10 s time constant) version of `inputBufferValue /
    /// inputBufferMax`. Used by the Monitoring buffer-fill bar so the
    /// display shows trend rather than tick-by-tick wobble; raw
    /// `inputBufferValue` keeps its 30 Hz cadence for any logic that
    /// needs the instantaneous reading.
    @Published var bufferFillSmoothed: Double = 0.0
    @Published var streamHealth: MonitoringStreamHealth = .stopped

    @Published var inputLLevel: Double = 0.0
    @Published var inputRLevel: Double = 0.0
    @Published var agcOutputLLevel: Double = 0.0
    @Published var agcOutputRLevel: Double = 0.0
    @Published var outputLevel: Double = 0.0
    @Published var modulationLevel: Double = 0.0
    @Published var inputLPeakHoldLevel: Double = 0.0
    @Published var inputRPeakHoldLevel: Double = 0.0
    @Published var agcOutputLPeakHoldLevel: Double = 0.0
    @Published var agcOutputRPeakHoldLevel: Double = 0.0
    @Published var outputPeakHoldLevel: Double = 0.0
    @Published var modulationPeakHoldLevel: Double = 0.0
    @Published var stickyPeaksEnabled: Bool = true
    @Published var meterPeakHoldSeconds: Double = 1.5
    @Published var meterPeakFallDBPerSecond: Double = 18.0

    @Published var inputLText: String = "-inf dBFS"
    @Published var inputRText: String = "-inf dBFS"
    @Published var agcOutputLText: String = "-inf dBFS"
    @Published var agcOutputRText: String = "-inf dBFS"
    @Published var outputText: String = "-inf dBFS"
    @Published var modulationText: String = "0.0 kHz"

    @Published var limiterStateText: String = "Off"
    @Published var limiterDetailText: String = "Drive 0.0 dB • GR 0.0 dB • Safe 0.0 dB • Peak -inf dBFS"
    @Published var compositeBudgetStateText: String = "Off"
    @Published var compositeCalibrationText: String = "Pilot 0.0% • RDS 0.0% • Audio -inf dBFS • Margin 0.0 dB"
    @Published var estimatedDeviationPeakKHz: Float = 0.0
    @Published var pilotInjectionPercentValue: Float = 0.0
    @Published var rdsInjectionPercentValue: Float = 0.0
    @Published var audioCompositePeakLinear: Float = 0.0
    @Published var compositeBudgetMarginDBValue: Float = 0.0
    /// Post-injection overshoot envelope (from `CompositeCalibrationStatus`).
    /// Non-zero ⇒ pilot/RDS subcarriers are clipping at the final
    /// ±1.0 clamp because audio + subcarrier × outputGain exceeds
    /// budget. UI surfaces this as an over-budget warning so the
    /// operator can reduce outputGain / pilot / RDS levels.
    @Published var postInjectionOvershootValue: Float = 0.0
    /// True when the composite budget governor has muted the audio
    /// path — outputGain × subcarrier reservation left no headroom.
    @Published var compositeOverBudget: Bool = false
    @Published var compositeClipperGainReductionDBValue: Float = 0.0
    @Published var compositeClipperLookaheadGainReductionDBValue: Float = 0.0
    @Published var preEncodeLimiterGainReductionDBValue: Float = 0.0
    @Published var safetyLimiterGainReductionDBValue: Float = 0.0
    @Published var stereoImageText: String = "Corr +1.00 • Side 0.00x"
    @Published var agcStateText: String = "Off"
    @Published var agcDetailText: String = "Detector -inf dB • Gain 0.0 dB"
    @Published var multibandStateText: String = "Off"
    @Published var primeBassStateText: String = "Off"
    @Published var widenerStateText: String = "Off"

    @Published var rdsPS: String = "-"
    @Published var rdsPI: String = "-"
    @Published var rdsPTY: String = "-"
    @Published var rdsPTYN: String = "-"
    @Published var rdsAID: String = "AID: OFF"
    @Published var rdsLongPS: String = "-"
    @Published var rdsRadiotext: String = "-"
    @Published var rdsNowPlayingStatus: String = "Now Playing: off"

    @Published var inputScopeLeft: [Float] = Array(repeating: 0.0, count: 128)
    @Published var inputScopeRight: [Float] = Array(repeating: 0.0, count: 128)
    @Published var outputScope: [Float] = Array(repeating: 0.0, count: 128)
    @Published var scopeTimebaseMS: Double = 10.0
    @Published var scopeAutoGainEnabled: Bool = true
    @Published var mpxSpectrumDB: [Float] = Array(repeating: -100.0, count: 512)
    @Published var mpxSpectrumMaxHz: Double = 92_000.0
    @Published var mpxSpectrumNyquistHz: Double = 0.0
    @Published var scopesWindowVisible: Bool = false
    @Published var spectrumWindowVisible: Bool = false
    @Published var preMPXSpectrumLeftDB: [Float] = Array(repeating: -100.0, count: 128)
    @Published var preMPXSpectrumRightDB: [Float] = Array(repeating: -100.0, count: 128)
    @Published var preMPXSpectrumMaxHz: Double = 16_000.0
    @Published var preMPXSpectrumNyquistHz: Double = 0.0
    @Published var preMPXSpectrumWindowVisible: Bool = false
    @Published var levelsWindowVisible: Bool = false

    private let configPath: String
    private let nowPlayingState: NowPlayingState
    private let nowPlayingRunner: NowPlayingScriptRunner
    var config: AppConfig
    private var runningEngine: AudioOutputEngine?
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
        Self.ptyNames.enumerated().map { ($0.offset, $0.element) }
    }

    var primeBassPresetChoices: [PresetChoice] {
        Self.primeBassPresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var widenerPresetChoices: [PresetChoice] {
        [PresetChoice(id: "custom", title: "Custom")]
            + Self.widenerPresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var multibandPresetChoices: [PresetChoice] {
        Self.multibandPresets.map { PresetChoice(id: $0.id, title: $0.title) }
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
            ("Now Playing", rdsNowPlayingStatus.replacingOccurrences(of: "Now Playing: ", with: "")),
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
            selectedInputUID = selectUID(preferred: config.inputDeviceUID, from: inputDevices)
            selectedOutputUID = selectUID(preferred: config.outputDeviceUID, from: outputDevices)
            selectedMonitorUID = selectUID(preferred: config.monitorDeviceUID, from: outputDevices)
        } catch {
            statusText = "Device scan failed: \(error)"
            inputDevices = []
            outputDevices = []
            selectedInputUID = ""
            selectedOutputUID = ""
            selectedMonitorUID = ""
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

    /// Snapshot the current config into the named slot (`"a"` or `"b"`).
    /// Marks that slot active. Tweaks made after this point are
    /// ephemeral until the slot is re-captured.
    func captureCurrentToCompareSlot(_ slot: String) {
        publishConfigChange()
        let snapshot = config
        switch slot {
        case "a":
            compareSlotA = snapshot
            compareActiveSlot = "a"
            statusText = "Captured current state as A."
        case "b":
            compareSlotB = snapshot
            compareActiveSlot = "b"
            statusText = "Captured current state as B."
        default:
            return
        }
    }

    /// Swap to the other captured slot. No-op when only one slot is
    /// captured. Applies the loaded config via the existing save +
    /// live-apply path so live-applicable fields take effect
    /// immediately and restart-required fields surface the usual
    /// pending-apply prompt.
    func swapCompareSlot() {
        guard compareSlotA != nil, compareSlotB != nil else { return }
        publishConfigChange()
        if compareActiveSlot == "a", let next = compareSlotB {
            config = next
            compareActiveSlot = "b"
            statusText = "Compare: switched to B."
        } else if let next = compareSlotA {
            config = next
            compareActiveSlot = "a"
            statusText = "Compare: switched to A."
        }
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
    }

    /// Drop both captured slots.
    func clearCompareSlots() {
        compareSlotA = nil
        compareSlotB = nil
        compareActiveSlot = nil
        statusText = "A/B compare slots cleared."
    }

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
        } catch {
            statusText = "Failed to load snapshots: \(error.localizedDescription)"
        }
    }

    /// Persist all slots to disk. JSON envelope wraps the per-slot
    /// `ConfigSnapshot` objects (which embed the config as INI text so
    /// schema migrations stay handled by the existing INI parser's
    /// defaults).
    func writeSnapshotsToDisk() {
        let file = SnapshotFile(slots: snapshots)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(
                to: URL(fileURLWithPath: snapshotsFilePath), options: [.atomic])
        } catch {
            statusText = "Failed to write snapshots: \(error.localizedDescription)"
        }
    }

    /// Capture the current config into slot `slot` with the given name
    /// (empty → "Snapshot N"). Writes the file immediately so a crash
    /// doesn't lose the operator's save.
    func saveSnapshot(slot: Int, name: String) {
        guard (0..<snapshots.count).contains(slot) else { return }
        publishConfigChange()
        do {
            let ini = try config.captureAsINIString()
            let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshots[slot] = ConfigSnapshot(
                id: UUID(),
                name: resolvedName.isEmpty ? "Snapshot \(slot + 1)" : resolvedName,
                savedAt: Date(),
                configINIText: ini
            )
            writeSnapshotsToDisk()
            statusText = "Saved snapshot to slot \(slot + 1)."
        } catch {
            statusText = "Failed to save snapshot: \(error.localizedDescription)"
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
            statusText = "Loaded snapshot \"\(snapshot.name)\"."
        } catch {
            statusText = "Failed to load snapshot: \(error.localizedDescription)"
        }
    }

    /// Drop the snapshot in `slot` and persist the empty state.
    func clearSnapshot(slot: Int) {
        guard (0..<snapshots.count).contains(slot) else { return }
        snapshots[slot] = nil
        writeSnapshotsToDisk()
        statusText = "Cleared snapshot slot \(slot + 1)."
    }

    /// Rename an existing snapshot in place (doesn't touch the stored
    /// config text — just the operator-facing label). Persists on
    /// every keystroke; the operator gets immediate save semantics
    /// without an explicit confirm button.
    func renameSnapshot(slot: Int, name: String) {
        guard (0..<snapshots.count).contains(slot),
              var snapshot = snapshots[slot] else { return }
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.name = resolvedName.isEmpty ? "Snapshot \(slot + 1)" : resolvedName
        snapshots[slot] = snapshot
        writeSnapshotsToDisk()
    }

    // MARK: - Signal Flow Strip live GR

    /// Returns the current GR in dB for stages that the strip has live
    /// telemetry for, or nil for stages without dynamics (EQ-only, phase
    /// rotation, bass enhancement) or for stages whose GR isn't yet
    /// surfaced on the view model. Used by `SignalFlowStrip` to draw a
    /// small GR fill bar inside each chip — chip stays the same width;
    /// the bar grows as gain reduction increases.
    func signalFlowGR(for stage: Stage) -> Float? {
        switch stage {
        case .processingLimiter:
            return preEncodeLimiterGainReductionDBValue
        case .processingCompositeClipper:
            return max(
                compositeClipperGainReductionDBValue,
                compositeClipperLookaheadGainReductionDBValue
            )
        case .processingFinalStage:
            return safetyLimiterGainReductionDBValue
        default:
            return nil
        }
    }

    /// One-line description of the currently selected format profile,
    /// or a fallback string if the stored ID doesn't match any known
    /// profile (operator typed a custom value into INI).
    var currentFormatProfileSummary: String {
        Self.formatProfile(forID: config.formatProfileID)?.summary
            ?? "Custom (no matching format profile)."
    }

    func applyPrimeBassPreset(id: String) {
        guard let preset = Self.primeBassPresets.first(where: { $0.id == id }) else { return }
        publishConfigChange()
        config.primeBassEnabled = preset.enabled
        config.primeBassPresetID = id
        config.primeBassAmount = preset.amount
        config.primeBassFreqHz = preset.freqHz
        config.primeBassHarmonics = preset.harmonics
        config.primeBassDrive = preset.drive
        config.primeBassDensity = preset.density
        config.primeBassSubharmonicsEnabled = preset.subharmonicsEnabled
        config.primeBassSubharmonicsAmount = preset.subharmonicsAmount
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded PrimeBass preset \(preset.title) live."
            : "Loaded PrimeBass preset \(preset.title)."
    }

    var currentWidenerPresetID: String {
        guard let preset = Self.widenerPresets.first(where: {
            $0.stereoWidenEnabled == config.stereoWidenEnabled
                && $0.monoBassEnabled == config.monoBassEnabled
                && Self.approxEqual($0.monoBassFreqHz, config.monoBassFreqHz)
                && Self.approxEqual($0.width, config.stereoWidenWidth)
                && Self.approxEqual($0.center, config.stereoWidenCenter)
                && Self.approxEqual($0.mix, config.stereoWidenMix)
        }) else {
            return "custom"
        }
        return preset.id
    }

    func applyWidenerPreset(id: String) {
        guard let preset = Self.widenerPresets.first(where: { $0.id == id }) else { return }
        publishConfigChange()
        config.stereoWidenEnabled = preset.stereoWidenEnabled
        config.monoBassEnabled = preset.monoBassEnabled
        config.monoBassFreqHz = preset.monoBassFreqHz
        config.stereoWidenWidth = preset.width
        config.stereoWidenCenter = preset.center
        config.stereoWidenMix = preset.mix
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded image preset \(preset.title) live."
            : "Loaded image preset \(preset.title)."
    }

    func applyMultibandPreset(id: String, intensity: MultibandPresetIntensity) {
        guard let preset = Self.multibandPresets.first(where: { $0.id == id }) else { return }
        publishConfigChange()

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
        if let x1Hz = preset.x1Hz {
            config.multibandX1Hz = x1Hz
        }
        if let x2Hz = preset.x2Hz {
            config.multibandX2Hz = x2Hz
        }
        if let x3Hz = preset.x3Hz {
            config.multibandX3Hz = x3Hz
        }
        if let x4Hz = preset.x4Hz {
            config.multibandX4Hz = x4Hz
        }

        config.multibandLowThresholdDB = Self.clamp(
            preset.lowThresholdDB + intensity.thresholdDbOffset,
            min: -36.0,
            max: -6.0
        )
        config.multibandMidThresholdDB = Self.clamp(
            preset.midThresholdDB + intensity.thresholdDbOffset,
            min: -36.0,
            max: -6.0
        )
        config.multibandHighThresholdDB = Self.clamp(
            preset.highThresholdDB + intensity.thresholdDbOffset,
            min: -36.0,
            max: -6.0
        )

        config.multibandLowRatio = Self.clamp(
            preset.lowRatio * intensity.ratioMul, min: 1.0, max: 4.0)
        config.multibandMidRatio = Self.clamp(
            preset.midRatio * intensity.ratioMul, min: 1.0, max: 4.0)
        config.multibandHighRatio = Self.clamp(
            preset.highRatio * intensity.ratioMul, min: 1.0, max: 4.0)

        config.multibandLowAttackMS = Self.clamp(
            preset.lowAttackMS * intensity.attackMul, min: 1.0, max: 200.0)
        config.multibandMidAttackMS = Self.clamp(
            preset.midAttackMS * intensity.attackMul, min: 1.0, max: 200.0)
        config.multibandHighAttackMS = Self.clamp(
            preset.highAttackMS * intensity.attackMul, min: 1.0, max: 200.0)

        config.multibandLowReleaseMS = Self.clamp(
            preset.lowReleaseMS * intensity.releaseMul, min: 50.0, max: 1000.0)
        config.multibandMidReleaseMS = Self.clamp(
            preset.midReleaseMS * intensity.releaseMul, min: 50.0, max: 1000.0)
        config.multibandHighReleaseMS = Self.clamp(
            preset.highReleaseMS * intensity.releaseMul, min: 50.0, max: 1000.0)

        config.multibandKneeDB = preset.kneeDB
        config.multibandLinkStrength = preset.linkStrength
        config.multibandReleaseProgramDependent = preset.releaseProgramDependent

        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded Multiband preset \(preset.title) (\(intensity.title)) live."
            : "Loaded Multiband preset \(preset.title) (\(intensity.title))."
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
             .bassClipper, .dcClipper, .limiter,
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

        let selectedOutUID = monitorEnabled ? selectedMonitorUID : selectedOutputUID
        let outputID: AudioDeviceID? = outputDevices.first(where: { $0.uid == selectedOutUID })?.id
        let outputMode: AudioOutputMode = monitorEnabled ? .monitorAudio : .mpxComposite

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
            activeRuntimeSnapshot = captureRuntimeSnapshot()
            engineStartReference = Date().timeIntervalSinceReferenceDate
            let mode = monitorEnabled ? "monitor" : "output"
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
        modulationText = String(format: "%.1f kHz", deviationKHz)
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
        limiterStateText = limiterState
        limiterDetailText = String(
            format: "Drive %.1f dB • Pre-Enc GR %.1f dB • Max %.1f dB • Safe %.1f dB • Peak %@",
            config.finalDriveDB,
            preEncodeAudioLimiterGainReductionDB,
            limiterGRPeakHold,
            mpxSafetyLimiterGainReductionDB,
            Self.dbfsString(outputPeak)
        )
        if !isRunning {
            compositeBudgetStateText = "Off"
        } else if compositeBudgetMarginDB >= 3.0 {
            compositeBudgetStateText = "Safe"
        } else if compositeBudgetMarginDB >= 1.0 {
            compositeBudgetStateText = "Tight"
        } else {
            compositeBudgetStateText = "Risk"
        }
        compositeCalibrationText = String(
            format: "Pilot %.1f%% • RDS %.1f%% • Audio %@ • Margin %.1f dB",
            pilotInjectionPercent,
            rdsInjectionPercent,
            Self.dbfsString(audioCompositePeak),
            compositeBudgetMarginDB
        )
        stereoImageText = String(
            format: "Corr %@%.2f • Side %.2fx",
            outputStereoCorrelation >= 0 ? "+" : "",
            outputStereoCorrelation,
            outputSideToMidRatio
        )
        if config.widebandAGCEnabled && !processingBypass {
            agcStateText = agcGateActive ? "Gate" : "On"
        } else {
            agcStateText = "Off"
        }
        agcDetailText = String(
            format: "Detector %.1f dB • Gain %.1f dB",
            agcDetectorDB,
            agcGainDB
        ) + (agcGateActive ? " • Gate" : "")
        multibandStateText = config.multibandEnabled ? "On" : "Off"
        primeBassStateText = config.primeBassEnabled ? "On" : "Off"
        if !config.stereoWidenEnabled || config.monoMode {
            widenerStateText = "Off"
        } else if outputStereoCorrelation < 0.0 || outputSideToMidRatio > 0.85 {
            widenerStateText = "Risk"
        } else if outputStereoCorrelation < 0.30 || outputSideToMidRatio > 0.55 {
            widenerStateText = "Wide"
        } else {
            widenerStateText = "Safe"
        }

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
            rdsPS = live.ps
        } else {
            rdsPS = Self.currentTimedDisplayText(config.activePSBankText, elapsed: elapsed).ifEmpty("-")
        }
        rdsPI = config.rdsPI
        rdsPTY = Self.ptyName(for: config.rdsPTY)
        if let live, !live.ptyn.isEmpty {
            rdsPTYN = live.ptyn
        } else {
            rdsPTYN = Self.currentTimedDisplayText(config.rdsPTYN, elapsed: elapsed).ifEmpty("-")
        }
        rdsAID = config.rdsEnableRTPlus ? "AID: 4BD7 (GROUP 11A)" : "AID: OFF"
        if let live, !live.longPS.isEmpty {
            rdsLongPS = live.longPS
        } else {
            rdsLongPS = Self.currentTimedDisplayText(config.rdsLongPS32, elapsed: elapsed).ifEmpty("-")
        }
        if let live, !live.rt.isEmpty {
            // Trim trailing CR terminator (0x0D) that prepareRTFrame appends
            // for the 2A "end of text" marker so the on-screen readout is clean.
            rdsRadiotext = live.rt
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .ifEmpty("-")
        } else {
            rdsRadiotext = currentRTText(elapsed: elapsed).ifEmpty("-")
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
                        match.range.location == 0
                    {
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

    private static let ptyNames: [String] = [
        "None", "News", "Current Affairs", "Information", "Sport", "Education", "Drama", "Culture",
        "Science", "Varied", "Pop Music", "Rock Music", "Easy Music", "Light Classical",
        "Serious Classical",
        "Other Music", "Weather", "Finance", "Children's", "Social Affairs", "Religion", "Phone-In",
        "Travel", "Leisure", "Jazz", "Country", "National Music", "Oldies", "Folk Music",
        "Documentary",
        "Alarm Test", "Alarm",
    ]

    private static let primeBassPresets: [PrimeBassPreset] = [
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
            drive: 0.48, density: 0.22, subharmonicsEnabled: false, subharmonicsAmount: 0.0),
    ]

    private static let widenerPresets: [WidenerPreset] = [
        .init(
            id: "safe_fm",
            title: "Safe FM",
            stereoWidenEnabled: false,
            monoBassEnabled: true,
            monoBassFreqHz: 140.0,
            width: 0.30,
            center: 0.50,
            mix: 0.60
        ),
        .init(
            id: "open_music",
            title: "Open Music",
            stereoWidenEnabled: true,
            monoBassEnabled: true,
            monoBassFreqHz: 125.0,
            width: 0.46,
            center: 0.50,
            mix: 0.76
        ),
        .init(
            id: "wide_chr",
            title: "Wide CHR",
            stereoWidenEnabled: true,
            monoBassEnabled: true,
            monoBassFreqHz: 115.0,
            width: 0.46,
            center: 0.50,
            mix: 0.76
        ),
    ]

    private static let multibandPresets: [MultibandPreset] = [
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
            highReleaseMS: 210, kneeDB: 3.0, linkStrength: 0.48, releaseProgramDependent: true),
    ]

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
        ),
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
        ),
    ]

    static func formatProfile(forID id: String) -> FormatProfile? {
        formatProfiles.first(where: { $0.id == id })
    }

    private static func ptyName(for pty: Int) -> String {
        if ptyNames.indices.contains(pty) {
            return ptyNames[pty]
        }
        return "None"
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

    private func selectUID(preferred: String?, from devices: [AudioDevice]) -> String {
        if let preferred, !preferred.isEmpty, devices.contains(where: { $0.uid == preferred }) {
            return preferred
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
        let clampedTarget = max(0.0, min(1.0, target.isFinite ? target : 0.0))
        if clampedTarget >= current {
            return smoothMeter(
                current: current,
                target: clampedTarget,
                dt: dt,
                attackMS: Self.audioPeakMeterAttackMS,
                releaseMS: releaseMS
            )
        }
        return smoothMeter(
            current: current,
            target: clampedTarget,
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
        guard linear > 1e-9 else { return "-inf dBFS" }
        let db = 20.0 * log10(Double(linear))
        return String(format: "%.1f dBFS", db)
    }

    private static func meterMetaString(rms: Float, peak: Float, peakHoldDB: Float? = nil) -> String {
        let rmsString = dbfsString(rms)
        let displayPeakDB: Double
        if let peakHold = peakHoldDB {
            displayPeakDB = Double(peakHold)
        } else {
            displayPeakDB = peak > 1e-9 ? (20.0 * log10(Double(peak))) : -120.0
        }
        return "\(rmsString)   \(String(format: "%.1f", displayPeakDB)) pk"
    }

    private static func peakMeterString(currentPeak: Float, peakHoldDB: Float? = nil) -> String {
        let currentString = dbfsString(currentPeak)
        guard let peakHoldDB else { return currentString }
        return "\(currentString)   \(String(format: "%.1f", peakHoldDB)) pk"
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
        if let r = range(of: "   ") { return String(self[..<r.lowerBound]) }
        return self
    }
}

private struct RootView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Always-visible broadcast status header — transport / peaks /
            // deviation / GR / budget / injections. Pinned above the
            // NavigationSplitView so it spans every stage.
            BroadcastStatusBar(model: model)

            // Pinned-open sidebar: bind columnVisibility to `.constant(.all)`
            // so the user can't toggle the sidebar away, and remove the
            // toolbar's sidebarToggle button so there's no UI affordance to
            // collapse it. Stage navigation is the primary surface — losing
            // it would strand the user on whichever stage they last had
            // selected.
            NavigationSplitView(columnVisibility: .constant(.all)) {
                StageSidebar(model: model)
                    // Minimum width sized to fit the longest label
                    // ("Composite Clipper", 17 chars) plus icon and
                    // padding. The previous 200 pt minimum let the OS
                    // / autosaved state pin the sidebar narrow enough
                    // to truncate "Composite Clipper" / "Alt. Frequencies"
                    // on first launch of a fresh DMG.
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                StageContentView(model: model)
                    .inspector(isPresented: $model.inspectorVisible) {
                        StageInspector(model: model)
                            .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                    }
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
                Section(group.rawValue) {
                    ForEach(Stage.allCases.filter { $0.group == group }) { stage in
                        Label {
                            Text(stage.label)
                        } icon: {
                            Image(systemName: stage.icon)
                                // Explicit `.tint` foreground on the
                                // *icon only* — keeps text in the
                                // default sidebar foreground (white in
                                // dark mode) while making icons pick
                                // up the system accent (blue by
                                // default). Hierarchical layering on
                                // top gives the 3-level tonal depth
                                // Apple's first-party sidebars use
                                // (Music.app, Mail.app).
                                .foregroundStyle(.tint)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .tag(stage)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Content column for the currently-selected stage. Each stage renders its
/// own scroll view + content; for Processing and RDS stages the per-tab view
/// is the same one the legacy segmented-picker section used, plus the
/// per-tab reset button. Monitoring stays as a single dashboard.
private struct StageContentView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.selectedStage.detailTitle)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.top, 16)
            .padding(.horizontal, 22)
            .padding(.bottom, 8)

            Text(model.selectedStage.detailSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)

            Group {
                if model.selectedStage == .monitoring {
                    MonitoringDashboardView(model: model)
                } else if model.selectedStage == .testTone {
                    TestToneView(model: model)
                } else if model.selectedStage == .snapshots {
                    SnapshotsView(model: model)
                } else if let _ = model.selectedStage.legacyProcessingTab {
                    StageProcessingContent(model: model)
                } else if let _ = model.selectedStage.legacyRDSTab {
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
                SignalFlowStrip(model: model)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Tab help text block — shown above every Processing
                    // tab except the Overview grid (which is its own
                    // self-describing layout). Brief 1-3 sentence
                    // explanation of the DSP stage so operators can
                    // anchor without leaving for documentation.
                    if model.selectedProcessingTab != .overview {
                        TabHelpBox(text: model.selectedProcessingTab.helpText)
                    }

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
                // Tab help box — shown at the top of every RDS tab, same
                // pattern as the Processing tabs. Brief 1-3 sentence
                // anchor on what the tab covers and spec context.
                TabHelpBox(text: model.selectedRDSTab.helpText)

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
/// calibrated input levels (default −20 dBFS, broadcast line
/// reference). Three signal types — sine for level / separation /
/// encoder-bandwidth tests, pink and white noise for broadband
/// response checks. Stereo modes cover the operator's diagnostic
/// needs (mono / L=−R / L-only / R-only).
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TabHelpBox(text: "Eight named snapshot slots for the full configuration. Save the current setup into a slot, load it back later — survives app restart (stored as `<configPath>.snapshots.json`). Heavier than Format Profiles: snapshots capture every per-stage setting and RDS field, not just the DSP bundle.")

                Card(title: "Snapshots") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<MPXPrimeViewModel.snapshotSlotCount, id: \.self) { slot in
                            SnapshotSlotRow(model: model, slot: slot)
                            if slot < MPXPrimeViewModel.snapshotSlotCount - 1 {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
    }
}

private struct SnapshotSlotRow: View {
    @ObservedObject var model: MPXPrimeViewModel
    let slot: Int
    @State private var draftName: String = ""

    private var snapshot: ConfigSnapshot? { model.snapshots[slot] }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(slot + 1).")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                TextField(snapshot?.name ?? "Snapshot \(slot + 1)", text: $draftName, onCommit: {
                    if snapshot != nil {
                        model.renameSnapshot(slot: slot, name: draftName)
                    } else {
                        model.saveSnapshot(slot: slot, name: draftName)
                        draftName = ""
                    }
                })
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 260)

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

            Spacer()

            HStack(spacing: 8) {
                Button("Save") {
                    let nameToUse = !draftName.isEmpty ? draftName : (snapshot?.name ?? "")
                    model.saveSnapshot(slot: slot, name: nameToUse)
                    draftName = ""
                }
                .help("Capture the current full configuration into this slot. Overwrites any existing snapshot here.")

                Button("Load") {
                    model.loadSnapshot(slot: slot)
                }
                .disabled(snapshot == nil)
                .help("Apply this slot's saved configuration to the live engine. Restart-required fields surface a pending-apply prompt.")

                Button("Clear") {
                    model.clearSnapshot(slot: slot)
                    draftName = ""
                }
                .disabled(snapshot == nil)
                .help("Delete this slot. Cannot be undone.")
            }
            .controlSize(.small)
        }
        .onAppear {
            draftName = snapshot?.name ?? ""
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
        50, 100, 400, 1_000, 5_000, 10_000, 12_000, 15_000,
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
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Cards

    private var enableCard: some View {
        Card(title: "Test Tone Source") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Test Tone").font(.body)
                        Text(
                            "Replaces the audio input. The rest of the chain "
                            + "(AGC, multiband, clippers, BS.412, composite "
                            + "clipper) processes the generated tone normally."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
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
                        Text("L=−R").tag("stereo")
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
                        Button(presetLabel(for: freq)) {
                            freqBinding.wrappedValue = freq
                        }
                        .buttonStyle(.bordered)
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
                } label: {
                    Text(String(format: "%+0.1f dBFS", model.config.testToneLevelDB))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 96, alignment: .leading)
                }
                Text(
                    "Default −20 dBFS matches broadcast line-level reference. "
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
        case "stereo": return "Stereo (L=−R)"
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
                rdsPanel
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
                subcarriersPanel.frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 12) {
                mpxPanel
                headroomPanel
                subcarriersPanel
            }
        }
    }

    private var mpxPanel: some View {
        Card(title: "MPX") {
            metricsGrid([
                ("OUTPUT", model.outputText.ifEmpty("—")),
                ("AUDIO COMPOSITE", audioCompositeText),
                ("DEVIATION", String(format: "%.1f kHz", model.estimatedDeviationPeakKHz)),
                ("MODULATION", modulationText),
            ])
        }
    }

    private var headroomPanel: some View {
        Card(title: "Headroom") {
            metricsGrid([
                ("PRE-ENCODE GR", grText(model.preEncodeLimiterGainReductionDBValue)),
                ("COMPOSITE GR", grText(model.compositeClipperGainReductionDBValue)),
                ("SAFETY GR", grText(model.safetyLimiterGainReductionDBValue)),
                ("BS.412 BUDGET", budgetText),
            ])
        }
    }

    private var subcarriersPanel: some View {
        Card(title: "Subcarriers") {
            metricsGrid([
                ("PILOT", String(format: "%.1f%%", model.pilotInjectionPercentValue)),
                ("RDS", String(format: "%.1f%%", model.rdsInjectionPercentValue)),
                ("STEREO IMAGE", model.stereoImageText),
            ])
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
        return String(format: "%.1f dBFS", 20.0 * log10(v))
    }

    /// Modulation percentage: peak deviation as a fraction of the
    /// configured target. References `mpx_deviation_khz` from config
    /// (not the 75 kHz regulatory line) — operators with custom
    /// deviation targets read 100% at their chosen setpoint.
    private var modulationText: String {
        let peak = Double(model.estimatedDeviationPeakKHz)
        let target = max(1.0, model.config.mpxDeviationKHz)
        return String(format: "%.1f%%", (peak / target) * 100.0)
    }

    /// Budget margin + state. ON shown in tail when BS.412 is engaged;
    /// otherwise the numeric value alone (so OFF reads "+0.0 dB" with
    /// no implication that BS.412 is active).
    private var budgetText: String {
        let margin = Double(model.compositeBudgetMarginDBValue)
        let state = model.compositeBudgetStateText
        let core = String(format: "%+.1f dB", margin)
        return state.isEmpty || state == "Off" ? core : "\(core) · \(state)"
    }

    private func grText(_ valueDB: Float) -> String {
        let db = Double(valueDB)
        return db < 0.05 ? "0.0 dB" : String(format: "%.1f dB", db)
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
                            Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
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
                            Image(systemName: model.processingBypass ? "bolt.slash.fill" : "bolt.fill")
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
                    ("Monitor", monitorChipText, model.monitorEnabled ? .green : .secondary.opacity(0.75)),
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
            MeterRow(
                label: "L",
                valueText: model.inputLText.meterCurrentOnly,
                level: model.inputLLevel,
                peakLevel: model.inputLPeakHoldLevel,
                scaleStyle: .dbfs
            )
            MeterRow(
                label: "R",
                valueText: model.inputRText.meterCurrentOnly,
                level: model.inputRLevel,
                peakLevel: model.inputRPeakHoldLevel,
                scaleStyle: .dbfs
            )
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
            Text(streamRateText)
                .font(BroadcastStyle.valueReadout)
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
                Text(delayText)
                    .font(BroadcastStyle.valueReadout)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: bufferFill)
                .progressViewStyle(.linear)
                .tint(bufferTint)
                .frame(maxWidth: .infinity)
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
            HStack(spacing: 12) {
                dropoutPill(label: "OVR", count: model.streamHealth.overflowsRecent)
                dropoutPill(label: "UND", count: model.streamHealth.underflowsRecent)
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
        let tint: Color = count == 0 ? .green : (count < 3 ? .orange : .red)
        return HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(BroadcastStyle.scaleLabel)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(BroadcastStyle.valueReadout)
        }
    }

    // MARK: - Panel B: DSP chain (3-pill context strip + 13-stage grid)

    private var chainPanel: some View {
        Card(title: "Signal Chain") {
            VStack(alignment: .leading, spacing: 12) {
                FlowStatusRow(items: [
                    ("AGC", agcPillText, agcDotColor),
                    ("Stereo", stereoPillText, .secondary.opacity(0.75)),
                    ("Pre-Lim GR", preLimText, preLimDotColor),
                ])

                ProcessingOverviewGrid(model: model, embedded: true)
            }
        }
    }

    // MARK: - Panel C: RDS

    private var rdsPanel: some View {
        Card(title: "RDS") {
            VStack(alignment: .leading, spacing: 10) {
                FlowStatusRow(items: [
                    ("PS", model.rdsPS.ifEmpty("—"), .secondary.opacity(0.75)),
                    ("PI", model.rdsPI.ifEmpty("—"), .secondary.opacity(0.75)),
                    ("PTY", model.rdsPTY.ifEmpty("—"), .secondary.opacity(0.75)),
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
        String(format: "%.1f dB", Double(model.preEncodeLimiterGainReductionDBValue))
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
                Text(model.runtimeText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                ProgressView(value: model.inputBufferValue, total: max(1.0, model.inputBufferMax))
                    .tint(
                        model.inputBufferValue >= model.inputBufferCritical
                            ? .red
                            : (model.inputBufferValue >= model.inputBufferWarning
                                ? .yellow : .green))
                Text(model.inputRingText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
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
                    label: "MPX",
                    valueText: model.outputText.meterCurrentOnly,
                    level: model.outputLevel,
                    peakLevel: model.outputPeakHoldLevel,
                    scale: .dbfs
                )
                VerticalMeterStrip(
                    label: "MOD",
                    valueText: model.modulationText,
                    level: model.modulationLevel,
                    peakLevel: model.modulationPeakHoldLevel,
                    scale: .modulationKHz(limit: model.config.mpxDeviationKHz)
                )
                // GR + SAFE removed in 0.30 — peak-control gain-reduction
                // data is already surfaced by the Monitoring tab's Headroom
                // card (PRE-ENCODE / COMPOSITE / SAFETY GR + BS.412 budget)
                // and per-stage in the Signal Chain strip. The detached
                // Levels window is now purely VU-style level metering.
                Spacer(minLength: 0)
            }
            .frame(height: 340)
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
            }
            MeterBar(level: level, peakLevel: peakLevel, scaleStyle: scaleStyle)
        }
        .font(.callout)
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
                ScaleTick(position: Self.dbfsScalePosition(0.0), label: "0 dBFS"),
            ]
        case .modulation100kHz:
            return [
                ScaleTick(position: 0.0, label: "0"),
                ScaleTick(position: 0.25, label: "25"),
                ScaleTick(position: 0.5, label: "50"),
                ScaleTick(position: 0.75, label: "75"),
                ScaleTick(position: 1.0, label: "100 kHz"),
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
            GeometryReader { geo in
                let width = max(0.0, min(1.0, level)) * geo.size.width
                let peakX = (peakLevel.map { max(0.0, min(1.0, $0)) } ?? 0.0) * geo.size.width
                let targetX = (targetLevel.map { max(0.0, min(1.0, $0)) } ?? 0.0) * geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                    ForEach(scaleTicks) { tick in
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: 1)
                            .offset(x: (tick.position * geo.size.width) - 0.5)
                    }
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(meterTint.opacity(0.75))
                        .frame(width: max(0.0, width))
                    if targetLevel != nil {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.95))
                            .frame(width: 2, height: 14)
                            .offset(
                                x: min(
                                    max(0.0, targetX - 1.0),
                                    max(0.0, geo.size.width - 2.0)
                                )
                            )
                    }
                    if peakLevel != nil {
                        Rectangle()
                            .fill(Color.primary.opacity(0.98))
                            .frame(width: 2, height: 14)
                            .offset(x: min(max(0.0, peakX - 1.0), max(0.0, geo.size.width - 2.0)))
                    }
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

struct ScopeView: View {
    let samples: [Float]
    var secondarySamples: [Float]? = nil

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius), with: .color(.black.opacity(0.22)))

            var grid = Path()
            let midY = size.height * 0.5
            grid.move(to: CGPoint(x: 0, y: midY))
            grid.addLine(to: CGPoint(x: size.width, y: midY))
            for i in 1..<4 {
                let x = size.width * (CGFloat(i) / 4.0)
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)

            func makeWavePath(samples: [Float]) -> Path {
                guard samples.count > 1 else { return Path() }
                let stepX = size.width / CGFloat(samples.count - 1)
                var wave = Path()
                for (idx, sample) in samples.enumerated() {
                    let clamped = max(-1.0, min(1.0, sample))
                    let x = CGFloat(idx) * stepX
                    let y = midY - (CGFloat(clamped) * amplitude)
                    if idx == 0 {
                        wave.move(to: CGPoint(x: x, y: y))
                    } else {
                        wave.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                return wave
            }

            guard samples.count > 1 else { return }
            let amplitude = max(10.0, size.height * 0.46)
            if let secondarySamples {
                context.stroke(
                    makeWavePath(samples: secondarySamples),
                    with: .color(.cyan.opacity(0.85)),
                    lineWidth: 1.1
                )
            }
            context.stroke(
                makeWavePath(samples: samples),
                with: .color(.green.opacity(0.90)),
                lineWidth: 1.2
            )
        }
        .frame(minHeight: 130, idealHeight: 150)
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
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

struct MPXSpectrumView: View {
    let dbBins: [Float]
    let maxHz: Double
    let nyquistHz: Double

    private let dbMin: Float = -100.0
    private let dbMax: Float = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius), with: .color(.black.opacity(0.30)))
                let maxDisplayHz = max(1_000.0, maxHz)
                let nyquist = max(0.0, min(maxDisplayHz, nyquistHz))
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

                // Grid and border inside the plot region.
                var grid = Path()
                for db in stride(from: -100, through: 0, by: 10) {
                    let y = yPosition(forDB: Float(db), in: plotRect)
                    grid.move(to: CGPoint(x: plotRect.minX, y: y))
                    grid.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                }
                for tick in xTicks(maxHz: maxDisplayHz, dense: true) {
                    let x = xPosition(forHz: tick, in: plotRect, maxHz: maxDisplayHz)
                    grid.move(to: CGPoint(x: x, y: plotRect.minY))
                    grid.addLine(to: CGPoint(x: x, y: plotRect.maxY))
                }
                context.stroke(grid, with: .color(.white.opacity(0.18)), lineWidth: 0.9)
                context.stroke(
                    Path(plotRect),
                    with: .color(.white.opacity(0.40)),
                    lineWidth: 1.0
                )

                // Left and right Y-axis labels.
                for db in stride(from: -100, through: 0, by: 10) {
                    let y = yPosition(forDB: Float(db), in: plotRect)
                    let label = db == 0 ? "0 dB" : "\(db) dB"
                    let text = Text(label)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                    context.draw(text, at: CGPoint(x: 18, y: y))
                    context.draw(text, at: CGPoint(x: size.width - 18, y: y))
                }

                // Bottom X-axis labels.
                for tick in xTicks(maxHz: maxDisplayHz, dense: false) {
                    let x = xPosition(forHz: tick, in: plotRect, maxHz: maxDisplayHz)
                    let kHz = Int((tick / 1000.0).rounded())
                    let label = Text("\(kHz) kHz")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                    context.draw(label, at: CGPoint(x: x, y: plotRect.maxY + 12))
                }

                guard dbBins.count > 1 else { return }

                let stepX = plotRect.width / CGFloat(dbBins.count - 1)
                var line = Path()
                for (idx, value) in dbBins.enumerated() {
                    let x = plotRect.minX + (CGFloat(idx) * stepX)
                    let y = yPosition(forDB: max(dbMin, min(dbMax, value)), in: plotRect)
                    if idx == 0 {
                        line.move(to: CGPoint(x: x, y: y))
                    } else {
                        line.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                var fill = line
                fill.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
                fill.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
                fill.closeSubpath()
                let gradient = Gradient(colors: [
                    Color.red.opacity(0.65),
                    Color.yellow.opacity(0.60),
                    Color.green.opacity(0.55),
                    Color.cyan.opacity(0.50),
                    Color.blue.opacity(0.45),
                ])
                context.fill(
                    fill,
                    with: .linearGradient(
                        gradient, startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(.white.opacity(0.7)), lineWidth: 1.0)

                if nyquist > 0.0, nyquist < maxDisplayHz {
                    let xNyquist = xPosition(forHz: nyquist, in: plotRect, maxHz: maxDisplayHz)
                    let unsupportedRect = CGRect(
                        x: xNyquist,
                        y: plotRect.minY,
                        width: max(0, plotRect.maxX - xNyquist),
                        height: plotRect.height
                    )
                    context.fill(
                        Path(unsupportedRect),
                        with: .color(.black.opacity(0.38))
                    )
                }
            }
            .frame(minHeight: 190, idealHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))

            HStack(spacing: 14) {
                let maxDisplayHz = max(1_000.0, maxHz)
                if nyquistHz > 0.0, nyquistHz < maxDisplayHz {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: 6, height: 6)
                        Text("Nyquist \(Int((nyquistHz / 1000.0).rounded())) kHz")
                    }
                }
                Spacer()
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
        }
        // Disable SwiftUI implicit animations on @Published dbBins updates.
        // Without this, frame-to-frame interpolation queues accumulated
        // when 30 Hz spectrum updates were interrupted mid-interpolation —
        // visible as growing lag in the Audio Spectrum / MPX Spectrum
        // windows after several minutes. Matches the inline spectrum view
        // which already has this transaction modifier.
        .transaction { txn in
            txn.animation = nil
        }
    }

    private func yPosition(forDB db: Float, height: CGFloat) -> CGFloat {
        let clamped = max(dbMin, min(dbMax, db))
        let norm = (clamped - dbMin) / (dbMax - dbMin)
        return (1.0 - CGFloat(norm)) * height
    }

    private func yPosition(forDB db: Float, in rect: CGRect) -> CGFloat {
        rect.minY + yPosition(forDB: db, height: rect.height)
    }

    private func xPosition(forHz hz: Double, in rect: CGRect, maxHz: Double) -> CGFloat {
        let ratio = CGFloat(max(0.0, min(1.0, hz / max(1_000.0, maxHz))))
        return rect.minX + (ratio * rect.width)
    }

    private func xTicks(maxHz: Double, dense: Bool) -> [Double] {
        let maxDisplayHz = max(1_000.0, maxHz)
        let step = dense ? 5_000.0 : 10_000.0
        var ticks: [Double] = [0.0]
        var value = step
        while value < maxDisplayHz {
            ticks.append(value)
            value += step
        }
        if ticks.last != maxDisplayHz {
            ticks.append(maxDisplayHz)
        }
        return ticks
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
        3_150, 4_000, 5_000, 6_300, 8_000, 10_000, 12_500, 16_000,
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
                    Color.blue.opacity(0.55),
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
                    for b in lowBin...highBin {
                        if dbBins[b] > maxDB { maxDB = dbBins[b] }
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
                    (16_000, "16 kHz"),
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
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
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
                Text("Picking a profile overwrites Multiband, Final Stage, PrimeBass, Stereo Widener, and Composite Clipper settings. Per-stage knobs stay editable after — tune from the profile baseline, not from a blank slate. Pick `Custom` to keep your manual tuning when re-visiting this picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Text("Mono Mode transmits true mono composite. The full DSP chain (AGC, multiband, clippers, limiters) still runs; only the 19 kHz pilot, 38 kHz stereo subcarrier, and RDS are suppressed at composite assembly.")
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
                title: "MPX Output Level",
                value: model.configBinding(\.outputGainDB, runtimeDisposition: .live),
                range: -18...18,
                format: "%.1f dB",
                tooltip: "Final post-chain gain trim on the composite output before the audio device. Use for calibration into the exciter's MPX input — set so the exciter's deviation meter reads the licensed peak. Doesn't add loudness; the chain already drives the composite to 100% modulation."
            )
            Text("Use MPX Output Level for final transmit/output calibration. Do not use AGC target as the main loudness knob.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DoubleSliderRow(title: "HPF", value: model.configBinding(\.hpfHz), range: 10...180, format: "%.0f Hz",
                tooltip: "High-pass filter cutoff on the L/R input. Removes DC, rumble, and very-low-end energy that would otherwise eat headroom downstream. 30 Hz is the ITU-R BS.450 audio-bandwidth lower bound; raise to 50-80 Hz for ground-loop or rumble-heavy sources.")
            DoubleSliderRow(title: "HF Trim", value: model.configBinding(\.hfTrimDB), range: -12...12, format: "%.1f dB",
                tooltip: "Pre-multiband shelf cut/boost at HF Trim Freq. Negative values tame harsh sources before they hit the multiband; positive values brighten dull material. Apply sparingly — global tonal shaping is the Parametric EQ stage's job.")
            DoubleSliderRow(title: "HF Trim Freq", value: model.configBinding(\.hfTrimHz), range: 1_000...12_000, format: "%.0f Hz",
                tooltip: "Centre frequency for the HF Trim shelf above. 4 kHz default targets vocal presence and cymbal sheen.")
            DoubleSliderRow(title: "Program Lowpass", value: model.configBinding(\.programLowpassHz), range: 8_000...16_000, format: "%.0f Hz",
                tooltip: "Audio-bandwidth lowpass applied before stereo encoding. ITU-R BS.450 specifies 30 Hz - 15 kHz for FM stereo; 16 kHz default leaves room for the encoder FIR rolloff into the 17-19 kHz pilot guard. Lower for narrower bandwidth (talk, AM-style), higher only if your modulator FIR can cope.")
        }
        Card(title: "Engine — TX path") {
            Toggle("Encoder Lowpass: linear-phase FIR", isOn: model.configBinding(\.encoderFIREnabled))
                .help("Transmit-mode encoder bandwidth guard. On (default): Kaiser-windowed linear-phase FIR, >80 dB stop-band, ~1.67 ms latency at 192 kHz. Off: 12th-order Butterworth cascade, ~0.2 ms latency, ~40 dB stop-band. Monitor mode always uses Butterworth. Restart-required.")
            Toggle("Multiband Crossovers: linear-phase FIR", isOn: model.configBinding(\.multibandFIREnabled))
                .help("Transmit-mode multiband splitters. On (default): Kaiser-windowed FIR splitters, sum-to-flat at -155 dB, all bands share group delay (no transient smear / inter-band pumping), ~5.3 ms latency at 192 kHz. Off: IIR Linkwitz-Riley 4th-order cascade, low latency but with the IIR-LR4 phase artefacts. Monitor mode always uses LR4. Restart-required.")
            Text("Both toggles only affect the transmit (composite) path. Restart engine to apply.")
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
            Toggle(
                "Use New Band-limited Limiter Ceiling",
                isOn: model.configBinding(\.preEncodeBandlimitedResidualEnabled, runtimeDisposition: .live)
            )
            .help("Switches the pre-encode limiter ceiling from the classic tanh soft ceiling to the experimental 0.27 band-limited residual ceiling. Off = old/current chain. On = new patent-style candidate.")
            .disabled(disabled)
            DoubleSliderRow(
                title: "Look-ahead",
                value: model.configBinding(\.preEncodeLookaheadMS, runtimeDisposition: .restart),
                range: 0...5,
                format: "%.2f ms",
                tooltip: "Look-ahead time so the limiter's gain ramp engages before the peak reaches the gain stage. 0 ms = legacy feedback-only behavior. 1-2 ms recommended for cleaner HF transient handling on pre-emphasized content (cymbals, sibilance, percussion edges). Adds equivalent latency to the chain. Restart-required."
            ).disabled(disabled)
            Toggle(
                "HF-Only Look-ahead Detector (Phase 2 / Dolby)",
                isOn: model.configBinding(\.preEncodeLookaheadHFOnly, runtimeDisposition: .restart)
            )
            .help("Phase 2: high-pass the detector path so look-ahead engages only on HF transients (where pre-emphasis concentrates peaks). Audio path stays full-band. LF dynamics / punch are not subject to the look-ahead gain ramp. Patent: US 5,579,404 / EP 0685130 (Dolby, expired 2013). Restart-required.")
            .disabled(disabled || model.config.preEncodeLookaheadMS <= 0.0)
            DoubleSliderRow(
                title: "HF Detector Cutoff",
                value: model.configBinding(\.preEncodeLookaheadHFCutoffHz, runtimeDisposition: .restart),
                range: 1_000...12_000,
                format: "%.0f Hz",
                tooltip: "High-pass cutoff for the HF-only look-ahead detector. 4 kHz default matches the Dolby spec where pre-emphasis-induced peaks start dominating. Lower (2-3 kHz) catches more vocal sibilance; higher (6-8 kHz) targets cymbals / hi-hats only. Restart-required."
            ).disabled(disabled || !model.config.preEncodeLookaheadHFOnly || model.config.preEncodeLookaheadMS <= 0.0)
            Text("Pre-encode peak limiter on L/R audio. 4x oversampled true-peak detector with stereo-linked gain. Look-ahead and HF-only detector (Phase 2, Dolby US 5,579,404) are opt-in via the controls above; the band-limited residual toggle is the 0.27 patent-style ceiling candidate.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.limitThreshold), range: 0.5...0.999, format: "%.3f",
                tooltip: "Linear ceiling for the safety limiter (0.5..0.999). 0.98 = -0.18 dBFS. Below this the limiter doesn't engage; above it the look-ahead reduces gain to keep peaks under the ceiling.").disabled(disabled)
            Toggle("Enable Look-Ahead", isOn: model.configBinding(\.limitLookaheadEnabled))
                .help("Look-ahead delay so the limiter sees future peaks and applies gain reduction smoothly before the peak arrives. Off makes the limiter purely reactive (more overshoot).")
                .disabled(disabled)
            DoubleSliderRow(title: "Look-Ahead", value: model.configBinding(\.limitLookaheadMS), range: 0...20, format: "%.1f ms",
                tooltip: "How far ahead the limiter looks before responding. 5 ms is standard; longer = smoother gain reduction at the cost of latency.").disabled(disabled || !model.config.limitLookaheadEnabled)
            Text("Final guardrail on the audio composite after the composite clipper and BS.412. Pilot and RDS subcarriers are injected after this stage at constant amplitude. Restart-required.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("Per-band fast peak limiter operating after multiband compression. Controls instantaneous transient peaks independently from the compressor ratio.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("Per-band noise reduction within the multiband compressor. Reduces gain on quiet bands to prevent AGC from lifting the noise floor.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                tooltip: "LR4 crossover frequency isolating the low band for clipping. Content below this is clipped independently; above passes unmodified.").disabled(disabled)
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.bassClipperThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Clipping threshold for the low band. Lower = more aggressive bass clipping, reducing bass-induced IMD in downstream stages.").disabled(disabled)
            DoubleSliderRow(title: "Drive", value: model.configBinding(\.bassClipperDrive, runtimeDisposition: .live), range: 0.5...3, format: "%.2f",
                tooltip: "Pre-clipping gain applied to the low band. Higher drive increases density but also clipping distortion.").disabled(disabled)
            Text("Pre-clips bass peaks independently before the final limiter, dramatically reducing bass-induced intermodulation distortion.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProcessingDCClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Distortion-Cancelled Clipper") {
            Toggle("Enable DC Clipper", isOn: model.configBinding(\.dcClipperEnabled, runtimeDisposition: .live))
            let disabled = !model.config.dcClipperEnabled
            DoubleSliderRow(title: "Ceiling", value: model.configBinding(\.dcClipperCeilingDB, runtimeDisposition: .live), range: -6...0, format: "%.1f dB",
                tooltip: "Clipping ceiling for the distortion-cancelled clipper. Lower ceiling = more audible density but more clipping artifacts.").disabled(disabled)
            DoubleSliderRow(title: "Cancel Freq", value: model.configBinding(\.dcClipperCancelFreqHz, runtimeDisposition: .live), range: 500...4000, format: "%.0f Hz",
                tooltip: "Cutoff of the LF error-extraction filter. Clipping distortion below this frequency is subtracted; above, it is left for masking.").disabled(disabled)
            Text("Audio clipper with low-frequency distortion cancellation (Orban principle). Clips signal, extracts LF error below cancel frequency, and subtracts it \u{2014} leaving only psychoacoustically masked HF distortion.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("ITU-R BS.412 rolling average power limiter for European regulatory compliance (DE, AT, CH, SE, CZ, SI). Limits MPX power over a sliding time window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProcessingCompositeClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Composite Clipper") {
            Toggle("Enable Composite Clipper", isOn: model.configBinding(\.compositeClipperEnabled, runtimeDisposition: .live))
            Toggle("Experimental Multiband Composite Clipping", isOn: model.configBinding(\.compositeMultibandClipperEnabled, runtimeDisposition: .live))
                .help("Additional off-by-default loudness stage after the broadband composite clipper. Splits the audio composite into low/mid/high bands, clips the bands independently, then recombines before pilot/RDS injection.")
            let disabled = !model.config.compositeClipperEnabled
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.compositeClipperThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Onset of composite-level soft clipping on the audio composite (not pilot/RDS). Primary loudness lever when engaged.").disabled(disabled)
            DoubleSliderRow(title: "Ceiling", value: model.configBinding(\.compositeClipperCeilingDB, runtimeDisposition: .live), range: -6...0, format: "%.1f dB",
                tooltip: "Maximum output level after composite clipping. Must stay below 0 dBFS to leave headroom for pilot/RDS injection.").disabled(disabled)
            DoubleSliderRow(title: "Look-ahead", value: model.configBinding(\.compositeClipperLookaheadMS, runtimeDisposition: .live), range: 0...5, format: "%.1f ms",
                tooltip: "Predictive peak shaving. 0.0 disables; 2.0 ms = recommended preset. Sliding-window-max detector + half-cosine attack + 200 Hz smoother bound overshoots tighter than the soft-clip alone, at the cost of N ms added chain latency. Hardcoded internals: 1.5 ms attack, 80 ms release, 200 Hz smoothing.").disabled(disabled)
            LabeledContent("Look-ahead GR") {
                Text(String(format: "%.1f dB", Double(model.compositeClipperLookaheadGainReductionDBValue)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Per-band cancellation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle("Cancel audio band (0-17 kHz)", isOn: model.configBinding(\.compositeClipperCancelAudio, runtimeDisposition: .live))
                .help("Off (default): full clipping in the audio band — maximum loudness. On: subtracts in-band clip residual to keep highs cleaner at the cost of peak control / loudness. Enable when high-frequency harshness is the bigger concern.")
                .disabled(disabled)
            Toggle("Cancel pilot guard (17-21 kHz)", isOn: model.configBinding(\.compositeClipperCancelPilot, runtimeDisposition: .live))
                .help("Removes clipping IM from the 19 kHz pilot region so the receiver decodes stereo cleanly. Leave on except for diagnostic A/B.")
                .disabled(disabled)
            Toggle("Cancel stereo subcarrier (23-53 kHz)", isOn: model.configBinding(\.compositeClipperCancelStereo, runtimeDisposition: .live))
                .help("Removes clipping IM from the 38 kHz DSB-SC L-R subcarrier so stereo separation is preserved. Leave on except for diagnostic A/B.")
                .disabled(disabled)
            Toggle("Cancel RDS guard (55-59 kHz)", isOn: model.configBinding(\.compositeClipperCancelRDS, runtimeDisposition: .live))
                .help("Removes clipping IM from the 57 kHz RDS region so receivers don't see clipper noise vector-summed with RDS. Leave on except for diagnostic A/B.")
                .disabled(disabled)
            Text("8x oversampled tanh soft-clip on audio composite with additive distortion cancellation (Orban US 4,460,871 / 5,737,434). Primary loudness lever: peaks above Threshold are shaped toward Ceiling. Bandpass-isolated clip residual is subtracted from the 17-21 kHz pilot guard, 23-53 kHz stereo subcarrier, and 55-59 kHz RDS guard so those bands stay clean. Placed before BS.412 and safety limiter. Pilot and RDS are injected after this stage.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Tip: leave the composite clipper off when loudness isn't critical — it trades peak control for stereo image and HF cleanliness. If you do enable it, turning on \"Cancel audio band\" recovers HF detail at the cost of some loudness.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            DoubleSliderRow(
                title: "Pilot Level", value: model.pilotLevelPercentBinding(),
                range: 0...12, format: "%.1f %%")
            .disabled(model.config.monoMode)

            InlineRestartRequiredNote(
                text: "Sample rate, block size, mono mode, pre-emphasis, pilot level, program lowpass, and other encoder-structure changes."
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
            Toggle("Center PS", isOn: model.configBinding(\.rdsPSCentered, runtimeDisposition: .liveRDS))
            DoubleSliderRow(
                title: "PS Frame",
                value: model.configBinding(\.rdsPSFrameSeconds, runtimeDisposition: .liveRDS),
                range: 0.5...10.0,
                format: "%.1f s")
            .help("Default seconds each PS chunk is shown when the source has no explicit Ns: timing marker. Typical broadcast cadence is 3 s. Per-segment markers like 4s:NEWS still override this.")
            LabeledContent("PI Code") {
                HexCodeField(text: model.piBinding(), placeholder: "0000", width: 72)
            }
            LabeledContent("ECC") {
                HexCodeField(text: model.hexByteBinding(\.rdsECC), placeholder: "E3", width: 54)
            }
            Picker("Program Type (PTY)", selection: model.ptyBinding()) {
                ForEach(model.ptyChoices, id: \.0) { pty in
                    Text("\(pty.0) · \(pty.1)").tag(pty.0)
                }
            }
            Toggle("Enable PTYN", isOn: model.configBinding(\.rdsEnablePTYN, runtimeDisposition: .liveRDS))
            TextField("PTYN", text: model.configBinding(\.rdsPTYN, runtimeDisposition: .liveRDS))
            Toggle("Center PTYN", isOn: model.configBinding(\.rdsPTYNCentered, runtimeDisposition: .liveRDS))
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
                Toggle("TA", isOn: model.configBinding(\.rdsTA, runtimeDisposition: .liveRDS))
                Toggle("MS", isOn: model.configBinding(\.rdsMS, runtimeDisposition: .liveRDS))
                Toggle("DI Stereo", isOn: model.configBinding(\.rdsDI_STEREO, runtimeDisposition: .liveRDS))
                Toggle("DI Head", isOn: model.configBinding(\.rdsDI_HEAD, runtimeDisposition: .liveRDS))
                Toggle("DI Comp", isOn: model.configBinding(\.rdsDI_COMP, runtimeDisposition: .liveRDS))
                Toggle("DI Dyn PTY", isOn: model.configBinding(\.rdsDI_DYN, runtimeDisposition: .liveRDS))
            }
            .toggleStyle(.switch)
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
            Button(action: {
                model.setConfigValue(\.rdsPSActiveBank, letter, runtimeDisposition: .liveRDS)
            }) {
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

            TextField("", text: model.configBinding(path, runtimeDisposition: .liveRDS))
                .textFieldStyle(.roundedBorder)
                .disabled(false)
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
            TextField("Single Radiotext", text: model.configBinding(\.rdsRTText, runtimeDisposition: .liveRDS))
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
                Text("RT+ tags are derived from the structured script output when now playing is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("RT+ Format A", text: model.configBinding(\.rdsRTPlusFormatA, runtimeDisposition: .liveRDS))
                TextField("RT+ Format B", text: model.configBinding(\.rdsRTPlusFormatB, runtimeDisposition: .liveRDS))
            }
            Text(model.rdsNowPlayingStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RDSLongPSTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Long PS") {
            Toggle("Enable Long PS (15A)", isOn: model.configBinding(\.rdsEnableLPS, runtimeDisposition: .liveRDS))
            TextField("Long PS Text", text: model.configBinding(\.rdsLongPS32, runtimeDisposition: .liveRDS))
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
                range: 0...10, format: "%.1f %%")
            Text("Subcarrier physical-layer settings: injection level only. Carrier is fixed at 57 kHz, locked to 3x pilot per EN 50067 Sec 2.1.4. Gaussian-shaping FIR (enable / bandwidth / taps) is tuned at the defaults (on, 2400 Hz, 81 taps) and not exposed in the GUI — power users can adjust via INI keys `rds_gaussian_enabled` / `rds_gaussian_bw_hz` / `rds_gaussian_taps`. Restart required.")
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

    var body: some View {
        Card(title: "Group Schedule") {
            TextField(
                "Group Sequence",
                text: model.configBinding(\.rdsGroupSequence, runtimeDisposition: .liveRDS))
            Toggle(
                "Scheduler Auto",
                isOn: model.configBinding(\.rdsSchedulerAuto, runtimeDisposition: .liveRDS))
            Toggle(
                "Use Standard Schedule",
                isOn: model.configBinding(\.rdsSchedulerStandard, runtimeDisposition: .liveRDS))
            Toggle(
                "Include LPS in Standard",
                isOn: model.configBinding(\.rdsSchedulerStandardLPS, runtimeDisposition: .liveRDS))
            Text("Custom sequence is used when Scheduler Auto and Use Standard are both off. Standard schedule covers IEC 62106 Table 14 group rates.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Card(title: "Clock Time (4A)") {
            Toggle("Enable CT (4A)", isOn: model.configBinding(\.rdsEnableCT, runtimeDisposition: .liveRDS))
            Toggle("Enable ID (1A)", isOn: model.configBinding(\.rdsEnableID, runtimeDisposition: .liveRDS))
            DoubleSliderRow(
                title: "Clock Offset",
                value: model.configBinding(\.rdsTZOffset, runtimeDisposition: .liveRDS),
                range: -12...14, format: "%.1f h")
            LabeledContent("LIC") {
                HexCodeField(text: model.hexByteBinding(\.rdsLIC), placeholder: "1D", width: 54)
            }
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
                .frame(width: 130)
                TextField(
                    "AF List",
                    text: model.configBinding(\.rdsAFList, runtimeDisposition: .liveRDS)
                )
                .textFieldStyle(.roundedBorder)
            }
            Text("Method A: up to 25 frequencies as a flat list. Method B: paired (tuned + alternative) — used for stations sharing AF lists across regions.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("Master enable applies live. Subcarrier-physical-layer settings (injection level, frequency, Gaussian shaping) live on the Subcarrier tab and require a transport restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Card(title: "Snapshot", style: .meter) {
            RDSLivePreviewPlate(model: model)
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

            Section("Audio Engine") {
                SystemSettingsSectionContent(model: model)
            }

            Section("Spectrum") {
                Toggle("96 kHz Window", isOn: model.configBinding(\.fftWindow96kHz))
                Text("When enabled, shows full 96 kHz spectrum. When disabled, shows the 60 kHz FM band.")
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

/// macOS-style About panel: app icon + name + version + copyright,
/// stacked centered, with a brief description and disclaimer in plain
/// prose. Matches the Apple HIG About-window pattern (cf. Music.app,
/// Mail.app) rather than a settings-style framed card.
private struct AboutSectionView: View {
    private var appIcon: NSImage? {
        if let icon = NSApp?.applicationIconImage, icon.size.width > 0 {
            return icon
        }
        return NSImage(named: NSImage.applicationIconName)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
            }

            Text("MPX Prime")
                .font(.title2.weight(.semibold))

            Text("Version \(AppConfig.appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Copyright © 2026 Bkram Developments")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Link("github.com/bkram/MPXPrime",
                 destination: URL(string: "https://github.com/bkram/MPXPrime")!)
                .font(.system(size: 11))

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Experimental amateur-grade FM composite (MPX) generator with stereo encoding and optional RDS. Targets core behavior from EN 50067 / IEC 62106 and common FM stereo practice, but is not certified and no compliance warranty is implied.")

                Text("Suitable for LPFM, community radio, prosumer broadcast-style encoding, and study of FM signal processing — not for certified production broadcast. The author assumes no liability for regulatory violations, equipment damage, interference, or any direct or indirect consequences arising from its use. Use at your own risk.")

                Text("Released under GPL-3.0.")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

private struct DoubleSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var accessibilityLabel: String? = nil
    var tooltip: String? = nil

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: $value, in: range)
                    .controlSize(.small)
                    .accessibilityLabel(accessibilityLabel ?? title)
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
    var tooltip: String? = nil

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
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
                .toggleStyle(.checkbox)
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stereo Input").font(.subheadline).foregroundStyle(.secondary)
                    ScopeView(samples: model.inputScopeLeft, secondarySamples: model.inputScopeRight)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("MPX Output").font(.subheadline).foregroundStyle(.secondary)
                    ScopeView(samples: model.outputScope)
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
                MPXSpectrumView(
                    dbBins: model.mpxSpectrumDB,
                    maxHz: model.mpxSpectrumMaxHz,
                    nyquistHz: model.mpxSpectrumNyquistHz
                )
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

            StereoPreMPXSpectrumView(
                leftBins: model.preMPXSpectrumLeftDB,
                rightBins: model.preMPXSpectrumRightDB,
                maxHz: model.preMPXSpectrumMaxHz,
                nyquistHz: model.preMPXSpectrumNyquistHz
            )
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
