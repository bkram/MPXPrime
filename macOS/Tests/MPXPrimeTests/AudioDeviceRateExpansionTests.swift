import Testing
import Foundation
import MPXPrimeCore

// CoreAudio reports supported rates as AudioValueRanges. Pre-0.45 only
// mMaximum was kept, so a device advertising a continuous (44100...384000)
// range looked like it supported only 384 kHz -- the Meter's exact-match test
// for the preferred 192 kHz then failed and capture opened at 384 kHz.
// `expandRateRanges` is the pure, headless-testable part of the fix.
@Suite struct AudioDeviceRateExpansionTests {

    @Test func discreteRatesPassThrough() {
        let rates = AudioDevices.expandRateRanges([(48_000, 48_000), (192_000, 192_000)])
        #expect(rates == [48_000, 192_000])
    }

    @Test func continuousRangeContainsTheStandardRates() {
        let rates = AudioDevices.expandRateRanges([(44_100, 384_000)])
        #expect(rates.contains(192_000), "the preferred capture rate must be discoverable inside a range")
        #expect(rates.contains(96_000))
        #expect(rates.contains(44_100) && rates.contains(384_000), "range endpoints are real rates")
        #expect(!rates.contains(8_000), "rates below the range must not appear")
    }

    @Test func mixedAndDuplicateRangesDeduplicate() {
        let rates = AudioDevices.expandRateRanges([(48_000, 48_000), (8_000, 192_000)])
        #expect(rates.filter { $0 == 48_000 }.count == 1)
        #expect(rates.first == 8_000)
        #expect(rates.last == 192_000)
        #expect(rates == rates.sorted())
    }
}
