import Foundation
import Testing

@testable import MPXPrime

// Pins the served dashboard schema (Control/WebUI/schema.json) against the
// INI vocabulary, in BOTH directions. This is the drift-killer: before it,
// index.html hand-maintained the widget table and silently dropped any page
// key without one (10 controls were missing this way -- the test tone had no
// frequency or level slider), and the schema could reference keys the config
// never reads. Now:
//
//   - a NEW config key cannot ship without a schema decision (add a widget,
//     or add the key to `deliberatelyUnexposed` with a reason), and
//   - a schema entry cannot reference a nonexistent key (a typo becomes a
//     red test instead of a silent no-op patch).
//
// The schema file itself is the single source of truth for the dashboard --
// served by GET /api/schema, consumed at boot; index.html carries no copy.
@Suite("Control schema vs INI vocabulary")
struct ControlSchemaTests {

    /// INI keys with NO dashboard widget, each with the reason. Additions
    /// here are a deliberate decision, reviewed like code.
    private static let deliberatelyUnexposed: [String: String] = [
        // RDS physical layer the native GUI also hides (docs call them
        // INI-only; restart-required modulator internals).
        // Written by the card-mixer API (PATCH /api/mixer records the level
        // the card took), asserted by the engine; a direct config patch of a
        // dB the card cannot represent would be worse than no control.
        "alsa_playback_volume_db": "set through PATCH /api/mixer, not as a widget",
        "alsa_capture_volume_db": "set through PATCH /api/mixer, not as a widget",
        "rds_gaussian_enabled": "GUI hides it too; modulator internal",
        "rds_gaussian_bw_hz": "GUI hides it too; modulator internal",
        "rds_gaussian_taps": "GUI hides it too; modulator internal",
        // Remote-control plumbing: editing the server's own bind/port/key
        // from the page it serves is a lockout footgun. Read-only display
        // is planned (Phase 2); patching stays INI/GUI-only.
        "control_enabled": "self-referential; lockout risk",
        "control_bind": "self-referential; lockout risk",
        "control_port": "self-referential; lockout risk",
        "control_api_key": "secret; must never round-trip to a browser",
        // Device selection is a special UI (the Interfaces page renders
        // <select>s from /api/devices and patches the *_uid keys); a plain
        // text widget would invite typo'd UIDs. The *_name keys are derived
        // mirrors, not controls.
        "input_device_uid": "patched by the Interfaces device picker",
        "output_device_uid": "patched by the Interfaces device picker",
        "monitor_device_uid": "patched by the Interfaces device picker",
        "input_device_name": "derived mirror of input_device_uid",
        "output_device_name": "derived mirror of output_device_uid",
        "monitor_device_name": "derived mirror of monitor_device_uid",
        // Engine internals no remote operator should steer.
        "monitor_rate_hz": "engine internal; monitor path only",
        "dual_rate_audio_domain_enabled": "experimental engine internal",
        "dual_rate_audio_domain_rate_hz": "experimental engine internal",
        // Preset/profile LABELS: written by POST /api/presets applies (and
        // the GUI's pickers); patching the id alone performs no fan-out, so
        // a text widget would be a lie. Intensity rides the preset API's
        // `intensity` parameter.
        "multiband_preset_id": "label written by preset applies",
        "multiband_intensity": "set via POST /api/presets intensity",
        "primebass_preset_id": "label written by preset applies",
        "final_stage_preset_id": "label written by preset applies",
        "format_profile_id": "label written by profile applies",
    ]

    /// Widget kinds the dashboard's factories implement (index.html).
    private static let knownKinds: Set<String> = [
        "toggle", "slider", "seg", "number", "text"
    ]

    private struct LoadedSchema {
        var widgets: [String: [String: Any]]
        var modelKeys: Set<String>   // every key referenced by any page/card
    }

    private func loadSchema() throws -> LoadedSchema {
        // Read the resource from the source tree (tests run from the repo).
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MPXPrimeTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macOS
            .appendingPathComponent("Sources/MPXPrime/Control/WebUI/schema.json")
        let data = try Data(contentsOf: path)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let widgets = root["schema"] as? [String: [String: Any]] ?? [:]
        var modelKeys = Set<String>()
        func collect(_ page: [String: Any]) {
            for k in (page["keys"] as? [String]) ?? [] { modelKeys.insert(k) }
            if let k2 = page["keys2"] as? [String: Any] {
                for k in (k2["keys"] as? [String]) ?? [] { modelKeys.insert(k) }
            }
            if let enable = page["enable"] as? String { modelKeys.insert(enable) }
            for card in (page["cards"] as? [[String: Any]]) ?? [] {
                for k in (card["keys"] as? [String]) ?? [] { modelKeys.insert(k) }
            }
        }
        let model = root["model"] as? [String: Any] ?? [:]
        for group in ["stages", "rds", "tools"] {
            for page in (model[group] as? [[String: Any]]) ?? [] { collect(page) }
        }
        return LoadedSchema(widgets: widgets, modelKeys: modelKeys)
    }

    /// Every key the INI schema reads/writes, from the same serialization the
    /// config API uses.
    private func iniVocabulary() throws -> Set<String> {
        let sections = try ConfigPatch.sectionedValues(of: AppConfig())
        return Set(sections.values.flatMap { $0.keys })
    }

    /// The dashboard's sections and Sound groups are the Swift tables
    /// (`NavigationSection`, `StageGroup`) written out -- same ids, titles,
    /// order and page lists -- so the two sidebars can never drift apart, and
    /// every page the model knows has exactly one home.
    /// The dashboard folds exactly the controls `AdvancedControls.keys` names
    /// (and the GUI tabs follow that list by hand): a flag on a widget the
    /// table does not know, or a table entry the schema lacks, is a drift.
    @Test func advancedFlagsMirrorTheSharedTable() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MPXPrime/Control/WebUI/schema.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]
        let schema = root["schema"] as? [String: [String: Any]] ?? [:]
        let flagged = Set(schema.filter { ($0.value["advanced"] as? Bool) == true }.keys)
        #expect(flagged == AdvancedControls.keys,
                "schema-only: \(flagged.subtracting(AdvancedControls.keys).sorted()); table-only: \(AdvancedControls.keys.subtracting(flagged).sorted())")
        for key in AdvancedControls.keys {
            #expect(schema[key] != nil, "AdvancedControls names unknown key \(key)")
        }
    }

    @Test func sectionsMirrorTheSharedNavigationTable() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MPXPrime/Control/WebUI/schema.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]
        let model = root["model"] as? [String: Any] ?? [:]
        let sections = model["sections"] as? [[String: Any]] ?? []
        #expect(sections.map { $0["id"] as? String } == NavigationSection.allCases.map(\.rawValue))
        #expect(sections.map { $0["title"] as? String } == NavigationSection.allCases.map(\.title))

        let sound = sections.first { $0["id"] as? String == "sound" } ?? [:]
        #expect(sound["pages"] as? [String] == StageGroup.soundLandingPageIDs)
        let groups = sound["groups"] as? [[String: Any]] ?? []
        #expect(groups.map { $0["id"] as? String } == StageGroup.allCases.map(\.rawValue))
        #expect(groups.map { $0["title"] as? String } == StageGroup.allCases.map(\.title))
        #expect(groups.map { $0["pages"] as? [String] ?? [] } == StageGroup.allCases.map(\.pageIDs))

        var homes: [String: Int] = [:]
        for sec in sections {
            for id in sec["pages"] as? [String] ?? [] { homes[id, default: 0] += 1 }
            for g in sec["groups"] as? [[String: Any]] ?? [] {
                for id in g["pages"] as? [String] ?? [] { homes[id, default: 0] += 1 }
            }
        }
        var known = ["monitoring", "overview"]
        for list in ["stages", "rds", "tools"] {
            known += (model[list] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        for id in known {
            #expect(homes[id] == 1, "page \(id) sits in \(homes[id] ?? 0) sections/groups")
        }
        for id in homes.keys where !known.contains(id) {
            Issue.record("sections name an unknown page \(id)")
        }
        // Every stage page is in a Sound group and every group id names a stage page.
        let stageIDs = Set((model["stages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let grouped = Set(StageGroup.allCases.flatMap(\.pageIDs)).union(StageGroup.soundLandingPageIDs)
        #expect(stageIDs.isSubset(of: grouped), "stages without a group: \(stageIDs.subtracting(grouped).sorted())")
        // And the GUI can reach every one of them.
        for id in StageGroup.allCases.flatMap(\.pageIDs) {
            #expect(Stage.stage(forSchemaPage: id) != nil, "no GUI stage for dashboard page \(id)")
        }
    }

    @Test func everyINIKeyHasASchemaDecision() throws {
        let schema = try loadSchema()
        let vocabulary = try iniVocabulary()
        let undecided = vocabulary
            .subtracting(schema.widgets.keys)
            .subtracting(Self.deliberatelyUnexposed.keys)
            .sorted()
        #expect(undecided.isEmpty,
                "INI keys without a schema widget or an explicit exemption: \(undecided)")
    }

    @Test func everySchemaKeyExistsInTheINIVocabulary() throws {
        // The inverse direction: a schema entry for a nonexistent key would
        // render a control whose PATCH is a silent no-op.
        let schema = try loadSchema()
        let vocabulary = try iniVocabulary()
        let phantoms = Set(schema.widgets.keys).subtracting(vocabulary).sorted()
        #expect(phantoms.isEmpty,
                "schema widgets for keys the config never reads: \(phantoms)")
    }

    @Test func everyModelKeyHasAWidget() throws {
        // The exact failure mode controlFor() used to hide: a page listing a
        // key with no widget silently rendered nothing.
        let schema = try loadSchema()
        let dropped = schema.modelKeys.subtracting(schema.widgets.keys).sorted()
        #expect(dropped.isEmpty,
                "page keys without a widget (would render as nothing): \(dropped)")
    }

    @Test func everyModesListUsesTheOperatingModeVocabulary() throws {
        // A typo in a `modes` list hides a control forever, silently, in one
        // mode only -- the kind of defect nobody finds by clicking around.
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MPXPrime/Control/WebUI/schema.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]
        let valid = Set(AppConfig.OperatingMode.allCases.map(\.rawValue))
        var checked = 0

        func check(_ modes: Any?, _ owner: String) {
            guard let modes = modes as? [String] else { return }
            checked += 1
            #expect(!modes.isEmpty, "\(owner) carries an empty modes list, so it can never be shown")
            let unknown = Set(modes).subtracting(valid).sorted()
            #expect(unknown.isEmpty, "\(owner) lists unknown operating modes: \(unknown)")
        }

        let model = root["model"] as? [String: Any] ?? [:]
        check(model["rdsModes"], "model.rdsModes")
        check(model["monitorModes"], "model.monitorModes")
        for page in (model["stages"] as? [[String: Any]] ?? []) {
            check(page["modes"], "stage \(page["id"] ?? "?")")
        }
        for (key, widget) in (root["schema"] as? [String: [String: Any]] ?? [:]) {
            check(widget["modes"], "widget \(key)")
        }
        #expect(checked > 5, "expected the mode gating to be present in the schema; checked \(checked)")
    }

    @Test func modeGatedWidgetsMatchTheChainFeatureTable() throws {
        // The dashboard and the native GUI must hide the same things: the
        // schema's `modes` lists are the web copy of `ChainFeature`, so they
        // are compared against it rather than maintained by eye.
        let schema = try loadSchema()
        let expected: [String: ChainFeature] = [
            "preemphasis_us": .preemphasis,
            "processed_audio_ceiling_dbtp": .digitalCeiling,
            "processed_audio_coder_has_clipper": .coderFinalClipper,
            "processed_audio_final_clip_drive_db": .coderFinalClipper,
            "am_preemphasis_us": .amShaping,
            "am_lowpass_hz": .amShaping,
            "am_positive_peak_pct": .amShaping,
            "monitor_enabled": .monitorPath,
            "mono_mode": .stereoProgram,
            "mono_bass_enabled": .stereoProgram,
            "mono_bass_freq_hz": .stereoProgram,
            "multiband_link_strength": .stereoProgram,
            "hf_limiter_enabled": .hfLimiter,
            "hf_limiter_threshold_db": .hfLimiter,
            "hf_limiter_attack_ms": .hfLimiter,
            "hf_limiter_release_ms": .hfLimiter,
            "hf_limiter_max_reduction_db": .hfLimiter
        ]
        let everyMode = AppConfig.OperatingMode.allCases.map(\.rawValue)
        for (key, feature) in expected {
            // An ABSENT `modes` list means "every mode" to the page, so that is
            // what a feature applying everywhere must look like -- spelling all
            // four out would be the same thing, but the page would then have to
            // be edited whenever a mode is added.
            let modes = schema.widgets[key]?["modes"] as? [String] ?? everyMode
            #expect(modes == feature.modes,
                    "widget \(key) is gated to \(modes) but \(feature) applies in \(feature.modes)")
        }
    }

    @Test func modeGatedPagesMatchTheChainFeatureTable() throws {
        // Page-level gating is the same contract as widget-level gating: the
        // sidebar, the Overview grid and the Monitoring signal chain all read
        // it, so a page that disagrees with the table shows a stage the mode
        // does not run.
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MPXPrime/Control/WebUI/schema.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]
        let model = root["model"] as? [String: Any] ?? [:]
        let stages = model["stages"] as? [[String: Any]] ?? []
        let expected: [String: ChainFeature] = [
            "stereoCoder": .stereoCoder,
            "compositeClipper": .compositeClipper,
            "bs412": .bs412,
            "finalStage": .finalStage,
            "hfLimiter": .hfLimiter
        ]
        for stage in stages {
            let id = stage["id"] as? String ?? "?"
            let modes = stage["modes"] as? [String] ?? []
            if let feature = expected[id] {
                #expect(modes == feature.modes,
                        "stage page \(id) is gated to \(modes) but \(feature) applies in \(feature.modes)")
            } else {
                #expect(modes.isEmpty, "stage page \(id) carries modes \(modes) with no feature behind it")
            }
        }
        // The model-level lists the page reads for whole sections.
        #expect(model["rdsModes"] as? [String] == ChainFeature.rds.modes)
        #expect(model["monitorModes"] as? [String] == ChainFeature.monitorPath.modes)
        #expect(model["compositeModes"] as? [String] == ChainFeature.finalStage.modes)
    }

    @Test func everyWidgetHasAValidKindAndSliderBounds() throws {
        let schema = try loadSchema()
        for (key, w) in schema.widgets {
            let kind = w["kind"] as? String ?? ""
            #expect(Self.knownKinds.contains(kind), "\(key): unknown kind '\(kind)'")
            if kind == "slider" {
                let lo = (w["min"] as? NSNumber)?.doubleValue
                let hi = (w["max"] as? NSNumber)?.doubleValue
                #expect(lo != nil && hi != nil && lo! < hi!,
                        "\(key): slider needs min < max")
            }
            if kind == "seg" {
                let options = w["options"] as? [[String]] ?? []
                #expect(options.count >= 2, "\(key): seg needs >= 2 options")
            }
        }
    }

    @Test func exemptionListStaysHonest() throws {
        // An exemption for a key that no longer exists (or that someone later
        // added a widget for) is stale and must be removed.
        let schema = try loadSchema()
        let vocabulary = try iniVocabulary()
        for key in Self.deliberatelyUnexposed.keys {
            #expect(vocabulary.contains(key), "stale exemption (key gone): \(key)")
            #expect(schema.widgets[key] == nil,
                    "exemption AND widget both present: \(key)")
        }
    }
}
