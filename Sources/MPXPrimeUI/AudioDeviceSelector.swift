// Device-plus-channels selector, ported from Prime Mixer's
// InputSelectionControl / OutputSelectionControl and their routing popovers,
// folded into one view that serves both roles. Takes the device list and two
// bindings; never touches CoreAudio itself.

import MPXPrimeCore
import SwiftUI

/// Whether a selector picks the channels a device RECEIVES on (input) or
/// SENDS on (output): decides which channel count is shown and the wording
/// ("Inputs 3, 4" vs "Outputs 3, 4").
public enum AudioDeviceRole: Sendable {
    case input
    case output
}

/// Text helpers shared by the device views.
enum AudioDeviceText {
    /// "48 kHz" / "44.1 kHz" (Prime Mixer's `RouteTable.kHz`).
    static func kHz(_ rate: Double) -> String {
        let value = rate / 1000
        return value == value.rounded() ? String(format: "%.0f kHz", value) : String(format: "%.1f kHz", value)
    }

    /// "Inputs 3, 4" / "Input 3" / "Outputs 1, 2" for a pair (nil = 1, 2).
    static func channelWords(_ pair: ChannelPair?, role: AudioDeviceRole) -> String {
        let p = pair ?? .stereoDefault
        let noun = role == .input ? "Input" : "Output"
        return "\(noun)\(p.isMono ? "" : "s") \(p.numbers)"
    }
}

/// A bordered button showing the chosen device's name with a subtitle such as
/// "Inputs 3, 4, 192 kHz" (red when `problem` is set, which then replaces the
/// subtitle), opening a popover with the Device and Channels menus and
/// the explanation / footnote lines.
///
/// `selectedUID` is the device UID ("" = none / the default, labelled
/// `noneLabel`). `channels` is the operator's pair; nil means channels 1, 2.
/// Choosing a device the current pair does not fit resets the pair to nil.
public struct AudioDeviceSelector: View {
    let title: String
    let role: AudioDeviceRole
    let devices: [AudioDevice]
    @Binding var selectedUID: String
    @Binding var channels: ChannelPair?
    let allowNone: Bool
    let noneLabel: String
    let problem: String?
    let footnote: String?
    @State private var showingPopover = false

    public init(
        title: String, role: AudioDeviceRole, devices: [AudioDevice],
        selectedUID: Binding<String>, channels: Binding<ChannelPair?>,
        allowNone: Bool = true, noneLabel: String = "None",
        problem: String? = nil, footnote: String? = nil
    ) {
        self.title = title
        self.role = role
        self.devices = devices
        self._selectedUID = selectedUID
        self._channels = channels
        self.allowNone = allowNone
        self.noneLabel = noneLabel
        self.problem = problem
        self.footnote = footnote
    }

    public var body: some View {
        Button { showingPopover = true } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(deviceName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(subtitleIsAProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .help(helpText)
        .accessibilityLabel("Configure \(title): \(deviceName), \(subtitle)")
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            AudioDevicePopover(
                title: title, role: role, devices: devices,
                selectedUID: $selectedUID, channels: $channels,
                allowNone: allowNone, noneLabel: noneLabel,
                problem: problem, footnote: footnote)
        }
    }

    private var selectedDevice: AudioDevice? {
        devices.first { $0.uid == selectedUID }
    }

    private var deviceName: String {
        if let device = selectedDevice { return device.name }
        return selectedUID.isEmpty ? noneLabel : "Device missing"
    }

    private var subtitleIsAProblem: Bool {
        problem != nil || (selectedDevice == nil && !selectedUID.isEmpty)
    }

    private var subtitle: String {
        if let problem { return problem }
        guard let device = selectedDevice else {
            return selectedUID.isEmpty ? "No device selected" : "Not connected"
        }
        let words = AudioDeviceText.channelWords(channels, role: role)
        guard device.nominalSampleRate > 0 else { return words }
        return "\(words), \(AudioDeviceText.kHz(device.nominalSampleRate))"
    }

    private var helpText: String {
        if let problem { return problem }
        return selectedDevice.map { "\($0.name), \(subtitle). Configure \(title.lowercased())." }
            ?? "Configure \(title.lowercased()): device and channels"
    }
}

/// The popover body: Device menu, problem line, Channels menu, footnote.
private struct AudioDevicePopover: View {
    let title: String
    let role: AudioDeviceRole
    let devices: [AudioDevice]
    @Binding var selectedUID: String
    @Binding var channels: ChannelPair?
    let allowNone: Bool
    let noneLabel: String
    let problem: String?
    let footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Picker("Device", selection: deviceSelection) {
                if allowNone {
                    Text(noneLabel).tag("")
                }
                if !selectedUID.isEmpty && selectedDevice == nil {
                    // Keep a saved-but-absent device selectable so the menu
                    // shows the truth instead of silently picking another.
                    Text("Not connected (\(selectedUID))").tag(selectedUID)
                }
                ForEach(devices) { device in
                    Text(menuRow(device)).tag(device.uid)
                }
            }
            .pickerStyle(.menu)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text(selectedDevice.map { "\(sectionNoun) channels, \(channelCount($0)) available" }
                ?? "\(sectionNoun) channels")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let device = selectedDevice, channelCount(device) > 0 {
                channelMenu(count: channelCount(device))
                Text(channelCount(device) == 1
                     ? "This device has one channel."
                     : "Left on the first channel of the pair, right on the second.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose a device to select its channels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private var sectionNoun: String { role == .input ? "Input" : "Output" }

    private var selectedDevice: AudioDevice? {
        devices.first { $0.uid == selectedUID }
    }

    private func channelCount(_ device: AudioDevice) -> Int {
        role == .input ? device.inputChannels : device.outputChannels
    }

    private func menuRow(_ device: AudioDevice) -> String {
        let count = "\(channelCount(device)) \(role == .input ? "in" : "out")"
        guard device.nominalSampleRate > 0 else { return "\(device.name), \(count)" }
        return "\(device.name), \(count), \(AudioDeviceText.kHz(device.nominalSampleRate))"
    }

    private var deviceSelection: Binding<String> {
        Binding(get: { selectedUID }, set: { uid in
            selectedUID = uid
            // A pair the new device does not have goes back to 1, 2 rather
            // than staying as a dangling request.
            if let pair = channels, let device = devices.first(where: { $0.uid == uid }),
               !pair.fits(channelCount: channelCount(device)) {
                channels = nil
            }
        })
    }

    /// The pair in effect: nil means channels 1, 2 (mono 1 on a one-channel
    /// device), as `ChannelPair.resolve` applies it.
    private func currentPair(count: Int) -> ChannelPair {
        channels ?? (count == 1 ? ChannelPair(left: 0, right: 0) : .stereoDefault)
    }

    /// One menu of consecutive stereo pairs (1-2, 3-4, ...). A mono or
    /// non-adjacent pair from the INI is listed as it is, so the menu never
    /// claims a choice the engine is not using.
    private func channelMenu(count: Int) -> some View {
        let offered = ChannelPair.stereoPairs(channelCount: count)
        let current = currentPair(count: count)
        return Picker("Channels", selection: Binding(
            get: { current },
            set: { channels = $0 }
        )) {
            ForEach(offered, id: \.self) { pair in
                Text(pair.rangeLabel).tag(pair)
            }
            if !offered.contains(current) {
                Divider()
                Text("\(current.rangeLabel) (from settings)").tag(current)
            }
        }
        .pickerStyle(.menu)
        .help("The pair of \(sectionNoun.lowercased()) channels this device uses")
        .accessibilityLabel("\(sectionNoun) channels")
    }
}
