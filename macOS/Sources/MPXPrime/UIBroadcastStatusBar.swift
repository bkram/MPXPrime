import SwiftUI

// Always-visible broadcast-status header. Sits immediately under the
// window chrome and stays present across all three sections
// (Monitoring, Processing, RDS) so the operator never loses sight of
// transport state, levels, and composite-safety margins while tweaking
// DSP or RDS. Orban Optimod hardware silhouette — tight columns of
// labelled chips, LED-style status dot, monospaced numeric readouts.

struct BroadcastStatusBar: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            wrappedLayout
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BroadcastStyle.meterSurface.opacity(0.85))
        .overlay(
            Rectangle()
                .fill(BroadcastStyle.panelBorder)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Layouts

    /// Single-row layout for wider windows.
    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 14) {
            transportChip
            divider
            peakChip(label: "IN L", value: model.inputLText, level: model.inputLLevel)
            peakChip(label: "IN R", value: model.inputRText, level: model.inputRLevel)
            divider
            peakChip(label: "MPX", value: model.outputText, level: model.outputLevel, emphasized: true)
            deviationChip
            modulationChip
            divider
            gainReductionChip(
                label: "GR",
                valueDB: model.compositeClipperGainReductionDBValue
            )
            gainReductionChip(
                label: "SAFE",
                valueDB: model.safetyLimiterGainReductionDBValue
            )
            budgetChip
            divider
            injectionChip(label: "PILOT", percent: model.pilotInjectionPercentValue, tint: BroadcastStyle.pilotBlue)
            injectionChip(label: "RDS", percent: model.rdsInjectionPercentValue, tint: BroadcastStyle.rdsMagenta)
            Spacer(minLength: 0)
        }
    }

    /// Two-row fallback for narrow windows. Preserves every chip, just
    /// wraps after the input-peak group.
    private var wrappedLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                transportChip
                peakChip(label: "IN L", value: model.inputLText, level: model.inputLLevel)
                peakChip(label: "IN R", value: model.inputRText, level: model.inputRLevel)
                peakChip(label: "MPX", value: model.outputText, level: model.outputLevel, emphasized: true)
                deviationChip
                modulationChip
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                gainReductionChip(label: "GR", valueDB: model.compositeClipperGainReductionDBValue)
                gainReductionChip(label: "SAFE", valueDB: model.safetyLimiterGainReductionDBValue)
                budgetChip
                injectionChip(label: "PILOT", percent: model.pilotInjectionPercentValue, tint: BroadcastStyle.pilotBlue)
                injectionChip(label: "RDS", percent: model.rdsInjectionPercentValue, tint: BroadcastStyle.rdsMagenta)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Chips
    //
    // Every value-bearing chip reserves a fixed-width frame for its
    // readout column so the bar doesn't shuffle horizontally as values
    // gain or lose digits, signs, or secondary peak-hold suffixes
    // ("…pk"). Widths chosen to fit the worst-case formatted string in
    // the monospaced value font.

    /// Column widths in points. Tuned against the `.system(.callout, .monospaced)`
    /// metric at default text size. Each value is sized to fit the
    /// worst-case formatted string (e.g. "-99.9 dBFS   -99.9 pk").
    private enum W {
        static let peak: CGFloat = 168   // "-99.9 dBFS   -99.9 pk"
        static let mpxPeak: CGFloat = 178  // heroReadout is a touch wider
        static let deviation: CGFloat = 108  // "-999.9 kHz"
        static let modulation: CGFloat = 80  // "100.0%"
        static let grValue: CGFloat = 64   // "16.0 dB"
        static let budgetValue: CGFloat = 76  // "+99.9 dB"
        static let injectionValue: CGFloat = 56  // "99.9%"
        static let transportValue: CGFloat = 78  // "STOPPED"
    }

    private var transportChip: some View {
        HStack(spacing: 8) {
            BroadcastStyle.ledHalo(for: model.isRunning ? BroadcastStyle.safeGreen : Color.secondary, active: model.isRunning)
            chipLabelledValue(
                label: "TRANSPORT",
                value: model.isRunning ? "RUNNING" : "STOPPED",
                width: W.transportValue,
                valueFont: BroadcastStyle.chipValue,
                tint: model.isRunning ? BroadcastStyle.safeGreen : Color.secondary
            )
        }
    }

    private func peakChip(label: String, value: String, level: Double, emphasized: Bool = false) -> some View {
        let tint = BroadcastStyle.tint(forLevel: level)
        return chipLabelledValue(
            label: label,
            value: value,
            width: emphasized ? W.mpxPeak : W.peak,
            valueFont: emphasized ? BroadcastStyle.heroReadout : BroadcastStyle.chipValue,
            tint: tint
        )
    }

    private var deviationChip: some View {
        let limit: Double = 75.0
        let kHz = Double(model.estimatedDeviationPeakKHz)
        let norm = max(0.0, min(1.0, kHz / 100.0))
        let tint = BroadcastStyle.tint(forLevel: norm, limitNorm: limit / 100.0)
        return chipLabelledValue(
            label: "DEV",
            value: String(format: "%.1f kHz", kHz),
            width: W.deviation,
            valueFont: BroadcastStyle.heroReadout,
            tint: tint
        )
    }

    /// Modulation as a percentage of the configured deviation target.
    /// Stereotool/Omnia/Optimod all surface this — operators tune by %
    /// even when the kHz figure is also visible. References the user's
    /// configured `mpx_deviation_khz` (not the 75 kHz regulatory line),
    /// so a custom-target setup reads "100%" at whatever kHz the
    /// operator picked.
    private var modulationChip: some View {
        let peakKHz = Double(model.estimatedDeviationPeakKHz)
        let limitKHz = max(1.0, model.config.mpxDeviationKHz)
        let percent = (peakKHz / limitKHz) * 100.0
        let norm = max(0.0, min(1.0, percent / 100.0))
        let tint = BroadcastStyle.tint(forLevel: norm, limitNorm: 1.0)
        return chipLabelledValue(
            label: "MOD",
            value: String(format: "%.1f%%", percent),
            width: W.modulation,
            valueFont: BroadcastStyle.heroReadout,
            tint: tint
        )
    }

    private func gainReductionChip(label: String, valueDB: Float) -> some View {
        // GR is positive-magnitude attenuation; ~1-3 dB is healthy,
        // >6 dB indicates sustained limiting.
        let db = Double(valueDB)
        let tint: Color
        if db >= 6.0 { tint = BroadcastStyle.overRed }
        else if db >= 3.0 { tint = BroadcastStyle.tightAmber }
        else if db > 0.1 { tint = BroadcastStyle.safeGreen }
        else { tint = .secondary }
        return chipLabelledValue(
            label: label,
            value: String(format: "%.1f dB", db),
            width: W.grValue,
            valueFont: BroadcastStyle.chipValue,
            tint: tint
        )
    }

    private var budgetChip: some View {
        let margin = Double(model.compositeBudgetMarginDBValue)
        let tint: Color
        if margin >= 0.5 { tint = BroadcastStyle.safeGreen }
        else if margin >= -0.5 { tint = BroadcastStyle.tightAmber }
        else { tint = BroadcastStyle.overRed }
        return HStack(spacing: 8) {
            BroadcastStyle.ledHalo(for: tint)
            chipLabelledValue(
                label: "BUDGET",
                value: String(format: "%+.1f dB", margin),
                width: W.budgetValue,
                valueFont: BroadcastStyle.chipValue,
                tint: tint
            )
        }
    }

    private func injectionChip(label: String, percent: Float, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint.opacity(0.85))
                .frame(width: 6, height: 6)
            chipLabelledValue(
                label: label,
                value: String(format: "%.1f%%", percent),
                width: W.injectionValue,
                valueFont: BroadcastStyle.chipValue,
                tint: .primary
            )
        }
    }

    /// Shared chip body: uppercase caption label stacked over a
    /// fixed-width monospaced value. `frame(width:)` on the value locks
    /// the chip width so sign flips and digit changes don't re-flow the
    /// rest of the bar. `.monospacedDigit()` keeps digits column-
    /// aligned within the reserved box.
    private func chipLabelledValue(
        label: String,
        value: String,
        width: CGFloat,
        valueFont: Font,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
            Text(value)
                .font(valueFont)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(BroadcastStyle.panelBorder)
            .frame(width: 0.5, height: 22)
    }
}
