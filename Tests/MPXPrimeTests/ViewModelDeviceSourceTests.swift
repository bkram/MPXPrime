// macOS-only: exercises the SwiftUI view model, which the Linux CLI build excludes.
#if os(macOS)

import Foundation
import MPXPrimeCore
import Testing

@testable import MPXPrime

// Unit tests must never touch audio hardware: the view model takes its device
// source AND its hot-plug observer by injection, and every test that builds
// one passes a stub lister and no observer. This pins that the injected
// source is what `init`, `refreshDevices` and `rescanDevices` use, that no
// observer is started unless one is injected, and that the channel-pair
// selections round-trip through the config like the device UIDs do.
@Suite struct ViewModelDeviceSourceTests {
    private final class Counter: @unchecked Sendable { var calls = 0 }

    /// A stand-in for `AudioDeviceObservation`: records the handler so a test
    /// can fire a hot-plug event, and whether it was cancelled.
    private final class StubObservation: DeviceObservationHandle, @unchecked Sendable {
        let handler: @Sendable () -> Void
        var cancelled = false
        init(handler: @escaping @Sendable () -> Void) { self.handler = handler }
        func cancel() { cancelled = true }
    }

    private func tempConfigPath() -> String {
        NSTemporaryDirectory() + "MPXPrime-DeviceSource-\(UUID().uuidString).ini"
    }

    private func stubOutput(_ uid: String = "stub-out", channels: Int = 2) -> AudioDevice {
        AudioDevice(id: 1, uid: uid, name: "Stub Output", inputChannels: 0, outputChannels: channels)
    }

    @MainActor
    @Test func viewModelEnumeratesDevicesThroughTheInjectedSource() {
        let counter = Counter()
        let model = MPXPrimeViewModel(configPath: tempConfigPath()) {
            counter.calls += 1
            return [self.stubOutput()]
        }
        #expect(counter.calls == 1)
        #expect(model.outputDevices.map(\.uid) == ["stub-out"])
        #expect(model.allDevices.map(\.uid) == ["stub-out"])
        #expect(model.inputDevices.isEmpty)
        model.refreshDevices()
        #expect(counter.calls == 2)
    }

    @MainActor
    @Test func viewModelNeverObservesWithoutAnInjectedFactory() {
        let model = MPXPrimeViewModel(configPath: tempConfigPath(), deviceLister: { [] })
        #expect(!model.isObservingDevices)
        model.shutdown()
        #expect(!model.isObservingDevices)
    }

    @MainActor
    @Test func hotPlugEventsReListThroughTheInjectedSourceUntilShutdown() async {
        let counter = Counter()
        final class Box: @unchecked Sendable { var observation: StubObservation? }
        let box = Box()
        let model = MPXPrimeViewModel(
            configPath: tempConfigPath(),
            deviceLister: {
                counter.calls += 1
                return counter.calls == 1 ? [] : [self.stubOutput()]
            },
            deviceObserver: { handler in
                let observation = StubObservation(handler: handler)
                box.observation = observation
                return observation
            })
        #expect(model.isObservingDevices)
        #expect(counter.calls == 1)
        #expect(model.allDevices.isEmpty)

        // A device appears: the handler runs the refresh on the main actor.
        box.observation?.handler()
        // The refresh is a main-actor Task. In the full parallel run other
        // main-actor suites hold that actor for over a minute, so bound the
        // wait by turns, not wall time: each sleep hands the actor back and
        // the queued refresh runs as soon as it is free.
        for _ in 0..<6000 where counter.calls < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // At least one re-list: the config watcher may also re-list when it
        // sees the temp INI saved, so an exact count is not the contract.
        #expect(counter.calls >= 2)
        #expect(model.allDevices.map(\.uid) == ["stub-out"])

        model.shutdown()
        #expect(box.observation?.cancelled == true)
        #expect(!model.isObservingDevices)
    }

    @MainActor
    @Test func rescanUpdatesTheScanTimeAndReListsThroughTheInjectedSource() {
        let counter = Counter()
        let model = MPXPrimeViewModel(configPath: tempConfigPath()) {
            counter.calls += 1
            return counter.calls == 1 ? [self.stubOutput()] : [self.stubOutput(), self.stubOutput("stub-8", channels: 8)]
        }
        // Start from a known-old time: `>= before` also passed when the scan
        // time was never updated (finding 15).
        model.lastDeviceScan = .distantPast
        model.rescanDevices()
        #expect(counter.calls == 2)
        #expect(model.lastDeviceScan > .distantPast, "rescanDevices did not update the scan time")
        #expect(model.allDevices.map(\.uid) == ["stub-out", "stub-8"])
        #expect(model.outputDevices.count == 2)
    }

    @MainActor
    @Test func channelPairsRoundTripThroughPersistBasicConfig() {
        let model = MPXPrimeViewModel(configPath: tempConfigPath(), deviceLister: { [] })
        model.selectedInputChannels = ChannelPair(left: 2, right: 3)
        model.selectedOutputChannels = .stereoDefault
        model.selectedMonitorChannels = ChannelPair(left: 4, right: 4)
        model.persistBasicConfig()
        #expect(model.config.inputChannels == ChannelPair(left: 2, right: 3))
        // Channels 1, 2 is the default and stays an empty INI key.
        #expect(model.config.outputChannels == nil)
        #expect(model.config.monitorChannels == ChannelPair(left: 4, right: 4))

        // The monitor pair goes through the live-apply path as well.
        model.selectedMonitorChannels = .stereoDefault
        model.persistMonitorSettings()
        #expect(model.config.monitorChannels == nil)
        model.selectedMonitorChannels = ChannelPair(left: 6, right: 7)
        model.persistMonitorSettings()
        #expect(model.config.monitorChannels == ChannelPair(left: 6, right: 7))
    }

    @MainActor
    @Test func channelPairsSurviveResetToDefaultsLikeTheDeviceUIDs() {
        let model = MPXPrimeViewModel(configPath: tempConfigPath(), deviceLister: { [] })
        model.selectedInputChannels = ChannelPair(left: 2, right: 3)
        model.selectedOutputChannels = ChannelPair(left: 6, right: 7)
        model.persistBasicConfig()
        model.resetToDefaults()
        #expect(model.config.inputChannels == ChannelPair(left: 2, right: 3))
        #expect(model.config.outputChannels == ChannelPair(left: 6, right: 7))
        #expect(model.selectedInputChannels == ChannelPair(left: 2, right: 3))
        #expect(model.selectedOutputChannels == ChannelPair(left: 6, right: 7))
    }

    @MainActor
    @Test func configuredChannelPairsLoadIntoTheSelections() throws {
        let path = tempConfigPath()
        var cfg = AppConfig()
        cfg.inputChannels = ChannelPair.parse("3,4")
        cfg.outputChannels = ChannelPair.parse("7,8")
        cfg.monitorChannels = ChannelPair.parse("5")
        try cfg.save(toINI: path)
        let model = MPXPrimeViewModel(configPath: path, deviceLister: { [] })
        #expect(model.selectedInputChannels == ChannelPair(left: 2, right: 3))
        #expect(model.selectedOutputChannels == ChannelPair(left: 6, right: 7))
        #expect(model.selectedMonitorChannels == ChannelPair(left: 4, right: 4))
        // The pairs reach the control API in INI form.
        let remote = model.remoteDevices()
        #expect(remote.selectedInputChannels == "3,4")
        #expect(remote.selectedOutputChannels == "7,8")
        #expect(remote.selectedMonitorChannels == "5")
    }
}

#endif  // os(macOS)
