import SwiftUI

// Vertical meter-strip component used on the dedicated Levels window.
// Orban Optimod-style: narrow column per signal, scale ticks on the
// right edge, peak-hold dot, colour-graded fill via BroadcastStyle.
//
// Horizontal MeterBar continues to be used on the Monitoring dashboard
// and the header status bar — vertical strips are specifically for the
// Levels window where they make sense at full window height.

struct VerticalMeterStrip: View {
    enum Scale: Equatable {
        case dbfs                           // -36..0 dBFS, 6 breakpoints
        case modulationKHz(limit: Double)   // 0..100 kHz, limit highlighted
        case gainReductionDB                // 0..16 dB attenuation, inverted
    }

    let label: String
    let valueText: String
    /// 0..1 linear position along the strip (bottom = 0, top = 1).
    let level: Double
    let peakLevel: Double?
    let scale: Scale

    private struct Tick: Identifiable {
        let position: Double
        let label: String
        var id: String { "\(label)-\(position)" }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .fixedSize()
            // Bar + ticks + scale labels + peak-hold, all drawn in a single
            // Canvas. Critical for performance: the level / peak / target change
            // every frame, and a SwiftUI subview whose `.frame(height:)` tracks the
            // level would re-run Auto Layout on every update (a full window
            // constraint re-solve at the refresh rate -- the cause of the
            // "near-frozen after hours" stall when the Levels window stays open).
            // A Canvas just repaints on a value change; it never invalidates layout.
            Canvas { ctx, size in
                drawMeter(into: ctx, size: size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(valueText)
                .font(BroadcastStyle.valueReadout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 64)
        // The bar/peak-hold/ticks are decorative to VoiceOver; collapse the
        // strip into one element that announces its name and current reading
        // (e.g. "IN L, -6.2 dB") instead of two disconnected text fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
    }

    // MARK: - Drawing

    /// Paints the bar body, level fill, tick marks + scale labels, target line,
    /// and peak-hold marker. Runs inside `Canvas`, so a per-frame value change is a
    /// repaint, not an Auto Layout pass. y is top-down; normalized position 0 = bottom.
    private func drawMeter(into ctx: GraphicsContext, size: CGSize) {
        let barW: CGFloat = 22
        let h = size.height
        let radius: CGFloat = 3
        let barRect = CGRect(x: 0, y: 0, width: barW, height: h)
        let barPath = Path(roundedRect: barRect, cornerRadius: radius, style: .continuous)
        ctx.fill(barPath, with: .color(BroadcastStyle.meterSurface))

        let fillH = h * CGFloat(clamp(level))
        if fillH > 0.5 {
            let fillRect = CGRect(x: 0, y: h - fillH, width: barW, height: fillH)
            ctx.fill(
                Path(roundedRect: fillRect, cornerRadius: radius, style: .continuous),
                with: .color(tint.opacity(0.80)))
        }
        ctx.stroke(barPath, with: .color(BroadcastStyle.panelBorder), lineWidth: 0.5)

        for tick in scaleTicks {
            let y = h * CGFloat(1.0 - tick.position)
            ctx.fill(
                Path(CGRect(x: barW - 6, y: y - 0.5, width: 6, height: 1)),
                with: .color(BroadcastStyle.scaleTick))
            ctx.draw(
                Text(tick.label).font(BroadcastStyle.scaleLabel).foregroundColor(.secondary),
                at: CGPoint(x: barW + 6, y: y), anchor: .leading)
        }

        if let targetNorm {
            let y = h * CGFloat(1.0 - targetNorm)
            ctx.fill(
                Path(CGRect(x: 0, y: y - 0.75, width: barW, height: 1.5)),
                with: .color(BroadcastStyle.accent.opacity(0.85)))
        }

        if let peak = peakLevel {
            let y = h * CGFloat(1.0 - clamp(peak))
            ctx.fill(
                Path(CGRect(x: 0, y: y - 1, width: barW, height: 2)),
                with: .color(Color.primary.opacity(0.95)))
        }
    }

    // MARK: - Scale helpers

    private func clamp(_ v: Double) -> Double {
        max(0.0, min(1.0, v))
    }

    private var tint: Color {
        switch scale {
        case .dbfs:
            return BroadcastStyle.tint(forLevel: level)
        case .modulationKHz(let limit):
            return BroadcastStyle.tint(forLevel: level, limitNorm: limit / 100.0)
        case .gainReductionDB:
            // More GR = redder (signal is being fought harder).
            return BroadcastStyle.tint(forLevel: level)
        }
    }

    private var targetNorm: Double? {
        switch scale {
        case .modulationKHz(let limit): return max(0.0, min(1.0, limit / 100.0))
        default: return nil
        }
    }

    private var scaleTicks: [Tick] {
        switch scale {
        case .dbfs:
            let points: [Double] = [-36, -24, -12, -6, -3, 0]
            return points.map {
                Tick(position: (($0 - -36) / 36), label: "\(Int($0))")
            }
        case .modulationKHz:
            return [0, 25, 50, 75, 100].map {
                Tick(position: $0 / 100, label: "\(Int($0))")
            }
        case .gainReductionDB:
            return [0, 3, 6, 9, 12, 16].map {
                Tick(position: $0 / 16.0, label: "\(Int($0))")
            }
        }
    }
}
