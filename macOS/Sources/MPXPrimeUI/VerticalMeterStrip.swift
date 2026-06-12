import SwiftUI

// Vertical meter-strip component (shared). Orban Optimod-style: narrow column
// per signal, scale ticks on the right edge, peak-hold dot, colour-graded fill
// via BroadcastStyle. Takes plain scalars + a pre-formatted value string, so
// any app can feed it (the transmit Levels window and the Meter window both do).

public struct VerticalMeterStrip: View {
    public enum Scale: Equatable {
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

    public init(label: String, valueText: String, level: Double, peakLevel: Double?, scale: Scale) {
        self.label = label
        self.valueText = valueText
        self.level = level
        self.peakLevel = peakLevel
        self.scale = scale
    }

    private struct Tick: Identifiable {
        let position: Double
        let label: String
        var id: String { "\(label)-\(position)" }
    }

    public var body: some View {
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
        // The scale range + colour meaning go in the hint so the primary
        // announcement stays crisp.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityHint(accessibilityHint)
    }

    /// Supplementary VoiceOver context: what the meter measures, its scale,
    /// and what the colour bands mean (so colour isn't the only state cue).
    private var accessibilityHint: String {
        switch scale {
        case .dbfs:
            return "Level meter, scale -36 to 0 dBFS. Green safe, amber near limit, red over."
        case .modulationKHz:
            return "Modulation meter, scale 0 to 100 kHz. Amber near the deviation limit, red over."
        case .gainReductionDB:
            return "Gain-reduction meter, scale 0 to 16 dB of attenuation."
        }
    }

    // MARK: - Drawing

    /// Paints the bar body, level fill, tick marks + scale labels, target line,
    /// and peak-hold marker. Runs inside `Canvas`, so a per-frame value change is a
    /// repaint, not an Auto Layout pass. y is top-down; normalized position 0 = bottom.
    private func drawMeter(into ctx: GraphicsContext, size: CGSize) {
        let barW: CGFloat = 22
        let h = size.height
        let radius: CGFloat = 3
        // Inset the whole scale vertically so the extreme tick labels (top "0",
        // bottom "-36"/"100") render fully instead of being clipped at the
        // Canvas edge -- they are centred on their y, so half would sit off-view
        // at y=0 / y=h. Everything (bar, fill, ticks, target, peak) maps through
        // the same inset range so labels stay aligned with their ticks.
        let vpad: CGFloat = 8
        let usable = max(1.0, h - 2 * vpad)
        func yFor(_ position: Double) -> CGFloat { vpad + usable * CGFloat(1.0 - clamp(position)) }

        let barRect = CGRect(x: 0, y: vpad, width: barW, height: usable)
        let barPath = Path(roundedRect: barRect, cornerRadius: radius, style: .continuous)
        ctx.fill(barPath, with: .color(BroadcastStyle.meterSurface))

        let fillH = usable * CGFloat(clamp(level))
        if fillH > 0.5 {
            let fillRect = CGRect(x: 0, y: vpad + usable - fillH, width: barW, height: fillH)
            ctx.fill(
                Path(roundedRect: fillRect, cornerRadius: radius, style: .continuous),
                with: .color(tint.opacity(0.80)))
        }
        ctx.stroke(barPath, with: .color(BroadcastStyle.panelBorder), lineWidth: 0.5)

        for tick in scaleTicks {
            let y = yFor(tick.position)
            ctx.fill(
                Path(CGRect(x: barW - 6, y: y - 0.5, width: 6, height: 1)),
                with: .color(BroadcastStyle.scaleTick))
            ctx.draw(
                Text(tick.label).font(BroadcastStyle.scaleLabel).foregroundColor(.secondary),
                at: CGPoint(x: barW + 6, y: y), anchor: .leading)
        }

        if let targetNorm {
            let y = yFor(targetNorm)
            ctx.fill(
                Path(CGRect(x: 0, y: y - 0.75, width: barW, height: 1.5)),
                with: .color(BroadcastStyle.accent.opacity(0.85)))
        }

        if let peak = peakLevel {
            let y = yFor(peak)
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
