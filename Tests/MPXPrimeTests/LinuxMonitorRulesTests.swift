import Testing
@testable import MPXPrime

/// The Linux monitor's start/stop rules, as a pure decision over ALSA device
/// names. Same intent as the macOS `MonitorOutputDecisionTests`: every rule
/// protects the AIR feed, so they are pinned on every platform.
@Suite("Linux monitor rules")
struct LinuxMonitorRulesTests {
    @Test func offWhenDisabledNeedsNoExplanation() {
        #expect(LinuxMonitorRules.decide(enabled: false, monitorDevice: "hw:CARD=Loopback,DEV=0", outputDevice: "hw:CARD=Device,DEV=0") == .off(note: nil))
    }

    @Test func emptySelectionIsOffNotDefault() {
        // "default" may BE the transmitter's PCM on a one-card box.
        for empty in ["", "   ", nil] as [String?] {
            let d = LinuxMonitorRules.decide(enabled: true, monitorDevice: empty, outputDevice: "hw:CARD=Device,DEV=0")
            if case .off(let note) = d { #expect(note?.contains("no monitor device") == true) } else { Issue.record("started on an empty selection") }
        }
    }

    @Test func refusesTheTransmittersOwnDevice() {
        let d = LinuxMonitorRules.decide(enabled: true, monitorDevice: "hw:CARD=Device,DEV=0", outputDevice: "hw:CARD=Device,DEV=0")
        if case .off(let note) = d { #expect(note?.contains("transmitter output") == true) } else { Issue.record("shared the TX device") }
        // Both on the ALSA default is the same device by another name.
        #expect(LinuxMonitorRules.decide(enabled: true, monitorDevice: "default", outputDevice: "default") != .run(device: "default"))
    }

    @Test func runsOnItsOwnDevice() {
        #expect(LinuxMonitorRules.decide(enabled: true, monitorDevice: "hw:CARD=Loopback,DEV=0", outputDevice: "hw:CARD=Device,DEV=0") == .run(device: "hw:CARD=Loopback,DEV=0"))
    }
}
