import Testing
import Foundation
@testable import MPXPrime

// Stored receiver-baseline comparison (Next-up #5). The receiver-model
// verifier pins decode separation + subcarrier health in `receiver.json`;
// these tests cover the comparison logic in isolation (no rendering) so the
// drift-detection contract is locked: identical = clean, beyond tolerance =
// flagged on exactly the drifted metric, within tolerance = clean.

@Suite("Receiver baseline compare")
struct ReceiverBaselineTests {

    private func sampleRecord() -> ReceiverBaselineRecord {
        ReceiverBaselineRecord(
            coherentSep1k: 98.3, coherentSep10k: 86.1, coherentSep14k: 97.2,
            pllSep1k: 68.0, pllSep10k: 51.8, pllSep14k: 44.2,
            noPilotPilotPercent: 0.0,
            subcarrierPilotPercent: 8.0,
            pilotGuardDepthDB: 11.8,
            rdsGuardDepthDB: 12.5
        )
    }

    @Test func identicalRecordsReportNoDrift() {
        let r = sampleRecord()
        #expect(compareReceiverMetrics(measured: r, baseline: r).isEmpty)
    }

    @Test func separationBeyondToleranceIsFlagged() {
        let base = sampleRecord()
        var measured = base
        // Default separation tolerance is 2.0 dB; +5 dB is well beyond.
        measured.coherentSep14k = base.coherentSep14k - 5.0
        let findings = compareReceiverMetrics(measured: measured, baseline: base)
        #expect(findings.count == 1)
        #expect(findings.first?.metricName == "coherentSep@14k")
        #expect(findings.first?.scenarioName == "receiver")
    }

    @Test func separationWithinToleranceIsClean() {
        let base = sampleRecord()
        var measured = base
        // +1.5 dB is inside the 2.0 dB separation tolerance.
        measured.coherentSep10k = base.coherentSep10k + 1.5
        #expect(compareReceiverMetrics(measured: measured, baseline: base).isEmpty)
    }

    @Test func guardDepthUsesItsOwnTolerance() {
        let base = sampleRecord()
        var measured = base
        // Guard-depth tolerance is 1.5 dB: 1.0 dB is clean, 2.0 dB flags.
        measured.pilotGuardDepthDB = base.pilotGuardDepthDB - 1.0
        #expect(compareReceiverMetrics(measured: measured, baseline: base).isEmpty)
        measured.pilotGuardDepthDB = base.pilotGuardDepthDB - 2.0
        #expect(compareReceiverMetrics(measured: measured, baseline: base).count == 1)
    }

    @Test func multipleDriftsAllReported() {
        let base = sampleRecord()
        var measured = base
        measured.pilotGuardDepthDB = base.pilotGuardDepthDB - 5.0     // > 1.5 dB
        measured.subcarrierPilotPercent = base.subcarrierPilotPercent + 1.0  // > 0.10 %
        let findings = compareReceiverMetrics(measured: measured, baseline: base)
        #expect(findings.count == 2)
        #expect(Set(findings.map(\.metricName)) == ["pilotGuardDepth", "subcarrierPilotPercent"])
    }
}
