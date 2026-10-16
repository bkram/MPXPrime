// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI

// The detached monitoring windows: Levels, Audio Spectrum, MPX Spectrum and
// Scopes. One layout for all four: `MonitoringWindowHeader` (title,
// subtitle, controls right-aligned: source first, then options), the
// content, 20 pt padding. Titles and sizes come from `MonitoringWindowKind`
// in AppConstants.swift.

struct LevelsOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MonitoringWindowHeader(
                    title: MonitoringWindowKind.levels.title,
                    subtitle: "What you set levels by: the input, the output and, in MPX Output, the deviation."
                ) {
                    InputSourcePicker()
                }
                LevelsCardView(model: model, title: "", showsSourcePicker: false)
            }
            .padding(PageLayout.padding)
        }
    }
}

struct ScopesOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel
    private let scopeTimebasesMS: [Double] = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0]

    /// The scale caption under the traces.
    static func scaleCaption(autoGain: Bool) -> String {
        autoGain ? "Auto gain on." : "Fixed vertical scale: +/-1.0."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MonitoringWindowHeader(
                title: MonitoringWindowKind.scopes.title,
                subtitle: "Stereo input and \(model.config.operatingMode.title) waveforms."
            ) {
                // "Time Base", not "Window": the horizontal span of a trace.
                Picker(
                    "Time Base",
                    selection: Binding(
                        get: { model.scopeTimebaseMS },
                        set: { model.scopeTimebaseMS = $0 }
                    )
                ) {
                    ForEach(scopeTimebasesMS, id: \.self) { ms in
                        Text("\(Int(ms)) ms").tag(ms)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Toggle(
                    "Auto Gain",
                    isOn: Binding(
                        get: { model.scopeAutoGainEnabled },
                        set: { model.scopeAutoGainEnabled = $0 }
                    )
                )
                .toggleStyle(.switch)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stereo Input").font(.subheadline).foregroundStyle(.secondary)
                    LiveObservationView(telemetry: model.telemetry) { t in
                        ScopeView(samples: t.inputScopeLeft, secondarySamples: t.inputScopeRight)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.config.operatingMode.title).font(.subheadline).foregroundStyle(.secondary)
                    LiveObservationView(telemetry: model.telemetry) { t in
                        ScopeView(samples: t.outputScope)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(Self.scaleCaption(autoGain: model.scopeAutoGainEnabled))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(PageLayout.padding)
    }
}

struct SpectrumOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // No minimum frame of its own: the window's minimum size
        // (`MonitoringWindowKind.mpxSpectrum`) is the one limit.
        VStack(alignment: .leading, spacing: 16) {
            MonitoringWindowHeader(
                title: MonitoringWindowKind.mpxSpectrum.title,
                subtitle: "Composite spectrum after stereo encoding."
            )
            LiveObservationView(telemetry: model.telemetry) { t in
                MPXSpectrumView(
                    dbBins: t.mpxSpectrumDB,
                    maxHz: t.mpxSpectrumMaxHz,
                    nyquistHz: t.mpxSpectrumNyquistHz,
                    showBandLabels: true
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PageLayout.padding)
    }
}

struct PreMPXSpectrumOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel
    /// Pre = the input as it arrives, Post = after processing. Kept per user.
    @AppStorage("audioSpectrum.showsProcessed") private var showsProcessed = true

    private var subtitle: String {
        if !showsProcessed { return "The stereo input as it arrives, before any processing." }
        return model.processedAudioOutputActive
            ? "The processed stereo audio, as it leaves the \(model.config.operatingMode.title)."
            : "The processed stereo audio, as it goes into the stereo encoder."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MonitoringWindowHeader(title: MonitoringWindowKind.audioSpectrum.title, subtitle: subtitle) {
                Picker("Spectrum source", selection: $showsProcessed) {
                    Text("Pre").tag(false)
                    Text("Post").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Pre: the input before processing. Post: the audio after processing.")
            }
            .onAppear { model.audioSpectrumShowsProcessed = showsProcessed }
            .onChange(of: showsProcessed) { _, value in model.audioSpectrumShowsProcessed = value }

            LiveObservationView(telemetry: model.telemetry) { t in
                StereoPreMPXSpectrumView(
                    leftBins: t.preMPXSpectrumLeftDB,
                    rightBins: t.preMPXSpectrumRightDB,
                    maxHz: t.preMPXSpectrumMaxHz,
                    nyquistHz: t.preMPXSpectrumNyquistHz,
                    showsProcessed: showsProcessed
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PageLayout.padding)
    }
}

struct StereoPreMPXSpectrumView: View {
    let leftBins: [Float]
    let rightBins: [Float]
    let maxHz: Double
    let nyquistHz: Double
    /// Which tap the bins come from, so the footer names it (it said "raw
    /// stereo input" with Post selected too).
    let showsProcessed: Bool

    static func tapText(showsProcessed: Bool) -> String {
        showsProcessed
            ? "Tap: processed stereo audio, after the chain"
            : "Tap: stereo input, before processing"
    }

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
                Text(Self.tapText(showsProcessed: showsProcessed))
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
        }
    }
}

#endif  // os(macOS)
