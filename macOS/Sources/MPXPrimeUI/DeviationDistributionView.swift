import SwiftUI

// Canvas plot of the deviation histogram as an ACCUMULATED distribution: for
// each 1 kHz bin, the share of measured 50 ms peak-hold slots reaching that
// deviation or more. Reads right-to-left from 100 % at the bottom of the range
// down to 0 % past the loudest slot ever measured.
//
// Why the accumulated form and not the raw bar chart: the operator's question
// is "how much of the programme gets near the limit", which is a tail
// question. A raw histogram buries that in bin-by-bin noise; the accumulated
// curve answers it by inspection -- follow 75 kHz up to the trace and read the
// percentage. This is the presentation ITU-R SM.1268-annex measurement
// practice and the Pira analyzers both use.
//
// Signal-agnostic like TrendView: the caller supplies the counts and the
// limit. Drawn in a Canvas so an update is a repaint, never a layout pass.
public struct DeviationDistributionView: View {
    let counts: [UInt32]
    let totalSamples: UInt64
    var maxKHz: Double
    var limit: Double?
    var accessibilityName: String

    public init(
        counts: [UInt32],
        totalSamples: UInt64,
        maxKHz: Double = 90.0,
        limit: Double? = 75.0,
        accessibilityName: String = "Deviation distribution"
    ) {
        self.counts = counts
        self.totalSamples = totalSamples
        self.maxKHz = maxKHz
        self.limit = limit
        self.accessibilityName = accessibilityName
    }

    public var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius),
                with: .color(BroadcastStyle.instrumentBackground))

            let span = max(1.0, maxKHz)
            func xFor(_ kHz: Double) -> CGFloat {
                CGFloat(max(0.0, min(1.0, kHz / span))) * size.width
            }
            func yFor(_ fraction: Double) -> CGFloat {
                size.height * CGFloat(1.0 - max(0.0, min(1.0, fraction)))
            }

            // Horizontal grid at 0 / 25 / 50 / 75 / 100 %.
            var grid = Path()
            for i in 0...4 {
                let y = size.height * CGFloat(i) / 4.0
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            // Vertical grid every 20 kHz.
            var kHz = 20.0
            while kHz < span {
                let x = xFor(kHz)
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                kHz += 20.0
            }
            ctx.stroke(grid, with: .color(BroadcastStyle.instrumentGrid), lineWidth: 1)

            if let limit, limit < span {
                let x = xFor(limit)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(BroadcastStyle.accent.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ctx.draw(
                    Text("\(Int(limit))").font(.system(size: 9, design: .monospaced))
                        .foregroundColor(BroadcastStyle.accent),
                    at: CGPoint(x: min(size.width - 2, x + 3), y: 7), anchor: .leading)
            }
            ctx.draw(
                Text("100%").font(.system(size: 9, design: .monospaced))
                    .foregroundColor(BroadcastStyle.instrumentLabel),
                at: CGPoint(x: 4, y: 7), anchor: .leading)
            ctx.draw(
                Text("kHz").font(.system(size: 9, design: .monospaced))
                    .foregroundColor(BroadcastStyle.instrumentLabel),
                at: CGPoint(x: size.width - 4, y: size.height - 7), anchor: .trailing)

            guard totalSamples > 0, !counts.isEmpty else { return }

            // Accumulate from the top bin down so each point is "this bin or
            // higher", then walk left-to-right to draw.
            var atOrAbove = [Double](repeating: 0.0, count: counts.count)
            var running: UInt64 = 0
            for i in stride(from: counts.count - 1, through: 0, by: -1) {
                running &+= UInt64(counts[i])
                atOrAbove[i] = Double(running) / Double(totalSamples)
            }

            var curve = Path()
            var started = false
            for i in 0..<counts.count {
                let kHz = Double(i)
                if kHz > span { break }
                let pt = CGPoint(x: xFor(kHz), y: yFor(atOrAbove[i]))
                if started { curve.addLine(to: pt) } else { curve.move(to: pt); started = true }
            }
            guard started else { return }

            var area = curve
            area.addLine(to: CGPoint(x: xFor(min(span, Double(counts.count - 1))),
                                     y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Color.green.opacity(0.28), Color.green.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(curve, with: .color(.green.opacity(0.90)), lineWidth: 1.3)
        }
        .frame(maxWidth: .infinity, minHeight: 56, idealHeight: 96)
        .clipShape(RoundedRectangle(
            cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        // Same implicit-animation guard every live Canvas view in this module
        // carries: queued frame interpolations otherwise accumulate into lag.
        .transaction { txn in txn.animation = nil }
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(.isImage)
    }
}
