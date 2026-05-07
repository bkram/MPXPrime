import AppKit
import SwiftUI

/// Inline rail of compact visualizer tiles (Levels / Scope / MPX
/// Spectrum). Each tile renders the same view content the dedicated
/// auxiliary window uses, plus a small pop-out button that re-opens
/// that window via the existing AppDelegate @objc actions. Adopts the
/// Omnia.9 NfRemote "Display Windows" pattern: visualizations are
/// inline by default, separate windows on demand for multi-monitor
/// workflows.
struct VisualizerRail: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Visualizers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            HStack(spacing: 12) {
                VisualizerTile(
                    title: "Levels",
                    popoutSelector: NSSelectorFromString("showLevelsWindow")
                ) {
                    LevelsCardView(model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VisualizerTile(
                    title: "Scope",
                    popoutSelector: NSSelectorFromString("showScopesWindow")
                ) {
                    InlineScopeContent(model: model)
                }
                VisualizerTile(
                    title: "MPX Spectrum",
                    popoutSelector: NSSelectorFromString("showSpectrumWindow")
                ) {
                    InlineSpectrumContent(model: model)
                }
            }
        }
    }
}

/// One visualizer tile — header with title + pop-out button, then
/// supplied content. Pop-out fires `popoutSelector` against the
/// current responder chain (the AppDelegate handles the existing
/// `showLevelsWindow` / `showScopesWindow` / `showSpectrumWindow`
/// @objc methods).
private struct VisualizerTile<Content: View>: View {
    let title: String
    let popoutSelector: Selector
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSApp.sendAction(popoutSelector, to: nil, from: nil)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help("Open \(title) in a new window")
            }
            content
                .frame(maxWidth: .infinity, maxHeight: 140)
                .clipped()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BroadcastStyle.panelSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(BroadcastStyle.panelBorder, lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity)
    }
}

private struct InlineScopeContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        HStack(spacing: 8) {
            ScopeView(samples: model.inputScopeLeft, secondarySamples: model.inputScopeRight)
            ScopeView(samples: model.outputScope)
        }
    }
}

private struct InlineSpectrumContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        MPXSpectrumView(
            dbBins: model.mpxSpectrumDB,
            maxHz: model.mpxSpectrumMaxHz,
            nyquistHz: model.mpxSpectrumNyquistHz
        )
    }
}
