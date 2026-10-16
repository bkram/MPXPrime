// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import MPXPrimeUI
import SwiftUI

// Broadcast-console "everything at once" view for the Processing section.
//
// Before this overview, entering Processing dropped the operator into
// whichever parameter tab was last selected, with no quick way to see
// which stages are engaged or what they're doing. Competitor processors
// (Orban, Stereotool) give you a bird's-eye grid on entry; this is the
// equivalent.
//
// Each card shows: stage name, live enabled toggle, one telling metric
// (the parameter an operator most wants to glance at for that stage),
// and a chevron button that jumps to the detailed tab for that stage.
// All data-binding reads from the shared view model so edits here
// propagate through the same RuntimeConfig path as the detail tabs.

struct ProcessingOverviewGrid: View {
    @ObservedObject var model: MPXPrimeViewModel
    /// When true, the grid renders alone (no Format Profile or levelling
    /// cards and no per-card switches), for embedding as a read-only chain.
    var embedded: Bool = false

    // Adaptive grid: cards fill the width, four per row at the default size.
    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12, alignment: .top)
    ]

    var body: some View {
        if embedded {
            grid
        } else {
            VStack(alignment: .leading, spacing: PageLayout.cardSpacing) {
                formatProfileCard
                levellingCard
                Card(title: "Stages") {
                    grid
                }
            }
        }
    }

    // MARK: - Format Profile

    /// The station's Format Profile: the choice and, beside it, the button
    /// that re-applies it after per-stage tuning drifted (`applyFormatProfile`
    /// via `PresetCatalog`). A profile owns stage keys only -- devices,
    /// levels, the operating mode, the control server and calibration are
    /// not in it. `custom` is the sentinel for bespoke tuning: nothing to
    /// re-apply, so the button rests. (The separate Format Profile page and
    /// "Recommended settings" card are merged into this one.)
    private var formatProfileCard: some View {
        let id = model.config.formatProfileID
        let canReapply = MPXPrimeViewModel.formatProfile(forID: id) != nil && id != "custom"
        return Card(title: "Format Profile") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Format Profile", selection: model.formatProfileBinding()) {
                    ForEach(MPXPrimeViewModel.formatProfiles) { profile in
                        Text(profile.title).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Button("Re-apply Profile") {
                    model.applyFormatProfile(id)
                    model.normalizeSelection()
                }
                .buttonStyle(.bordered)
                .disabled(!canReapply)
                .help("Re-applies the profile's stage settings (multiband, final stage, PrimeBass, mono bass, clippers, limiters, AGC). Applies live. Devices, levels and the operating mode are not touched.")
                Spacer(minLength: 0)
            }
            Text(model.currentFormatProfileSummary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Levelling engine

    /// The levelling engine as ONE segmented choice, exactly like the
    /// operating mode on Audio I/O. The setter writes the stored flag through
    /// the live path (the engine swaps levellers without a restart) and then
    /// re-checks the selection, because the page the operator was on may
    /// belong to the engine that just went away.
    private var levellingBinding: Binding<LevellingEngine> {
        Binding(
            get: { LevellingEngine.current(for: model.config) },
            set: { engine in
                guard engine != LevellingEngine.current(for: model.config) else { return }
                model.setConfigValue(\.advancedDynamicsEnabled, engine == .advanced, runtimeDisposition: .live)
                model.normalizeSelection()
            }
        )
    }

    private var levellingCard: some View {
        Card(title: "Levelling Engine") {
            Picker("Levelling Engine", selection: levellingBinding) {
                ForEach(LevellingEngine.allCases, id: \.self) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("AGC + Multiband: the wideband AGC followed by the multiband compressor, with its per-band Expander and Band Limiter. Advanced Dynamics: one 5-band leveller that does the work of all four. The pages of the engine not in use are hidden. Applies live.")
        }
    }

    // MARK: - Stage grid

    /// The stages in the order the signal meets them, each with its master
    /// name from the `Stage` table. Only the levelling engine in use has
    /// cards, and the mode gating reads `ChainFeature` like the sidebar.
    private var gridStages: [Stage] {
        Stage.signalChain
            .flatMap { stage -> [Stage] in
                // The Expander and Band Limiter run inside the multiband.
                stage == .processingMultiband
                    ? [.processingMultiband, .processingExpander, .processingMBLimiter] : [stage]
            }
            .filter { $0 != .processingCore && $0 != .processingFinalStage && model.isStageVisible($0) }
    }

    @ViewBuilder
    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(gridStages, id: \.self) { stage in
                stageCard(stage)
            }
        }
    }

    /// The enable flag a card's switch drives, or nil for a stage without
    /// one. Stereo encoding is always on, so the Stereo Coder card has no
    /// enable dot; its switch is the SSB option and says so.
    private func enablePath(_ stage: Stage) -> (path: WritableKeyPath<AppConfig, Bool>, label: String)? {
        switch stage {
        case .processingPhaseRotator: return (\.phaseRotationEnabled, "Enabled")
        case .processingAGC: return (\.widebandAGCEnabled, "Enabled")
        case .processingParametricEQ: return (\.parametricEQEnabled, "Enabled")
        case .processingMultiband: return (\.multibandEnabled, "Enabled")
        case .processingExpander: return (\.downwardExpanderEnabled, "Enabled")
        case .processingMBLimiter: return (\.multibandLimiterEnabled, "Enabled")
        case .processingPrimeBass: return (\.primeBassEnabled, "Enabled")
        case .processingBassClipper: return (\.bassClipperEnabled, "Enabled")
        case .processingDCClipper: return (\.dcClipperEnabled, "Enabled")
        case .processingHFLimiter: return (\.hfLimiterEnabled, "Enabled")
        case .processingLimiter: return (\.preEncodeAudioLimiterEnabled, "Enabled")
        case .processingStereoCoder: return (\.ssbStereoEnabled, "SSB")
        case .processingCompositeClipper: return (\.compositeClipperEnabled, "Enabled")
        case .processingBS412: return (\.bs412Enabled, "Enabled")
        default: return nil
        }
    }

    private func liveReadout(_ stage: Stage) -> ((LiveTelemetry) -> String)? {
        switch stage {
        case .processingAGC: return { $0.agcStateText }
        case .processingMultiband: return { $0.multibandStateText }
        case .processingPrimeBass: return { $0.primeBassStateText }
        case .processingLimiter: return { String(format: "Gain Reduction %.1f dB", $0.preEncodeLimiterGainReductionDBValue) }
        case .processingCompositeClipper: return { String(format: "Gain Reduction %.1f dB", $0.compositeClipperGainReductionDBValue) }
        default: return nil
        }
    }

    // MARK: - Card builder

    @ViewBuilder
    private func stageCard(_ stage: Stage) -> some View {
        let enable = enablePath(stage)
        // A stage without an enable flag of its own draws as enabled. The
        // dot reads `isStageEnabled`, the sidebar's rule, so the two agree.
        let enabled = model.isStageEnabled(stage) ?? true
        let title = stage.label
        InsetTile(highlighted: enabled) {
            // The whole title and summary region opens the stage's page.
            Button {
                model.selectedStage = stage
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if model.isStageEnabled(stage) != nil {
                            Circle()
                                .fill(enabled ? BroadcastStyle.accent : BroadcastStyle.panelBorder)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    // Live per-stage readout in an isolated telemetry leaf
                    // with one line, so a metering tick repaints only it.
                    if let readout = liveReadout(stage) {
                        LiveObservationView(telemetry: model.telemetry) { t in
                            Text(readout(t))
                                .font(BroadcastStyle.valueReadout)
                                .monospacedDigit()
                                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text(Self.summary(for: stage, config: model.config))
                        .font(BroadcastStyle.valueReadout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(minHeight: 32, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(title)")
            .accessibilityLabel("Open \(title)")
            if !embedded, let enable {
                // Same live path as the stage page's own enable.
                Toggle(enable.label, isOn: model.setting(enable.path, .live).binding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(stage == .processingStereoCoder
                          ? "SSB stereo option. Stereo encoding itself is always on."
                          : "Turn \(title) on or off.")
            }
        }
    }

    // MARK: - Summaries

    /// One line per stage with the values an operator glances at, in full
    /// words, separated by commas, every number with its unit.
    static func summary(for stage: Stage, config c: AppConfig) -> String {
        switch stage {
        case .processingPhaseRotator:
            return String(format: "Frequency %.0f Hz", c.phaseRotationFreqHz)
        case .processingAGC:
            return String(format: "Target %.1f dB, range %.0f to %+.0f dB",
                          c.widebandAGCTargetDB, c.widebandAGCMinGainDB, c.widebandAGCMaxGainDB)
        case .processingParametricEQ:
            return "4 bands: shelf, peak, peak, shelf"
        case .processingMultiband:
            let filter = c.multibandFIREnabled ? "linear phase" : "low latency"
            return "\(c.multibandMode) bands, \(filter), preset \(c.multibandPresetID)"
        case .processingAdvancedDynamics:
            return String(format: "Target %.1f dB, density %.0f%%", c.advancedDynamicsTargetDB, c.advancedDynamicsDensity * 100)
        case .processingExpander:
            return String(format: "Threshold %.0f dB, ratio %.1f:1", c.expanderThresholdDB, c.expanderRatio)
        case .processingMBLimiter:
            return String(format: "Threshold %.1f dB, attack %.1f ms, release %.0f ms",
                          c.multibandLimiterThresholdDB, c.multibandLimiterAttackMS, c.multibandLimiterReleaseMS)
        case .processingPrimeBass:
            let mono = c.monoBassEnabled ? String(format: "mono below %.0f Hz", c.monoBassFreqHz) : "mono bass off"
            return String(format: "Amount %.0f%%, %.0f Hz, %@", c.primeBassAmount * 100, c.primeBassFreqHz, mono)
        case .processingBassClipper:
            return String(format: "Threshold %.1f dB, crossover %.0f Hz, drive %.0f%%",
                          c.bassClipperThresholdDB, c.bassClipperCrossoverHz, c.bassClipperDrive * 100)
        case .processingDCClipper:
            return String(format: "Ceiling %.1f dB, cancellation %.0f Hz", c.dcClipperCeilingDB, c.dcClipperCancelFreqHz)
        case .processingHFLimiter:
            return String(format: "Threshold %.1f dB, top %.1f dB", c.hfLimiterThresholdDB, c.hfLimiterTopThresholdDB)
        case .processingLimiter:
            return String(format: "Threshold %.1f dBFS, release %.0f ms",
                          MPXPrimeViewModel.dBFS(fromLinear: c.preEncodeThreshold), c.preEncodeReleaseMS)
        case .processingStereoCoder:
            return String(format: "Pilot %.1f%%, SSB %@", c.pilotLevel * 100, c.ssbStereoEnabled ? "on" : "off")
        case .processingCompositeClipper:
            return String(format: "Threshold %.1f dB, ceiling %.1f dB, drive %.1f dB",
                          c.compositeClipperThresholdDB, c.compositeClipperCeilingDB, c.finalDriveDB)
        case .processingBS412:
            return String(format: "Ceiling %.1f dBr over 60 s", c.bs412CeilingDBr)
        default:
            return stage.detailSubtitle
        }
    }
}

#endif  // os(macOS)
