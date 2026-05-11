import Foundation

// MARK: - Baseline data model
//
// Stored verifier baselines snapshot the per-scenario measurements of a clean
// `--verify` run and let subsequent runs compare every metric against its
// stored value with a per-metric tolerance. The goal is to catch the class of
// silent regression where the top-level TIGHT/OK/WARN result looks unchanged
// but underlying numbers drift (e.g. `>60k/In` moving from -58 dB to -30 dB
// while pre-existing warnings mask the delta).
//
// The baseline file is human-readable JSON, pretty-printed with sorted keys
// so `git diff` is meaningful. Per-scenario entries are flat records of the
// metrics worth gating on.

/// Flat, Codable record of the metrics we gate on per scenario. Sourced from
/// `VerificationMetrics` and the config-level deviation target, but kept as
/// its own type so the baseline layer doesn't reach into private harness
/// structs.
struct VerifierBaselineRecord: Codable, Equatable {
    var peakDBFS: Float
    var deviationKHz: Float
    var limiterGRDB: Float
    var safetyGRDB: Float
    var audioCompositePeakDBFS: Float
    var postInjectionOvershoot: Float
    var overBudget: Bool
    var pilotPercent: Float
    var rdsPercent: Float
    var budgetMarginDB: Float
    var agcReductionDB: Float
    var inputCorrelation: Float
    var outputCorrelation: Float
    var inputSideToMid: Float
    var outputSideToMid: Float
    var rmsDeltaDB: Float
    var occupied999Hz: Float
    var above60kRatioDB: Float
    var above67kRatioDB: Float
}

struct VerifierBaselineFile: Codable, Equatable {
    var schemaVersion: Int
    var capturedAt: String
    var configPath: String
    var renderSampleRateHz: Int
    var blockSize: Int
    var durationSeconds: Double
    /// Dictionary keyed by scenario name → baseline record.
    var scenarios: [String: VerifierBaselineRecord]

    static let currentSchemaVersion: Int = 2
}

// MARK: - Tolerances
//
// Per-metric tolerance. Field names match `VerifierBaselineRecord`. Tuned to
// catch the regressions that burned us (0.00 → -0.37 dBFS peak, 2.8 → 0.0 dB
// LimGR, -58 → -30 dB above-60k ratio) while tolerating small floating-point
// jitter in metrics like AGC reduction and RMS delta.
struct MetricTolerances {
    var peakDBFS: Float = 0.10
    var deviationKHz: Float = 0.30
    var limiterGRDB: Float = 0.15
    var safetyGRDB: Float = 0.15
    var audioCompositePeakDBFS: Float = 0.10
    var postInjectionOvershoot: Float = 0.0001
    var pilotPercent: Float = 0.05
    var rdsPercent: Float = 0.05
    var budgetMarginDB: Float = 0.15
    var agcReductionDB: Float = 0.30
    var inputCorrelation: Float = 0.02
    var outputCorrelation: Float = 0.02
    var inputSideToMid: Float = 0.02
    var outputSideToMid: Float = 0.02
    var rmsDeltaDB: Float = 0.30
    var occupied999Hz: Float = 150.0
    var above60kRatioDB: Float = 1.0
    var above67kRatioDB: Float = 1.0

    static let `default` = MetricTolerances()
}

// MARK: - Comparison

/// One drift finding: which scenario, which metric, measured vs. baseline vs. tolerance.
struct BaselineDriftFinding {
    let scenarioName: String
    let metricName: String
    let measured: Float
    let baseline: Float
    let tolerance: Float
    let unit: String

    var formattedLine: String {
        let signStr = measured >= baseline ? "+" : ""
        let delta = measured - baseline
        return
            "\(scenarioName): \(metricName) measured \(fmt(measured)) \(unit), "
            + "baseline \(fmt(baseline)) \(unit) "
            + "(\(signStr)\(fmt(delta)) \(unit), tolerance ±\(fmt(tolerance)) \(unit))"
    }

    private func fmt(_ v: Float) -> String {
        if abs(v) >= 1000.0 { return String(format: "%.0f", v) }
        if abs(v) >= 100.0 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

/// Compare a set of measured per-scenario records against a stored baseline.
/// Returns a flat list of drift findings — one per metric that drifted beyond
/// tolerance, across all scenarios.
func compareBaseline(
    measured: [String: VerifierBaselineRecord],
    baseline: VerifierBaselineFile,
    tolerances: MetricTolerances = .default
) -> [BaselineDriftFinding] {
    var findings: [BaselineDriftFinding] = []

    // Ordered per-metric check so output is stable.
    struct Probe {
        let name: String
        let unit: String
        let tolerance: Float
        let get: (VerifierBaselineRecord) -> Float
    }
    let probes: [Probe] = [
        Probe(name: "peakDBFS", unit: "dBFS", tolerance: tolerances.peakDBFS, get: { $0.peakDBFS }),
        Probe(name: "deviationKHz", unit: "kHz", tolerance: tolerances.deviationKHz, get: { $0.deviationKHz }),
        Probe(name: "limiterGRDB", unit: "dB", tolerance: tolerances.limiterGRDB, get: { $0.limiterGRDB }),
        Probe(name: "safetyGRDB", unit: "dB", tolerance: tolerances.safetyGRDB, get: { $0.safetyGRDB }),
        Probe(name: "audioCompositePeakDBFS", unit: "dBFS", tolerance: tolerances.audioCompositePeakDBFS, get: { $0.audioCompositePeakDBFS }),
        Probe(name: "postInjectionOvershoot", unit: "", tolerance: tolerances.postInjectionOvershoot, get: { $0.postInjectionOvershoot }),
        Probe(name: "pilotPercent", unit: "%", tolerance: tolerances.pilotPercent, get: { $0.pilotPercent }),
        Probe(name: "rdsPercent", unit: "%", tolerance: tolerances.rdsPercent, get: { $0.rdsPercent }),
        Probe(name: "budgetMarginDB", unit: "dB", tolerance: tolerances.budgetMarginDB, get: { $0.budgetMarginDB }),
        Probe(name: "agcReductionDB", unit: "dB", tolerance: tolerances.agcReductionDB, get: { $0.agcReductionDB }),
        Probe(name: "inputCorrelation", unit: "", tolerance: tolerances.inputCorrelation, get: { $0.inputCorrelation }),
        Probe(name: "outputCorrelation", unit: "", tolerance: tolerances.outputCorrelation, get: { $0.outputCorrelation }),
        Probe(name: "inputSideToMid", unit: "", tolerance: tolerances.inputSideToMid, get: { $0.inputSideToMid }),
        Probe(name: "outputSideToMid", unit: "", tolerance: tolerances.outputSideToMid, get: { $0.outputSideToMid }),
        Probe(name: "rmsDeltaDB", unit: "dB", tolerance: tolerances.rmsDeltaDB, get: { $0.rmsDeltaDB }),
        Probe(name: "occupied999Hz", unit: "Hz", tolerance: tolerances.occupied999Hz, get: { $0.occupied999Hz }),
        Probe(name: "above60kRatioDB", unit: "dB", tolerance: tolerances.above60kRatioDB, get: { $0.above60kRatioDB }),
        Probe(name: "above67kRatioDB", unit: "dB", tolerance: tolerances.above67kRatioDB, get: { $0.above67kRatioDB }),
    ]

    // Report missing scenarios (new in measured, or dropped from baseline).
    let baselineNames = Set(baseline.scenarios.keys)
    let measuredNames = Set(measured.keys)
    for missing in baselineNames.subtracting(measuredNames).sorted() {
        findings.append(BaselineDriftFinding(
            scenarioName: missing,
            metricName: "<missing>",
            measured: 0.0, baseline: 0.0, tolerance: 0.0,
            unit: "scenario was in baseline but not measured this run"
        ))
    }
    for added in measuredNames.subtracting(baselineNames).sorted() {
        findings.append(BaselineDriftFinding(
            scenarioName: added,
            metricName: "<new>",
            measured: 0.0, baseline: 0.0, tolerance: 0.0,
            unit: "scenario ran but has no baseline — recapture to add"
        ))
    }

    // Per-scenario metric drift.
    for name in baselineNames.intersection(measuredNames).sorted() {
        guard let measuredRec = measured[name], let baselineRec = baseline.scenarios[name] else {
            continue
        }
        for probe in probes {
            let mv = probe.get(measuredRec)
            let bv = probe.get(baselineRec)
            if abs(mv - bv) > probe.tolerance {
                findings.append(BaselineDriftFinding(
                    scenarioName: name,
                    metricName: probe.name,
                    measured: mv,
                    baseline: bv,
                    tolerance: probe.tolerance,
                    unit: probe.unit
                ))
            }
        }
        if measuredRec.overBudget != baselineRec.overBudget {
            findings.append(BaselineDriftFinding(
                scenarioName: name,
                metricName: "overBudget",
                measured: measuredRec.overBudget ? 1.0 : 0.0,
                baseline: baselineRec.overBudget ? 1.0 : 0.0,
                tolerance: 0.0,
                unit: "bool"
            ))
        }
    }

    return findings
}

// MARK: - Load / save

enum VerifierBaselineError: Error, CustomStringConvertible {
    case fileMissing(URL)
    case schemaMismatch(expected: Int, found: Int)
    case readFailed(URL, Error)
    case writeFailed(URL, Error)
    case decodeFailed(URL, Error)

    var description: String {
        switch self {
        case .fileMissing(let url):
            return "Baseline file not found at \(url.path). Run with --capture-baseline to create."
        case .schemaMismatch(let expected, let found):
            return "Baseline file schema version \(found) does not match expected \(expected). Recapture with --capture-baseline."
        case .readFailed(let url, let err):
            return "Failed to read baseline at \(url.path): \(err)"
        case .writeFailed(let url, let err):
            return "Failed to write baseline at \(url.path): \(err)"
        case .decodeFailed(let url, let err):
            return "Failed to decode baseline at \(url.path): \(err)"
        }
    }
}

func loadVerifierBaseline(from url: URL) throws -> VerifierBaselineFile {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw VerifierBaselineError.fileMissing(url)
    }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw VerifierBaselineError.readFailed(url, error)
    }
    let decoded: VerifierBaselineFile
    do {
        decoded = try JSONDecoder().decode(VerifierBaselineFile.self, from: data)
    } catch {
        throw VerifierBaselineError.decodeFailed(url, error)
    }
    guard decoded.schemaVersion == VerifierBaselineFile.currentSchemaVersion else {
        throw VerifierBaselineError.schemaMismatch(
            expected: VerifierBaselineFile.currentSchemaVersion,
            found: decoded.schemaVersion
        )
    }
    return decoded
}

func saveVerifierBaseline(_ baseline: VerifierBaselineFile, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data: Data
    do {
        data = try encoder.encode(baseline)
    } catch {
        throw VerifierBaselineError.writeFailed(url, error)
    }
    // Ensure parent directory exists.
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        throw VerifierBaselineError.writeFailed(url, error)
    }
}

// MARK: - Path helpers

/// Resolves the default baseline path. Prefers `macOS/verifier_baselines/`
/// when run from the repo root (detected by presence of `macOS/Package.swift`),
/// otherwise `./verifier_baselines/` — so the same binary works whether it's
/// invoked from the repo root or from inside the `macOS/` subdirectory.
func defaultVerifierBaselinePath() -> URL {
    let cwd = FileManager.default.currentDirectoryPath
    let repoRootMarker = URL(fileURLWithPath: cwd)
        .appendingPathComponent("macOS")
        .appendingPathComponent("Package.swift")
    if FileManager.default.fileExists(atPath: repoRootMarker.path) {
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent("macOS")
            .appendingPathComponent("verifier_baselines")
            .appendingPathComponent("default.json")
    }
    return URL(fileURLWithPath: cwd)
        .appendingPathComponent("verifier_baselines")
        .appendingPathComponent("default.json")
}

/// ISO-8601 timestamp for capture metadata. Truncated to whole seconds so
/// round-trips don't introduce sub-second jitter in `git diff`.
func verifierBaselineTimestampNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}
