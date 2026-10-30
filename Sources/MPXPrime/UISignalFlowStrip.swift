// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import MPXPrimeUI
import SwiftUI

/// Compact "block-diagram chip strip" header for the Processing section.
/// Renders the audio chain as a horizontal row of clickable chips -- input
/// on the left, output on the right, current stage highlighted. Tapping
/// a chip selects that stage in the sidebar (drives `model.selectedStage`).
///
/// Each chip is a thin pill: stage label + small leading dot when bypassed.
/// Strip is read-only signal flow; it doesn't model branches or returns.
/// Wheatstone-style draggable block-diagram editing is explicitly out of
/// scope (signal flow is fixed in MPXGenerator.swift).
struct SignalFlowStrip: View {
    @ObservedObject var model: MPXPrimeViewModel

    // The stages and their chip names come from the one name table
    // (`Stage.signalChain`, `Stage.chipLabel`); the dashboard's chain pills
    // are the same table written out (`LayoutNameTableTests`). The Expander
    // and the Band Limiter run per band inside the multiband, so the strip
    // shows only the multiband chip for them.

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip(text: "IN", kind: .terminal)
                connector
                // Processed-audio output drops the composite-domain stages
                // (composite clipper, BS.412, final stage) -- they aren't in the
                // chain and their sidebar entries are hidden.
                ForEach(Stage.signalChain.filter { model.isStageVisible($0) }, id: \.self) { stage in
                    chip(
                        text: stage.chipLabel ?? stage.label,
                        kind: stage == model.selectedStage ? .active : .stage,
                        stage: stage
                    )
                    connector
                }
                // The output terminal is OUT in every mode: what follows is
                // an exciter, a stereo coder, a stream encoder or a
                // transmitter, and the Mode chip in the status bar says which.
                chip(text: "OUT", kind: .terminal)
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, PageLayout.padding)
        .padding(.bottom, 4)
    }

    private enum ChipKind {
        case stage
        case active
        case terminal
    }

    @ViewBuilder
    private func chip(text: String, kind: ChipKind, stage: Stage? = nil) -> some View {
        // A stage with an enable toggle that is currently off renders dimmed
        // so the strip shows what's actually in the signal path. Stages with
        // no toggle (Core, Final) report nil and stay full-strength.
        let bypassed = stage.map { model.isStageEnabled($0) == false } ?? false
        let help = (stage?.label ?? "") + ": \(stage?.detailSubtitle ?? "")"
            + (bypassed ? " (bypassed)" : "")
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
                            .fill(BroadcastStyle.stagePillFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .opacity(bypassed ? 0.4 : 1.0)
            .help(help)
            .accessibilityValue(bypassed ? "bypassed" : "active")

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
            .opacity(bypassed ? 0.5 : 1.0)
            .help(help)
            .accessibilityValue(bypassed ? "bypassed, selected" : "selected")

        case .terminal:
            label
                .foregroundStyle(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(BroadcastStyle.terminalPillFill)
                )
        }
    }

    private var connector: some View {
        // Decorative line between chips -- hide from VoiceOver so the
        // strip reads as "AGC, Multiband, Bass Clipper, ..." instead
        // of intermixed connector / chip / connector / chip noise.
        Rectangle()
            .fill(BroadcastStyle.connectorFill)
            .frame(width: 6, height: 1)
            .accessibilityHidden(true)
    }
}

#endif  // os(macOS)
