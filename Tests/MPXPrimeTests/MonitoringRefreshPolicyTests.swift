#if os(macOS)
import Foundation
import Testing

@testable import MPXPrime

// The GUI monitor timer's rate tiers and analysis gating
// (MonitoringRefreshPolicy). Before this the timer ran at full rate with the
// engine stopped, a monitoring window behind other windows counted as
// visible, and scopes / spectrum FFTs ran whenever the Monitoring page was
// selected -- a page that draws neither.
@Suite struct MonitoringRefreshPolicyTests {
    private typealias Policy = MonitoringRefreshPolicy

    @Test func stoppedEngineIsQuietWhateverIsVisible() {
        var v = MonitoringVisibility()
        v.windowsOnScreen = [.levels, .scopes]
        #expect(Policy.tier(engineRunning: false, visibility: v) == .quiet)
    }

    @Test func runningWithAVisibleMainWindowIsLiveOrBackground() {
        var v = MonitoringVisibility()
        #expect(Policy.tier(engineRunning: true, visibility: v) == .live)
        // Inactive but visible: still responsive, at the background rate.
        v.appActive = false
        #expect(Policy.tier(engineRunning: true, visibility: v) == .background)
    }

    @Test func nothingLiveOnScreenIsQuiet() {
        var v = MonitoringVisibility()
        v.mainWindowOccluded = true
        #expect(Policy.tier(engineRunning: true, visibility: v) == .quiet)
        v.mainWindowOccluded = false
        v.mainWindowMinimized = true
        #expect(Policy.tier(engineRunning: true, visibility: v) == .quiet)
    }

    @Test func aVisibleMonitoringWindowKeepsTheRateUp() {
        var v = MonitoringVisibility()
        v.mainWindowMinimized = true
        v.windowsOnScreen = [.levels]
        #expect(Policy.tier(engineRunning: true, visibility: v) == .live)
        v.appActive = false
        #expect(Policy.tier(engineRunning: true, visibility: v) == .background)
    }

    @MainActor @Test func ratesAreOrderedAndQuietIsAFewHertz() {
        let r = MPXPrimeViewModel.monitoringRefreshRates
        #expect(r.live > r.background)
        #expect(r.background > r.quiet)
        #expect(r.quiet >= 2 && r.quiet <= 5)
        #expect(r.hz(for: .quiet) == r.quiet)
    }

    @Test func scopesAndSpectraRunOnlyForTheWindowThatDrawsThem() {
        var v = MonitoringVisibility()
        // The Monitoring page on screen: stereo image only, no FFT, no scope.
        var n = Policy.needs(visibility: v, monitoringPageSelected: true,
                             remoteTelemetryActive: false, remoteMetersActive: false)
        #expect(!n.scopes && !n.mpxSpectrum && !n.audioSpectrum)
        #expect(n.stereoImage)
        #expect(!n.inputHistory && !n.outputHistory && !n.preMPXHistory)

        v.windowsOnScreen = [.mpxSpectrum]
        n = Policy.needs(visibility: v, monitoringPageSelected: false,
                         remoteTelemetryActive: false, remoteMetersActive: false)
        #expect(n.mpxSpectrum && !n.scopes && !n.audioSpectrum)
        #expect(n.outputHistory && !n.inputHistory)
        #expect(!n.stereoImage)

        v.windowsOnScreen = [.audioSpectrum]
        n = Policy.needs(visibility: v, monitoringPageSelected: false,
                         remoteTelemetryActive: false, remoteMetersActive: false)
        #expect(n.audioSpectrum && n.inputHistory && n.preMPXHistory && !n.outputHistory)

        v.windowsOnScreen = [.scopes]
        n = Policy.needs(visibility: v, monitoringPageSelected: false,
                         remoteTelemetryActive: false, remoteMetersActive: false)
        #expect(n.scopes && n.inputHistory && n.outputHistory)
    }

    @Test func hiddenMainWindowDropsTheStereoImageUnlessARemoteClientReadsIt() {
        var v = MonitoringVisibility()
        v.mainWindowOccluded = true
        var n = Policy.needs(visibility: v, monitoringPageSelected: true,
                             remoteTelemetryActive: false, remoteMetersActive: false)
        #expect(!n.stereoImage)
        n = Policy.needs(visibility: v, monitoringPageSelected: false,
                         remoteTelemetryActive: true, remoteMetersActive: true)
        #expect(n.stereoImage, "/api/meters carries the stereo correlation")
        #expect(n.inputHistory && n.outputHistory, "/api/telemetry reads both histories")
        #expect(!n.scopes && !n.mpxSpectrum, "the GUI does not draw for a remote client")
    }

    @MainActor @Test func viewModelStartsQuietWithNoEngineAndTracksWindows() {
        let vm = MPXPrimeViewModel(
            configPath: NSTemporaryDirectory() + "refresh-policy-\(UUID().uuidString).ini",
            deviceLister: { [] })
        #expect(vm.monitoringRefreshTier == .quiet)
        vm.setMonitoringWindowOnScreen(.scopes, true)
        #expect(vm.visibility.windowsOnScreen == [.scopes])
        vm.setMonitoringWindowOnScreen(.scopes, false)
        #expect(vm.visibility.windowsOnScreen.isEmpty)
        #expect(vm.monitoringRefreshTier == .quiet)
    }
}
#endif
