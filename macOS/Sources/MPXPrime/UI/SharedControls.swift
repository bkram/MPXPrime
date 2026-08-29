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

/// Compact "restart-required" affordance. Sits next to a control whose
/// change does not apply live (the engine must stop/restart). Matches the
/// pending-restart status chip's icon so the two read as the same concept.
/// Module-visible so the stage inspector can reuse it.
struct RestartBadge: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.caption2)
            .foregroundStyle(BroadcastStyle.tightAmber)
            .help("Restart-required: this setting takes effect only after the engine restarts (use Apply Restart). Changing it while running marks a pending restart in the header.")
            .accessibilityLabel("Restart required")
    }
}

struct DoubleSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var accessibilityLabel: String?
    var tooltip: String?
    var restartRequired: Bool = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Slider(value: $value, in: range)
                    .controlSize(.small)
                    .accessibilityLabel(accessibilityLabel ?? title)
                    // VoiceOver otherwise reads the slider as a bare 0-100%;
                    // surface the real unit-bearing readout instead.
                    .accessibilityValue(Text(String(format: format, value)))
                Text(String(format: format, value))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
            // Attach on the interactive HStack so hovering the slider /
            // readout fires the tooltip reliably (LabeledContent alone does
            // not always forward `.help()` to its content on macOS 15).
            .contentShape(Rectangle())
            .modifier(TooltipIfPresent(text: tooltip))
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if restartRequired { RestartBadge() }
            }
        }
        .contentShape(Rectangle())
        .modifier(TooltipIfPresent(text: tooltip))
    }
}

struct IntStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let format: String
    var tooltip: String?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                    // labelsHidden() drops the visual label; restore an
                    // explicit name + the unit-bearing value for VoiceOver.
                    .accessibilityLabel(title)
                    .accessibilityValue(Text(String(format: format, value)))
                Text(String(format: format, value))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 180, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .modifier(TooltipIfPresent(text: tooltip))
        }
        .contentShape(Rectangle())
        .modifier(TooltipIfPresent(text: tooltip))
    }
}

struct ScopesOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel
    private let scopeTimebasesMS: [Double] = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0]

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                MonitoringWindowHeader(
                    title: kScopesWindowTitle,
                    subtitle: "Stereo input and MPX output waveforms."
                )
                Spacer(minLength: 16)
                LabeledContent("Window") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.scopeTimebaseMS },
                            set: { model.scopeTimebaseMS = $0 }
                        )
                    ) {
                        ForEach(scopeTimebasesMS, id: \.self) { ms in
                            Text("\(Int(ms)) ms").tag(ms)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Toggle(
                    "Auto Gain",
                    isOn: Binding(
                        get: { model.scopeAutoGainEnabled },
                        set: { model.scopeAutoGainEnabled = $0 }
                    )
                )
                .toggleStyle(.switch)
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stereo Input").font(.subheadline).foregroundStyle(.secondary)
                    LiveObservationView(telemetry: model.telemetry) { t in
                        ScopeView(samples: t.inputScopeLeft, secondarySamples: t.inputScopeRight)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("MPX Output").font(.subheadline).foregroundStyle(.secondary)
                    LiveObservationView(telemetry: model.telemetry) { t in
                        ScopeView(samples: t.outputScope)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(
                model.scopeAutoGainEnabled ? "Auto gain enabled." : "Fixed vertical scale: ±1.0"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom)
        }
        .padding()
    }
}

struct SpectrumOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(spacing: 16) {
            MonitoringWindowHeader(
                title: kMPXSpectrumWindowTitle,
                subtitle: "Composite spectrum after stereo encoding."
            )
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                LiveObservationView(telemetry: model.telemetry) { t in
                    MPXSpectrumView(
                        dbBins: t.mpxSpectrumDB,
                        maxHz: t.mpxSpectrumMaxHz,
                        nyquistHz: t.mpxSpectrumNyquistHz,
                        showBandLabels: true
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
        .frame(minWidth: 600, minHeight: 300)
    }
}

struct PreMPXSpectrumOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MonitoringWindowHeader(
                title: kAudioSpectrumWindowTitle,
                subtitle: "Raw stereo input spectrum before processing."
            )

            LiveObservationView(telemetry: model.telemetry) { t in
                StereoPreMPXSpectrumView(
                    leftBins: t.preMPXSpectrumLeftDB,
                    rightBins: t.preMPXSpectrumRightDB,
                    maxHz: t.preMPXSpectrumMaxHz,
                    nyquistHz: t.preMPXSpectrumNyquistHz
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 300)
    }
}

struct StereoPreMPXSpectrumView: View {
    let leftBins: [Float]
    let rightBins: [Float]
    let maxHz: Double
    let nyquistHz: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                AudioBarSpectrumView(
                    dbBins: leftBins,
                    maxHz: maxHz,
                    nyquistHz: nyquistHz
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                AudioBarSpectrumView(
                    dbBins: rightBins,
                    maxHz: maxHz,
                    nyquistHz: nyquistHz
                )
            }

            HStack {
                Spacer()
                Text("Tap: raw stereo input before processing")
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
        }
    }
}

#endif  // os(macOS)
