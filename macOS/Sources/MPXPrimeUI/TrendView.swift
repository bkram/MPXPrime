import SwiftUI

// Canvas line-graph of a scrolling [Float] history (oldest -> newest), shared.
// Signal-agnostic: caller supplies the value range and an optional limit line
// (e.g. the 75 kHz deviation cap or the 0 dBr MPX-power limit). Draws in a
// Canvas so a per-tick history update is a repaint, never an Auto Layout pass.
public struct TrendView: View {
    let samples: [Float]
    let minValue: Double
    let maxValue: Double
    var limit: Double?
    var accessibilityName: String

    public init(
        samples: [Float],
        minValue: Double,
        maxValue: Double,
        limit: Double? = nil,
        accessibilityName: String = "Trend graph"
    ) {
        self.samples = samples
        self.minValue = minValue
        self.maxValue = maxValue
        self.limit = limit
        self.accessibilityName = accessibilityName
    }

    public var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius),
                with: .color(BroadcastStyle.instrumentBackground))

            let span = max(1e-9, maxValue - minValue)
            func yFor(_ v: Double) -> CGFloat {
                let norm = max(0.0, min(1.0, (v - minValue) / span))
                return size.height * CGFloat(1.0 - norm)
            }
            func axisLabel(_ value: Double, _ y: CGFloat, _ color: Color) {
                ctx.draw(
                    Text(value.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(color),
                    at: CGPoint(x: 4, y: max(7, min(size.height - 7, y))), anchor: .leading)
            }

            // Horizontal grid (quarters).
            var grid = Path()
            for i in 0...4 {
                let y = size.height * CGFloat(i) / 4.0
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(grid, with: .color(BroadcastStyle.instrumentGrid), lineWidth: 1)

            if let limit {
                let y = yFor(limit)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(BroadcastStyle.accent.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                axisLabel(limit, y, BroadcastStyle.accent)
            }

            // Y-axis scale: max (top) and min (bottom).
            axisLabel(maxValue, 7, BroadcastStyle.instrumentLabel)
            axisLabel(minValue, size.height - 7, BroadcastStyle.instrumentLabel)

            guard samples.count > 1 else { return }
            let stepX = size.width / CGFloat(samples.count - 1)
            var wave = Path()
            for (idx, sample) in samples.enumerated() {
                let pt = CGPoint(x: CGFloat(idx) * stepX, y: yFor(Double(sample)))
                if idx == 0 { wave.move(to: pt) } else { wave.addLine(to: pt) }
            }
            // Soft gradient fill under the trace so a flat, stable reading reads
            // as a filled band rather than a thin line in a dark void.
            var area = wave
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Color.green.opacity(0.28), Color.green.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(wave, with: .color(.green.opacity(0.90)), lineWidth: 1.3)
        }
        .frame(maxWidth: .infinity, minHeight: 56, idealHeight: 96)
        .clipShape(RoundedRectangle(
            cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(.isImage)
    }
}
