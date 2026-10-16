// macOS-only: builds SwiftUI page bodies, which the Linux build excludes.
#if os(macOS)

import Foundation
import SwiftUI
import Testing

@testable import MPXPrime

/// Builds page bodies headlessly (no window, no engine) with the setting
/// audit on, and holds every control's declared disposition -- the value that
/// draws its restart badge and decides whether a change restarts the engine
/// -- against the engine-derived classification (`RestartClassKeys`).
@MainActor
enum LayoutAudit {
    static func model(_ mode: AppConfig.OperatingMode = .mpx, advancedDynamics: Bool? = nil) -> MPXPrimeViewModel {
        let m = MPXPrimeViewModel(
            configPath: NSTemporaryDirectory() + "MPXPrime-LayoutAudit-\(UUID().uuidString).ini",
            deviceLister: { [] })
        m.config.operatingMode = mode
        if let advancedDynamics { m.config.advancedDynamicsEnabled = advancedDynamics }
        return m
    }

    /// Runs `build` (which evaluates page bodies) and returns every
    /// mismatch as "property (key): declared X, engine Y".
    static func mismatches(_ build: () -> Void) -> (checked: Int, problems: [String]) {
        SettingAudit.reset()
        SettingAudit.isRecording = true
        build()
        SettingAudit.isRecording = false
        var problems: [String] = []
        var checked = 0
        for entry in SettingAudit.entries {
            let keys = entry.iniKeys()
            if keys.isEmpty {
                problems.append("\(entry.name): no INI key found")
                continue
            }
            for key in keys {
                guard let derived = RestartClassKeys.guiDisposition(of: key) else { continue }
                checked += 1
                if derived != entry.disposition {
                    problems.append("\(entry.name) (\(key)): declared \(entry.disposition), engine \(derived)")
                }
            }
        }
        SettingAudit.reset()
        return (checked, problems)
    }
}

@Suite("Layout: restart badges follow the engine", .serialized)
@MainActor
struct LayoutRestartBadgeTests {

    @Test func soundPagesDeclareTheEnginesDisposition() {
        var total = 0
        for mode in AppConfig.OperatingMode.allCases {
            for advanced in [false, true] {
                let m = LayoutAudit.model(mode, advancedDynamics: advanced)
                let result = LayoutAudit.mismatches {
                    _ = ProcessingCoreTab(model: m).body
                    _ = ProcessingPhaseRotatorTab(model: m).body
                    _ = ProcessingAGCTab(model: m).body
                    _ = ProcessingParametricEQTab(model: m).body
                    _ = ProcessingMultibandTab(model: m).body
                    _ = ProcessingAdvancedDynamicsTab(model: m).body
                    _ = ProcessingExpanderTab(model: m).body
                    _ = ProcessingMultibandLimiterTab(model: m).body
                    _ = ProcessingPrimeBassTab(model: m).body
                    _ = ProcessingBassClipperTab(model: m).body
                    _ = ProcessingDCClipperTab(model: m).body
                    _ = ProcessingHFLimiterTab(model: m).body
                    _ = ProcessingLimiterTab(model: m).body
                    _ = ProcessingStereoCoderTab(model: m).body
                    _ = ProcessingCompositeClipperTab(model: m).body
                    _ = ProcessingBS412Tab(model: m).body
                    _ = ProcessingFinalStageTab(model: m).body
                }
                total += result.checked
                #expect(result.problems.isEmpty, "\(mode.title): \(result.problems)")
                m.shutdown()
            }
        }
        #expect(total > 100, "expected the Sound pages to declare their settings; checked \(total)")
    }

    @Test func theRestartListIsDerivedAndHonest() {
        let list = RestartClassKeys.all
        // Engine structure needs a restart...
        for key in ["sample_rate", "blocksize", "preemphasis_us", "encoder_fir_enabled", "rds_level"] {
            #expect(list.contains(key), "\(key) should need a restart")
        }
        // ...the listening monitor, the pilot and the deviation do not (the
        // hand-written list said monitor routing did; the Pilot Level slider
        // carried a restart badge), and labels or launch-time keys are not
        // engine restarts at all.
        for key in ["monitor_enabled", "monitor_gain_db", "pilot_level", "mpx_deviation_khz",
                    "format_profile_id", "control_port", "now_playing_script", "pin_day"] {
            #expect(!list.contains(key), "\(key) does not need an engine restart")
        }
        #expect(!list.contains { $0.hasPrefix("monitor") })
    }

    @Test func noPageBindsConfigWithoutDeclaringItsDisposition() throws {
        // Every page binds through `setting()` (badge derived, audit
        // recorded); a bare `configBinding` would bypass both, as all but a
        // handful of controls did before.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/MPXPrime")
        var files = try FileManager.default.contentsOfDirectory(atPath: sources.appendingPathComponent("UI").path)
            .filter { $0.hasSuffix(".swift") && $0 != "SharedControls.swift" }
            .map { sources.appendingPathComponent("UI/\($0)") }
        files += try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasPrefix("UI") && $0.hasSuffix(".swift") }
            .map { sources.appendingPathComponent($0) }
        #expect(files.count > 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("configBinding("), "\(file.lastPathComponent) binds config without setting()")
            #expect(!text.contains("RestartBadge()"), "\(file.lastPathComponent) places a restart badge by hand")
        }
    }

    @Test func theFastClassifierAgreesWithTheAPIClassifier() throws {
        // RestartClassKeys classifies in memory; ConfigPatch.apply (the REST
        // API's classifier) round-trips through an INI file. Same answer.
        let base = AppConfig()
        let cases: [(String, String)] = [
            ("sample_rate", "96000"), ("preemphasis_us", "75"), ("pilot_level", "0.085"),
            ("mpx_deviation_khz", "70.0"), ("rds_level", "3.0"), ("ps_frame_seconds", "4.0"),
            ("multiband_mode", "3"), ("hpf_hz", "40.0"), ("monitor_enabled", "True")
        ]
        for (key, value) in cases {
            let api = try ConfigPatch.apply([key: value], to: base).outcomes.first?.disposition
            #expect(RestartClassKeys.disposition(of: key) == api, "\(key)")
        }
    }
}

#endif  // os(macOS)
