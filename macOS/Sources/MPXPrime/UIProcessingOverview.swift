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
    /// When true, the grid renders without its own ScrollView so it can
    /// be embedded inside another scrolling container (e.g. the
    /// Monitoring dashboard). Default false preserves the existing
    /// behaviour for the Processing → Overview stage host.
    var embedded: Bool = false

    // 4-up grid. Minimum card width kept tight enough to fit four per row
    // on the default window width without horizontal scroll; cards grow
    // to fill when the window expands.
    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12, alignment: .top)
    ]

    var body: some View {
        if embedded {
            grid
        } else {
            ScrollView {
                grid
            }
        }
    }

    @ViewBuilder
    private var grid: some View {
            LazyVGrid(columns: columns, spacing: 12) {
                stageCard(
                    .phaseRotator,
                    title: "Phase Rotator",
                    subtitle: phaseRotatorSubtitle,
                    enabledPath: \.phaseRotationEnabled
                )
                stageCard(
                    .agc,
                    title: "Wideband AGC",
                    subtitle: agcSubtitle,
                    enabledPath: \.widebandAGCEnabled,
                    liveReadout: { $0.agcStateText },
                    bypassedByAdvancedDynamics: model.config.advancedDynamicsEnabled
                )
                stageCard(
                    .parametricEQ,
                    title: "Parametric EQ",
                    subtitle: parametricEQSubtitle,
                    enabledPath: \.parametricEQEnabled
                )
                stageCard(
                    .multiband,
                    title: "Multiband",
                    subtitle: multibandSubtitle,
                    enabledPath: \.multibandEnabled,
                    liveReadout: { $0.multibandStateText },
                    bypassedByAdvancedDynamics: model.config.advancedDynamicsEnabled
                )
                stageCard(
                    .advancedDynamics,
                    title: "Advanced Dynamics",
                    subtitle: advancedDynamicsSubtitle,
                    enabledPath: \.advancedDynamicsEnabled
                )
                stageCard(
                    .expander,
                    title: "Downward Expander",
                    subtitle: expanderSubtitle,
                    enabledPath: \.downwardExpanderEnabled,
                    bypassedByAdvancedDynamics: model.config.advancedDynamicsEnabled
                )
                stageCard(
                    .mbLimiter,
                    title: "Multiband Limiter",
                    subtitle: mbLimiterSubtitle,
                    enabledPath: \.multibandLimiterEnabled,
                    bypassedByAdvancedDynamics: model.config.advancedDynamicsEnabled
                )
                stageCard(
                    .primeBass,
                    title: "PrimeBass",
                    subtitle: primeBassSubtitle,
                    enabledPath: \.primeBassEnabled,
                    liveReadout: { $0.primeBassStateText }
                )
                stageCard(
                    .bassClipper,
                    title: "Bass Clipper",
                    subtitle: bassClipperSubtitle,
                    enabledPath: \.bassClipperEnabled
                )
                stageCard(
                    .dcClipper,
                    title: "DC Clipper",
                    subtitle: dcClipperSubtitle,
                    enabledPath: \.dcClipperEnabled
                )
                stageCard(
                    .limiter,
                    title: "Audio Limiter",
                    subtitle: limiterSubtitle,
                    enabledPath: \.preEncodeAudioLimiterEnabled,
                    liveReadout: { String(format: "GR %.1f dB", $0.preEncodeLimiterGainReductionDBValue) }
                )
                // Composite-domain stages are absent in processed-audio output.
                if !model.processedAudioOutputActive {
                    stageCard(
                        .compositeClipper,
                        title: "Composite Clipper",
                        subtitle: compositeClipperSubtitle,
                        enabledPath: \.compositeClipperEnabled,
                        liveReadout: { String(format: "GR %.1f dB", $0.compositeClipperGainReductionDBValue) }
                    )
                    stageCard(
                        .bs412,
                        title: "BS.412 Power",
                        subtitle: bs412Subtitle,
                        enabledPath: \.bs412Enabled
                    )
                }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // MARK: - Card builder

    @ViewBuilder
    private func stageCard(
        _ tab: ProcessingTab,
        title: String,
        subtitle: String,
        enabledPath: WritableKeyPath<AppConfig, Bool>,
        heroValue: String? = nil,
        liveReadout: ((LiveTelemetry) -> String)? = nil,
        bypassedByAdvancedDynamics: Bool = false
    ) -> some View {
        // Use configBinding so the toggle follows the same runtime-apply /
        // live-apply semantics as the detail tabs — no ad-hoc mutation.
        let binding = model.configBinding(enabledPath, runtimeDisposition: .live)
        // A stage bypassed by Advanced Dynamics renders as off (ghosted)
        // even when its own flag is on — the card shows the EFFECTIVE state.
        let enabled = model.config[keyPath: enabledPath] && !bypassedByAdvancedDynamics
        let subtitle = bypassedByAdvancedDynamics
            ? "Bypassed — Advanced Dynamics is on"
            : subtitle
        VStack(alignment: .leading, spacing: 6) {
            // Whole title+hero+subtitle region is one Button so clicking
            // anywhere on the card (except the Enabled toggle) drills
            // into the sidebar's detail row for this stage. Mirrors
            // System Settings / Music navigation cards — the trailing
            // chevron is the visual affordance, but the entire surface
            // is the hit target.
            Button {
                model.selectedStage = tab.stage
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        // Leading enabled-state dot (accent on, hairline off)
                        // matching the sidebar row vocabulary. Reflects the
                        // config flag (static), not telemetry.
                        Circle()
                            .fill(enabled ? BroadcastStyle.accent : BroadcastStyle.panelBorder)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    if let heroValue {
                        Text(heroValue)
                            .font(BroadcastStyle.heroReadout)
                            .foregroundStyle(enabled ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    // Live per-stage readout (GR / state). Isolated in a
                    // LiveTelemetryView leaf with a fixed frame + lineLimit(1)
                    // so a metering tick repaints only this text and never
                    // propagates a layout pass out to the card (the
                    // load-bearing Canvas/LiveTelemetry rule).
                    if let liveReadout {
                        LiveObservationView(telemetry: model.telemetry) { t in
                            Text(liveReadout(t))
                                .font(BroadcastStyle.valueReadout)
                                .monospacedDigit()
                                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text(subtitle)
                        .font(BroadcastStyle.valueReadout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(minHeight: 32, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(title) settings")
            .accessibilityLabel("Open \(title) settings")
            // Embedded cards (Monitoring dashboard's Signal Chain panel)
            // drop the per-card Enable toggle — the sidebar's stage-row
            // dot indicator and each stage's detail tab already expose
            // the same control, so a third copy here is duplication
            // operators have to scan past. Processing > Overview keeps
            // its toggles because that surface is the configuration grid.
            if !embedded {
                Toggle("Enabled", isOn: binding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .disabled(bypassedByAdvancedDynamics)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(bypassedByAdvancedDynamics ? 0.55 : 1.0)
        .background(BroadcastStyle.meterSurface.opacity(0.70))
        .overlay(
            RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous)
                .stroke(enabled ? BroadcastStyle.accent.opacity(0.40) : BroadcastStyle.panelBorder, lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: BroadcastStyle.panelInsetCornerRadius, style: .continuous))
    }

    // MARK: - Subtitle builders
    //
    // Each stage picks the parameter an operator most often glances at
    // from the detail tab. Stored directly in AppConfig; read via
    // `model.config` so updates here and in the detail tabs stay in
    // sync automatically.

    private var phaseRotatorSubtitle: String {
        String(format: "f %.0f Hz", model.config.phaseRotationFreqHz)
    }

    private var agcSubtitle: String {
        String(format: "Target %.1f dB · range %.0f/%+0.0f dB",
            model.config.widebandAGCTargetDB,
            model.config.widebandAGCMinGainDB,
            model.config.widebandAGCMaxGainDB)
    }

    private var parametricEQSubtitle: String {
        "4 bands · shelf+peak+peak+shelf"
    }

    private var primeBassSubtitle: String {
        let bass = model.config.monoBassEnabled
            ? String(format: "Mono<%.0f", model.config.monoBassFreqHz) : "Mono off"
        return String(format: "Amt %.2f · f %.0f Hz · %@",
            model.config.primeBassAmount,
            model.config.primeBassFreqHz,
            bass)
    }

    private var multibandSubtitle: String {
        "\(model.config.multibandMode)-band · LR4 · \(model.config.multibandPresetID)"
    }

    private var advancedDynamicsSubtitle: String {
        String(format: "Target %.1f dB · density %.2f · replaces AGC+MB",
            model.config.advancedDynamicsTargetDB,
            model.config.advancedDynamicsDensity)
    }

    private var mbLimiterSubtitle: String {
        String(format: "Thr %.1f dB · atk %.1f ms · rel %.0f ms",
            model.config.multibandLimiterThresholdDB,
            model.config.multibandLimiterAttackMS,
            model.config.multibandLimiterReleaseMS)
    }

    private var expanderSubtitle: String {
        String(format: "Thr %.0f dB · ratio %.1f:1",
            model.config.expanderThresholdDB,
            model.config.expanderRatio)
    }

    private var bassClipperSubtitle: String {
        String(format: "X %.0f Hz · thr %.1f dB · drv %.2f",
            model.config.bassClipperCrossoverHz,
            model.config.bassClipperThresholdDB,
            model.config.bassClipperDrive)
    }

    private var dcClipperSubtitle: String {
        String(format: "Ceil %.1f dB · cancel %.0f Hz",
            model.config.dcClipperCeilingDB,
            model.config.dcClipperCancelFreqHz)
    }

    private var limiterSubtitle: String {
        let kernel = model.config.preEncodeBandlimitedResidualEnabled ? "residual" : "tanh"
        return String(format: "Thr %.2f | rel %.0f ms | %@",
            model.config.preEncodeThreshold,
            model.config.preEncodeReleaseMS,
            kernel)
    }

    private var bs412Subtitle: String {
        String(format: "Thr %.1f dB · win %.0f s",
            model.config.bs412ThresholdDB,
            model.config.bs412WindowSeconds)
    }

    private var compositeClipperSubtitle: String {
        String(format: "Thr %.1f dB · ceil %.1f dB · drive %.1f dB",
            model.config.compositeClipperThresholdDB,
            model.config.compositeClipperCeilingDB,
            model.config.finalDriveDB)
    }

}

#endif  // os(macOS)
