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
                    title: "Phase Rot",
                    subtitle: phaseRotatorSubtitle,
                    enabledPath: \.phaseRotationEnabled
                )
                stageCard(
                    .agc,
                    title: "Wideband AGC",
                    subtitle: agcSubtitle,
                    enabledPath: \.widebandAGCEnabled
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
                    enabledPath: \.multibandEnabled
                )
                stageCard(
                    .expander,
                    title: "Downward Expander",
                    subtitle: expanderSubtitle,
                    enabledPath: \.downwardExpanderEnabled
                )
                stageCard(
                    .mbLimiter,
                    title: "MB Limiter",
                    subtitle: mbLimiterSubtitle,
                    enabledPath: \.multibandLimiterEnabled
                )
                stageCard(
                    .widener,
                    title: "Stereo Widener",
                    subtitle: widenerSubtitle,
                    enabledPath: \.stereoWidenEnabled
                )
                stageCard(
                    .primeBass,
                    title: "PrimeBass",
                    subtitle: primeBassSubtitle,
                    enabledPath: \.primeBassEnabled
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
                    enabledPath: \.preEncodeAudioLimiterEnabled
                )
                stageCard(
                    .compositeClipper,
                    title: "Composite Clipper",
                    subtitle: compositeClipperSubtitle,
                    enabledPath: \.compositeClipperEnabled
                )
                stageCard(
                    .bs412,
                    title: "BS.412 Power",
                    subtitle: bs412Subtitle,
                    enabledPath: \.bs412Enabled
                )
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
        heroValue: String? = nil
    ) -> some View {
        // Use configBinding so the toggle follows the same runtime-apply /
        // live-apply semantics as the detail tabs — no ad-hoc mutation.
        let binding = model.configBinding(enabledPath, runtimeDisposition: .live)
        let enabled = model.config[keyPath: enabledPath]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                Spacer()
                Button {
                    model.selectedProcessingTab = tab
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open \(title) settings")
                .accessibilityLabel("Open \(title) settings")
            }
            if let heroValue {
                Text(heroValue)
                    .font(BroadcastStyle.heroReadout)
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            Text(subtitle)
                .font(BroadcastStyle.valueReadout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(minHeight: 32, alignment: .topLeading)
            Toggle("Enabled", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        String(format: "Amt %.2f · f %.0f Hz · drv %.2f",
            model.config.primeBassAmount,
            model.config.primeBassFreqHz,
            model.config.primeBassDrive)
    }

    private var widenerSubtitle: String {
        let bass = model.config.monoBassEnabled ? String(format: "Mono<%.0f", model.config.monoBassFreqHz) : "Mono off"
        return String(format: "W %.2f · C %.2f · %@",
            model.config.stereoWidenWidth,
            model.config.stereoWidenCenter,
            bass)
    }

    private var multibandSubtitle: String {
        "\(model.config.multibandMode)-band · LR4 · \(model.config.multibandPresetID)"
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
