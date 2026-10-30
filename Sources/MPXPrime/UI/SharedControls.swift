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

/// The restart-required badge. Never placed by hand: the setting wrappers
/// below draw it whenever their `ConfigSetting` is restart-class, so a
/// control cannot carry a wrong badge or miss one. Matches the status bar's
/// Restart to Apply chip so the two read as one concept.
struct RestartBadge: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.caption2)
            .foregroundStyle(BroadcastStyle.tightAmber)
            .help("Takes effect after an engine restart. Changing it while running shows Restart to Apply in the status bar.")
            .accessibilityLabel("Restart required")
    }
}

/// A config value bound together with how a change to it is applied. The
/// control that shows it derives its restart badge from `disposition`, the
/// same value `setConfigValue` uses to decide whether a change needs a
/// restart, so the badge and the behaviour cannot disagree.
struct ConfigSetting<Value> {
    let binding: Binding<Value>
    let disposition: MPXPrimeViewModel.RuntimeChangeDisposition

    var restartRequired: Bool { disposition == .restart }
}

extension MPXPrimeViewModel {
    /// The one way a page binds a config value: the disposition is
    /// required, never defaulted, so each control states how it applies.
    func setting<T>(
        _ keyPath: WritableKeyPath<AppConfig, T>,
        _ disposition: RuntimeChangeDisposition
    ) -> ConfigSetting<T> {
        SettingAudit.record(keyPath, disposition)
        return ConfigSetting(binding: configBinding(keyPath, runtimeDisposition: disposition), disposition: disposition)
    }
}

extension MPXPrimeViewModel {
    /// A linear amplitude key (0.5-0.999) shown and edited in dBFS, so every
    /// level on the page reads in the same unit. Stored linear, unchanged.
    func dbSetting(
        _ keyPath: WritableKeyPath<AppConfig, Double>,
        _ disposition: RuntimeChangeDisposition,
        linearRange: ClosedRange<Double> = 0.5...0.999
    ) -> ConfigSetting<Double> {
        SettingAudit.record(keyPath, disposition)
        return ConfigSetting(
            binding: Binding(
                get: { Self.dBFS(fromLinear: self.config[keyPath: keyPath]) },
                set: { db in
                    let linear = min(linearRange.upperBound, max(linearRange.lowerBound, Self.linear(fromDBFS: db)))
                    self.setConfigValue(keyPath, linear, runtimeDisposition: disposition)
                }),
            disposition: disposition)
    }

    /// A 0-1 (or 0-n) amount shown and edited as a percentage.
    func percentSetting(
        _ keyPath: WritableKeyPath<AppConfig, Double>,
        _ disposition: RuntimeChangeDisposition
    ) -> ConfigSetting<Double> {
        SettingAudit.record(keyPath, disposition)
        return ConfigSetting(
            binding: Binding(
                get: { self.config[keyPath: keyPath] * 100.0 },
                set: { self.setConfigValue(keyPath, $0 / 100.0, runtimeDisposition: disposition) }),
            disposition: disposition)
    }

    nonisolated static func dBFS(fromLinear linear: Double) -> Double {
        20.0 * log10(max(linear, 1e-9))
    }

    nonisolated static func linear(fromDBFS db: Double) -> Double {
        pow(10.0, db / 20.0)
    }
}

/// Every (property, disposition) pair a page declared through `setting()`
/// since the last `reset()`. Tests build each page's body and hold the
/// declarations against the engine-derived classification
/// (`RestartClassKeys`), so a wrong badge or a live key wired as restart
/// fails a test instead of reaching an operator.
@MainActor
enum SettingAudit {
    /// The declared disposition and a way to find the INI key(s) behind it.
    private(set) static var entries: [(iniKeys: () -> [String], disposition: MPXPrimeViewModel.RuntimeChangeDisposition, name: String)] = []
    static var isRecording = false

    static func record<T>(_ keyPath: WritableKeyPath<AppConfig, T>,
                          _ disposition: MPXPrimeViewModel.RuntimeChangeDisposition) {
        guard isRecording else { return }
        entries.append(({ RestartClassKeys.iniKeys(for: keyPath) }, disposition, "\(keyPath)"))
    }

    static func reset() { entries.removeAll() }
}

/// The collapsed "Advanced" group every page uses for set-once controls
/// (`AdvancedControls.keys`). Builds its content when the page is built, so
/// the controls inside are part of the page like any other.
struct AdvancedGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String = "Advanced", @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(title) {
            content
        }
    }
}

/// Label text plus the restart badge when the setting needs one.
struct SettingLabel: View {
    let title: String
    let restartRequired: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if restartRequired { RestartBadge() }
        }
    }
}

/// On/off option bound to a `ConfigSetting`; draws its own restart badge.
/// Pass `.toggleStyle(.switch)` for a stage's enable at the top of a card.
struct SettingToggle: View {
    let title: String
    let setting: ConfigSetting<Bool>
    var tooltip: String?

    init(_ title: String, setting: ConfigSetting<Bool>, tooltip: String? = nil) {
        self.title = title
        self.setting = setting
        self.tooltip = tooltip
    }

    var body: some View {
        Toggle(isOn: setting.binding) {
            SettingLabel(title: title, restartRequired: setting.restartRequired)
        }
        .accessibilityLabel(title)
        .modifier(TooltipIfPresent(text: tooltip))
    }
}

/// A choice bound to a `ConfigSetting`; draws its own restart badge. The
/// caller sets the picker style (segmented for 2-4 options, menu above).
struct SettingPicker<Value: Hashable, Options: View>: View {
    let title: String
    let setting: ConfigSetting<Value>
    var tooltip: String?
    @ViewBuilder var options: Options

    init(_ title: String, setting: ConfigSetting<Value>, tooltip: String? = nil,
         @ViewBuilder options: () -> Options) {
        self.title = title
        self.setting = setting
        self.tooltip = tooltip
        self.options = options()
    }

    var body: some View {
        Picker(selection: setting.binding) {
            options
        } label: {
            SettingLabel(title: title, restartRequired: setting.restartRequired)
        }
        .accessibilityLabel(title)
        .modifier(TooltipIfPresent(text: tooltip))
    }
}

struct DoubleSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var accessibilityLabel: String?
    var tooltip: String?
    var restartRequired: Bool = false
    /// What the reset button and a double-click on the title restore: the
    /// active Format Profile's value (`MPXPrimeViewModel.resetValue`). nil =
    /// no reset affordance.
    var defaultValue: Double?

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String,
         accessibilityLabel: String? = nil, tooltip: String? = nil,
         restartRequired: Bool = false, defaultValue: Double? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
        self.accessibilityLabel = accessibilityLabel
        self.tooltip = tooltip
        self.restartRequired = restartRequired
        self.defaultValue = defaultValue
    }

    /// The badge follows the setting's disposition.
    init(title: String, setting: ConfigSetting<Double>, range: ClosedRange<Double>, format: String,
         accessibilityLabel: String? = nil, tooltip: String? = nil, defaultValue: Double? = nil) {
        self.init(title: title, value: setting.binding, range: range, format: format,
                  accessibilityLabel: accessibilityLabel, tooltip: tooltip,
                  restartRequired: setting.restartRequired, defaultValue: defaultValue)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Slider(value: $value, in: range)
                    .controlSize(.small)
                    .accessibilityLabel(accessibilityLabel ?? title)
                    // VoiceOver otherwise reads the slider as a bare 0-100%;
                    // surface the real unit-bearing readout instead.
                    .accessibilityValue(Text(String(format: format, value)))
                Text(String(format: format, value))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                if let defaultValue { resetButton(defaultValue) }
            }
            // Attach on the interactive HStack so hovering the slider /
            // readout fires the tooltip reliably (LabeledContent alone does
            // not always forward `.help()` to its content on macOS 15).
            .contentShape(Rectangle())
            .modifier(TooltipIfPresent(text: tooltip))
        } label: {
            SettingLabel(title: title, restartRequired: restartRequired)
            // Double-click the name to reset, as on a mixing desk.
            .onTapGesture(count: 2) { if let defaultValue { value = defaultValue } }
        }
        .contentShape(Rectangle())
        .modifier(TooltipIfPresent(text: tooltip))
    }

    /// Within 0.01 % of the range counts as "at the default", so a value
    /// that round-tripped through the INI does not leave the button lit.
    private func isAtDefault(_ target: Double) -> Bool {
        abs(value - target) <= max(1e-9, (range.upperBound - range.lowerBound) * 1e-4)
    }

    /// Always laid out (fixed width), hidden at the default, so moving the
    /// slider off it never shifts the row.
    private func resetButton(_ target: Double) -> some View {
        let atDefault = isAtDefault(target)
        let text = String(format: format, target)
        return Button {
            value = target
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .frame(width: 16)
        .opacity(atDefault ? 0 : 1)
        .disabled(atDefault)
        .help("Reset to \(text)")
        .accessibilityLabel("Reset \(accessibilityLabel ?? title) to \(text)")
        .accessibilityHidden(atDefault)
    }
}

#endif  // os(macOS)
