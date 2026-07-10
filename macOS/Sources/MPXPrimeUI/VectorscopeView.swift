import SwiftUI

// Stereo goniometer / vectorscope (shared). Plots decoded L vs R rotated 45 deg
// so a mono signal traces a vertical line, L-only leans left, R-only leans
// right, and wide stereo fills the field. Signal-agnostic: takes two equal-
// length [Float] buffers. Draws in a Canvas (repaint, not layout) like the
// other live displays.
public struct VectorscopeView: View {
    let left: [Float]
    let right: [Float]
    /// Display gain applied before the +/-1 clamp: hardware goniometers ride
    /// their display gain so quiet program still fills the field. Points
    /// pushed past full scale saturate at the edge, like the real thing.
    var zoom: Double
    var accessibilityName: String

    public init(left: [Float], right: [Float], zoom: Double = 1.0,
                accessibilityName: String = "Stereo vectorscope") {
        self.left = left
        self.right = right
        self.zoom = zoom
        self.accessibilityName = accessibilityName
    }

    public var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius),
                with: .color(BroadcastStyle.instrumentBackground))

            let cx = size.width * 0.5
            let cy = size.height * 0.5
            // Inset so the circle's stroke never clips at the panel edges.
            let radius = min(cx, cy) - 4

            // Faint bounding circle (the full-scale envelope).
            let circle = Path(ellipseIn: CGRect(
                x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
            ctx.stroke(circle, with: .color(BroadcastStyle.instrumentGrid.opacity(0.7)),
                       lineWidth: 1)
            // Vertical = mono (L=R) drawn solid; the L-only / R-only diagonals are
            // dashed and dimmer so they read as reference, not clutter.
            var axis = Path()
            axis.move(to: CGPoint(x: cx, y: cy - radius))
            axis.addLine(to: CGPoint(x: cx, y: cy + radius))
            ctx.stroke(axis, with: .color(BroadcastStyle.instrumentGrid), lineWidth: 1)
            var diagonals = Path()
            diagonals.move(to: CGPoint(x: cx - radius, y: cy - radius))
            diagonals.addLine(to: CGPoint(x: cx + radius, y: cy + radius))
            diagonals.move(to: CGPoint(x: cx + radius, y: cy - radius))
            diagonals.addLine(to: CGPoint(x: cx - radius, y: cy + radius))
            ctx.stroke(diagonals, with: .color(BroadcastStyle.instrumentGrid.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            guard left.count > 1, right.count == left.count else { return }
            // Rotate 45 deg: x = (L-R), y = (L+R). The rotated axes span 2x
            // the per-channel range (mono L=R=1 gives y = 2), so k = r/2
            // guarantees every |L|,|R| <= 1 point stays inside the circle --
            // the earlier /sqrt2 let full-scale mono overshoot the field by
            // ~30%. 0.92 leaves a small margin; the auto-zoom (driven by the
            // rotated-axis peaks) provides the fill.
            let k = radius * 0.92 / 2.0
            let g = Float(zoom)
            var path = Path()
            for i in 0..<left.count {
                let l = CGFloat(max(-1.0, min(1.0, left[i] * g)))
                let r = CGFloat(max(-1.0, min(1.0, right[i] * g)))
                let pt = CGPoint(x: cx + (l - r) * k, y: cy - (l + r) * k)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(.green.opacity(0.85)), lineWidth: 1.0)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        // Disable implicit animations on the ~25 Hz point-cloud updates; queued
        // frame interpolations otherwise accumulate into GUI lag that only a
        // fresh launch clears (same fix as MPXSpectrumView).
        .transaction { txn in txn.animation = nil }
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(.isImage)
    }
}
