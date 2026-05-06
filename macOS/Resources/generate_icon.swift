#!/usr/bin/env swift
// Generates an MPX Prime app icon: radio tower with broadcast waves
// and a stylized MPX spectrum bar at the bottom.
// Run: swift generate_icon.swift

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

    // Background: dark blue-grey gradient (broadcast console feel)
    let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                               xRadius: r, yRadius: r)
    let topColor = NSColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 1.0)
    let bottomColor = NSColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 1.0)
    let gradient = NSGradient(starting: bottomColor, ending: topColor)!
    gradient.draw(in: bgPath, angle: 90)

    // Radio tower (center, stylized triangle)
    let towerCx = s * 0.5
    let towerTop = s * 0.82
    let towerBottom = s * 0.30
    let towerHalfW = s * 0.035
    let towerBaseHalfW = s * 0.10

    ctx.setFillColor(NSColor(red: 0.75, green: 0.80, blue: 0.85, alpha: 1.0).cgColor)

    // Main tower body (tapered)
    let tower = CGMutablePath()
    tower.move(to: CGPoint(x: towerCx - towerHalfW, y: towerTop))
    tower.addLine(to: CGPoint(x: towerCx + towerHalfW, y: towerTop))
    tower.addLine(to: CGPoint(x: towerCx + towerBaseHalfW, y: towerBottom))
    tower.addLine(to: CGPoint(x: towerCx - towerBaseHalfW, y: towerBottom))
    tower.closeSubpath()
    ctx.addPath(tower)
    ctx.fillPath()

    // Tower cross-bars
    ctx.setStrokeColor(NSColor(red: 0.55, green: 0.60, blue: 0.68, alpha: 1.0).cgColor)
    ctx.setLineWidth(s * 0.008)
    let barYs: [CGFloat] = [0.45, 0.55, 0.65]
    for frac in barYs {
        let y = towerBottom + (towerTop - towerBottom) * (frac - 0.30) / (0.82 - 0.30)
        let interpFrac = (y - towerBottom) / (towerTop - towerBottom)
        let halfW = towerBaseHalfW + (towerHalfW - towerBaseHalfW) * interpFrac
        ctx.move(to: CGPoint(x: towerCx - halfW * 1.1, y: y))
        ctx.addLine(to: CGPoint(x: towerCx + halfW * 1.1, y: y))
        ctx.strokePath()
    }

    // Tower top beacon (small circle, glowing)
    let beaconR = s * 0.022
    let beaconY = towerTop + beaconR * 0.5

    // Glow
    ctx.setFillColor(NSColor(red: 1.0, green: 0.3, blue: 0.2, alpha: 0.3).cgColor)
    ctx.fillEllipse(in: CGRect(x: towerCx - beaconR * 3, y: beaconY - beaconR * 3,
                                width: beaconR * 6, height: beaconR * 6))
    ctx.setFillColor(NSColor(red: 1.0, green: 0.35, blue: 0.25, alpha: 0.6).cgColor)
    ctx.fillEllipse(in: CGRect(x: towerCx - beaconR * 1.5, y: beaconY - beaconR * 1.5,
                                width: beaconR * 3, height: beaconR * 3))
    ctx.setFillColor(NSColor(red: 1.0, green: 0.45, blue: 0.35, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: towerCx - beaconR, y: beaconY - beaconR,
                                width: beaconR * 2, height: beaconR * 2))

    // Broadcast waves (concentric arcs radiating from tower top)
    ctx.setLineWidth(s * 0.012)
    let waveRadii: [(r: CGFloat, alpha: CGFloat)] = [
        (s * 0.12, 0.6), (s * 0.20, 0.4), (s * 0.28, 0.25)
    ]
    let waveCenter = CGPoint(x: towerCx, y: towerTop)
    for (radius, alpha) in waveRadii {
        ctx.setStrokeColor(NSColor(red: 0.4, green: 0.75, blue: 1.0, alpha: alpha).cgColor)
        // Left arc
        ctx.addArc(center: waveCenter, radius: radius,
                   startAngle: .pi * 0.55, endAngle: .pi * 0.85, clockwise: false)
        ctx.strokePath()
        // Right arc
        ctx.addArc(center: waveCenter, radius: radius,
                   startAngle: .pi * 0.15, endAngle: .pi * 0.45, clockwise: false)
        ctx.strokePath()
    }

    // MPX spectrum bar at the bottom — stylized frequency bars showing
    // audio (0-15k), pilot (19k), stereo subcarrier (23-53k), RDS (57k)
    let barAreaY = s * 0.08
    let barAreaH = s * 0.14
    let barAreaX = s * 0.12
    let barAreaW = s * 0.76

    // Audio region (left block, teal)
    let audioW = barAreaW * 0.25
    ctx.setFillColor(NSColor(red: 0.2, green: 0.7, blue: 0.6, alpha: 0.8).cgColor)
    ctx.fill(CGRect(x: barAreaX, y: barAreaY, width: audioW, height: barAreaH * 0.9))

    // Pilot spike (narrow, bright)
    let pilotX = barAreaX + barAreaW * 0.32
    ctx.setFillColor(NSColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 0.9).cgColor)
    ctx.fill(CGRect(x: pilotX, y: barAreaY, width: barAreaW * 0.02, height: barAreaH))

    // Stereo subcarrier region (wider block, blue)
    let subX = barAreaX + barAreaW * 0.38
    let subW = barAreaW * 0.38
    ctx.setFillColor(NSColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 0.6).cgColor)
    ctx.fill(CGRect(x: subX, y: barAreaY, width: subW, height: barAreaH * 0.65))

    // RDS spike (narrow, magenta)
    let rdsX = barAreaX + barAreaW * 0.82
    ctx.setFillColor(NSColor(red: 0.8, green: 0.3, blue: 0.7, alpha: 0.7).cgColor)
    ctx.fill(CGRect(x: rdsX, y: barAreaY, width: barAreaW * 0.02, height: barAreaH * 0.5))

    // "MPX" text label (small, at tower base)
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.065, weight: .bold),
        .foregroundColor: NSColor(red: 0.8, green: 0.85, blue: 0.9, alpha: 0.9)
    ]
    let text = "MPX" as NSString
    let textSize = text.size(withAttributes: textAttrs)
    text.draw(at: NSPoint(x: towerCx - textSize.width / 2, y: towerBottom - textSize.height - s * 0.01),
              withAttributes: textAttrs)

    image.unlockFocus()
    return image
}

// Generate all required icon sizes
let iconsetDir = "/tmp/MPXPrime.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for entry in sizes {
    let image = drawIcon(size: entry.size)
    guard let tiff = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiff),
          let pngData = bitmapRep.representation(using: .png, properties: [:])
    else {
        print("Failed to render \(entry.name)")
        continue
    }
    let path = (iconsetDir as NSString).appendingPathComponent(entry.name)
    try! pngData.write(to: URL(fileURLWithPath: path))
    print("Generated \(entry.name) (\(Int(entry.size))px)")
}

print("\nIconset at: \(iconsetDir)")
print("Convert with: iconutil --convert icns \(iconsetDir) --output macOS/Resources/MPXPrime.icns")
