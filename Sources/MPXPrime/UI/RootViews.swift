// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // NavigationSplitView gives the standard macOS collapsible sidebar
        // (toggle auto-provided in the toolbar, plus View > Toggle Sidebar /
        // Cmd-Ctrl-S). Minimum 220 pt fits the longest label ("Composite
        // Clipper") with icon + padding without truncation.
        NavigationSplitView {
            StageSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            StageContentView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .alert("Cannot Start",
                       isPresented: Binding(
                           get: { model.startBlockedMessage != nil },
                           set: { if !$0 { model.startBlockedMessage = nil } })) {
                    Button("OK", role: .cancel) { model.startBlockedMessage = nil }
                } message: {
                    Text(model.startBlockedMessage ?? "")
                }
                // Always-visible broadcast status header (transport / peaks /
                // deviation / GR / budget / injections). On the detail column
                // so the sidebar runs full height under the title bar, the
                // standard macOS sidebar layout. It still spans every stage
                // because the detail hosts them all.
                .safeAreaInset(edge: .top, spacing: 0) {
                    BroadcastStatusBar(model: model)
                }
        }
        .toolbar {
            // Frequently used commands belong in the toolbar (HIG). The
            // sidebar-collapse toggle is added automatically by
            // NavigationSplitView at the leading edge. Open and Save are
            // rare and live in the File menu only.
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.startOrStopTransport()
                } label: {
                    Label(model.isRunning ? "Stop" : "Start",
                          systemImage: model.isRunning ? "stop.fill" : "play.fill")
                }
                .help(model.isRunning
                      ? "Stop the encoder (Command-Return)"
                      : "Start the encoder (Command-Return)")

                // The label says the state, not just the action: "Bypassed"
                // with a filled red tint while the chain is bypassed, so the
                // toolbar alone shows that the station is unprocessed.
                Button {
                    model.toggleBypass()
                } label: {
                    Label(model.processingBypass ? "Bypassed" : "Bypass",
                          systemImage: model.processingBypass ? "waveform.slash" : "waveform")
                }
                .tint(model.processingBypass ? BroadcastStyle.overRed : nil)
                .help(model.processingBypass
                      ? "Processing is bypassed. Click to process again (Command-B)."
                      : "Bypass all processing (Command-B)")
            }
            // Same order as the Window menu. A window the mode has no signal
            // for is disabled, not hidden, so the toolbar never changes shape.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.showLevelsWindow), to: nil, from: nil)
                } label: {
                    Label(kLevelsWindowTitle, systemImage: "slider.vertical.3")
                }
                .help("Open the Levels window (Command-6)")

                Button {
                    NSApp.sendAction(#selector(AppDelegate.showPreMPXSpectrumWindow), to: nil, from: nil)
                } label: {
                    Label(kAudioSpectrumWindowTitle, systemImage: "chart.bar")
                }
                .help("Open the Audio Spectrum window (Command-7)")

                Button {
                    NSApp.sendAction(#selector(AppDelegate.showSpectrumWindow), to: nil, from: nil)
                } label: {
                    Label(kMPXSpectrumWindowTitle, systemImage: "chart.bar.xaxis")
                }
                .disabled(!ChainFeature.finalStage.applies(in: model.config.operatingMode))
                .help("Open the MPX Spectrum window (Command-8). Only MPX Output generates a composite.")

                Button {
                    NSApp.sendAction(#selector(AppDelegate.showScopesWindow), to: nil, from: nil)
                } label: {
                    Label(kScopesWindowTitle, systemImage: "waveform.path")
                }
                .disabled(!ChainFeature.finalStage.applies(in: model.config.operatingMode))
                .help("Open the Scopes window (Command-9). Only MPX Output generates a composite.")
            }
        }
    }
}

/// Sidebar grouping every stage by its top-level group (Monitoring,
/// Processing, RDS). Selecting a row updates `model.selectedStage`, which
/// propagates to the legacy enums so existing per-tab content code keeps
/// working unchanged.
struct StageSidebar: View {
    @ObservedObject var model: MPXPrimeViewModel
    /// Which Sound groups are folded shut; all open by default, remembered
    /// for the session. Two levels at most (section > group), per the
    /// taxonomy plan -- never a third.
    @State private var collapsedGroups: Set<StageGroup> = []
    /// The sidebar's search field (the GUI's counterpart of the dashboard's
    /// settings search): a non-empty filter flattens the sidebar to the
    /// pages whose label, group or section matches.
    @State private var filter = ""

    var body: some View {
        List(selection: $model.selectedStage) {
            if !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
                let hits = Stage.allCases.filter { stage in
                    model.isStageVisible(stage) && (
                        stage.label.lowercased().contains(needle)
                        || stage.group.title.lowercased().contains(needle)
                        || Stage.soundGroups.contains { $0.stages.contains(stage) && $0.group.title.lowercased().contains(needle) })
                }
                Section(hits.isEmpty ? "No page matches" : "Pages") {
                    ForEach(hits) { stage in
                        StageSidebarRow(model: model, stage: stage).tag(stage)
                    }
                }
            } else {
            ForEach(Stage.Group.allCases, id: \.rawValue) { group in
                // A mode hides whole stages (the composite-domain ones outside
                // MPX Output, every RDS page); a section or group left empty
                // by that is not drawn at all.
                if group == .sound {
                    soundSection
                } else {
                    let stages = Stage.allCases.filter { $0.group == group && model.isStageVisible($0) }
                    if !stages.isEmpty {
                        Section(group.title) {
                            ForEach(stages) { stage in
                                StageSidebarRow(model: model, stage: stage)
                                    .tag(stage)
                            }
                        }
                    }
                }
            }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filter, placement: .sidebar, prompt: "Search pages")
    }

    /// Sound: the landing pages, then the stages grouped by what they do to
    /// the signal, in signal order -- the same `StageGroup` table the
    /// dashboard renders, so the two sidebars read alike.
    @ViewBuilder private var soundSection: some View {
        Section(Stage.Group.sound.title) {
            ForEach(Stage.soundLandingStages.filter { model.isStageVisible($0) }) { stage in
                StageSidebarRow(model: model, stage: stage).tag(stage)
            }
            ForEach(Stage.soundGroups, id: \.group) { entry in
                let stages = entry.stages.filter { model.isStageVisible($0) }
                if !stages.isEmpty {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { !collapsedGroups.contains(entry.group) },
                            set: { open in if open { collapsedGroups.remove(entry.group) } else { collapsedGroups.insert(entry.group) } })
                    ) {
                        ForEach(stages) { stage in
                            StageSidebarRow(model: model, stage: stage).tag(stage)
                        }
                    } label: {
                        Text(entry.group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One sidebar row. Renders the existing Label (icon + text) and, when
/// the stage has an enable toggle that is currently on, a small accent
/// dot on the trailing edge -- matches Mail's unread-count / Slack's
/// online-status idiom: filled when on, nothing when off, no badge at
/// all for stages with no enable concept (Monitoring, Overview, Core,
/// Loudness and Output, RDS sub-tabs, Snapshots).
struct StageSidebarRow: View {
    @ObservedObject var model: MPXPrimeViewModel
    let stage: Stage

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(stage.label)
            } icon: {
                // Decorative -- the adjacent Text(stage.label)
                // already conveys the row identity to VoiceOver.
                Image(systemName: stage.icon)
                    .accessibilityHidden(true)
                    // Explicit `.tint` foreground on the *icon only* --
                    // keeps text in the default sidebar foreground
                    // (white in dark mode) while icons pick up the
                    // system accent. Hierarchical layering gives the
                    // 3-level tonal depth Apple's first-party sidebars
                    // use (Music.app, Mail.app).
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            }
            Spacer(minLength: 0)
            if model.isStageEnabled(stage) == true {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Enabled")
                    .help("Enabled")
            }
        }
    }
}

/// Content column for the selected stage, with ONE page anatomy for every
/// page: title (the sidebar label), one-sentence subtitle, the page's cards
/// at 20 pt padding and 1120 pt maximum width, the reset button (pages with
/// settings of their own) and the help box from `Stage.helpText`.
struct StageContentView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // A selection the configuration hides (an RDS page outside MPX Output,
        // the other levelling engine's page) shows the Sound Overview, and the
        // header says so too: title and content always name the same page.
        let stage = model.isStageVisible(model.selectedStage) ? model.selectedStage : .processingOverview
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stage.detailTitle)
                    .font(.title2.weight(.semibold))
                Text(stage.detailSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.horizontal, PageLayout.padding)
            .padding(.bottom, 12)

            // Sound pages carry the signal-flow strip as alternate navigation.
            if stage.group == .sound && stage != .processingOverview {
                SignalFlowStrip(model: model)
                    .frame(maxWidth: PageLayout.maxWidth, alignment: .leading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: PageLayout.cardSpacing) {
                    StagePageBody(model: model, stage: stage)

                    if stage.hasReset {
                        HStack {
                            Spacer()
                            Button(stage.resetButtonTitle) {
                                model.resetPage(stage)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Footer help, below the controls and the reset: the
                    // System Settings "explanation under the controls" idiom.
                    TabHelpBox(text: stage.helpText)
                }
                .padding(PageLayout.padding)
                .frame(maxWidth: PageLayout.maxWidth, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The cards of one page, without scroll view, padding, reset or help: the
/// scaffold in `StageContentView` owns those for every page alike.
struct StagePageBody: View {
    @ObservedObject var model: MPXPrimeViewModel
    let stage: Stage

    var body: some View {
        if stage == .monitoring {
            MonitoringDashboardView(model: model)
        } else if stage == .audioIO {
            AudioIOTab(model: model)
        } else if stage == .testTone {
            TestToneView(model: model)
        } else if stage == .snapshots {
            SnapshotsView(model: model)
        } else if let tab = stage.legacyProcessingTab {
            processingPage(tab)
        } else if let tab = stage.legacyRDSTab {
            rdsPage(tab)
        }
    }

    @ViewBuilder private func processingPage(_ tab: ProcessingTab) -> some View {
        switch tab {
        case .overview: ProcessingOverviewGrid(model: model)
        case .core: ProcessingCoreTab(model: model)
        case .agc: ProcessingAGCTab(model: model)
        case .phaseRotator: ProcessingPhaseRotatorTab(model: model)
        case .parametricEQ: ProcessingParametricEQTab(model: model)
        case .primeBass: ProcessingPrimeBassTab(model: model)
        case .multiband: ProcessingMultibandTab(model: model)
        case .advancedDynamics: ProcessingAdvancedDynamicsTab(model: model)
        case .mbLimiter: ProcessingMultibandLimiterTab(model: model)
        case .expander: ProcessingExpanderTab(model: model)
        case .bassClipper: ProcessingBassClipperTab(model: model)
        case .dcClipper: ProcessingDCClipperTab(model: model)
        case .hfLimiter: ProcessingHFLimiterTab(model: model)
        case .limiter: ProcessingLimiterTab(model: model)
        case .bs412: ProcessingBS412Tab(model: model)
        case .stereoCoder: ProcessingStereoCoderTab(model: model)
        case .compositeClipper: ProcessingCompositeClipperTab(model: model)
        case .finalStage: ProcessingFinalStageTab(model: model)
        }
    }

    @ViewBuilder private func rdsPage(_ tab: RDSTab) -> some View {
        switch tab {
        case .control: RDSStatusTab(model: model)
        case .program: RDSProgramTab(model: model)
        case .radiotext: RDSRadiotextTab(model: model)
        case .af: RDSAFTab(model: model)
        case .schedule: RDSScheduleTab(model: model)
        case .carrier: RDSCarrierTab(model: model)
        }
    }
}

#endif  // os(macOS)
