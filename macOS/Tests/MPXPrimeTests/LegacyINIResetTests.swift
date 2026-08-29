import Foundation
import Testing

@testable import MPXPrime

// A pre-0.45 INI (legacy Format Profile id) has its PROCESSING reset to the
// migrated profile on load, while RDS, interfaces, control server and the
// hardware-calibration keys are kept. Anything else carries the field
// failure forward: every peak controller off, safety soft clips clipping.
@Suite struct LegacyINIResetTests {

    private func writeTemp(_ text: String) -> String {
        let path = NSTemporaryDirectory() + "MPXPrime-LegacyINI-\(UUID().uuidString).ini"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private let legacyINI = """
    [MPX]
    format_profile_id = chr_top40
    final_stage_preset_id = chr
    pre_encode_limiter_enabled = False
    mpx_clipper_enabled = False
    mpx_clipper_cancel_audio = True
    hf_clipper_enabled = True
    advanced_dynamics_enabled = True
    final_drive_db = 8.0
    input_gain_db = -3.98
    pilot_level = 0.09
    mpx_deviation_khz = 70.0
    mpx_line_output_dbfs = -3.0
    output_gain_db = -1.5
    preemphasis_us = 75
    test_tone_level_db = -12.0

    [RDS]
    en_rds = True
    pi = 1234
    ps_a = LEGACY
    rt_text = Kept as it was
    rds_level = 3.1

    [INTERFACES]
    sample_rate = 96000.0
    blocksize = 1024
    output_device_uid = legacy-out-uid

    [CONTROL]
    control_enabled = True
    control_port = 9999
    """

    @Test func legacyProfileResetsProcessingToTheMigratedProfile() throws {
        let loaded = try AppConfig.loadReportingMigration(fromINI: writeTemp(legacyINI))
        #expect(loaded.legacyProfileID == "chr_top40")
        let cfg = loaded.config
        #expect(cfg.formatProfileID == "music_loud")
        // The music_loud gain structure, not the legacy one.
        #expect(cfg.preEncodeAudioLimiterEnabled)
        #expect(cfg.compositeClipperEnabled)
        #expect(cfg.compositeClipperCancelAudio == false)
        #expect(cfg.hfLimiterEnabled)
        #expect(cfg.hfClipperEnabled == false)
        #expect(cfg.advancedDynamicsEnabled == false)
        #expect(abs(cfg.inputGainDB) < 1e-9)
        #expect(abs(cfg.finalDriveDB - 8.0) < 1e-9)
    }

    @Test func legacyResetKeepsRDSInterfacesControlAndCalibration() throws {
        let cfg = try AppConfig.load(fromINI: writeTemp(legacyINI))
        // RDS verbatim
        #expect(cfg.enRDS)
        #expect(cfg.rdsPI == "1234")
        #expect(cfg.rdsPSA == "LEGACY")
        #expect(abs(cfg.rdsLevel - 3.1) < 1e-6)
        // Interfaces + control verbatim
        #expect(abs(cfg.sampleRate - 96_000.0) < 1e-6)
        #expect(cfg.blockSize == 1024)
        #expect(cfg.outputDeviceUID == "legacy-out-uid")
        #expect(cfg.controlEnabled)
        #expect(cfg.controlPort == 9999)
        // Calibration keys from [MPX]
        #expect(abs(cfg.pilotLevel - 0.09) < 1e-6)
        #expect(abs(cfg.mpxDeviationKHz - 70.0) < 1e-6)
        #expect(abs(cfg.mpxLineOutputDBFS - (-3.0)) < 1e-6)
        #expect(abs(cfg.outputGainDB - (-1.5)) < 1e-6)
        #expect(cfg.preemphasisUS == 75)
        #expect(abs(cfg.testToneLevelDB - (-12.0)) < 1e-6)
    }

    @Test func currentProfileINIIsLoadedUntouched() throws {
        var original = AppConfig()
        original.formatProfileID = "music_clean"
        original.preEncodeAudioLimiterEnabled = false   // deliberately odd: must survive
        original.finalDriveDB = 2.5
        original.rdsPI = "ABCD"
        let path = writeTemp(original.iniText())
        let loaded = try AppConfig.loadReportingMigration(fromINI: path)
        #expect(loaded.legacyProfileID == nil)
        #expect(loaded.config.preEncodeAudioLimiterEnabled == false)
        #expect(abs(loaded.config.finalDriveDB - 2.5) < 1e-9)
        #expect(loaded.config.rdsPI == "ABCD")
        #expect(loaded.config == original)
    }
}
