import Foundation
import MPXPrimeCore
import Testing

@testable import MPXPrime

// Restart-equals-live parity for the RDS runtime (the issues.txt "now-playing
// off after an API restart" class). Two AppConfig -> coder mappings exist:
//
//   A. `BasicRDSCoder.init(config:)` -- the path a REBUILT engine takes
//      (API `transport/restart`, systemd restart, GUI restart).
//   B. default-ish init + `applyRDSRuntimeConfig(RDSRuntimeConfig.make(from:))`
//      -- the LIVE-apply path a running engine takes on a config PATCH.
//
// The init is a hand-written duplicate of the canonical make()+apply mapping;
// nothing else pins them together. This suite does: a coder built from a
// maximally non-default config via path A must emit a BIT-IDENTICAL group
// stream to a coder that reached the same config via path B. Any field that
// init and make() read differently breaks the bit comparison immediately.
//
// When adding a field to RDSRuntimeConfig, extend `richConfig()` with a
// non-default value for it (and `neutralConfig()` with a different one) so
// the new field is covered by the parity contract.
@Suite("RDS restart-vs-live-apply parity")
struct RDSRestartParityTests {

    /// Non-default value for every live field RDSRuntimeConfig carries.
    /// Deliberately excluded, with reasons:
    /// - enCT / enID: 4A/1A(variant) emission is wall-clock minute-aligned --
    ///   nondeterministic across the two emission runs.
    /// - rdsTA: identical in both configs. A TA CHANGE through live apply
    ///   intentionally schedules a forced 0A (UECP 2.5.1.1) that a fresh init
    ///   does not -- a legitimate transient divergence, not a parity bug.
    /// - rt_manual_buffers / rt_cycle / rt_active_buffer: outside
    ///   RDSRuntimeConfig (restart-only by ConfigPatch's derived
    ///   classification), so both paths read them from init; identical here.
    private func richConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0                    // restart-only; same in neutral
        cfg.rdsPI = "D3A5"
        cfg.rdsPTY = 17
        cfg.rdsTP = true
        cfg.rdsTA = false                     // see header: same in neutral
        cfg.rdsMS = false
        cfg.rdsDI_STEREO = false
        cfg.rdsDI_HEAD = true
        cfg.rdsDI_COMP = true
        cfg.rdsDI_DYN = true
        cfg.rdsPSA = "BANK-A"
        cfg.rdsPSB = "BANK-B"
        cfg.rdsPSC = "PARITYFM"
        cfg.rdsPSD = "BANK-D"
        cfg.rdsPSActiveBank = "C"
        cfg.rdsPSCentered = true
        cfg.rdsPSFrameSeconds = 2.0
        cfg.rdsEnablePTYN = true
        cfg.rdsPTYN = "DANCEFLR"
        cfg.rdsPTYNCentered = true
        cfg.rdsECC = "E2"
        cfg.rdsLIC = "23"
        cfg.rdsEnableLPS = true
        cfg.rdsLongPS32 = "Parity Test Station Long Name"
        cfg.rdsLPSCentered = true
        cfg.rdsLPSCR = true
        cfg.rdsRTText = "NOW {artist} - {title}"
        cfg.rdsRTA = "Buffer A text"
        cfg.rdsRTB = "Buffer B text"
        cfg.rdsRTC = "Buffer C text"
        cfg.rdsRTD = "Buffer D text"
        cfg.rdsRTBufferAEnabled = true
        cfg.rdsRTBufferBEnabled = false
        cfg.rdsRTBufferCEnabled = true
        cfg.rdsRTBufferDEnabled = false
        cfg.rdsRTCR = true
        cfg.rdsRTCentered = true
        cfg.rdsRTMode = "2A"
        cfg.rdsRTCycleTime = 7.0
        cfg.rdsRTCycleAB = true
        cfg.rdsRTABCycleCount = 2
        cfg.rdsEnableRTPlus = true
        cfg.rdsNowPlayingEnabled = true
        cfg.rdsEnableAF = true
        cfg.rdsAFList = "98.5, 101.1, 87.6"  // comma-separated (parseAFList contract)
        cfg.rdsAFMethod = "A"
        cfg.rdsEnableCT = false               // see header
        cfg.rdsEnableID = false               // see header
        cfg.rdsTZOffset = 5.5
        cfg.rdsGroupSequence = "0A 1A 2A 0A 10A 15A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        cfg.rdsSchedulerStandardLPS = false
        return cfg
    }

    /// Differs from richConfig on every live field (so the apply genuinely
    /// changes each one); identical on the restart-only and excluded fields.
    private func neutralConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "1234"
        cfg.rdsPTY = 3
        cfg.rdsTP = false
        cfg.rdsTA = false
        cfg.rdsMS = true
        cfg.rdsPSA = "NEUTRAL"
        cfg.rdsPSActiveBank = "A"
        cfg.rdsRTText = "neutral radiotext"
        cfg.rdsEnableAF = false
        cfg.rdsEnablePTYN = false
        cfg.rdsEnableLPS = false
        cfg.rdsEnableRTPlus = false
        cfg.rdsNowPlayingEnabled = false
        cfg.rdsEnableCT = false
        cfg.rdsEnableID = false
        cfg.rdsGroupSequence = "0A 0A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        cfg.rdsSchedulerStandardLPS = false
        return cfg
    }

    private func emit(_ coder: BasicRDSCoder, groups: Int) -> [UInt8] {
        var bits: [UInt8] = []
        for _ in 0..<groups { bits.append(contentsOf: coder.nextGroupBits()) }
        return bits
    }

    @Test func rebuiltCoderMatchesLiveAppliedCoderBitForBit() {
        let rich = richConfig()
        let state = NowPlayingState()
        state.update(display: "UB40 - Sing Our Own Song",
                     artist: "UB40", title: "Sing Our Own Song")

        // Path A: the restart/rebuild path (engine factory after
        // transport/restart, systemd start, GUI restart).
        let rebuilt = BasicRDSCoder(
            config: rich, sampleRate: 192_000.0, nowPlayingState: state)

        // Path B: the live path -- a running coder PATCHed to the same config.
        let live = BasicRDSCoder(
            config: neutralConfig(), sampleRate: 192_000.0, nowPlayingState: state)
        live.applyRDSRuntimeConfig(MPXGenerator.RDSRuntimeConfig.make(from: rich))

        let bitsA = emit(rebuilt, groups: 60)
        let bitsB = emit(live, groups: 60)
        #expect(bitsA.count == bitsB.count)
        #expect(bitsA == bitsB)
    }

    @Test func rebuiltCoderAirsTheFullConfiguredState() {
        // Content check on the REBUILT coder alone: everything the rich
        // config sets must actually reach a receiver -- including the
        // now-playing track, the literal reported failure.
        var rich = richConfig()
        // Two deviations from the parity fixture, both because THIS test
        // checks airing, not mapping parity:
        // - enabled manual RT buffers OVERRIDE the now-playing template by
        //   design (currentRTFrame checks them first), so disable them here
        //   or the template can never air;
        // - 1A (which carries the ECC) is gated on en_id, excluded from the
        //   parity fixture only because the 1A variant selector could race a
        //   background timer across two coders -- irrelevant with one coder.
        rich.rdsRTBufferAEnabled = false
        rich.rdsRTBufferBEnabled = false
        rich.rdsRTBufferCEnabled = false
        rich.rdsRTBufferDEnabled = false
        rich.rdsEnableID = true
        let state = NowPlayingState()
        state.update(display: "UB40 - Sing Our Own Song",
                     artist: "UB40", title: "Sing Our Own Song")
        let coder = BasicRDSCoder(
            config: rich, sampleRate: 192_000.0, nowPlayingState: state)

        // 1A alternates ECC / LIC on a WALL-CLOCK 2 s window (epoch/2 & 1,
        // refreshed by the coder's 1 Hz clock-cache timer), so a single burst
        // of groups sees only one variant. Emit in short timed rounds until
        // the ECC variant has aired -- bounded by ~3 s, never flaky: an
        // even window arrives within 2 s and the timer republishes each 1 s.
        let decoder = RDSStreamDecoder()
        var airedRT = Set<String>()
        for round in 0..<30 {
            for bit in emit(coder, groups: 40) {
                decoder.feed(bit: bit)
                if !decoder.state.radioText.isEmpty { airedRT.insert(decoder.state.radioText) }
            }
            if decoder.state.ecc != nil { break }
            if round < 29 { Thread.sleep(forTimeInterval: 0.1) }
        }
        let s = decoder.state

        #expect(s.pi == 0xD3A5)
        #expect(s.pty == 17)
        #expect(s.tp == true)
        #expect(s.ta == false)
        #expect(s.ms == false)
        #expect(s.programService.trimmingCharacters(in: .whitespaces) == "PARITYFM")
        #expect(airedRT.contains { $0.contains("UB40") && $0.contains("Sing Our Own Song") })
        #expect(s.programTypeName.trimmingCharacters(in: .whitespaces) == "DANCEFLR")
        #expect(s.longPS.contains("Parity Test Station"))
        #expect(s.ecc == 0xE2)
        let af = Set(s.alternativeFrequenciesMHz.map { ($0 * 10).rounded() / 10 })
        #expect(af.isSuperset(of: [98.5, 101.1, 87.6]))
    }
}
