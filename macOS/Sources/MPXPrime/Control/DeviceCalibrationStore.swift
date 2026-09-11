import Foundation

// Per-device level calibration memory: Input Gain is remembered per INPUT
// device, MPX Output Level + Line Output per OUTPUT device (per operating
// mode), and recalled automatically when the device selection changes --
// switching exciters restores each rig's calibration with zero clicks.
//
// Storage is a JSON sidecar next to the INI (`<configPath>.devicecal.json`,
// the SnapshotStore pattern): a per-device map cannot be INI keys without
// dynamic key names, which the schema contract forbids. Keys are CoreAudio
// UIDs on macOS and ALSA PCM names on Linux; the last-known device NAME is
// kept per entry because USB UIDs can change with the physical port -- a
// lookup falls back to the newest same-name entry, and the next capture
// migrates it to the new UID (the `selectUID` re-matching policy).

/// One device's remembered calibration. Level fields are optional: nil means
/// "never calibrated in that role/mode" and recall keeps the current value.
/// Output gain is kept PER OPERATING MODE: composite `output_gain_db` is a
/// modulation-domain trim (clamp -40..0) while processed-audio is a line
/// feed level (clamp +/-40) -- different physical calibrations of one rig.
struct DeviceCalibration: Codable, Equatable {
    var name: String?
    var inputGainDB: Double?
    var compositeOutputGainDB: Double?
    var compositeLineOutputDBFS: Double?
    var processedOutputGainDB: Double?
    var updatedAt: Date
}

/// On-disk envelope for `<configPath>.devicecal.json`.
struct DeviceCalibrationFile: Codable, Equatable {
    var inputs: [String: DeviceCalibration]
    var outputs: [String: DeviceCalibration]

    static let empty = DeviceCalibrationFile(inputs: [:], outputs: [:])
}

/// Stateless load/save, same posture as SnapshotStore: callers (the
/// MainActor view model, the headless backend actor) own their copy of the
/// decoded file and serialize their writes themselves; a missing or corrupt
/// file loads as empty; writes are atomic.
enum DeviceCalibrationStore {
    /// Growth cap per direction; oldest-updated entries are evicted first.
    /// USB UID drift is the only unbounded generator and the same-name
    /// dedupe in `capture` kills it at the source, so 32 is generous.
    static let maxEntriesPerDirection = 32

    static func filePath(forConfigPath configPath: String) -> String {
        configPath + ".devicecal.json"
    }

    static func load(configPath: String) -> DeviceCalibrationFile {
        let path = filePath(forConfigPath: configPath)
        guard FileManager.default.fileExists(atPath: path) else { return .empty }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DeviceCalibrationFile.self, from: data)
        } catch {
            return .empty
        }
    }

    static func write(_ file: DeviceCalibrationFile, configPath: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(
            to: URL(fileURLWithPath: filePath(forConfigPath: configPath)),
            options: [.atomic])
    }
}

extension DeviceCalibrationFile {
    /// UID-first lookup with newest-same-name fallback (the USB-port UID
    /// drift case). No further fallback: a miss means "keep current values".
    func inputEntry(uid: String, name: String?) -> DeviceCalibration? {
        Self.entry(in: inputs, uid: uid, name: name)
    }

    func outputEntry(uid: String, name: String?) -> DeviceCalibration? {
        Self.entry(in: outputs, uid: uid, name: name)
    }

    private static func entry(
        in map: [String: DeviceCalibration], uid: String, name: String?
    ) -> DeviceCalibration? {
        if let exact = map[uid] { return exact }
        guard let name, !name.isEmpty else { return nil }
        return map.values
            .filter { $0.name == name }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// Write-through: record the config's current levels under its selected
    /// devices. Empty UIDs are never captured. Same-name entries under OTHER
    /// UIDs that are not currently connected are dropped (UID-drift
    /// migration; two same-name devices both connected are genuinely two
    /// devices and both kept). Evicts oldest-updated entries beyond the cap.
    /// Returns true when anything changed (callers skip the disk write
    /// otherwise).
    mutating func capture(
        from config: AppConfig,
        inputName: String?,
        outputName: String?,
        connectedUIDs: Set<String>
    ) -> Bool {
        var changed = false
        let now = Date()

        if let uid = config.inputDeviceUID, !uid.isEmpty {
            var entry = inputs[uid]
                ?? DeviceCalibration(name: nil, updatedAt: now)
            let name = inputName ?? config.inputDeviceName ?? entry.name
            if entry.name != name || entry.inputGainDB != config.inputGainDB {
                entry.name = name
                entry.inputGainDB = config.inputGainDB
                entry.updatedAt = now
                inputs[uid] = entry
                changed = true
            }
            changed = Self.dedupeAndCap(
                &inputs, keepUID: uid, name: name, connectedUIDs: connectedUIDs) || changed
        }

        if let uid = config.outputDeviceUID, !uid.isEmpty {
            var entry = outputs[uid]
                ?? DeviceCalibration(name: nil, updatedAt: now)
            let name = outputName ?? config.outputDeviceName ?? entry.name
            var entryChanged = entry.name != name
            entry.name = name
            if config.processedAudioOutput {
                entryChanged = entryChanged
                    || entry.processedOutputGainDB != config.outputGainDB
                entry.processedOutputGainDB = config.outputGainDB
            } else {
                entryChanged = entryChanged
                    || entry.compositeOutputGainDB != config.outputGainDB
                    || entry.compositeLineOutputDBFS != config.mpxLineOutputDBFS
                entry.compositeOutputGainDB = config.outputGainDB
                entry.compositeLineOutputDBFS = config.mpxLineOutputDBFS
            }
            if entryChanged {
                entry.updatedAt = now
                outputs[uid] = entry
                changed = true
            }
            changed = Self.dedupeAndCap(
                &outputs, keepUID: uid, name: name, connectedUIDs: connectedUIDs) || changed
        }
        return changed
    }

    /// Recall: overwrite the config's calibration levels from the entries
    /// for its selected devices. Mode-aware on the output side; a missing
    /// entry or nil field keeps the current value (the caller's follow-up
    /// `capture` seeds it). Pure read -- callers re-validate the config so
    /// recalled values ride the canonical clamps. Returns true when any
    /// level changed.
    func recall(
        into config: inout AppConfig,
        recallInput: Bool,
        recallOutput: Bool,
        inputName: String?,
        outputName: String?
    ) -> Bool {
        var changed = false
        if recallInput, let uid = config.inputDeviceUID, !uid.isEmpty,
            let entry = inputEntry(uid: uid, name: inputName ?? config.inputDeviceName),
            let gain = entry.inputGainDB, gain != config.inputGainDB {
            config.inputGainDB = gain
            changed = true
        }
        if recallOutput, let uid = config.outputDeviceUID, !uid.isEmpty,
            let entry = outputEntry(uid: uid, name: outputName ?? config.outputDeviceName) {
            if config.processedAudioOutput {
                if let gain = entry.processedOutputGainDB, gain != config.outputGainDB {
                    config.outputGainDB = gain
                    changed = true
                }
            } else {
                if let gain = entry.compositeOutputGainDB, gain != config.outputGainDB {
                    config.outputGainDB = gain
                    changed = true
                }
                if let line = entry.compositeLineOutputDBFS, line != config.mpxLineOutputDBFS {
                    config.mpxLineOutputDBFS = line
                    changed = true
                }
            }
        }
        return changed
    }

    /// Drop same-name entries under other, not-connected UIDs (the drifted
    /// UID's orphan) and evict oldest-updated beyond the cap. Returns true
    /// when anything was removed.
    private static func dedupeAndCap(
        _ map: inout [String: DeviceCalibration],
        keepUID: String,
        name: String?,
        connectedUIDs: Set<String>
    ) -> Bool {
        var changed = false
        if let name, !name.isEmpty {
            for (uid, entry) in map
            where uid != keepUID && entry.name == name && !connectedUIDs.contains(uid) {
                map.removeValue(forKey: uid)
                changed = true
            }
        }
        while map.count > DeviceCalibrationStore.maxEntriesPerDirection {
            guard let oldest = map
                .filter({ $0.key != keepUID })
                .min(by: { $0.value.updatedAt < $1.value.updatedAt })
            else { break }
            map.removeValue(forKey: oldest.key)
            changed = true
        }
        return changed
    }
}
