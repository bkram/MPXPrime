import Testing
import MPXPrimeCore

// `ChannelPair` is pure Swift (no CoreAudio), so these run on macOS and Linux.
// It is the one model every multichannel path shares -- INI keys, the channel
// grid, the AUHAL channel map, the monitor player's buffer indices -- so the
// parsing rule and the fallback note are pinned here, not in each consumer.
@Suite("Channel pair")
struct ChannelPairTests {

    // MARK: Parsing (one-based text -> zero-based indices)

    @Test func parsesAStereoPair() {
        #expect(ChannelPair.parse("1,2") == ChannelPair(left: 0, right: 1))
        #expect(ChannelPair.parse("1,2") == .stereoDefault)
    }

    @Test func toleratesWhitespace() {
        #expect(ChannelPair.parse(" 3 , 4 ") == ChannelPair(left: 2, right: 3))
    }

    @Test func aSingleNumberIsMono() {
        let mono = ChannelPair.parse("3")
        #expect(mono == ChannelPair(left: 2, right: 2))
        #expect(mono?.isMono == true)
        #expect(mono?.indices == [2])
    }

    @Test func emptyAndNilParseToNil() {
        #expect(ChannelPair.parse("") == nil)
        #expect(ChannelPair.parse("   ") == nil)
        #expect(ChannelPair.parse(nil) == nil)
    }

    @Test func channelNumbersStartAtOne() {
        // Operators count from 1; a 0 is a typo, never "channel -1".
        #expect(ChannelPair.parse("0,1") == nil)
        #expect(ChannelPair.parse("0") == nil)
        #expect(ChannelPair.parse("-1,2") == nil)
    }

    @Test func rejectsNonNumericText() {
        #expect(ChannelPair.parse("a") == nil)
        #expect(ChannelPair.parse("1,b") == nil)
        #expect(ChannelPair.parse("1,") == nil)
        #expect(ChannelPair.parse(",2") == nil)
    }

    @Test func rejectsMoreThanTwoNumbers() {
        #expect(ChannelPair.parse("1,2,3") == nil)
    }

    @Test func theLowerNumberedChannelIsLeft() {
        // The UI's rule ("the lower-numbered channel is left") is applied at
        // parse time, so "2,1" is the same pair as "1,2".
        #expect(ChannelPair.parse("2,1") == ChannelPair(left: 0, right: 1))
        #expect(ChannelPair.parse("8,7") == ChannelPair(left: 6, right: 7))
    }

    @Test func aRepeatedNumberIsMono() {
        #expect(ChannelPair.parse("3,3") == ChannelPair(left: 2, right: 2))
    }

    @Test func theInitialiserKeepsTheOrderItIsGiven() {
        let swapped = ChannelPair(left: 1, right: 0)
        #expect(swapped.left == 1 && swapped.right == 0)
        #expect(swapped != .stereoDefault)
    }

    // MARK: INI round trip

    @Test func iniValueRoundTrips() {
        for text in ["1,2", "3,4", "3", "7,8", "16"] {
            let pair = ChannelPair.parse(text)
            #expect(pair?.iniValue == text, "\(text)")
            #expect(ChannelPair.parse(pair?.iniValue) == pair, "\(text)")
        }
        #expect(ChannelPair.parse(" 3 , 4 ")?.iniValue == "3,4", "whitespace is not preserved")
        #expect(ChannelPair.parse("2,1")?.iniValue == "1,2", "the normalised order is written back")
    }

    // MARK: Labels

    @Test func labelsAreOneBased() {
        #expect(ChannelPair(left: 2, right: 3).label == "Channels 3, 4")
        #expect(ChannelPair(left: 2, right: 2).label == "Channel 3")
        #expect(ChannelPair.stereoDefault.label == "Channels 1, 2")
        #expect(ChannelPair(left: 2, right: 3).numbers == "3, 4")
        #expect(ChannelPair(left: 2, right: 2).numbers == "3")
    }

    // MARK: Geometry

    @Test func fitsChecksTheHighestIndex() {
        #expect(ChannelPair.stereoDefault.fits(channelCount: 2))
        #expect(!ChannelPair.stereoDefault.fits(channelCount: 1))
        #expect(ChannelPair(left: 0, right: 0).fits(channelCount: 1))
        #expect(ChannelPair(left: 6, right: 7).fits(channelCount: 8))
        #expect(!ChannelPair(left: 6, right: 7).fits(channelCount: 7))
        #expect(!ChannelPair(left: -1, right: 0).fits(channelCount: 2))
        #expect(ChannelPair(left: 2, right: 3).maxIndex == 3)
    }

    @Test func overlapsSharesAChannel() {
        let tx = ChannelPair(left: 6, right: 7)
        let monitor = ChannelPair(left: 0, right: 1)
        #expect(!tx.overlaps(monitor))
        #expect(!monitor.overlaps(tx))
        #expect(tx.overlaps(ChannelPair(left: 7, right: 7)), "a mono pair on one of the channels")
        #expect(tx.overlaps(ChannelPair(left: 5, right: 6)))
        #expect(tx.overlaps(tx))
    }

    // MARK: Resolution against a real device

    @Test func nilRequestIsTheStereoDefaultOnStereoAndWiderDevices() {
        let on2 = ChannelPair.resolve(requested: nil, channelCount: 2, role: "Input")
        #expect(on2.pair == .stereoDefault && on2.note == nil)
        let on8 = ChannelPair.resolve(requested: nil, channelCount: 8, role: "Output")
        #expect(on8.pair == .stereoDefault && on8.note == nil)
    }

    @Test func nilRequestIsMonoOnASingleChannelDevice() {
        let on1 = ChannelPair.resolve(requested: nil, channelCount: 1, role: "Input")
        #expect(on1.pair == ChannelPair(left: 0, right: 0) && on1.note == nil)
    }

    @Test func aFittingRequestIsUsedWithoutANote() {
        let r = ChannelPair.resolve(requested: ChannelPair(left: 6, right: 7), channelCount: 8, role: "Output")
        #expect(r.pair == ChannelPair(left: 6, right: 7))
        #expect(r.note == nil)
    }

    @Test func aRequestThatDoesNotFitFallsBackWithTheExactNote() {
        let r = ChannelPair.resolve(requested: ChannelPair(left: 2, right: 3), channelCount: 2, role: "Input")
        #expect(r.pair == .stereoDefault)
        #expect(r.note == "Input channels 3, 4 are not on this device (it has 2); using 1, 2.")
    }

    @Test func aMonoRequestThatDoesNotFitFallsBackWithAMonoNote() {
        let r = ChannelPair.resolve(requested: ChannelPair(left: 4, right: 4), channelCount: 2, role: "Monitor")
        #expect(r.pair == .stereoDefault)
        #expect(r.note == "Monitor channel 5 is not on this device (it has 2); using 1, 2.")
    }

    @Test func aFittingMonoRequestIsUsed() {
        let r = ChannelPair.resolve(requested: ChannelPair(left: 4, right: 4), channelCount: 8, role: "Monitor")
        #expect(r.pair == ChannelPair(left: 4, right: 4))
        #expect(r.note == nil)
    }

    @Test func theFallbackOnASingleChannelDeviceIsChannelOne() {
        let r = ChannelPair.resolve(requested: .stereoDefault, channelCount: 1, role: "Input")
        #expect(r.pair == ChannelPair(left: 0, right: 0))
        #expect(r.note == "Input channels 1, 2 are not on this device (it has 1); using 1.")
    }
}
