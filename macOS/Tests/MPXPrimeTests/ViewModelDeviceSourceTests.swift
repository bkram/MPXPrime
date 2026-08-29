// macOS-only: exercises the SwiftUI view model, which the Linux CLI build excludes.
#if os(macOS)

import Foundation
import MPXPrimeCore
import Testing

@testable import MPXPrime

// Unit tests must never touch audio hardware: the view model takes its device
// source by injection, and every test that builds one passes a stub. This
// pins that the injected source is what `init` and `refreshDevices` use.
@Suite struct ViewModelDeviceSourceTests {
    @MainActor
    @Test func viewModelEnumeratesDevicesThroughTheInjectedSource() {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let path = NSTemporaryDirectory() + "MPXPrime-DeviceSource-\(UUID().uuidString).ini"
        let model = MPXPrimeViewModel(configPath: path) {
            counter.calls += 1
            return [AudioDevice(id: 1, uid: "stub-out", name: "Stub Output", inputChannels: 0, outputChannels: 2)]
        }
        #expect(counter.calls == 1)
        #expect(model.outputDevices.map(\.uid) == ["stub-out"])
        #expect(model.inputDevices.isEmpty)
        model.refreshDevices()
        #expect(counter.calls == 2)
    }
}

#endif  // os(macOS)
