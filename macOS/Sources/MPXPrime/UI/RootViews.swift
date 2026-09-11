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
                .inspector(isPresented: $model.inspectorVisible) {
                    StageInspector(model: model)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
        }
        .toolbar {
            // Frequently used commands belong in the toolbar (HIG). The
            // sidebar-collapse toggle is added automatically by
            // NavigationSplitView at the leading edge.
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

                Button {
                    model.toggleBypass()
                } label: {
                    Label("Bypass",
                          systemImage: model.processingBypass ? "waveform.slash" : "waveform")
                }
                .help("Toggle processing bypass (Command-B)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.openConfig), to: nil, from: nil)
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a configuration file (Command-O)")

                Button {
                    model.saveCurrentConfig()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .help("Save the current configuration (Command-S)")

                // Composite scope is meaningless without an MPX composite.
                if !model.processedAudioOutputActive {
                    Button {
                        NSApp.sendAction(#selector(AppDelegate.showScopesWindow), to: nil, from: nil)
                    } label: {
                        Label("Scopes", systemImage: "waveform.path")
                    }
                    .help("Open the Scopes window")
                }

                // In processed-audio mode the MPX spectrum is meaningless; the
                // Spectrum button opens the Audio (pre-MPX) spectrum instead.
                Button {
                    if model.processedAudioOutputActive {
                        NSApp.sendAction(#selector(AppDelegate.showPreMPXSpectrumWindow), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(#selector(AppDelegate.showSpectrumWindow), to: nil, from: nil)
                    }
                } label: {
                    Label("Spectrum", systemImage: "chart.bar.xaxis")
                }
                .help(model.processedAudioOutputActive ? "Open the Audio Spectrum window" : "Open the MPX Spectrum window")

                Button {
                    NSApp.sendAction(#selector(AppDelegate.showLevelsWindow), to: nil, from: nil)
                } label: {
                    Label("Levels", systemImage: "slider.vertical.3")
                }
                .help("Open the Levels window")
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

    var body: some View {
        List(selection: $model.selectedStage) {
            ForEach(Stage.Group.allCases, id: \.rawValue) { group in
                // Processed-audio output hides the RDS group and the
                // composite-domain Processing stages (composite clipper, BS.412).
                let stages = Stage.allCases.filter { $0.group == group && model.isStageVisible($0) }
                if !stages.isEmpty {
                    Section(group.rawValue) {
                        ForEach(stages) { stage in
                            StageSidebarRow(model: model, stage: stage)
                                .tag(stage)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// One sidebar row. Renders the existing Label (icon + text) and, when
/// the stage has an enable toggle that is currently on, a small accent
/// dot on the trailing edge — matches Mail's unread-count / Slack's
/// online-status idiom: filled when on, nothing when off, no badge at
/// all for stages with no enable concept (Monitoring, Overview, Core,
/// Final Stage, RDS sub-tabs, Snapshots).
struct StageSidebarRow: View {
    @ObservedObject var model: MPXPrimeViewModel
    let stage: Stage

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(stage.label)
            } icon: {
                // Decorative — the adjacent Text(stage.label)
                // already conveys the row identity to VoiceOver.
                Image(systemName: stage.icon)
                    .accessibilityHidden(true)
                    // Explicit `.tint` foreground on the *icon only* —
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

/// Content column for the currently-selected stage. Each stage renders its
/// own scroll view + content; for Processing and RDS stages the per-tab view
/// is the same one the legacy segmented-picker section used, plus the
/// per-tab reset button. Monitoring stays as a single dashboard.
struct StageContentView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // If the selection is hidden by the active output mode (e.g. an RDS or
        // composite stage while processed-audio output is on), display the
        // Processing overview instead of a stale pane.
        let stage = model.isStageVisible(model.selectedStage) ? model.selectedStage : .processingOverview
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(stage.detailTitle)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.top, 16)
            .padding(.horizontal, 22)
            .padding(.bottom, 8)

            Text(stage.detailSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)

            Group {
                if stage == .monitoring {
                    MonitoringDashboardView(model: model)
                } else if stage == .audioIO {
                    AudioIOTab(model: model)
                } else if stage == .testTone {
                    TestToneView(model: model)
                } else if stage == .snapshots {
                    SnapshotsView(model: model)
                } else if !model.isStageVisible(model.selectedStage) {
                    ProcessingOverviewGrid(model: model)
                } else if stage.legacyProcessingTab != nil {
                    StageProcessingContent(model: model)
                } else if stage.legacyRDSTab != nil {
                    StageRDSContent(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Content for a Processing stage selection. Hosts the existing per-tab
/// view plus the per-tab reset button. The legacy segmented Picker is
/// gone — sidebar selection drives `selectedProcessingTab` via the
/// `selectedStage.didSet` sync. A read-only signal-flow chip strip sits
/// at the top as alternate navigation (Wheatstone-style block-diagram
/// hint without the editor cost).
struct StageProcessingContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedStage != .processingOverview {
                // Cap to the same 1120 pt width as the content column
                // below so the strip sits horizontally centered over its
                // content. Default `.frame(maxWidth:)` alignment is
                // `.center`, so no extra alignment argument needed.
                SignalFlowStrip(model: model)
                    .frame(maxWidth: 1120)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.selectedProcessingTab {
                    case .overview:
                        ProcessingOverviewGrid(model: model)
                    case .formatProfile:
                        ProcessingFormatProfileTab(model: model)
                    case .core:
                        ProcessingCoreTab(model: model)
                    case .agc:
                        ProcessingAGCTab(model: model)
                    case .phaseRotator:
                        ProcessingPhaseRotatorTab(model: model)
                    case .parametricEQ:
                        ProcessingParametricEQTab(model: model)
                    case .primeBass:
                        ProcessingPrimeBassTab(model: model)
                    case .multiband:
                        ProcessingMultibandTab(model: model)
                    case .advancedDynamics:
                        ProcessingAdvancedDynamicsTab(model: model)
                    case .mbLimiter:
                        ProcessingMultibandLimiterTab(model: model)
                    case .expander:
                        ProcessingExpanderTab(model: model)
                    case .bassClipper:
                        ProcessingBassClipperTab(model: model)
                    case .dcClipper:
                        ProcessingDCClipperTab(model: model)
                    case .hfClipper:
                        ProcessingHFClipperTab(model: model)
                    case .limiter:
                        ProcessingLimiterTab(model: model)
                    case .bs412:
                        ProcessingBS412Tab(model: model)
                    case .stereoCoder:
                        ProcessingStereoCoderTab(model: model)
                    case .compositeClipper:
                        ProcessingCompositeClipperTab(model: model)
                    case .finalStage:
                        ProcessingFinalStageTab(model: model)
                    }

                    if model.selectedProcessingTab != .overview {
                        HStack {
                            Spacer()
                            Button(model.selectedProcessingTab.resetButtonTitle) {
                                model.resetCurrentProcessingTabToDefaults()
                            }
                            .buttonStyle(.bordered)
                        }

                        // Tab help text as a footer block below the
                        // controls and the Reset action — matches
                        // System Settings / Xcode "explanation under
                        // the controls" idiom rather than competing
                        // with the controls visually at the top of
                        // the tab.
                        TabHelpBox(text: model.selectedProcessingTab.helpText)
                    }
                }
                .padding(20)
                .frame(maxWidth: 1120, alignment: .topLeading)
            }
        }
    }
}

/// Content for an RDS stage selection.
struct StageRDSContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.selectedRDSTab {
                case .control:
                    RDSStatusTab(model: model)
                case .program:
                    RDSProgramTab(model: model)
                case .radiotext:
                    RDSRadiotextTab(model: model)
                case .longPS:
                    RDSLongPSTab(model: model)
                case .af:
                    RDSAFTab(model: model)
                case .schedule:
                    RDSScheduleTab(model: model)
                case .carrier:
                    RDSCarrierTab(model: model)
                }

                HStack {
                    Spacer()
                    Button(model.selectedRDSTab.resetButtonTitle) {
                        model.resetCurrentRDSTabToDefaults()
                    }
                    .buttonStyle(.bordered)
                }

                // Footer help block — same pattern as Processing tabs.
                // Sits below the controls and the Reset action so it
                // reads as explanatory text rather than competing with
                // the controls at the top of the view.
                TabHelpBox(text: model.selectedRDSTab.helpText)
            }
            .padding(20)
            .frame(maxWidth: 1120, alignment: .topLeading)
        }
    }
}

enum CardStyle {
    /// Standard broadcast panel — used for parameter controls, general
    /// status blocks, RDS config. Uses the window control-background
    /// surface.
    case standard
    /// Meter / readout plate — slightly darker surface so heat-mapped
    /// bars and LED dots pop. Used for metering cards and RDS live
    /// snapshots where the content is dense numeric readout.
    case meter
}

struct Card<Content: View>: View {
    let title: String
    let style: CardStyle
    @ViewBuilder var content: Content

    init(title: String, style: CardStyle = .standard, @ViewBuilder content: () -> Content) {
        self.title = title
        self.style = style
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: BroadcastStyle.cardSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(surface)
            .overlay(
                RoundedRectangle(cornerRadius: BroadcastStyle.panelCornerRadius)
                    .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelCornerRadius))
        }
    }

    private var surface: Color {
        switch style {
        case .standard: return BroadcastStyle.panelSurface
        case .meter:    return BroadcastStyle.meterSurface
        }
    }

    private var padding: CGFloat {
        switch style {
        case .standard: return BroadcastStyle.cardPadding
        case .meter:    return BroadcastStyle.meterCardPadding
        }
    }
}

#endif  // os(macOS)
