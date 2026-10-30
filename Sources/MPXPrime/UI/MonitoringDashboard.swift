// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI

/// On Air > Monitoring: what is on air, read-only. The page's title,
/// subtitle, padding and help box come from `StageContentView`. Transport
/// and bypass live in the toolbar, the Control menu and the status bar;
/// stage settings live on the Sound pages. Cards, top to bottom: Levels
/// (the same ladder meters as the Levels window), Output (titled with the
/// operating mode), Headroom, Subcarriers (MPX Output), Signal Chain
/// (read-only), Stream Health and, in MPX Output, RDS On Air.
struct MonitoringDashboardView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PageLayout.cardSpacing) {
            LevelsCardView(model: model)
            metricsPanels
            chainPanel
            streamPanel
            // No RDS in processed-audio output (no subcarrier carries it).
            if ChainFeature.rds.applies(in: model.config.operatingMode) {
                rdsPanel
            }
        }
    }

    // MARK: - Output, Headroom, Subcarriers

    /// Side by side when the window is wide, stacked when it is not.
    private var metricsPanels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                outputPanel.frame(maxWidth: .infinity)
                headroomPanel.frame(maxWidth: .infinity)
                if hasSubcarriers {
                    subcarriersPanel.frame(maxWidth: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                outputPanel
                headroomPanel
                if hasSubcarriers {
                    subcarriersPanel
                }
            }
        }
    }

    /// Pilot and RDS exist only where a composite is generated.
    private var hasSubcarriers: Bool { ChainFeature.stereoCoder.applies(in: model.config.operatingMode) }

    private var outputPanel: some View {
        // Titled with the operating mode as the Audio I/O picker spells it.
        Card(title: model.config.operatingMode.title, style: .meter) {
            LiveObservationView(telemetry: model.telemetry) { _ in
                if model.processedAudioOutputActive {
                    metricsGrid([
                        ("Output", model.outputText.ifEmpty("-")),
                        ("Stereo Image", Self.plainDetail(model.stereoImageText))
                    ])
                } else {
                    metricsGrid([
                        ("Output", model.outputText.ifEmpty("-")),
                        ("Audio Composite", audioCompositeText),
                        ("Deviation", String(format: "%5.1f kHz", model.estimatedDeviationPeakKHz)),
                        ("Modulation", modulationText),
                        ("Stereo Image", Self.plainDetail(model.stereoImageText))
                    ])
                }
            }
        }
    }

    private var headroomPanel: some View {
        // Which rows exist in which mode is `HeadroomReadout`'s table, shared
        // with the tests; this view only knows how to render each row.
        Card(title: "Headroom", style: .meter) {
            LiveObservationView(telemetry: model.telemetry) { _ in
                metricsGrid(HeadroomReadout.visible(in: model.config.operatingMode).map(headroomRow))
            }
        }
    }

    /// Row label for each headroom readout, named after the stage it reads
    /// (the `Stage` name table) or the quantity it measures.
    static func headroomLabel(_ readout: HeadroomReadout) -> String {
        switch readout {
        case .preEncodeGR: return "\(Stage.processingLimiter.label) GR"
        case .compositeGR: return "\(Stage.processingCompositeClipper.label) GR"
        case .safetyGR: return "Safety Limiter GR"
        case .safetyClip: return "Safety Clip"
        // NOT a BS.412 quantity: the peak headroom left between the audio
        // composite plus the pilot / RDS reservation and full scale
        // (`MPXGenerator.makeCompositeCalibration`, -20 log10(audio peak +
        // reserved)). BS.412 multiplex power is the next row.
        case .compositeBudget: return "Composite Budget"
        case .mpxPower: return "Multiplex Power"
        case .bs412GR: return "\(Stage.processingBS412.label) GR"
        case .badInput: return "Bad Input"
        }
    }

    private func headroomRow(_ readout: HeadroomReadout) -> (String, String) {
        let value: String
        switch readout {
        case .preEncodeGR: value = grText(model.preEncodeLimiterGainReductionDBValue)
        case .compositeGR: value = grText(model.compositeClipperGainReductionDBValue)
        case .safetyGR: value = grText(model.safetyLimiterGainReductionDBValue)
        case .safetyClip: value = grText(model.safetyClipDBValue)
        case .compositeBudget: value = budgetText
        case .mpxPower: value = mpxPowerText
        case .bs412GR: value = grText(model.bs412StatusValue.gainReductionDB)
        case .badInput: value = badInputText
        }
        return (Self.headroomLabel(readout), value)
    }

    private var subcarriersPanel: some View {
        Card(title: "Subcarriers", style: .meter) {
            LiveObservationView(telemetry: model.telemetry) { _ in
                metricsGrid([
                    ("Pilot", Self.subcarrierText(
                        percent: Double(model.pilotInjectionPercentValue),
                        deviationKHz: model.config.mpxDeviationKHz)),
                    ("RDS", Self.subcarrierText(
                        percent: Double(model.rdsInjectionPercentValue),
                        deviationKHz: model.config.mpxDeviationKHz))
                ])
            }
        }
    }

    /// A subcarrier injection in kHz with its share of the deviation
    /// second: "6.8 kHz (9.0%)". The engine reports the injection as a
    /// percentage of the composite, which the generator scales to the
    /// configured deviation (AGENTS.md "Deviation readout scale"), so the
    /// deviation it takes is that share of `mpx_deviation_khz`.
    static func subcarrierText(percent: Double, deviationKHz: Double) -> String {
        let p = max(0.0, percent)
        return String(format: "%.1f kHz (%.1f%%)", p / 100.0 * max(0.0, deviationKHz), p)
    }

    private func metricsGrid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    // Title Case source strings, drawn as small caps.
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

    /// Audio-composite peak in dBFS, with a -120 dBFS floor so the readout
    /// settles to a fixed string when silent rather than reading "-inf".
    private var audioCompositeText: String {
        let v = Double(model.audioCompositePeakLinear)
        guard v > 1e-6 else { return "-120.0 dBFS" }
        return String(format: "%6.1f dBFS", 20.0 * log10(v))
    }

    /// Peak deviation as a share of the configured deviation, so an operator
    /// with a custom target reads 100% at their chosen setpoint.
    private var modulationText: String {
        let peak = Double(model.estimatedDeviationPeakKHz)
        let target = max(1.0, model.config.mpxDeviationKHz)
        return String(format: "%6.1f%%", (peak / target) * 100.0)
    }

    /// Composite budget margin plus its state (Safe / Tight / Risk) while
    /// the engine runs; the number alone when stopped.
    private var budgetText: String {
        Self.budgetText(marginDB: Double(model.compositeBudgetMarginDBValue),
                        state: model.compositeBudgetStateText)
    }

    static func budgetText(marginDB: Double, state: String) -> String {
        let core = String(format: "%+5.1f dB", marginDB)
        return state.isEmpty || state == "Off" ? core : "\(core) - \(state)"
    }

    /// ITU-R BS.412 multiplex power. Never a bare number before a full 60 s
    /// window exists, and never a compliance reading while Test Tone
    /// suspends control.
    private var mpxPowerText: String {
        let status = model.bs412StatusValue
        if status.controlSuspended { return "Suspended (tone)" }
        if status.unachievable { return "Pilot and RDS over budget" }
        guard status.powerValid else {
            return String(format: "%.0f / 60 s", Double(status.secondsObserved))
        }
        let core = String(format: "%+5.2f dBr", Double(status.powerDBr))
        if status.guardActive { return "\(core) - guard" }
        return status.overCeiling ? "\(core) - over" : core
    }

    /// NaN / Inf arriving from the source. "None" is the normal reading.
    private var badInputText: String {
        let count = model.nonFiniteInputSamplesValue
        return count == 0 ? "None" : String(count)
    }

    private func grText(_ valueDB: Float) -> String {
        // Fixed-width field so the readout does not resize as GR varies.
        let db = Double(valueDB)
        return String(format: "%5.1f dB", db < 0.05 ? 0.0 : db)
    }

    // MARK: - Signal chain (read-only)

    /// The chain as read-only chips (dimmed when the stage is off) and the
    /// levelling engine's live state. Configuring the chain is the Sound
    /// Overview's job; this card only shows it.
    private var chainPanel: some View {
        Card(title: "Signal Chain", style: .meter) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Chip(text: "IN")
                    ForEach(Stage.signalChain.filter { model.isStageVisible($0) }, id: \.self) { stage in
                        let off = model.isStageEnabled(stage) == false
                        Chip(text: stage.chipLabel ?? stage.label)
                            .opacity(off ? 0.4 : 1.0)
                            .help(stage.label + (off ? " (off)" : ""))
                            .accessibilityLabel(stage.label)
                            .accessibilityValue(off ? "off" : "on")
                    }
                    Chip(text: "OUT")
                }
            }
            LiveObservationView(telemetry: model.telemetry) { _ in
                FlowStatusRow(items: [
                    // Advanced Dynamics REPLACES the AGC, so the pill switches
                    // identity rather than showing a bypassed AGC.
                    model.advancedDynamicsActive
                        ? (Stage.processingAdvancedDynamics.label, levellingText(model.advancedDynamicsDetailText,
                                                                               "Density", "Gain"), .green)
                        : (Stage.processingAGC.label, levellingText(model.agcDetailText, "Detector", "Gain"),
                           agcDotColor)
                ])
            }
        }
    }

    private func levellingText(_ detail: String, _ first: String, _ second: String) -> String {
        let a = Self.parseDetail(detail, key: first) ?? "-"
        let b = Self.parseDetail(detail, key: second) ?? "-"
        return "\(first) \(a), \(second.lowercased()) \(b)"
    }

    private var agcDotColor: Color {
        switch model.agcStateText.lowercased() {
        case "off": return .secondary.opacity(0.75)
        case "gate": return .orange
        default: return .green
        }
    }

    // MARK: - Stream health

    private var streamPanel: some View {
        Card(title: "Stream Health", style: .meter) {
            FlowStatusRow(items: [
                ("Source", inputName, model.isRunning ? .green : .secondary.opacity(0.75)),
                ("Output", outputName, model.isRunning ? .green : .secondary.opacity(0.75)),
                ("Monitor", monitorChipText, model.monitorEnabled ? .green : .secondary.opacity(0.75))
            ])
            HStack(alignment: .top, spacing: 12) {
                InsetTile {
                    tileTitle("Stream")
                    LiveObservationView(telemetry: model.telemetry) { t in
                        Text(Self.rateText(inputHz: t.streamSummary.inputHz, renderHz: t.streamSummary.renderHz,
                                           blockFrames: t.streamSummary.blockFrames))
                            .font(BroadcastStyle.valueReadout)
                            .lineLimit(1)
                    }
                }
                InsetTile {
                    HStack {
                        tileTitle("Buffer")
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
                InsetTile {
                    tileTitle("Dropouts (10 s)")
                    LiveObservationView(telemetry: model.telemetry) { t in
                        HStack(spacing: 12) {
                            dropoutPill(label: "Over", count: t.streamHealth.overflowsRecent)
                            dropoutPill(label: "Under", count: t.streamHealth.underflowsRecent)
                        }
                    }
                }
                .help("Totals since engine start: \(model.streamSummary.overflowsTotal) overflows, \(model.streamSummary.underflowsTotal) underflows.")
            }
        }
    }

    private func tileTitle(_ text: String) -> some View {
        Text(text)
            .font(BroadcastStyle.chipLabel)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// "48 -> 192 kHz, block 512" while the input is resampled, else
    /// "192 kHz, block 512"; "-" when stopped. Rates in kHz, as the status bar.
    static func rateText(inputHz: Int, renderHz: Int, blockFrames: Int) -> String {
        func kHz(_ hz: Int) -> String {
            hz % 1_000 == 0 ? "\(hz / 1_000)" : String(format: "%.1f", Double(hz) / 1_000.0)
        }
        if inputHz > 0, renderHz > 0, inputHz != renderHz {
            return "\(kHz(inputHz)) -> \(kHz(renderHz)) kHz, block \(blockFrames)"
        }
        let effective = max(renderHz, inputHz)
        return effective > 0 ? "\(kHz(effective)) kHz, block \(blockFrames)" : "-"
    }

    private func dropoutPill(label: String, count: Int) -> some View {
        let tint: Color = count == 0
            ? BroadcastStyle.safeGreen
            : (count < 3 ? BroadcastStyle.tightAmber : BroadcastStyle.overRed)
        // Distinct symbol per state so the cue is shape + colour, not colour
        // alone.
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(count), \(state)")
    }

    // MARK: - RDS on air

    private var rdsPanel: some View {
        Card(title: "RDS On Air", style: .meter) {
            LiveObservationView(telemetry: model.telemetry) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    FlowStatusRow(items: [
                        ("PS", model.rdsPS.ifEmpty("-"), .secondary.opacity(0.75)),
                        ("PI", model.rdsPI.ifEmpty("-"), .secondary.opacity(0.75)),
                        ("PTY", model.rdsPTY.ifEmpty("-"), .secondary.opacity(0.75))
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
        guard !model.selectedInputUID.isEmpty else { return "-" }
        return model.inputDevices.first(where: { $0.uid == model.selectedInputUID })?.name ?? "-"
    }

    private var outputName: String {
        guard !model.selectedOutputUID.isEmpty else { return "-" }
        return model.outputDevices.first(where: { $0.uid == model.selectedOutputUID })?.name ?? "-"
    }

    private var monitorChipText: String {
        guard model.monitorEnabled else { return "Off" }
        guard !model.selectedMonitorUID.isEmpty else { return "-" }
        return model.outputDevices.first(where: { $0.uid == model.selectedMonitorUID })?.name ?? "-"
    }

    /// The low-passed buffer fill (~10 s), so the bar shows the trend; a
    /// real underflow shows in the Dropouts tile within one tick.
    private var bufferFill: Double {
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
        guard let delayMS = model.streamHealth.estimatedDelayMS else { return "-" }
        if delayMS >= 100.0 { return String(format: "%.0f ms", delayMS) }
        if delayMS >= 10.0 { return String(format: "%.1f ms", delayMS) }
        return String(format: "%.2f ms", delayMS)
    }

    /// Drop empty / placeholder RDS rows so the table does not render
    /// "PTYN: -" lines.
    private var rdsRowsFiltered: [(String, String)] {
        model.rdsRows.filter { _, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "-" && trimmed != "\u{2014}"
        }
    }

    /// Detail strings from the view model separate their fields with a
    /// bullet or a vertical bar ("Detector -12.0 dB | Gain 3.0 dB").
    private static let detailSeparators = CharacterSet(charactersIn: "\u{2022}|")

    /// Pull a single value out of a "Key1 V1 | Key2 V2" detail string.
    static func parseDetail(_ text: String, key: String) -> String? {
        for part in text.components(separatedBy: detailSeparators) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key + " ") {
                return String(trimmed.dropFirst(key.count + 1))
            }
        }
        return nil
    }

    /// A detail string with its separators as plain commas, for display.
    static func plainDetail(_ text: String) -> String {
        text.components(separatedBy: detailSeparators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// Monospaced plate showing what is going out on air right now: PS
/// window, Radiotext, PTYN, Long PS. Reads from `model.rdsRows`, which is sourced from
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

/// Prime Mixer ladder meters for what the operator sets levels by: the
/// input (before or after Input Gain, the same switch as the Audio I/O Input
/// card) and the output -- a stereo pair for the processed feed (FM / HD / AM
/// Output), one bar for the composite plus the deviation ladder in MPX
/// Output. One meter family (`LadderMeterView`, -60 to 0 dBFS) on the
/// Monitoring page, in the Levels window and on Audio I/O.
struct LevelsCardView: View {
    @ObservedObject var model: MPXPrimeViewModel
    /// The card title; the Levels window passes "" because its own header
    /// already says Levels.
    var title: String = "Levels"
    /// The Pre / Post switch inside the card; the Levels window puts it in
    /// its header instead, where every monitoring window keeps its source.
    var showsSourcePicker: Bool = true
    @AppStorage(LevelsCardView.inputPostGainKey) private var inputPostGain = true

    static let inputPostGainKey = "audioIO.inputMetersPostGain"
    private static let meterHeight: CGFloat = 300

    var body: some View {
        Card(title: title, style: .meter) {
            VStack(alignment: .leading, spacing: 10) {
                if showsSourcePicker {
                    InputSourcePicker()
                }
                LiveObservationView(telemetry: model.telemetry) { t in
                    HStack(alignment: .top, spacing: 18) {
                        group(
                            "Input",
                            inputPostGain ? [t.inputPostLeft, t.inputPostRight] : [t.inputPreLeft, t.inputPreRight],
                            labels: ["L", "R"], scale: .dbfs)
                        if model.processedAudioOutputActive {
                            group(model.config.operatingMode.title, [t.outputLeft, t.outputRight], labels: ["L", "R"], scale: .dbfs)
                        } else {
                            group(model.config.operatingMode.title, [t.outputLeft], labels: [""], scale: .dbfs)
                            // Deviation is a composite quantity: MPX Output only.
                            group("Deviation", [t.modulation], labels: [""], scale: deviationScale)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.meterHeight + 36, alignment: .top)
                    // One named VoiceOver container; the bars inside carry
                    // their own readings.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(
                        model.processedAudioOutputActive
                            ? "Level meters: input, output left and right"
                            : "Level meters: input, MPX output, deviation")
                }
            }
        }
    }

    private var deviationScale: LadderMeterScale {
        .deviation(fullScaleKHz: 100, limitKHz: max(1, model.config.mpxDeviationKHz))
    }

    /// A ladder with its title and the held peak of its loudest bar beneath.
    /// The readout has a fixed width, so a new value repaints in place.
    private func group(
        _ title: String, _ readings: [LadderMeterReading], labels: [String], scale: LadderMeterScale
    ) -> some View {
        let held = readings.map(\.heldPeakDBFS).max() ?? -.infinity
        return VStack(spacing: 4) {
            LadderMeterView(readings: readings, labels: labels, scale: scale, height: Self.meterHeight)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(LadderMeterView.readout(held, scale: scale))
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76)
        }
    }
}

/// The input meters' source: Pre (as the device delivers it) or Post (after
/// Input Gain). One stored setting shared by every input meter.
struct InputSourcePicker: View {
    @AppStorage(LevelsCardView.inputPostGainKey) private var inputPostGain = true

    var body: some View {
        Picker("Input meters", selection: $inputPostGain) {
            Text("Pre").tag(false)
            Text("Post").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Input meters. Pre: what the input device delivers. Post: after Input Gain, "
            + "the level the processing receives.")
    }
}

/// The one header every monitoring window uses: title and subtitle on the
/// left, the window's controls right-aligned (source first, then options).
struct MonitoringWindowHeader<Controls: View>: View {
    let title: String
    let subtitle: String
    let controls: Controls

    init(title: String, subtitle: String, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.subtitle = subtitle
        self.controls = controls()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                controls
            }
        }
    }
}

extension MonitoringWindowHeader where Controls == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Bar-style 1/3-octave RTA visualization. Used for the Audio Spectrum
/// window -- more representative of how pro broadcast processors
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
                // still shows -- the upper half of its 1/3-octave window
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
                // [center * 2^(-1/6), center * 2^(1/6)] -- standard
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
                    // Floor for visual readability -- a 1-pixel sliver at
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
        // Discrete updates -- no implicit interpolation between frames
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
        InsetTile {
            pill
        }
        // Read as one item ("AGC, On") instead of LED + two text fragments.
        .accessibilityElement(children: .combine)
    }

    private var pill: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif  // os(macOS)
