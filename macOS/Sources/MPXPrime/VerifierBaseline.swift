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
    /// 4x-oversampled true-peak minus sample-peak, in dB. The inter-sample
    /// overshoot the sample-domain peak meter misses. Baselining the delta
    /// (not the absolute true-peak, which tracks peakDBFS) catches a
    /// regression that lets inter-sample peaks grow past the 75 kHz
    /// deviation ceiling without moving the sample peak.
    var truePeakOvershootDB: Float
}

/// Encoder-side DSB-SC sideband metrics, captured once from an L-only
/// tone drive at 1 / 10 / 14 kHz (independent of the program scenarios).
/// These gate the composite clipper's guard-band cancellation and
/// DSB-SC balance: a drift in clipper / FIR group-delay alignment moves
/// `asymmetryDB` (lower-vs-upper sideband imbalance) or `sideMonoDeltaDB`
/// (side-vs-mono level), neither of which the program-scenario records
/// surface. Source is `EncoderSidebandMetrics` in the harness.
struct EncoderSidebandBaselineRecord: Codable, Equatable {
    var asymmetryDB1k: Float
    var sideMonoDeltaDB1k: Float
    var asymmetryDB10k: Float
    var sideMonoDeltaDB10k: Float
    var asymmetryDB14k: Float
    var sideMonoDeltaDB14k: Float
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
    /// Encoder-side sideband fingerprint (L-only tone drive at 1/10/14
    /// kHz). Optional so schema-2 files decode, but always written by
    /// schema-3 captures.
    var encoderSidebands: EncoderSidebandBaselineRecord?

    static let currentSchemaVersion: Int = 3
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
    var truePeakOvershootDB: Float = 0.20

    static let `default` = MetricTolerances()
}

/// Per-metric tolerance for the encoder-side sideband fingerprint. These
/// are tighter than the program-scenario tolerances because the drive is
/// a clean single tone, so the only motion should be genuine encoder /
/// clipper drift, not program-dependent jitter.
struct EncoderSidebandTolerances {
    var asymmetryDB: Float = 0.5
    var sideMonoDeltaDB: Float = 0.5

    static let `default` = EncoderSidebandTolerances()
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
        Probe(name: "truePeakOvershootDB", unit: "dB", tolerance: tolerances.truePeakOvershootDB, get: { $0.truePeakOvershootDB })
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

/// Compare measured encoder-side sideband metrics against the stored
/// baseline. Returns one drift finding per (tone, metric) that moved
/// beyond tolerance. The synthetic scenario name "encoder_sidebands"
/// keeps these findings visually distinct from per-scenario drift.
func compareEncoderSidebands(
    measured: EncoderSidebandBaselineRecord,
    baseline: EncoderSidebandBaselineRecord,
    tolerances: EncoderSidebandTolerances = .default
) -> [BaselineDriftFinding] {
    var findings: [BaselineDriftFinding] = []

    struct Probe {
        let name: String
        let tolerance: Float
        let get: (EncoderSidebandBaselineRecord) -> Float
    }
    let probes: [Probe] = [
        Probe(name: "asymmetryDB@1k", tolerance: tolerances.asymmetryDB, get: { $0.asymmetryDB1k }),
        Probe(name: "sideMonoDeltaDB@1k", tolerance: tolerances.sideMonoDeltaDB, get: { $0.sideMonoDeltaDB1k }),
        Probe(name: "asymmetryDB@10k", tolerance: tolerances.asymmetryDB, get: { $0.asymmetryDB10k }),
        Probe(name: "sideMonoDeltaDB@10k", tolerance: tolerances.sideMonoDeltaDB, get: { $0.sideMonoDeltaDB10k }),
        Probe(name: "asymmetryDB@14k", tolerance: tolerances.asymmetryDB, get: { $0.asymmetryDB14k }),
        Probe(name: "sideMonoDeltaDB@14k", tolerance: tolerances.sideMonoDeltaDB, get: { $0.sideMonoDeltaDB14k })
    ]

    for probe in probes {
        let mv = probe.get(measured)
        let bv = probe.get(baseline)
        if abs(mv - bv) > probe.tolerance {
            findings.append(BaselineDriftFinding(
                scenarioName: "encoder_sidebands",
                metricName: probe.name,
                measured: mv,
                baseline: bv,
                tolerance: probe.tolerance,
                unit: "dB"
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

/// Baseline filename, per platform. Composite output is numerics-identical
/// only within a platform (Apple libm + vvtanhf vs Glibc libm + scalar tanhf),
/// so each platform pins its own strict baseline: `default.json` on macOS
/// (unchanged), `default-linux-<arch>.json` on Linux.
private func verifierBaselineFileName() -> String {
    #if os(Linux)
    #if arch(x86_64)
    return "default-linux-x86_64.json"
    #else
    return "default-linux-arm64.json"
    #endif
    #else
    return "default.json"
    #endif
}

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
            .appendingPathComponent(verifierBaselineFileName())
    }
    return URL(fileURLWithPath: cwd)
        .appendingPathComponent("verifier_baselines")
        .appendingPathComponent(verifierBaselineFileName())
}

/// ISO-8601 timestamp for capture metadata. Truncated to whole seconds so
/// round-trips don't introduce sub-second jitter in `git diff`.
func verifierBaselineTimestampNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

// MARK: - Receiver-side baseline
//
// Kept in a SEPARATE file (`receiver.json`) from the composite baseline
// (`default.json`): the receiver-model metrics are captured by the
// `--verify-receiver` path, the composite scenario metrics by the `--verify`
// sweep. Independent files mean neither capture clobbers the other and the
// composite schema needs no migration.

/// Stored receiver-decode metrics. Pins the decoder/encoder stereo
/// separation and subcarrier health so a regression — e.g. reintroducing a
/// decoder pilot/RDS notch (see plan.md "MPXDecoder has no pre-demod
/// notch"), or an encoder change that quietly costs separation — is caught
/// by `--verify-receiver --baseline-strict` instead of sailing past the
/// loose inline >=16-18 dB thresholds. Pilot/RDS phase-lock drift already
/// has its own hard gate, so it is intentionally not duplicated here.
struct ReceiverBaselineRecord: Codable, Equatable {
    var coherentSep1k: Float
    var coherentSep10k: Float
    var coherentSep14k: Float
    var pllSep1k: Float
    var pllSep10k: Float
    var pllSep14k: Float
    var noPilotPilotPercent: Float
    var subcarrierPilotPercent: Float
    var pilotGuardDepthDB: Float
    var rdsGuardDepthDB: Float
    // Deliberately NOT pinned: mono / no-pilot side rejection. Those are
    // ~175-230 dB ratios — i.e. the side channel sits at the numerical floor
    // (~-180 dBFS) for a mono input, so the exact dB is meaningless jitter
    // that drifts with render duration (settling), not a regression signal.
    // A genuine rejection failure is still caught by the inline >=26 dB
    // thresholds in runReceiverModelVerification.
}

struct ReceiverBaselineFile: Codable, Equatable {
    var schemaVersion: Int
    var capturedAt: String
    var configPath: String
    var renderSampleRateHz: Int
    var metrics: ReceiverBaselineRecord

    static let currentSchemaVersion: Int = 1
}

/// Per-metric tolerance for the receiver baseline. Conservative defaults —
/// separations and rejections can jitter a little with FFT windowing, so
/// widen (never tighten below the observed run-to-run spread) if a clean
/// recapture+strict cycle reports drift.
struct ReceiverMetricTolerances {
    var separationDB: Float = 2.0
    var pilotPercent: Float = 0.10
    var guardDepthDB: Float = 1.5

    static let `default` = ReceiverMetricTolerances()
}

/// Compare measured receiver metrics against the stored baseline. One drift
/// finding per metric beyond tolerance; the synthetic scenario name
/// "receiver" keeps these visually distinct from per-scenario composite drift.
func compareReceiverMetrics(
    measured: ReceiverBaselineRecord,
    baseline: ReceiverBaselineRecord,
    tolerances: ReceiverMetricTolerances = .default
) -> [BaselineDriftFinding] {
    var findings: [BaselineDriftFinding] = []
    struct Probe {
        let name: String
        let unit: String
        let tolerance: Float
        let get: (ReceiverBaselineRecord) -> Float
    }
    let probes: [Probe] = [
        Probe(name: "coherentSep@1k", unit: "dB", tolerance: tolerances.separationDB, get: { $0.coherentSep1k }),
        Probe(name: "coherentSep@10k", unit: "dB", tolerance: tolerances.separationDB, get: { $0.coherentSep10k }),
        Probe(name: "coherentSep@14k", unit: "dB", tolerance: tolerances.separationDB, get: { $0.coherentSep14k }),
        Probe(name: "pllSep@1k", unit: "dB", tolerance: tolerances.separationDB, get: { $0.pllSep1k }),
        Probe(name: "pllSep@10k", unit: "dB", tolerance: tolerances.separationDB, get: { $0.pllSep10k }),
        Probe(name: "pllSep@14k", unit: "dB", tolerance: tolerances.separationDB, get: { $0.pllSep14k }),
        Probe(name: "noPilotPilotPercent", unit: "%", tolerance: tolerances.pilotPercent, get: { $0.noPilotPilotPercent }),
        Probe(name: "subcarrierPilotPercent", unit: "%", tolerance: tolerances.pilotPercent, get: { $0.subcarrierPilotPercent }),
        Probe(name: "pilotGuardDepth", unit: "dB", tolerance: tolerances.guardDepthDB, get: { $0.pilotGuardDepthDB }),
        Probe(name: "rdsGuardDepth", unit: "dB", tolerance: tolerances.guardDepthDB, get: { $0.rdsGuardDepthDB })
    ]
    for probe in probes {
        let mv = probe.get(measured)
        let bv = probe.get(baseline)
        if abs(mv - bv) > probe.tolerance {
            findings.append(BaselineDriftFinding(
                scenarioName: "receiver",
                metricName: probe.name,
                measured: mv,
                baseline: bv,
                tolerance: probe.tolerance,
                unit: probe.unit
            ))
        }
    }
    return findings
}

func loadReceiverBaseline(from url: URL) throws -> ReceiverBaselineFile {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw VerifierBaselineError.fileMissing(url)
    }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw VerifierBaselineError.readFailed(url, error)
    }
    let decoded: ReceiverBaselineFile
    do {
        decoded = try JSONDecoder().decode(ReceiverBaselineFile.self, from: data)
    } catch {
        throw VerifierBaselineError.decodeFailed(url, error)
    }
    guard decoded.schemaVersion == ReceiverBaselineFile.currentSchemaVersion else {
        throw VerifierBaselineError.schemaMismatch(
            expected: ReceiverBaselineFile.currentSchemaVersion,
            found: decoded.schemaVersion
        )
    }
    return decoded
}

func saveReceiverBaseline(_ baseline: ReceiverBaselineFile, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data: Data
    do {
        data = try encoder.encode(baseline)
    } catch {
        throw VerifierBaselineError.writeFailed(url, error)
    }
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        throw VerifierBaselineError.writeFailed(url, error)
    }
}

/// Receiver baseline lives next to the composite baseline, named `receiver.json`.
func defaultReceiverBaselinePath() -> URL {
    defaultVerifierBaselinePath()
        .deletingLastPathComponent()
        .appendingPathComponent("receiver.json")
}
