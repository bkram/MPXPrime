import SwiftUI

// Canvas plot of the RF spectrum around the tuned carrier -- the band view an
// SDR application shows, drawn from the tuner's complex FFT of the IQ.
//
// Distinct from MPXSpectrumView, which plots the demodulated BASEBAND (0-100
// kHz: mono, pilot, stereo, RDS). This one plots what is on the air either
// side of the carrier: the station's own RF footprint, its neighbours on the
// 100/200 kHz raster, and any splatter between them. Bins arrive already
// fftshifted, so index 0 is the low edge of the span and the centre index is
// the tuned frequency.
//
// Drawn in a Canvas so a 20 Hz frame is a repaint, never a layout pass, with
// the same implicit-animation guard every live view in this module carries.
public struct RFSpectrumView: View {
    let bins: [Float]
    /// Total width the bins cover (the IQ capture rate).
    let spanHz: Double
    /// Tuned centre frequency, for the axis labels.
    let centerMHz: Double
    var minDB: Double
    var maxDB: Double
    var accessibilityName: String

    public init(
        bins: [Float],
        spanHz: Double,
        centerMHz: Double,
        minDB: Double = -110,
        maxDB: Double = -10,
        accessibilityName: String = "RF spectrum"
    ) {
        self.bins = bins
        self.spanHz = spanHz
        self.centerMHz = centerMHz
        self.minDB = minDB
        self.maxDB = maxDB
        self.accessibilityName = accessibilityName
    }

    public var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius),
                with: .color(BroadcastStyle.instrumentBackground))

            let span = max(1.0, spanHz)
            let halfMHz = span / 2.0 / 1e6
            func xForOffsetMHz(_ off: Double) -> CGFloat {
                CGFloat((off + halfMHz) / (2.0 * halfMHz)) * size.width
            }
            func yFor(_ db: Double) -> CGFloat {
                let norm = max(0.0, min(1.0, (db - minDB) / max(1e-9, maxDB - minDB)))
                return size.height * CGFloat(1.0 - norm)
            }

            // Horizontal dB grid (quarters) + labels at top and bottom.
            var grid = Path()
            for i in 0...4 {
                let y = size.height * CGFloat(i) / 4.0
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }

            // Vertical grid on the 100 kHz FM raster while it stays legible,
            // else every 500 kHz. Broadcast channels sit on that raster, so it
            // doubles as a channel ruler.
            let stepMHz = halfMHz <= 0.6 ? 0.1 : 0.5
            var off = -halfMHz + stepMHz
            while off < halfMHz {
                if abs(off) > 1e-9 {
                    let x = xForOffsetMHz(off)
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                off += stepMHz
            }
            ctx.stroke(grid, with: .color(BroadcastStyle.instrumentGrid), lineWidth: 1)

            // Centre marker: the tuned frequency.
            let cx = xForOffsetMHz(0)
            var centre = Path()
            centre.move(to: CGPoint(x: cx, y: 0))
            centre.addLine(to: CGPoint(x: cx, y: size.height))
            ctx.stroke(centre, with: .color(BroadcastStyle.accent.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ anchor: UnitPoint,
                       _ color: Color) {
                ctx.draw(
                    Text(text).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(color),
                    at: CGPoint(x: x, y: y), anchor: anchor)
            }
            label(String(format: "%.2f", centerMHz), cx + 3, size.height - 7,
                  .leading, BroadcastStyle.accent)
            label(String(format: "%.2f", centerMHz - halfMHz), 4, size.height - 7,
                  .leading, BroadcastStyle.instrumentLabel)
            label(String(format: "%.2f MHz", centerMHz + halfMHz), size.width - 4,
                  size.height - 7, .trailing, BroadcastStyle.instrumentLabel)
            label("\(Int(maxDB)) dB", 4, 7, .leading, BroadcastStyle.instrumentLabel)

            guard bins.count > 1 else { return }
            let stepX = size.width / CGFloat(bins.count - 1)
            var trace = Path()
            for (i, db) in bins.enumerated() {
                let pt = CGPoint(x: CGFloat(i) * stepX, y: yFor(Double(db)))
                if i == 0 { trace.move(to: pt) } else { trace.addLine(to: pt) }
            }
            var area = trace
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Color.green.opacity(0.28), Color.green.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(trace, with: .color(.green.opacity(0.90)), lineWidth: 1.2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(
            cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        .transaction { txn in txn.animation = nil }
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(.isImage)
    }
}
