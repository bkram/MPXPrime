import Testing
import Foundation
@testable import MPXPrime

// Guards against silent drift between the CODE defaults (AppConfig()) and
// the shipped sample config (macOS/MPXPrime.ini). Every key where the
// sample deliberately differs from the default must be listed here WITH the
// reason -- an unexplained difference is either a stale sample (update the
// INI) or an accidentally-changed default (fix the code). Verification.ini
// intentionally differs wholesale and is not checked.
@Suite("Sample INI vs code defaults")
struct SampleINIDefaultDriftTests {
    /// Keys the sample INI deliberately sets away from the code default,
    /// with the reason. Reviewed like code.
    private static let deliberateDifferences: Set<String> = [
        // The sample ships as a ready-to-broadcast demo station: RDS text
        // and identity fields are filled in, not blank defaults.
        "pi", "ps_a", "ps_dynamic", "rt_text", "ptyn", "ps_long_32",
        "pty", "ecc",
        // Demo station enables the operational RDS extras.
        "en_ptyn", "en_ct", "en_id", "en_af", "af_list",
        // Sample demonstrates a tuned processing starting point rather
        // than the bare code defaults.
        "multiband_preset_id", "format_profile_id",
        // Derived from the preset choice above: applying the 5_ac preset
        // at `light` intensity expands these per-band values away from the
        // raw code defaults (they are the preset's numbers, not drift).
        "multiband_intensity",
        "multiband_low_threshold_db", "multiband_mid_threshold_db",
        "multiband_high_threshold_db",
        "multiband_low_ratio", "multiband_mid_ratio", "multiband_high_ratio",
        "multiband_low_attack_ms", "multiband_mid_attack_ms",
        "multiband_high_attack_ms",
        "multiband_low_release_ms", "multiband_mid_release_ms",
        "multiband_high_release_ms",
        // PrimeBass preset values (the `ac` preset, not raw defaults).
        "primebass_amount", "primebass_freq_hz", "primebass_harmonics",
        "primebass_drive", "primebass_density",
        // Demo convenience: sample starts the transport on launch and
        // ships a neutral UTC clock offset (code default is CET +1).
        "auto_start", "tz_offset",
    ]

    private func sampleINIURL() -> URL {
        // <package>/Tests/MPXPrimeTests/ThisFile.swift -> <package>/MPXPrime.ini
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MPXPrimeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macOS package root
            .appendingPathComponent("MPXPrime.ini")
    }

    @Test func sampleINIOnlyDiffersFromDefaultsWhereDocumented() throws {
        let url = sampleINIURL()
        #expect(FileManager.default.fileExists(atPath: url.path),
            "sample INI not found at \(url.path)")

        let sample = try AppConfig.load(fromINI: url.path)
        let defaults = AppConfig()

        // Serialize both through the same writer and diff by key, so the
        // comparison covers exactly the persisted vocabulary.
        let sampleSections = INIParser.parse(try sample.captureAsINIString())
        let defaultSections = INIParser.parse(try defaults.captureAsINIString())

        var unexpected: [String] = []
        for (section, bucket) in sampleSections {
            for (key, value) in bucket {
                let defaultValue = defaultSections[section]?[key]
                if value != defaultValue
                    && !Self.deliberateDifferences.contains(key) {
                    unexpected.append(
                        "\(key) = \(value) (default \(defaultValue ?? "<missing>"))")
                }
            }
        }
        let details = unexpected.sorted().joined(separator: "\n")
        #expect(unexpected.isEmpty,
            "sample INI drifted from code defaults without a documented reason:\n\(details)")
    }
}
