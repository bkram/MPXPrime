import Testing
@testable import MPXPrime

/// The render-overload note's hysteresis. The rig sat at 94-96 % for hours
/// with zero xruns, then ran 43 a second at 102 % -- the note must fire on
/// the second and stay quiet on the first.
@Suite("Render load watch")
struct RenderLoadWatchTests {
    /// Feed a sequence, return what the watch says after each reading.
    private func run(_ loads: [Float?]) -> [Bool] {
        var w = RenderLoadWatch()
        return loads.map { w.observe($0) }
    }

    @Test func twoTicksOverRaiseOneSpikeDoesNot() {
        #expect(run([101, 103]) == [false, true], "two consecutive readings over the line must raise the note")
        #expect(run([120, 94]) == [false, false], "one spike followed by a normal reading is not an overload")
    }

    @Test func holdsInTheBandAndClearsBelowIt() {
        // 95 % keeps a raised note (the load hovers, it has not recovered);
        // under 90 % it clears; hovering at 95 % afterwards does not re-raise.
        #expect(run([99, 99, 95, 80, 95]) == [false, true, true, false, false])
    }

    @Test func noReadingMeansNoNote() {
        // Engine stopped, or a platform without the measurement.
        #expect(run([100, 100, nil]) == [false, true, false])
    }
}
