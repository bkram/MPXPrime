// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Foundation

/// What is on screen right now, as the GUI's monitoring refresh sees it.
/// Fed by the AppDelegate's occlusion / miniaturise / activation
/// notifications; pure, so the refresh decisions below are unit-tested
/// without a window.
struct MonitoringVisibility: Equatable {
    var appActive = true
    var mainWindowOccluded = false
    var mainWindowMinimized = false
    /// Detached monitoring windows that are open AND at least partly
    /// visible (not closed, not miniaturised, not fully covered).
    var windowsOnScreen: Set<MonitoringWindowKind> = []

    var mainWindowOnScreen: Bool { !mainWindowOccluded && !mainWindowMinimized }

    /// Anything that draws live values: the main window (meters, status
    /// chips, readouts on every page) or a detached monitoring window.
    var liveViewOnScreen: Bool { mainWindowOnScreen || !windowsOnScreen.isEmpty }
}

/// The GUI monitor timer's rate, and which analyses it computes.
///
/// Three tiers. LIVE (30 Hz arm64, 20 Hz Intel): the app is frontmost and
/// something that shows live values is visible. BACKGROUND (20 / 12 Hz):
/// the app is not frontmost but such a view is still visible, so the meters
/// stay responsive to a glance from another app. QUIET (4 Hz): the engine is
/// stopped or nothing live is visible -- enough for the transport state and
/// the status chips, and it keeps the ballistics warm for the next view.
/// Before this the timer ran at the background rate whenever the main window
/// was hidden and at full rate while the engine was stopped.
enum MonitoringRefreshPolicy {
    enum Tier: Equatable {
        case live, background, quiet
    }

    struct Rates: Equatable {
        var live: Double
        var background: Double
        var quiet: Double

        func hz(for tier: Tier) -> Double {
            switch tier {
            case .live: return live
            case .background: return background
            case .quiet: return quiet
            }
        }
    }

    static func tier(engineRunning: Bool, visibility: MonitoringVisibility) -> Tier {
        guard engineRunning, visibility.liveViewOnScreen else { return .quiet }
        return visibility.appActive ? .live : .background
    }

    /// The analyses worth computing this tick: only what a visible view
    /// draws, plus what a remote client asked for recently.
    struct Needs: Equatable {
        /// Scopes window traces.
        var scopes = false
        /// MPX Spectrum window FFT.
        var mpxSpectrum = false
        /// Audio Spectrum window FFTs.
        var audioSpectrum = false
        /// Stereo correlation / side ratio (Monitoring page, /api/meters).
        var stereoImage = false
        /// Engine history taps feeding the above (and /api/telemetry).
        var inputHistory = false
        var outputHistory = false
        var preMPXHistory = false
    }

    static func needs(
        visibility: MonitoringVisibility,
        monitoringPageSelected: Bool,
        remoteTelemetryActive: Bool,
        remoteMetersActive: Bool
    ) -> Needs {
        var n = Needs()
        n.scopes = visibility.windowsOnScreen.contains(.scopes)
        n.mpxSpectrum = visibility.windowsOnScreen.contains(.mpxSpectrum)
        n.audioSpectrum = visibility.windowsOnScreen.contains(.audioSpectrum)
        n.stereoImage = (visibility.mainWindowOnScreen && monitoringPageSelected) || remoteMetersActive
        // The Audio Spectrum's Pre source reads the input history, its Post
        // source the pre-MPX history; /api/telemetry reads input + output.
        n.inputHistory = n.scopes || n.audioSpectrum || remoteTelemetryActive
        n.outputHistory = n.scopes || n.mpxSpectrum || remoteTelemetryActive
        n.preMPXHistory = n.audioSpectrum
        return n
    }
}

#endif  // os(macOS)
