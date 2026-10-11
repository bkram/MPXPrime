import Foundation
import Testing

@testable import MPXPrime

// The 0.60 BS.412 key change is a load-time migration that BOTH runtimes
// persist: an INI carrying the pre-0.60 keys is read onto the standard's
// 0.0 dBr ceiling, reported, and -- once saved -- rewritten without the old
// keys. The first 0.60 deploy read it silently and the rig's INI kept
// showing keys the encoder no longer used.
@Suite struct BS412KeyMigrationTests {

    private func writeTemp(_ text: String) -> String {
        let path = NSTemporaryDirectory() + "MPXPrime-BS412Migration-\(UUID().uuidString).ini"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func oldKeysAreReportedReadOntoTheStandardCeilingAndSavedAway() throws {
        let path = writeTemp("""
        [MPX]
        bs412_enabled = True
        bs412_threshold_db = -10.0
        bs412_window_seconds = 60.0
        """)
        let loaded = try AppConfig.loadReportingMigration(fromINI: path)
        #expect(loaded.bs412KeysMigrated)
        #expect(loaded.legacyProfileID == nil)
        #expect(loaded.config.bs412Enabled)
        #expect(loaded.config.bs412CeilingDBr == 0.0)

        try loaded.config.save(toINI: path)
        let rewritten = try INIParser.parseFile(path)
        let mpx = try #require(rewritten["MPX"])
        #expect(mpx["bs412_ceiling_dbr"] != nil)
        #expect(mpx["bs412_threshold_db"] == nil)
        #expect(mpx["bs412_window_seconds"] == nil)

        let reloaded = try AppConfig.loadReportingMigration(fromINI: path)
        #expect(reloaded.bs412KeysMigrated == false)
        #expect(reloaded.config.bs412CeilingDBr == 0.0)
    }

    @Test func eitherOldKeyAloneTriggersTheMigration() throws {
        let windowOnly = try AppConfig.loadReportingMigration(
            fromINI: writeTemp("[MPX]\nbs412_window_seconds = 45.0\n"))
        #expect(windowOnly.bs412KeysMigrated)
        #expect(windowOnly.config.bs412CeilingDBr == 0.0)
    }

    @Test func theNewKeyWinsOverLingeringOldOnes() throws {
        let loaded = try AppConfig.loadReportingMigration(
            fromINI: writeTemp("[MPX]\nbs412_ceiling_dbr = -2.5\nbs412_threshold_db = -10.0\n"))
        #expect(loaded.bs412KeysMigrated == false)
        #expect(abs(loaded.config.bs412CeilingDBr - (-2.5)) < 1e-9)
    }

    @Test func aCurrentINIIsNotReportedAsMigrated() throws {
        let loaded = try AppConfig.loadReportingMigration(
            fromINI: writeTemp("[MPX]\nbs412_enabled = False\n"))
        #expect(loaded.bs412KeysMigrated == false)
        #expect(loaded.config.bs412CeilingDBr == AppConfig().bs412CeilingDBr)
    }
}

// Persisting a migration is reported truthfully: "Saved." only after the
// write succeeded, and a failed write says so and leaves the migrated
// settings running. Both runtimes go through this one helper, with the save
// injectable so the failure path runs headless.
@Suite struct MigrationPersistenceTests {

    private func writeTemp(_ text: String) -> String {
        let path = NSTemporaryDirectory() + "MPXPrime-MigrationPersist-\(UUID().uuidString).ini"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private struct WriteFailure: Error, LocalizedError {
        var errorDescription: String? { "disk full" }
    }

    @Test func aSuccessfulWriteIsReportedAsSavedAndRewritesTheFile() throws {
        let path = writeTemp("[MPX]\nbs412_threshold_db = -10.0\n")
        let loaded = try AppConfig.loadReportingMigration(fromINI: path)
        let report = AppConfig.persistMigration(
            loaded.config, toINI: path,
            legacyProfileID: loaded.legacyProfileID, bs412KeysMigrated: loaded.bs412KeysMigrated)
        #expect(report.count == 2)
        #expect(report.last == "Saved.")
        #expect(report.first?.hasPrefix("Pre-0.60 BS.412 keys") == true)
        let mpx = try #require(try INIParser.parseFile(path)["MPX"])
        #expect(mpx["bs412_threshold_db"] == nil)
        #expect(mpx["bs412_ceiling_dbr"] != nil)
    }

    @Test func aFailedWriteIsReportedAsNotSavedAndLeavesTheFileAlone() throws {
        let path = writeTemp("[MPX]\nbs412_threshold_db = -10.0\n")
        let loaded = try AppConfig.loadReportingMigration(fromINI: path)
        let report = AppConfig.persistMigration(
            loaded.config, toINI: path,
            legacyProfileID: loaded.legacyProfileID, bs412KeysMigrated: loaded.bs412KeysMigrated,
            save: { _, _ in throw WriteFailure() })
        #expect(report.count == 2)
        #expect(report.last?.hasPrefix("NOT saved (disk full)") == true)
        #expect(report.contains { $0.contains("Saved.") && !$0.contains("NOT saved") } == false)
        // The migrated settings still run in memory...
        #expect(loaded.config.bs412CeilingDBr == 0.0)
        // ...and the file was not touched, so the next start migrates again.
        let mpx = try #require(try INIParser.parseFile(path)["MPX"])
        #expect(mpx["bs412_threshold_db"] == "-10.0")
        #expect(mpx["bs412_ceiling_dbr"] == nil)
    }

    @Test func nothingToMigrateSaysNothingAndWritesNothing() throws {
        let path = writeTemp("[MPX]\nbs412_enabled = False\n")
        let loaded = try AppConfig.loadReportingMigration(fromINI: path)
        var writes = 0
        let report = AppConfig.persistMigration(
            loaded.config, toINI: path,
            legacyProfileID: nil, bs412KeysMigrated: loaded.bs412KeysMigrated,
            save: { _, _ in writes += 1 })
        #expect(report.isEmpty)
        #expect(writes == 0)
    }

    @Test func bothMigrationsShareOneWrite() {
        var writes = 0
        let report = AppConfig.persistMigration(
            AppConfig(), toINI: "/dev/null",
            legacyProfileID: "chr_top40", bs412KeysMigrated: true,
            save: { _, _ in writes += 1 })
        #expect(report.count == 3)
        #expect(writes == 1)
        #expect(report.last == "Saved.")
    }
}

// How the Now Playing poller launches a script. Until 0.60 it hard-coded
// `/bin/zsh`, which no stock Ubuntu ships, so on Linux every script failed
// to launch and the journal repeated "launch failed" every poll.
@Suite struct NowPlayingLaunchPlanTests {

    @Test func anExecutableScriptRunsDirectlySoItsShebangDecides() {
        let plan = NowPlayingScriptRunner.launchPlan(
            forScript: "/opt/station/nowplaying",
            isExecutable: { $0 == "/opt/station/nowplaying" },
            exists: { _ in true })
        #expect(plan == .init(executable: "/opt/station/nowplaying", arguments: []))
    }

    @Test func aPlainFileRunsThroughTheFirstShellPresent() {
        // A box without zsh (stock Ubuntu): bash is next in line.
        let noZsh = NowPlayingScriptRunner.launchPlan(
            forScript: "/home/op/np.sh",
            isExecutable: { $0 == "/bin/bash" || $0 == "/bin/sh" },
            exists: { _ in true })
        #expect(noZsh == .init(executable: "/bin/bash", arguments: ["/home/op/np.sh"]))

        // A Mac: zsh, as before 0.60.
        let mac = NowPlayingScriptRunner.launchPlan(
            forScript: "/Users/op/np.sh",
            isExecutable: { NowPlayingScriptRunner.shellCandidates.contains($0) },
            exists: { _ in true })
        #expect(mac == .init(executable: "/bin/zsh", arguments: ["/Users/op/np.sh"]))

        // Nothing recognisable at all: sh is the POSIX floor.
        let bare = NowPlayingScriptRunner.launchPlan(
            forScript: "/x/np.sh", isExecutable: { _ in false }, exists: { _ in true })
        #expect(bare == .init(executable: "/bin/sh", arguments: ["/x/np.sh"]))
    }

    @Test func aMissingScriptHasNoPlan() {
        let plan = NowPlayingScriptRunner.launchPlan(
            forScript: "/Users/someone/Projects/nowplaying.sh",
            isExecutable: { _ in true },
            exists: { _ in false })
        #expect(plan == nil)
    }
}
