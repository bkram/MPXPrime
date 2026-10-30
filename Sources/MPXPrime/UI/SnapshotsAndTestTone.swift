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

/// Named-snapshot manager. 8 fixed slots saved to `<configPath>.snapshots.json`
/// alongside the INI. Each slot row: name field, then the actions in task
/// order -- Load (the common one, prominent), Save (capture the current
/// config into this slot, overwrites) and a More menu for Import, Export and
/// Clear. The saved-at timestamp reads "Saved <date>" once the slot is used.
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
        InsetTile(highlighted: activePresetName != nil) {
        HStack(spacing: 8) {
            if let name = activePresetName {
                Image(systemName: modified ? "pencil.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(modified ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                Text(modified ? "Active preset: \(name) (edited since loading)"
                              : "Active preset: \(name)")
                    .fontWeight(.semibold)
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No preset loaded: the live configuration is not tied to a saved preset.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        }
    }

    var body: some View {
        // One card: the page title already says Presets.
        Card {
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

    private var slotNumber: some View {
        Text("\(slot + 1).")
            .font(.system(.callout, design: .monospaced))
            .fontWeight(isActive ? .bold : .regular)
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .frame(width: 22, alignment: .trailing)
    }

    private var nameColumn: some View {
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
                        model.activeSnapshotModified ? "Loaded, Edited" : "Loaded",
                        systemImage: model.activeSnapshotModified
                            ? "pencil.circle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(model.activeSnapshotModified ? Color.orange : Color.accentColor)
                }
                if let snap = snapshot {
                    Text("Saved \(Self.relativeDateString(snap.savedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Empty")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Task order: Load is what an operator does most (the prominent
    /// action), Save next, the file and delete actions in a menu.
    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("Load") {
                model.loadSnapshot(slot: slot)
            }
            .buttonStyle(.borderedProminent)
            .disabled(snapshot == nil)
            .help("Apply this slot's saved settings to the live engine. Devices, level calibration and the operating mode stay as installed. A setting that needs a restart shows Restart to Apply.")

            Button("Save") {
                // Capture the current full config into this slot under the
                // field's name (saveSnapshot trims + defaults when empty).
                // Do NOT clear draftName -- the name stays visible, and the
                // onChange(of: snapshot?.name) sync keeps the field correct.
                model.saveSnapshot(slot: slot, name: draftName)
            }
            .buttonStyle(.bordered)
            .help("Capture the current configuration into this slot. Overwrites any preset here.")

            Menu("More") {
                Button("Import\u{2026}") {
                    importPreset()
                }
                .help("Load a preset from an MPX Prime Studio .ini file into this slot (overwrites). Does not apply it: use Load for that.")
                Button("Export\u{2026}") {
                    exportPreset()
                }
                .disabled(snapshot == nil)
                .help("Save this preset to a file: a standard MPX Prime Studio .ini you can share or load with --config.")
                Divider()
                Button("Clear\u{2026}", role: .destructive) {
                    confirmingClear = true
                }
                .disabled(snapshot == nil)
                .help("Delete this slot. This cannot be undone.")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More actions for preset \(slot + 1)")
        }
        .controlSize(.small)
    }

    // Split into three subviews: one expression for the whole row made the
    // Swift 6.4 type checker give up in release builds (Xcode 27 CLT).
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            slotNumber
            nameColumn
            Spacer()
            actionButtons
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
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

/// Test Tone page: a line-up generator that REPLACES the input and bypasses
/// the processing chain (AGC, EQ, multiband, enhancers, clippers, limiters and
/// Final Drive), so its level arrives at the output unchanged; a sine is
/// pre-compensated for the pre-emphasis curve, so the expected deviation is
/// what a modulation monitor reads. Sine for level, separation and
/// bandwidth tests; pink and white noise for broadband checks. Every control
/// applies live.
struct TestToneView: View {
    @ObservedObject var model: MPXPrimeViewModel

    static let frequencyPresets: [Double] = [
        50, 100, 400, 1_000, 5_000, 10_000, 12_000, 15_000
    ]

    /// The tone replaces the input: source_mode, with the view model's
    /// mirror kept in step by `applyLiveTestToneIfRunning`.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { model.config.sourceMode.lowercased() == "tone" },
            set: {
                model.config.sourceMode = $0 ? "tone" : "input"
                model.applyLiveTestToneIfRunning()
            }
        )
    }

    var body: some View {
        // One card: the page title already says Test Tone.
        Card {
            Toggle("Enable Test Tone", isOn: isEnabled)
                .toggleStyle(.switch)
                .help("Replaces the input with the tone, live. Turn it off to put the programme back.")
            SettingPicker("Type", setting: model.setting(\.testToneType, .live)) {
                Text("Sine").tag("sine")
                Text("Pink Noise").tag("pink")
                Text("White Noise").tag("white")
            }
            .pickerStyle(.segmented)
            SettingPicker("Stereo Mode", setting: model.setting(\.testToneMode, .live),
                          tooltip: "Mono: the same signal on both channels. L=-R: left and right in anti-phase (pure stereo difference). Left or Right: one channel only, for separation checks.") {
                Text("Mono").tag("mono")
                Text("L=-R").tag("stereo")
                Text("Left").tag("left")
                Text("Right").tag("right")
            }
            .pickerStyle(.segmented)
            if model.config.testToneType.lowercased() == "sine" {
                TestToneFrequencyRow(model: model)
            }
            DoubleSliderRow(
                title: "Tone Level",
                setting: model.setting(\.testToneLevelDB, .live),
                range: -60...0,
                format: "%.1f dBFS",
                tooltip: "0 dBFS is 100% of the audio modulation left after the pilot and RDS reservation. -20 dBFS is the usual line-up reference.",
                defaultValue: AppConfig().testToneLevelDB)
            if ChainFeature.finalStage.applies(in: model.config.operatingMode) {
                Text(Self.expectedDeviationText(model.config))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Expected deviation")
                    .help("What a modulation monitor should read for this level: the audio deviation plus the pilot and RDS on top.")
            }
        }
    }

    /// Audio deviation a modulation monitor should read for the current
    /// level: `mpx_deviation_khz x budget x 10^(level/20)`, where the budget
    /// is the audio-composite headroom after the pilot/RDS reservation (the
    /// same arithmetic as `MPXGenerator.makeFinalCompositeThresholds` with
    /// 0 dB output gain). Pilot and RDS add on top at their injection levels.
    static func expectedDeviationText(_ c: AppConfig) -> String {
        let outputGain = max(1.0, pow(10.0, c.outputGainDB / 20.0))
        let rdsAmplitude = c.enRDS && !c.monoMode ? c.rdsLevel / 75.0 : 0.0
        let pilotAmplitude = c.monoMode ? 0.0 : c.pilotLevel
        let budget = max(0.0, (0.98 / outputGain) - pilotAmplitude - rdsAmplitude - 0.02)
        let audioKHz = c.mpxDeviationKHz * budget * pow(10.0, c.testToneLevelDB / 20.0)
        let subcarrierKHz = c.mpxDeviationKHz * (pilotAmplitude + rdsAmplitude)
        return String(
            format: "Expected: %.1f kHz audio + %.1f kHz pilot and RDS = %.1f kHz peak",
            audioKHz, subcarrierKHz, audioKHz + subcarrierKHz)
    }

    /// "50 Hz", "1 kHz", "12 kHz": every number with its unit.
    static func presetLabel(for freq: Double) -> String {
        if freq >= 1_000 {
            let kHz = freq / 1_000.0
            return kHz == kHz.rounded() ? "\(Int(kHz)) kHz" : String(format: "%.1f kHz", kHz)
        }
        return "\(Int(freq)) Hz"
    }
}

/// The sine's frequency: an exact number typed in, with one-click presets.
struct TestToneFrequencyRow: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let setting = model.setting(\.testToneFreq, .live)
        LabeledContent("Frequency") {
            HStack(spacing: 6) {
                TextField("Frequency", value: setting.binding,
                          format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .labelsHidden()
                Text("Hz").foregroundStyle(.secondary)
            }
        }
        .help("20 Hz to 20 kHz.")
        HStack(spacing: 6) {
            ForEach(TestToneView.frequencyPresets, id: \.self) { freq in
                let isActive = abs(setting.binding.wrappedValue - freq) < 0.5
                Button(TestToneView.presetLabel(for: freq)) {
                    setting.binding.wrappedValue = freq
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // Tint the preset matching the current frequency so the
                // active selection is visible at a glance.
                .tint(isActive ? BroadcastStyle.accent : nil)
            }
        }
    }
}

#endif  // os(macOS)
