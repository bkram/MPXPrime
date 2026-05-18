import Testing
import Foundation
@testable import MPXPrime

// A/B compare slots are an in-memory workspace on MPXPrimeViewModel:
// the operator captures the current config into slot A, tweaks, captures
// into slot B, then swaps between them while listening. These tests pin
// the contract — capture stores a snapshot, swap restores it, swap when
// only one slot is captured is a no-op, clear empties both.

@Suite("A/B Compare")
@MainActor
struct ABCompareTests {

    private func makeViewModel() -> MPXPrimeViewModel {
        let tempPath = NSTemporaryDirectory()
            + "MPXPrime-ABCompareTests-\(UUID().uuidString).ini"
        return MPXPrimeViewModel(configPath: tempPath)
    }

    @Test func initialStateHasNoCapturedSlots() {
        let model = makeViewModel()
        #expect(model.compareSlotA == nil)
        #expect(model.compareSlotB == nil)
        #expect(model.compareActiveSlot == nil)
    }

    @Test func captureASnapshotsCurrentConfig() {
        let model = makeViewModel()
        model.config.pilotLevel = 0.085
        model.captureCurrentToCompareSlot("a")
        #expect(model.compareSlotA != nil)
        #expect(model.compareActiveSlot == "a")
        #expect(abs((model.compareSlotA?.pilotLevel ?? 0) - 0.085) < 1e-9)
    }

    @Test func captureBSnapshotsCurrentConfig() {
        let model = makeViewModel()
        model.config.compositeClipperThresholdDB = -0.7
        model.captureCurrentToCompareSlot("b")
        #expect(model.compareSlotB != nil)
        #expect(model.compareActiveSlot == "b")
        #expect(abs((model.compareSlotB?.compositeClipperThresholdDB ?? 0) - (-0.7)) < 1e-9)
    }

    @Test func swapWithOnlyOneSlotIsNoOp() {
        let model = makeViewModel()
        model.config.finalDriveDB = 5.0
        model.captureCurrentToCompareSlot("a")
        let beforeActive = model.compareActiveSlot
        let beforeDrive = model.config.finalDriveDB
        model.swapCompareSlot()  // no B → no-op
        #expect(model.compareActiveSlot == beforeActive)
        #expect(abs(model.config.finalDriveDB - beforeDrive) < 1e-9)
    }

    @Test func swapAfterBothCapturedAlternatesConfigs() {
        let model = makeViewModel()
        // Capture state A: pilot 8.0 %, drive 5 dB
        model.config.pilotLevel = 0.080
        model.config.finalDriveDB = 5.0
        model.captureCurrentToCompareSlot("a")

        // Tweak then capture state B: pilot 9.0 %, drive 7 dB
        model.config.pilotLevel = 0.090
        model.config.finalDriveDB = 7.0
        model.captureCurrentToCompareSlot("b")

        // After capturing B, active should be "b"
        #expect(model.compareActiveSlot == "b")
        #expect(abs(model.config.pilotLevel - 0.090) < 1e-9)
        #expect(abs(model.config.finalDriveDB - 7.0) < 1e-9)

        // Swap → loads A's snapshot.
        model.swapCompareSlot()
        #expect(model.compareActiveSlot == "a")
        #expect(abs(model.config.pilotLevel - 0.080) < 1e-9)
        #expect(abs(model.config.finalDriveDB - 5.0) < 1e-9)

        // Swap again → loads B.
        model.swapCompareSlot()
        #expect(model.compareActiveSlot == "b")
        #expect(abs(model.config.pilotLevel - 0.090) < 1e-9)
        #expect(abs(model.config.finalDriveDB - 7.0) < 1e-9)
    }

    @Test func clearRemovesBothSlots() {
        let model = makeViewModel()
        model.captureCurrentToCompareSlot("a")
        model.config.finalDriveDB = 7.5
        model.captureCurrentToCompareSlot("b")
        #expect(model.compareSlotA != nil)
        #expect(model.compareSlotB != nil)

        model.clearCompareSlots()
        #expect(model.compareSlotA == nil)
        #expect(model.compareSlotB == nil)
        #expect(model.compareActiveSlot == nil)
    }

    @Test func tweaksAfterCaptureAreEphemeralUntilNextCapture() {
        // Pro workflow contract: changes made AFTER capturing a slot
        // are lost when the operator swaps. Only an explicit
        // re-capture commits new state into the slot.
        let model = makeViewModel()
        model.config.pilotLevel = 0.080
        model.captureCurrentToCompareSlot("a")
        model.config.pilotLevel = 0.100  // ephemeral tweak
        model.captureCurrentToCompareSlot("b")
        // Tweak after capturing B — should be ephemeral.
        model.config.pilotLevel = 0.060
        model.swapCompareSlot()  // load A — should NOT carry the 0.060 tweak forward.
        #expect(model.compareActiveSlot == "a")
        #expect(abs(model.config.pilotLevel - 0.080) < 1e-9,
            "swap must restore captured A snapshot, not preserve ephemeral 0.060 tweak")
    }
}
