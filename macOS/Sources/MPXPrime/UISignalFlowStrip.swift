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

    /// Stages shown in the strip, in chain order.
    private static let chainStages: [Stage] = [
        .processingCore,
        .processingAGC,
        .processingParametricEQ,
        .processingPrimeBass,
        .processingWidener,
        .processingMultiband,
        .processingMBLimiter,
        .processingExpander,
        .processingBassClipper,
        .processingDCClipper,
        .processingLimiter,
        .processingBS412,
        .processingCompositeClipper,
        .processingFinalStage,
    ]

    /// Compact label for each stage in the chip — chain order is
    /// dense; full-length labels won't fit at typical window widths.
    private static let chipLabels: [Stage: String] = [
        .processingCore: "Core",
        .processingAGC: "AGC",
        .processingParametricEQ: "PEQ",
        .processingPrimeBass: "PrimeBass",
        .processingWidener: "Width",
        .processingMultiband: "MB",
        .processingMBLimiter: "MB-Lim",
        .processingExpander: "Exp",
        .processingBassClipper: "BassClip",
        .processingDCClipper: "DC-Clip",
        .processingLimiter: "Lim",
        .processingBS412: "BS.412",
        .processingCompositeClipper: "MPX-Clip",
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
            .padding(.vertical, 4)

        switch kind {
        case .stage:
            Button {
                if let stage { model.selectedStage = stage }
            } label: {
                label
                    .foregroundStyle(.secondary)
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
            .help((stage?.label ?? "") + " — \(stage?.detailSubtitle ?? "")")

        case .active:
            Button {
                if let stage { model.selectedStage = stage }
            } label: {
                label
                    .foregroundStyle(.primary)
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
            .help((stage?.label ?? "") + " — \(stage?.detailSubtitle ?? "")")

        case .terminal:
            label
                .foregroundStyle(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.tertiary.opacity(0.18))
                )
        }
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
