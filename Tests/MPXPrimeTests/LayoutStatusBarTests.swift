// macOS-only: exercises the SwiftUI status bar, which the Linux build excludes.
#if os(macOS)

import Foundation
import Testing

@testable import MPXPrime

// The status bar names the operating mode exactly as everywhere else, and
// the listening monitor is not a mode (UI layout review 2026-10, Q2 / 1.3).
// Before: MODE read COMPOSITE, MONITOR or PROC AUDIO -- never one of the four
// mode names -- and switching the monitor on turned "COMPOSITE" into
// "MONITOR" although the transmitter feed had not changed.
@Suite("Layout: status bar")
@MainActor
struct LayoutStatusBarTests {

    @Test func modeChipShowsTheOperatingModeTitle() {
        let expected: [AppConfig.OperatingMode: String] = [
            .mpx: "MPX Output", .fm: "FM Output", .hd: "HD Output", .am: "AM Output"
        ]
        for mode in AppConfig.OperatingMode.allCases {
            #expect(BroadcastStatusBar.modeText(mode) == expected[mode])
            #expect(BroadcastStatusBar.modeText(mode) == mode.title)
        }
    }

    @Test func sourceChipSaysTestToneWhileTheToneReplacesTheInput() {
        #expect(BroadcastStatusBar.sourceText(inputName: "BlackHole 2ch", isRunning: true, sourceMode: "input")
                == "BlackHole 2ch")
        #expect(BroadcastStatusBar.sourceText(inputName: "BlackHole 2ch", isRunning: true, sourceMode: "tone")
                == "Test Tone")
        #expect(BroadcastStatusBar.sourceText(inputName: "BlackHole 2ch", isRunning: false, sourceMode: "tone")
                == "-")
    }

    @Test func windowMenuFollowsTheToolbarOnConsecutiveShortcuts() {
        // Was Audio Spectrum, MPX Spectrum, Levels, Scopes on 7, 8, 9 and
        // Shift-0 while the toolbar read Scopes, Spectrum, Levels.
        #expect(AppDelegate.monitoringWindowMenu.map { $0.title }
                == [kLevelsWindowTitle, kAudioSpectrumWindowTitle, kMPXSpectrumWindowTitle, kScopesWindowTitle])
        #expect(AppDelegate.monitoringWindowMenu.map { $0.key } == ["6", "7", "8", "9"])
        // A page, not a dialog: no ellipsis.
        #expect(AppDelegate.testToneMenuTitle == "Test Tone")
    }

    @Test func restartSignalIsOneActionNamedRestartToApply() {
        let model = MPXPrimeViewModel(
            configPath: NSTemporaryDirectory() + "MPXPrime-LayoutStatus-\(UUID().uuidString).ini",
            deviceLister: { [] })
        #expect(model.runtimeApplyButtonTitle == "Restart to Apply")
        model.shutdown()
    }
}

#endif  // os(macOS)
