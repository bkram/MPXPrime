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
            if model.runtimeApplyPending {
                divider
                restartPendingChip
            }
            if rdsAtInsufficientRate {
                divider
                rdsRateWarningChip
            }
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

    // MARK: - RDS + sample-rate misconfiguration warning

    /// RDS sits at 57 kHz; the upper RDS sideband at ~59 kHz needs a
    /// sample rate of at least 192 kHz for the chain to represent it
    /// without aliasing. The most common amateur misconfiguration is
    /// running on built-in Mac audio (96 kHz) with RDS enabled — output
    /// looks fine on the meters but the RDS subcarrier folds back into
    /// the audio band, and no receiver will decode it. Surface a chip
    /// the moment we detect that condition, whether the engine is
    /// running (compare against the actual `renderHz`) or stopped
    /// (compare against the configured `sampleRate`).
    private var rdsAtInsufficientRate: Bool {
        guard model.config.enRDS else { return false }
        let effectiveRate: Int
        if model.streamHealth.isRunning && model.streamHealth.renderHz > 0 {
            effectiveRate = model.streamHealth.renderHz
        } else {
            effectiveRate = Int(model.config.sampleRate)
        }
        return effectiveRate < 192_000
    }

    private var rdsRateWarningChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            chipLabelledValue(
                label: "RDS WARNING",
                value: "RATE < 192 kHz",
                tint: .orange
            )
        }
        .help("RDS subcarrier at 57 kHz cannot be represented below 192 kHz output sample rate — the upper sideband at ~59 kHz aliases back into the audio band and no receiver will decode RDS. Either raise the output sample rate to 192 kHz (Audio MIDI Setup + the engine's `sample_rate`) or disable RDS for this output configuration.")
    }

    /// Globally visible "Restart pending" indicator. Shows whenever one
    /// or more restart-required settings have been changed but the engine
    /// is still running the old values (`runtimeApplyPending`). Single
    /// always-visible chip is intentionally less invasive than per-card
    /// badges, but more discoverable than the existing status-text
    /// approach that operators were missing in dense tabs.
    private var restartPendingChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            chipLabelledValue(
                label: "PENDING",
                value: "RESTART REQ.",
                tint: .yellow
            )
        }
        .help("One or more restart-required settings have been changed since the engine started. The new values are saved but not on-air — use Apply Restart in Monitoring to stop and restart the engine so they take effect. Sample rate, block size, source mode, monitor routing, device changes, pre-emphasis, pilot/sum/diff levels, FIR settings, and dual-rate boundary are restart-required; everything else applies live.")
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
