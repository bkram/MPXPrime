#!/usr/bin/env swift
// Generates the MPX Prime Meter app icon: an analyzer VU gauge (arc scale +
// needle) over a stylized MPX spectrum bar, in a teal "receive/measure"
// palette -- a deliberate sibling to the MPX Prime Studio tower icon so the two
// apps read as a matched pair but are distinct in the Dock.
// Run: swift generate_meter_icon.swift

import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size
    let r = s * 0.185  // corner radius (macOS icon shape)

    // Background: dark teal gradient (analyzer / receive feel).
    let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                              xRadius: r, yRadius: r)
    let topColor = NSColor(red: 0.10, green: 0.20, blue: 0.22, alpha: 1.0)
    let bottomColor = NSColor(red: 0.05, green: 0.10, blue: 0.12, alpha: 1.0)
    NSGradient(starting: bottomColor, ending: topColor)!.draw(in: bgPath, angle: 90)

    // VU gauge geometry: an arc centered low-center, sweeping ~ -60..+60 deg
    // from vertical, with a needle near the top of the scale.
    let cx = s * 0.5
    let cy = s * 0.30
    let radius = s * 0.40
    let startA = CGFloat.pi * 0.78   // left end
    let endA = CGFloat.pi * 0.22     // right end (smaller angle = more to the right)

    // Scale arc.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor(red: 0.45, green: 0.85, blue: 0.70, alpha: 0.55).cgColor)
    ctx.setLineWidth(s * 0.018)
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
               startAngle: endA, endAngle: startA, clockwise: false)
    ctx.strokePath()

    // Tick marks along the arc.
    let ticks = 9
    for i in 0...ticks {
        let f = CGFloat(i) / CGFloat(ticks)
        let a = startA + (endA - startA) * f
        let inner = radius - s * 0.035
        let outer = radius + s * 0.005
        // Upper part of the scale (right side) is the "over" zone -> warm tint.
        let warm = f > 0.72
        ctx.setStrokeColor((warm
            ? NSColor(red: 1.0, green: 0.5, blue: 0.35, alpha: 0.95)
            : NSColor(red: 0.55, green: 0.95, blue: 0.80, alpha: 0.9)).cgColor)
        ctx.setLineWidth(s * (i % 2 == 0 ? 0.012 : 0.007))
        ctx.move(to: CGPoint(x: cx + cos(a) * inner, y: cy + sin(a) * inner))
        ctx.addLine(to: CGPoint(x: cx + cos(a) * outer, y: cy + sin(a) * outer))
        ctx.strokePath()
    }

    // Needle (points to ~80% of scale -- a healthy-but-hot reading).
    let needleA = startA + (endA - startA) * 0.80
    let needleLen = radius - s * 0.02
    ctx.setStrokeColor(NSColor(red: 0.95, green: 0.97, blue: 0.98, alpha: 1.0).cgColor)
    ctx.setLineWidth(s * 0.020)
    ctx.move(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx + cos(needleA) * needleLen,
                            y: cy + sin(needleA) * needleLen))
    ctx.strokePath()
    // Needle hub.
    ctx.setFillColor(NSColor(red: 0.85, green: 0.90, blue: 0.92, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - s * 0.03, y: cy - s * 0.03,
                               width: s * 0.06, height: s * 0.06))

    // MPX spectrum bar at the bottom -- brand tie to the Studio icon.
    let barY = s * 0.085
    let barH = s * 0.11
    let barX = s * 0.14
    let barW = s * 0.72
    // Audio block (teal).
    ctx.setFillColor(NSColor(red: 0.25, green: 0.75, blue: 0.65, alpha: 0.8).cgColor)
    ctx.fill(CGRect(x: barX, y: barY, width: barW * 0.25, height: barH * 0.9))
    // Pilot spike (yellow).
    ctx.setFillColor(NSColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 0.9).cgColor)
    ctx.fill(CGRect(x: barX + barW * 0.32, y: barY, width: barW * 0.02, height: barH))
    // Stereo subcarrier block (blue).
    ctx.setFillColor(NSColor(red: 0.3, green: 0.55, blue: 0.9, alpha: 0.55).cgColor)
    ctx.fill(CGRect(x: barX + barW * 0.38, y: barY, width: barW * 0.38, height: barH * 0.62))
    // RDS spike (magenta).
    ctx.setFillColor(NSColor(red: 0.8, green: 0.35, blue: 0.7, alpha: 0.75).cgColor)
    ctx.fill(CGRect(x: barX + barW * 0.82, y: barY, width: barW * 0.02, height: barH * 0.5))

    // "MPX" label between the gauge and the bar.
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.060, weight: .bold),
        .foregroundColor: NSColor(red: 0.85, green: 0.92, blue: 0.90, alpha: 0.9)
    ]
    let text = "MPX" as NSString
    let tsz = text.size(withAttributes: textAttrs)
    text.draw(at: NSPoint(x: cx - tsz.width / 2, y: s * 0.205), withAttributes: textAttrs)

    image.unlockFocus()
    return image
}

let iconsetDir = "/tmp/MPXPrimeMeter.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for entry in sizes {
    let image = drawIcon(size: entry.size)
    guard let tiff = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiff),
          let pngData = bitmapRep.representation(using: .png, properties: [:])
    else { print("Failed to render \(entry.name)"); continue }
    let path = (iconsetDir as NSString).appendingPathComponent(entry.name)
    try! pngData.write(to: URL(fileURLWithPath: path))
}

print("Iconset at: \(iconsetDir)")
print("Convert: iconutil --convert icns \(iconsetDir) --output macOS/Resources/MPXPrimeMeter.icns")
