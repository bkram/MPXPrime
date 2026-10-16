// The "Devices" button and its device-list popover, ported from Prime
// Mixer's ConsoleView.DeviceListPopover. Takes the device list and the scan
// time in; the owner rescans (and hot-plug refreshes) outside the view.

import MPXPrimeCore
import SwiftUI

/// `Label("Devices", systemImage: "cable.connector.horizontal")` that opens
/// `DeviceListPopover` below itself.
public struct DevicesButton: View {
    let devices: [AudioDevice]
    let lastScan: Date
    let rescan: () -> Void
    @State private var showingDevices = false

    public init(devices: [AudioDevice], lastScan: Date, rescan: @escaping () -> Void) {
        self.devices = devices
        self.lastScan = lastScan
        self.rescan = rescan
    }

    public var body: some View {
        Button { showingDevices = true } label: {
            Label("Devices", systemImage: "cable.connector.horizontal")
        }
        .controlSize(.small)
        .help("Show every audio device with its channels, sample rate and bit depth, or rescan")
        .accessibilityLabel("Audio devices")
        .popover(isPresented: $showingDevices, arrowEdge: .bottom) {
            DeviceListPopover(devices: devices, lastScan: lastScan, rescan: rescan)
        }
    }
}

/// Every audio device in one grid: Device / Transport / In / Out / Rate /
/// Depth / Buffer, with "in" / "out" badges on the system defaults, the time
/// of the last scan and a Rescan button.
public struct DeviceListPopover: View {
    let devices: [AudioDevice]
    let lastScan: Date
    let rescan: () -> Void

    public init(devices: [AudioDevice], lastScan: Date, rescan: @escaping () -> Void) {
        self.devices = devices
        self.lastScan = lastScan
        self.rescan = rescan
    }

    private let columns = [
        GridItem(.flexible(minimum: 160), alignment: .leading),
        GridItem(.fixed(74), alignment: .leading),
        GridItem(.fixed(44), alignment: .trailing),
        GridItem(.fixed(44), alignment: .trailing),
        GridItem(.fixed(64), alignment: .trailing),
        GridItem(.fixed(96), alignment: .trailing),
        GridItem(.fixed(58), alignment: .trailing)
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Audio devices").font(.headline)
                Spacer()
                Text("Scanned \(lastScan.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
                    .help("Re-read every device, its sample rate and bit depth")
                    .accessibilityLabel("Rescan audio devices")
            }
            Divider()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                Group {
                    Text("Device"); Text("Transport"); Text("In"); Text("Out"); Text("Rate"); Text("Depth"); Text("Buffer")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(devices) { device in
                    HStack(spacing: 4) {
                        Text(device.name).lineLimit(1)
                        if device.isDefaultInput { badge("in") }
                        if device.isDefaultOutput { badge("out") }
                    }
                    Text(device.transport.isEmpty ? "-" : device.transport).foregroundStyle(.secondary)
                    Text(device.inputChannels == 0 ? "-" : "\(device.inputChannels)")
                    Text(device.outputChannels == 0 ? "-" : "\(device.outputChannels)")
                    Text(device.nominalSampleRate > 0 ? AudioDeviceText.kHz(device.nominalSampleRate) : "-")
                        .help(availableRates(device))
                    Text(depthText(device))
                        .help("Physical sample size the hardware moves. The engine itself is always 32-bit float.")
                    Text(device.bufferFrameSize > 0 ? "\(device.bufferFrameSize)" : "-")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .monospacedDigit()
            }
            if devices.isEmpty {
                Text("No audio devices found.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Rates, depths and buffers are what each device runs at now. The engine switches a device to the configured rate when it starts; use Audio MIDI Setup for anything else.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 660, alignment: .leading)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .help(text == "in" ? "System default input" : "System default output")
            .accessibilityLabel(text == "in" ? "System default input" : "System default output")
    }

    private func availableRates(_ device: AudioDevice) -> String {
        guard !device.availableSampleRates.isEmpty else { return "Available rates not reported" }
        return "Available: " + device.availableSampleRates.map { AudioDeviceText.kHz($0) }.joined(separator: ", ")
    }

    private func depthText(_ device: AudioDevice) -> String {
        let formats = [device.inputPhysicalFormat, device.outputPhysicalFormat].filter { !$0.isEmpty }
        guard !formats.isEmpty else { return "-" }
        let unique = Array(Set(formats)).sorted()
        return unique.joined(separator: " / ")
    }
}
