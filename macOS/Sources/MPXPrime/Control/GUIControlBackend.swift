// ControlBackend for GUI mode (macOS): a thin MainActor adapter over the
// view model, so remote changes go through the exact same choke points the
// GUI's own controls use (setConfigValue semantics, saveConfig, live-apply,
// status text) and the window reflects them immediately.
#if os(macOS)

import Foundation

struct GUIControlBackend: ControlBackend {
    // The VM owns the server task; weak breaks the retain cycle
    // (vm -> controlServerTask -> backend -> vm).
    weak var vm: MPXPrimeViewModel?

    private func withVM<R: Sendable>(
        _ body: @MainActor @escaping (MPXPrimeViewModel) throws -> R
    ) async throws -> R {
        guard let vm else {
            throw ControlError.engineFailure("view model gone")
        }
        return try await MainActor.run { try body(vm) }
    }

    func status() async -> ControlStatus {
        (try? await withVM { $0.remoteStatus() })
            ?? ControlStatus(
                running: false, platform: "macOS (GUI)",
                version: AppConfig.appVersion, sampleRateHz: 0,
                uptimeSeconds: nil, restartPending: false,
                sourceMode: "", outputMode: "", notes: ["view model gone"])
    }

    func meters() async -> ControlMeters? {
        try? await withVM { $0.remoteMeters() }
    }

    func rds() async -> ControlRDS {
        (try? await withVM { $0.remoteRDS() })
            ?? ControlRDS(
                enabled: false, pi: "", pty: 0, ta: false, tp: false,
                livePS: nil, liveRT: nil, livePTYN: nil, liveLongPS: nil,
                configuredRT: "", configuredPSActiveBank: "")
    }

    func devices() async -> ControlDevices {
        (try? await withVM { $0.remoteDevices() })
            ?? ControlDevices(
                inputs: [], outputs: [], selectedInput: "", selectedOutput: "", note: "")
    }

    func configSections() async throws -> [String: [String: String]] {
        try await withVM { try ConfigPatch.sectionedValues(of: $0.config) }
    }

    func applyConfigPatch(_ patch: [String: String]) async throws -> ConfigApplyResult {
        try await withVM { try $0.applyRemoteConfigPatch(patch) }
    }

    func transport(_ action: TransportAction) async throws -> ControlStatus {
        try await withVM { $0.remoteTransport(action) }
    }

    func presets() async -> [String: [String]] {
        (try? await withVM { $0.remotePresets() }) ?? [:]
    }

    func applyPreset(kind: String, id: String, intensity: Double?) async throws -> ConfigApplyResult {
        try await withVM { vm in
            try vm.remoteApplyPreset(kind: kind, id: id, intensity: intensity)
            return ConfigApplyResult(
                outcomes: [], appliedLive: vm.isRunning,
                restartPending: vm.runtimeApplyPending)
        }
    }

    func setNowPlaying(artist: String, title: String, display: String) async -> Bool {
        (try? await withVM { $0.applyRemoteNowPlaying(artist: artist, title: title, display: display) })
            ?? false
    }
}

#endif  // os(macOS)
