import SwiftUI

/// Compact "block-diagram chip strip" header for the Processing section.
/// Renders the audio chain as a horizontal row of clickable chips — input
/// on the left, output on the right, current stage highlighted. Tapping
/// a chip selects that stage in the sidebar (drives `model.selectedStage`).
///
/// Each chip is a thin pill: stage label + small leading dot when bypassed.
/// Strip is read-only signal flow; it doesn't model branches or returns.
/// Wheatstone-style draggable block-diagram editing is explicitly out of
/// scope (signal flow is fixed in MPXGenerator.swift).
struct SignalFlowStrip: View {
    @ObservedObject var model: MPXPrimeViewModel

    /// Stages shown in the strip, in chain order. Phase Rotator runs
    /// before AGC (cf. MPXGenerator.processProgramStereo). Composite
    /// Clipper runs before BS.412 in the audio-composite domain
    /// (cf. processFinalComposite); earlier strip ordering had them
    /// reversed.
    ///
    /// MB Limiter and Downward Expander are *per-band* processors
    /// inside the Multiband stage — not three serial stages — so the
    /// strip only shows the `MB` pill. They keep their own sidebar
    /// entries for operator-facing controls.
    private static let chainStages: [Stage] = [
        .processingCore,
        .processingPhaseRotator,
        .processingAGC,
        .processingParametricEQ,
        .processingMultiband,
        .processingWidener,
        .processingPrimeBass,
        .processingBassClipper,
        .processingDCClipper,
        .processingLimiter,
        .processingCompositeClipper,
        .processingBS412,
        .processingFinalStage,
    ]

    /// Compact label for each stage in the chip — chain order is
    /// dense; full-length labels won't fit at typical window widths.
    private static let chipLabels: [Stage: String] = [
        .processingCore: "Core",
        .processingPhaseRotator: "PhaseRot",
        .processingAGC: "AGC",
        .processingParametricEQ: "PEQ",
        .processingPrimeBass: "PrimeBass",
        .processingWidener: "Width",
        .processingMultiband: "MB",
        .processingBassClipper: "BassClip",
        .processingDCClipper: "DC-Clip",
        .processingLimiter: "Lim",
        .processingCompositeClipper: "MPX-Clip",
        .processingBS412: "BS.412",
        .processingFinalStage: "Final",
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip(text: "IN", kind: .terminal)
                connector
                ForEach(Array(Self.chainStages.enumerated()), id: \.element) { _, stage in
                    chip(
                        text: Self.chipLabels[stage] ?? stage.label,
                        kind: stage == model.selectedStage ? .active : .stage,
                        stage: stage
                    )
                    connector
                }
                chip(text: "OUT", kind: .terminal)
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private enum ChipKind {
        case stage
        case active
        case terminal
    }

    @ViewBuilder
    private func chip(text: String, kind: ChipKind, stage: Stage? = nil) -> some View {
        let label = Text(text)
            .font(.caption.monospaced().weight(kind == .active ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 4)

        switch kind {
        case .stage:
            Button {
                if let stage { model.selectedStage = stage }
            } label: {
                VStack(spacing: 0) {
                    label.foregroundStyle(.secondary)
                    Self.grBar(forGR: stage.flatMap { model.signalFlowGR(for: $0) })
                }
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.quaternary.opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help(Self.chipTooltip(stage: stage, gr: stage.flatMap { model.signalFlowGR(for: $0) }))

        case .active:
            Button {
                if let stage { model.selectedStage = stage }
            } label: {
                VStack(spacing: 0) {
                    label.foregroundStyle(.primary)
                    Self.grBar(forGR: stage.flatMap { model.signalFlowGR(for: $0) })
                }
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(BroadcastStyle.accent.opacity(0.20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(BroadcastStyle.accent.opacity(0.85), lineWidth: 1.0)
                )
            }
            .buttonStyle(.plain)
            .help(Self.chipTooltip(stage: stage, gr: stage.flatMap { model.signalFlowGR(for: $0) }))

        case .terminal:
            label
                .foregroundStyle(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.tertiary.opacity(0.18))
                )
        }
    }

    /// Live GR bar drawn at the bottom of stage chips that have telemetry.
    /// 3 px tall, full-chip-width-minus-padding. Fill width is mapped
    /// 0..12 dB GR to 0..100% bar width; colour stages green / yellow /
    /// orange / red as GR climbs. Returns an empty 3 px spacer when GR is
    /// nil (stage has no telemetry) so chip dimensions stay consistent
    /// across the strip.
    @ViewBuilder
    private static func grBar(forGR gr: Float?) -> some View {
        let height: CGFloat = 3
        if let gr, gr > 0.1 {
            let normalized = CGFloat(min(max(gr, 0), 12)) / 12.0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(grColor(forGR: gr))
                        .frame(width: max(2, geo.size.width * normalized))
                }
            }
            .frame(height: height)
            .padding(.horizontal, 4)
            .padding(.bottom, 3)
        } else {
            Color.clear.frame(height: height + 3)
        }
    }

    private static func grColor(forGR gr: Float) -> Color {
        switch gr {
        case ..<3: return Color.green.opacity(0.85)
        case ..<6: return Color.yellow.opacity(0.85)
        case ..<9: return Color.orange.opacity(0.85)
        default:   return Color.red.opacity(0.90)
        }
    }

    private static func chipTooltip(stage: Stage?, gr: Float?) -> String {
        let header = (stage?.label ?? "") + " — \(stage?.detailSubtitle ?? "")"
        if let gr, gr > 0.1 {
            return header + String(format: "\nGR: %.1f dB", gr)
        }
        return header
    }

    private var connector: some View {
        // Decorative line between chips — hide from VoiceOver so the
        // strip reads as "AGC, Multiband, Bass Clipper, …" instead
        // of intermixed connector / chip / connector / chip noise.
        Rectangle()
            .fill(.tertiary.opacity(0.5))
            .frame(width: 6, height: 1)
            .accessibilityHidden(true)
    }
}
