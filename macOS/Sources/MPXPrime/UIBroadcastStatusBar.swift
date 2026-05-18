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
            ABCompareWidget(model: model)
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

/// A/B compare widget — two capture buttons + a swap button. Right-side
/// of the persistent status bar so it's always one click away while
/// the operator is tuning. Pro-workflow standard (Optimod / Stereotool /
/// Omnia). Slots are in-memory only — clear on app restart by design;
/// for persistent saves use the format profile picker or a future
/// Snapshots feature.
struct ABCompareWidget: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        HStack(spacing: 6) {
            Text("COMPARE")
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
            slotButton(slot: "a", title: "A", hasSlot: model.compareSlotA != nil)
            swapButton
            slotButton(slot: "b", title: "B", hasSlot: model.compareSlotB != nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .help("Capture A / B snapshots of the current config and swap between them while listening. Slots clear on app restart.")
        .contextMenu {
            Button("Clear A/B Slots") { model.clearCompareSlots() }
                .disabled(model.compareSlotA == nil && model.compareSlotB == nil)
        }
    }

    private func slotButton(slot: String, title: String, hasSlot: Bool) -> some View {
        let isActive = (model.compareActiveSlot == slot)
        return Button {
            model.captureCurrentToCompareSlot(slot)
        } label: {
            Text(title)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(
                    isActive ? Color.white : (hasSlot ? Color.primary : Color.secondary)
                )
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            isActive
                                ? BroadcastStyle.safeGreen
                                : (hasSlot ? Color.secondary.opacity(0.20) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            hasSlot ? Color.clear : Color.secondary.opacity(0.35),
                            lineWidth: 0.5
                        )
                )
        }
        .buttonStyle(.plain)
        .help(
            hasSlot
                ? (isActive
                    ? "Slot \(title) is active. Tap to re-capture current state into \(title)."
                    : "Tap to re-capture current state into slot \(title).")
                : "Slot \(title) is empty. Tap to capture the current config."
        )
    }

    private var swapButton: some View {
        let enabled = (model.compareSlotA != nil && model.compareSlotB != nil)
        return Button {
            model.swapCompareSlot()
        } label: {
            // Decorative — the Button's accessibilityLabel below carries
            // the action description to VoiceOver. Hiding the icon
            // prevents the screen reader from announcing "arrow.left
            // arrow.right" alongside our label.
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 22, height: 18)
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "Swap to the other slot." : "Capture both A and B before swapping.")
        .accessibilityLabel("Swap A and B compare slots")
        .accessibilityHint(enabled ? "Loads the inactive snapshot into the live engine." : "Capture both slots first.")
    }
}
