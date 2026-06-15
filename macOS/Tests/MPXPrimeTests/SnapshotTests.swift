import Testing
import Foundation
@testable import MPXPrime

// Named snapshot slots — persistent operator-saved setups beyond format
// profiles. Stored as JSON next to the INI; embed the config as INI text
// so schema migrations stay handled by the existing INI parser's
// defaults. These tests pin the contract: save / load / clear roundtrip
// preserves config exactly, the file persists across viewmodel
// instances, and corrupt files don't crash the load path.

@Suite("Snapshots")
@MainActor
struct SnapshotTests {

    /// Use a fresh temp dir per test so concurrent runs don't trample
    /// each other's snapshot files.
    private func makeTempConfigPath() -> String {
        NSTemporaryDirectory()
            + "MPXPrime-SnapshotTests-\(UUID().uuidString).ini"
    }

    private func makeViewModel(at path: String? = nil) -> MPXPrimeViewModel {
        let configPath = path ?? makeTempConfigPath()
        return MPXPrimeViewModel(configPath: configPath)
    }

    @Test func initialStateHasEightEmptySlots() {
        let model = makeViewModel()
        #expect(model.snapshots.count == MPXPrimeViewModel.snapshotSlotCount)
        #expect(model.snapshots.allSatisfy { $0 == nil })
    }

    @Test func saveSnapshotStoresCurrentConfig() {
        let model = makeViewModel()
        model.config.pilotLevel = 0.092
        model.config.compositeClipperThresholdDB = -0.85
        model.saveSnapshot(slot: 0, name: "Test Save")

        #expect(model.snapshots[0] != nil)
        #expect(model.snapshots[0]?.name == "Test Save")
        #expect(!(model.snapshots[0]?.configINIText.isEmpty ?? true),
            "saved snapshot must embed INI text")
    }

    @Test func loadSnapshotRestoresStoredConfig() {
        let model = makeViewModel()
        model.config.pilotLevel = 0.092
        model.config.compositeClipperThresholdDB = -0.85
        model.config.finalDriveDB = 7.5
        model.saveSnapshot(slot: 1, name: "Restore Test")

        // Drift the live config.
        model.config.pilotLevel = 0.060
        model.config.compositeClipperThresholdDB = -1.0
        model.config.finalDriveDB = 3.0

        // Loading the snapshot must overwrite the drift.
        model.loadSnapshot(slot: 1)
        #expect(abs(model.config.pilotLevel - 0.092) < 1e-6)
        #expect(abs(model.config.compositeClipperThresholdDB - (-0.85)) < 1e-6)
        #expect(abs(model.config.finalDriveDB - 7.5) < 1e-6)
    }

    @Test func clearSnapshotEmptiesSlotOnly() {
        let model = makeViewModel()
        model.saveSnapshot(slot: 0, name: "Keep me")
        model.config.pilotLevel = 0.095
        model.saveSnapshot(slot: 1, name: "Drop me")
        model.clearSnapshot(slot: 1)

        #expect(model.snapshots[0] != nil, "slot 0 must remain")
        #expect(model.snapshots[1] == nil, "slot 1 must be empty")
    }

    @Test func exportWritesConfigINIToFile() throws {
        let model = makeViewModel()
        model.config.pilotLevel = 0.087
        model.saveSnapshot(slot: 3, name: "Export me")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MPXPrime-export-\(UUID().uuidString).ini")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(model.exportSnapshot(slot: 3, to: url))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == model.snapshots[3]?.configINIText,
            "exported file must equal the stored preset config")
        // The export is a loadable config.
        let reloaded = try AppConfig.loadFromINIString(written)
        #expect(abs(reloaded.pilotLevel - 0.087) < 1e-6)

        // Empty slot exports nothing.
        #expect(!model.exportSnapshot(slot: 4, to: url))
    }

    @Test func importLoadsConfigFromFileIntoSlot() throws {
        let exporter = makeViewModel()
        exporter.config.pilotLevel = 0.091
        exporter.saveSnapshot(slot: 0, name: "Shared")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Shared Setup.ini")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(exporter.exportSnapshot(slot: 0, to: url))

        // A fresh model imports the exported file into a slot.
        let importer = makeViewModel()
        #expect(importer.importSnapshot(slot: 4, from: url))
        #expect(importer.snapshots[4] != nil)
        #expect(importer.snapshots[4]?.name == "Shared Setup", "name comes from the filename")

        // Loading the imported slot reproduces the original config.
        importer.loadSnapshot(slot: 4)
        #expect(abs(importer.config.pilotLevel - 0.091) < 1e-6)

        // A missing file fails cleanly (returns false, slot untouched).
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).ini")
        #expect(!importer.importSnapshot(slot: 5, from: missing))
        #expect(importer.snapshots[5] == nil)
    }

    @Test func exportFilenameSanitizesName() {
        let model = makeViewModel()
        model.saveSnapshot(slot: 0, name: "Rock / Pop: A?")
        #expect(model.exportFilename(slot: 0) == "Rock - Pop- A-.ini")
        #expect(model.exportFilename(slot: 1) == "Preset 2.ini", "empty slot uses the label")
    }

    @Test func emptyNameFallsBackToSlotLabel() {
        let model = makeViewModel()
        model.saveSnapshot(slot: 2, name: "")
        #expect(model.snapshots[2]?.name == "Preset 3")

        model.saveSnapshot(slot: 5, name: "   \n\t  ")
        #expect(model.snapshots[5]?.name == "Preset 6",
            "whitespace-only names should also fall back")
    }

    @Test func renameSnapshotUpdatesNameOnly() {
        let model = makeViewModel()
        model.config.pilotLevel = 0.085
        model.saveSnapshot(slot: 0, name: "Original")
        let originalINI = model.snapshots[0]?.configINIText
        let originalSavedAt = model.snapshots[0]?.savedAt

        model.renameSnapshot(slot: 0, name: "Renamed")

        #expect(model.snapshots[0]?.name == "Renamed")
        #expect(model.snapshots[0]?.configINIText == originalINI,
            "rename must not change the captured config")
        #expect(model.snapshots[0]?.savedAt == originalSavedAt,
            "rename must not bump the savedAt timestamp")
    }

    @Test func outOfRangeSlotIndicesAreNoOps() {
        let model = makeViewModel()
        // Out-of-bounds save / load / clear / rename must not crash.
        model.saveSnapshot(slot: -1, name: "Bad")
        model.saveSnapshot(slot: 999, name: "Bad")
        model.loadSnapshot(slot: -1)
        model.loadSnapshot(slot: 999)
        model.clearSnapshot(slot: -1)
        model.clearSnapshot(slot: 999)
        model.renameSnapshot(slot: -1, name: "Bad")
        model.renameSnapshot(slot: 999, name: "Bad")
        #expect(model.snapshots.allSatisfy { $0 == nil },
            "invalid indices must not mutate slot state")
    }

    @Test func loadEmptySlotIsNoOp() {
        let model = makeViewModel()
        model.config.pilotLevel = 0.075
        // Slot 3 is empty.
        model.loadSnapshot(slot: 3)
        // Pilot level should not have changed.
        #expect(abs(model.config.pilotLevel - 0.075) < 1e-6)
    }

    // MARK: - Disk persistence

    @Test func snapshotsPersistAcrossViewModelInstances() {
        let configPath = makeTempConfigPath()
        // First VM instance — save a snapshot.
        let model1 = makeViewModel(at: configPath)
        model1.config.pilotLevel = 0.088
        model1.config.finalDriveDB = 8.2
        model1.saveSnapshot(slot: 0, name: "Persist Test")

        // Second VM instance pointing at the same config path — should
        // load the snapshot from disk.
        let model2 = makeViewModel(at: configPath)
        #expect(model2.snapshots[0] != nil,
            "snapshot must survive across viewmodel instances via disk")
        #expect(model2.snapshots[0]?.name == "Persist Test")

        // Cleanup — remove the on-disk snapshot file so test runs don't
        // leak temp files indefinitely.
        try? FileManager.default.removeItem(atPath: model2.snapshotsFilePath)
        try? FileManager.default.removeItem(atPath: configPath)
    }

    @Test func corruptSnapshotFileDoesNotCrash() {
        let configPath = makeTempConfigPath()
        let model = makeViewModel(at: configPath)

        // Write nonsense JSON to the snapshot file.
        try? "not json {{{".data(using: .utf8)?.write(
            to: URL(fileURLWithPath: model.snapshotsFilePath))

        // Reloading must not crash; slots stay empty.
        model.loadSnapshotsFromDisk()
        #expect(model.snapshots.allSatisfy { $0 == nil },
            "corrupt snapshot file must reset to empty slots, not crash")

        try? FileManager.default.removeItem(atPath: model.snapshotsFilePath)
        try? FileManager.default.removeItem(atPath: configPath)
    }
}
