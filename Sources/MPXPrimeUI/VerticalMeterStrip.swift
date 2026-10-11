import SwiftUI

// Vertical meter-strip component (shared). Orban Optimod-style: narrow column
// per signal, scale ticks on the right edge, peak-hold dot, colour-graded fill
// via BroadcastStyle. Takes plain scalars + a pre-formatted value string, so
// any app can feed it (the transmit Levels window and the Meter window both do).

public struct VerticalMeterStrip: View {
    public enum Scale: Equatable {
        case dbfs                                        // -36..0 dBFS, 6 breakpoints
        /// 0..fullScale kHz with an optional highlighted limit line. fullScale
        /// is per-meter so low-deviation subcarriers (pilot ~7.5, RDS ~2-4 kHz)
        /// get a readable range instead of a stub on a 0..100 scale.
        case modulationKHz(fullScale: Double, limit: Double?)
        case gainReductionDB                             // 0..16 dB attenuation, inverted
    }

    let label: String
    let valueText: String
    /// 0..1 linear position along the strip (bottom = 0, top = 1).
    let level: Double
    let peakLevel: Double?
    let scale: Scale
    /// Draw the per-strip tick labels on the right edge. Set false when a group
    /// shares one `MeterScaleRuler` instead (declutters multi-bar groups); the
    /// strip then centres its bar and stays narrow.
    let showScale: Bool
    /// Hover tooltip: what the meter shows and its safe range. Empty = none.
    let help: String

    public init(
        label: String, valueText: String, level: Double, peakLevel: Double?,
        scale: Scale, showScale: Bool = true, help: String = ""
    ) {
        self.label = label
        self.valueText = valueText
        self.level = level
        self.peakLevel = peakLevel
        self.scale = scale
        self.showScale = showScale
        self.help = help
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
        .frame(width: showScale ? 64 : 34)
        // Disable implicit animations on the ~25 Hz level/peak updates; queued
        // frame interpolations otherwise accumulate into GUI lag that only a
        // fresh launch clears (same fix as MPXSpectrumView).
        .transaction { txn in txn.animation = nil }
        // The bar/peak-hold/ticks are decorative to VoiceOver; collapse the
        // strip into one element that announces its name and current reading
        // (e.g. "IN L, -6.2 dB") instead of two disconnected text fragments.
        // The scale range + colour meaning go in the hint so the primary
        // announcement stays crisp.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityHint(help.isEmpty ? accessibilityHint : help)
        .help(help)
    }

    /// Supplementary VoiceOver context: what the meter measures, its scale,
    /// and what the colour bands mean (so colour isn't the only state cue).
    private var accessibilityHint: String {
        switch scale {
        case .dbfs:
            return "Level meter, scale -36 to 0 dBFS. Green safe, amber near limit, red over."
        case .modulationKHz(let fullScale, _):
            return "Modulation meter, scale 0 to \(Int(fullScale)) kHz. "
                + "Amber near the deviation limit, red over."
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
        // With a shared ruler the strip is narrow and the bar is centred; with
        // per-strip ticks the bar sits left so the labels have room on the right.
        let barX: CGFloat = showScale ? 0 : (size.width - barW) / 2
        func yFor(_ position: Double) -> CGFloat { vpad + usable * CGFloat(1.0 - clamp(position)) }

        let barRect = CGRect(x: barX, y: vpad, width: barW, height: usable)
        let barPath = Path(roundedRect: barRect, cornerRadius: radius, style: .continuous)
        ctx.fill(barPath, with: .color(BroadcastStyle.meterSurface))

        let fillH = usable * CGFloat(clamp(level))
        if fillH > 0.5 {
            let fillRect = CGRect(x: barX, y: vpad + usable - fillH, width: barW, height: fillH)
            // Subtle vertical gradient (brighter toward the top of the fill) for
            // a less utilitarian, more dimensional bar.
            ctx.fill(
                Path(roundedRect: fillRect, cornerRadius: radius, style: .continuous),
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.60), tint.opacity(0.95)]),
                    startPoint: CGPoint(x: 0, y: vpad + usable),
                    endPoint: CGPoint(x: 0, y: vpad + usable - fillH)))
        }
        ctx.stroke(barPath, with: .color(BroadcastStyle.panelBorder), lineWidth: 0.5)

        if showScale {
            for tick in scaleTicks {
                let y = yFor(tick.position)
                ctx.fill(
                    Path(CGRect(x: barX + barW - 6, y: y - 0.5, width: 6, height: 1)),
                    with: .color(BroadcastStyle.scaleTick))
                ctx.draw(
                    Text(tick.label).font(BroadcastStyle.scaleLabel).foregroundColor(.secondary),
                    at: CGPoint(x: barX + barW + 6, y: y), anchor: .leading)
            }
        }

        if let targetNorm {
            let y = yFor(targetNorm)
            ctx.fill(
                Path(CGRect(x: barX, y: y - 0.75, width: barW, height: 1.5)),
                with: .color(BroadcastStyle.accent.opacity(0.85)))
        }

        if let peak = peakLevel {
            let y = yFor(peak)
            ctx.fill(
                Path(CGRect(x: barX, y: y - 1, width: barW, height: 2)),
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
        case .modulationKHz(let fullScale, let limit):
            if let limit {
                return BroadcastStyle.tint(forLevel: level, limitNorm: limit / fullScale)
            }
            return BroadcastStyle.tint(forLevel: level)
        case .gainReductionDB:
            // More GR = redder (signal is being fought harder).
            return BroadcastStyle.tint(forLevel: level)
        }
    }

    private var targetNorm: Double? {
        switch scale {
        case .modulationKHz(let fullScale, let limit):
            return limit.map { max(0.0, min(1.0, $0 / fullScale)) }
        default: return nil
        }
    }

    private var scaleTicks: [Tick] {
        scale.tickMarks().map { Tick(position: $0.position, label: $0.label) }
    }
}

public extension VerticalMeterStrip.Scale {
    /// Scale tick positions (0..1, bottom..top) + labels. Shared by the strip's
    /// own ticks and by `MeterScaleRuler` so a group's shared ruler stays in
    /// register with the bars.
    func tickMarks() -> [(position: Double, label: String)] {
        switch self {
        case .dbfs:
            return [-36, -24, -12, -6, -3, 0].map { (($0 - -36) / 36, "\(Int($0))") }
        case .modulationKHz(let fullScale, _):
            let step: Double
            switch fullScale {
            case ...10: step = 2
            case ...16: step = 3
            case ...30: step = 5
            case ...60: step = 10
            default: step = 25
            }
            var ticks: [(Double, String)] = []
            var v = 0.0
            while v <= fullScale + 0.001 {
                ticks.append((v / fullScale, "\(Int(v.rounded()))"))
                v += step
            }
            return ticks
        case .gainReductionDB:
            return [0, 3, 6, 9, 12, 16].map { ($0 / 16.0, "\(Int($0))") }
        }
    }
}

/// A standalone scale column matching `VerticalMeterStrip`'s vertical layout, so
/// a group of same-scale bars can share one ruler instead of repeating the
/// number column on every bar. Place it as the first item in the group's HStack.
public struct MeterScaleRuler: View {
    let scale: VerticalMeterStrip.Scale
    public init(scale: VerticalMeterStrip.Scale) { self.scale = scale }

    public var body: some View {
        VStack(spacing: 6) {
            // Spacers match the strip's label (top) and value (bottom) rows so
            // the Canvas region lines up with the bars' Canvas region exactly.
            Text(" ").font(BroadcastStyle.chipLabel).hidden()
            Canvas { ctx, size in
                let vpad: CGFloat = 8
                let usable = max(1.0, size.height - 2 * vpad)
                for tick in scale.tickMarks() {
                    let y = vpad + usable * CGFloat(1.0 - tick.position)
                    ctx.draw(
                        Text(tick.label).font(BroadcastStyle.scaleLabel).foregroundColor(.secondary),
                        at: CGPoint(x: size.width - 2, y: y), anchor: .trailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(" ").font(BroadcastStyle.valueReadout).hidden()
        }
        .frame(width: 26)
        .accessibilityHidden(true)
    }
}
