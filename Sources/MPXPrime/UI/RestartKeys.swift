// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Foundation

/// How a change to each INI key is applied, DERIVED from the engine rather
/// than written by hand: the key is flipped alone through `ConfigPatch`, the
/// classifier the REST API uses, which compares the engine's two live-apply
/// structs (`RuntimeConfig`, `RDSRuntimeConfig`). The Help window's restart
/// list reads this, and `LayoutRestartBadgeTests` holds every GUI control's
/// declared disposition (which draws its restart badge) equal to it, so
/// neither can drift from what the engine can hot-apply. (A hand-written
/// list said the monitor routing was restart-class while Audio I/O applied
/// it live; the Pilot Level slider carried a restart badge on a live key.)
enum RestartClassKeys {
    /// Keys the ENGINE never reads, so "not in a live struct" does not mean
    /// "restart": stored and acted on elsewhere, or simply recorded.
    static let notEngineKeys: [String: String] = [
        "format_profile_id": "label written by profile applies",
        "multiband_preset_id": "label written by preset applies",
        "multiband_intensity": "label written by preset applies",
        "primebass_preset_id": "label written by preset applies",
        "final_stage_preset_id": "label written by preset applies",
        "input_device_name": "derived mirror of the device UID",
        "output_device_name": "derived mirror of the device UID",
        "monitor_device_name": "derived mirror of the device UID",
        "now_playing_script": "the now-playing poller reloads it",
        "now_playing_poll_seconds": "the now-playing poller reloads it",
        "now_playing_timeout_seconds": "the now-playing poller reloads it",
        "pty_rbds": "names the PTY codes in the GUI; the transmitted code is the same",
        "auto_start": "read at app launch",
        "control_enabled": "read at app launch",
        "control_bind": "read at app launch",
        "control_port": "read at app launch",
        "control_api_key": "read at app launch"
    ]

    /// Every INI key whose change alone needs an engine restart, sorted.
    static let all: [String] = compute()

    /// The disposition of one key: the most live classification against the
    /// shipped configuration and against one with every optional feature
    /// switched on (a PIN field is inert while PIN is off, which is not the
    /// same as needing a restart). nil when no probe value moved the config.
    static func disposition(of key: String) -> ConfigKeyOutcome.Disposition? {
        if notEngineKeys[key] != nil { return ConfigKeyOutcome.Disposition.none }
        let results = [baseline, everythingOn].compactMap { classify(key, in: $0) }
        if results.contains(.live) { return .live }
        if results.contains(.liveRDS) { return .liveRDS }
        if results.contains(ConfigKeyOutcome.Disposition.none) { return ConfigKeyOutcome.Disposition.none }
        return results.first
    }

    /// The GUI's spelling of a disposition.
    static func guiDisposition(of key: String) -> MPXPrimeViewModel.RuntimeChangeDisposition? {
        guard let d = disposition(of: key) else { return nil }
        switch d {
        case .live: return .live
        case .liveRDS: return .liveRDS
        case .restartRequired: return .restart
        case .none: return MPXPrimeViewModel.RuntimeChangeDisposition.none
        case .unchanged: return nil
        }
    }

    /// The INI key(s) a config property is stored under, found by changing
    /// the property and diffing the serialized configuration.
    static func iniKeys<T>(for keyPath: WritableKeyPath<AppConfig, T>) -> [String] {
        let base = AppConfig()
        guard let a = try? ConfigPatch.sectionedValues(of: base) else { return [] }
        var keys: Set<String> = []
        for value in probeValues(base[keyPath: keyPath]) {
            var changed = base
            changed[keyPath: keyPath] = value
            guard let b = try? ConfigPatch.sectionedValues(of: changed) else { continue }
            for (section, bucket) in b {
                for (key, v) in bucket where a[section]?[key] != v { keys.insert(key) }
            }
        }
        return keys.sorted()
    }

    private static func probeValues<T>(_ value: T) -> [T] {
        switch value {
        case let b as Bool: return [!b].compactMap { $0 as? T }
        case let d as Double: return [d + 1, d - 1, d + 0.1].compactMap { $0 as? T }
        case let i as Int: return [i + 1, i - 1].compactMap { $0 as? T }
        case let s as String: return [s + "X", s == "A" ? "B" : "A"].compactMap { $0 as? T }
        default: return []
        }
    }

    private static let baseline = AppConfig()

    /// The shipped configuration with every boolean key switched on.
    private static let everythingOn: AppConfig = {
        let config = AppConfig()
        guard let sections = try? ConfigPatch.sectionedValues(of: config) else { return config }
        var patch: [String: String] = [:]
        for bucket in sections.values {
            for (key, value) in bucket where value.lowercased() == "false" { patch[key] = "True" }
        }
        return (try? ConfigPatch.apply(patch, to: config).config) ?? config
    }()

    private static func compute() -> [String] {
        guard let sections = try? ConfigPatch.sectionedValues(of: baseline) else { return [] }
        let keys = Set(sections.values.flatMap { $0.keys })
        return keys.filter { disposition(of: $0) == .restartRequired }.sorted()
    }

    /// The same comparison `ConfigPatch.apply` makes (the key alone moves
    /// `RuntimeConfig`: live; `RDSRuntimeConfig`: live RDS; neither:
    /// restart), on the parsed sections in memory rather than through a
    /// temporary file per probe, so the whole table builds in about a second.
    private static func classify(_ key: String, in config: AppConfig) -> ConfigKeyOutcome.Disposition? {
        guard let sections = try? ConfigPatch.sectionedValues(of: config),
              let current = sections.values.compactMap({ $0[key] }).first else { return nil }
        let dsp = MPXGenerator.makeRuntimeConfig(from: config)
        let rds = MPXGenerator.RDSRuntimeConfig.make(from: config)
        for candidate in probes(for: current) {
            var patched = sections
            for (section, var bucket) in patched {
                bucket[key] = candidate
                patched[section] = bucket
            }
            let solo = AppConfig.make(fromParsed: patched)
            if solo == config { continue }
            if MPXGenerator.makeRuntimeConfig(from: solo) != dsp { return .live }
            if MPXGenerator.RDSRuntimeConfig.make(from: solo) != rds { return .liveRDS }
            if ConfigPatch.backendOwnedKeys.contains(key) { return ConfigKeyOutcome.Disposition.none }
            return .restartRequired
        }
        return nil
    }

    /// Values that differ from `current` and survive validation for most
    /// keys: the other boolean, nearby numbers, an edited string.
    private static func probes(for current: String) -> [String] {
        switch current.lowercased() {
        case "true": return ["False"]
        case "false": return ["True"]
        default: break
        }
        if let v = Double(current) {
            let candidates = [v + 1, v - 1, v * 0.5, v + 0.1, v - 0.1, v * 2, v + 10, v - 10, 0, 1]
            if current.contains(".") || current.contains("e") {
                return candidates.map { String($0) }
            }
            return candidates.map { String(Int($0.rounded())) }
        }
        return [current + "X", "", "A"]
    }
}

#endif  // os(macOS)
