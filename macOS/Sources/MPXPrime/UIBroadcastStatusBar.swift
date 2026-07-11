// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import MPXPrimeUI
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
            divider
            outputModeChip
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
        // No RDS subcarrier exists in processed-audio output, so the warning is moot.
        guard !model.processedAudioOutputActive else { return false }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RDS warning: output sample rate is below 192 kHz; the RDS subcarrier aliases and will not decode")
        .help("RDS subcarrier at 57 kHz cannot be represented below 192 kHz output sample rate — the upper sideband at ~59 kHz aliases back into the audio band and no receiver will decode RDS. Either raise the output sample rate to 192 kHz (Audio MIDI Setup + the engine's `sample_rate`) or disable RDS for this output configuration.")
    }

    /// Globally visible "Restart pending" indicator. Shows whenever one
    /// or more restart-required settings have been changed but the engine
    /// is still running the old values (`runtimeApplyPending`). Single
    /// always-visible chip is intentionally less invasive than per-card
    /// badges, but more discoverable than the existing status-text
    /// approach that operators were missing in dense tabs.
    private var restartPendingChip: some View {
        // Actionable: clicking the always-visible chip stops and restarts the
        // engine to apply the pending restart-required changes — same as the
        // Control > Apply Restart menu item (Shift-Cmd-A), but reachable
        // without leaving a dense tab.
        Button {
            model.applyPendingRuntimeChanges()
        } label: {
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
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Restart pending: one or more changed settings need an engine restart to take effect. Activate to apply now.")
        .help("One or more restart-required settings have been changed since the engine started. The new values are saved but not on-air — use Apply Restart in Monitoring to stop and restart the engine so they take effect. Sample rate, block size, source mode, monitor routing, device changes, pre-emphasis, pilot/sum/diff levels, FIR settings, and dual-rate boundary are restart-required; everything else applies live.")
    }

    // MARK: - Chips

    private var transportChip: some View {
        HStack(spacing: 8) {
            BroadcastStyle.ledHalo(
                for: model.isRunning ? BroadcastStyle.safeGreen : Color.secondary,
                active: model.isRunning
            )
            // Decorative — the adjacent value text ("RUNNING"/"STOPPED")
            // already carries transport state to VoiceOver.
            .accessibilityHidden(true)
            chipLabelledValue(
                label: "TRANSPORT",
                value: model.isRunning ? "RUNNING" : "STOPPED",
                tint: model.isRunning ? BroadcastStyle.safeGreen : Color.secondary
            )
        }
    }

    // SOURCE / RATE come from streamHealth, which is populated by the
    // monitoring refresh (now on LiveTelemetry, not the view model). Observe
    // telemetry directly so these chips fill in after the engine starts;
    // otherwise the always-visible header would only refresh on a view-model
    // change and read a stale "-" until the next one.
    private var sourceChip: some View {
        LiveObservationView(telemetry: model.telemetry) { t in
            let raw = t.streamHealth.inputName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (t.streamHealth.isRunning && !raw.isEmpty) ? raw : "—"
            chipLabelledValue(
                label: "SOURCE",
                value: value,
                tint: .primary
            )
        }
    }

    private var sampleRateChip: some View {
        LiveObservationView(telemetry: model.telemetry) { t in
            let rate = t.streamHealth.renderHz
            let value = rate > 0 ? "\(rate / 1_000) kHz" : "—"
            chipLabelledValue(
                label: "RATE",
                value: value,
                tint: .primary
            )
        }
    }

    /// Current output mode: the FM composite (default), the decoded-MPX monitor,
    /// or processed stereo audio for an external coder. Reflects the selected
    /// config; restart-required changes show the pending-restart chip alongside.
    private var outputModeChip: some View {
        let value: String
        let tint: Color
        if model.processedAudioOutputActive {
            value = "PROC AUDIO"
            tint = BroadcastStyle.safeGreen
        } else if model.monitorEnabled {
            value = "MONITOR"
            tint = .primary
        } else {
            value = "COMPOSITE"
            tint = .primary
        }
        return chipLabelledValue(label: "MODE", value: value, tint: tint)
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
        // Read each chip as one item ("Transport, Running") rather than two
        // separate text fragments. State is carried by the value text, not
        // the transport LED alone, so this is color-independent.
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle()
            .fill(BroadcastStyle.panelBorder)
            .frame(width: 0.5, height: 22)
    }
}

#endif  // os(macOS)
