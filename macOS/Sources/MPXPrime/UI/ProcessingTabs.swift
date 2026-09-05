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

/// Dedicated tab hosting the top-level Station Format picker. Moved out
/// of the Processing → Overview grid so the grid stays focused on per-
/// stage status; the format selector gets its own breathing room and
/// can show the full per-profile summary plus the standard tab help
/// box without crowding the dashboard.
struct ProcessingFormatProfileTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Station Format") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Profile")
                        .foregroundStyle(.secondary)
                    Picker("Station Format", selection: model.formatProfileBinding()) {
                        ForEach(MPXPrimeViewModel.formatProfiles) { profile in
                            Text(profile.title).tag(profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Spacer()
                }
                Text(model.currentFormatProfileSummary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProcessingCoreTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Card(title: "Core Processing") {
            Toggle("Bypass Processing", isOn: Binding(
                get: { model.processingBypass },
                set: { _ in model.toggleBypass() }
            ))
            // AM Output is mono by construction (L+R are summed ahead of the
            // chain), so the toggle has nothing to switch there.
            if model.config.operatingMode != .am {
                Toggle("Mono Mode", isOn: model.configBinding(\.monoMode))
                Text(model.processedAudioOutputActive
                    ? "Mono Mode sums L+R to mono. The full DSP chain still runs; the processed output is identical on both channels."
                    : "Mono Mode transmits true mono composite. The full DSP chain (AGC, multiband, clippers, limiters) still runs; only the 19 kHz pilot, 38 kHz stereo subcarrier, and RDS are suppressed at composite assembly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Pre-emphasis: shown where it is THIS control that owns it --
            // under MPX Output. FM Output puts the same picker on Audio I/O
            // next to the coder-ownership question, HD forces it off, and AM
            // has its own NRSC picker (see `ChainFeature.preemphasis`).
            if !model.config.operatingMode.isAudioOutput {
                Picker("Pre-emphasis", selection: model.configBinding(\.preemphasisUS)) {
                    Text("Off").tag(0)
                    Text("50 us").tag(50)
                    Text("75 us").tag(75)
                }
                .pickerStyle(.segmented)
            }
            // Input Gain / MPX Output Level / Line Output moved to the Audio
            // I/O section (0.50): they are rig CALIBRATION, remembered per
            // device -- not part of the sound, so they left the DSP tabs.
            Text("Input gain and output/line level calibration live in the sidebar's Audio I/O section (remembered per device). Loudness belongs to AGC target, Final Drive, and the composite clipper.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DoubleSliderRow(title: "HPF", value: model.configBinding(\.hpfHz), range: 10...180, format: "%.0f Hz",
                tooltip: "High-pass filter cutoff on the L/R input. Removes DC, rumble, and very-low-end energy that would otherwise eat headroom downstream. 30 Hz is the ITU-R BS.450 audio-bandwidth lower bound; raise to 50-80 Hz for ground-loop or rumble-heavy sources.")
            DoubleSliderRow(title: "HF Trim", value: model.configBinding(\.hfTrimDB), range: -12...12, format: "%.1f dB",
                tooltip: "Pre-multiband shelf cut/boost at HF Trim Freq. Negative values tame harsh sources before they hit the multiband; positive values brighten dull material. Apply sparingly — global tonal shaping is the Parametric EQ stage's job.")
            DoubleSliderRow(title: "HF Trim Freq", value: model.configBinding(\.hfTrimHz), range: 1_000...12_000, format: "%.0f Hz",
                tooltip: "Centre frequency for the HF Trim shelf above. 4 kHz default targets vocal presence and cymbal sheen.")
            DoubleSliderRow(title: "Program Lowpass", value: model.configBinding(\.programLowpassHz), range: 8_000...(model.config.processedAudioDigitalDelivery ? 20_000 : 16_000), format: "%.0f Hz",
                tooltip: model.config.operatingMode == .am
                    ? "Audio-bandwidth lowpass. In AM Output the narrower of this and the AM Bandwidth setting (Audio I/O) applies, so leave it wide and set the bandwidth there."
                    : model.processedAudioOutputActive
                    ? "Audio-bandwidth lowpass on the L/R output. ITU-R BS.450 specifies 30 Hz - 15 kHz for FM; 16 kHz default. This band-limits the feed to your external coder. Lower for narrower bandwidth (talk)."
                    : "Audio-bandwidth lowpass applied before stereo encoding. ITU-R BS.450 specifies 30 Hz - 15 kHz for FM stereo; 16 kHz default leaves room for the encoder FIR rolloff into the 17-19 kHz pilot guard. Lower for narrower bandwidth (talk, AM-style), higher only if your modulator FIR can cope.")
        }
        Card(title: "Engine — Filters") {
            Toggle("Encoder Lowpass: linear-phase FIR", isOn: model.configBinding(\.encoderFIREnabled))
                .help("Audio-bandwidth (15 kHz) lowpass. On (default): Kaiser-windowed linear-phase FIR, >80 dB stop-band, ~1.67 ms latency at 192 kHz. Off: 12th-order Butterworth cascade, ~0.2 ms latency, ~40 dB stop-band. Monitor mode always uses Butterworth. Restart-required.")
            Toggle("Multiband Crossovers: linear-phase FIR", isOn: model.configBinding(\.multibandFIREnabled))
                .help("Multiband splitters. On (default): Kaiser-windowed FIR splitters, sum-to-flat at -155 dB, all bands share group delay (no transient smear / inter-band pumping), ~5.3 ms latency at 192 kHz. Off: IIR Linkwitz-Riley 4th-order cascade, low latency but with the IIR-LR4 phase artefacts. Monitor mode always uses LR4. Restart-required.")
            Text(model.processedAudioOutputActive
                ? "Both filters apply to the processed L/R output (the encoder lowpass is the 15 kHz band-limit). Restart engine to apply."
                : "Both toggles affect the transmit (composite) path. Restart engine to apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
      }
    }
}

/// Banner + ghosting for the stages Advanced Dynamics replaces (AGC,
/// Multiband, and the per-band Expander / MB Limiter that run inside the
/// multiband stage). Their tabs stay reachable so the operator can inspect
/// the stored settings, but the controls are dimmed + disabled to make
/// unmistakable that the stage is not in the chain right now.
struct BypassedByAdvancedDynamicsNotice: View {
    @ObservedObject var model: MPXPrimeViewModel
    let stageName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .accessibilityHidden(true)
            Text("\(stageName) is bypassed: Advanced Dynamics is enabled and does this stage's work.")
            Spacer()
            Button("Open Advanced Dynamics") {
                model.selectedStage = .processingAdvancedDynamics
            }
            .buttonStyle(.bordered)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

struct ProcessingAGCTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let bypassed = model.config.advancedDynamicsEnabled
        if bypassed {
            BypassedByAdvancedDynamicsNotice(model: model, stageName: "Wideband AGC")
        }
        Card(title: "Wideband AGC") {
            Toggle("Enable Wideband AGC", isOn: model.configBinding(\.widebandAGCEnabled, runtimeDisposition: .live))
            DoubleSliderRow(title: "Platform Target", value: model.configBinding(\.widebandAGCTargetDB, runtimeDisposition: .live), range: -36 ... -6, format: "%.1f dB",
                tooltip: "Target average level the AGC drives toward. Lower = more gain reduction on loud program; higher = less AGC action. Not the final loudness target.")
            DoubleSliderRow(title: "Attack", value: model.configBinding(\.widebandAGCAttackMS, runtimeDisposition: .live), range: 1...500, format: "%.1f ms",
                tooltip: "How quickly the AGC pulls gain down when the signal exceeds the target. Faster = tighter control but more pumping on transients.")
            DoubleSliderRow(title: "Release", value: model.configBinding(\.widebandAGCReleaseMS, runtimeDisposition: .live), range: 40...5000, format: "%.1f ms",
                tooltip: "How quickly the AGC restores gain when the signal drops below target. Slower = smoother, less noise pumping during quiet passages. Range extended to 5 s for true platform-leveling.")
            DoubleSliderRow(title: "Max Gain", value: model.configBinding(\.widebandAGCMaxGainDB, runtimeDisposition: .live), range: 0...24, format: "%.1f dB",
                tooltip: "Upper limit on how much gain the AGC will add to quiet material. Too high lifts noise and hiss during silences.")
            DoubleSliderRow(title: "Min Gain", value: model.configBinding(\.widebandAGCMinGainDB, runtimeDisposition: .live), range: -24...0, format: "%.1f dB",
                tooltip: "Lower limit on how much the AGC will attenuate loud material before downstream stages take over.")
            Toggle("K-Weighted Detector", isOn: model.configBinding(\.widebandAGCKWeightingEnabled, runtimeDisposition: .live))
                .help("BS.1770-flavoured pre-filter on the detector sidechain (HPF ~38 Hz + high-shelf +4 dB @ ~1.5 kHz). Tracks perceived loudness instead of flat RMS — bass rumble no longer pulls the AGC down unfairly; bright content reads hotter. Audio path is untouched. Default on.")
            Toggle("Program-Dependent Release", isOn: model.configBinding(\.widebandAGCReleaseProgramDependent, runtimeDisposition: .live))
                .help("Slow release up to 3x on busy program (dense voice, music with many transients), speed back to the configured rate on flat program. Reduces pumping without forcing slow defaults. Default on.")
            Toggle("Bass-Desensitised Sidechain", isOn: model.configBinding(\.widebandAGCBassDesensitizeEnabled, runtimeDisposition: .live))
                .help("Low-shelf-cuts the LF band out of the detector sidechain so a kick / heavy bass line can't drive the loudness reading and pump the whole chain (US 4,249,042 + US 3,790,896: also recovers fast from brief reductions). Audio path is untouched. Trade-off: very bass-heavy program reads quieter, so the AGC adds more gain. Default off.")
            Text("Wideband AGC should establish a stable average level platform. It is not the final loudness stage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(bypassed)
        .opacity(bypassed ? 0.5 : 1.0)
    }
}

struct ProcessingPrimeBassTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "PrimeBass") {
            Picker("Preset", selection: Binding(
                get: { self.model.config.primeBassPresetID },
                set: { newValue in
                    self.model.config.primeBassPresetID = newValue
                    self.model.applyPrimeBassPreset(id: newValue)
                }
            )) {
                ForEach(model.primeBassPresetChoices) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            Toggle("Enable PrimeBass", isOn: model.configBinding(\.primeBassEnabled, runtimeDisposition: .live))
            DoubleSliderRow(title: "Amount", value: model.configBinding(\.primeBassAmount, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Overall strength of the low-band enhancement. Higher values emphasize bass; too high introduces pumping and obvious low-frequency coloration.")
            DoubleSliderRow(title: "Frequency", value: model.configBinding(\.primeBassFreqHz, runtimeDisposition: .live), range: 40...180, format: "%.1f Hz",
                tooltip: "Corner frequency of the low-band enhancement. Lower frequencies emphasize sub-bass, higher frequencies emphasize upper bass.")
            DoubleSliderRow(title: "Harmonics", value: model.configBinding(\.primeBassHarmonics, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Adds restrained harmonic overtones so bass remains audible on small speakers that can't reproduce the fundamental.")
            DoubleSliderRow(title: "Drive", value: model.configBinding(\.primeBassDrive, runtimeDisposition: .live), range: 0.2...2.0, format: "%.2f",
                tooltip: "Input level into the nonlinear enhancement stage. Higher drive increases harmonics intensity and perceived density.")
            DoubleSliderRow(title: "Density", value: model.configBinding(\.primeBassDensity, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Smoothing of the enhancement envelope. Higher density reduces attack transients in the low band for a more sustained feel.")
            Toggle("Enable Subharmonics", isOn: model.configBinding(\.primeBassSubharmonicsEnabled, runtimeDisposition: .live))
            DoubleSliderRow(title: "Subharmonics", value: model.configBinding(\.primeBassSubharmonicsAmount, runtimeDisposition: .live), range: 0...1.0, format: "%.2f",
                tooltip: "Synthesizes an octave-below reinforcement for fundamentals. Use sparingly — easily over-emphasizes sub-40 Hz content.")
                .disabled(!model.config.primeBassSubharmonicsEnabled)
        }
        // Mono Bass moved here from the removed Stereo Widener tab (0.50):
        // both are post-multiband bass-domain image controls.
        Card(title: "Mono Bass") {
            Toggle("Mono Bass", isOn: model.configBinding(\.monoBassEnabled, runtimeDisposition: .live))
                .help("Sums L and R to mono below the crossover. Sub-bass side energy eats deviation for no audible width and breaks mono compatibility on FM -- every shipped profile keeps this on.")
            DoubleSliderRow(
                title: "Bass Mono Freq",
                value: model.configBinding(\.monoBassFreqHz, runtimeDisposition: .live),
                range: 70...220,
                format: "%.0f Hz",
                tooltip: "Below this frequency, L and R side energy is summed to mono. 110-140 Hz is the usual range; profiles use 140 Hz (clean/speech/classical) and 115 Hz (loud)."
            )
            .disabled(!model.config.monoBassEnabled)
        }
    }
}

struct ProcessingMultibandTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let bypassed = model.config.advancedDynamicsEnabled
        if bypassed {
            BypassedByAdvancedDynamicsNotice(model: model, stageName: "Multiband")
        }
        Card(title: "Multiband Dynamics") {
            // Preset / intensity / enable / mode — common to all bands.
            Picker("Preset", selection: Binding(
                get: { self.model.config.multibandPresetID },
                set: { newValue in
                    let intensity = MultibandPresetIntensity(rawValue: self.model.config.multibandIntensity) ?? .normal
                    self.model.config.multibandPresetID = newValue
                    self.model.applyMultibandPreset(id: newValue, intensity: intensity)
                }
            )) {
                ForEach(model.multibandPresetChoices) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            Picker("Intensity", selection: Binding(
                get: { MultibandPresetIntensity(rawValue: self.model.config.multibandIntensity) ?? .normal },
                set: { newValue in
                    self.model.config.multibandIntensity = newValue.rawValue
                    self.model.applyMultibandPreset(id: self.model.config.multibandPresetID, intensity: newValue)
                }
            )) {
                ForEach(MultibandPresetIntensity.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Enable Multiband", isOn: model.configBinding(\.multibandEnabled, runtimeDisposition: .live))
            Picker("Mode", selection: model.configBinding(\.multibandMode, runtimeDisposition: .live)) {
                Text("2-band").tag(2)
                Text("3-band").tag(3)
                Text("5-band").tag(5)
            }

            Divider().padding(.vertical, 6)

            // Per-band detail editor — replaces the previous 12-slider
            // Low/Mid/High wall with an active-band picker that
            // re-targets a single set of controls. Visible widget count
            // drops from 12 to 4 (plus the picker). The non-active
            // bands' values aren't lost — switching the picker just
            // re-binds the controls.
            Picker("Active Band", selection: $model.activeMultibandBand) {
                Text("Low").tag(0)
                Text("Mid").tag(1)
                Text("High").tag(2)
            }
            .pickerStyle(.segmented)

            switch model.activeMultibandBand {
            case 0:
                DoubleSliderRow(title: "Threshold", value: model.configBinding(\.multibandLowThresholdDB, runtimeDisposition: .live), range: (-40)...(-6), format: "%.1f dB",
                    tooltip: "Low band compression threshold. Material above this level is attenuated by the ratio.")
                DoubleSliderRow(title: "Ratio", value: model.configBinding(\.multibandLowRatio, runtimeDisposition: .live), range: 1...8, format: "%.2f",
                    tooltip: "Low band compression ratio. 1:1 = no compression; higher ratios flatten dynamics more aggressively.")
                DoubleSliderRow(title: "Attack", value: model.configBinding(\.multibandLowAttackMS, runtimeDisposition: .live), range: 1...120, format: "%.1f ms",
                    tooltip: "Low band attack time. Slow attacks preserve transients; fast attacks tighten the low end.")
                DoubleSliderRow(title: "Release", value: model.configBinding(\.multibandLowReleaseMS, runtimeDisposition: .live), range: 40...1200, format: "%.0f ms",
                    tooltip: "Low band release time. Longer release prevents bass pumping at the cost of average-level recovery speed.")
            case 2:
                DoubleSliderRow(title: "Threshold", value: model.configBinding(\.multibandHighThresholdDB, runtimeDisposition: .live), range: (-40)...(-6), format: "%.1f dB",
                    tooltip: "High band compression threshold. Material above this level is attenuated by the ratio.")
                DoubleSliderRow(title: "Ratio", value: model.configBinding(\.multibandHighRatio, runtimeDisposition: .live), range: 1...8, format: "%.2f",
                    tooltip: "High band compression ratio. Controls sibilance and cymbal energy.")
                DoubleSliderRow(title: "Attack", value: model.configBinding(\.multibandHighAttackMS, runtimeDisposition: .live), range: 1...120, format: "%.1f ms",
                    tooltip: "High band attack time. Fast attack tames sibilance; slow attack preserves air.")
                DoubleSliderRow(title: "Release", value: model.configBinding(\.multibandHighReleaseMS, runtimeDisposition: .live), range: 40...1200, format: "%.0f ms",
                    tooltip: "High band release time. Shorter release brightens; longer release keeps the top smooth.")
            default:
                DoubleSliderRow(title: "Threshold", value: model.configBinding(\.multibandMidThresholdDB, runtimeDisposition: .live), range: (-40)...(-6), format: "%.1f dB",
                    tooltip: "Mid band compression threshold. Material above this level is attenuated by the ratio.")
                DoubleSliderRow(title: "Ratio", value: model.configBinding(\.multibandMidRatio, runtimeDisposition: .live), range: 1...8, format: "%.2f",
                    tooltip: "Mid band compression ratio. Vocals and leads live here — moderate values (2:1 - 4:1) are typical.")
                DoubleSliderRow(title: "Attack", value: model.configBinding(\.multibandMidAttackMS, runtimeDisposition: .live), range: 1...120, format: "%.1f ms",
                    tooltip: "Mid band attack time. Slower values preserve vocal consonants; faster values increase density.")
                DoubleSliderRow(title: "Release", value: model.configBinding(\.multibandMidReleaseMS, runtimeDisposition: .live), range: 40...1200, format: "%.0f ms",
                    tooltip: "Mid band release time. Typical vocal release; shorter = more density, longer = more transparent.")
            }

            Divider().padding(.vertical, 6)

            // Output / common — apply across all bands.
            DoubleSliderRow(title: "Makeup", value: model.configBinding(\.multibandMakeupDB, runtimeDisposition: .live), range: -12...18, format: "%.1f dB",
                tooltip: "Overall gain applied after multiband processing. Set to offset average level loss from compression; not a loudness control.")
            DoubleSliderRow(title: "Knee", value: model.configBinding(\.multibandKneeDB, runtimeDisposition: .live), range: 0...12, format: "%.1f dB",
                tooltip: "Width of the soft transition around each band's threshold. Larger knee = gentler onset of compression.")
            DoubleSliderRow(title: "Link", value: model.configBinding(\.multibandLinkStrength, runtimeDisposition: .live), range: 0...1, format: "%.2f",
                tooltip: "How much gain reduction is shared across bands. 0 = independent (dense), 1 = linked (preserves spectral balance).")
            Toggle("Program-dependent Release", isOn: model.configBinding(\.multibandReleaseProgramDependent, runtimeDisposition: .live))
            Toggle("Transient-aware Attack", isOn: model.configBinding(\.multibandTransientAwareAttackEnabled, runtimeDisposition: .live))
                .help("Uses a peak/RMS hybrid detector and briefly slows attack on percussive fronts so kicks and snares are not over-squashed.")
            Toggle("Inter-band Coupling", isOn: model.configBinding(\.multibandInterBandCouplingEnabled, runtimeDisposition: .live))
                .help("Experimental: low-band gain reduction gently lowers upper-band thresholds so bass-heavy passages stay tonally glued.")

            // Crossovers — operator-rare; collapsed by default. Once
            // the FabFilter-style spectrum-with-drag-handles editor
            // ships, this group disappears entirely.
            DisclosureGroup("Crossovers") {
                DoubleSliderRow(title: "X1 (Low / Low-Mid)", value: model.configBinding(\.multibandX1Hz, runtimeDisposition: .live), range: 30...300, format: "%.0f Hz",
                    tooltip: "Low / Low-Mid crossover frequency. Separates kick/bass from low-mid body.")
                DoubleSliderRow(title: "X2 (Low-Mid / Mid)", value: model.configBinding(\.multibandX2Hz, runtimeDisposition: .live), range: 120...1200, format: "%.0f Hz",
                    tooltip: "Low-Mid / Mid crossover frequency. Separates body from upper-vocal and presence region.")
                DoubleSliderRow(title: "X3 (Mid / High-Mid)", value: model.configBinding(\.multibandX3Hz, runtimeDisposition: .live), range: 600...4000, format: "%.0f Hz",
                    tooltip: "Mid / High-Mid crossover frequency. Separates vocal presence from upper consonants and sibilance.")
                DoubleSliderRow(title: "X4 (High-Mid / High)", value: model.configBinding(\.multibandX4Hz, runtimeDisposition: .live), range: 2500...12000, format: "%.0f Hz",
                    tooltip: "High-Mid / High crossover frequency. Separates sibilance region from air / top-end.")
            }
        }
        .disabled(bypassed)
        .opacity(bypassed ? 0.5 : 1.0)
    }
}

struct ProcessingLimiterTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Audio Limiter") {
            Toggle("Enable Pre-Encode Limiter", isOn: model.configBinding(\.preEncodeAudioLimiterEnabled, runtimeDisposition: .live))
            let disabled = !model.config.preEncodeAudioLimiterEnabled
            DoubleSliderRow(
                title: "Threshold",
                value: model.configBinding(\.preEncodeThreshold, runtimeDisposition: .live),
                range: 0.5...0.999,
                format: "%.3f",
                tooltip: "Linear ceiling for the 4x oversampled true-peak limiter (0.5..0.999). 0.95 = -0.45 dBFS, 0.85 = -1.41 dBFS. Lower = more headroom for downstream stages, more limiting on peaks."
            ).disabled(disabled)
            DoubleSliderRow(
                title: "Release",
                value: model.configBinding(\.preEncodeReleaseMS, runtimeDisposition: .live),
                range: 10...200,
                format: "%.0f ms",
                tooltip: "Release time of the limiter envelope. Faster (lower ms) recovers loudness quicker but may pump; slower is cleaner but holds gain reduction longer."
            ).disabled(disabled)
            DoubleSliderRow(
                title: "Look-ahead",
                value: model.configBinding(\.preEncodeLookaheadMS, runtimeDisposition: .restart),
                range: 0...5,
                format: "%.2f ms",
                tooltip: "Look-ahead time so the limiter's gain ramp engages before the peak reaches the gain stage. 0 ms = feedback-only behavior. 1-2 ms recommended for cleaner HF transient handling on pre-emphasized content (cymbals, sibilance, percussion edges). Adds equivalent latency to the chain. Restart-required.",
                restartRequired: true
            ).disabled(disabled)
            DisclosureGroup("Advanced") {
                Toggle(
                    "Reduce Clipping Distortion",
                    isOn: model.configBinding(\.preEncodeBandlimitedResidualEnabled, runtimeDisposition: .live)
                )
                .help("Shapes the limiter's clipping residual to suppress aliasing and intermodulation, instead of the classic soft ceiling. Experimental; off keeps the current behavior.")
                .disabled(disabled)
                Toggle(isOn: model.configBinding(\.preEncodeLookaheadHFOnly, runtimeDisposition: .restart)) {
                    HStack(spacing: 6) {
                        Text("High-Frequency Transient Look-ahead")
                        RestartBadge()
                    }
                }
                .help("Engages look-ahead only on high-frequency transients (where pre-emphasis concentrates peaks), leaving low-frequency punch untouched. Requires Look-ahead above 0. Restart-required.")
                .disabled(disabled || model.config.preEncodeLookaheadMS <= 0.0)
                DoubleSliderRow(
                    title: "HF Detector Cutoff",
                    value: model.configBinding(\.preEncodeLookaheadHFCutoffHz, runtimeDisposition: .restart),
                    range: 1_000...12_000,
                    format: "%.0f Hz",
                    tooltip: "High-pass cutoff for the HF transient look-ahead detector. 4 kHz default; lower (2-3 kHz) catches more vocal sibilance, higher (6-8 kHz) targets cymbals / hi-hats only. Restart-required.",
                    restartRequired: true
                ).disabled(disabled || !model.config.preEncodeLookaheadHFOnly || model.config.preEncodeLookaheadMS <= 0.0)
            }
            .disabled(disabled)
        }
    }
}

struct ProcessingFinalStageTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Card(title: "Final Stage") {
            Picker("Broadcast Preset", selection: Binding(
                get: { self.model.config.finalStagePresetID },
                set: { newValue in
                    self.model.config.finalStagePresetID = newValue
                    self.model.applyFinalStagePreset(id: newValue)
                }
            )) {
                ForEach(model.finalStagePresetChoices) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            DoubleSliderRow(
                title: "Final Drive",
                value: model.configBinding(\.finalDriveDB, runtimeDisposition: .live),
                range: 0...12,
                format: "%.1f dB",
                tooltip: "Drive into the composite clipper. The primary loudness control. Higher drive = hotter, more clipping; sustained high attenuation means too hot."
            )
            DoubleSliderRow(title: "Composite Deviation", value: model.configBinding(\.mpxDeviationKHz, runtimeDisposition: .live), range: 40...90, format: "%.1f kHz",
                tooltip: "Target peak FM deviation. 75 kHz = ITU-R BS.450 / US FM; 50 kHz = some European reduced-deviation mandates.")
            Text("Broadcast Preset updates AGC platform and final-stage drive together. Final Drive feeds the composite clipper before MPX Output Level calibration. Composite Deviation sets the peak target for the final FM modulator.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Card(title: "Final-MPX Safety Limiter") {
            Toggle("Enable Safety Limiter", isOn: model.configBinding(\.limitMPX))
                .help("Look-ahead peak limiter on the final MPX (audio composite + safety net). Pilot and RDS bypass this stage to keep subcarriers at constant amplitude. Restart-required.")
            let disabled = !model.config.limitMPX
            DisclosureGroup("Advanced") {
                DoubleSliderRow(title: "Threshold", value: model.configBinding(\.limitThreshold), range: 0.5...0.999, format: "%.3f",
                    tooltip: "Linear ceiling for the safety limiter (0.5..0.999). 0.98 = -0.18 dBFS. Below this the limiter doesn't engage; above it the look-ahead reduces gain to keep peaks under the ceiling.").disabled(disabled)
                Toggle("Enable Look-Ahead", isOn: model.configBinding(\.limitLookaheadEnabled))
                    .help("Look-ahead delay so the limiter sees future peaks and applies gain reduction smoothly before the peak arrives. Off makes the limiter purely reactive (more overshoot).")
                    .disabled(disabled)
                DoubleSliderRow(title: "Look-Ahead", value: model.configBinding(\.limitLookaheadMS), range: 0...20, format: "%.1f ms",
                    tooltip: "How far ahead the limiter looks before responding. 5 ms is standard; longer = smoother gain reduction at the cost of latency.").disabled(disabled || !model.config.limitLookaheadEnabled)
            }
            .disabled(disabled)
        }
      }
    }
}

struct ProcessingPhaseRotatorTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Phase Rotator") {
            Toggle("Enable Phase Rotator", isOn: model.configBinding(\.phaseRotationEnabled, runtimeDisposition: .live))
            DoubleSliderRow(
                title: "Frequency",
                value: model.configBinding(\.phaseRotationFreqHz, runtimeDisposition: .live),
                range: 50...500,
                format: "%.1f Hz",
                tooltip: "Center frequency of the 4-pole allpass chain. 200 Hz is typical; lower values target male voice, higher values target female voice."
            )
            .disabled(!model.config.phaseRotationEnabled)
            Text("4-pole allpass chain reduces waveform asymmetry (especially voice) by 3\u{2013}4 dB, giving free headroom to downstream dynamics stages.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ProcessingParametricEQTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Parametric EQ") {
            Toggle("Enable Parametric EQ", isOn: model.configBinding(\.parametricEQEnabled, runtimeDisposition: .live))
            let disabled = !model.config.parametricEQEnabled

            Text("Band 1 \u{2014} Low Shelf").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            DoubleSliderRow(title: "Freq", value: model.configBinding(\.peqB1FreqHz, runtimeDisposition: .live), range: 20...500, format: "%.0f Hz",
                tooltip: "Low shelf corner frequency. Content below this frequency is boost/cut by the shelf gain.").disabled(disabled)
            DoubleSliderRow(title: "Gain", value: model.configBinding(\.peqB1GainDB, runtimeDisposition: .live), range: -12...12, format: "%.1f dB",
                tooltip: "Boost or cut applied below the shelf frequency. Positive adds warmth; negative tightens bass.").disabled(disabled)

            Text("Band 2 \u{2014} Peaking").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            DoubleSliderRow(title: "Freq", value: model.configBinding(\.peqB2FreqHz, runtimeDisposition: .live), range: 100...5000, format: "%.0f Hz",
                tooltip: "Center frequency of this peaking band.").disabled(disabled)
            DoubleSliderRow(title: "Gain", value: model.configBinding(\.peqB2GainDB, runtimeDisposition: .live), range: -12...12, format: "%.1f dB",
                tooltip: "Boost or cut at the center frequency.").disabled(disabled)
            DoubleSliderRow(title: "Q", value: model.configBinding(\.peqB2Q, runtimeDisposition: .live), range: 0.1...10, format: "%.2f",
                tooltip: "Bandwidth of the peaking filter. Low Q = broad / musical; high Q = narrow / surgical.").disabled(disabled)

            Text("Band 3 \u{2014} Peaking").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            DoubleSliderRow(title: "Freq", value: model.configBinding(\.peqB3FreqHz, runtimeDisposition: .live), range: 500...12000, format: "%.0f Hz",
                tooltip: "Center frequency of this peaking band.").disabled(disabled)
            DoubleSliderRow(title: "Gain", value: model.configBinding(\.peqB3GainDB, runtimeDisposition: .live), range: -12...12, format: "%.1f dB",
                tooltip: "Boost or cut at the center frequency.").disabled(disabled)
            DoubleSliderRow(title: "Q", value: model.configBinding(\.peqB3Q, runtimeDisposition: .live), range: 0.1...10, format: "%.2f",
                tooltip: "Bandwidth of the peaking filter. Low Q = broad / musical; high Q = narrow / surgical.").disabled(disabled)

            Text("Band 4 \u{2014} High Shelf").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            DoubleSliderRow(title: "Freq", value: model.configBinding(\.peqB4FreqHz, runtimeDisposition: .live), range: 1000...16000, format: "%.0f Hz",
                tooltip: "High shelf corner frequency. Content above this frequency is boost/cut by the shelf gain.").disabled(disabled)
            DoubleSliderRow(title: "Gain", value: model.configBinding(\.peqB4GainDB, runtimeDisposition: .live), range: -12...12, format: "%.1f dB",
                tooltip: "Boost or cut applied above the shelf frequency. Positive adds air; negative dulls harshness.").disabled(disabled)
        }
    }
}

struct ProcessingMultibandLimiterTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let bypassed = model.config.advancedDynamicsEnabled
        if bypassed {
            BypassedByAdvancedDynamicsNotice(model: model, stageName: "Multiband Limiter")
        }
        Card(title: "Multiband Limiter") {
            Toggle("Enable Multiband Limiter", isOn: model.configBinding(\.multibandLimiterEnabled, runtimeDisposition: .live))
            DoubleSliderRow(
                title: "Threshold",
                value: model.configBinding(\.multibandLimiterThresholdDB, runtimeDisposition: .live),
                range: -20...0,
                format: "%.1f dB",
                tooltip: "Per-band brick-wall limit threshold. Instantaneous peaks above this level are clipped regardless of the compressor ratio."
            )
            .disabled(!model.config.multibandLimiterEnabled)
            DoubleSliderRow(
                title: "Attack",
                value: model.configBinding(\.multibandLimiterAttackMS, runtimeDisposition: .live),
                range: 0.01...10,
                format: "%.2f ms",
                tooltip: "Limiter attack in ms. Sub-ms attack catches fast transients cleanly at the cost of some distortion."
            )
            .disabled(!model.config.multibandLimiterEnabled)
            DoubleSliderRow(
                title: "Release",
                value: model.configBinding(\.multibandLimiterReleaseMS, runtimeDisposition: .live),
                range: 10...500,
                format: "%.1f ms",
                tooltip: "Limiter release in ms. Short release = more density; long release = more transparent."
            )
            .disabled(!model.config.multibandLimiterEnabled)
        }
        .disabled(bypassed)
        .opacity(bypassed ? 0.5 : 1.0)
    }
}

struct ProcessingExpanderTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let bypassed = model.config.advancedDynamicsEnabled
        if bypassed {
            BypassedByAdvancedDynamicsNotice(model: model, stageName: "Downward Expander")
        }
        Card(title: "Downward Expander") {
            Toggle("Enable Expander", isOn: model.configBinding(\.downwardExpanderEnabled, runtimeDisposition: .live))
            let disabled = !model.config.downwardExpanderEnabled
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.expanderThresholdDB, runtimeDisposition: .live), range: -60...(-20), format: "%.1f dB",
                tooltip: "Level below which gain starts to reduce. Set just above the noise floor of the program material.").disabled(disabled)
            DoubleSliderRow(title: "Ratio", value: model.configBinding(\.expanderRatio, runtimeDisposition: .live), range: 1...8, format: "%.1f:1",
                tooltip: "Gain reduction ratio below threshold. Higher ratio = deeper attenuation of quiet material.").disabled(disabled)
            DoubleSliderRow(title: "Attack", value: model.configBinding(\.expanderAttackMS, runtimeDisposition: .live), range: 0.1...100, format: "%.1f ms",
                tooltip: "Time to re-open the gate once program re-exceeds the threshold. Fast attack preserves initial transients.").disabled(disabled)
            DoubleSliderRow(title: "Release", value: model.configBinding(\.expanderReleaseMS, runtimeDisposition: .live), range: 10...2000, format: "%.0f ms",
                tooltip: "Time to close the gate once program falls below the threshold. Longer release avoids chattering on sustained-but-quiet sources.").disabled(disabled)
        }
        .disabled(bypassed)
        .opacity(bypassed ? 0.5 : 1.0)
    }
}

struct ProcessingBassClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Bass Clipper") {
            Toggle("Enable Bass Clipper", isOn: model.configBinding(\.bassClipperEnabled, runtimeDisposition: .live))
            let disabled = !model.config.bassClipperEnabled
            DoubleSliderRow(title: "Crossover", value: model.configBinding(\.bassClipperCrossoverHz, runtimeDisposition: .live), range: 60...300, format: "%.0f Hz",
                tooltip: "Crossover frequency isolating the low band for clipping. Content below this is clipped independently; above passes unmodified.").disabled(disabled)
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.bassClipperThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Clipping threshold for the low band. Lower = more aggressive bass clipping, reducing bass-induced IMD in downstream stages.").disabled(disabled)
            DoubleSliderRow(title: "Drive", value: model.configBinding(\.bassClipperDrive, runtimeDisposition: .live), range: 0.5...3, format: "%.2f",
                tooltip: "Pre-clipping gain applied to the low band. Higher drive increases density but also clipping distortion.").disabled(disabled)
        }
    }
}

struct ProcessingHFClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "HF Limiter") {
            Toggle("Enable HF Limiter", isOn: model.configBinding(\.hfLimiterEnabled, runtimeDisposition: .live))
                .help("Gain-riding HF control: rides only the pre-emphasis boost, so overshooting cymbals / hi-hats briefly lose part of their boost instead of being clipped (Optimod HF-limiter topology, Orban US 4,103,243, expired). Prefer this over the HF Clipper.")
            let limiterDisabled = !model.config.hfLimiterEnabled
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.hfLimiterThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Pre-emphasised L/R peak that starts the HF gain ride. Set at or a little below the Audio Limiter threshold so HF peaks are tamed before the broadband limiter has to act.").disabled(limiterDisabled)
            DoubleSliderRow(title: "Attack", value: model.configBinding(\.hfLimiterAttackMS, runtimeDisposition: .live), range: 0.2...20, format: "%.2f ms",
                tooltip: "How fast the boost is pulled down. 1-3 ms: the Audio Limiter's look-ahead catches what leaks during the attack.").disabled(limiterDisabled)
            DoubleSliderRow(title: "Release", value: model.configBinding(\.hfLimiterReleaseMS, runtimeDisposition: .live), range: 5...500, format: "%.0f ms",
                tooltip: "How fast full pre-emphasis returns. 10-50 ms keeps the HF dip brief; longer values trade sparkle for density.").disabled(limiterDisabled)
            DoubleSliderRow(title: "Max Reduction", value: model.configBinding(\.hfLimiterMaxReductionDB, runtimeDisposition: .live), range: 1...24, format: "%.1f dB",
                tooltip: "Cap on how much of the pre-emphasis boost may be removed. The stage can never cut HF below the flat (un-emphasised) program level.").disabled(limiterDisabled)
        }
        Card(title: "HF Clipper") {
            Toggle("Enable HF Clipper", isOn: model.configBinding(\.hfClipperEnabled, runtimeDisposition: .live))
                .help("Waveshaper on the pre-emphasised high band: it distorts the band it controls. Keep off unless you need maximum HF density; the HF Limiter above is the clean alternative.")
            let disabled = !model.config.hfClipperEnabled
            DoubleSliderRow(title: "Crossover", value: model.configBinding(\.hfClipperCrossoverHz, runtimeDisposition: .live), range: 3000...8000, format: "%.0f Hz",
                tooltip: "Crossover frequency isolating the high band for clipping. Content above this is clipped; below passes unmodified.").disabled(disabled)
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.hfClipperThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Clipping threshold for the high band. Lower = more aggressive HF clipping, offloading HF transients from the broadband limiter.").disabled(disabled)
            DoubleSliderRow(title: "Drive", value: model.configBinding(\.hfClipperDrive, runtimeDisposition: .live), range: 0.5...3, format: "%.2f",
                tooltip: "Pre-clipping gain on the high band. Higher drive increases HF density but also clipping distortion.").disabled(disabled)
        }
    }
}

struct ProcessingAdvancedDynamicsTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Advanced Dynamics") {
            Toggle("Enable Advanced Dynamics", isOn: model.configBinding(\.advancedDynamicsEnabled, runtimeDisposition: .live))
                .help("Experimental single-stage 5-band leveler. While enabled, the AGC and Multiband stages are bypassed and this stage does all the leveling and density work in one place.")
            let disabled = !model.config.advancedDynamicsEnabled
            // Usage tip (the shared help box below already explains WHAT the
            // stage is; this is the how-to-drive-it line).
            Text("While enabled, AGC and Multiband are bypassed. Start with the defaults, then raise Density for a more competitive sound. Band layout follows the Multiband tab's crossovers (toggle this stage off briefly to edit them).")
                .font(.caption)
                .foregroundStyle(.secondary)
            DoubleSliderRow(title: "Target Level", value: model.configBinding(\.advancedDynamicsTargetDB, runtimeDisposition: .live), range: -30...(-6), format: "%.1f dB",
                tooltip: "The level every band is brought toward. Lower = more headroom and gentler sound; higher = denser and louder into the clippers.").disabled(disabled)
            DoubleSliderRow(title: "Density", value: model.configBinding(\.advancedDynamicsDensity, runtimeDisposition: .live), range: 0...1, format: "%.2f",
                tooltip: "How tightly the leveler holds program at target. Higher = tighter hold window and faster leveling (denser, more processed); lower = more dynamics left intact.").disabled(disabled)
            DoubleSliderRow(title: "Speed", value: model.configBinding(\.advancedDynamicsSpeed, runtimeDisposition: .live), range: 0.25...4, format: "%.2fx",
                tooltip: "Overall time-constant scale. The stage adapts its own attack/release to the programme; this scales that adaptive behavior faster or slower.").disabled(disabled)
            DoubleSliderRow(title: "Max Boost", value: model.configBinding(\.advancedDynamicsMaxGainDB, runtimeDisposition: .live), range: 0...24, format: "%.1f dB",
                tooltip: "Maximum lift applied to quiet program per band. The reduction side is fixed at 24 dB, so the total range absorbs large in-song level jumps.").disabled(disabled)
            DoubleSliderRow(title: "Bass Balance", value: model.configBinding(\.advancedDynamicsLowOffsetDB, runtimeDisposition: .live), range: -12...6, format: "%.1f dB",
                tooltip: "Low-band target offset relative to Target Level. The five bands interpolate between the Bass / Mid / Treble anchors, setting the on-air tonal balance.").disabled(disabled)
            DoubleSliderRow(title: "Mid Balance", value: model.configBinding(\.advancedDynamicsMidOffsetDB, runtimeDisposition: .live), range: -12...6, format: "%.1f dB",
                tooltip: "Mid-band target offset relative to Target Level.").disabled(disabled)
            DoubleSliderRow(title: "Treble Balance", value: model.configBinding(\.advancedDynamicsHighOffsetDB, runtimeDisposition: .live), range: -12...6, format: "%.1f dB",
                tooltip: "High-band target offset relative to Target Level. The default -9 dB approximates a natural music spectrum; raise it for a brighter on-air sound.").disabled(disabled)
        }
    }
}

struct ProcessingDCClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Audio Clipper") {
            Toggle("Enable Audio Clipper", isOn: model.configBinding(\.dcClipperEnabled, runtimeDisposition: .live))
            let disabled = !model.config.dcClipperEnabled
            DoubleSliderRow(title: "Ceiling", value: model.configBinding(\.dcClipperCeilingDB, runtimeDisposition: .live), range: -6...0, format: "%.1f dB",
                tooltip: "Clipping ceiling for the distortion-cancelled clipper. Lower ceiling = more audible density but more clipping artifacts.").disabled(disabled)
            DoubleSliderRow(title: "Cancel Freq", value: model.configBinding(\.dcClipperCancelFreqHz, runtimeDisposition: .live), range: 500...4000, format: "%.0f Hz",
                tooltip: "Cutoff of the LF error-extraction filter. Clipping distortion below this frequency is subtracted; above, it is left for masking.").disabled(disabled)
        }
    }
}

struct ProcessingBS412Tab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "BS.412 MPX Power Limiter") {
            Toggle("Enable BS.412", isOn: model.configBinding(\.bs412Enabled, runtimeDisposition: .live))
            let disabled = !model.config.bs412Enabled
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.bs412ThresholdDB, runtimeDisposition: .live), range: -20...0, format: "%.1f dB",
                tooltip: "MPX average-power ceiling per ITU-R BS.412. Required for EU regulatory compliance (DE, AT, CH, SE, CZ, SI, etc).").disabled(disabled)
            DoubleSliderRow(title: "Window", value: model.configBinding(\.bs412WindowSeconds, runtimeDisposition: .live), range: 30...90, format: "%.0f s",
                tooltip: "Rolling averaging window for BS.412 power measurement. 60 s is the regulatory default; values outside ~30-90 s stop being BS.412 and become a generic AGC.").disabled(disabled)
        }
    }
}

struct ProcessingStereoCoderTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Stereo Encoder") {
            // Pilot Level moved here from the Settings window (0.50): it is
            // stereo-encoder structure, not Audio I/O. Range follows ITU-R
            // BS.450-4 / FCC 73.322 (8-10% deviation); 0-12% for headroom,
            // 0 = mute. Composite-only (no pilot in processed audio).
            if !model.processedAudioOutputActive {
                DoubleSliderRow(
                    title: "Pilot Level", value: model.pilotLevelPercentBinding(),
                    range: 0...12, format: "%.1f %%",
                    restartRequired: true)
                .disabled(model.config.monoMode)
            }
            Toggle("SSB Stereo Encoder", isOn: model.configBinding(\.ssbStereoEnabled, runtimeDisposition: .live))
                .help("Leans the 38 kHz stereo subcarrier toward single-sideband, opportunistically keeping whichever sideband currently peaks lower -- reclaims composite headroom before the clipper works. Independent of the Composite Clipper's enable.")
            // Disclaimer caption (the Advanced Dynamics pattern) instead of
            // folding the controls away: the tab exists for this option.
            Text("Experimental. Standard receivers decode SSB stereo fine (measured 81+ dB separation), but phase-imperfect radios may lose a little separation -- A/B on a real receiver and verify with --verify-ssb-stereo before regular use. Stereo encoding itself is always active; this only changes how the subcarrier is assembled.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DoubleSliderRow(title: "SSB Amount", value: model.configBinding(\.ssbStereoAmount, runtimeDisposition: .live), range: 0...1, format: "%.2f",
                tooltip: "How far the stereo subcarrier leans toward single-sideband. 0 = classic double-sideband (no effect), 1 = full SSB (maximum headroom reclaim, maximum receiver sensitivity). Start around 0.5-0.7.")
                .disabled(!model.config.ssbStereoEnabled)
        }
    }
}

struct ProcessingCompositeClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Composite Clipper") {
            Toggle("Enable Composite Clipper", isOn: model.configBinding(\.compositeClipperEnabled, runtimeDisposition: .live))
            let disabled = !model.config.compositeClipperEnabled
            DoubleSliderRow(title: "Threshold", value: model.configBinding(\.compositeClipperThresholdDB, runtimeDisposition: .live), range: -12...0, format: "%.1f dB",
                tooltip: "Onset of composite-level soft clipping on the audio composite (not pilot/RDS). Primary loudness lever when engaged.").disabled(disabled)
            DoubleSliderRow(title: "Ceiling", value: model.configBinding(\.compositeClipperCeilingDB, runtimeDisposition: .live), range: -6...0, format: "%.1f dB",
                tooltip: "Maximum output level after composite clipping. Must stay below 0 dBFS to leave headroom for pilot/RDS injection.").disabled(disabled)
            DoubleSliderRow(title: "Look-ahead", value: model.configBinding(\.compositeClipperLookaheadMS, runtimeDisposition: .live), range: 0...5, format: "%.1f ms",
                tooltip: "Predictive peak shaving. 0.0 disables; 2.0 ms = recommended preset. Sliding-window-max detector + half-cosine attack + 200 Hz smoother bound overshoots tighter than the soft-clip alone, at the cost of N ms added chain latency. Hardcoded internals: 1.5 ms attack, 80 ms release, 200 Hz smoothing.").disabled(disabled)
            LabeledContent("Look-ahead GR") {
                LiveObservationView(telemetry: model.telemetry) { t in
                    Text(String(format: "%5.1f dB", Double(t.compositeClipperLookaheadGainReductionDBValue)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Subcarrier Protection")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle("Protect Audio Highs", isOn: model.configBinding(\.compositeClipperCancelAudio, runtimeDisposition: .live))
                .help("Off (default): full clipping in the audio band for maximum loudness. On: subtracts in-band clip residual to keep highs cleaner, at the cost of some peak control / loudness. Enable when high-frequency harshness is the bigger concern.")
                .disabled(disabled)
            Toggle("Protect Stereo Pilot", isOn: model.configBinding(\.compositeClipperCancelPilot, runtimeDisposition: .live))
                .help("Removes clipping distortion from the 19 kHz pilot region so the receiver decodes stereo cleanly. Leave on except for diagnostic A/B.")
                .disabled(disabled)
            DoubleSliderRow(title: "Protect Stereo Subcarrier", value: model.configBinding(\.compositeClipperStereoGuard, runtimeDisposition: .live), range: 0...1, format: "%.2f",
                tooltip: "How much of the clipper's distortion is kept out of the 22-53 kHz stereo (L-R) subcarrier. 1.00 restores the whole subcarrier: best HF stereo separation, but the clipper then only ever clips the mono share of a peak and the Final-MPX limiter rides the rest. 0.00 clips the full composite the way Orban / Omnia / Stereo Tool do: most loudness, least HF separation on dense program. The shipped value comes from the --verify-stereo-guard sweep.").disabled(disabled)
            Toggle("Protect RDS", isOn: model.configBinding(\.compositeClipperCancelRDS, runtimeDisposition: .live))
                .help("Removes clipping distortion from the 57 kHz RDS region so receivers don't see clipper noise summed with the RDS subcarrier. Leave on except for diagnostic A/B.")
                .disabled(disabled)
            Text("Tip: leave the composite clipper off when loudness isn't critical -- it trades peak control for stereo image and HF cleanliness. If you do enable it, turning on \"Protect Audio Highs\" recovers HF detail at the cost of some loudness.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#endif  // os(macOS)
