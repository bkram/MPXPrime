import AppKit

// Runtime renderer for the MPX Prime Meter app icon (analyzer VU gauge + MPX
// spectrum bar, teal palette). The canonical `.icns` (Resources/
// MPXPrimeMeter.icns, from generate_meter_icon.swift) is what Finder shows for
// the bundled .app; this mirror lets the *running* process set its Dock icon in
// every mode -- including the unbundled `swift run` / CLI binary, which has no
// bundle for LaunchServices to read CFBundleIconFile from. Keep this drawing in
// sync with generate_meter_icon.swift.
enum MeterIcon {
    static func image(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        let s = size
        let r = s * 0.185

        let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                                  xRadius: r, yRadius: r)
        let topColor = NSColor(red: 0.10, green: 0.20, blue: 0.22, alpha: 1.0)
        let bottomColor = NSColor(red: 0.05, green: 0.10, blue: 0.12, alpha: 1.0)
        NSGradient(starting: bottomColor, ending: topColor)?.draw(in: bgPath, angle: 90)

        let cx = s * 0.5, cy = s * 0.30, radius = s * 0.40
        let startA = CGFloat.pi * 0.78, endA = CGFloat.pi * 0.22

        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor(red: 0.45, green: 0.85, blue: 0.70, alpha: 0.55).cgColor)
        ctx.setLineWidth(s * 0.018)
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                   startAngle: endA, endAngle: startA, clockwise: false)
        ctx.strokePath()

        let ticks = 9
        for i in 0...ticks {
            let f = CGFloat(i) / CGFloat(ticks)
            let a = startA + (endA - startA) * f
            let inner = radius - s * 0.035, outer = radius + s * 0.005
            let warm = f > 0.72
            ctx.setStrokeColor((warm
                ? NSColor(red: 1.0, green: 0.5, blue: 0.35, alpha: 0.95)
                : NSColor(red: 0.55, green: 0.95, blue: 0.80, alpha: 0.9)).cgColor)
            ctx.setLineWidth(s * (i % 2 == 0 ? 0.012 : 0.007))
            ctx.move(to: CGPoint(x: cx + cos(a) * inner, y: cy + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: cx + cos(a) * outer, y: cy + sin(a) * outer))
            ctx.strokePath()
        }

        let needleA = startA + (endA - startA) * 0.80
        let needleLen = radius - s * 0.02
        ctx.setStrokeColor(NSColor(red: 0.95, green: 0.97, blue: 0.98, alpha: 1.0).cgColor)
        ctx.setLineWidth(s * 0.020)
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + cos(needleA) * needleLen, y: cy + sin(needleA) * needleLen))
        ctx.strokePath()
        ctx.setFillColor(NSColor(red: 0.85, green: 0.90, blue: 0.92, alpha: 1.0).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - s * 0.03, y: cy - s * 0.03, width: s * 0.06, height: s * 0.06))

        let barY = s * 0.085, barH = s * 0.11, barX = s * 0.14, barW = s * 0.72
        ctx.setFillColor(NSColor(red: 0.25, green: 0.75, blue: 0.65, alpha: 0.8).cgColor)
        ctx.fill(CGRect(x: barX, y: barY, width: barW * 0.25, height: barH * 0.9))
        ctx.setFillColor(NSColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 0.9).cgColor)
        ctx.fill(CGRect(x: barX + barW * 0.32, y: barY, width: barW * 0.02, height: barH))
        ctx.setFillColor(NSColor(red: 0.3, green: 0.55, blue: 0.9, alpha: 0.55).cgColor)
        ctx.fill(CGRect(x: barX + barW * 0.38, y: barY, width: barW * 0.38, height: barH * 0.62))
        ctx.setFillColor(NSColor(red: 0.8, green: 0.35, blue: 0.7, alpha: 0.75).cgColor)
        ctx.fill(CGRect(x: barX + barW * 0.82, y: barY, width: barW * 0.02, height: barH * 0.5))

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: s * 0.060, weight: .bold),
            .foregroundColor: NSColor(red: 0.85, green: 0.92, blue: 0.90, alpha: 0.9)
        ]
        let text = "MPX" as NSString
        let tsz = text.size(withAttributes: textAttrs)
        text.draw(at: NSPoint(x: cx - tsz.width / 2, y: s * 0.205), withAttributes: textAttrs)

        return image
    }
}
