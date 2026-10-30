import MPXPrimeCore
import SwiftUI

/// What a ladder meter's scale measures.
public enum LadderMeterScale: Equatable, Sendable {
    /// -60...0 dBFS, Prime Mixer's ladder.
    case dbfs
    /// 0...`fullScaleKHz` deviation. The readings are in dB re `limitKHz`
    /// (feed the ballistics `kHz / limitKHz`), so the clip latch is the
    /// over-deviation latch and the colours turn red at the limit.
    case deviation(fullScaleKHz: Double, limitKHz: Double)
}

/// Prime Mixer's ladder meter: one or more LED-segmented bars sharing one
/// scale (dBFS: green to -18, yellow by -11, orange by -4, red at 0), a white
/// held-peak line, a latched red clip cap, and the marks on the right.
/// Drawn in one `Canvas` so a 30 Hz meter tick is a repaint, never a layout
/// pass (the project's live-meter rule; the mixer's own view used frames).
public struct LadderMeterView: View {
    let readings: [LadderMeterReading]
    let labels: [String]
    let scale: LadderMeterScale
    let height: CGFloat

    static let barWidth: CGFloat = 16
    static let barGap: CGFloat = 5
    static let scaleWidth: CGFloat = 26
    static let labelHeight: CGFloat = 14

    /// One bar (mono, unlabelled) or a labelled L / R pair on the dBFS scale.
    public init(left: LadderMeterReading, right: LadderMeterReading?, height: CGFloat = 170) {
        if let right {
            self.init(readings: [left, right], labels: ["L", "R"], scale: .dbfs, height: height)
        } else {
            self.init(readings: [left], labels: [""], scale: .dbfs, height: height)
        }
    }

    public init(readings: [LadderMeterReading], labels: [String], scale: LadderMeterScale, height: CGFloat = 170) {
        self.readings = readings
        self.labels = labels
        self.scale = scale
        self.height = height
    }

    /// A reading in dB as a 0...1 fraction of the scale, from the bottom.
    public static func fraction(_ dB: Float, scale: LadderMeterScale = .dbfs) -> CGFloat {
        guard dB.isFinite else { return 0 }
        switch scale {
        case .dbfs:
            return CGFloat(max(0, min(1, (dB + 60) / 60)))
        case .deviation(let fullScale, let limit):
            guard fullScale > 0 else { return 0 }
            let kHz = pow(10.0, Double(dB) / 20.0) * limit
            return CGFloat(max(0, min(1, kHz / fullScale)))
        }
    }

    private var width: CGFloat {
        let bars = CGFloat(max(1, readings.count))
        return bars * Self.barWidth + bars * Self.barGap + Self.scaleWidth
    }

    public var body: some View {
        Canvas { context, size in
            let barHeight = size.height - Self.labelHeight
            var x: CGFloat = 0
            for (index, reading) in readings.enumerated() {
                let label = index < labels.count ? labels[index] : ""
                drawBar(reading, label: label, in: context, x: x, barHeight: barHeight)
                x += Self.barWidth + Self.barGap
            }
            drawScale(in: context, x: x, barHeight: barHeight)
        }
        .frame(width: width, height: height)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readings.count > 1 ? "Left and right level meters" : "Level meter")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        let parts = readings.enumerated().map { index, reading -> String in
            let name = index < labels.count && !labels[index].isEmpty ? labels[index] + " " : ""
            return name + Self.readout(reading.peakDBFS, scale: scale)
        }
        return parts.joined(separator: ", ")
    }

    /// The value as the scale's unit, for readouts beside the meter.
    public static func readout(_ dB: Float, scale: LadderMeterScale) -> String {
        switch scale {
        case .dbfs:
            return dB.isFinite ? String(format: "%.1f dBFS", dB) : "-inf dBFS"
        case .deviation(_, let limit):
            let kHz = dB.isFinite ? pow(10.0, Double(dB) / 20.0) * limit : 0
            return String(format: "%.1f kHz", kHz)
        }
    }

    private var gradient: Gradient {
        switch scale {
        case .dbfs:
            return Gradient(stops: [
                .init(color: Self.green, location: 0),
                .init(color: Self.green, location: 0.70),
                .init(color: Self.yellow, location: 0.82),
                .init(color: Self.orange, location: 0.93),
                .init(color: Self.red, location: 1)
            ])
        case .deviation(let fullScale, let limit):
            let g = CGFloat(max(0.05, min(0.95, limit / max(1, fullScale))))
            return Gradient(stops: [
                .init(color: Self.green, location: 0),
                .init(color: Self.green, location: g * 0.80),
                .init(color: Self.yellow, location: g * 0.93),
                .init(color: Self.orange, location: g),
                .init(color: Self.red, location: min(1, g + 0.03)),
                .init(color: Self.red, location: 1)
            ])
        }
    }

    private var marks: [(fraction: CGFloat, text: String, emphasised: Bool)] {
        switch scale {
        case .dbfs:
            return [0, -6, -12, -18, -30, -40, -60].map { (mark: Float) in
                (Self.fraction(mark), mark == 0 ? "0" : String(format: "%.0f", mark), mark == 0)
            }
        case .deviation(let fullScale, let limit):
            let step = fullScale <= 40 ? 10.0 : 25.0
            var values = Array(stride(from: 0.0, through: fullScale, by: step))
            if !values.contains(where: { abs($0 - limit) < step * 0.3 }) { values.append(limit) }
            return values.map { kHz in
                (CGFloat(kHz / fullScale), String(format: "%.0f", kHz), abs(kHz - limit) < 0.5)
            }
        }
    }

    private static let green = Color(red: 0.25, green: 0.80, blue: 0.45)
    private static let yellow = Color(red: 0.98, green: 0.80, blue: 0.20)
    private static let orange = Color(red: 0.98, green: 0.55, blue: 0.15)
    private static let red = Color(red: 0.95, green: 0.25, blue: 0.22)

    private func drawBar(
        _ reading: LadderMeterReading, label: String, in context: GraphicsContext, x: CGFloat, barHeight: CGFloat
    ) {
        let rect = CGRect(x: x, y: 0, width: Self.barWidth, height: barHeight)
        let shape = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)
        var bar = context
        bar.clip(to: shape)
        bar.fill(shape, with: .color(.black.opacity(0.42)))
        let fill = barHeight * Self.fraction(reading.peakDBFS, scale: scale)
        if fill > 0 {
            let filled = CGRect(x: x, y: barHeight - fill, width: Self.barWidth, height: fill)
            bar.fill(Path(filled), with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: x, y: barHeight),
                endPoint: CGPoint(x: x, y: 0)))
        }
        if reading.heldPeakDBFS.isFinite {
            let y = (barHeight - 2) * (1 - Self.fraction(reading.heldPeakDBFS, scale: scale))
            bar.fill(Path(CGRect(x: x, y: y, width: Self.barWidth, height: 2)), with: .color(.white.opacity(0.85)))
        }
        // LED segment lines give the ladder its hardware feel.
        var segments = Path()
        var y: CGFloat = 3
        while y < barHeight {
            segments.move(to: CGPoint(x: x, y: y))
            segments.addLine(to: CGPoint(x: x + Self.barWidth, y: y))
            y += 3
        }
        bar.stroke(segments, with: .color(.black.opacity(0.30)), lineWidth: 1)
        if reading.clipped {
            bar.fill(Path(CGRect(x: x, y: 0, width: Self.barWidth, height: 4)), with: .color(.red))
        }
        context.stroke(shape, with: .color(.white.opacity(0.10)), lineWidth: 1)
        if !label.isEmpty {
            context.draw(
                Text(label).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary),
                at: CGPoint(x: x + Self.barWidth / 2, y: barHeight + Self.labelHeight / 2))
        }
    }

    private func drawScale(in context: GraphicsContext, x: CGFloat, barHeight: CGFloat) {
        for mark in marks {
            let y = min(barHeight - 5, max(5, barHeight * (1 - mark.fraction)))
            context.fill(Path(CGRect(x: x, y: y, width: 4, height: 1)), with: .color(.secondary.opacity(0.6)))
            let text = Text(mark.text)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(mark.emphasised ? .secondary : .tertiary)
            context.draw(text, at: CGPoint(x: x + 7, y: y), anchor: .leading)
        }
    }
}
