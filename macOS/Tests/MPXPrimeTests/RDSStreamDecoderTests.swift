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
    }
}
