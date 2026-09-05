import Foundation

// Snapshot loads restore THE SOUND, not the wiring: keys that describe this
// installation (hardware, routing, calibration, remote-control reachability)
// are preserved from the live config when a snapshot is loaded. Snapshot
// SAVE and export stay full-config, so an exported slot remains a complete,
// shareable --config file; only the load-into-live path filters.
//
// Companion of `legacyResetPreservedMPXKeys` (AppConfig.swift), which plays
// the same role across the legacy-profile migration.

extension AppConfig {
    /// INI keys preserved from the LIVE config on snapshot load, by section.
    /// - devices + engine format: loading a colleague's preset must not
    ///   retarget the transmitter feed or restart-class engine format
    /// - the three calibration levels AND the operating mode booleans: the
    ///   levels are per-rig calibration, and `output_gain_db`'s meaning
    ///   depends on `processed_audio_output` (preserving one without the
    ///   other would be incoherent)
    /// - the control_* keys: a snapshot loaded over REST that turns the
    ///   control server off (or moves it) strands a remote box
    static let installationPreservedKeysBySection: [String: [String]] = [
        "INTERFACES": [
            "input_device_uid", "output_device_uid", "monitor_device_uid",
            "input_device_name", "output_device_name", "monitor_device_name",
            "sample_rate", "blocksize",
            "operating_mode", "monitor_enabled"
        ],
        "MPX": [
            "input_gain_db", "output_gain_db", "mpx_line_output_dbfs", "processed_audio_ceiling_dbtp"
        ],
        "CONTROL": [
            "control_enabled", "control_bind", "control_port", "control_api_key"
        ]
    ]

    /// The snapshot-load merge: the snapshot's INI text with the live
    /// config's installation keys overlaid (a key ABSENT in the live config
    /// is also removed from the snapshot side, so "no device selected" is
    /// preserved too). Runs through the canonical parse/make path, so all
    /// clamps and validation apply.
    static func applyingSnapshot(
        iniText: String, preservingInstallationFrom live: AppConfig
    ) -> AppConfig {
        var merged = INIParser.parse(iniText)
        let liveSections = INIParser.parse(live.iniText())
        for (section, keys) in installationPreservedKeysBySection {
            for key in keys {
                if let value = liveSections[section]?[key] {
                    merged[section, default: [:]][key] = value
                } else {
                    merged[section]?[key] = nil
                }
            }
        }
        return make(fromParsed: merged)
    }
}
