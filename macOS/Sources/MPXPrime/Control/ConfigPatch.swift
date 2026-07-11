import Foundation

// Config patching for the remote-control API.
//
// The INI vocabulary is the public config language (docs/manual.md documents
// every key), so the API patches configs BY INI KEY with zero per-key mapping
// code: serialize the current AppConfig to INI text (captureAsINIString),
// inject the patched keys into every section, and reload through the
// existing parser -- missing-key defaults, validators, and clamps apply
// exactly as a normal disk load. Injecting into all sections is safe because
// AppConfig's readers are section-specific; the few keys read from two
// sections (source_mode, en_rds) have the same meaning in both.
//
// Live-vs-restart classification is DERIVED, not tabulated: a changed key is
// live if flipping it (alone) moves MPXGenerator.RuntimeConfig, live-RDS if
// it moves MPXGenerator.RDSRuntimeConfig, and restart-required otherwise.
// The two runtime structs are the existing single source of truth for what
// the engine can hot-apply (AudioOutputEngine.applyRuntimeConfig /
// applyRDSRuntimeConfig consume exactly these), so the API can never drift
// from the engine's actual live-apply ability.

/// Which planes a config change touches.
struct ConfigChangePlanes {
    var dspLive = false
    var rdsLive = false
    var restartRequired = false
}

/// Per-key application outcome, reported back to the API caller.
struct ConfigKeyOutcome: Codable, Equatable {
    enum Disposition: String, Codable {
        case live            // hot-applied to the DSP plane
        case liveRDS         // hot-applied to the RDS plane
        case restartRequired // stored; takes effect on next engine start
        case unchanged       // value identical, or unknown key (no effect)
    }
    var key: String
    var disposition: Disposition
    /// The effective value after apply (post-clamp/parse), from the
    /// re-serialized config; nil when the key is unknown to the INI schema.
    var effectiveValue: String?
}

enum ConfigPatchError: Error, CustomStringConvertible {
    case serializationFailed(String)

    var description: String {
        switch self {
        case .serializationFailed(let why):
            return "config serialization failed: \(why)"
        }
    }
}

enum ConfigPatch {
    /// All keys the INI schema knows, grouped by section, with current
    /// effective values -- the GET /api/config payload.
    static func sectionedValues(of config: AppConfig) throws -> [String: [String: String]] {
        let ini: String
        do {
            ini = try config.captureAsINIString()
        } catch {
            throw ConfigPatchError.serializationFailed(String(describing: error))
        }
        return INIParser.parse(ini)
    }

    /// Apply `patch` (INI key -> raw string value) to `config`. Returns the
    /// patched config plus per-key outcomes. Keys the schema does not read
    /// come back `.unchanged` with a nil effective value.
    static func apply(
        _ patch: [String: String], to config: AppConfig
    ) throws -> (config: AppConfig, outcomes: [ConfigKeyOutcome], planes: ConfigChangePlanes) {
        let baseINI: String
        do {
            baseINI = try config.captureAsINIString()
        } catch {
            throw ConfigPatchError.serializationFailed(String(describing: error))
        }

        let patched = try reload(baseINI: baseINI, overlay: patch)

        var outcomes: [ConfigKeyOutcome] = []
        var planes = ConfigChangePlanes()
        let patchedSections = INIParser.parse(
            (try? patched.captureAsINIString()) ?? baseINI)

        for key in patch.keys.sorted() {
            let effective = effectiveValue(forKey: key, in: patchedSections)
            // Classify by flipping ONLY this key against the ORIGINAL config.
            let solo = try reload(baseINI: baseINI, overlay: [key: patch[key] ?? ""])
            let disposition: ConfigKeyOutcome.Disposition
            if solo == config {
                disposition = .unchanged
            } else if MPXGenerator.makeRuntimeConfig(from: solo)
                != MPXGenerator.makeRuntimeConfig(from: config) {
                disposition = .live
                planes.dspLive = true
            } else if MPXGenerator.RDSRuntimeConfig.make(from: solo)
                != MPXGenerator.RDSRuntimeConfig.make(from: config) {
                disposition = .liveRDS
                planes.rdsLive = true
            } else {
                disposition = .restartRequired
                planes.restartRequired = true
            }
            outcomes.append(ConfigKeyOutcome(
                key: key, disposition: disposition, effectiveValue: effective))
        }
        // A key can move BOTH planes (e.g. en_rds gates RDSRuntimeConfig.enabled
        // and RuntimeConfig carries no RDS fields -- but keep the combined
        // check honest): recompute the aggregate planes from the full patch
        // so multi-key interactions are not missed.
        if MPXGenerator.makeRuntimeConfig(from: patched)
            != MPXGenerator.makeRuntimeConfig(from: config) {
            planes.dspLive = true
        }
        if MPXGenerator.RDSRuntimeConfig.make(from: patched)
            != MPXGenerator.RDSRuntimeConfig.make(from: config) {
            planes.rdsLive = true
        }
        return (patched, outcomes, planes)
    }

    /// Rebuild an AppConfig from `baseINI` with `overlay` keys appended to
    /// every section (last-wins within a section in INIParser).
    private static func reload(baseINI: String, overlay: [String: String]) throws -> AppConfig {
        var sections = INIParser.parse(baseINI)
        for (section, var bucket) in sections {
            for (k, v) in overlay {
                bucket[k] = v
            }
            sections[section] = bucket
        }
        var text = ""
        // Deterministic dump; the empty pre-section bucket goes first.
        for section in sections.keys.sorted() {
            guard let bucket = sections[section] else { continue }
            if !section.isEmpty {
                text += "[\(section)]\n"
            }
            for k in bucket.keys.sorted() {
                text += "\(k) = \(bucket[k] ?? "")\n"
            }
        }
        return try AppConfig.loadFromINIString(text)
    }

    private static func effectiveValue(
        forKey key: String, in sections: [String: [String: String]]
    ) -> String? {
        for (_, bucket) in sections {
            if let v = bucket[key] { return v }
        }
        return nil
    }
}
