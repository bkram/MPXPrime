import SwiftUI

// Always-visible header. Sits immediately under the window chrome and
// stays present across all sections so the operator never loses sight
// of "is the encoder running, on what source, at what rate" while
// tweaking DSP or RDS.
//
// Industry pattern (Stereo Tool / Logic Pro / Final Cut / Apple Music):
// the always-visible top strip is **transport + hardware health only**
// — content-level numbers (input dB, GR, modulation %, pilot/RDS
// injection) belong in dedicated panels in the relevant section, not
// multiplexed onto a status strip across every tab. This view holds
// the line at three small label/value pairs: Transport state,
// Source, Sample rate. Everything else moved to MonitoringDashboardView
// as proper Cards (MPX, Headroom, Subcarriers).

struct BroadcastStatusBar: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            transportChip
            divider
            sourceChip
            divider
            sampleRateChip
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BroadcastStyle.meterSurface.opacity(0.85))
        .overlay(
            Rectangle()
                .fill(BroadcastStyle.panelBorder)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Chips

    private var transportChip: some View {
        HStack(spacing: 8) {
            BroadcastStyle.ledHalo(
                for: model.isRunning ? BroadcastStyle.safeGreen : Color.secondary,
                active: model.isRunning
            )
            chipLabelledValue(
                label: "TRANSPORT",
                value: model.isRunning ? "RUNNING" : "STOPPED",
                tint: model.isRunning ? BroadcastStyle.safeGreen : Color.secondary
            )
        }
    }

    private var sourceChip: some View {
        let raw = model.streamHealth.inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (model.streamHealth.isRunning && !raw.isEmpty) ? raw : "—"
        return chipLabelledValue(
            label: "SOURCE",
            value: value,
            tint: .primary
        )
    }

    private var sampleRateChip: some View {
        let rate = model.streamHealth.renderHz
        let value = rate > 0 ? "\(rate / 1_000) kHz" : "—"
        return chipLabelledValue(
            label: "RATE",
            value: value,
            tint: .primary
        )
    }

    /// Compact label-over-value chip. Single small font for the value;
    /// no aggressive color coding (the only color is the transport LED
    /// dot — everything else inherits the system foreground). Width
    /// floats with content rather than locking to fixed columns; this
    /// header is informational, not a meter strip.
    private func chipLabelledValue(
        label: String,
        value: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
            Text(value)
                .font(BroadcastStyle.chipValue)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(BroadcastStyle.panelBorder)
            .frame(width: 0.5, height: 22)
    }
}
