// macOS-only: exercises the SwiftUI Sound pages, which the Linux build excludes.
#if os(macOS)

import Foundation
import Testing

@testable import MPXPrime

// The Sound pages after the UI layout review (2026-10): WP4, Q5, Q7, Q8, Q11
// and the dropped 2-band multiband.
@Suite("Layout: Sound pages")
@MainActor
struct LayoutSoundTests {

    @Test func multibandOffersOnlyTheBandCountsTheEngineRuns() {
        // The engine runs 3 or 5 bands; AppConfig folds anything else onto 3.
        // The GUI offered a 2-band choice that silently became 3.
        #expect(ProcessingMultibandTab.bandChoices == [3, 5])
        var c = AppConfig()
        c.multibandMode = 2
        let folded = try? AppConfig.loadFromINIString(c.iniText())
        #expect(folded?.multibandMode == 3)
    }

    @Test func linearThresholdsReadInDBFS() {
        let m = LayoutAudit.model()
        m.config.preEncodeThreshold = 0.95
        let s = m.dbSetting(\.preEncodeThreshold, .live)
        #expect(abs(s.binding.wrappedValue - (-0.4455)) < 0.001)
        s.binding.wrappedValue = -1.0
        #expect(abs(m.config.preEncodeThreshold - 0.891) < 0.001)
        // Stored range holds: the slider cannot push past the clamp.
        s.binding.wrappedValue = -20
        #expect(m.config.preEncodeThreshold == 0.5)
        m.shutdown()
    }

    @Test func amountsReadAsPercent() {
        let m = LayoutAudit.model()
        m.config.primeBassAmount = 0.35
        let s = m.percentSetting(\.primeBassAmount, .live)
        #expect(abs(s.binding.wrappedValue - 35) < 1e-9)
        s.binding.wrappedValue = 20
        #expect(abs(m.config.primeBassAmount - 0.2) < 1e-9)
        m.shutdown()
    }

    @Test func overviewSummariesUseFullWordsUnitsAndTheRealFilter() {
        var c = AppConfig()
        c.multibandFIREnabled = true
        #expect(ProcessingOverviewGrid.summary(for: .processingMultiband, config: c).contains("linear phase"))
        c.multibandFIREnabled = false
        let lowLatency = ProcessingOverviewGrid.summary(for: .processingMultiband, config: c)
        #expect(lowLatency.contains("low latency"))
        #expect(!lowLatency.contains("LR4"), "the summary said LR4 whatever the filter")
        c.preEncodeThreshold = 0.95
        #expect(ProcessingOverviewGrid.summary(for: .processingLimiter, config: c).contains("dBFS"))
        for stage in Stage.signalChain {
            let text = ProcessingOverviewGrid.summary(for: stage, config: AppConfig())
            for abbreviation in ["Thr ", "atk ", "rel ", "drv ", "Ceil ", "Amt ", "tanh", "residual", "|"] {
                #expect(!text.contains(abbreviation), "\(stage): '\(text)'")
            }
            #expect(text.unicodeScalars.allSatisfy { $0.isASCII }, "\(stage): '\(text)'")
        }
    }

    @Test func stereoCoderHasNoEnableDot() {
        // Its only switch is SSB; reading that flag showed stereo as off in
        // the default configuration.
        let m = LayoutAudit.model()
        m.config.ssbStereoEnabled = false
        #expect(m.isStageEnabled(.processingStereoCoder) == nil)
        m.shutdown()
    }

    @Test func noStaleOrJargonPromisesInPageText() {
        let stale = ["Community Radio", "Apply Restart", "Monitor mode", "pulse shaping",
                     "subcarrier frequency", "Output gain", "input/output gains", "MaxxBass-style",
                     "LR4", "delta-based", "NL prefix", "for NL", "for Dutch", "Most settings here are restart-required"]
        for stage in Stage.allCases {
            for text in [stage.detailSubtitle, stage.helpText] {
                for phrase in stale {
                    #expect(!text.contains(phrase), "\(stage): '\(phrase)'")
                }
            }
        }
        let m = LayoutAudit.model()
        #expect(m.runtimeApplyButtonTitle == "Restart to Apply")
        m.shutdown()
    }

    @Test func pageResetsTouchOnlyWhatThePageShows() {
        let m = LayoutAudit.model()
        // Basics no longer shows bypass or pre-emphasis; its reset must not
        // change them behind the operator's back.
        m.config.preemphasisUS = 75
        m.processingBypass = true
        m.config.processingBypass = true
        m.config.monoMode = true
        m.resetPage(.processingCore)
        #expect(m.config.preemphasisUS == 75)
        #expect(m.config.processingBypass)
        #expect(m.config.monoMode == AppConfig().monoMode)
        // Loudness and Output shows the safety limiter: its reset includes it,
        // and no longer the deviation (now on Audio I/O).
        m.config.limitMPX = !AppConfig().limitMPX
        m.config.mpxDeviationKHz = 60
        m.resetPage(.processingFinalStage)
        #expect(m.config.limitMPX == AppConfig().limitMPX)
        #expect(m.config.mpxDeviationKHz == 60)
        // Only the Subcarrier reset needs an engine restart.
        for tab in RDSTab.allCases {
            #expect(tab.resetNeedsRestart == (tab == .carrier), "\(tab)")
        }
        // Identity resets the Long PS that now lives on it.
        m.config.rdsLongPS32 = "CHANGED"
        m.resetPage(.rdsProgram)
        #expect(m.config.rdsLongPS32 == AppConfig().rdsLongPS32)
        m.shutdown()
    }
}

#endif  // os(macOS)
