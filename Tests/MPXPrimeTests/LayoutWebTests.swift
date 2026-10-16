import Foundation
import Testing

@testable import MPXPrime

// The web dashboard's half of the UI layout review (2026-10, WP6): the schema
// encodes the same decisions as the native app, so the two surfaces name,
// place and scale every control alike. Before: Bands offered 2-band in the
// app only, pilot and RDS injection sat on two pages each, Composite
// Deviation lived on Loudness and Output, both limiter thresholds read as a
// bare 0.950, the time zone moved in half hours, and the labels differed
// ("Platform Target", "HPF", "Program Lowpass", "96 kHz Window").
@Suite("Layout: web dashboard schema")
struct LayoutWebTests {

    private struct Loaded {
        var widgets: [String: [String: Any]]
        var pages: [String: [String: Any]]
    }

    private func load() throws -> Loaded {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MPXPrime/Control/WebUI/schema.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]
        let model = root["model"] as? [String: Any] ?? [:]
        var pages: [String: [String: Any]] = [:]
        for list in ["stages", "rds", "tools"] {
            for page in model[list] as? [[String: Any]] ?? [] {
                if let id = page["id"] as? String { pages[id] = page }
            }
        }
        return Loaded(widgets: root["schema"] as? [String: [String: Any]] ?? [:], pages: pages)
    }

    /// Every key a page shows, from keys, keys2 and cards.
    private func keys(of page: [String: Any]) -> Set<String> {
        var out = Set(page["keys"] as? [String] ?? [])
        if let k2 = page["keys2"] as? [String: Any] { out.formUnion(k2["keys"] as? [String] ?? []) }
        for card in page["cards"] as? [[String: Any]] ?? [] { out.formUnion(card["keys"] as? [String] ?? []) }
        return out
    }

    private func homes(of key: String, in s: Loaded) -> [String] {
        s.pages.filter { keys(of: $0.value).contains(key) }.map(\.key).sorted()
    }

    @Test func multibandOffersThreeOrFiveBandsOnly() throws {
        let s = try load()
        let options = s.widgets["multiband_mode"]?["options"] as? [[String]] ?? []
        #expect(options.map { $0[0] } == ["3", "5"])
        #expect(options.map { $0[1] } == ["3 Bands", "5 Bands"])
        #expect(s.widgets["multiband_mode"]?["label"] as? String == "Bands")
    }

    @Test func everyKeyHasOneHome() throws {
        let s = try load()
        #expect(homes(of: "rds_level", in: s) == ["rdsSubcarrier"])
        #expect(homes(of: "pilot_level", in: s) == ["stereoCoder"])
        #expect(homes(of: "mpx_deviation_khz", in: s) == ["interfaces"])
        #expect(s.widgets["mpx_deviation_khz"]?["modes"] as? [String] == ChainFeature.finalStage.modes)
        #expect(homes(of: "preemphasis_us", in: s) == ["interfaces"])
        #expect(homes(of: "encoder_fir_enabled", in: s) == ["interfaces"])
        #expect(homes(of: "multiband_fir_enabled", in: s) == ["interfaces"])
        #expect(homes(of: "ps_long_32", in: s) == ["rdsIdentity"])
        // Bypass is the status-strip button, not a Basics control.
        #expect(homes(of: "processing_bypass", in: s).isEmpty)
        #expect(s.pages["profile"] == nil && s.pages["rdsLongPS"] == nil)
    }

    @Test func limiterThresholdsReadInDBFS() throws {
        let s = try load()
        for key in ["pre_encode_threshold", "limit_threshold"] {
            let w = try #require(s.widgets[key])
            #expect(w["transform"] as? String == "db20", "\(key)")
            #expect(w["unit"] as? String == " dBFS", "\(key)")
        }
    }

    @Test func outputLevelRangeFollowsTheMode() throws {
        let s = try load()
        let w = try #require(s.widgets["output_gain_db"])
        #expect(w["label"] as? String == "Output Level")
        #expect((w["min"] as? NSNumber)?.doubleValue == -18 && (w["max"] as? NSNumber)?.doubleValue == 18)
        let variants = w["variants"] as? [[String: Any]] ?? []
        #expect(variants.count == 1)
        #expect(variants.first?["modes"] as? [String] == ["mpx"])
        #expect(variants.first?["label"] as? String == "MPX Output Level")
        #expect((variants.first?["max"] as? NSNumber)?.doubleValue == 0)
    }

    @Test func timeZoneIsAMenuInQuarterHours() throws {
        let s = try load()
        let w = try #require(s.widgets["tz_offset"])
        #expect(w["kind"] as? String == "seg" && w["style"] as? String == "menu")
        let options = w["options"] as? [[String]] ?? []
        let values = options.compactMap { Double($0[0]) }
        #expect(values.first == -12 && values.last == 14 && values.count == 105)
        #expect(zip(values, values.dropFirst()).allSatisfy { abs($1 - $0 - 0.25) < 1e-9 })
        #expect(options.first { $0[0] == "1" }?[1] == "UTC+01:00")
        #expect(options.first { $0[0] == "-3.5" }?[1] == "UTC-03:30")
    }

    @Test func rangesAndUnitsMatchTheApp() throws {
        let s = try load()
        let num = { (k: String, f: String) in (s.widgets[k]?[f] as? NSNumber)?.doubleValue }
        #expect(num("ps_frame_seconds", "min") == 0.5 && num("ps_frame_seconds", "max") == 30)
        #expect(num("rt_cycle_time", "min") == 1 && num("rt_cycle_time", "max") == 60)
        #expect(num("rds_level", "max") == 7.5)
        #expect(s.widgets["rds_level"]?["unit"] as? String == " kHz")
        #expect(s.widgets["rds_level"]?["readout2"] != nil, "RDS injection shows its percent too")
        for key in ["primebass_amount", "primebass_harmonics", "primebass_drive", "primebass_density",
                    "primebass_subharmonics_amount", "multiband_link_strength", "mpx_ssb_stereo_amount",
                    "mpx_clipper_stereo_guard", "advanced_dynamics_density", "bass_clipper_drive"] {
            #expect(num(key, "scale") == 100, "\(key) shows as percent")
            #expect(s.widgets[key]?["unit"] as? String == "%", "\(key)")
        }
    }

    @Test func labelsMatchTheApp() throws {
        // The app's labels (UI layout review shared label list). One name per
        // control on both surfaces; British spelling; Title Case.
        let expected: [String: String] = [
            "mono_mode": "Mono Mode", "hpf_hz": "High-Pass Filter", "hf_trim_db": "HF Trim",
            "hf_trim_hz": "HF Trim Frequency", "program_lowpass_hz": "Programme Lowpass",
            "wideband_agc_enabled": "Enable AGC", "wideband_agc_target_db": "Target Level",
            "wideband_agc_k_weighting": "K-Weighted Detector",
            "wideband_agc_release_program_dependent": "Programme-Dependent Release",
            "wideband_agc_bass_desensitize": "Ignore Bass in Detector",
            "primebass_enabled": "Enable PrimeBass", "primebass_amount": "Amount",
            "primebass_subharmonics_enabled": "Enable Subharmonics",
            "primebass_subharmonics_amount": "Subharmonic Amount",
            "mono_bass_enabled": "Enable Mono Bass", "mono_bass_freq_hz": "Mono Below",
            "multiband_enabled": "Enable Multiband", "multiband_makeup_db": "Makeup",
            "multiband_knee_db": "Knee", "multiband_link_strength": "Stereo Link",
            "multiband_release_program_dependent": "Programme-Dependent Release",
            "multiband_transient_aware_attack_enabled": "Transient-Aware Attack",
            "multiband_inter_band_coupling_enabled": "Inter-Band Coupling",
            "multiband_limiter_enabled": "Enable Band Limiter",
            "pre_encode_limiter_enabled": "Enable Audio Limiter", "pre_encode_lookahead_ms": "Look-Ahead",
            "pre_encode_bandlimited_residual_enabled": "Reduce Clipping Distortion",
            "pre_encode_lookahead_hf_only": "Look-Ahead on HF Transients Only",
            "pre_encode_lookahead_hf_cutoff_hz": "HF Detector Cutoff",
            "dc_clipper_ceiling_db": "Ceiling", "dc_clipper_cancel_freq_hz": "Cancellation Frequency",
            "pilot_level": "Pilot Level", "mpx_ssb_stereo_enabled": "Enable SSB Stereo",
            "mpx_ssb_stereo_amount": "SSB Amount", "mpx_clipper_lookahead_ms": "Look-Ahead",
            "mpx_clipper_oversampling": "Oversampling", "mpx_clipper_cancel_audio": "Protect Audio Highs",
            "mpx_clipper_cancel_pilot": "Protect Stereo Pilot",
            "mpx_clipper_stereo_guard": "Protect Stereo Subcarrier", "mpx_clipper_cancel_rds": "Protect RDS",
            "final_drive_db": "Final Drive", "limit_mpx": "Enable Safety Limiter",
            "limit_lookahead_enabled": "Enable Look-Ahead", "limit_lookahead_ms": "Look-Ahead",
            "encoder_fir_enabled": "Encoder Lowpass", "multiband_fir_enabled": "Multiband Crossovers",
            "fft_window_92khz": "96 kHz Spectrum", "test_tone_level_db": "Tone Level",
            "tz_offset": "Time Zone", "ps_frame_seconds": "PS Frame Time", "rt_cycle_time": "Cycle Time"
        ]
        let s = try load()
        for (key, label) in expected {
            #expect(s.widgets[key]?["label"] as? String == label, "\(key)")
        }
        for key in ["encoder_fir_enabled", "multiband_fir_enabled"] {
            #expect(s.widgets[key]?["options"] as? [[String]] == [["True", "Linear Phase"], ["False", "Low Latency"]])
        }
    }

    @Test func everyWidgetStringIsPlainASCII() throws {
        let s = try load()
        for (key, w) in s.widgets {
            for field in ["label", "help", "unit"] {
                guard let text = w[field] as? String else { continue }
                let ascii = text.unicodeScalars.allSatisfy { $0.isASCII }
                #expect(ascii, "\(key).\(field)")
            }
        }
    }
}
