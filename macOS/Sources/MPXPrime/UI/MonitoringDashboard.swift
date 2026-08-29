// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI
import UniformTypeIdentifiers

struct MonitoringDashboardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                transportPanel
                metricsPanels
                chainPanel
                // No RDS in processed-audio output (no subcarrier carries it).
                if !model.processedAudioOutputActive {
                    rdsPanel
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Three side-by-side cards with the live broadcast metrics
    /// (previously crammed into the persistent top status strip):
    /// MPX peak / deviation / modulation, headroom across the peak-
    /// control stages, and subcarrier injection levels. Card layout
    /// matches the rdsPanel grid pattern (uppercase secondary label
    /// in the left column, monospaced value on the right). Wraps to
    /// stacked layout on narrow windows via `ViewThatFits`.
    private var metricsPanels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                mpxPanel.frame(maxWidth: .infinity)
                headroomPanel.frame(maxWidth: .infinity)
                // Pilot/RDS injection is composite-only; in processed-audio the
                // panel would be all N/A, so omit it.
                if !model.processedAudioOutputActive {
                    subcarriersPanel.frame(maxWidth: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                mpxPanel
                headroomPanel
                if !model.processedAudioOutputActive {
                    subcarriersPanel
                }
            }
        }
    }

    private var mpxPanel: some View {
        // In processed-audio mode there is no composite: deviation / modulation /
        // audio-composite peak are all meaningless. Show the output level and the
        // (still-valid) stereo image instead.
        Card(title: model.processedAudioOutputActive ? "Output" : "MPX") {
            LiveObservationView(telemetry: model.telemetry) { _ in
                if model.processedAudioOutputActive {
                    metricsGrid([
                        ("OUTPUT", model.outputText.ifEmpty("—")),
                        ("STEREO IMAGE", model.stereoImageText)
                    ])
                } else {
                    metricsGrid([
                        ("OUTPUT", model.outputText.ifEmpty("—")),
                        ("AUDIO COMPOSITE", audioCompositeText),
                        ("DEVIATION", String(format: "%5.1f kHz", model.estimatedDeviationPeakKHz)),
                        ("MODULATION", modulationText)
                    ])
                }
            }
        }
    }

    private var headroomPanel: some View {
        // Composite clipper / safety limiter / BS.412 don't run in processed-audio
        // output — only the pre-encode limiter does.
        Card(title: "Headroom") {
            LiveObservationView(telemetry: model.telemetry) { _ in
                if model.processedAudioOutputActive {
                    metricsGrid([
                        ("PRE-ENCODE GR", grText(model.preEncodeLimiterGainReductionDBValue))
                    ])
                } else {
                    metricsGrid([
                        ("PRE-ENCODE GR", grText(model.preEncodeLimiterGainReductionDBValue)),
                        ("COMPOSITE GR", grText(model.compositeClipperGainReductionDBValue)),
                        ("SAFETY GR", grText(model.safetyLimiterGainReductionDBValue)),
                        ("BS.412 BUDGET", budgetText)
                    ])
                }
            }
        }
    }

    private var subcarriersPanel: some View {
        Card(title: "Subcarriers") {
            LiveObservationView(telemetry: model.telemetry) { _ in
                metricsGrid([
                    ("PILOT", String(format: "%5.1f%%", model.pilotInjectionPercentValue)),
                    ("RDS", String(format: "%5.1f%%", model.rdsInjectionPercentValue)),
                    ("STEREO IMAGE", model.stereoImageText)
                ])
            }
        }
    }

    private func metricsGrid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .font(BroadcastStyle.scaleLabel)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(row.1)
                        .font(BroadcastStyle.valueReadout)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Audio-composite peak in dBFS. Linear-to-dBFS with a -120 dBFS
    /// floor so the readout settles to a fixed string when silent
    /// rather than reading "-inf".
    private var audioCompositeText: String {
        let v = Double(model.audioCompositePeakLinear)
        guard v > 1e-6 else { return "-120.0 dBFS" }
        return String(format: "%6.1f dBFS", 20.0 * log10(v))
    }

    /// Modulation percentage: peak deviation as a fraction of the
    /// configured target. References `mpx_deviation_khz` from config
    /// (not the 75 kHz regulatory line) — operators with custom
    /// deviation targets read 100% at their chosen setpoint.
    private var modulationText: String {
        let peak = Double(model.estimatedDeviationPeakKHz)
        let target = max(1.0, model.config.mpxDeviationKHz)
        return String(format: "%6.1f%%", (peak / target) * 100.0)
    }

    /// Budget margin + state. ON shown in tail when BS.412 is engaged;
    /// otherwise the numeric value alone (so OFF reads "+0.0 dB" with
    /// no implication that BS.412 is active).
    private var budgetText: String {
        let margin = Double(model.compositeBudgetMarginDBValue)
        let state = model.compositeBudgetStateText
        let core = String(format: "%+5.1f dB", margin)
        return state.isEmpty || state == "Off" ? core : "\(core) · \(state)"
    }

    private func grText(_ valueDB: Float) -> String {
        // 5-char numeric field (covers " 0.0".."16.0", and "-NN.N") so the GR
        // readout stays a constant width as gain reduction varies.
        let db = Double(valueDB)
        return String(format: "%5.1f dB", db < 0.05 ? 0.0 : db)
    }

    // MARK: - Panel A: Transport + Devices

    private var transportPanel: some View {
        Card(title: "Transport") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        model.startOrStopTransport()
                    } label: {
                        HStack {
                            // Decorative — the adjacent "Start" / "Stop"
                            // text conveys the action to VoiceOver.
                            Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                                .accessibilityHidden(true)
                            Text(model.isRunning ? "Stop" : "Start")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .keyboardShortcut(.return, modifiers: [.command])

                    Button {
                        model.toggleBypass()
                    } label: {
                        HStack {
                            // Decorative — the adjacent "Bypass On / Off"
                            // text conveys the action to VoiceOver.
                            Image(systemName: model.processingBypass ? "bolt.slash.fill" : "bolt.fill")
                                .accessibilityHidden(true)
                            Text(model.processingBypass ? "Bypass On" : "Bypass Off")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                    .keyboardShortcut("b", modifiers: [.command])
                }

                FlowStatusRow(items: [
                    ("Source", inputName, model.isRunning ? .green : .secondary.opacity(0.75)),
                    ("Output", outputName, model.isRunning ? .green : .secondary.opacity(0.75)),
                    ("Monitor", monitorChipText, model.monitorEnabled ? .green : .secondary.opacity(0.75))
                ])

                // Input levels — visible here so the operator can
                // adjust source gain without leaving the dashboard.
                // Same data the BroadcastStatusBar shows numerically,
                // but rendered as proper L/R meter bars with peak hold.
                inputLevelsTile

                HStack(alignment: .top, spacing: 12) {
                    streamTile
                    bufferTile
                    dropoutsTile
                }
            }
        }
    }

    private var inputLevelsTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input")
                    .font(BroadcastStyle.chipLabel)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("Adjust source level so peaks sit between -6 and -3 dBFS")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            LiveObservationView(telemetry: model.telemetry) { t in
                VStack(alignment: .leading, spacing: 6) {
                    MeterRow(
                        label: "L",
                        valueText: t.inputLText.meterCurrentOnly,
                        level: t.inputLLevel,
                        peakLevel: t.inputLPeakHoldLevel,
                        scaleStyle: .dbfs
                    )
                    MeterRow(
                        label: "R",
                        valueText: t.inputRText.meterCurrentOnly,
                        level: t.inputRLevel,
                        peakLevel: t.inputRPeakHoldLevel,
                        scaleStyle: .dbfs
                    )
                }
            }
        }
        .padding(10)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
    }

    private var streamTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stream")
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            LiveObservationView(telemetry: model.telemetry) { _ in
                Text(streamRateText)
                    .font(BroadcastStyle.valueReadout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
    }

    private var bufferTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Buffer")
                    .font(BroadcastStyle.chipLabel)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                LiveObservationView(telemetry: model.telemetry) { _ in
                    Text(delayText)
                        .font(BroadcastStyle.valueReadout)
                        .foregroundStyle(.secondary)
                }
            }
            LiveObservationView(telemetry: model.telemetry) { _ in
                ProgressView(value: bufferFill)
                    .progressViewStyle(.linear)
                    .tint(bufferTint)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
    }

    private var dropoutsTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dropouts (10 s)")
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            LiveObservationView(telemetry: model.telemetry) { t in
                HStack(spacing: 12) {
                    dropoutPill(label: "OVR", count: t.streamHealth.overflowsRecent)
                    dropoutPill(label: "UND", count: t.streamHealth.underflowsRecent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        .help("Cumulative totals: \(model.streamHealth.overflowsTotal) overflows / \(model.streamHealth.underflowsTotal) underflows since engine start.")
    }

    private func dropoutPill(label: String, count: Int) -> some View {
        let tint: Color = count == 0
            ? BroadcastStyle.safeGreen
            : (count < 3 ? BroadcastStyle.tightAmber : BroadcastStyle.overRed)
        // Distinct symbol per state so the cue is shape + colour, not colour
        // alone (WCAG 2.1 / Differentiate-Without-Color).
        let symbol = count == 0
            ? "checkmark.circle.fill"
            : (count < 3 ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
        let state = count == 0 ? "ok" : (count < 3 ? "warning" : "error")
        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(label)
                .font(BroadcastStyle.scaleLabel)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(BroadcastStyle.valueReadout)
        }
        // Symbol + colour carry the state visually; mirror it in words for
        // VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(count), \(state)")
    }

    // MARK: - Panel B: DSP chain (3-pill context strip + 13-stage grid)

    private var chainPanel: some View {
        Card(title: "Signal Chain") {
            VStack(alignment: .leading, spacing: 12) {
                LiveObservationView(telemetry: model.telemetry) { _ in
                    FlowStatusRow(items: [
                        ("AGC", agcPillText, agcDotColor),
                        ("Stereo", stereoPillText, .secondary.opacity(0.75)),
                        ("Pre-Lim GR", preLimText, preLimDotColor)
                    ])
                }

                ProcessingOverviewGrid(model: model, embedded: true)
            }
        }
    }

    // MARK: - Panel C: RDS

    private var rdsPanel: some View {
        Card(title: "RDS") {
            LiveObservationView(telemetry: model.telemetry) { _ in
              VStack(alignment: .leading, spacing: 10) {
                FlowStatusRow(items: [
                    ("PS", model.rdsPS.ifEmpty("—"), .secondary.opacity(0.75)),
                    ("PI", model.rdsPI.ifEmpty("—"), .secondary.opacity(0.75)),
                    ("PTY", model.rdsPTY.ifEmpty("—"), .secondary.opacity(0.75))
                ])

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(rdsRowsFiltered, id: \.0) { row in
                        GridRow {
                            Text(row.0)
                                .font(BroadcastStyle.scaleLabel)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(row.1)
                                .font(BroadcastStyle.valueReadout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
              }
            }
        }
    }

    // MARK: - Computed values

    private var inputName: String {
        guard !model.selectedInputUID.isEmpty else { return "—" }
        return model.inputDevices.first(where: { $0.uid == model.selectedInputUID })?.name ?? "—"
    }

    private var outputName: String {
        guard !model.selectedOutputUID.isEmpty else { return "—" }
        return model.outputDevices.first(where: { $0.uid == model.selectedOutputUID })?.name ?? "—"
    }

    private var monitorName: String {
        guard model.monitorEnabled, !model.selectedMonitorUID.isEmpty else { return "—" }
        return model.outputDevices.first(where: { $0.uid == model.selectedMonitorUID })?.name ?? "—"
    }

    private var monitorChipText: String {
        if !model.monitorEnabled { return "Off" }
        return monitorName
    }

    private var streamRateText: String {
        let h = model.streamHealth
        if h.inputHz > 0, h.renderHz > 0, h.inputHz != h.renderHz {
            return "\(h.inputHz) → \(h.renderHz) Hz · block \(h.blockFrames)"
        }
        let effective = max(h.renderHz, h.inputHz)
        if effective > 0 {
            return "\(effective) Hz · block \(h.blockFrames)"
        }
        return "—"
    }

    private var bufferFill: Double {
        // Display the low-passed buffer fill (~10 s time constant) so
        // the bar shows trend rather than tick-by-tick wobble. The
        // underlying `streamHealth.ringFill` and `inputBufferValue`
        // still update at full rate for any caller that needs the
        // instantaneous reading; a real underflow surfaces in the
        // `Dropouts` tile within one tick.
        max(0.0, min(1.0, model.bufferFillSmoothed))
    }

    private var bufferTint: Color {
        guard model.streamHealth.isRunning else { return .secondary }
        switch model.streamHealth.bufferHealth {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }

    private var delayText: String {
        guard let delayMS = model.streamHealth.estimatedDelayMS else { return "—" }
        if delayMS >= 100.0 { return String(format: "%.0f ms", delayMS) }
        if delayMS >= 10.0 { return String(format: "%.1f ms", delayMS) }
        return String(format: "%.2f ms", delayMS)
    }

    private var agcPillText: String {
        // Detector + gain on one line, parsed from the existing
        // `agcDetailText` ("Detector X dB • Gain Y dB").
        let detector = parseDetail(model.agcDetailText, key: "Detector") ?? "—"
        let gain = parseDetail(model.agcDetailText, key: "Gain") ?? "—"
        return "\(detector) → \(gain)"
    }

    private var agcDotColor: Color {
        switch model.agcStateText.lowercased() {
        case "off": return .secondary.opacity(0.75)
        case "gate": return .orange
        default: return .green
        }
    }

    private var stereoPillText: String {
        // "Corr +X.XX • Side Y.YYx" from stereoImageText.
        let corr = parseDetail(model.stereoImageText, key: "Corr") ?? "—"
        let side = parseDetail(model.stereoImageText, key: "Side") ?? "—"
        return "\(corr) · \(side)"
    }

    private var preLimText: String {
        String(format: "%5.1f dB", Double(model.preEncodeLimiterGainReductionDBValue))
    }

    private var preLimDotColor: Color {
        let gr = Double(model.preEncodeLimiterGainReductionDBValue)
        if gr < 0.5 { return .green }
        if gr < 3.0 { return .orange }
        return .red
    }

    /// Drop empty / placeholder RDS rows so the table doesn't render
    /// "PTYN: —" or "Long PS: —" lines that just clutter the panel.
    private var rdsRowsFiltered: [(String, String)] {
        model.rdsRows.filter { _, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "—"
        }
    }

    /// Pull a single value out of a "Key1 V1 • Key2 V2" detail string.
    private func parseDetail(_ text: String, key: String) -> String? {
        let parts = text.split(separator: "•")
        for p in parts {
            let trimmed = p.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key) {
                return trimmed.replacingOccurrences(of: "\(key) ", with: "")
            }
        }
        return nil
    }
}

struct DashboardMetricGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            content
        }
    }
}

struct FlowStatusRow: View {
    let items: [(title: String, value: String, color: Color)]

    var body: some View {
        ViewThatFits(in: .vertical) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    DSPStatusPill(title: item.title, value: item.value, color: item.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    DSPStatusPill(title: item.title, value: item.value, color: item.color)
                }
            }
        }
    }
}

struct DSPStatusPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            BroadcastStyle.ledHalo(for: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(BroadcastStyle.chipLabel)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(BroadcastStyle.chipValue)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BroadcastStyle.meterSurface.opacity(0.70))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
        // Read as one item ("AGC, On") instead of LED + two text fragments.
        // The value text already states the status word, so it is not
        // color-only; this only fixes the fragmentation.
        .accessibilityElement(children: .combine)
    }
}

struct DSPMetricGroupCard: View {
    let title: String
    let subtitle: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        Text(rows[i].0)
                            .font(BroadcastStyle.scaleLabel)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(rows[i].1)
                            .font(BroadcastStyle.valueReadout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BroadcastStyle.meterSurface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
    }
}

struct DSPStateIndicator: View {
    let title: String
    let dotColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("\(title):")
                .foregroundStyle(.secondary)
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
    }
}

struct RuntimeCardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Runtime") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("State") {
                    Text(model.isRunning ? "Running" : "Not running")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Source") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.sourceMode },
                            set: {
                                model.sourceMode = $0
                                model.persistBasicConfig()
                            }
                        )
                    ) {
                        Text("input").tag("input")
                        Text("tone").tag("tone")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                LabeledContent("Input") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.selectedInputUID },
                            set: {
                                model.selectedInputUID = $0
                                model.persistBasicConfig()
                            }
                        )
                    ) {
                        ForEach(model.inputDevices, id: \.uid) { d in
                            Text(d.name).tag(d.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                LabeledContent("Output") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.selectedOutputUID },
                            set: {
                                model.selectedOutputUID = $0
                                model.persistBasicConfig()
                            }
                        )
                    ) {
                        ForEach(model.outputDevices, id: \.uid) { d in
                            Text(d.name).tag(d.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Toggle(
                    "Enable Monitor Output",
                    isOn: Binding(
                        get: { model.monitorEnabled },
                        set: {
                            model.monitorEnabled = $0
                            model.persistBasicConfig()
                        }
                    ))

                if model.monitorEnabled {
                    LabeledContent("Monitor Output Device (Decoded MPX Simulation)") {
                        Picker(
                            "",
                            selection: Binding(
                                get: { model.selectedMonitorUID },
                                set: {
                                    model.selectedMonitorUID = $0
                                    model.persistBasicConfig()
                                }
                            )
                        ) {
                            ForEach(model.outputDevices, id: \.uid) { d in
                                Text(d.name).tag(d.uid)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityLabel("Monitor output device decoded MPX simulation")
                    }
                }

                Divider()
                LiveObservationView(telemetry: model.telemetry) { _ in
                    Text(model.runtimeText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LiveObservationView(telemetry: model.telemetry) { _ in
                    ProgressView(value: model.inputBufferValue, total: max(1.0, model.inputBufferMax))
                        .tint(
                            model.inputBufferValue >= model.inputBufferCritical
                                ? .red
                                : (model.inputBufferValue >= model.inputBufferWarning
                                    ? .yellow : .green))
                }
                LiveObservationView(telemetry: model.telemetry) { _ in
                    Text(model.inputRingText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.regular)
        }
    }
}

/// Terminal-style monospaced plate showing what's actually going out on
/// the air right now — PS window, Radiotext, PTYN, Long PS, plus the PI
/// / PTY / AID chips. Reads from `model.rdsRows`, which is sourced from
/// the running coder's live snapshot via `updateRDSFields`.
struct RDSLivePreviewPlate: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.rdsRows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0.uppercased())
                        .font(BroadcastStyle.chipLabel)
                        .foregroundStyle(.secondary)
                        .frame(width: 68, alignment: .leading)
                    Text(row.1)
                        .font(BroadcastStyle.valueReadout)
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(BroadcastStyle.panelSurface.opacity(0.70))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
    }
}

struct LevelsCardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Levels", style: .meter) {
            LiveObservationView(telemetry: model.telemetry) { _ in
              HStack(alignment: .center, spacing: 12) {
                VerticalMeterStrip(
                    label: "IN L",
                    valueText: model.inputLText.meterCurrentOnly,
                    level: model.inputLLevel,
                    peakLevel: model.inputLPeakHoldLevel,
                    scale: .dbfs
                )
                VerticalMeterStrip(
                    label: "IN R",
                    valueText: model.inputRText.meterCurrentOnly,
                    level: model.inputRLevel,
                    peakLevel: model.inputRPeakHoldLevel,
                    scale: .dbfs
                )
                VerticalMeterStrip(
                    label: "AGC L",
                    valueText: model.agcOutputLText.meterCurrentOnly,
                    level: model.agcOutputLLevel,
                    peakLevel: model.agcOutputLPeakHoldLevel,
                    scale: .dbfs
                )
                VerticalMeterStrip(
                    label: "AGC R",
                    valueText: model.agcOutputRText.meterCurrentOnly,
                    level: model.agcOutputRLevel,
                    peakLevel: model.agcOutputRPeakHoldLevel,
                    scale: .dbfs
                )
                VerticalMeterStrip(
                    label: model.processedAudioOutputActive ? "OUT" : "MPX",
                    valueText: model.outputText.meterCurrentOnly,
                    level: model.outputLevel,
                    peakLevel: model.outputPeakHoldLevel,
                    scale: .dbfs
                )
                // Modulation/deviation is a composite-domain quantity. In
                // processed-audio output there is no FM composite, so the MOD
                // (kHz deviation) meter is meaningless — hide it.
                if !model.processedAudioOutputActive {
                    VerticalMeterStrip(
                        label: "MOD",
                        valueText: model.modulationText,
                        level: model.modulationLevel,
                        peakLevel: model.modulationPeakHoldLevel,
                        scale: .modulationKHz(fullScale: 100, limit: model.config.mpxDeviationKHz)
                    )
                }
                // GR + SAFE removed in 0.30 — peak-control gain-reduction
                // data is already surfaced by the Monitoring tab's Headroom
                // card (PRE-ENCODE / COMPOSITE / SAFETY GR + BS.412 budget)
                // and per-stage in the Signal Chain strip. The detached
                // Levels window is now purely VU-style level metering.
                Spacer(minLength: 0)
              }
              .frame(height: 340)
              // Group the strips under one named VoiceOver container so the
              // cluster is announced as a unit ("Level meters, …") and the
              // user can navigate into the individual strips for readings,
              // instead of landing on disconnected strips with no context.
              .accessibilityElement(children: .contain)
              .accessibilityLabel(
                model.processedAudioOutputActive
                    ? "Level meters: input L and R, AGC output L and R, output"
                    : "Level meters: input L and R, AGC output L and R, MPX output, modulation")
            }
        }
    }
}

struct MeterRow: View {
    enum ScaleStyle: Equatable {
        case dbfs
        case modulation100kHz(limitKHz: Double)
        case none
    }

    let label: String
    let valueText: String
    let level: Double
    let peakLevel: Double?
    let scaleStyle: ScaleStyle

    init(
        label: String, valueText: String, level: Double, peakLevel: Double? = nil,
        showsDBScale: Bool = false,
        scaleStyle: ScaleStyle? = nil
    ) {
        self.label = label
        self.valueText = valueText
        self.level = level
        self.peakLevel = peakLevel
        if let scaleStyle {
            self.scaleStyle = scaleStyle
        } else {
            self.scaleStyle = showsDBScale ? .dbfs : .none
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    // Fixed footprint so a per-tick value change (e.g.
                    // "-6.2 dB" -> "-12.4 dB") repaints in place instead of
                    // resizing and re-solving the enclosing stack layout.
                    .frame(width: 68, alignment: .trailing)
            }
            MeterBar(level: level, peakLevel: peakLevel, scaleStyle: scaleStyle)
        }
        .font(.callout)
        // Collapse the label / readout / bar into one VoiceOver element so it
        // announces "<name>, <value>" rather than two stray text fragments
        // with a meaningless bar in between.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
    }
}

struct MeterBar: View {
    let level: Double
    let peakLevel: Double?
    let scaleStyle: MeterRow.ScaleStyle

    private struct ScaleTick: Identifiable {
        let position: Double
        let label: String

        var id: String { "\(label)-\(position)" }
    }

    private static func dbfsScalePosition(_ db: Double) -> Double {
        let floorDB = -36.0
        let clampedDB = min(0.0, max(floorDB, db))
        let norm = max(0.0, min(1.0, (clampedDB - floorDB) / -floorDB))
        return norm
    }

    private var scaleTicks: [ScaleTick] {
        switch scaleStyle {
        case .dbfs:
            return [
                ScaleTick(position: Self.dbfsScalePosition(-36.0), label: "-36"),
                ScaleTick(position: Self.dbfsScalePosition(-24.0), label: "-24"),
                ScaleTick(position: Self.dbfsScalePosition(-12.0), label: "-12"),
                ScaleTick(position: Self.dbfsScalePosition(-6.0), label: "-6"),
                ScaleTick(position: Self.dbfsScalePosition(-3.0), label: "-3"),
                ScaleTick(position: Self.dbfsScalePosition(0.0), label: "0 dBFS")
            ]
        case .modulation100kHz:
            return [
                ScaleTick(position: 0.0, label: "0"),
                ScaleTick(position: 0.25, label: "25"),
                ScaleTick(position: 0.5, label: "50"),
                ScaleTick(position: 0.75, label: "75"),
                ScaleTick(position: 1.0, label: "100 kHz")
            ]
        case .none:
            return []
        }
    }

    private var meterTint: Color {
        switch scaleStyle {
        case .modulation100kHz(let limitKHz):
            return BroadcastStyle.tint(forLevel: level, limitNorm: limitKHz / 100.0)
        case .dbfs, .none:
            return BroadcastStyle.tint(forLevel: level)
        }
    }

    private var targetLevel: Double? {
        switch scaleStyle {
        case .modulation100kHz(let limitKHz):
            return max(0.0, min(1.0, limitKHz / 100.0))
        case .dbfs, .none:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Drawn in a Canvas, not laid-out subviews: the fill width / peak / target
            // change every frame, and a `.frame(width:)` tracking the level would
            // re-run Auto Layout on every update at the refresh rate (the cause of the
            // long-run GUI stall). A Canvas just repaints.
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let radius: CGFloat = 3
                let track = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                                 cornerRadius: radius, style: .continuous)
                ctx.fill(track, with: .color(Color.secondary.opacity(0.18)))
                for tick in scaleTicks {
                    let x = tick.position * w
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)),
                             with: .color(Color.primary.opacity(0.15)))
                }
                let fw = max(0.0, min(1.0, level)) * w
                if fw > 0.5 {
                    ctx.fill(
                        Path(roundedRect: CGRect(x: 0, y: 0, width: fw, height: h),
                             cornerRadius: radius, style: .continuous),
                        with: .color(meterTint.opacity(0.75)))
                }
                if let target = targetLevel {
                    let x = min(max(0.0, (max(0.0, min(1.0, target)) * w) - 1.0), max(0.0, w - 2.0))
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: h)),
                             with: .color(Color.accentColor.opacity(0.95)))
                }
                if let peak = peakLevel {
                    let x = min(max(0.0, (max(0.0, min(1.0, peak)) * w) - 1.0), max(0.0, w - 2.0))
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: h)),
                             with: .color(Color.primary.opacity(0.98)))
                }
            }
            .frame(height: 14)
            if scaleStyle != .none {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        ForEach(scaleTicks) { tick in
                            Text(tick.label)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .position(
                                    x: min(
                                        max(12.0, tick.position * geo.size.width),
                                        max(12.0, geo.size.width - 24.0)
                                    ),
                                    y: 7.0
                                )
                        }
                    }
                }
                .frame(height: 14)
            }
        }
        .transaction { txn in
            txn.animation = nil
        }
    }
}

struct MonitoringWindowHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bar-style 1/3-octave RTA visualization. Used for the Audio Spectrum
/// window — more representative of how pro broadcast processors
/// (Optimod / Omnia / Stereotool) show audio program spectrum than a
/// line/area FFT plot. Same underlying `dbBins` source as
/// `MPXSpectrumView`; this view just remaps to ISO 1/3-octave bands and
/// renders each as a gradient-filled bar.
struct AudioBarSpectrumView: View {
    let dbBins: [Float]
    let maxHz: Double
    let nyquistHz: Double

    private let dbMin: Float = -100.0
    private let dbMax: Float = 0.0

    /// ISO 1/3-octave center frequencies (Hz). Covers the FM audio
    /// program band; bands above the actual display Nyquist are filtered
    /// out at render time.
    private static let isoCenters: [Double] = [
        31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250,
        315, 400, 500, 630, 800, 1_000, 1_250, 1_600, 2_000, 2_500,
        3_150, 4_000, 5_000, 6_300, 8_000, 10_000, 12_500, 16_000
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: BroadcastStyle.panelInsetCornerRadius),
                    with: .color(.black.opacity(0.30))
                )
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

                // dB grid + border.
                var grid = Path()
                for db in stride(from: -100, through: 0, by: 10) {
                    let y = yPosition(forDB: Float(db), in: plotRect)
                    grid.move(to: CGPoint(x: plotRect.minX, y: y))
                    grid.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.18)), lineWidth: 0.9)
                context.stroke(
                    Path(plotRect),
                    with: .color(.white.opacity(0.40)),
                    lineWidth: 1.0
                )

                // dB axis labels (both sides).
                for db in stride(from: -100, through: 0, by: 10) {
                    let y = yPosition(forDB: Float(db), in: plotRect)
                    let label = db == 0 ? "0 dB" : "\(db) dB"
                    let text = Text(label)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                    context.draw(text, at: CGPoint(x: 18, y: y))
                    context.draw(text, at: CGPoint(x: size.width - 18, y: y))
                }

                // Filter ISO bands by display Nyquist so we don't draw
                // bars whose center is beyond the actual analyzed range.
                // Inclusive comparison: a 16 kHz band at exactly maxHz
                // still shows — the upper half of its 1/3-octave window
                // extends past maxHz but its lower half (14.25-16 kHz)
                // has valid FFT data and the bar reflects that energy.
                let displayMaxHz = max(1_000.0, maxHz)
                let nyquist = nyquistHz > 0 ? min(nyquistHz, displayMaxHz) : displayMaxHz
                let usableCenters = Self.isoCenters.filter { $0 <= nyquist }
                guard !usableCenters.isEmpty, dbBins.count > 1 else { return }

                let barCount = usableCenters.count
                let interBarGap: CGFloat = max(1.0, plotRect.width * 0.004)
                let barWidth = max(
                    2.0,
                    (plotRect.width - interBarGap * CGFloat(barCount - 1)) / CGFloat(barCount)
                )

                // For each ISO band, pull max of FFT bins falling in
                // [center * 2^(-1/6), center * 2^(1/6)] — standard
                // 1/3-octave window.
                let binCount = dbBins.count
                let oneSixthOctave = pow(2.0, 1.0 / 6.0)

                let gradient = Gradient(colors: [
                    Color.red.opacity(0.88),
                    Color.yellow.opacity(0.80),
                    Color.green.opacity(0.74),
                    Color.cyan.opacity(0.62),
                    Color.blue.opacity(0.55)
                ])

                for (i, center) in usableCenters.enumerated() {
                    let lowHz = center / oneSixthOctave
                    let highHz = center * oneSixthOctave
                    let lowBin = max(
                        0,
                        min(binCount - 1, Int((lowHz / displayMaxHz) * Double(binCount - 1)))
                    )
                    let highBin = max(
                        lowBin,
                        min(
                            binCount - 1,
                            Int(ceil((highHz / displayMaxHz) * Double(binCount - 1)))
                        )
                    )
                    var maxDB: Float = -100.0
                    for b in lowBin...highBin where dbBins[b] > maxDB {
                        maxDB = dbBins[b]
                    }
                    // Floor for visual readability — a 1-pixel sliver at
                    // -100 is invisible; cap at -98 so very-quiet bands
                    // still show a faint base.
                    maxDB = max(-98.0, maxDB)

                    let xLeft = plotRect.minX + CGFloat(i) * (barWidth + interBarGap)
                    let yTop = yPosition(forDB: maxDB, in: plotRect)
                    let barRect = CGRect(
                        x: xLeft,
                        y: yTop,
                        width: barWidth,
                        height: max(0, plotRect.maxY - yTop)
                    )
                    context.fill(
                        Path(
                            roundedRect: barRect,
                            cornerRadius: max(1.0, min(3.5, barWidth * 0.18))
                        ),
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: barRect.midX, y: plotRect.minY),
                            endPoint: CGPoint(x: barRect.midX, y: plotRect.maxY)
                        )
                    )
                }

                // Decade labels along the X-axis at 100 Hz, 1 kHz, 10 kHz,
                // plus a 16 kHz marker at the audio-program ceiling.
                let decadeLabels: [(Double, String)] = [
                    (100, "100 Hz"),
                    (1_000, "1 kHz"),
                    (10_000, "10 kHz"),
                    (16_000, "16 kHz")
                ]
                for (decadeHz, label) in decadeLabels where decadeHz <= nyquist {
                    if let idx = usableCenters.firstIndex(where: { abs($0 - decadeHz) < 0.5 }) {
                        let xCenter =
                            plotRect.minX
                            + CGFloat(idx) * (barWidth + interBarGap)
                            + barWidth * 0.5
                        let text = Text(label)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                        context.draw(text, at: CGPoint(x: xCenter, y: plotRect.maxY + 12))
                    }
                }
            }
            .frame(minHeight: 190, idealHeight: 220)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: BroadcastStyle.panelInsetCornerRadius,
                    style: .continuous
                )
            )

            HStack(spacing: 14) {
                Text("RTA: 1/3-octave (ISO) bars, log frequency, max in band")
                Spacer()
                if nyquistHz > 0.0, nyquistHz < maxHz {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: 6, height: 6)
                        Text("Nyquist \(Int((nyquistHz / 1000.0).rounded())) kHz")
                    }
                }
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
        }
        // Discrete updates — no implicit interpolation between frames
        // (matches the line spectrum's transaction modifier; prevents
        // animation queue buildup at 30 Hz refresh).
        .transaction { txn in
            txn.animation = nil
        }
        // Canvas content is invisible to VoiceOver; name the region.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio spectrum, one-third octave RTA")
        .accessibilityAddTraits(.isImage)
    }

    private func yPosition(forDB db: Float, in rect: CGRect) -> CGFloat {
        let clamped = max(dbMin, min(dbMax, db))
        let norm = (clamped - dbMin) / (dbMax - dbMin)
        return rect.minY + (1.0 - CGFloat(norm)) * rect.height
    }
}

struct KeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0)
                        .foregroundStyle(.secondary)
                    Text(rows[i].1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.callout)
    }
}

/// One-paragraph help block shown at the top of each Processing detail
/// tab (everything except the Overview grid). Intentionally muted /
/// secondary styling so it reads as documentation rather than a control;
/// stays out of the way once the operator knows the stage but is there
/// when they need to anchor.
struct TabHelpBox: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Decorative info-icon — the Text alongside it carries the
            // entire content to VoiceOver. Hide the icon from the
            // accessibility tree so screen readers don't announce
            // "info circle" before every tab help block.
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }
}

#endif  // os(macOS)
