import Foundation
import Testing

@testable import MPXPrime

// ConfigPatch is the remote-control API's config engine: INI-key patches
// reloaded through the existing parser, with live/liveRDS/restart
// dispositions DERIVED from the RuntimeConfig/RDSRuntimeConfig factories.
@Suite("Config patch engine")
struct ConfigPatchTests {
    private func baseConfig() -> AppConfig {
        AppConfig()
    }

    @Test func roundTripIsStable() throws {
        // The whole mechanism rests on captureAsINIString/loadFromINIString
        // being a fixed point; a drifting round-trip would make every
        // classification report phantom changes.
        let cfg = baseConfig()
        let reloaded = try AppConfig.loadFromINIString(cfg.captureAsINIString())
        #expect(reloaded == cfg)
    }

    @Test func dspKeyClassifiesLive() throws {
        let cfg = baseConfig()
        let target = cfg.outputGainDB - 1.5   // composite mode is attenuation-only (0.45)
        let (patched, outcomes, planes) = try ConfigPatch.apply(
            ["output_gain_db": String(target)], to: cfg)
        #expect(abs(patched.outputGainDB - target) < 1e-9)
        #expect(outcomes.count == 1)
        #expect(outcomes[0].disposition == .live)
        #expect(planes.dspLive && !planes.rdsLive && !planes.restartRequired)
    }

    @Test func rdsTextClassifiesLiveRDS() throws {
        let cfg = baseConfig()
        let (patched, outcomes, planes) = try ConfigPatch.apply(
            ["rt_text": "REMOTE CONTROL TEST"], to: cfg)
        #expect(patched.rdsRTText == "REMOTE CONTROL TEST")
        #expect(outcomes[0].disposition == .liveRDS)
        #expect(planes.rdsLive && !planes.dspLive)
    }

    @Test func rdsPIClassifiesLiveRDS() throws {
        let cfg = baseConfig()
        let (patched, outcomes, _) = try ConfigPatch.apply(["pi": "83E1"], to: cfg)
        #expect(patched.rdsPI.uppercased().hasSuffix("83E1"))
        #expect(outcomes[0].disposition == .liveRDS)
    }

    @Test func injectionLevelClassifiesRestart() throws {
        // rds_level (injection kHz) reconfigures the modulator: the GUI marks
        // it restart-only and RDSRuntimeConfig carries only the enable gate
        // for it, so a *level* change must classify restart-required.
        let cfg = baseConfig()
        let target = cfg.rdsLevel + 0.5
        let (patched, outcomes, planes) = try ConfigPatch.apply(
            ["rds_level": String(target)], to: cfg)
        #expect(abs(patched.rdsLevel - target) < 1e-6)
        #expect(outcomes[0].disposition == .restartRequired)
        #expect(planes.restartRequired)
    }

    @Test func lineOutputClassifiesLiveAndClamps() throws {
        // The dBFS line output must hot-apply (it rides RuntimeConfig to the
        // engines' DAC write) and clamp to the -60..0 validation range.
        let cfg = baseConfig()
        let (patched, outcomes, planes) = try ConfigPatch.apply(
            ["mpx_line_output_dbfs": "-12.0"], to: cfg)
        #expect(abs(patched.mpxLineOutputDBFS - (-12.0)) < 1e-9)
        #expect(outcomes[0].disposition == .live)
        #expect(planes.dspLive)
        // Positive values are unphysical at a DAC (they only clip the
        // composite and skew pilot/RDS upward -- observed in the field as
        // "deviation good, pilot/RDS 3 dB high"); the load clamp caps at 0.
        let (plusSix, _, _) = try ConfigPatch.apply(
            ["mpx_line_output_dbfs": "6.0"], to: cfg)
        #expect(plusSix.mpxLineOutputDBFS == 0.0)
        let (plusThree, _, _) = try ConfigPatch.apply(
            ["mpx_line_output_dbfs": "3.0"], to: cfg)
        #expect(plusThree.mpxLineOutputDBFS == 0.0)
    }

    @Test func deliveryTargetClassifiesRestartAndCeilingLive() throws {
        // The digital delivery target changes filtering and the make-up, so it
        // is restart-class like the operating mode; the true-peak ceiling only
        // rescales the make-up and must hot-apply.
        var cfg = AppConfig()
        cfg.processedAudioOutput = true
        let (target, targetOutcomes, planesA) = try ConfigPatch.apply(
            ["processed_audio_target": "digital"], to: cfg)
        #expect(targetOutcomes[0].disposition == .restartRequired)
        #expect(planesA.restartRequired)
        #expect(target.processedAudioTarget == "digital")
        let (ceiling, ceilingOutcomes, planesB) = try ConfigPatch.apply(
            ["processed_audio_ceiling_dbtp": "-2.0"], to: cfg)
        #expect(ceilingOutcomes[0].disposition == .live)
        #expect(planesB.dspLive && !planesB.restartRequired)
        #expect(abs(ceiling.processedAudioCeilingDBTP - (-2.0)) < 1e-9)
        // Out-of-range values clamp; unknown target words fall back to fm_coder.
        let (clamped, _, _) = try ConfigPatch.apply(["processed_audio_ceiling_dbtp": "-9.0"], to: cfg)
        #expect(abs(clamped.processedAudioCeilingDBTP - (-6.0)) < 1e-9)
        let (bogus, _, _) = try ConfigPatch.apply(["processed_audio_target": "hd"], to: cfg)
        #expect(bogus.processedAudioTarget == "fm_coder")
    }

    @Test func sampleRateClassifiesRestart() throws {
        let cfg = baseConfig()
        let (patched, outcomes, planes) = try ConfigPatch.apply(
            ["sample_rate": "96000"], to: cfg)
        #expect(patched.sampleRate == 96000)
        #expect(outcomes[0].disposition == .restartRequired)
        #expect(planes.restartRequired && !planes.dspLive)
    }

    @Test func unknownKeyReportsUnchanged() throws {
        let cfg = baseConfig()
        let (patched, outcomes, planes) = try ConfigPatch.apply(
            ["definitely_not_a_key": "42"], to: cfg)
        #expect(patched == cfg)
        #expect(outcomes[0].disposition == .unchanged)
        #expect(outcomes[0].effectiveValue == nil)
        #expect(!planes.dspLive && !planes.rdsLive && !planes.restartRequired)
    }

    @Test func sameValueReportsUnchanged() throws {
        let cfg = baseConfig()
        let (_, outcomes, planes) = try ConfigPatch.apply(
            ["output_gain_db": String(cfg.outputGainDB)], to: cfg)
        #expect(outcomes[0].disposition == .unchanged)
        #expect(!planes.dspLive)
    }

    @Test func multiKeyPatchClassifiesEachKey() throws {
        let cfg = baseConfig()
        let (patched, outcomes, planes) = try ConfigPatch.apply(
            [
                "output_gain_db": String(cfg.outputGainDB - 2.0),
                "ps_a": "WEBCTRL",
                "sample_rate": "96000",
            ], to: cfg)
        #expect(patched.sampleRate == 96000)
        let byKey = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.key, $0.disposition) })
        #expect(byKey["output_gain_db"] == .live)
        #expect(byKey["ps_a"] == .liveRDS)
        #expect(byKey["sample_rate"] == .restartRequired)
        #expect(planes.dspLive && planes.rdsLive && planes.restartRequired)
    }

    @Test func sectionedValuesExposesAllSections() throws {
        let sections = try ConfigPatch.sectionedValues(of: baseConfig())
        #expect(sections["MPX"]?["output_gain_db"] != nil)
        #expect(sections["RDS"]?["pi"] != nil)
        #expect(sections["INTERFACES"]?["sample_rate"] != nil)
    }

    @Test func clampingAppliesOnReload() throws {
        // Loading runs the same validators as a disk load; out-of-range PTY
        // must come back clamped, not raw.
        let cfg = baseConfig()
        let (patched, _, _) = try ConfigPatch.apply(["pty": "99"], to: cfg)
        #expect(patched.rdsPTY <= 31)
    }
}
