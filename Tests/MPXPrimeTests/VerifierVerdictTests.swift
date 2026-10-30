import Testing
import Foundation
@testable import MPXPrime

// The verifier's verdict and baseline layer, which had no unit test at all
// (test-suite review 2026-10 findings 6 and 9):
//
// - the exit ladder let a quality TIGHT (1) mask an over-budget or safety
//   WARN (2), against the "stronger verdict wins" rule in AGENTS.md and
//   docs/BUILDING.md;
// - `--baseline-strict` passed on the physical limits alone when the baseline
//   file was missing, undecodable or of another schema version;
// - the 4x true-peak overshoot was printed but never counted;
// - `compareBaseline`'s missing-scenario / new-scenario findings were never
//   exercised.

@Suite("Verifier verdict and baseline")
struct VerifierVerdictTests {

    // MARK: - Exit ladder: the strongest verdict wins

    @Test func aQualityWarningDoesNotMaskAnOverBudgetComposite() {
        var input = CompositeVerdictInputs()
        input.qualityWarningCount = 3
        input.anyOverBudget = true
        #expect(compositeVerdict(input) == 2,
                "quality TIGHT + over budget must exit WARN (2), got \(compositeVerdict(input))")
        #expect(compositeVerdictFindings(input).first?.message.hasPrefix("WARN") == true)
    }

    @Test func aQualityWarningDoesNotMaskTheSafetyLimiter() {
        var input = CompositeVerdictInputs()
        input.qualityWarningCount = 1
        input.worstSafetyGRDB = 4.5
        #expect(compositeVerdict(input) == 2)
        input.worstSafetyGRDB = 3.5
        #expect(compositeVerdict(input) == 1, "3-4 dB of safety GR is TIGHT")
    }

    @Test func aQualityWarningDoesNotMaskANegativeMargin() {
        var input = CompositeVerdictInputs()
        input.qualityWarningCount = 1
        input.worstBudgetMarginDB = -0.4
        #expect(compositeVerdict(input) == 2)
    }

    @Test func postInjectionOvershootIsAFailWhateverElseFires() {
        var input = CompositeVerdictInputs()
        input.qualityWarningCount = 2
        input.anyOverBudget = true
        input.worstSafetyGRDB = 9.0
        input.worstPostInjectionOvershoot = 2e-4
        #expect(compositeVerdict(input) == 3)
        input.worstPostInjectionOvershoot = 0.5e-4
        #expect(compositeVerdict(input) == 2, "below 1e-4 the overshoot rule must not fire")
    }

    @Test func eachRuleAloneGivesItsOwnLevel() {
        #expect(compositeVerdict(CompositeVerdictInputs()) == 0, "a clean run is PASS")
        var q = CompositeVerdictInputs(); q.qualityWarningCount = 1
        #expect(compositeVerdict(q) == 1)
        var m = CompositeVerdictInputs(); m.worstBudgetMarginDB = -0.1
        #expect(compositeVerdict(m) == 1)
        var mw = CompositeVerdictInputs(); mw.worstBudgetMarginDB = -0.3
        #expect(compositeVerdict(mw) == 2)
        var s = CompositeVerdictInputs(); s.worstSafetyGRDB = 2.9
        #expect(compositeVerdict(s) == 0, "the limiter's normal duty is not a finding")
    }

    // MARK: - True peak counts

    @Test func truePeakOverFullDeviationCountsInTheVerdict() {
        var input = CompositeVerdictInputs()
        input.worstTruePeakDBFS = -0.3
        #expect(compositeVerdict(input) == 0)
        input.worstTruePeakDBFS = 0.1
        #expect(compositeVerdict(input) == 1, "an inter-sample peak above 75 kHz is TIGHT")
        input.worstTruePeakDBFS = 0.6
        #expect(compositeVerdict(input) == 2, "more than +0.25 dB of over-deviation is WARN")
        input.qualityWarningCount = 1
        #expect(compositeVerdict(input) == 2, "and a quality TIGHT does not mask it")
    }

    // MARK: - Strict baseline

    @Test func strictBaselineFailsWhenTheBaselineIsUnusable() {
        var input = CompositeVerdictInputs()
        input.baselineUnavailable = true
        #expect(compositeVerdict(input) == 0, "a plain run without a baseline stays a physical-limits run")
        input.strictBaseline = true
        #expect(compositeVerdict(input) == 2, "--baseline-strict without a usable baseline must not pass")
    }

    @Test func driftIsTightPlainAndWarnStrict() {
        var input = CompositeVerdictInputs()
        input.baselineDriftCount = 1
        #expect(compositeVerdict(input) == 1)
        input.strictBaseline = true
        #expect(compositeVerdict(input) == 2)
    }

    @Test func theAvailabilityExitFollowsStrictMode() {
        #expect(baselineAvailabilityExit(.loaded, strict: true) == 0)
        #expect(baselineAvailabilityExit(.missing("x"), strict: true) == 2)
        #expect(baselineAvailabilityExit(.unreadable("y"), strict: true) == 2)
        #expect(baselineAvailabilityExit(.missing("x"), strict: false) == 0)
    }

    // MARK: - Loader classification (missing / undecodable / schema)

    private func scratchURL(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpxprime-verdict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func record(_ peak: Float = -0.5) -> VerifierBaselineRecord {
        VerifierBaselineRecord(
            peakDBFS: peak, deviationKHz: 70.0, limiterGRDB: 1.0, safetyGRDB: 0.5,
            audioCompositePeakDBFS: -1.1, postInjectionOvershoot: 0.0, overBudget: false,
            pilotPercent: 8.0, rdsPercent: 2.7, budgetMarginDB: 0.4, agcReductionDB: 2.0,
            inputCorrelation: 0.5, outputCorrelation: 0.5, inputSideToMid: 0.3,
            outputSideToMid: 0.3, rmsDeltaDB: 1.0, occupied999Hz: 57_000.0,
            above60kRatioDB: -80.0, above67kRatioDB: -85.0, truePeakOvershootDB: 0.1)
    }

    private func file(_ scenarios: [String: VerifierBaselineRecord], schema: Int = VerifierBaselineFile.currentSchemaVersion)
        -> VerifierBaselineFile {
        VerifierBaselineFile(
            schemaVersion: schema, capturedAt: "test", configPath: "test.ini",
            renderSampleRateHz: 192_000, blockSize: 512, durationSeconds: 5.0,
            scenarios: scenarios, encoderSidebands: nil)
    }

    @Test func aMissingFileIsClassifiedMissing() throws {
        let url = try scratchURL("absent.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attempt = classifyBaselineLoad { try loadVerifierBaseline(from: url) }
        #expect(attempt.value == nil)
        #expect(attempt.availability == .missing(url.path))
        #expect(baselineAvailabilityExit(attempt.availability, strict: true) == 2)
    }

    @Test func anUndecodableFileIsClassifiedUnreadable() throws {
        let url = try scratchURL("garbage.json")
        try Data("{ not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attempt = classifyBaselineLoad { try loadVerifierBaseline(from: url) }
        #expect(attempt.value == nil)
        guard case .unreadable = attempt.availability else {
            Issue.record("garbage must be unreadable, got \(attempt.availability)")
            return
        }
        #expect(baselineAvailabilityExit(attempt.availability, strict: true) == 2)
    }

    @Test func anotherSchemaVersionIsClassifiedUnreadable() throws {
        let url = try scratchURL("old.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try saveVerifierBaseline(file(["a": record()], schema: VerifierBaselineFile.currentSchemaVersion - 1), to: url)
        let attempt = classifyBaselineLoad { try loadVerifierBaseline(from: url) }
        #expect(attempt.value == nil)
        guard case .unreadable(let reason) = attempt.availability else {
            Issue.record("a schema mismatch must be unreadable, got \(attempt.availability)")
            return
        }
        #expect(reason.contains("schema"))
    }

    @Test func aCurrentFileRoundTrips() throws {
        let url = try scratchURL("current.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stored = file(["a": record()])
        try saveVerifierBaseline(stored, to: url)
        let attempt = classifyBaselineLoad { try loadVerifierBaseline(from: url) }
        #expect(attempt.availability == .loaded)
        #expect(attempt.value == stored)
    }

    // MARK: - compareBaseline

    @Test func identicalRecordsGiveNoFindings() {
        #expect(compareBaseline(measured: ["a": record(), "b": record()], baseline: file(["a": record(), "b": record()])).isEmpty)
    }

    @Test func driftBeyondToleranceIsReportedAndInsideIsNot() {
        let tol = MetricTolerances.default.peakDBFS
        let inside = compareBaseline(measured: ["a": record(-0.5 + tol * 0.5)], baseline: file(["a": record()]))
        #expect(inside.isEmpty, "drift inside the tolerance must not be reported")
        let outside = compareBaseline(measured: ["a": record(-0.5 + tol * 3.0)], baseline: file(["a": record()]))
        #expect(outside.count == 1)
        #expect(outside.first?.metricName == "peakDBFS")
        #expect(outside.first?.scenarioName == "a")
    }

    @Test func missingAndNewScenariosAreFindings() {
        let findings = compareBaseline(measured: ["a": record(), "new": record()],
                                       baseline: file(["a": record(), "gone": record()]))
        #expect(findings.contains { $0.scenarioName == "gone" && $0.metricName == "<missing>" })
        #expect(findings.contains { $0.scenarioName == "new" && $0.metricName == "<new>" })
        #expect(findings.count == 2)
    }

    @Test func anOverBudgetFlipIsAFinding() {
        var flipped = record()
        flipped.overBudget = true
        let findings = compareBaseline(measured: ["a": flipped], baseline: file(["a": record()]))
        #expect(findings.map(\.metricName) == ["overBudget"])
    }

    @Test func truePeakOvershootDriftIsCompared() {
        var moved = record()
        moved.truePeakOvershootDB += MetricTolerances.default.truePeakOvershootDB * 2.0
        let findings = compareBaseline(measured: ["a": moved], baseline: file(["a": record()]))
        #expect(findings.map(\.metricName) == ["truePeakOvershootDB"])
    }
}
