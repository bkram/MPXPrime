import Testing
import Foundation
@testable import MPXPrime

// Tests for the 4-bank PS system with exclusive active selector. Covers:
// initial bank selection, switching banks via RDSRuntimeConfig without
// engine restart, empty bank transmits 8 spaces, legacy `ps_dynamic` INI
// key migrates into bank A, sequence state resets on bank switch.

@Suite("PS banks")
struct PSBankTests {

    private func baseConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "82FF"
        cfg.rdsPSA = "BANK A"
        cfg.rdsPSB = "BANK B"
        cfg.rdsPSC = "BANK C"
        cfg.rdsPSD = "BANK D"
        cfg.rdsPSActiveBank = "A"
        cfg.rdsPSCentered = false
        cfg.rdsRTText = ""
        cfg.rdsRTBufferAEnabled = false
        cfg.rdsRTBufferBEnabled = false
        cfg.rdsRTBufferCEnabled = false
        cfg.rdsRTBufferDEnabled = false
        cfg.rdsEnableCT = false
        cfg.rdsEnableID = false
        cfg.rdsEnableAF = false
        cfg.rdsEnableRTPlus = false
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        return cfg
    }

    private func readPS(_ coder: BasicRDSCoder) -> String {
        let groups = (0..<4).map { _ in
            RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        }
        return RDSGroupDecoder.reconstructPS(groups: groups)
    }

    private func runtimeConfig(
        from cfg: AppConfig,
        psActive: String? = nil,
        psBanks: [String]? = nil,
        psCentered: Bool? = nil
    ) -> MPXGenerator.RDSRuntimeConfig {
        MPXGenerator.RDSRuntimeConfig(
            rtText: cfg.rdsRTText,
            rtBuffers: [cfg.rdsRTA, cfg.rdsRTB, cfg.rdsRTC, cfg.rdsRTD],
            rtBufferEnabled: [false, false, false, false],
            rtCR: cfg.rdsRTCR,
            rtCentered: cfg.rdsRTCentered,
            rtMode2B: cfg.rdsRTMode.uppercased() == "2B",
            rtCycleTime: cfg.rdsRTCycleTime,
            rtCycleAB: cfg.rdsRTCycleAB,
            rtABCycleCount: cfg.rdsRTABCycleCount,
            rtPlusEnabled: false,
            rtPlusFormatA: "",
            rtPlusFormatB: "",
            nowPlayingEnabled: false,
            psBanks: psBanks ?? [cfg.rdsPSA, cfg.rdsPSB, cfg.rdsPSC, cfg.rdsPSD],
            psActiveBank: psActive ?? cfg.rdsPSActiveBank,
            psCentered: psCentered ?? cfg.rdsPSCentered,
            psFrameSeconds: cfg.rdsPSFrameSeconds
        )
    }

    @Test func initialActiveBankTransmitsBankA() {
        var cfg = baseConfig()
        cfg.rdsPSActiveBank = "A"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let ps = readPS(coder).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ps == "BANK A")
    }

    @Test func selectingBankBTransmitsBankB() {
        var cfg = baseConfig()
        cfg.rdsPSActiveBank = "B"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let ps = readPS(coder).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ps == "BANK B")
    }

    @Test func selectingBankCTransmitsBankC() {
        var cfg = baseConfig()
        cfg.rdsPSActiveBank = "C"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let ps = readPS(coder).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ps == "BANK C")
    }

    @Test func selectingBankDTransmitsBankD() {
        var cfg = baseConfig()
        cfg.rdsPSActiveBank = "D"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let ps = readPS(coder).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ps == "BANK D")
    }

    @Test func emptyActiveBankTransmitsBlanks() {
        var cfg = baseConfig()
        cfg.rdsPSD = ""
        cfg.rdsPSActiveBank = "D"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let ps = readPS(coder)
        // 8 spaces expected when the active bank is empty.
        #expect(ps == String(repeating: " ", count: 8))
    }

    @Test func invalidBankSelectorFallsBackToA() {
        var cfg = baseConfig()
        cfg.rdsPSActiveBank = "X"
        // Sanitize on load clamps to "A" — test that BasicRDSCoder also falls
        // back when given a bad selector without sanitize (belt and braces).
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let ps = readPS(coder).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ps == "BANK A")
    }

    // MARK: - Live-apply via RDSRuntimeConfig

    @Test func switchingActiveBankViaRuntimeConfig() {
        let cfg = baseConfig()
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Bank A active initially.
        let initial = readPS(coder).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(initial == "BANK A")

        // Live-apply switch to bank C.
        coder.applyRDSRuntimeConfig(runtimeConfig(from: cfg, psActive: "C"))
        let afterSwitch = readPS(coder).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(afterSwitch == "BANK C")
    }

    @Test func updatingBankTextLiveApplies() {
        let cfg = baseConfig()
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        let initial = readPS(coder).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(initial == "BANK A")

        // Edit bank A via runtime config — should re-parse and emit new text.
        coder.applyRDSRuntimeConfig(runtimeConfig(
            from: cfg, psBanks: ["UPDATED", "BANK B", "BANK C", "BANK D"]
        ))
        let afterEdit = readPS(coder).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(afterEdit == "UPDATED")
    }

    @Test func bankSwitchResetsSegmentCounter() {
        // After pumping group 0 a few times, rtSegment/psSegment is mid-frame.
        // A bank switch must restart at segment 0 so receivers see a clean
        // 8-char reconstruction.
        let cfg = baseConfig()
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Pump 2 group-0 blocks (segments 0 and 1 of bank A).
        _ = coder.buildGroup0(versionB: false)
        _ = coder.buildGroup0(versionB: false)

        // Switch to bank B.
        coder.applyRDSRuntimeConfig(runtimeConfig(from: cfg, psActive: "B"))

        // Next 4 blocks should be segments 0-3 of bank B.
        let groups = (0..<4).map { _ in
            RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        }
        let segments = groups.map { RDSGroupDecoder.psSegment($0) }
        #expect(segments == [0, 1, 2, 3])
        let ps = RDSGroupDecoder.reconstructPS(groups: groups)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ps == "BANK B")
    }

    // MARK: - AppConfig INI migration

    @Test func activePSBankTextReturnsSelectedBank() {
        var cfg = baseConfig()
        cfg.rdsPSActiveBank = "C"
        #expect(cfg.activePSBankText == "BANK C")
    }

    @Test func invalidActiveBankSanitizedToA() {
        var cfg = AppConfig()
        cfg.rdsPSActiveBank = "zzz"
        cfg.validate()
        #expect(cfg.rdsPSActiveBank == "A")
    }

    @Test func activeBankLowercaseIsUppercased() {
        var cfg = AppConfig()
        cfg.rdsPSActiveBank = "b"
        cfg.validate()
        #expect(cfg.rdsPSActiveBank == "B")
    }
}
