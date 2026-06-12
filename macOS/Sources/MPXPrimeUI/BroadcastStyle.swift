import AppKit
import SwiftUI

// Centralised visual vocabulary for the MPX Prime broadcast-console look,
// shared by the transmit GUI and the MPX Prime Meter window.
// Orban Optimod silhouette: subdued warm palette, saturated signal colours
// for the at-a-glance state dots (safe / tight / over), soft LED halos on
// active indicators, tight panels-in-panels surfaces, monospaced numeric
// readouts for every metric.
//
// All colours are dynamic (light/dark appearance aware) so the app stays
// HIG-correct — we do not force a theme.

public enum BroadcastStyle {

    // MARK: - Signal state palette
    // The three-state traffic-light used by every status dot, meter peak,
    // and budget chip in the app. Muted in light mode, slightly
    // brighter-saturated in dark mode so LED halos read well against
    // dark panels without glaring.

    public static let safeGreen = Color.adaptive(
        light: NSColor(calibratedRed: 0.18, green: 0.63, blue: 0.26, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.33, alpha: 1.0)
    )

    public static let tightAmber = Color.adaptive(
        light: NSColor(calibratedRed: 0.75, green: 0.53, blue: 0.00, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.82, green: 0.60, blue: 0.13, alpha: 1.0)
    )

    public static let overRed = Color.adaptive(
        light: NSColor(calibratedRed: 0.81, green: 0.13, blue: 0.18, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.97, green: 0.32, blue: 0.29, alpha: 1.0)
    )

    // MARK: - Informational accents

    /// Pilot / 19 kHz carrier indicator.
    public static let pilotBlue = Color.adaptive(
        light: NSColor(calibratedRed: 0.03, green: 0.41, blue: 0.85, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.34, green: 0.65, blue: 1.00, alpha: 1.0)
    )

    /// RDS / 57 kHz carrier indicator.
    public static let rdsMagenta = Color.adaptive(
        light: NSColor(calibratedRed: 0.51, green: 0.31, blue: 0.87, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.74, green: 0.55, blue: 1.00, alpha: 1.0)
    )

    /// App accent — used for targets and active-state highlights. Delegates
    /// to the user's system accent so the app respects "Use accent colour"
    /// preferences; falls back to a broadcast-friendly cyan.
    public static let accent = Color.accentColor

    // MARK: - Surfaces

    /// Meter / readout plate — slightly darker than panel so heat-mapped
    /// meter fills and LED dots pop.
    public static let meterSurface = Color.adaptive(
        light: NSColor(calibratedRed: 0.94, green: 0.94, blue: 0.95, alpha: 1.0),
        dark: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
    )

    /// Panel / Card body — sits atop the window content background.
    public static let panelSurface = Color(nsColor: .controlBackgroundColor)

    /// Hairline border between panels. Kept very subtle so it reads as
    /// broadcast chassis division, not a boxy UI.
    public static let panelBorder = Color.adaptive(
        light: NSColor(calibratedWhite: 0.70, alpha: 0.45),
        dark: NSColor(calibratedWhite: 0.35, alpha: 0.55)
    )

    // MARK: - Component fills
    // Centralised fills for the small chip / connector / tick surfaces that
    // used to inline raw hierarchical styles. Stored as type-erased
    // ShapeStyles so they reproduce the exact prior appearance (the
    // hierarchical `.quaternary` / `.tertiary` materials adapt to
    // appearance on their own) while giving a single source of truth.

    /// Signal-flow strip inactive stage pill background.
    public static let stagePillFill = AnyShapeStyle(.quaternary.opacity(0.4))

    /// Signal-flow strip terminal (IN / OUT / CODER) pill background.
    public static let terminalPillFill = AnyShapeStyle(.tertiary.opacity(0.18))

    /// Signal-flow strip connector line between chips.
    public static let connectorFill = AnyShapeStyle(.tertiary.opacity(0.5))

    /// Meter scale tick mark fill.
    public static let scaleTick = Color.primary.opacity(0.32)

    // MARK: - Readout foreground

    /// Hero monospaced readouts (Peak, Deviation, GR, Budget margin).
    public static let readoutPrimary = Color.primary

    /// Secondary labels and unit text.
    public static let readoutSecondary = Color.secondary

    // MARK: - Typography

    /// Hero numeric readout. Used for values that an operator watches
    /// continuously — input peak, MPX peak, deviation, limiter GR, budget
    /// margin. Large enough to read across a studio.
    public static let heroReadout: Font = .system(.title3, design: .monospaced).weight(.semibold)

    /// Standard numeric readout inside parameter rows, metric grids, and
    /// cards. The current `.callout.monospaced()` equivalent.
    public static let valueReadout: Font = .system(.callout, design: .monospaced)

    /// Meter scale tick labels and chip micro-labels.
    public static let scaleLabel: Font = .system(.caption2, design: .monospaced)

    /// Status chip label (small uppercase tag above a value — "IN L",
    /// "DEV", "GR", "BUDGET").
    public static let chipLabel: Font = .caption2.weight(.semibold)

    /// Status chip value (monospaced, slightly heavier than valueReadout).
    public static let chipValue: Font = .system(.callout, design: .monospaced).weight(.semibold)

    // MARK: - Geometry

    public static let panelCornerRadius: CGFloat = 10
    public static let panelInsetCornerRadius: CGFloat = 8
    public static let cardPadding: CGFloat = 12
    public static let cardSpacing: CGFloat = 8
    public static let meterCardPadding: CGFloat = 10
    public static let meterCardSpacing: CGFloat = 6
    public static let statusDotSize: CGFloat = 10
    public static let meterBarHeight: CGFloat = 14
    public static let meterScaleHeight: CGFloat = 14

    // MARK: - LED halo

    /// Subtle glow applied to active status dots. Takes the dot's colour
    /// directly so each LED halos in its own tint.
    @inline(__always)
    public static func ledHalo(for tint: Color, active: Bool = true) -> some View {
        Circle()
            .fill(tint)
            .frame(width: statusDotSize, height: statusDotSize)
            .shadow(color: active ? tint.opacity(0.55) : .clear, radius: 2.5)
    }

    // MARK: - Signal-state helper
    //
    // Small utility so meters, pills, and budget chips agree on the mapping
    // from a normalised 0…1 level to a single paint colour. Thresholds
    // match the current `MeterBar.meterTint` behaviour, but all four
    // historical call sites now look up the colour here.

    public static func tint(forLevel level: Double, limitNorm: Double? = nil) -> Color {
        if let limit = limitNorm {
            let lim = max(0.01, min(1.0, limit))
            if level > lim { return overRed }
            if level >= lim * 0.95 { return tightAmber }
            if level >= lim * 0.80 { return tightAmber.opacity(0.80) }
            return safeGreen
        }
        if level >= 0.92 { return overRed }
        if level >= 0.83 { return tightAmber }
        if level >= 0.66 { return tightAmber.opacity(0.80) }
        return safeGreen
    }
}

// MARK: - Dynamic colour helper

extension Color {
    /// Builds a light/dark-appearance-aware SwiftUI `Color` from two
    /// `NSColor` instances. Used by `BroadcastStyle` so every palette
    /// entry tracks the user's macOS appearance without per-view
    /// `colorScheme` branching.
    public static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            NSColor(name: nil) { appearance in
                switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
                case .darkAqua: return dark
                default: return light
                }
            }
        )
    }
}
