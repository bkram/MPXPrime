import SwiftUI

// Canvas FFT spectrum plot (shared): filled gradient area + line, dB grid,
// kHz axis, optional Nyquist shading, and optional frequency markers (the
// Meter passes pilot/38k/57k). Takes plain dB bins + display scalars; both
// apps feed it.
public struct MPXSpectrumView: View {
    let dbBins: [Float]
    let maxHz: Double
    let nyquistHz: Double
    /// Optional vertical reference markers in Hz (e.g. 19k/38k/57k). Default
    /// nil keeps existing transmit call sites unchanged.
    var markersHz: [Double]?
    /// When true, draw the FM composite band regions (Mono L+R, 19 kHz Pilot,
    /// Stereo L-R, 57 kHz RDS, SCA) as trapezoid outlines + captions along the
    /// bottom, MpxTool-style. Default false leaves transmit call sites unchanged.
    var showBandLabels: Bool

    private let dbMin: Float = -100.0
    private let dbMax: Float = 0.0

    // Standard FM composite band regions (lo, hi in Hz; two-line caption).
    private static let compositeBands: [(lo: Double, hi: Double, top: String, bottom: String)] = [
        (500, 15_000, "Mono", "L+R"),
        (18_000, 20_000, "19 kHz", "Pilot"),
        (23_000, 37_000, "Stereo", "L-R"),
        (39_000, 53_000, "Stereo", "L-R"),
        (55_000, 59_000, "57 kHz", "RDS"),
        (64_000, 71_000, "67.65 kHz", "Direct Band"),
        (88_000, 96_000, "92 kHz", "SCA")
    ]

    public init(
        dbBins: [Float], maxHz: Double, nyquistHz: Double,
        markersHz: [Double]? = nil, showBandLabels: Bool = false
    ) {
        self.dbBins = dbBins
        self.maxHz = maxHz
        self.nyquistHz = nyquistHz
        self.markersHz = markersHz
        self.showBandLabels = showBandLabels
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius),
                    with: .color(BroadcastStyle.instrumentBackground))
                let maxDisplayHz = max(1_000.0, maxHz)
                let nyquist = max(0.0, min(maxDisplayHz, nyquistHz))
                let leftAxisWidth: CGFloat = 42
                let rightAxisWidth: CGFloat = 42
                let topInset: CGFloat = 8
                let bottomInset: CGFloat = 20
                let plotRect = CGRect(
                    x: leftAxisWidth,
                    y: topInset,
                    width: max(10, size.width - leftAxisWidth - rightAxisWidth),
                    height: max(10, size.height - topInset - bottomInset)
                )

                // Grid and border inside the plot region.
                var grid = Path()
                for db in stride(from: -100, through: 0, by: 10) {
                    let y = yPosition(forDB: Float(db), in: plotRect)
                    grid.move(to: CGPoint(x: plotRect.minX, y: y))
                    grid.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                }
                for tick in xTicks(maxHz: maxDisplayHz, dense: true) {
                    let x = xPosition(forHz: tick, in: plotRect, maxHz: maxDisplayHz)
                    grid.move(to: CGPoint(x: x, y: plotRect.minY))
                    grid.addLine(to: CGPoint(x: x, y: plotRect.maxY))
                }
                context.stroke(grid, with: .color(BroadcastStyle.instrumentGrid), lineWidth: 0.9)
                context.stroke(
                    Path(plotRect),
                    with: .color(BroadcastStyle.instrumentLabel.opacity(0.5)),
                    lineWidth: 1.0
                )

                // Left and right Y-axis labels.
                for db in stride(from: -100, through: 0, by: 10) {
                    let y = yPosition(forDB: Float(db), in: plotRect)
                    let label = db == 0 ? "0 dB" : "\(db) dB"
                    let text = Text(label)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(BroadcastStyle.instrumentLabel)
                    context.draw(text, at: CGPoint(x: 18, y: y))
                    context.draw(text, at: CGPoint(x: size.width - 18, y: y))
                }

                // Bottom X-axis labels.
                for tick in xTicks(maxHz: maxDisplayHz, dense: false) {
                    let x = xPosition(forHz: tick, in: plotRect, maxHz: maxDisplayHz)
                    let kHz = Int((tick / 1000.0).rounded())
                    let label = Text("\(kHz) kHz")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(BroadcastStyle.instrumentLabel)
                    context.draw(label, at: CGPoint(x: x, y: plotRect.maxY + 12))
                }

                guard dbBins.count > 1 else { return }

                let stepX = plotRect.width / CGFloat(dbBins.count - 1)
                var line = Path()
                for (idx, value) in dbBins.enumerated() {
                    let x = plotRect.minX + (CGFloat(idx) * stepX)
                    let y = yPosition(forDB: max(dbMin, min(dbMax, value)), in: plotRect)
                    if idx == 0 {
                        line.move(to: CGPoint(x: x, y: y))
                    } else {
                        line.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                var fill = line
                fill.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
                fill.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
                fill.closeSubpath()
                let gradient = Gradient(colors: [
                    Color.red.opacity(0.65),
                    Color.yellow.opacity(0.60),
                    Color.green.opacity(0.55),
                    Color.cyan.opacity(0.50),
                    Color.blue.opacity(0.45)
                ])
                context.fill(
                    fill,
                    with: .linearGradient(
                        gradient, startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(.white.opacity(0.7)), lineWidth: 1.0)

                if nyquist > 0.0, nyquist < maxDisplayHz {
                    let xNyquist = xPosition(forHz: nyquist, in: plotRect, maxHz: maxDisplayHz)
                    let unsupportedRect = CGRect(
                        x: xNyquist,
                        y: plotRect.minY,
                        width: max(0, plotRect.maxX - xNyquist),
                        height: plotRect.height
                    )
                    context.fill(
                        Path(unsupportedRect),
                        with: .color(.black.opacity(0.38))
                    )
                }

                // Optional reference markers (e.g. pilot 19k / 38k / RDS 57k).
                if let markersHz {
                    for marker in markersHz where marker > 0.0 && marker < maxDisplayHz {
                        let x = xPosition(forHz: marker, in: plotRect, maxHz: maxDisplayHz)
                        var mline = Path()
                        mline.move(to: CGPoint(x: x, y: plotRect.minY))
                        mline.addLine(to: CGPoint(x: x, y: plotRect.maxY))
                        context.stroke(
                            mline, with: .color(.orange.opacity(0.55)),
                            style: StrokeStyle(lineWidth: 1.0, dash: [3, 3]))
                        let kHz = Int((marker / 1000.0).rounded())
                        context.draw(
                            Text("\(kHz)k").font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.orange.opacity(0.95)),
                            at: CGPoint(x: x, y: plotRect.minY + 7))
                    }
                }

                // FM composite band regions: trapezoid outline + two-line caption
                // along the bottom (MpxTool-style reference labels).
                if showBandLabels {
                    let bandColor = Color(.sRGB, red: 0.80, green: 0.74, blue: 0.46, opacity: 1.0)
                    let baseY = plotRect.maxY
                    let trapTop = plotRect.maxY - plotRect.height * 0.30
                    for band in Self.compositeBands where band.lo < maxDisplayHz {
                        let xLo = xPosition(forHz: band.lo, in: plotRect, maxHz: maxDisplayHz)
                        let xHi = xPosition(forHz: min(band.hi, maxDisplayHz), in: plotRect, maxHz: maxDisplayHz)
                        let slope = min(10.0, (xHi - xLo) * 0.28)
                        var trap = Path()
                        trap.move(to: CGPoint(x: xLo, y: baseY))
                        trap.addLine(to: CGPoint(x: xLo + slope, y: trapTop))
                        trap.addLine(to: CGPoint(x: xHi - slope, y: trapTop))
                        trap.addLine(to: CGPoint(x: xHi, y: baseY))
                        context.stroke(trap, with: .color(bandColor.opacity(0.35)), lineWidth: 1.0)
                        let cx = (xLo + xHi) * 0.5
                        context.draw(
                            Text(band.top).font(.system(.caption2, design: .monospaced))
                                .foregroundColor(bandColor.opacity(0.95)),
                            at: CGPoint(x: cx, y: trapTop + 15))
                        context.draw(
                            Text(band.bottom).font(.system(.caption2, design: .monospaced))
                                .foregroundColor(bandColor.opacity(0.95)),
                            at: CGPoint(x: cx, y: trapTop + 29))
                    }
                }
            }
            .frame(minHeight: 190, idealHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))

            HStack(spacing: 14) {
                let maxDisplayHz = max(1_000.0, maxHz)
                if nyquistHz > 0.0, nyquistHz < maxDisplayHz {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: 6, height: 6)
                        Text("Nyquist \(Int((nyquistHz / 1000.0).rounded())) kHz")
                    }
                }
                Spacer()
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
        }
        // Disable SwiftUI implicit animations on dbBins updates. Without this,
        // frame-to-frame interpolation queued accumulated when 30 Hz spectrum
        // updates were interrupted mid-interpolation — visible as growing lag.
        .transaction { txn in
            txn.animation = nil
        }
        // Canvas content is invisible to VoiceOver; name the region.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MPX spectrum, 0 to \(Int((maxHz / 1000.0).rounded())) kHz")
        .accessibilityAddTraits(.isImage)
    }

    private func yPosition(forDB db: Float, height: CGFloat) -> CGFloat {
        let clamped = max(dbMin, min(dbMax, db))
        let norm = (clamped - dbMin) / (dbMax - dbMin)
        return (1.0 - CGFloat(norm)) * height
    }

    private func yPosition(forDB db: Float, in rect: CGRect) -> CGFloat {
        rect.minY + yPosition(forDB: db, height: rect.height)
    }

    private func xPosition(forHz hz: Double, in rect: CGRect, maxHz: Double) -> CGFloat {
        let ratio = CGFloat(max(0.0, min(1.0, hz / max(1_000.0, maxHz))))
        return rect.minX + (ratio * rect.width)
    }

    private func xTicks(maxHz: Double, dense: Bool) -> [Double] {
        let maxDisplayHz = max(1_000.0, maxHz)
        let step = dense ? 5_000.0 : 10_000.0
        var ticks: [Double] = [0.0]
        var value = step
        while value < maxDisplayHz {
            ticks.append(value)
            value += step
        }
        if ticks.last != maxDisplayHz {
            ticks.append(maxDisplayHz)
        }
        return ticks
    }
}
