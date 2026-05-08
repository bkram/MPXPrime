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
            // Bar + scale-label column side by side. Bar stays 22pt
            // wide; label column gets the rest of the strip width
            // (~36pt) so dB / kHz labels render outside the bar
            // alongside their tick marks.
            HStack(alignment: .top, spacing: 4) {
                GeometryReader { geo in
                    ZStack {
                        // Body + tinted fill.
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(BroadcastStyle.meterSurface)
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(tint.opacity(0.80))
                                .frame(height: geo.size.height * CGFloat(clamp(level)))
                        }
                        // Scale tick marks pinned to the bar's right edge.
                        ForEach(scaleTicks) { tick in
                            Rectangle()
                                .fill(Color.primary.opacity(0.32))
                                .frame(width: 6, height: 1)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .offset(
                                    x: 0,
                                    y: (0.5 - tick.position) * geo.size.height
                                )
                        }
                        // Target line for modulation deviation.
                        if let targetNorm {
                            Rectangle()
                                .fill(BroadcastStyle.accent.opacity(0.85))
                                .frame(height: 1.5)
                                .offset(x: 0, y: (0.5 - targetNorm) * geo.size.height)
                        }
                        // Peak-hold dot.
                        if let peak = peakLevel {
                            let y = (0.5 - clamp(peak)) * geo.size.height
                            Rectangle()
                                .fill(Color.primary.opacity(0.95))
                                .frame(height: 2)
                                .offset(x: 0, y: y)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
                    )
                }
                .frame(width: 22)

                // Scale labels rendered alongside their tick marks via
                // y-offset positioning. Top-aligned with the bar so the
                // tick → label vertical mapping is exact.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        ForEach(scaleTicks) { tick in
                            Text(tick.label)
                                .font(BroadcastStyle.scaleLabel)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .offset(
                                    x: 0,
                                    y: ((1.0 - tick.position) * geo.size.height) - 6
                                )
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
                .frame(width: 22)
            }
            Text(valueText)
                .font(BroadcastStyle.valueReadout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 64)
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
