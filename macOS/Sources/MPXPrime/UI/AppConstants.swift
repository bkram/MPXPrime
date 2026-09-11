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
let kWindowWidth: CGFloat = 860
let kWindowHeight: CGFloat = 440
let kWindowMinWidth: CGFloat = 760
let kWindowMinHeight: CGFloat = 380
// Six 64 pt meter strips (~444 pt) + card/window padding fit comfortably in
// ~560 pt; the prior 860/760 defaults left half the window empty (the meters
// are left-aligned, not stretched).
let kLevelsWindowWidth: CGFloat = 560
let kLevelsWindowHeight: CGFloat = 560
let kLevelsWindowMinWidth: CGFloat = 480
let kLevelsWindowMinHeight: CGFloat = 460
let kMPXPrimeIconSymbol = "\u{1F3A7}"
let kScopesWindowTitle = "Scopes"
let kMPXSpectrumWindowTitle = "MPX Spectrum"
let kAudioSpectrumWindowTitle = "Audio Spectrum"
let kLevelsWindowTitle = "Levels"
// Window-frame autosave keys (UserDefaults).
let kMainWindowAutosaveName = "MPXPrimeStudio.MainWindow"
let kScopesWindowAutosaveName = "MPXPrimeStudio.ScopesWindow"
let kSpectrumWindowAutosaveName = "MPXPrimeStudio.SpectrumWindow"
let kPreMPXSpectrumWindowAutosaveName = "MPXPrimeStudio.PreMPXSpectrumWindow"
let kLevelsWindowAutosaveName = "MPXPrimeStudio.LevelsWindow"
let kAboutWindowAutosaveName = "MPXPrimeStudio.AboutWindow"
let kHelpWindowAutosaveName = "MPXPrimeStudio.HelpWindow"
let kSettingsWindowAutosaveName = "MPXPrimeStudio.SettingsWindow"
// Compile-time constant URL; literal is well-formed so the optional
// returned by URL(string:) is guaranteed non-nil.
let kProjectURL = URL(string: "https://github.com/bkram/MPXPrime")!
let kManualURL = URL(string: "https://github.com/bkram/MPXPrime/blob/main/docs/studio-operator-guide.md")!
let kLicenseURL = URL(string: "https://github.com/bkram/MPXPrime/blob/main/LICENSE")!
let kRestartRequiredSettingsListText =
    "Restart required for sample rate, block size, source mode, monitor output routing, input/output/monitor device changes, mono mode, pre-emphasis, pilot/sum/diff levels, program lowpass, and other encoder-structure changes."

func makeMPXPrimeAppIcon(size: CGFloat = 512) -> NSImage {
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

#endif  // os(macOS)
