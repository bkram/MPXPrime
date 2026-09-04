// RFOverloadGateTests.swift
// The debounce behind the Meter's RF OVERLOAD badge: fires on a railed
// block, holds for the configured time past the last hot block, and never
// fires on the clean-capture ratios measured on the bench (0.0000 at a
// correct manual gain vs 0.10-0.40 railed under auto gain on a strong
// local, 2026-08-31).
//
// Results land in a variable before #expect: the macro cannot expand a
// mutating member call on the struct inline.

import Testing
@testable import MPXPrimeCore

@Suite("RFOverloadGate")
struct RFOverloadGateTests {

    @Test("clean capture never fires")
    func cleanCaptureStaysQuiet() {
        var gate = RFOverloadGate()
        for i in 0..<100 {
            let active = gate.update(ratio: 0.0, now: Double(i) * 0.03)
            #expect(!active)
        }
        // A single railed byte in an 8192-sample block (1/8192 = 0.012%) is
        // below the 0.1% threshold: transients do not flicker the badge.
        let transient = gate.update(ratio: 1.0 / 8192.0, now: 3.1)
        #expect(!transient)
    }

    @Test("railed block fires immediately and holds")
    func railedBlockFiresAndHolds() {
        var gate = RFOverloadGate(threshold: 0.001, holdSeconds: 2.0)
        let onHit = gate.update(ratio: 0.40, now: 10.0)
        #expect(onHit)
        // Clean blocks inside the hold window keep the warning up...
        let heldEarly = gate.update(ratio: 0.0, now: 11.0)
        let heldLate = gate.update(ratio: 0.0, now: 11.9)
        #expect(heldEarly)
        #expect(heldLate)
        // ...and it releases once the hold expires.
        let released = gate.update(ratio: 0.0, now: 12.1)
        #expect(!released)
    }

    @Test("sustained overload extends the hold")
    func sustainedOverloadExtends() {
        var gate = RFOverloadGate(threshold: 0.001, holdSeconds: 2.0)
        _ = gate.update(ratio: 0.10, now: 0.0)
        _ = gate.update(ratio: 0.10, now: 5.0)   // re-arms the hold
        let heldFromSecondHit = gate.update(ratio: 0.0, now: 6.9)
        #expect(heldFromSecondHit)
        let released = gate.update(ratio: 0.0, now: 7.1)
        #expect(!released)
    }

    @Test("reset drops the latch")
    func resetDropsLatch() {
        var gate = RFOverloadGate()
        let armed = gate.update(ratio: 0.5, now: 0.0)
        #expect(armed)
        gate.reset()
        let afterReset = gate.update(ratio: 0.0, now: 0.1)
        #expect(!afterReset)
    }

    @Test("threshold is exclusive: exactly-at-threshold stays quiet")
    func thresholdExclusive() {
        var gate = RFOverloadGate(threshold: 0.001, holdSeconds: 2.0)
        let atThreshold = gate.update(ratio: 0.001, now: 0.0)
        #expect(!atThreshold)
        let aboveThreshold = gate.update(ratio: 0.0011, now: 0.1)
        #expect(aboveThreshold)
    }
}
