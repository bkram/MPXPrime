import SwiftUI

// Stereo goniometer / vectorscope (shared). Plots decoded L vs R rotated 45 deg
// so a mono signal traces a vertical line, L-only leans left, R-only leans
// right, and wide stereo fills the field. Signal-agnostic: takes two equal-
// length [Float] buffers. Draws in a Canvas (repaint, not layout) like the
// other live displays.
public struct VectorscopeView: View {
    let left: [Float]
    let right: [Float]
    var accessibilityName: String

    public init(left: [Float], right: [Float], accessibilityName: String = "Stereo vectorscope") {
        self.left = left
        self.right = right
        self.accessibilityName = accessibilityName
    }

    public var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius),
                with: .color(.black.opacity(0.22)))

            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let radius = min(cx, cy)

            // Guides: vertical = mono (L=R), the two diagonals = L-only / R-only.
            var guides = Path()
            guides.move(to: CGPoint(x: cx, y: cy - radius))
            guides.addLine(to: CGPoint(x: cx, y: cy + radius))
            guides.move(to: CGPoint(x: cx - radius, y: cy - radius))
            guides.addLine(to: CGPoint(x: cx + radius, y: cy + radius))
            guides.move(to: CGPoint(x: cx + radius, y: cy - radius))
            guides.addLine(to: CGPoint(x: cx - radius, y: cy + radius))
            ctx.stroke(guides, with: .color(.white.opacity(0.10)), lineWidth: 1)

            guard left.count > 1, right.count == left.count else { return }
            // Rotate 45 deg: x = (L-R), y = (L+R); /sqrt2 keeps full-scale mono
            // inside the field. 0.92 leaves a small margin.
            let k = radius * 0.92 / 1.41421356
            var path = Path()
            for i in 0..<left.count {
                let l = CGFloat(max(-1.0, min(1.0, left[i])))
                let r = CGFloat(max(-1.0, min(1.0, right[i])))
                let pt = CGPoint(x: cx + (l - r) * k, y: cy - (l + r) * k)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(.green.opacity(0.85)), lineWidth: 1.0)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(.isImage)
    }
}
