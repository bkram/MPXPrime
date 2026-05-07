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

private struct MonitoringStatusLine: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            
            Text(isRunning ? "Running" : "Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
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
    case core = "Core"
    case agc = "AGC"
    case phaseRotator = "Phase Rot"
    case parametricEQ = "PEQ"
    case orbass = "Orbass"
    case widener = "Widener"
    case multiband = "Multiband"
    case mbLimiter = "MB Limiter"
    case expander = "Expander"
    case bassClipper = "Bass Clip"
    case dcClipper = "DC Clipper"
    case limiter = "Limiter"
    case bs412 = "BS.412"
    case compositeClipper = "Comp Clip"

    var id: String { rawValue }

    var resetButtonTitle: String {
        switch self {
        case .overview:
            return "Reset All Processing"
        case .core:
            return "Reset Core Tab"
        case .agc:
            return "Reset AGC Tab"
        case .phaseRotator:
            return "Reset Phase Rotator Tab"
        case .parametricEQ:
            return "Reset PEQ Tab"
        case .orbass:
            return "Reset Orbass Tab"
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
            return "Reset Limiter Tab"
        case .bs412:
            return "Reset BS.412 Tab"
        case .compositeClipper:
            return "Reset Composite Clipper Tab"
        }
    }

    var resetStatusText: String {
        switch self {
        case .overview:
            return "Reset every processing tab to defaults"
        case .core:
            return "Reset processing core tab to defaults"
        case .agc:
            return "Reset AGC tab to defaults"
        case .phaseRotator:
            return "Reset phase rotator tab to defaults"
        case .parametricEQ:
            return "Reset parametric EQ tab to defaults"
        case .orbass:
            return "Reset Orbass tab to defaults"
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
            return "Reset Limiter tab to defaults"
        case .bs412:
            return "Reset BS.412 tab to defaults"
        case .compositeClipper:
            return "Reset composite clipper tab to defaults"
        }
    }
}

enum RDSTab: String, CaseIterable, Identifiable {
    case program = "Program"
    case radiotext = "Radiotext"
    case longPS = "Long PS"
    case flags = "Flags"
    case carrier = "Carrier"

    var id: String { rawValue }

    var resetButtonTitle: String {
        switch self {
        case .program:
            return "Reset Program Tab"
        case .radiotext:
            return "Reset Radiotext Tab"
        case .longPS:
            return "Reset Long PS Tab"
        case .flags:
            return "Reset Flags Tab"
        case .carrier:
            return "Reset Carrier Tab"
        }
    }

    var resetStatusText: String {
        switch self {
        case .program:
            return "Reset RDS program tab to defaults"
        case .radiotext:
            return "Reset RDS radiotext tab to defaults"
        case .longPS:
            return "Reset RDS long PS tab to defaults"
        case .flags:
            return "Reset RDS flags tab to defaults"
        case .carrier:
            return "Reset RDS carrier tab to defaults"
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
                vDSP_zvmags(&split, 1, &magnitudesSq, 1, vDSP_Length(n / 2))
            }
        }

        let invN = 1.0 / Float(n)
        if !magnitudesSq.isEmpty {
            let dcAmp = sqrtf(max(0.0, magnitudesSq[0])) * invN
            spectrumDB[0] = max(-100.0, min(0.0, 20.0 * log10f(max(1e-9, dcAmp))))
        }
        if magnitudesSq.count > 1 {
            for k in 1..<magnitudesSq.count {
                let amp = (2.0 * sqrtf(max(0.0, magnitudesSq[k]))) * invN
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

private struct OrbassPreset {
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
        if vm.autoStartEnabled {
            // WORKAROUND (auto-start input stall): AVAudioEngine has an
            // observed issue where the FIRST start() in a process with a
            // non-default input device fails to deliver tap callbacks —
            // engine.start() returns success, capture.isRunning is true,
            // ring stays at 0/N forever. Manual Stop+Start always recovers
            // because the second AVAudioEngine in the process is fine.
            //
            // What we tried that did NOT fix it:
            //   - 1 s asyncAfter delay (gives runloop time to settle)
            //   - throwaway warmup AVAudioEngine that touches inputNode +
            //     start()/stop()/reset() before the real engine starts
            //   - permission gate via AVCaptureDevice.requestAccess
            //
            // What this workaround does: kick off auto-start, then 1.5 s
            // later check whether the input ring has any samples. If not,
            // run a real Stop+Start cycle (matches what the user does
            // manually, which deterministically fixes it). Adds 0.25 s
            // visible "stall + recover" flash on launch in the failure
            // case; no-op when auto-start succeeds first try.
            //
            // PROPER FIX (future): replace the AVAudioEngine-based capture
            // path in AudioOutputEngine.setupInputCapture with a direct
            // AUHAL audio unit (kAudioUnitSubType_HALOutput, EnableIO on
            // input scope, manual render callback). AUHAL is the
            // Apple-documented capture-from-specific-device path and
            // doesn't have AVAudioEngine's input-binding quirks. Tracked
            // in plan.md "Auto-start input stall workaround".
            DispatchQueue.main.async { [weak vm] in
                vm?.startOrStopTransport(forceStart: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak vm] in
                guard let vm, vm.isRunning, vm.transportInputStalled else { return }
                vm.statusText = "Auto-start input stall detected; cycling engine."
                vm.cycleEngineForRecovery()
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
        w.setContentSize(NSSize(width: 450, height: 500))
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
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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

    private static let monitoringRefreshHz: Double = 30.0
    private static let inlineMPXSpectrumRefreshHz: Double = 12.0
    private static let windowMPXSpectrumRefreshHz: Double = 24.0
    private static let windowPreMPXSpectrumRefreshHz: Double = 24.0
    private static let inlineMPXSpectrumBins: Int = 384
    private static let windowMPXSpectrumBins: Int = 512
    private static let preMPXSpectrumBins: Int = 128
    private static let meterAttackMS: Float = 18.0
    private static let meterReleaseMS: Float = 110.0
    private static let audioPeakMeterAttackMS: Float = 1.0
    private static let audioPeakMeterReleaseMS: Float = 180.0

    @Published var selectedSection: AppSection = .monitoring
    @Published var selectedProcessingTab: ProcessingTab = .overview
    @Published var selectedRDSTab: RDSTab = .program
    @Published var statusText: String = "Idle"
    @Published var pendingRuntimeApply: Bool = false

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
    @Published var compositeClipperGainReductionDBValue: Float = 0.0
    @Published var preEncodeLimiterGainReductionDBValue: Float = 0.0
    @Published var safetyLimiterGainReductionDBValue: Float = 0.0
    @Published var stereoImageText: String = "Corr +1.00 • Side 0.00x"
    @Published var agcStateText: String = "Off"
    @Published var agcDetailText: String = "Detector -inf dB • Gain 0.0 dB"
    @Published var multibandStateText: String = "Off"
    @Published var orbassStateText: String = "Off"
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

    var orbassPresetChoices: [PresetChoice] {
        Self.orbassPresets.map { PresetChoice(id: $0.id, title: $0.title) }
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
        monitorTimer?.invalidate()
        let timer = Timer(timeInterval: (1.0 / Self.monitoringRefreshHz), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMonitoringSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
        timer.fire()
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
        if runtimeDisposition == .live {
            applyLiveRuntimeConfigIfRunning()
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
            set: { self.setConfigValue(\.rdsPTY, max(0, min(31, $0)), runtimeDisposition: .restart) }
        )
    }

    func piBinding() -> Binding<String> {
        Binding(
            get: { self.config.rdsPI },
            set: {
                self.setConfigValue(\.rdsPI, Self.sanitizeHex($0, width: 4), runtimeDisposition: .restart)
            }
        )
    }

    func hexByteBinding(_ keyPath: WritableKeyPath<AppConfig, String>) -> Binding<String> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: {
                self.setConfigValue(keyPath, Self.sanitizeHex($0, width: 2), runtimeDisposition: .restart)
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
        saveConfig(restartRequired: true)
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

    func applyOrbassPreset(id: String) {
        guard let preset = Self.orbassPresets.first(where: { $0.id == id }) else { return }
        publishConfigChange()
        config.orbassEnabled = preset.enabled
        config.orbassPresetID = id
        config.orbassAmount = preset.amount
        config.orbassFreqHz = preset.freqHz
        config.orbassHarmonics = preset.harmonics
        config.orbassDrive = preset.drive
        config.orbassDensity = preset.density
        config.orbassSubharmonicsEnabled = preset.subharmonicsEnabled
        config.orbassSubharmonicsAmount = preset.subharmonicsAmount
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded Orbass preset \(preset.title) live."
            : "Loaded Orbass preset \(preset.title)."
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
        case .orbass:
            config.orbassEnabled = defaults.orbassEnabled
            config.orbassPresetID = defaults.orbassPresetID
            config.orbassAmount = defaults.orbassAmount
            config.orbassFreqHz = defaults.orbassFreqHz
            config.orbassHarmonics = defaults.orbassHarmonics
            config.orbassDrive = defaults.orbassDrive
            config.orbassDensity = defaults.orbassDensity
            config.orbassSubharmonicsEnabled = defaults.orbassSubharmonicsEnabled
            config.orbassSubharmonicsAmount = defaults.orbassSubharmonicsAmount
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
            config.finalStagePresetID = defaults.finalStagePresetID
            config.preEncodeAudioLimiterEnabled = defaults.preEncodeAudioLimiterEnabled
            config.preEncodeThreshold = defaults.preEncodeThreshold
            config.preEncodeReleaseMS = defaults.preEncodeReleaseMS
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
        }

        let runtimeDisposition: RuntimeChangeDisposition
        switch selectedProcessingTab {
        case .core:
            runtimeDisposition = .restart
        case .overview,
             .agc, .orbass, .multiband, .widener, .limiter,
             .phaseRotator, .parametricEQ, .mbLimiter, .expander,
             .bassClipper, .dcClipper, .bs412, .compositeClipper:
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
        case .program:
            config.enRDS = defaults.enRDS
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
        case .flags:
            config.rdsTP = defaults.rdsTP
            config.rdsTA = defaults.rdsTA
            config.rdsMS = defaults.rdsMS
            config.rdsDI_STEREO = defaults.rdsDI_STEREO
            config.rdsDI_HEAD = defaults.rdsDI_HEAD
            config.rdsDI_COMP = defaults.rdsDI_COMP
            config.rdsDI_DYN = defaults.rdsDI_DYN
            config.rdsEnableAF = defaults.rdsEnableAF
            config.rdsAFList = defaults.rdsAFList
            config.rdsAFMethod = defaults.rdsAFMethod
            config.rdsLIC = defaults.rdsLIC
        case .carrier:
            config.rdsLevel = defaults.rdsLevel
            config.rdsGroupSequence = defaults.rdsGroupSequence
            config.rdsSchedulerAuto = defaults.rdsSchedulerAuto
            config.rdsSchedulerStandard = defaults.rdsSchedulerStandard
            config.rdsSchedulerStandardLPS = defaults.rdsSchedulerStandardLPS
            config.rdsEnableCT = defaults.rdsEnableCT
            config.rdsEnableID = defaults.rdsEnableID
            config.rdsTZOffset = defaults.rdsTZOffset
            config.rdsFreq = defaults.rdsFreq
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

    /// True when the transport reports running but the input ring has
    /// received zero samples — the AVAudioEngine first-start input-stall
    /// signature. Used by the auto-start watchdog to decide whether to
    /// trigger an automatic engine cycle.
    var transportInputStalled: Bool {
        guard isRunning, sourceMode.lowercased() == "input" else { return false }
        guard let engine = runningEngine, let snap = engine.transportSnapshot else { return false }
        return snap.bufferedFrames == 0
    }

    /// Cycle the engine: stop, then start again on the next runloop tick.
    /// The auto-start watchdog uses this to recover from a stalled first
    /// start without requiring user interaction.
    func cycleEngineForRecovery() {
        stopEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.startEngine()
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
        let minRefreshInterval = 1.0 / Self.monitoringRefreshHz
        if let last = lastMonitorRefreshTime, (now - last) < minRefreshInterval {
            return
        }

        let dt = max(
            1.0 / (Self.monitoringRefreshHz * 2.0),
            min(0.25, now - (lastMonitorRefreshTime ?? (now - (1.0 / Self.monitoringRefreshHz))))
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
        var preEncodeAudioLimiterGainReductionDB: Float = 0.0
        var mpxSafetyLimiterGainReductionDB: Float = 0.0
        var pilotInjectionPercent: Float = 0.0
        var rdsInjectionPercent: Float = 0.0
        var audioCompositePeak: Float = 0.0
        var compositeBudgetMarginDB: Float = 0.0
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
            preEncodeAudioLimiterGainReductionDB = meters.preEncodeAudioLimiterGainReductionDB
            mpxSafetyLimiterGainReductionDB = meters.mpxSafetyLimiterGainReductionDB
            pilotInjectionPercent = meters.pilotInjectionPercent
            rdsInjectionPercent = meters.rdsInjectionPercent
            audioCompositePeak = meters.audioCompositePeak
            compositeBudgetMarginDB = meters.compositeBudgetMarginDB
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
            compositeClipperGainReductionDBValue = 0.0
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
        compositeClipperGainReductionDBValue = compositeClipperGainReductionDB
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
        orbassStateText = config.orbassEnabled ? "On" : "Off"
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

    private static let orbassPresets: [OrbassPreset] = [
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

    private enum ConfigReloadOrigin {
        case manual
        case external
    }

    enum RuntimeChangeDisposition {
        case restart
        case live
        case none
    }

    private func applyLoadedConfig(_ loadedConfig: AppConfig, origin: ConfigReloadOrigin) {
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
            // deviation / GR / budget / injections. Present across all
            // sections so operators never lose sight of safety metrics.
            BroadcastStatusBar(model: model)

            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $model.selectedSection) {
                        Section {
                            ForEach(AppSection.allCases) { section in
                                Label(section.rawValue, systemImage: section.icon)
                                    .tag(section)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollDisabled(true)

                    Spacer()
                }
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(model.selectedSection.detailTitle)
                            .font(.title2.weight(.semibold))
                        Spacer()
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)

                    Text(model.selectedSection.detailSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 16)

                    Group {
                        switch model.selectedSection {
                        case .monitoring:
                            MonitoringDashboardView(model: model)
                        case .processing:
                            ProcessingSectionView(model: model)
                        case .rds:
                            RDSSectionView(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
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

private struct MonitoringDashboardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Status") {
                    VStack(alignment: .leading, spacing: 12) {
                        MonitoringHealthSummaryRow(health: model.streamHealth)

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
                    }
                }

                Card(title: "Interfaces") {
                    MonitoringInterfacesPanel(
                        inputName: inputName,
                        outputName: outputName,
                        monitorEnabled: model.monitorEnabled,
                        monitorName: monitorName
                    )
                }

                Card(title: "DSP") {
                    MonitoringDSPStatusSectionView(model: model)
                }

                Card(title: "Calibration") {
                    MonitoringCalibrationSectionView(model: model)
                }

                Card(title: "RDS") {
                    MonitoringRDSSnapshotSectionView(model: model)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

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
}

private struct MonitoringTransportHeader: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 12) {
                Spacer()

                if model.runtimeApplyPending {
                    Button(model.runtimeApplyButtonTitle) {
                        model.applyPendingRuntimeChanges()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(model.processingBypass ? "Bypass On" : "Bypass") {
                    model.toggleBypass()
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)

                Button(model.isRunning ? "Stop" : "Start") {
                    model.startOrStopTransport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
            if model.runtimeApplyPending {
                Text(model.runtimeApplyHintText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct MonitoringHealthSummaryRow: View {
    let health: MonitoringStreamHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowStatusRow(items: [
                ("Transport", health.isRunning ? "Running" : "Stopped", indicatorColor),
                ("Buffer", health.bufferSummary, indicatorColor),
                ("Source", health.inputName, .secondary.opacity(0.75)),
            ])

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 180), spacing: 12),
                    GridItem(.flexible(minimum: 180), spacing: 12),
                ],
                alignment: .leading,
                spacing: 12
            ) {
                DSPMetricGroupCard(
                    title: "Stream",
                    subtitle: "Current source and sample-rate path",
                    rows: [
                        ("Input", health.inputName),
                        ("Rates", rateText),
                    ]
                )
                DSPMetricGroupCard(
                    title: "Buffer",
                    subtitle: "Ring fill, estimated delay, and health state",
                    rows: [
                        ("Ring", ringText),
                        ("Delay", delayText),
                        ("Health", health.bufferSummary),
                    ]
                )
                DSPMetricGroupCard(
                    title: "Recent Dropouts",
                    subtitle: "Overflows and underflows over 10 seconds",
                    rows: [
                        ("Over", "\(health.overflowsRecent)"),
                        ("Under", "\(health.underflowsRecent)"),
                    ]
                )
                DSPMetricGroupCard(
                    title: "Totals",
                    subtitle: "Cumulative capture and render faults",
                    rows: [
                        ("Over", "\(health.overflowsTotal)"),
                        ("Under", "\(health.underflowsTotal)"),
                    ]
                )
            }
        }
    }

    private var ringText: String {
        if health.ringCapacity <= 0 {
            return "n/a"
        }
        let percent = Int(max(0.0, min(1.0, health.ringFill)) * 100.0)
        return "\(health.ringFrames) / \(health.ringCapacity) (\(percent)%)"
    }

    private var rateText: String {
        if health.inputHz > 0 {
            return "render \(health.renderHz) Hz • input \(health.inputHz) Hz"
        }
        return "render \(health.renderHz) Hz"
    }

    private var delayText: String {
        guard let delayMS = health.estimatedDelayMS else { return "n/a" }
        if delayMS >= 100.0 {
            return String(format: "%.0f ms", delayMS)
        }
        if delayMS >= 10.0 {
            return String(format: "%.1f ms", delayMS)
        }
        return String(format: "%.2f ms", delayMS)
    }

    private var indicatorColor: Color {
        guard health.isRunning else { return .secondary }
        switch health.bufferHealth {
        case .ok:
            return .green
        case .warn:
            return .orange
        case .bad:
            return .red
        }
    }
}

private struct MonitoringDetailValue: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
            Text(value)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MonitoringRuntimeSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runtime").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
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
                    .accessibilityLabel("Input device")
                }
                LabeledContent("MPX Output") {
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
                    .accessibilityLabel("Output device")
                }
                Toggle(
                    "Enable Monitor Output",
                    isOn: Binding(
                        get: { model.monitorEnabled },
                        set: {
                            model.monitorEnabled = $0
                            model.persistBasicConfig()
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .accessibilityLabel("Enable monitor output")

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
            }
        }
    }
}

private struct MonitoringRDSSnapshotSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        MonitoringRDSPanel(rows: model.rdsRows)
    }
}

private struct MonitoringInterfacesPanel: View {
    let inputName: String
    let outputName: String
    let monitorEnabled: Bool
    let monitorName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowStatusRow(items: [
                ("Source", "Ready", .green),
                ("Output", "Ready", .green),
                ("Monitor", monitorEnabled ? "Enabled" : "Off", monitorEnabled ? .green : .secondary.opacity(0.45)),
            ])

            DashboardMetricGrid {
                DSPMetricGroupCard(
                    title: "Input Source",
                    subtitle: "Active capture device",
                    rows: [
                        ("Device", inputName),
                        ("Role", "Program input"),
                    ]
                )
                DSPMetricGroupCard(
                    title: "Main Output",
                    subtitle: "Transmit and MPX routing",
                    rows: [
                        ("Device", outputName),
                        ("Role", "MPX output"),
                    ]
                )
                DSPMetricGroupCard(
                    title: "Monitor Path",
                    subtitle: "Decoded MPX monitor routing",
                    rows: [
                        ("State", monitorEnabled ? "Enabled" : "Off"),
                        ("Device", monitorEnabled ? monitorName : "—"),
                    ]
                )
            }
        }
    }
}

private struct MonitoringRDSPanel: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowStatusRow(items: summaryItems)

            DashboardMetricGrid {
                DSPMetricGroupCard(
                    title: "Program Service",
                    subtitle: "Station identity and classification",
                    rows: rowsFor(["PS", "PI", "PTY", "PTYN"])
                )
                DSPMetricGroupCard(
                    title: "Advanced Data",
                    subtitle: "RT+ application data and long text",
                    rows: rowsFor(["RT+ App ID", "Long PS"])
                )
                DSPMetricGroupCard(
                    title: "Radiotext",
                    subtitle: "Current transmitted text fields",
                    rows: rowsFor(["Radiotext", "Now Playing"])
                )
            }
        }
    }

    private var rowMap: [String: String] {
        Dictionary(uniqueKeysWithValues: rows)
    }

    private var summaryItems: [(title: String, value: String, color: Color)] {
        let ps = rowMap["PS"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let pty = rowMap["PTY"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let rt = rowMap["Radiotext"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let aid = rowMap["RT+ App ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "OFF"
        return [
            ("PS", ps, .secondary.opacity(0.75)),
            ("PTY", pty, .secondary.opacity(0.75)),
            ("RT", rt == "-" || rt == "—" ? "Idle" : "Live", rt == "-" || rt == "—" ? .secondary.opacity(0.45) : .green),
            ("RT+", aid == "AID: OFF" || aid == "OFF" ? "Off" : "On", aid == "AID: OFF" || aid == "OFF" ? .secondary.opacity(0.45) : .green),
        ]
    }

    private func rowsFor(_ keys: [String]) -> [(String, String)] {
        keys.map { key in
            let rawValue = rowMap[key] ?? "—"
            if key == "RT+ App ID" {
                return (key, formattedAIDValue(rawValue))
            }
            return (key, rawValue)
        }
    }

    private func formattedAIDValue(_ rawValue: String) -> String {
        if rawValue.hasPrefix("AID: ") {
            return String(rawValue.dropFirst(5))
        }
        return rawValue
    }
}

private struct MonitoringLevelsSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel
    private let holdOptions: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0]
    private let fallOptions: [Double] = [6.0, 12.0, 18.0, 24.0, 30.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Levels").font(.headline)

            HStack(spacing: 14) {
                Toggle(
                    "Sticky Peaks",
                    isOn: Binding(
                        get: { model.stickyPeaksEnabled },
                        set: { model.stickyPeaksEnabled = $0 }
                    )
                )
                .toggleStyle(.checkbox)
                Spacer(minLength: 12)
                Picker(
                    "Hold",
                    selection: Binding(
                        get: { model.meterPeakHoldSeconds },
                        set: { model.meterPeakHoldSeconds = $0 }
                    )
                ) {
                    ForEach(holdOptions, id: \.self) { seconds in
                        Text(String(format: "%.1f s", seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 100)
                Picker(
                    "Fall",
                    selection: Binding(
                        get: { model.meterPeakFallDBPerSecond },
                        set: { model.meterPeakFallDBPerSecond = $0 }
                    )
                ) {
                    ForEach(fallOptions, id: \.self) { value in
                        Text(String(format: "%.0f dB/s", value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 110)
                Button("Reset Peaks") {
                    model.resetPeaks()
                }
            }
            .controlSize(.small)
            .font(.callout)

            MeterRow(
                label: "Input L", valueText: model.inputLText, level: model.inputLLevel,
                peakLevel: model.inputLPeakHoldLevel, showsDBScale: true)
            MeterRow(
                label: "Input R", valueText: model.inputRText, level: model.inputRLevel,
                peakLevel: model.inputRPeakHoldLevel, showsDBScale: true)
            MeterRow(
                label: "MPX", valueText: model.outputText, level: model.outputLevel,
                peakLevel: model.outputPeakHoldLevel, showsDBScale: true)
            MeterRow(
                label: "Modulation", valueText: model.modulationText, level: model.modulationLevel,
                peakLevel: model.modulationPeakHoldLevel,
                scaleStyle: .modulation100kHz(limitKHz: model.config.mpxDeviationKHz))
        }
    }
}

private struct MonitoringDSPStatusSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DSP Status").font(.subheadline).foregroundStyle(.secondary)
            DSPOverviewPanel(model: model)
        }
    }

    static func compositeClipperDotColor(for state: String) -> Color {
        if state.caseInsensitiveCompare("Idle") == .orderedSame {
            return .green
        }
        if state.caseInsensitiveCompare("Off") == .orderedSame
            || state.caseInsensitiveCompare("Disabled") == .orderedSame
        {
            return .secondary.opacity(0.45)
        }
        return .red
    }

    static func stereoImageDotColor(for state: String) -> Color {
        if state.caseInsensitiveCompare("Off") == .orderedSame {
            return .secondary.opacity(0.45)
        }
        if state.caseInsensitiveCompare("Safe") == .orderedSame {
            return .green
        }
        if state.caseInsensitiveCompare("Wide") == .orderedSame {
            return .orange
        }
        return .red
    }

    static func compositeBudgetDotColor(for state: String) -> Color {
        if state.caseInsensitiveCompare("Safe") == .orderedSame {
            return .green
        }
        if state.caseInsensitiveCompare("Tight") == .orderedSame {
            return .orange
        }
        if state.caseInsensitiveCompare("Off") == .orderedSame {
            return .secondary.opacity(0.45)
        }
        return .red
    }
}

private struct DSPOverviewPanel: View {
    @ObservedObject var model: MPXPrimeViewModel

    private var limiterMetrics: [(String, String)] {
        metrics(from: model.limiterDetailText)
    }

    private var compositeMetrics: [(String, String)] {
        metrics(from: model.compositeCalibrationText)
    }

    private var stereoMetrics: [(String, String)] {
        metrics(from: model.stereoImageText)
    }

    private var agcMetrics: [(String, String)] {
        [
            ("Detector", metricValue(in: model.agcDetailText, for: "Detector") ?? "—"),
            ("Gain", metricValue(in: model.agcDetailText, for: "Gain") ?? "—"),
            ("State", model.agcStateText),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowStatusRow(items: [
                ("Limiter", model.limiterStateText, MonitoringDSPStatusSectionView.compositeClipperDotColor(for: model.limiterStateText)),
                ("Budget", model.compositeBudgetStateText, MonitoringDSPStatusSectionView.compositeBudgetDotColor(for: model.compositeBudgetStateText)),
                ("AGC", model.agcStateText, agcDotColor),
                ("Multiband", model.multibandStateText, model.multibandStateText.caseInsensitiveCompare("On") == .orderedSame ? .green : .secondary.opacity(0.45)),
                ("Orbass", model.orbassStateText, model.orbassStateText.caseInsensitiveCompare("On") == .orderedSame ? .green : .secondary.opacity(0.45)),
                ("Image", model.widenerStateText, MonitoringDSPStatusSectionView.stereoImageDotColor(for: model.widenerStateText)),
            ])

            DashboardMetricGrid {
                DSPMetricGroupCard(
                    title: "Final Stage",
                    subtitle: "Drive, gain reduction, safety, and peak",
                    rows: limiterMetrics
                )
                DSPMetricGroupCard(
                    title: "Composite Budget",
                    subtitle: "Pilot, RDS, audio headroom, and margin",
                    rows: compositeMetrics
                )
                DSPMetricGroupCard(
                    title: "Stereo Image",
                    subtitle: "Correlation and side-energy balance",
                    rows: stereoMetrics
                )
                DSPMetricGroupCard(
                    title: "AGC Rider",
                    subtitle: "Detector level and active gain riding",
                    rows: agcMetrics
                )
            }
        }
    }

    private var agcDotColor: Color {
        if model.agcStateText.caseInsensitiveCompare("Off") == .orderedSame {
            return .secondary.opacity(0.45)
        }
        if model.agcStateText.caseInsensitiveCompare("Gate") == .orderedSame {
            return .orange
        }
        return .green
    }

    private func metrics(from text: String) -> [(String, String)] {
        text
            .split(separator: "•")
            .map { part in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                let pieces = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if pieces.count == 2 {
                    return (String(pieces[0]), String(pieces[1]))
                }
                return ("Value", trimmed)
            }
    }

    private func metricValue(in text: String, for key: String) -> String? {
        for part in text.split(separator: "•") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\(key) ") else { continue }
            return String(trimmed.dropFirst(key.count + 1))
        }
        return nil
    }
}

private struct MonitoringCalibrationSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Calibration Workflow")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            FlowStatusRow(items: [
                ("Mode", modeState.value, modeState.color),
                ("Pilot", pilotState.value, pilotState.color),
                ("RDS", rdsState.value, rdsState.color),
                ("Budget", budgetState.value, budgetState.color),
                ("Safety", safetyState.value, safetyState.color),
            ])

            DashboardMetricGrid {
                DSPMetricGroupCard(
                    title: "Stereo Services",
                    subtitle: "Pilot and RDS should be calibrated before final loudness alignment",
                    rows: [
                        ("Pilot Target", "8-10%"),
                        ("Pilot Current", String(format: "%.1f %%", model.pilotInjectionPercentValue)),
                        ("RDS Target", "2-4%"),
                        ("RDS Current", String(format: "%.1f %%", model.rdsInjectionPercentValue)),
                    ]
                )
                DSPMetricGroupCard(
                    title: "Deviation & Headroom",
                    subtitle: "Use deviation peak and composite margin as the main calibration gates",
                    rows: [
                        ("Deviation Peak", String(format: "%.1f kHz", model.estimatedDeviationPeakKHz)),
                        ("Deviation Target", String(format: "%.1f kHz", model.config.mpxDeviationKHz)),
                        ("Audio Composite", Self.dbfsString(model.audioCompositePeakLinear)),
                        ("Budget Margin", String(format: "%.1f dB", model.compositeBudgetMarginDBValue)),
                    ]
                )
                DSPMetricGroupCard(
                    title: "Protection",
                    subtitle: "Pre-encode limiter controls L/R peaks; composite clipper is a safety net",
                    rows: [
                        ("Final Drive", String(format: "%.1f dB", model.config.finalDriveDB)),
                        ("Pre-Encode GR", String(format: "%.1f dB", model.preEncodeLimiterGainReductionDBValue)),
                        ("Safety GR", String(format: "%.1f dB", model.safetyLimiterGainReductionDBValue)),
                        ("MPX Output", String(format: "%.1f dB", model.config.outputGainDB)),
                    ]
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(calibrationSteps, id: \.self) { step in
                    Text("• \(step)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stereoServicesActive: Bool {
        model.isRunning && !model.config.monoMode
    }

    private var modeState: (value: String, color: Color) {
        if !model.isRunning {
            return ("Stopped", .secondary.opacity(0.45))
        }
        if model.config.monoMode {
            return ("Mono", .orange)
        }
        return ("Stereo", .green)
    }

    private var pilotState: (value: String, color: Color) {
        guard stereoServicesActive else { return ("Off", .secondary.opacity(0.45)) }
        let value = model.pilotInjectionPercentValue
        if (8.0...10.0).contains(value) {
            return ("On Target", .green)
        }
        if (6.0...12.0).contains(value) {
            return ("Adjust", .orange)
        }
        return ("Risk", .red)
    }

    private var rdsState: (value: String, color: Color) {
        guard stereoServicesActive && model.config.enRDS else {
            return ("Off", .secondary.opacity(0.45))
        }
        let value = model.rdsInjectionPercentValue
        if (2.0...4.0).contains(value) {
            return ("On Target", .green)
        }
        if (1.5...5.0).contains(value) {
            return ("Adjust", .orange)
        }
        return ("Risk", .red)
    }

    private var budgetState: (value: String, color: Color) {
        if !model.isRunning {
            return ("Off", .secondary.opacity(0.45))
        }
        if model.compositeBudgetMarginDBValue >= 3.0 {
            return ("Safe", .green)
        }
        if model.compositeBudgetMarginDBValue >= 1.0 {
            return ("Tight", .orange)
        }
        return ("Risk", .red)
    }

    private var safetyState: (value: String, color: Color) {
        if !model.isRunning {
            return ("Off", .secondary.opacity(0.45))
        }
        if model.safetyLimiterGainReductionDBValue <= 0.05 {
            return ("Idle", .green)
        }
        if model.safetyLimiterGainReductionDBValue <= 0.30 {
            return ("Touching", .orange)
        }
        return ("Active", .red)
    }

    private var calibrationSteps: [String] {
        if !model.isRunning {
            return ["Start the engine, then calibrate with normal program audio in stereo mode."]
        }

        var steps: [String] = []
        if model.config.monoMode {
            steps.append("Disable Mono Mode before calibrating. Pilot and RDS are suppressed while mono is active.")
        } else {
            steps.append("Set Pilot near 8-10% and RDS near 2-4%, then leave them fixed while you align loudness and output.")
        }

        let deviationTarget = Float(model.config.mpxDeviationKHz)
        if model.estimatedDeviationPeakKHz > (deviationTarget + 0.5) {
            steps.append("Estimated deviation peak is over target. Reduce Final Drive first, then use MPX Output Level only for final exciter or interface alignment.")
        } else {
            steps.append("Use Final Drive for loudness and MPX Output Level for final calibration. Do not use AGC target as the main loudness control.")
        }

        if model.compositeBudgetMarginDBValue < 1.0 {
            steps.append("Composite budget margin is at risk. Lower Final Drive, pilot, or RDS injection before pushing loudness harder.")
        } else if model.compositeBudgetMarginDBValue < 3.0 {
            steps.append("Composite budget is usable but tight. Prefer at least 3 dB margin when you want safer exciter headroom.")
        } else {
            steps.append("Composite budget margin is healthy. Keep that margin before reintroducing more stereo width or bass enhancement.")
        }

        if model.safetyLimiterGainReductionDBValue > 0.05 {
            steps.append("Safety limiter should stay mostly idle during calibration. If it moves, back down Final Drive and re-check deviation.")
        } else {
            steps.append("Safety limiter is idle. That is the desired operating state during ordinary alignment.")
        }

        return steps
    }

    private static func dbfsString(_ linear: Float) -> String {
        guard linear > 0.0 else { return "-inf dBFS" }
        return String(format: "%.1f dBFS", 20.0 * log10(linear))
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

private struct RDSSnapshotCardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "RDS Snapshot", style: .meter) {
            RDSLivePreviewPlate(model: model)
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

private struct RDSAdvancedCardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Scheduler & Advanced") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Group Sequence", text: model.configBinding(\.rdsGroupSequence))
                Toggle("Scheduler Auto", isOn: model.configBinding(\.rdsSchedulerAuto))
                Toggle("Use Standard Schedule", isOn: model.configBinding(\.rdsSchedulerStandard))
                Toggle(
                    "Include LPS in Standard",
                    isOn: model.configBinding(\.rdsSchedulerStandardLPS))
                Toggle("Enable CT (4A)", isOn: model.configBinding(\.rdsEnableCT))
                Toggle("Enable ID (1A)", isOn: model.configBinding(\.rdsEnableID))

                Divider()

                LabeledContent("LIC") {
                    HexCodeField(text: model.hexByteBinding(\.rdsLIC), placeholder: "1D", width: 54)
                }
                DoubleSliderRow(
                    title: "Clock Offset", value: model.configBinding(\.rdsTZOffset),
                    range: -12...14, format: "%.1f h")
            }
        }
    }
}

private struct LevelsCardView: View {
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
                VerticalMeterStrip(
                    label: "GR",
                    valueText: String(format: "%.1f dB", Double(model.compositeClipperGainReductionDBValue)),
                    level: max(0.0, min(1.0, Double(model.compositeClipperGainReductionDBValue) / 16.0)),
                    peakLevel: nil,
                    scale: .gainReductionDB
                )
                VerticalMeterStrip(
                    label: "SAFE",
                    valueText: String(format: "%.1f dB", Double(model.safetyLimiterGainReductionDBValue)),
                    level: max(0.0, min(1.0, Double(model.safetyLimiterGainReductionDBValue) / 16.0)),
                    peakLevel: nil,
                    scale: .gainReductionDB
                )
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

private struct DSPStatusCardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "DSP Overview") {
            DSPOverviewPanel(model: model)
        }
    }
}

private struct ScopeView: View {
    let samples: [Float]
    var secondarySamples: [Float]? = nil

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 8), with: .color(.black.opacity(0.22)))

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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

private struct MPXSpectrumView: View {
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
                    Path(roundedRect: rect, cornerRadius: 8), with: .color(.black.opacity(0.30)))
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

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

private struct ProcessingSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.selectedProcessingTab) {
                ForEach(ProcessingTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.selectedProcessingTab {
                    case .overview:
                        ProcessingOverviewGrid(model: model)
                    case .core:
                        ProcessingCoreTab(model: model)
                    case .agc:
                        ProcessingAGCTab(model: model)
                    case .phaseRotator:
                        ProcessingPhaseRotatorTab(model: model)
                    case .parametricEQ:
                        ProcessingParametricEQTab(model: model)
                    case .orbass:
                        ProcessingOrbassTab(model: model)
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
                    }

                    // Overview has no per-tab reset action.
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

private struct ProcessingCoreTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Core Processing") {
            Toggle("Bypass Processing", isOn: Binding(
                get: { model.processingBypass },
                set: { _ in model.toggleBypass() }
            ))
            Toggle("Mono Mode", isOn: model.configBinding(\.monoMode))
            Text("Mono Mode disables the stereo pilot, 38 kHz stereo subcarrier, and RDS so the transmitted composite is true mono.")
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
            ), range: -24...24, format: "%.1f dB")
            DoubleSliderRow(
                title: "MPX Output Level",
                value: model.configBinding(\.outputGainDB, runtimeDisposition: .live),
                range: -18...18,
                format: "%.1f dB"
            )
            Text("Use MPX Output Level for final transmit/output calibration. Do not use AGC target as the main loudness knob.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Use Monitoring > Calibration to align pilot, RDS, deviation peak, composite margin, and safety-limiter headroom.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DoubleSliderRow(title: "HPF", value: model.configBinding(\.hpfHz), range: 10...180, format: "%.0f Hz")
            DoubleSliderRow(title: "HF Trim", value: model.configBinding(\.hfTrimDB), range: -12...12, format: "%.1f dB")
            DoubleSliderRow(title: "HF Trim Freq", value: model.configBinding(\.hfTrimHz), range: 1_000...12_000, format: "%.0f Hz")
            DoubleSliderRow(title: "Program Lowpass", value: model.configBinding(\.programLowpassHz), range: 8_000...17_000, format: "%.0f Hz")
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

private struct ProcessingOrbassTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Orbass") {
            Picker("Preset", selection: Binding(
                get: { self.model.config.orbassPresetID },
                set: { newValue in
                    self.model.config.orbassPresetID = newValue
                    self.model.applyOrbassPreset(id: newValue)
                }
            )) {
                ForEach(model.orbassPresetChoices) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            Toggle("Enable Orbass", isOn: model.configBinding(\.orbassEnabled, runtimeDisposition: .live))
            DoubleSliderRow(title: "Amount", value: model.configBinding(\.orbassAmount, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Overall strength of the low-band enhancement. Higher values emphasize bass; too high introduces pumping and obvious low-frequency coloration.")
            DoubleSliderRow(title: "Frequency", value: model.configBinding(\.orbassFreqHz, runtimeDisposition: .live), range: 40...180, format: "%.1f Hz",
                tooltip: "Corner frequency of the low-band enhancement. Lower frequencies emphasize sub-bass, higher frequencies emphasize upper bass.")
            DoubleSliderRow(title: "Harmonics", value: model.configBinding(\.orbassHarmonics, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Adds restrained harmonic overtones so bass remains audible on small speakers that can't reproduce the fundamental.")
            DoubleSliderRow(title: "Drive", value: model.configBinding(\.orbassDrive, runtimeDisposition: .live), range: 0.2...2.0, format: "%.2f",
                tooltip: "Input level into the nonlinear enhancement stage. Higher drive increases harmonics intensity and perceived density.")
            DoubleSliderRow(title: "Density", value: model.configBinding(\.orbassDensity, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Smoothing of the enhancement envelope. Higher density reduces attack transients in the low band for a more sustained feel.")
            Toggle("Enable Subharmonics", isOn: model.configBinding(\.orbassSubharmonicsEnabled, runtimeDisposition: .live))
            DoubleSliderRow(title: "Subharmonics", value: model.configBinding(\.orbassSubharmonicsAmount, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Synthesizes an octave-below reinforcement for fundamentals. Use sparingly — easily over-emphasizes sub-40 Hz content.")
                .disabled(!model.config.orbassSubharmonicsEnabled)
        }
    }
}

private struct ProcessingMultibandTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Multiband Dynamics") {
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
            DoubleSliderRow(title: "Knee", value: model.configBinding(\.multibandKneeDB, runtimeDisposition: .live), range: 0...12, format: "%.1f dB",
                tooltip: "Width of the soft transition around each band's threshold. Larger knee = gentler onset of compression.")
            DoubleSliderRow(title: "Link", value: model.configBinding(\.multibandLinkStrength, runtimeDisposition: .live), range: 0...1, format: "%.2f",
                tooltip: "How much gain reduction is shared across bands. 0 = independent (dense), 1 = linked (preserves spectral balance).")
            Toggle("Program-dependent Release", isOn: model.configBinding(\.multibandReleaseProgramDependent, runtimeDisposition: .live))
            DoubleSliderRow(title: "X1", value: model.configBinding(\.multibandX1Hz, runtimeDisposition: .live), range: 30...300, format: "%.0f Hz",
                tooltip: "Low / Low-Mid crossover frequency. Separates kick/bass from low-mid body.")
            DoubleSliderRow(title: "X2", value: model.configBinding(\.multibandX2Hz, runtimeDisposition: .live), range: 120...1200, format: "%.0f Hz",
                tooltip: "Low-Mid / Mid crossover frequency. Separates body from upper-vocal and presence region.")
            DoubleSliderRow(title: "X3", value: model.configBinding(\.multibandX3Hz, runtimeDisposition: .live), range: 600...4000, format: "%.0f Hz",
                tooltip: "Mid / High-Mid crossover frequency. Separates vocal presence from upper consonants and sibilance.")
            DoubleSliderRow(title: "X4", value: model.configBinding(\.multibandX4Hz, runtimeDisposition: .live), range: 2500...12000, format: "%.0f Hz",
                tooltip: "High-Mid / High crossover frequency. Separates sibilance region from air / top-end.")
            DoubleSliderRow(title: "Low Threshold", value: model.configBinding(\.multibandLowThresholdDB, runtimeDisposition: .live), range: (-40)...(-6), format: "%.1f dB",
                tooltip: "Low band compression threshold. Material above this level is attenuated by the low ratio.")
            DoubleSliderRow(title: "Mid Threshold", value: model.configBinding(\.multibandMidThresholdDB, runtimeDisposition: .live), range: (-40)...(-6), format: "%.1f dB",
                tooltip: "Mid band compression threshold. Material above this level is attenuated by the mid ratio.")
            DoubleSliderRow(title: "High Threshold", value: model.configBinding(\.multibandHighThresholdDB, runtimeDisposition: .live), range: (-40)...(-6), format: "%.1f dB",
                tooltip: "High band compression threshold. Material above this level is attenuated by the high ratio.")
            DoubleSliderRow(title: "Low Ratio", value: model.configBinding(\.multibandLowRatio, runtimeDisposition: .live), range: 1...8, format: "%.2f",
                tooltip: "Low band compression ratio. 1:1 = no compression; higher ratios flatten dynamics more aggressively.")
            DoubleSliderRow(title: "Mid Ratio", value: model.configBinding(\.multibandMidRatio, runtimeDisposition: .live), range: 1...8, format: "%.2f",
                tooltip: "Mid band compression ratio. Vocals and leads live here — moderate values (2:1–4:1) are typical.")
            DoubleSliderRow(title: "High Ratio", value: model.configBinding(\.multibandHighRatio, runtimeDisposition: .live), range: 1...8, format: "%.2f",
                tooltip: "High band compression ratio. Controls sibilance and cymbal energy.")
            DoubleSliderRow(title: "Low Attack", value: model.configBinding(\.multibandLowAttackMS, runtimeDisposition: .live), range: 1...120, format: "%.1f",
                tooltip: "Low band attack time in ms. Slow attacks preserve transients; fast attacks tighten the low end.")
            DoubleSliderRow(title: "Mid Attack", value: model.configBinding(\.multibandMidAttackMS, runtimeDisposition: .live), range: 1...120, format: "%.1f",
                tooltip: "Mid band attack time in ms. Slower values preserve vocal consonants; faster values increase density.")
            DoubleSliderRow(title: "High Attack", value: model.configBinding(\.multibandHighAttackMS, runtimeDisposition: .live), range: 1...120, format: "%.1f",
                tooltip: "High band attack time in ms. Fast attack tames sibilance; slow attack preserves air.")
            DoubleSliderRow(title: "Low Release", value: model.configBinding(\.multibandLowReleaseMS, runtimeDisposition: .live), range: 40...1200, format: "%.0f",
                tooltip: "Low band release time in ms. Longer release prevents bass pumping at the cost of average level recovery speed.")
            DoubleSliderRow(title: "Mid Release", value: model.configBinding(\.multibandMidReleaseMS, runtimeDisposition: .live), range: 40...1200, format: "%.0f",
                tooltip: "Mid band release time in ms. Typical vocal release; shorter = more density, longer = more transparent.")
            DoubleSliderRow(title: "High Release", value: model.configBinding(\.multibandHighReleaseMS, runtimeDisposition: .live), range: 40...1200, format: "%.0f",
                tooltip: "High band release time in ms. Shorter release brightens; longer release keeps the top smooth.")
            DoubleSliderRow(title: "Makeup", value: model.configBinding(\.multibandMakeupDB, runtimeDisposition: .live), range: -12...18, format: "%.1f dB",
                tooltip: "Overall gain applied after multiband processing. Set to offset average level loss from compression; not a loudness control.")
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
            Toggle("Enable Pre-Encode Limiter", isOn: model.configBinding(\.preEncodeAudioLimiterEnabled, runtimeDisposition: .live))
            DoubleSliderRow(
                title: "Final Drive",
                value: model.configBinding(\.finalDriveDB, runtimeDisposition: .live),
                range: 0...12,
                format: "%.1f dB",
                tooltip: "Drive into the composite clipper. The primary loudness control. Higher drive = hotter, more clipping; sustained high attenuation means too hot."
            )
            Text("Broadcast Preset updates AGC platform and final-stage drive together. Final Drive feeds the composite clipper before MPX Output Level calibration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DoubleSliderRow(title: "Composite Deviation", value: model.configBinding(\.mpxDeviationKHz, runtimeDisposition: .live), range: 40...90, format: "%.1f kHz",
                tooltip: "Target peak FM deviation. 75 kHz = ITU-R BS.450 / US FM; 50 kHz = some European reduced-deviation mandates.")
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
            DoubleSliderRow(title: "Window", value: model.configBinding(\.bs412WindowSeconds, runtimeDisposition: .live), range: 1...120, format: "%.0f s",
                tooltip: "Rolling averaging window for BS.412 power measurement. 60 s is the regulatory default.").disabled(disabled)
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
            let disabled = !model.config.compositeClipperEnabled
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.compositeClipperThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Onset of composite-level soft clipping on the audio composite (not pilot/RDS). Primary loudness lever when engaged.").disabled(disabled)
            DoubleSliderRow(title: "Ceiling", value: model.configBinding(\.compositeClipperCeilingDB, runtimeDisposition: .live), range: -6...0, format: "%.1f dB",
                tooltip: "Maximum output level after composite clipping. Must stay below 0 dBFS to leave headroom for pilot/RDS injection.").disabled(disabled)
            Text("8x oversampled tanh soft-clip on audio composite with additive distortion cancellation (Orban US 4,460,871 / 5,737,434). Primary loudness lever: peaks above Threshold are shaped toward Ceiling. Bandpass-isolated clip residual is subtracted from the 17-21 kHz pilot guard, 23-53 kHz stereo subcarrier, and 55-59 kHz RDS guard so those bands stay clean. Placed before BS.412 and safety limiter. Pilot and RDS are injected after this stage.")
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

            Toggle("Mono Mode", isOn: model.configBinding(\.monoMode))
            Text("Mono Mode transmits true mono composite only. Pilot and RDS are suppressed while it is enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)

            DoubleSliderRow(
                title: "Pilot Level", value: model.configBinding(\.pilotLevel),
                range: 0...0.2, format: "%.3f")
            .disabled(model.config.monoMode)
            DoubleSliderRow(
                title: "Sum Level", value: model.configBinding(\.sumLevel),
                range: 0...1.5, format: "%.2f")
            DoubleSliderRow(
                title: "Diff Level", value: model.configBinding(\.diffLevel),
                range: 0...1.5, format: "%.2f")
            .disabled(model.config.monoMode)

            InlineRestartRequiredNote(
                text: "Sample rate, block size, mono mode, pre-emphasis, pilot/sum/diff levels, program lowpass, and other encoder-structure changes."
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

private struct RDSSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.selectedRDSTab) {
                ForEach(RDSTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.selectedRDSTab {
                    case .program:
                        RDSProgramTab(model: model)
                    case .radiotext:
                        RDSRadiotextTab(model: model)
                    case .longPS:
                        RDSLongPSTab(model: model)
                    case .flags:
                        RDSFlagsTab(model: model)
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
}

private struct RDSProgramTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Program Service") {
            Toggle("Enable RDS", isOn: model.configBinding(\.enRDS))
            PSBankRow(letter: "A", model: model, path: \.rdsPSA)
            PSBankRow(letter: "B", model: model, path: \.rdsPSB)
            PSBankRow(letter: "C", model: model, path: \.rdsPSC)
            PSBankRow(letter: "D", model: model, path: \.rdsPSD)
            Toggle("Center PS", isOn: model.configBinding(\.rdsPSCentered))
            DoubleSliderRow(
                title: "PS Frame",
                value: model.configBinding(\.rdsPSFrameSeconds),
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
            Toggle("Enable PTYN", isOn: model.configBinding(\.rdsEnablePTYN))
            TextField("PTYN", text: model.configBinding(\.rdsPTYN))
            Toggle("Center PTYN", isOn: model.configBinding(\.rdsPTYNCentered))
        }

        Card(title: "Snapshot", style: .meter) {
            RDSLivePreviewPlate(model: model)
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
                model.config.rdsPSActiveBank = letter
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

            TextField("", text: model.configBinding(path))
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
            TextField("Single Radiotext", text: model.configBinding(\.rdsRTText))
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
            Picker("RT Mode", selection: model.configBinding(\.rdsRTMode)) {
                Text("2A (64 chars)").tag("2A")
                Text("2B (32 chars)").tag("2B")
            }
            .pickerStyle(.segmented)
            DoubleSliderRow(
                title: "Cycle Time", value: model.configBinding(\.rdsRTCycleTime),
                range: 1...20, format: "%.1f s")
            Toggle("Center RT", isOn: model.configBinding(\.rdsRTCentered))
            Toggle("Append CR", isOn: model.configBinding(\.rdsRTCR))
            Toggle("Enable RT+", isOn: model.configBinding(\.rdsEnableRTPlus))
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
                TextField("RT+ Format A", text: model.configBinding(\.rdsRTPlusFormatA))
                TextField("RT+ Format B", text: model.configBinding(\.rdsRTPlusFormatB))
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
            Toggle("Enable Long PS (15A)", isOn: model.configBinding(\.rdsEnableLPS))
            TextField("Long PS Text", text: model.configBinding(\.rdsLongPS32))
            Toggle("Center Long PS", isOn: model.configBinding(\.rdsLPSCentered))
            Toggle("Append CR", isOn: model.configBinding(\.rdsLPSCR))
        }
    }
}

private struct RDSFlagsTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Flags") {
            LazyVGrid(columns: [
                GridItem(.flexible(minimum: 100)),
                GridItem(.flexible(minimum: 100)),
                GridItem(.flexible(minimum: 100))
            ], alignment: .leading, spacing: 8) {
                Toggle("TP", isOn: model.configBinding(\.rdsTP))
                Toggle("TA", isOn: model.configBinding(\.rdsTA))
                Toggle("MS", isOn: model.configBinding(\.rdsMS))
                Toggle("DI Stereo", isOn: model.configBinding(\.rdsDI_STEREO))
                Toggle("DI Head", isOn: model.configBinding(\.rdsDI_HEAD))
                Toggle("DI Comp", isOn: model.configBinding(\.rdsDI_COMP))
                Toggle("DI Dyn PTY", isOn: model.configBinding(\.rdsDI_DYN))
            }
            .toggleStyle(.switch)

            Toggle("Enable AF", isOn: model.configBinding(\.rdsEnableAF))
            HStack(spacing: 12) {
                Picker("AF Method", selection: model.configBinding(\.rdsAFMethod)) {
                    Text("Method A").tag("A")
                    Text("Method B").tag("B")
                }
                .frame(width: 100)
                TextField("AF List", text: model.configBinding(\.rdsAFList))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

private struct RDSCarrierTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "RDS Carrier") {
            DoubleSliderRow(
                title: "RDS Level", value: model.configBinding(\.rdsLevel),
                range: 0...7.5, format: "%.2f kHz")
            DoubleSliderRow(
                title: "Subcarrier Frequency", value: model.configBinding(\.rdsFreq),
                range: 40_000...80_000, format: "%.0f Hz")
            Toggle("Gaussian Shaping", isOn: model.configBinding(\.rdsGaussianEnabled))
            DoubleSliderRow(
                title: "Gaussian BW", value: model.configBinding(\.rdsGaussianBWHZ),
                range: 600...6_000, format: "%.0f Hz")
            IntStepperRow(
                title: "Gaussian Taps", value: model.oddTapBinding(), range: 9...401,
                step: 2, format: "%d")
        }

        Card(title: "Scheduler & Advanced") {
            TextField("Group Sequence", text: model.configBinding(\.rdsGroupSequence))
            Toggle("Scheduler Auto", isOn: model.configBinding(\.rdsSchedulerAuto))
            Toggle("Use Standard Schedule", isOn: model.configBinding(\.rdsSchedulerStandard))
            Toggle(
                "Include LPS in Standard",
                isOn: model.configBinding(\.rdsSchedulerStandardLPS))
            Toggle("Enable CT (4A)", isOn: model.configBinding(\.rdsEnableCT))
            Toggle("Enable ID (1A)", isOn: model.configBinding(\.rdsEnableID))
            LabeledContent("LIC") {
                HexCodeField(text: model.hexByteBinding(\.rdsLIC), placeholder: "1D", width: 54)
            }
            DoubleSliderRow(
                title: "Clock Offset", value: model.configBinding(\.rdsTZOffset),
                range: -12...14, format: "%.1f h")
        }
    }
}

private struct RDSAdvancedTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "RDS Carrier") {
            DoubleSliderRow(
                title: "RDS Level", value: model.configBinding(\.rdsLevel),
                range: 0...7.5, format: "%.2f kHz")
            DoubleSliderRow(
                title: "Subcarrier Frequency", value: model.configBinding(\.rdsFreq),
                range: 40_000...80_000, format: "%.0f Hz")
            Toggle("Gaussian Shaping", isOn: model.configBinding(\.rdsGaussianEnabled))
            DoubleSliderRow(
                title: "Gaussian BW", value: model.configBinding(\.rdsGaussianBWHZ),
                range: 600...6_000, format: "%.0f Hz")
            IntStepperRow(
                title: "Gaussian Taps", value: model.oddTapBinding(), range: 9...401,
                step: 2, format: "%d")
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
                    Button("Reload Config") { model.reloadConfigFromDisk() }
                    Button("Refresh Devices") { model.refreshDevices() }
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
                Text("• Untimed plain text holds for 10 s before repeating.")
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

private struct HelpSectionView: View {
    var body: some View {
        Form {
            Section("Input Levels") {
                Text("Target levels for FM broadcast:")
                HStack {
                    VStack(alignment: .leading) {
                        Text("Peak").font(.caption).foregroundStyle(.secondary)
                        Text("-18 to -6 dBFS").font(.callout.monospaced())
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Average RMS").font(.caption).foregroundStyle(.secondary)
                        Text("-24 to -20 dBFS").font(.callout.monospaced())
                    }
                }
                Text("US: -20 dBFS nominal | Europe (EBU R68): -18 dBFS | Hot: -6 dBFS peak")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Keep average around -24 dB with peaks between -18 and -6 dBFS. If hitting 0 dBFS, reduce input gain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("RDS Text Format") {
                Text("PS Dynamic and RT support timed text segments:")
                Text("10s:First/10s:Second").font(.callout.monospaced()).foregroundStyle(.blue)
                Text("Shows 'First' for 10 seconds, then 'Second' for 10 seconds, then repeats.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Examples:").font(.caption.bold())
                    Spacer()
                }
                Text("5s:MPX Prime - 5s:FM Coder").font(.caption.monospaced())
                Text("20s:Station Name/10s:Now Playing").font(.caption.monospaced())
                Text("8s:Tune to 88.5/8s:My Frequency").font(.caption.monospaced())
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }
}

private struct AboutSectionView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MPX Prime")
                        .font(.title2.weight(.semibold))
                    Text("Version \(AppConfig.appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Copyright © 2026 Bkram Developments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Project Repository", destination: URL(string: "https://github.com/bkram/MPXPrime")!)
                        .font(.caption)
                }
                .padding(.vertical, 4)
            }

            Section {
                DisclaimerBox()
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }
}

private struct DisclaimerBox: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Disclaimer")
                    .font(.headline)
            }
            
            Text("MPX Prime is a native macOS FM composite (MPX) generator with stereo encoding, optional RDS, and decoded monitor output.")
                .font(.caption)

            Text("This software is provided for experimental and educational purposes only and is not suitable for production broadcast use.")
                .font(.caption)
            
            Text("It may not conform to any applicable technical standards, regulatory requirements, or broadcast specifications related to:")
                .font(.caption)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("• RDS (Radio Data System)")
                Text("• FM composite (MPX) signal generation")
                Text("• RDS multiplex (RDS-MX) generation")
                Text("• Modulation accuracy, deviation limits, or spectral purity")
                Text("• Regional standards (e.g. EN 50067, IEC 62106, NRSC, ITU-R)")
            }
            .font(.caption)
            .padding(.leading, 8)
            
            Text("No warranty, guarantee, or representation is made that:")
                .font(.caption)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("• The generated composite or RDS signal meets required specifications")
                Text("• The output is suitable for on-air transmission")
                Text("• The software complies with any national or international broadcast regulations")
            }
            .font(.caption)
            .padding(.leading, 8)
            
            Text("Use of this software for transmission may require proper certification, measurement, and regulatory approval. The author assumes no liability for regulatory violations, equipment damage, interference, or any direct or indirect consequences arising from its use.")
                .font(.caption)
            
            Text("Use at your own risk.")
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
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
                MPXSpectrumView(
                    dbBins: leftBins,
                    maxHz: maxHz,
                    nyquistHz: nyquistHz
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                MPXSpectrumView(
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
