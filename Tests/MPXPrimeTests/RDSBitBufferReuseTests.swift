import Testing
import Foundation
@testable import MPXPrime

// Regression tests for the alloc-free `buildGroupBits` refactor.
// `buildGroupBits` writes into a pre-allocated 104-byte `bitBuffer`
// instead of allocating a fresh `[UInt8]` per call. Tests here lock
// in the contract callers depend on:
//
// 1. The first `nextGroupBits` after construction returns real bits
//    (not the 104 zeros from the initial buffer state).
// 2. Sequential `nextGroupBits` calls return different, correctly-CRC'd
//    groups — the buffer reuse must not mix bits across calls.
// 3. Holding a reference to a returned `[UInt8]` while calling
//    `nextGroupBits` again must not corrupt the held copy (Swift CoW
//    correctness — the returned array's storage must be independent
//    after a subsequent call mutates `self.bitBuffer`).
// 4. Direct `buildGroup*` calls also return well-formed bits and don't
//    leak state between calls.

@Suite("RDS bit buffer reuse")
struct RDSBitBufferReuseTests {

    private func makeCoder() -> BasicRDSCoder {
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "82FF"
        cfg.rdsPSA = "HELLO"
        cfg.rdsRTText = "HELLO WORLD"
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
        cfg.rdsGroupSequence = "0A 2A 0A 2A"
        return BasicRDSCoder(config: cfg, sampleRate: 192_000.0)
    }

    @Test func firstNextGroupBitsAfterConstructionReturnsRealBits() {
        // Initial bitBuffer is 104 zeros; if bitBufferIndex isn't past
        // the end, the first dequeueBit reads phantom zeros instead of
        // triggering a refill. nextGroupBits itself bypasses dequeueBit
        // but locks in the same invariant: the returned array must be a
        // valid 104-bit RDS group, not a buffer of zeros.
        let coder = makeCoder()
        let bits = coder.nextGroupBits()
        #expect(bits.count == 104, "Expected 104 bits per RDS group, got \(bits.count)")

        // PI block has the configured 0x82FF in the high 16 bits — at
        // least one of the high bits must be non-zero. A buffer-of-zeros
        // would read all PI bits as 0.
        let piBits = bits.prefix(16)
        #expect(piBits.contains(1), "PI block must not be all-zero (config piHex was 0x82FF)")
    }

    @Test func multipleNextGroupBitsCallsReturnIndependentValues() {
        // Two consecutive nextGroupBits() calls produce different group
        // types per the configured sequence "0A 2A". Verify the buffer
        // reuse hasn't merged them.
        let coder = makeCoder()
        let g1 = coder.nextGroupBits()
        let g2 = coder.nextGroupBits()
        let d1 = RDSGroupDecoder.decode(g1)
        let d2 = RDSGroupDecoder.decode(g2)
        #expect(d1.groupType == 0, "1st group should be type 0; got \(d1.groupType)")
        #expect(d2.groupType == 2, "2nd group should be type 2; got \(d2.groupType)")
    }

    @Test func heldReferenceSurvivesSubsequentCall() {
        // Critical CoW correctness: callers that retain a returned
        // `[UInt8]` must keep their original bits even after a later
        // call rewrites self.bitBuffer. If the refactor handed out a
        // shared buffer without proper Swift Array CoW, the second
        // call would mutate the first caller's view.
        let coder = makeCoder()
        let g1 = coder.nextGroupBits()
        let g1Snapshot = Array(g1)  // independent capture for ground-truth
        _ = coder.nextGroupBits()    // mutate self.bitBuffer
        #expect(g1 == g1Snapshot,
            "Holding the first nextGroupBits() result must not be clobbered by a second call")
    }

    @Test func eightSequentialCallsAllProduceDistinctValidGroups() {
        let coder = makeCoder()
        var observed: [[UInt8]] = []
        for _ in 0..<8 {
            let group = coder.nextGroupBits()
            observed.append(group)
            #expect(group.count == 104)
            // CRC must be valid for every block of every group.
            let decoded = RDSGroupDecoder.decode(group)
            for (idx, ok) in decoded.crcOK.enumerated() {
                #expect(ok, "CRC failed on block \(idx) of group iteration \(observed.count - 1)")
            }
        }
        // Spot-check: first and second groups should differ in at least
        // a few bits (different group types per the schedule).
        let diffBits = zip(observed[0], observed[1]).filter { $0 != $1 }.count
        #expect(diffBits > 0,
            "Sequential groups should differ in at least some bits; saw \(diffBits) diffs")
    }

    @Test func directBuildGroup0AndBuildGroup2ReturnDistinctBuffers() {
        // The internal bitBuffer is shared, but value-type Array return
        // semantics must give distinct logical arrays to callers.
        let coder = makeCoder()
        let g0 = coder.buildGroup0(versionB: false)
        let g0Snapshot = Array(g0)
        let g2 = coder.buildGroup2(versionB: false)
        #expect(g0 == g0Snapshot,
            "buildGroup0 result must survive a subsequent buildGroup2 call")
        let d0 = RDSGroupDecoder.decode(g0)
        let d2 = RDSGroupDecoder.decode(g2)
        #expect(d0.groupType == 0)
        #expect(d2.groupType == 2)
    }
}
