// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import SwiftUI

/// Stage-aware right-pane Inspector content. Modeled on Pages / Keynote /
/// Logic Pro inspectors — surfaces the advanced parameters and contextual
/// metering for the currently-selected sidebar stage. Default state for
/// stages without dedicated inspector content is a brief tip + the stage
/// description, so the inspector never feels empty.
///
/// Phase 3 only wires the infrastructure + composite-clipper cancellation
/// toggles (currently an "advanced operator-only" group with no UI prior
/// to this commit). Phase 4 wires the Multiband per-band advanced params.
struct StageInspector: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inspector")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(model.selectedStage.label)
                .font(.headline)
            Text(model.selectedStage.detailSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedStage {
        case .processingCompositeClipper:
            CompositeClipperInspector(model: model)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("Advanced parameters and contextual metering for this stage will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Composite-clipper inspector content: the four cancellation flags
/// that were previously config-only (no UI). Operator-targeted —
/// unchecking any of these has receiver-visible audible / RDS-quality
/// consequences. The clipper enable / threshold / ceiling stay on the
/// main editor; this inspector is for the per-band cancellation
/// toggles that 95% of users never need to touch.
private struct CompositeClipperInspector: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Per-band IM cancellation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Toggle(
                "Protect Audio Highs",
                isOn: model.configBinding(\.compositeClipperCancelAudio, runtimeDisposition: .live)
            )
            .help("Removes the clipper's distortion in the 0-15 kHz audio region. Costs loudness; off by default for full clipper drive. Inspired by Orban US 5,168,526.")

            Toggle(
                "Protect Stereo Pilot",
                isOn: model.configBinding(\.compositeClipperCancelPilot, runtimeDisposition: .live)
            )
            .help("Removes clipper distortion under the cleanly-injected 19 kHz pilot (17-21 kHz). Required for reliable stereo decoding — leave on.")

            DoubleSliderRow(
                title: "Protect Stereo Subcarrier",
                value: model.configBinding(\.compositeClipperStereoGuard, runtimeDisposition: .live),
                range: 0...1, format: "%.2f",
                tooltip: "Share of the clipper's distortion kept out of the 22-53 kHz stereo (L-R) subcarrier. 1.00 = subcarrier untouched (best HF separation, the Final-MPX limiter rides the overshoot); 0.00 = full composite clipping (industry practice, most loudness)."
            )

            Toggle(
                "Protect RDS",
                isOn: model.configBinding(\.compositeClipperCancelRDS, runtimeDisposition: .live)
            )
            .help("Removes clipper energy under the 57 kHz RDS subcarrier (55-59 kHz). Leave on or RDS reception degrades as the clipper drives.")

            Text("These flags subtract bandpass-isolated clipper residual back into the protected guard bands so the receiver doesn't see clipper noise vector-summed with the cleanly-injected pilot, stereo, and RDS subcarriers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Divider()

            HStack(spacing: 6) {
                Text("Oversampling factor")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                RestartBadge()
            }

            Picker(
                "",
                selection: model.configBinding(\.compositeClipperOversampling, runtimeDisposition: .restart)
            ) {
                Text("8x").tag(8)
                Text("16x").tag(16)
                Text("32x").tag(32)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Composite clipper oversampling factor. Restart required.")

            Text("16x is the industry-standard default (Optimod 8X00, Omnia.11, Stereotool). 8x halves this stage's CPU with a small alias-suppression tradeoff — pick it on older hardware. 32x doubles CPU for a further small alias-suppression improvement — pick it only with hardware headroom. See `mpx_clipper_oversampling` in the sample INI for the full rationale.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

#endif  // os(macOS)
