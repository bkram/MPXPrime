import Testing

@testable import MPXPrime

// The Headroom card's rows come from one table so the GUI cannot drop a row
// in a mode the web dashboard shows it in. 0.60 first added the Bad Input
// counter to the card's composite branch only; the ingress guard counts in
// every mode and the dashboard showed it in every mode.
@Suite("Headroom readouts per mode")
struct HeadroomReadoutTests {

    @Test(arguments: AppConfig.OperatingMode.allCases)
    func badInputAndThePreEncodeLimiterShowInEveryMode(mode: AppConfig.OperatingMode) {
        let visible = HeadroomReadout.visible(in: mode)
        #expect(visible.contains(.badInput), "Bad Input is missing in \(mode.rawValue)")
        #expect(visible.contains(.preEncodeGR))
    }

    @Test(arguments: AppConfig.OperatingMode.allCases)
    func compositeRowsExistOnlyWhereAComposite(mode: AppConfig.OperatingMode) {
        let visible = HeadroomReadout.visible(in: mode)
        let composite: [HeadroomReadout] = [.compositeGR, .safetyGR, .safetyClip, .bs412Budget, .mpxPower, .bs412GR]
        for row in composite {
            #expect(visible.contains(row) == (mode == .mpx),
                    "\(row.rawValue) visible=\(visible.contains(row)) in \(mode.rawValue)")
        }
    }

    @Test func displayOrderIsTheTableOrder() {
        // Signal order, Bad Input last, in every mode -- the card reads the
        // same way whatever is hidden.
        let mpx = HeadroomReadout.visible(in: .mpx)
        #expect(mpx == HeadroomReadout.allCases)
        #expect(HeadroomReadout.visible(in: .fm) == [.preEncodeGR, .badInput])
    }
}
