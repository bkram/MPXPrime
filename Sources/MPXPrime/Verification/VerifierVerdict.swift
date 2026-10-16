import Foundation

// MARK: - Verifier verdict (pure, unit-tested)
//
// The `--verify` exit code used to come from an if / else-if ladder in
// `runVerificationHarness` that tested the quality warnings (TIGHT, 1)
// BEFORE the over-budget and safety checks (WARN, 2), so a coinciding
// quality finding masked a WARN down to TIGHT. AGENTS.md and
// docs/BUILDING.md promise the opposite: the stronger verdict wins. Each
// rule below is now evaluated on its own and the result is the MAXIMUM, so
// no finding can hide another. `VerifierVerdictTests` pins the ladder.
//
// Exit codes: 0 PASS, 1 TIGHT, 2 WARN, 3 FAIL.

/// Everything the composite verdict depends on, as plain values so the rule
/// can be tested without rendering a scenario.
struct CompositeVerdictInputs: Equatable {
    var worstPostInjectionOvershoot: Float = 0.0
    var qualityWarningCount: Int = 0
    var anyOverBudget: Bool = false
    var worstSafetyGRDB: Float = 0.0
    var worstBudgetMarginDB: Float = .greatestFiniteMagnitude
    /// Worst 4x-oversampled true peak of the composite in dBFS (1.0 = 75 kHz
    /// at every deviation setting), or -infinity when nothing was measured.
    var worstTruePeakDBFS: Float = -.infinity
    var baselineDriftCount: Int = 0
    /// The stored baseline was expected but is missing, undecodable or of
    /// another schema version.
    var baselineUnavailable: Bool = false
    var strictBaseline: Bool = false
}

/// One rule that fired: its exit level and the line printed after "Result:".
struct VerdictFinding: Equatable {
    let level: Int32
    let message: String
}

/// Bounds of the composite verdict. Kept together so the ladder reads in one
/// place; the numbers are the ones the harness has used since 0.45 plus the
/// true-peak rule.
enum CompositeVerdictBounds {
    /// Post-injection overshoot (composite above its budget after pilot/RDS
    /// are summed) is a hard FAIL.
    static let postInjectionOvershoot: Float = 1e-4
    /// The final look-ahead limiter's normal duty is ~1.5 dB on bright_dense
    /// and the hot Verification.ini reads 2.6 dB honestly (0.45 A1b).
    static let safetyWarnDB: Float = 4.0
    static let safetyTightDB: Float = 3.0
    static let marginWarnDB: Float = -0.25
    static let marginTightDB: Float = 0.0
    /// 4x true peak of the complete composite. The composite IS the
    /// modulating signal: the exciter's reconstruction filter restores the
    /// inter-sample peak, so a true peak above 0 dBFS is over-deviation past
    /// 75 kHz that the sample-domain peak meter cannot see. Same two bounds
    /// as the sample-domain budget margin: any excess is TIGHT, more than
    /// 0.25 dB (about 77.2 kHz, +2.9 %) is WARN. Before this rule the figure
    /// was printed but never used in the verdict.
    static let truePeakTightDBFS: Float = 0.0
    static let truePeakWarnDBFS: Float = 0.25
}

/// Every rule that fires, strongest first. Empty means PASS.
func compositeVerdictFindings(_ input: CompositeVerdictInputs) -> [VerdictFinding] {
    typealias B = CompositeVerdictBounds
    var findings: [VerdictFinding] = []
    if input.worstPostInjectionOvershoot > B.postInjectionOvershoot {
        findings.append(VerdictFinding(
            level: 3,
            message: "FAIL - post-injection composite overshoot (subcarrier budget violated after pilot/RDS injection)."))
    }
    if input.anyOverBudget {
        findings.append(VerdictFinding(
            level: 2, message: "WARN - composite budget exceeded on at least one scenario."))
    }
    if input.worstSafetyGRDB > B.safetyWarnDB {
        findings.append(VerdictFinding(
            level: 2,
            message: "WARN - safety limiter is doing significant work (\(String(format: "%.1f", input.worstSafetyGRDB)) dB > \(String(format: "%.1f", B.safetyWarnDB)) dB)."))
    }
    if input.worstBudgetMarginDB < B.marginWarnDB {
        findings.append(VerdictFinding(
            level: 2,
            message: "WARN - composite budget margin \(String(format: "%.2f", input.worstBudgetMarginDB)) dB is below \(String(format: "%.2f", B.marginWarnDB)) dB."))
    }
    if input.worstTruePeakDBFS > B.truePeakWarnDBFS {
        findings.append(VerdictFinding(
            level: 2,
            message: "WARN - composite 4x true peak \(String(format: "%+.2f", input.worstTruePeakDBFS)) dBFS is over-deviation beyond \(String(format: "%+.2f", B.truePeakWarnDBFS)) dBFS."))
    }
    if input.strictBaseline && input.baselineDriftCount > 0 {
        findings.append(VerdictFinding(
            level: 2, message: "WARN - stored-baseline drift in --baseline-strict mode."))
    }
    if input.strictBaseline && input.baselineUnavailable {
        findings.append(VerdictFinding(
            level: 2,
            message: "WARN - --baseline-strict has no usable baseline (missing, undecodable or another schema version); the run cannot be compared."))
    }
    if input.qualityWarningCount > 0 {
        findings.append(VerdictFinding(
            level: 1,
            message: "TIGHT - composite safety is OK, but decoded-audio quality drift exceeded expected bounds."))
    }
    if input.worstBudgetMarginDB < B.marginTightDB && input.worstBudgetMarginDB >= B.marginWarnDB {
        findings.append(VerdictFinding(
            level: 1, message: "TIGHT - verification stayed close to the composite budget limit."))
    }
    if input.worstSafetyGRDB > B.safetyTightDB && input.worstSafetyGRDB <= B.safetyWarnDB {
        findings.append(VerdictFinding(
            level: 1,
            message: "TIGHT - safety limiter gain reduction \(String(format: "%.1f", input.worstSafetyGRDB)) dB is above \(String(format: "%.1f", B.safetyTightDB)) dB."))
    }
    if input.worstTruePeakDBFS > B.truePeakTightDBFS && input.worstTruePeakDBFS <= B.truePeakWarnDBFS {
        findings.append(VerdictFinding(
            level: 1,
            message: "TIGHT - composite 4x true peak \(String(format: "%+.2f", input.worstTruePeakDBFS)) dBFS is above full deviation."))
    }
    if !input.strictBaseline && input.baselineDriftCount > 0 {
        findings.append(VerdictFinding(
            level: 1,
            message: "TIGHT - stored-baseline drift detected (use --baseline-strict to fail the run)."))
    }
    // Stable sort: strongest level first, rule order within a level.
    return findings.enumerated()
        .sorted { ($0.element.level, -$0.offset) > ($1.element.level, -$1.offset) }
        .map(\.element)
}

/// The exit code: the strongest finding, or 0.
func compositeVerdict(_ input: CompositeVerdictInputs) -> Int32 {
    compositeVerdictFindings(input).first?.level ?? 0
}

// MARK: - Baseline availability

/// What the loader found. `--baseline-strict` must not fall back to the
/// physical limits alone when the stored baseline cannot be read: a bumped
/// schema, a run from another directory or a missing platform file used to
/// print "failed to load" and pass.
enum BaselineAvailability: Equatable {
    case loaded
    case missing(String)
    case unreadable(String)

    var isUsable: Bool {
        if case .loaded = self { return true }
        return false
    }

    var note: String {
        switch self {
        case .loaded: return "loaded"
        case .missing(let path): return "missing (\(path))"
        case .unreadable(let reason): return "unreadable (\(reason))"
        }
    }
}

/// Classify a load attempt. `load` throws `VerifierBaselineError` (or
/// anything else) on failure; a `.fileMissing` error is reported as missing.
func classifyBaselineLoad<T>(_ load: () throws -> T) -> (value: T?, availability: BaselineAvailability) {
    do {
        return (try load(), .loaded)
    } catch let error as VerifierBaselineError {
        if case .fileMissing(let url) = error { return (nil, .missing(url.path)) }
        return (nil, .unreadable(error.description))
    } catch {
        return (nil, .unreadable("\(error)"))
    }
}

/// Exit-code contribution of an unusable baseline: WARN (2) under
/// `--baseline-strict`, nothing otherwise (a plain run without a baseline
/// stays a physical-limits run, as documented).
func baselineAvailabilityExit(_ availability: BaselineAvailability, strict: Bool) -> Int32 {
    (strict && !availability.isUsable) ? 2 : 0
}
