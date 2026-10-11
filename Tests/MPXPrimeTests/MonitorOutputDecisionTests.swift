#if os(macOS)
import Testing
import CoreAudio
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

    @Test func offWhenTheOperatorHasNotEnabledIt() {
        let d = MonitorOutput.decide(enabled: false, monitorUID: "headphones", txDeviceID: tx, resolve: present)
        #expect(d == .off(note: nil), "a disabled monitor needs no explanation")
    }

    @Test func neverFallsBackToTheSystemDefault() {
        // The system default output may BE the transmitter, so "no monitor
        // device chosen" must mean silence, not "some device".
        let d = MonitorOutput.decide(enabled: true, monitorUID: "", txDeviceID: tx, resolve: present)
        #expect(!d.isRunning)
        if case .off(let note) = d { #expect(note?.contains("no monitor device") == true, "note: \(note ?? "nil")") }
    }

    @Test func refusesToShareTheTransmitterDevice() {
        // Decoded audio summed into the composite feed is on-air contamination.
        let d = MonitorOutput.decide(enabled: true, monitorUID: "tx", txDeviceID: tx, resolve: present)
        #expect(!d.isRunning)
        if case .off(let note) = d { #expect(note?.contains("transmitter output") == true, "note: \(note ?? "nil")") }
    }

    @Test func staysOffWhenTheDeviceIsUnplugged() {
        let d = MonitorOutput.decide(enabled: true, monitorUID: "vanished", txDeviceID: tx, resolve: present)
        #expect(!d.isRunning)
        if case .off(let note) = d { #expect(note?.contains("not connected") == true, "note: \(note ?? "nil")") }
    }

    @Test func runsOnItsOwnDeviceAlongsideTheTransmitter() {
        let d = MonitorOutput.decide(enabled: true, monitorUID: "headphones", txDeviceID: tx, resolve: present)
        #expect(d == .run(deviceID: headphones))
    }

    @Test func runsWithNoTransmitterDeviceAtAll() {
        // Auditioning: there is no transmitter output to clash with.
        let d = MonitorOutput.decide(enabled: true, monitorUID: "headphones", txDeviceID: nil, resolve: present)
        #expect(d == .run(deviceID: headphones))
    }
}
#endif
