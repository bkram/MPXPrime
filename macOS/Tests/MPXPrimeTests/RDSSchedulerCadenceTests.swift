import Testing
import Foundation
@testable import MPXPrime

// Cadence tests for the RDS group scheduler in auto and standard modes.
// The custom-sequence mode is already covered by RDSBitstreamTests.
// Here we lock in the auto / standard cadences so RT+ scheduling
// regressions like "3A every other cycle" surface immediately.

@Suite("RDS scheduler cadence")
struct RDSSchedulerCadenceTests {

    private func makeConfig(
        scheduler: String,
        rtPlus: Bool = false,
        ptyn: Bool = false,
        lps: Bool = false,
        af: Bool = false
    ) -> AppConfig {
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "82FF"
        cfg.rdsPSA = "HELLO"
        cfg.rdsRTText = "HELLO WORLD"
        cfg.rdsRTMode = "2A"
        cfg.rdsRTBufferAEnabled = false
        cfg.rdsRTBufferBEnabled = false
        cfg.rdsRTBufferCEnabled = false
        cfg.rdsRTBufferDEnabled = false
        cfg.rdsEnablePTYN = ptyn
        cfg.rdsPTYN = ptyn ? "NEWSFEED" : "--------"
        cfg.rdsEnableLPS = lps
        cfg.rdsLongPS32 = lps ? "Long PS test" : ""
        cfg.rdsEnableRTPlus = rtPlus
        cfg.rdsRTPlusFormatA = rtPlus ? "{title}" : ""
        cfg.rdsEnableCT = false
        cfg.rdsEnableID = false
        cfg.rdsEnableAF = af
        cfg.rdsNowPlayingEnabled = false
        cfg.rdsSchedulerAuto = (scheduler == "auto")
        cfg.rdsSchedulerStandard = (scheduler == "standard")
        return cfg
    }

    private func sampleGroupTypes(
        _ coder: BasicRDSCoder, count: Int
    ) -> [Int] {
        var types: [Int] = []
        for _ in 0..<count {
            let bits = coder.nextGroupBits()
            types.append(RDSGroupDecoder.decode(bits).groupType)
        }
        return types
    }

    // MARK: - Auto scheduler

    @Test func autoSchedulerEmitsPSGroupsMostOften() {
        // Auto schedule has ~12 group-0 entries per cycle. PS must be
        // the most-emitted group regardless of features.
        let cfg = makeConfig(scheduler: "auto")
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let types = sampleGroupTypes(coder, count: 200)
        let zeros = types.filter { $0 == 0 }.count
        #expect(zeros > types.count / 2,
            "Group 0 (PS) should dominate the auto schedule; observed \(zeros) of \(types.count)")
    }

    @Test func autoSchedulerEmitsGroup2ForRT() {
        // Auto schedule contains group 2 (RT) rotated with PS.
        let cfg = makeConfig(scheduler: "auto")
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let types = sampleGroupTypes(coder, count: 200)
        let twos = types.filter { $0 == 2 }.count
        #expect(twos > 30,
            "Group 2 (RT) should appear ~9 times per cycle in auto; saw \(twos)/\(types.count)")
    }

    @Test func autoSchedulerEmits3AEveryCycleWithRTPlus() {
        // Regression guard for the post-0.11 RT+ fix: 3A registration
        // appears every cycle (not every other) when RT+ is enabled.
        // With ~26 groups per cycle and 200 samples, we expect ~7+
        // copies of 3A — the previous "every other cycle" cadence
        // would yield ~3-4.
        let cfg = makeConfig(scheduler: "auto", rtPlus: true)
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let types = sampleGroupTypes(coder, count: 200)
        let threes = types.filter { $0 == 3 }.count
        #expect(threes >= 6,
            "Auto schedule should emit 3A every cycle when RT+ is on (~7 in 200 groups); saw \(threes)")
    }

    @Test func autoSchedulerEmits11AWhenRTPlusEnabled() {
        let cfg = makeConfig(scheduler: "auto", rtPlus: true)
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let types = sampleGroupTypes(coder, count: 200)
        let elevens = types.filter { $0 == 11 }.count
        #expect(elevens >= 6,
            "Auto schedule should emit 11A every cycle when RT+ is on; saw \(elevens)")
    }

    @Test func autoSchedulerSkipsRTPlusGroupsWhenDisabled() {
        let cfg = makeConfig(scheduler: "auto", rtPlus: false)
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let types = sampleGroupTypes(coder, count: 200)
        // No RT+ enabled → no 3A or 11A registrations.
        #expect(!types.contains(3),
            "Auto schedule must not emit 3A when RT+ is off")
        #expect(!types.contains(11),
            "Auto schedule must not emit 11A when RT+ is off")
    }

    // MARK: - Standard scheduler

    @Test func standardSchedulerEmitsBoth3AAnd11AWithRTPlus() {
        let cfg = makeConfig(scheduler: "standard", rtPlus: true)
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let types = sampleGroupTypes(coder, count: 200)
        let threes = types.filter { $0 == 3 }.count
        let elevens = types.filter { $0 == 11 }.count
        #expect(threes > 0 && elevens > 0,
            "Standard schedule must emit both 3A and 11A; saw 3A=\(threes), 11A=\(elevens)")
    }

    @Test func standardSchedulerEmits10AWhenPTYNEnabled() {
        let cfg = makeConfig(scheduler: "standard", ptyn: true)
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let types = sampleGroupTypes(coder, count: 200)
        let tens = types.filter { $0 == 10 }.count
        #expect(tens > 0,
            "Standard schedule must emit 10A (PTYN) when PTYN is enabled; saw \(tens)")
    }

    @Test func standardSchedulerSkips10AWhenPTYNDisabled() {
        let cfg = makeConfig(scheduler: "standard", ptyn: false)
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let types = sampleGroupTypes(coder, count: 200)
        #expect(!types.contains(10),
            "Standard schedule must not emit 10A when PTYN is off")
    }
}
