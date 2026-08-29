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

/// Test Tone tab — a first-class sidebar stage that drives the
/// engine's tone source. Enable replaces the audio input live; the
/// rest of the chain (AGC, multiband, clippers, encoder, BS.412)
/// processes the tone normally so operators can observe response at
/// calibrated input levels (default -20 dBFS, broadcast line
/// reference). Three signal types — sine for level / separation /
/// encoder-bandwidth tests, pink and white noise for broadband
/// response checks. Stereo modes cover the operator's diagnostic
/// needs (mono / L=-R / L-only / R-only).
///
/// All controls are live-applicable via the existing RuntimeConfig
/// path; no engine restart required when toggling enable, type,
/// mode, frequency, or level.
/// Named-snapshot manager. 8 fixed slots saved to `<configPath>.snapshots.json`
/// alongside the INI. Each slot row: name field + Save (capture current
/// config into this slot, overwrites) + Load (apply this slot's config
/// to the live engine) + Clear (delete this slot). The saved-at
/// timestamp reads "saved <date>" once the slot is occupied.
///
/// Snapshots are heavier than format profiles (full config capture vs
/// per-stage preset bundle) and meant for "Saturday Night vs Morning
/// Show" type setups operators want to flip between without recomposing
/// every stage by hand.
struct SnapshotsView: View {
    @ObservedObject var model: MPXPrimeViewModel

    private var activePresetName: String? {
        guard let id = model.activeSnapshotID else { return nil }
        return model.snapshots.compactMap { $0 }.first { $0.id == id }?.name
    }

    /// Unmissable summary of which preset is live (or that the config is custom).
    @ViewBuilder private var activePresetBanner: some View {
        let modified = model.activeSnapshotModified
        HStack(spacing: 8) {
            if let name = activePresetName {
                Image(systemName: modified ? "pencil.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(modified ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                Text(modified ? "Active preset: \(name)  (edited since loaded)"
                              : "Active preset: \(name)")
                    .fontWeight(.semibold)
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No preset loaded - the live configuration isn't tied to a saved preset.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(activePresetName == nil
                      ? Color.secondary.opacity(0.08)
                      : (modified ? Color.orange : Color.accentColor).opacity(0.12))
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Presets") {
                    VStack(alignment: .leading, spacing: 10) {
                        activePresetBanner
                        ForEach(0..<MPXPrimeViewModel.snapshotSlotCount, id: \.self) { slot in
                            SnapshotSlotRow(model: model, slot: slot)
                            if slot < MPXPrimeViewModel.snapshotSlotCount - 1 {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }

                TabHelpBox(text: "Eight named presets capturing the full configuration. Save the current setup into a slot, load it back later — survives app restart. Heavier than Format Profiles: a preset captures every per-stage setting and RDS field, not just the DSP bundle.")
            }
            .padding(20)
            .frame(maxWidth: 1120, alignment: .topLeading)
        }
    }
}

struct SnapshotSlotRow: View {
    @ObservedObject var model: MPXPrimeViewModel
    let slot: Int
    @State private var draftName: String = ""
    @State private var confirmingClear = false
    @FocusState private var nameFieldFocused: Bool

    private var snapshot: ConfigSnapshot? { model.snapshots[slot] }

    /// This slot holds the snapshot whose config is currently live.
    private var isActive: Bool { snapshot != nil && snapshot?.id == model.activeSnapshotID }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(slot + 1).")
                .font(.system(.callout, design: .monospaced))
                .fontWeight(isActive ? .bold : .regular)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Preset \(slot + 1)", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
                    .focused($nameFieldFocused)
                    // Enter commits (creates an empty slot or renames a saved
                    // one); losing focus commits a rename so a typed name is
                    // never silently lost.
                    .onSubmit { commitName(allowCreate: true) }
                    .onChange(of: nameFieldFocused) { _, focused in
                        if !focused { commitName(allowCreate: false) }
                    }

                HStack(spacing: 6) {
                    if isActive {
                        Label(
                            model.activeSnapshotModified ? "Loaded - edited" : "Loaded",
                            systemImage: model.activeSnapshotModified
                                ? "pencil.circle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(model.activeSnapshotModified ? Color.orange : Color.accentColor)
                    }
                    if let snap = snapshot {
                        Text("saved \(Self.relativeDateString(snap.savedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("empty")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button("Save") {
                    // Capture the current full config into this slot under the
                    // field's name (saveSnapshot trims + defaults when empty).
                    // Do NOT clear draftName -- the name stays visible, and the
                    // onChange(of: snapshot?.name) sync keeps the field correct.
                    model.saveSnapshot(slot: slot, name: draftName)
                }
                .help("Capture the current full configuration into this slot. Overwrites any existing preset here.")

                Button("Import...") {
                    importPreset()
                }
                .help("Load a preset from an MPX Prime Studio .ini file into this slot (overwrites). Does not apply it -- use Load for that.")

                Button("Load") {
                    model.loadSnapshot(slot: slot)
                }
                .disabled(snapshot == nil)
                .help("Apply this slot's saved configuration to the live engine. Restart-required fields surface a pending-apply prompt.")

                Button("Export...") {
                    exportPreset()
                }
                .disabled(snapshot == nil)
                .help("Save this preset to a file (a standard MPX Prime Studio .ini you can share or load with --config).")

                Button("Clear", role: .destructive) {
                    confirmingClear = true
                }
                .disabled(snapshot == nil)
                .help("Delete this slot. Cannot be undone.")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .onAppear {
            draftName = snapshot?.name ?? ""
        }
        // Keep the field in sync when the slot's stored name changes underneath
        // (loaded from disk, renamed, saved, cleared) -- but never clobber the
        // user's in-progress typing.
        .onChange(of: snapshot?.name) { _, newName in
            if !nameFieldFocused { draftName = newName ?? "" }
        }
        // Deleting a saved slot is irreversible -- confirm first (HIG: confirm
        // destructive actions that can't be undone).
        .confirmationDialog(
            "Clear preset \(slot + 1)?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Preset", role: .destructive) {
                model.clearSnapshot(slot: slot)
                draftName = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(snapshot?.name ?? "Preset \(slot + 1)")\" will be deleted. This cannot be undone.")
        }
    }

    /// Persist the edited name. For a saved slot, rename it (on Enter or focus
    /// loss) when the text actually changed. For an empty slot, only Enter
    /// (`allowCreate`) creates the snapshot -- clicking away must not silently
    /// save a slot the user never asked for.
    /// Prompt for an INI file and import it into this slot.
    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Preset"
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            model.importSnapshot(slot: slot, from: url)
        }
    }

    /// Prompt for a destination and write the preset's config there.
    private func exportPreset() {
        guard snapshot != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.exportFilename(slot: slot)
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .data]
        panel.canCreateDirectories = true
        panel.title = "Export Preset"
        panel.prompt = "Export"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportSnapshot(slot: slot, to: url)
        }
    }

    private func commitName(allowCreate: Bool) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = snapshot {
            if !trimmed.isEmpty, trimmed != existing.name {
                model.renameSnapshot(slot: slot, name: trimmed)
            }
        } else if allowCreate, !trimmed.isEmpty {
            model.saveSnapshot(slot: slot, name: trimmed)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static func relativeDateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

struct TestToneView: View {
    @ObservedObject var model: MPXPrimeViewModel

    private static let frequencyPresets: [Double] = [
        50, 100, 400, 1_000, 5_000, 10_000, 12_000, 15_000
    ]

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { model.config.sourceMode.lowercased() == "tone" },
            set: {
                model.config.sourceMode = $0 ? "tone" : "input"
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    private var typeBinding: Binding<String> {
        Binding(
            get: { model.config.testToneType.lowercased() },
            set: {
                model.config.testToneType = $0
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { model.config.testToneMode.lowercased() },
            set: {
                model.config.testToneMode = $0
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    private var freqBinding: Binding<Double> {
        Binding(
            get: { model.config.testToneFreq },
            set: {
                model.config.testToneFreq = $0
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    private var levelBinding: Binding<Double> {
        Binding(
            get: { model.config.testToneLevelDB },
            set: {
                model.config.testToneLevelDB = $0
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                enableCard
                signalCard
                if typeBinding.wrappedValue == "sine" {
                    frequencyCard
                }
                levelCard
                statusCard

                TabHelpBox(text: "Internal signal generator that replaces the audio input. Sine for level / separation / encoder-bandwidth tests; pink and white noise for broadband response checks. Four stereo modes (mono / L=-R / left-only / right-only) cover common diagnostic needs. The rest of the chain (AGC, multiband, clippers, BS.412, encoder) processes the tone normally so you can observe each stage's response at calibrated input levels.")
            }
            .padding(20)
            .frame(maxWidth: 1120, alignment: .topLeading)
        }
    }

    // MARK: - Cards

    private var enableCard: some View {
        Card(title: "Test Tone Source") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: isEnabled) {
                    Text("Enable Test Tone").font(.body)
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var signalCard: some View {
        Card(title: "Signal") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Type") {
                    Picker("Type", selection: typeBinding) {
                        Text("Sine").tag("sine")
                        Text("Pink").tag("pink")
                        Text("White").tag("white")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }

                LabeledContent("Stereo mode") {
                    Picker("Stereo mode", selection: modeBinding) {
                        Text("Mono").tag("mono")
                        Text("L=-R").tag("stereo")
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)
                }
            }
        }
    }

    private var frequencyCard: some View {
        Card(title: "Frequency") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Frequency (Hz)") {
                    TextField(
                        "Frequency",
                        value: freqBinding,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .labelsHidden()
                }

                HStack(spacing: 8) {
                    Text("Presets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Self.frequencyPresets, id: \.self) { freq in
                        let isActive = abs(freqBinding.wrappedValue - freq) < 0.5
                        Button(presetLabel(for: freq)) {
                            freqBinding.wrappedValue = freq
                        }
                        .buttonStyle(.bordered)
                        // Tint the preset matching the current frequency so the
                        // active selection is visible at a glance.
                        .tint(isActive ? BroadcastStyle.accent : nil)
                    }
                }
            }
        }
    }

    private var levelCard: some View {
        Card(title: "Output Level") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent {
                    Slider(
                        value: levelBinding,
                        in: -60.0 ... 0.0,
                        step: 0.5
                    )
                    .accessibilityLabel("Output level")
                    .accessibilityValue(
                        Text(String(format: "%+0.1f dBFS", model.config.testToneLevelDB)))
                } label: {
                    Text(String(format: "%+0.1f dBFS", model.config.testToneLevelDB))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 96, alignment: .leading)
                }
                Text(
                    "Default -20 dBFS matches broadcast line-level reference. "
                    + "Tone enters the chain pre-AGC, so the input meter on "
                    + "the Monitoring tab will read the configured level "
                    + "(modulo the chain's response to the signal)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        Card(title: "Status") {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Source").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(isEnabled.wrappedValue ? "Tone (active)" : "Input (test tone disabled)")
                            .font(BroadcastStyle.valueReadout)
                            .foregroundStyle(isEnabled.wrappedValue ? BroadcastStyle.safeGreen : .primary)
                    }
                    GridRow {
                        Text("Type").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(typeBinding.wrappedValue.capitalized).font(BroadcastStyle.valueReadout)
                    }
                    GridRow {
                        Text("Mode").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(modeLabel(modeBinding.wrappedValue)).font(BroadcastStyle.valueReadout)
                    }
                    if typeBinding.wrappedValue == "sine" {
                        GridRow {
                            Text("Frequency").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(String(format: "%.1f Hz", model.config.testToneFreq))
                                .font(BroadcastStyle.valueReadout)
                                .monospacedDigit()
                        }
                    }
                    GridRow {
                        Text("Level").font(BroadcastStyle.scaleLabel).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(String(format: "%+0.1f dBFS", model.config.testToneLevelDB))
                            .font(BroadcastStyle.valueReadout)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func presetLabel(for freq: Double) -> String {
        if freq >= 1_000 {
            let kHz = freq / 1_000.0
            if kHz == kHz.rounded() {
                return "\(Int(kHz))k"
            } else {
                return String(format: "%.1fk", kHz)
            }
        }
        return "\(Int(freq))"
    }

    private func modeLabel(_ mode: String) -> String {
        switch mode {
        case "stereo": return "Stereo (L=-R)"
        case "left":   return "Left only"
        case "right":  return "Right only"
        default:       return "Mono"
        }
    }
}

#endif  // os(macOS)
