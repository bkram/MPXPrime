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

struct SettingsSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Form {
            Section("Configuration") {
                LabeledContent("Path") {
                    Text(model.configFilePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                // Device rescans live on Audio I/O (the Devices button);
                // the spectrum span moved to Audio I/O > Engine > Advanced.
                HStack(spacing: 10) {
                    Button("Show in Finder") { model.revealConfigInFinder() }
                        .buttonStyle(.bordered)
                    Button("Reload from Disk") { model.reloadConfigFromDisk() }
                        .buttonStyle(.bordered)
                }
            }

            Section("Remote Control") {
                SettingToggle(
                    "Enable REST API and Web Dashboard",
                    setting: model.setting(\.controlEnabled, .none),
                    tooltip: "Serves a control API and web dashboard over HTTP. Applied at the next app launch.")
                LabeledContent("Address") {
                    TextField(
                        "127.0.0.1",
                        text: model.setting(\.controlBind, .none).binding
                    )
                    .frame(maxWidth: 180)
                    .help("Interface to listen on. 127.0.0.1 = this Mac only; 0.0.0.0 = all interfaces (requires an API key).")
                }
                LabeledContent("Port") {
                    TextField(
                        "8737",
                        value: model.setting(\.controlPort, .none).binding,
                        format: .number.grouping(.never)
                    )
                    .frame(maxWidth: 100)
                    .help("TCP port for the control server (default 8737).")
                }
                LabeledContent("API Key") {
                    TextField(
                        "Required for non-local access",
                        text: model.setting(\.controlAPIKey, .none).binding
                    )
                    .frame(maxWidth: 260)
                    .help("Clients send this as 'Authorization: Bearer <key>' or 'X-API-Key'. Mandatory when the address is not 127.0.0.1; the server refuses to start remote-exposed without one.")
                }
                Text("Changes take effect at the next app launch. For access beyond the local network, front with a TLS reverse proxy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 920, alignment: .topLeading)
        .padding(.horizontal, 10)
        .controlSize(.small)
    }
}

struct SettingsWindowView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingsSectionView(model: model)
            .navigationTitle("Settings")
    }
}

#endif  // os(macOS)
