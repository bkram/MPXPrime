import Testing
import Foundation
@testable import MPXPrime
@testable import MPXPrimeCore

// Round-trip the receive-side RDSStreamDecoder (MPXPrimeCore) against the
// transmit-side BasicRDSCoder (MPXPrime). The encoder emits a continuous bit
// stream; the decoder must acquire block sync from an arbitrary start phase,
// then recover PI / PTY / TP / TA / MS and reconstruct the PS name -- proving
// the two stay in lockstep on the BCH/offset/field conventions.

@Suite("RDS stream decoder")
struct RDSStreamDecoderTests {

    private func makeConfig(
        piHex: String = "1234",
        pty: Int = 15,
        tp: Bool = true,
        ta: Bool = true,
        ms: Bool = true,
        ps: String = "HELLO"
    ) -> AppConfig {
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = piHex
        cfg.rdsPTY = pty
        cfg.rdsTP = tp
        cfg.rdsTA = ta
        cfg.rdsMS = ms
        cfg.rdsPSA = ps
        cfg.rdsPSActiveBank = "A"
        return cfg
    }

    /// Emit `count` group-0A bitstreams and concatenate into one stream,
    /// optionally prefixed with `junk` leading bits to force the decoder to
    /// acquire sync mid-stream rather than at a convenient boundary.
    private func emitStream(_ coder: BasicRDSCoder, groups: Int, junk: Int) -> [UInt8] {
        var bits: [UInt8] = []
        // Arbitrary, deterministic non-zero junk so the search path has to
        // reject garbage before locking (zeros would be too kind).
        for i in 0..<junk { bits.append(UInt8((i * 7 + 3) & 1)) }
        for _ in 0..<groups { bits.append(contentsOf: coder.buildGroup0(versionB: false)) }
        return bits
    }

    @Test func syndromeOfValidBlockEqualsItsOffsetSyndrome() {
        // Lowest-level invariant the sync relies on: a freshly-built valid
        // block's 26-bit syndrome equals the syndrome of the offset word it
        // used. If this holds for all four blocks, the encoder and decoder
        // share the BCH convention.
        let coder = BasicRDSCoder(config: makeConfig(), sampleRate: 192_000.0)
        let group = coder.buildGroup0(versionB: false)
        func block(_ slot: Int) -> Int {
            var v = 0
            for i in 0..<26 { v = (v << 1) | Int(group[slot * 26 + i]) }
            return v
        }
        #expect(RDSStreamDecoder.syndrome(block(0)) == RDSStreamDecoder.syndrome(0x0FC)) // A
        #expect(RDSStreamDecoder.syndrome(block(1)) == RDSStreamDecoder.syndrome(0x198)) // B
        #expect(RDSStreamDecoder.syndrome(block(2)) == RDSStreamDecoder.syndrome(0x168)) // C (0A)
        #expect(RDSStreamDecoder.syndrome(block(3)) == RDSStreamDecoder.syndrome(0x1B4)) // D
    }

    @Test(arguments: [0, 13, 26, 37, 51, 70])
    func acquiresSyncAndRecoversFieldsFromAnyStartPhase(junk: Int) {
        let coder = BasicRDSCoder(config: makeConfig(), sampleRate: 192_000.0)
        let stream = emitStream(coder, groups: 16, junk: junk)

        let decoder = RDSStreamDecoder()
        var emitted = 0
        for bit in stream where decoder.feed(bit: bit) != nil { emitted += 1 }

        let state = decoder.state
        #expect(state.synced, "decoder failed to lock with \(junk) junk lead bits")
        #expect(emitted >= 8, "expected most of 16 groups to decode, got \(emitted)")
        #expect(state.pi == 0x1234)
        #expect(state.pty == 15)
        #expect(state.tp == true)
        #expect(state.ta == true)
        #expect(state.ms == true)
        // "HELLO" centered in 8 chars (default rdsPSCentered = true) -> " HELLO  ".
        #expect(state.programService == " HELLO  ")
        // Block error rate is cumulative and includes the acquisition
        // transient: a junk lead-in can cause one spurious early lock (a
        // group of mostly-bad blocks) before the decoder drops and re-locks
        // cleanly. Over this short 16-group window that is a few percent; over
        // a real continuous stream it converges to ~0. Bound it loosely here
        // to prove "locked and mostly clean", not steady-state perfection.
        #expect(state.blockErrorRate < 0.15, "block error rate \(state.blockErrorRate) too high once locked")
    }

    @Test func emitsGroupsWithAllBlocksValidOnceLocked() {
        let coder = BasicRDSCoder(config: makeConfig(piHex: "ABCD"), sampleRate: 192_000.0)
        let stream = emitStream(coder, groups: 10, junk: 0)

        let decoder = RDSStreamDecoder()
        var groups: [RDSGroup] = []
        for bit in stream {
            if let g = decoder.feed(bit: bit) { groups.append(g) }
        }
        #expect(groups.count >= 9)
        // Aligned start (junk = 0) -> every emitted group should be clean.
        for g in groups {
            #expect(g.allBlocksValid)
            #expect(g.pi == 0xABCD)
            #expect(g.groupType == 0)
            #expect(g.versionB == false)
        }
    }

    @Test func groupOrderTracksTransmissionSequenceAndIsCapped() {
        // The counts say WHAT an encoder sends; the order says how it
        // interleaves -- the thing that exposes a scheduler pattern or a
        // starved group type. A 0A/2A alternation must show up as one.
        var cfg = makeConfig(piHex: "83E1")
        cfg.rdsRTText = "Group order under test"
        // Explicit alternation: the auto/standard scheduler layers would
        // otherwise inject their own groups and blur the pattern.
        cfg.rdsSchedulerAuto = false
        cfg.rdsSchedulerStandard = false
        cfg.rdsSchedulerStandardLPS = false
        cfg.rdsGroupSequence = "0A 2A"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        // nextGroupBits() follows the scheduler; emitStream() is hard-wired
        // to 0A and would show no interleaving at all.
        var stream: [UInt8] = []
        for _ in 0..<30 { stream.append(contentsOf: coder.nextGroupBits()) }

        let decoder = RDSStreamDecoder()
        for bit in stream { decoder.feed(bit: bit) }
        let order = decoder.state.groupOrder
        #expect(!order.isEmpty)
        // Never grows past the ring capacity, however long the stream runs.
        #expect(order.count <= RDSReceiverState.groupOrderCapacity)
        // Buckets are groupType*2 + (B ? 1 : 0): 0A = 0, 2A = 4.
        #expect(order.allSatisfy { $0 == 0 || $0 == 4 })
        #expect(order.contains(0))
        #expect(order.contains(4))
        // Alternating, so no three consecutive entries are the same type.
        for i in 2..<order.count {
            #expect(!(order[i] == order[i - 1] && order[i] == order[i - 2]))
        }
        decoder.reset()
        #expect(decoder.state.groupOrder.isEmpty)
    }

    @Test func resetClearsAccumulatedState() {
        let coder = BasicRDSCoder(config: makeConfig(), sampleRate: 192_000.0)
        let stream = emitStream(coder, groups: 8, junk: 0)
        let decoder = RDSStreamDecoder()
        for bit in stream { decoder.feed(bit: bit) }
        #expect(decoder.state.synced)

        decoder.reset()
        let fresh = decoder.state
        #expect(!fresh.synced)
        #expect(fresh.pi == nil)
        #expect(fresh.programService == "        ")
        #expect(fresh.groupsDecoded == 0)
        #expect(fresh.radioText == "")
        #expect(fresh.clockTime == nil)
    }

    @Test func recoversRadioTextFromGroup2A() {
        var cfg = makeConfig()
        // RT comes from the manual buffers; enable only A so a single message
        // transmits without buffer-switch resets.
        cfg.rdsRTA = "NOW PLAYING TEST"
        cfg.rdsRTBufferAEnabled = true
        cfg.rdsRTBufferBEnabled = false
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        var bits: [UInt8] = []
        // 16 segments cover the full 64-char RadioText; emit a couple cycles.
        for _ in 0..<24 { bits.append(contentsOf: coder.buildGroup2(versionB: false)) }

        let decoder = RDSStreamDecoder()
        for bit in bits { decoder.feed(bit: bit) }
        #expect(decoder.state.radioText.contains("NOW PLAYING TEST"),
                "RadioText was '\(decoder.state.radioText)'")
    }

    @Test func recoversProgramTypeNameFromGroup10A() {
        var cfg = makeConfig()
        cfg.rdsEnablePTYN = true
        cfg.rdsPTYN = "ROCK"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        var bits: [UInt8] = []
        for _ in 0..<8 { bits.append(contentsOf: coder.buildGroup10A()) }

        let decoder = RDSStreamDecoder()
        for bit in bits { decoder.feed(bit: bit) }
        #expect(decoder.state.programTypeName.contains("ROCK"),
                "PTYN was '\(decoder.state.programTypeName)'")
    }

    @Test func recoversLongPSFromGroup15A() {
        var cfg = makeConfig()
        cfg.rdsEnableLPS = true
        cfg.rdsLongPS32 = "LONG STATION NAME"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
        var bits: [UInt8] = []
        // 8 segments cover the 32-char Long PS; emit a couple cycles.
        for _ in 0..<16 { bits.append(contentsOf: coder.buildGroup15A()) }

        let decoder = RDSStreamDecoder()
        for bit in bits { decoder.feed(bit: bit) }
        #expect(decoder.state.longPS.contains("LONG STATION NAME"),
                "Long PS was '\(decoder.state.longPS)'")
    }

    @Test func recoversRTPlusTagsFromGroup11A() {
        var cfg = makeConfig()
        // RT carries the item; RT+ format marks artist/title positions in it.
        // Trailing "!" bounds the {title} capture (the encoder's generic RT+
        // matcher is non-greedy, so an unbounded trailing {title} would clip
        // to one char -- that is a transmit-side regex quirk, not a decode
        // issue; here we test a clean, fully-bounded tagging).
        cfg.rdsRTA = "Now: Chris Rea - Josephine!"
        cfg.rdsRTBufferAEnabled = true
        cfg.rdsRTBufferBEnabled = false
        cfg.rdsEnableRTPlus = true
        cfg.rdsRTPlusFormatA = "Now: {artist} - {title}!"
        let coder = BasicRDSCoder(config: cfg, sampleRate: 192_000.0)

        // Interleave 2A (fills RT + computes RT+ tags) and 11A (emits tags).
        var bits: [UInt8] = []
        for _ in 0..<40 {
            bits.append(contentsOf: coder.buildGroup2(versionB: false))
            bits.append(contentsOf: coder.buildGroup11A())
        }

        let decoder = RDSStreamDecoder()
        for bit in bits { decoder.feed(bit: bit) }
        let tags = decoder.state.rtPlusTags
        #expect(!tags.isEmpty, "no RT+ tags decoded")
        // Content type 1 = ITEM.TITLE, 4 = ITEM.ARTIST.
        let title = tags.first { $0.contentType == 1 }?.text
        let artist = tags.first { $0.contentType == 4 }?.text
        #expect(title == "Josephine", "RT+ title was '\(title ?? "nil")'")
        #expect(artist == "Chris Rea", "RT+ artist was '\(artist ?? "nil")'")
    }

    @Test func gregorianFromMJDMatchesKnownDates() {
        // MJD 58849 = 2020-01-01, 59945 = 2023-01-01 (MJD = JD - 2400000.5).
        let a = RDSStreamDecoder.gregorian(fromMJD: 58849)
        #expect(a == (2020, 1, 1), "got \(a)")
        let b = RDSStreamDecoder.gregorian(fromMJD: 59945)
        #expect(b == (2023, 1, 1), "got \(b)")
    }
}
