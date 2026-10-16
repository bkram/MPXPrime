// macOS-only: exercises SwiftUI views, which the Linux build excludes.
#if os(macOS)

import Foundation
import Testing

@testable import MPXPrime

// The Monitoring page and the monitoring windows (UI layout review 2026-10,
// WP2, Q1, Q15).
@Suite("Layout: monitoring")
@MainActor
struct LayoutMonitoringTests {

    @Test func subcarriersReadInKilohertzWithThePercentSecond() {
        // Before: "9.0%" and "2.7%" only; the guide and the RDS page speak kHz.
        #expect(MonitoringDashboardView.subcarrierText(percent: 9.0, deviationKHz: 75.0) == "6.8 kHz (9.0%)")
        #expect(MonitoringDashboardView.subcarrierText(percent: 2.6667, deviationKHz: 75.0) == "2.0 kHz (2.7%)")
        // The generator scales the whole composite to the chosen deviation.
        #expect(MonitoringDashboardView.subcarrierText(percent: 9.0, deviationKHz: 50.0) == "4.5 kHz (9.0%)")
        #expect(MonitoringDashboardView.subcarrierText(percent: -1.0, deviationKHz: 75.0) == "0.0 kHz (0.0%)")
    }

    @Test func theCompositeBudgetRowIsNotCalledBS412() {
        // The row reads the composite peak margin (-20 log10(audio peak +
        // pilot/RDS reservation)), not BS.412 multiplex power: it was
        // labelled "BS.412 BUDGET".
        #expect(MonitoringDashboardView.headroomLabel(.compositeBudget) == "Composite Budget")
        #expect(MonitoringDashboardView.headroomLabel(.mpxPower) == "Multiplex Power")
        // GR rows carry the stage's one name.
        #expect(MonitoringDashboardView.headroomLabel(.preEncodeGR) == "Audio Limiter GR")
        #expect(MonitoringDashboardView.headroomLabel(.compositeGR) == "Composite Clipper GR")
        for readout in HeadroomReadout.allCases where readout != .bs412GR {  // "BS.412 GR" is all acronym
            let label = MonitoringDashboardView.headroomLabel(readout)
            #expect(label.unicodeScalars.allSatisfy { $0.isASCII })
            #expect(label != label.uppercased(), "\(label): Title Case source, drawn as small caps")
        }
        #expect(MonitoringDashboardView.budgetText(marginDB: 2.0, state: "Tight") == " +2.0 dB - Tight")
        #expect(MonitoringDashboardView.budgetText(marginDB: 2.0, state: "Off") == " +2.0 dB")
    }

    @Test func audioSpectrumFooterFollowsPreAndPost() {
        // Before: always "Tap: raw stereo input before processing".
        let pre = StereoPreMPXSpectrumView.tapText(showsProcessed: false)
        let post = StereoPreMPXSpectrumView.tapText(showsProcessed: true)
        #expect(pre != post)
        #expect(pre.contains("before processing"))
        #expect(post.contains("processed"))
    }

    @Test func scopesCaptionIsASCII() {
        #expect(ScopesOnlyView.scaleCaption(autoGain: false) == "Fixed vertical scale: +/-1.0.")
        #expect(ScopesOnlyView.scaleCaption(autoGain: true) == "Auto gain on.")
    }

    @Test func streamRateReadsInKilohertz() {
        #expect(MonitoringDashboardView.rateText(inputHz: 48_000, renderHz: 192_000, blockFrames: 512)
                == "48 -> 192 kHz, block 512")
        #expect(MonitoringDashboardView.rateText(inputHz: 44_100, renderHz: 192_000, blockFrames: 256)
                == "44.1 -> 192 kHz, block 256")
        #expect(MonitoringDashboardView.rateText(inputHz: 192_000, renderHz: 192_000, blockFrames: 512)
                == "192 kHz, block 512")
        #expect(MonitoringDashboardView.rateText(inputHz: 0, renderHz: 0, blockFrames: 0) == "-")
    }

    @Test func detailStringsParseWithEitherSeparator() {
        // The view model writes bullet-separated details today; ASCII
        // sources write " | ". Both parse, and the display is plain commas.
        #expect(MonitoringDashboardView.parseDetail("Detector -12.0 dB \u{2022} Gain 3.0 dB", key: "Gain") == "3.0 dB")
        #expect(MonitoringDashboardView.parseDetail("Detector -12.0 dB | Gain 3.0 dB", key: "Detector") == "-12.0 dB")
        #expect(MonitoringDashboardView.plainDetail("Corr +1.00 \u{2022} Side 0.00x") == "Corr +1.00, Side 0.00x")
    }

    @Test func monitoringWindowsComeFromOneTable() {
        let titles = MonitoringWindowKind.allCases.map(\.title)
        #expect(titles == ["Levels", "Audio Spectrum", "MPX Spectrum", "Scopes"])
        #expect(kLevelsWindowTitle == MonitoringWindowKind.levels.title)
        #expect(kScopesWindowTitle == MonitoringWindowKind.scopes.title)
        for kind in MonitoringWindowKind.allCases {
            #expect(kind.minSize.width <= kind.size.width && kind.minSize.height <= kind.size.height,
                    "\(kind.title): default size below its minimum")
        }
        #expect(kWindowMinWidth == MonitoringWindowKind.scopes.minSize.width)
        #expect(kAudioSpectrumWindowMinHeight == MonitoringWindowKind.audioSpectrum.minSize.height)
    }

    @Test func monitoringPageHasNoSettings() {
        // Read-only: no transport buttons, no stage switches. Building the
        // page records no setting in any operating mode.
        for mode in AppConfig.OperatingMode.allCases {
            let m = LayoutAudit.model(mode)
            let result = LayoutAudit.mismatches {
                _ = MonitoringDashboardView(model: m).body
                _ = LevelsCardView(model: m).body
            }
            #expect(result.checked == 0 && result.problems.isEmpty)
            m.shutdown()
        }
    }
}

#endif  // os(macOS)
