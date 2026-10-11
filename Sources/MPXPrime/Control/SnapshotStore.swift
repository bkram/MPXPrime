import Foundation

// The operator preset slots ("Presets" in the GUI sidebar), extracted from
// the view model so BOTH control backends can serve them over the REST API
// (GET/POST/PATCH/DELETE /api/snapshots...) -- previously the slots were
// GUI-process state and a headless box had no snapshot concept at all.
//
// Storage stays exactly what the GUI always wrote: `<configPath>.snapshots.json`,
// a JSON envelope of 8 optional slots, each carrying a full MPX Prime INI as
// text (so an exported slot doubles as a shareable --config file, and schema
// migrations ride the INI parser's defaults).

/// One saved snapshot slot -- name, save timestamp, and the configuration
/// captured at save time as canonical INI text.
struct ConfigSnapshot: Identifiable, Codable {
    let id: UUID
    var name: String
    var savedAt: Date
    var configINIText: String
}

/// On-disk JSON envelope for `snapshots.json`. Wraps the slot array so future
/// top-level fields can be added without breaking old files.
struct SnapshotFile: Codable {
    var slots: [ConfigSnapshot?]
    /// The preset whose config is currently live (persisted so the "Loaded"
    /// marker survives relaunch). Optional with defaults so older files decode.
    var activeID: UUID?
    var activeModified: Bool?
}

/// Stateless load/save over the snapshots file. Thread-agnostic: callers
/// (the MainActor view model, the headless backend actor) own their copy of
/// the decoded file and serialize their writes themselves.
enum SnapshotStore {
    static let slotCount = 8

    static func filePath(forConfigPath configPath: String) -> String {
        configPath + ".snapshots.json"
    }

    /// Load the file, padding/truncating to `slotCount` and dropping a stale
    /// activeID whose slot is gone. A missing/corrupt file loads as empty --
    /// same defensive posture the GUI always had.
    static func load(configPath: String) -> SnapshotFile {
        let empty = SnapshotFile(
            slots: Array(repeating: nil, count: slotCount),
            activeID: nil, activeModified: false)
        let path = filePath(forConfigPath: configPath)
        guard FileManager.default.fileExists(atPath: path) else { return empty }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var file = try decoder.decode(SnapshotFile.self, from: data)
            var slots: [ConfigSnapshot?] = Array(repeating: nil, count: slotCount)
            for i in 0..<min(file.slots.count, slots.count) { slots[i] = file.slots[i] }
            file.slots = slots
            if let active = file.activeID,
               !slots.contains(where: { $0?.id == active }) {
                file.activeID = nil
                file.activeModified = false
            }
            if file.activeModified == nil { file.activeModified = false }
            return file
        } catch {
            return empty
        }
    }

    static func write(_ file: SnapshotFile, configPath: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(
            to: URL(fileURLWithPath: filePath(forConfigPath: configPath)),
            options: [.atomic])
    }

    /// Default display name for an empty-name save into `slot`.
    static func defaultName(slot: Int) -> String { "Preset \(slot + 1)" }
}
