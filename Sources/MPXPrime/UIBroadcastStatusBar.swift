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
// -- content-level numbers (input dB, GR, modulation %, pilot/RDS
// injection) belong in dedicated panels in the relevant section, not
// multiplexed onto a status strip across every tab. This view holds
// the line at Transport, Source, Rate and Mode, plus three chips that
// appear only while they apply: the listening Monitor, Bypassed (red) and
// Restart to Apply. Levels live on Monitoring and in the Levels window.

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
            // The listening monitor runs alongside the transmitter feed in
            // every mode; it is an indicator of its own, never a mode.
            if model.monitorEnabled {
                divider
                monitorChip
            }
            if model.processingBypass {
                divider
                bypassChip
            }
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
    /// running on built-in Mac audio (96 kHz) with RDS enabled -- output
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
        if model.streamSummary.isRunning && model.streamSummary.renderHz > 0 {
            effectiveRate = model.streamSummary.renderHz
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
                label: "RDS Warning",
                value: "Rate < 192 kHz",
                tint: .orange
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RDS warning: output sample rate is below 192 kHz; the RDS subcarrier aliases and will not decode")
        .help("The 57 kHz RDS subcarrier cannot be represented below a 192 kHz output sample rate: the upper sideband near 59 kHz aliases back into the audio band and no receiver will decode RDS. Raise the sample rate to 192 kHz (Audio I/O > Engine) or turn RDS off.")
    }

    /// The one restart signal: a chip-button that says what to do. Shows
    /// whenever a restart-class setting changed while the engine runs
    /// (`runtimeApplyPending`); clicking it restarts the engine, like
    /// Control > Restart to Apply (Shift-Cmd-A).
    private var restartPendingChip: some View {
        Button {
            model.applyPendingRuntimeChanges()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(BroadcastStyle.tightAmber)
                    .accessibilityHidden(true)
                chipLabelledValue(
                    label: "Restart",
                    value: model.runtimeApplyButtonTitle,
                    tint: BroadcastStyle.tightAmber
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Restart to apply: a changed setting needs an engine restart. Activate to restart now.")
        .help("A changed setting takes effect only after an engine restart. The new value is saved but not yet on air. Click to restart the engine now (Shift-Command-A).")
    }

    /// Red while the whole chain is bypassed: the station is unprocessed.
    private var bypassChip: some View {
        Button {
            model.toggleBypass()
        } label: {
            chipLabelledValue(label: "Processing", value: "Bypassed", tint: BroadcastStyle.overRed)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processing bypassed. Activate to process again.")
        .help("All processing is bypassed. Click to process again (Command-B).")
    }

    /// The listening monitor is on (a second output, every mode).
    private var monitorChip: some View {
        chipLabelledValue(label: "Monitor", value: "On", tint: .primary)
            .help("The listening monitor plays alongside the transmitter feed (Audio I/O > Monitor).")
    }

    // MARK: - Chips

    private var transportChip: some View {
        HStack(spacing: 8) {
            BroadcastStyle.ledHalo(
                for: model.isRunning ? BroadcastStyle.safeGreen : Color.secondary,
                active: model.isRunning
            )
            // Decorative -- the adjacent value text ("RUNNING"/"STOPPED")
            // already carries transport state to VoiceOver.
            .accessibilityHidden(true)
            chipLabelledValue(
                label: "Transport",
                value: model.isRunning ? "Running" : "Stopped",
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
            chipLabelledValue(
                label: "Source",
                value: Self.sourceText(
                    inputName: t.streamSummary.inputName,
                    isRunning: t.streamSummary.isRunning,
                    sourceMode: model.config.sourceMode),
                tint: .primary
            )
        }
    }

    /// What feeds the chain: the test tone while it runs (it REPLACES the
    /// input, so the device name would be wrong), else the input device.
    static func sourceText(inputName: String, isRunning: Bool, sourceMode: String) -> String {
        guard isRunning else { return "-" }
        if sourceMode.lowercased() == "tone" { return Stage.testTone.label }
        let raw = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "-" : raw
    }

    private var sampleRateChip: some View {
        LiveObservationView(telemetry: model.telemetry) { t in
            let rate = t.streamSummary.renderHz
            let value = rate > 0 ? "\(rate / 1_000) kHz" : "-"
            chipLabelledValue(
                label: "Rate",
                value: value,
                tint: .primary
            )
        }
    }

    /// The operating mode, spelled exactly as everywhere else
    /// (`OperatingMode.title`). The configured mode: a change made while
    /// running shows the restart chip beside it.
    private var outputModeChip: some View {
        chipLabelledValue(label: "Mode", value: Self.modeText(model.config.operatingMode), tint: .primary)
    }

    static func modeText(_ mode: AppConfig.OperatingMode) -> String { mode.title }

    /// Compact label-over-value chip. Single small font for the value;
    /// no aggressive color coding (the only color is the transport LED
    /// dot -- everything else inherits the system foreground). Width
    /// floats with content rather than locking to fixed columns; this
    /// header is informational, not a meter strip.
    private func chipLabelledValue(
        label: String,
        value: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // Title Case source strings, drawn as small caps.
            Text(label)
                .font(BroadcastStyle.chipLabel)
                .textCase(.uppercase)
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
