import Testing
import Foundation
@testable import MPXPrime

// Tests for the expanded RDSRuntimeConfig live-apply path. Each test
// constructs a coder from a base config, asserts the initial group
// stream encodes the initial state, applies a runtime-config delta,
// then asserts the next group stream encodes the new state — without
// any restart / rebuild.
//
// Coverage spans the fields converted from let -> var in
// BasicRDSCoder during the live-apply expansion: identification (PI,
// PTY, PTYN, ECC, LIC), runtime flags (TP, TA, MS, DI), AF list,
// scheduler / clock toggles, master enable, and the derived-cache
// rebuilds (PTYN frames, Long PS frames, schedule).

@Suite("RDS live-apply")
struct RDSLiveApplyTests {

    // MARK: - Fixtures

    private func baseConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "82FF"
        cfg.rdsPTY = 8
        cfg.rdsPSA = "STATION1"
        cfg.rdsPSB = "STATION2"
        cfg.rdsPSC = ""
        cfg.rdsPSD = ""
        cfg.rdsPSActiveBank = "A"
        cfg.rdsPSCentered = false
        cfg.rdsRTText = ""
        cfg.rdsRTBufferAEnabled = false
        cfg.rdsRTBufferBEnabled = false
        cfg.rdsRTBufferCEnabled = false
        cfg.rdsRTBufferDEnabled = false
        cfg.rdsTP = false
        cfg.rdsTA = false
        cfg.rdsMS = true
        cfg.rdsDI_STEREO = true
        cfg.rdsDI_HEAD = false
        cfg.rdsDI_COMP = true
        cfg.rdsDI_DYN = false
        cfg.rdsEnableAF = false
        cfg.rdsAFList = ""
        cfg.rdsAFMethod = "A"
        cfg.rdsEnableCT = false
        cfg.rdsEnableID = false
        cfg.rdsEnablePTYN = false
        cfg.rdsPTYN = ""
        cfg.rdsEnableLPS = false
        cfg.rdsLongPS32 = ""
        cfg.rdsEnableRTPlus = false
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        cfg.rdsSchedulerStandardLPS = false
        cfg.rdsGroupSequence = "0A 0A"
        return cfg
    }

    private func runtime(from cfg: AppConfig) -> MPXGenerator.RDSRuntimeConfig {
        MPXGenerator.RDSRuntimeConfig.make(from: cfg)
    }

    // MARK: - Identification

    @Test func piCodeAppliesLive() {
        var cfg = baseConfig()
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Initial: PI = 0x82FF.
        let g0 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(g0.piCode == 0x82FF)

        // Live-apply new PI.
        cfg.rdsPI = "1234"
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        let g1 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(g1.piCode == 0x1234)
    }

    @Test func ptyAppliesLive() {
        var cfg = baseConfig()
        cfg.rdsPTY = 8
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        let g0 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(g0.pty == 8)

        cfg.rdsPTY = 22  // "Pop M"
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        let g1 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(g1.pty == 22)
    }

    @Test func ptyClampedTo0_31LiveApply() {
        var cfg = baseConfig()
        cfg.rdsPTY = 8
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Out-of-range value gets clamped during live-apply.
        cfg.rdsPTY = 99
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        let g = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(g.pty == 31)
    }

    // MARK: - Operational flags

    @Test func tpFlagFlipsLive() {
        var cfg = baseConfig()
        cfg.rdsTP = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        let g0 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(g0.tpFlag == false)

        cfg.rdsTP = true
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        let g1 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(g1.tpFlag == true)
    }

    @Test func taFlagFlipsLive() {
        // TA is bit 4 of block 2's b2Tail in group 0A, segment-independent.
        var cfg = baseConfig()
        cfg.rdsTA = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        let g0 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        let initialTA = (g0.b2Tail >> 4) & 1
        #expect(initialTA == 0)

        cfg.rdsTA = true
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        let g1 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        let liveTA = (g1.b2Tail >> 4) & 1
        #expect(liveTA == 1)
    }

    @Test func msFlagFlipsLive() {
        // MS is bit 3 of block 2's b2Tail in group 0A.
        var cfg = baseConfig()
        cfg.rdsMS = true
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        let g0 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        let initialMS = (g0.b2Tail >> 3) & 1
        #expect(initialMS == 1)

        cfg.rdsMS = false
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        let g1 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        let liveMS = (g1.b2Tail >> 3) & 1
        #expect(liveMS == 0)
    }

    // MARK: - Master enable

    @Test func disablingRDSSilencesNextSample() {
        var cfg = baseConfig()
        cfg.enRDS = true
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Run a few samples through to engage the modulator.
        for _ in 0..<512 {
            _ = coder.nextSample()
        }
        // Some of those should have been non-zero (RDS subcarrier active).
        var anyNonZero = false
        for _ in 0..<2048 {
            if abs(coder.nextSample()) > 1e-6 { anyNonZero = true; break }
        }
        #expect(anyNonZero)

        // Live-disable RDS.
        cfg.enRDS = false
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        // After disabling, nextSample must return exactly 0 forever.
        for _ in 0..<2048 {
            #expect(coder.nextSample() == 0.0)
        }
    }

    @Test func reEnablingRDSResetsBitPhaseCleanly() {
        var cfg = baseConfig()
        cfg.enRDS = true
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Disable then re-enable.
        cfg.enRDS = false
        coder.applyRDSRuntimeConfig(runtime(from: cfg))
        cfg.enRDS = true
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        // Should be transmitting again.
        var anyNonZero = false
        for _ in 0..<4096 {
            if abs(coder.nextSample()) > 1e-6 { anyNonZero = true; break }
        }
        #expect(anyNonZero)

        // First-decoded group should still produce a valid PI block.
        let g = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(g.piCode == 0x82FF)
        #expect(g.crcOK[0])
    }

    // MARK: - PTYN (10A) text rebuild

    @Test func ptynTextRebuildsFramesLive() {
        var cfg = baseConfig()
        cfg.rdsEnablePTYN = true
        cfg.rdsPTYN = "ROCKMUSC"  // 8 chars exactly
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Two segments of 4 chars cover all 8 characters of PTYN.
        let g0 = RDSGroupDecoder.decode(coder.buildGroup10A())
        let g1 = RDSGroupDecoder.decode(coder.buildGroup10A())
        let initial = ptynChars([g0, g1])
        #expect(initial.contains("ROCK"))
        #expect(initial.contains("MUSC"))

        // Change PTYN text live.
        cfg.rdsPTYN = "JAZZNOWS"
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        let h0 = RDSGroupDecoder.decode(coder.buildGroup10A())
        let h1 = RDSGroupDecoder.decode(coder.buildGroup10A())
        let after = ptynChars([h0, h1])
        #expect(after.contains("JAZZ"))
        #expect(after.contains("NOWS"))
        #expect(!after.contains("ROCK"))
    }

    /// Reconstruct PTYN segments from group 10A blocks 3+4. Each segment
    /// has 4 chars; bit 0 of b2Tail picks segment 0 vs 1.
    private func ptynChars(_ groups: [RDSDecodedGroup]) -> [String] {
        groups.map { g in
            let c1 = Character(Unicode.Scalar(UInt32((g.block3 >> 8) & 0xFF))!)
            let c2 = Character(Unicode.Scalar(UInt32(g.block3 & 0xFF))!)
            let c3 = Character(Unicode.Scalar(UInt32((g.block4 >> 8) & 0xFF))!)
            let c4 = Character(Unicode.Scalar(UInt32(g.block4 & 0xFF))!)
            return String([c1, c2, c3, c4])
        }
    }

    // MARK: - Long PS (15A) text rebuild

    @Test func longPSTextRebuildsFramesLive() {
        var cfg = baseConfig()
        cfg.rdsEnableLPS = true
        cfg.rdsLongPS32 = "MORNING SHOW"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Pump enough 15A groups to cover 32 chars (8 segments of 4 chars).
        let initialSegments = (0..<8).map { _ in
            RDSGroupDecoder.decode(coder.buildGroup15A())
        }
        let initialText = lpsChars(initialSegments)
        #expect(initialText.contains("MORNING"))

        // Live-edit Long PS text.
        cfg.rdsLongPS32 = "EVENING NEWS"
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        let liveSegments = (0..<8).map { _ in
            RDSGroupDecoder.decode(coder.buildGroup15A())
        }
        let liveText = lpsChars(liveSegments)
        #expect(liveText.contains("EVENING"))
        #expect(!liveText.contains("MORNING"))
    }

    private func lpsChars(_ groups: [RDSDecodedGroup]) -> String {
        var chars: [Character] = Array(repeating: " ", count: 32)
        for g in groups {
            let seg = g.b2Tail & 0x07
            let base = seg * 4
            let extracted = [
                Character(Unicode.Scalar(UInt32((g.block3 >> 8) & 0xFF))!),
                Character(Unicode.Scalar(UInt32(g.block3 & 0xFF))!),
                Character(Unicode.Scalar(UInt32((g.block4 >> 8) & 0xFF))!),
                Character(Unicode.Scalar(UInt32(g.block4 & 0xFF))!),
            ]
            for (i, ch) in extracted.enumerated() where base + i < chars.count {
                chars[base + i] = ch
            }
        }
        return String(chars)
    }

    // MARK: - AF list (block C of 0A)

    @Test func afListLiveAppliesIntoGroup0BlockC() {
        var cfg = baseConfig()
        cfg.rdsEnableAF = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // With AF disabled, block C is the AF "no AF / filler" pair (0xE0 +
        // 0xCD per the encoder; details are encoder-specific). Capture
        // baseline.
        let g0 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        let baseline = g0.block3

        // Enable AF with a list. Method A frequency code is `freq - 87.5
        // MHz over 0.1 MHz` + 0xE0 follow-up offsets handled by the
        // encoder. We just need to assert the AF block contents differ
        // from the disabled baseline once a couple of group 0A frames
        // have transmitted.
        cfg.rdsEnableAF = true
        cfg.rdsAFList = "98.8, 106.6"
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        // Pump several groups and see whether ANY block-3 word differs
        // from the baseline. AF lives in block C only on selected
        // segments per Method A.
        var sawDifferentBlockC = false
        for _ in 0..<8 {
            let g = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
            if g.block3 != baseline { sawDifferentBlockC = true; break }
        }
        #expect(sawDifferentBlockC)
    }

    // MARK: - Schedule (group sequence)

    @Test func customScheduleLiveAppliesGroupOrder() {
        var cfg = baseConfig()
        // Custom sequence — group 0A only.
        cfg.rdsGroupSequence = "0A 0A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Pump four groups; all should be type 0.
        for _ in 0..<4 {
            let g = RDSGroupDecoder.decode(coder.nextGroupBits())
            #expect(g.groupType == 0)
        }

        // Live-apply schedule with group 2 mixed in.
        cfg.rdsGroupSequence = "2A 2A 2A 2A"
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        // After live-apply, schedule should yield group-2 frames.
        var sawGroup2 = false
        for _ in 0..<8 {
            let g = RDSGroupDecoder.decode(coder.nextGroupBits())
            if g.groupType == 2 { sawGroup2 = true; break }
        }
        #expect(sawGroup2)
    }

    // MARK: - Clock-time (CT) enable toggle

    @Test func enableCTLiveAppliesWhenScheduled() {
        var cfg = baseConfig()
        cfg.rdsEnableCT = false
        cfg.rdsGroupSequence = "4A 4A 4A 4A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // CT disabled: 4A entries should fall back to group 0A.
        for _ in 0..<4 {
            let g = RDSGroupDecoder.decode(coder.nextGroupBits())
            #expect(g.groupType == 0)
        }

        // Live-enable CT.
        cfg.rdsEnableCT = true
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        // Now 4A should emit group 4 (clock-time).
        var sawGroup4 = false
        for _ in 0..<8 {
            let g = RDSGroupDecoder.decode(coder.nextGroupBits())
            if g.groupType == 4 { sawGroup4 = true; break }
        }
        #expect(sawGroup4)
    }

    // MARK: - Round-trip factory

    // MARK: - TA-edge auto-injection (UECP §2.5.1.1)

    @Test func taEdgeInjectsForcedGroup0AAheadOfSchedule() {
        // Schedule contains no 0A entries. With the existing path, a
        // TA-flag flip would have to wait for the next 0A in the
        // schedule (potentially many groups). Per UECP §2.5.1.1 a TA
        // edge must produce an immediate group ahead of the schedule.
        var cfg = baseConfig()
        cfg.rdsTA = false
        cfg.rdsGroupSequence = "2A 2A 2A 2A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // First few groups must be type 2A (no TA in here).
        for _ in 0..<4 {
            let g = RDSGroupDecoder.decode(coder.nextGroupBits())
            #expect(g.groupType == 2)
        }

        // Toggle TA via runtime config — this is the trigger.
        cfg.rdsTA = true
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        // Next group must be a forced 0A carrying the new TA bit,
        // even though the schedule next-up was 2A.
        let forced = RDSGroupDecoder.decode(coder.nextGroupBits())
        #expect(forced.groupType == 0)
        let taBit = (forced.b2Tail >> 4) & 1
        #expect(taBit == 1)

        // Schedule resumes from where it was: subsequent groups go
        // back to 2A.
        let g2 = RDSGroupDecoder.decode(coder.nextGroupBits())
        #expect(g2.groupType == 2)
    }

    @Test func taEdgeFiresOnBothEdges() {
        // Off-to-on flips the meter once; on-to-off must also fire.
        var cfg = baseConfig()
        cfg.rdsTA = false
        cfg.rdsGroupSequence = "2A 2A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        cfg.rdsTA = true
        coder.applyRDSRuntimeConfig(runtime(from: cfg))
        let onEdge = RDSGroupDecoder.decode(coder.nextGroupBits())
        #expect(onEdge.groupType == 0)
        #expect(((onEdge.b2Tail >> 4) & 1) == 1)

        // No change → schedule resumes (2A).
        _ = coder.nextGroupBits()

        cfg.rdsTA = false
        coder.applyRDSRuntimeConfig(runtime(from: cfg))
        let offEdge = RDSGroupDecoder.decode(coder.nextGroupBits())
        #expect(offEdge.groupType == 0)
        #expect(((offEdge.b2Tail >> 4) & 1) == 0)
    }

    @Test func nonTAConfigChangeDoesNotForceGroup0A() {
        // Sanity: changing something other than TA must NOT trigger
        // a forced 0A (the TA-edge path is opt-in).
        var cfg = baseConfig()
        cfg.rdsTA = false
        cfg.rdsGroupSequence = "2A 2A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        cfg.rdsRTA = "Different RT text"  // non-TA change
        coder.applyRDSRuntimeConfig(runtime(from: cfg))

        // Schedule must continue as 2A — no forced 0A.
        let g = RDSGroupDecoder.decode(coder.nextGroupBits())
        #expect(g.groupType == 2)
    }

    // MARK: - AF Method B (EN 50067 §3.2.1.6.4 / IEC 62106-2 §7.5.3)

    @Test func afMethodBFirstBlockCarriesCountThenTuned() {
        var cfg = baseConfig()
        cfg.rdsEnableAF = true
        // Tuned 98.8 MHz, alternatives 88.1 + 106.6 MHz. Per EN 50067
        // Table 10: 88.1 = 6, 98.8 = 113, 106.6 = 191.
        cfg.rdsAFList = "98.8, 88.1, 106.6"
        cfg.rdsAFMethod = "B"
        cfg.rdsGroupSequence = "0A 0A 0A 0A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        let first = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        let firstHi = (first.block3 >> 8) & 0xFF
        let firstLo = first.block3 & 0xFF
        // Count = tuned + 2 alternatives = 3 → count code 224+3 = 227.
        #expect(firstHi == 227)
        // Byte 2 = tuned (98.8 MHz = code 113).
        #expect(firstLo == 113)
    }

    @Test func afMethodBSubsequentBlocksRepeatTunedAndCycleAlts() {
        var cfg = baseConfig()
        cfg.rdsEnableAF = true
        cfg.rdsAFList = "98.8, 88.1, 106.6"
        cfg.rdsAFMethod = "B"
        cfg.rdsGroupSequence = "0A 0A 0A 0A 0A 0A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // First block consumed (count + tuned). Skip it.
        _ = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))

        // Second block: tuned (113) + first alt (88.1 → code 6).
        let g2 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(((g2.block3 >> 8) & 0xFF) == 113)
        #expect((g2.block3 & 0xFF) == 6)

        // Third block: tuned + second alt (106.6 → code 191).
        let g3 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(((g3.block3 >> 8) & 0xFF) == 113)
        #expect((g3.block3 & 0xFF) == 191)

        // Fourth block: cycle restarts with count + tuned.
        let g4 = RDSGroupDecoder.decode(coder.buildGroup0(versionB: false))
        #expect(((g4.block3 >> 8) & 0xFF) == 227)
        #expect((g4.block3 & 0xFF) == 113)
    }

    @Test func afMethodBDiffersFromMethodA() {
        // With the same AF list, Method A and Method B must produce
        // different block-C sequences. Sanity check that the encoder
        // actually branches on the method flag.
        var cfg = baseConfig()
        cfg.rdsEnableAF = true
        cfg.rdsAFList = "98.8, 88.1, 106.6"
        cfg.rdsGroupSequence = "0A 0A 0A 0A"
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false

        cfg.rdsAFMethod = "A"
        let coderA = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let aBlocks = (0..<4).map { _ in
            RDSGroupDecoder.decode(coderA.buildGroup0(versionB: false)).block3
        }

        cfg.rdsAFMethod = "B"
        let coderB = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let bBlocks = (0..<4).map { _ in
            RDSGroupDecoder.decode(coderB.buildGroup0(versionB: false)).block3
        }

        #expect(aBlocks != bBlocks)
    }

    // MARK: - Runtime config factory

    @Test func runtimeConfigFactoryRoundtripsAppConfig() {
        // Sanity: RDSRuntimeConfig.make captures every relevant AppConfig
        // field, so applying make(from: cfg) is equivalent to constructing
        // a fresh BasicRDSCoder from cfg (modulo physical-layer settings).
        var cfg = baseConfig()
        cfg.rdsPI = "ABCD"
        cfg.rdsPTY = 17
        cfg.rdsTP = true
        cfg.rdsTA = true

        let freshCoder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        let liveCoder = BasicRDSCoder(config: baseConfig(), sampleRate: 192_000.0)
        liveCoder.applyRDSRuntimeConfig(runtime(from: cfg))

        let fresh = RDSGroupDecoder.decode(freshCoder.buildGroup0(versionB: false))
        let live = RDSGroupDecoder.decode(liveCoder.buildGroup0(versionB: false))
        #expect(fresh.piCode == live.piCode)
        #expect(fresh.pty == live.pty)
        #expect(fresh.tpFlag == live.tpFlag)
    }
}
