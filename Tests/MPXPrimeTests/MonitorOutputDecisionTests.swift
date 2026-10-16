#if os(macOS)
import Testing
import CoreAudio
import MPXPrimeCore
@testable import MPXPrime

/// The monitor's start/stop rules, as a pure decision so they can be tested
/// without touching CoreAudio.
///
/// Every rule here exists to protect the AIR feed: the monitor is a listening
/// aid, and none of its failure modes may reach the transmitter.
@Suite("Monitor output decisions")
struct MonitorOutputDecisionTests {

    private let tx: AudioDeviceID = 10
    private let headphones: AudioDeviceID = 20
    private func present(_ uid: String) -> AudioDeviceID? {
        uid == "headphones" ? headphones : (uid == "tx" ? tx : nil)
    }

    /// The decision with the pairs defaulted: what every pre-multichannel
    /// caller asked.
    private func decide(enabled: Bool, monitorUID: String?, txDeviceID: AudioDeviceID?)
        -> MonitorOutput.Decision {
        MonitorOutput.decide(
            enabled: enabled, monitorUID: monitorUID, monitorChannels: nil,
            txDeviceID: txDeviceID, txChannels: nil, resolve: present)
    }

    @Test func offWhenTheOperatorHasNotEnabledIt() {
        let d = decide(enabled: false, monitorUID: "headphones", txDeviceID: tx)
        #expect(d == .off(note: nil), "a disabled monitor needs no explanation")
    }

    @Test func neverFallsBackToTheSystemDefault() {
        // The system default output may BE the transmitter, so "no monitor
        // device chosen" must mean silence, not "some device".
        let d = decide(enabled: true, monitorUID: "", txDeviceID: tx)
        #expect(!d.isRunning)
        if case .off(let note) = d { #expect(note?.contains("no monitor device") == true, "note: \(note ?? "nil")") }
    }

    @Test func refusesToShareTheTransmitterDeviceOnTheSameChannels() {
        // Decoded audio summed into the composite feed is on-air contamination:
        // both sides on the device's first pair is the classic mistake.
        let d = decide(enabled: true, monitorUID: "tx", txDeviceID: tx)
        #expect(!d.isRunning)
        #expect(d == .off(note: MonitorOutput.sharedChannelsNote))
    }

    @Test func refusesOverlappingPairsOnTheTransmitterDevice() {
        // Feed on 3, 4 and monitor on 4, 5: channel 4 would carry both.
        let d = MonitorOutput.decide(
            enabled: true, monitorUID: "tx", monitorChannels: ChannelPair(left: 3, right: 4),
            txDeviceID: tx, txChannels: ChannelPair(left: 2, right: 3), resolve: present)
        #expect(d == .off(note: MonitorOutput.sharedChannelsNote))
        // A mono monitor on one of the feed's channels is just as bad.
        let mono = MonitorOutput.decide(
            enabled: true, monitorUID: "tx", monitorChannels: ChannelPair(left: 3, right: 3),
            txDeviceID: tx, txChannels: ChannelPair(left: 2, right: 3), resolve: present)
        #expect(mono == .off(note: MonitorOutput.sharedChannelsNote))
    }

    @Test func anExplicitFirstPairStillClashesWithTheDefaultedOther() {
        // nil means channels 1, 2 on either side: the monitor on an explicit
        // 1, 2 against a transmitter that never chose is the same channels.
        let d = MonitorOutput.decide(
            enabled: true, monitorUID: "tx", monitorChannels: .stereoDefault,
            txDeviceID: tx, txChannels: nil, resolve: present)
        #expect(d == .off(note: MonitorOutput.sharedChannelsNote))
    }

    @Test func sharesTheTransmitterDeviceOnDisjointChannels() {
        // An 8-out box: feed on 7, 8 and the operator's headphones on 1, 2.
        let d = MonitorOutput.decide(
            enabled: true, monitorUID: "tx", monitorChannels: ChannelPair(left: 0, right: 1),
            txDeviceID: tx, txChannels: ChannelPair(left: 6, right: 7), resolve: present)
        #expect(d == .run(deviceID: tx, channels: ChannelPair(left: 0, right: 1)))
        // And the other way round, with the monitor on the default pair.
        let swapped = MonitorOutput.decide(
            enabled: true, monitorUID: "tx", monitorChannels: nil,
            txDeviceID: tx, txChannels: ChannelPair(left: 6, right: 7), resolve: present)
        #expect(swapped == .run(deviceID: tx, channels: nil))
    }

    @Test func staysOffWhenTheDeviceIsUnplugged() {
        let d = decide(enabled: true, monitorUID: "vanished", txDeviceID: tx)
        #expect(!d.isRunning)
        if case .off(let note) = d { #expect(note?.contains("not connected") == true, "note: \(note ?? "nil")") }
    }

    @Test func runsOnItsOwnDeviceAlongsideTheTransmitter() {
        let d = decide(enabled: true, monitorUID: "headphones", txDeviceID: tx)
        #expect(d == .run(deviceID: headphones, channels: nil))
    }

    @Test func differentDevicesNeverCompareChannels() {
        // The same pair on two devices is two different pairs of wires.
        let d = MonitorOutput.decide(
            enabled: true, monitorUID: "headphones", monitorChannels: ChannelPair(left: 0, right: 1),
            txDeviceID: tx, txChannels: ChannelPair(left: 0, right: 1), resolve: present)
        #expect(d == .run(deviceID: headphones, channels: ChannelPair(left: 0, right: 1)))
    }

    @Test func carriesTheRequestedChannelsIntoTheRun() {
        // The run decision hands the player the operator's pair unchanged
        // (the player resolves it against the device; the decision cannot).
        let d = MonitorOutput.decide(
            enabled: true, monitorUID: "headphones", monitorChannels: ChannelPair(left: 2, right: 2),
            txDeviceID: tx, txChannels: nil, resolve: present)
        #expect(d == .run(deviceID: headphones, channels: ChannelPair(left: 2, right: 2)))
    }

    @Test func runsWithNoTransmitterDeviceAtAll() {
        // Auditioning: there is no transmitter output to clash with.
        let d = decide(enabled: true, monitorUID: "headphones", txDeviceID: nil)
        #expect(d == .run(deviceID: headphones, channels: nil))
    }
}
#endif
