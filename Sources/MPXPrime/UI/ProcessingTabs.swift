// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI

// The Sound stage pages. Each page is only its cards: `StageContentView`
// draws the title, subtitle, reset button and help box from the `Stage` name
// table. Conventions (docs/ui-style-guide.md):
//   - a page with one card draws it without a title; a card title never
//     repeats the page title
//   - every config value is bound through `model.setting(...)` (or the dB /
//     percent variants), so the restart badge follows the disposition the
//     engine actually has (`LayoutRestartBadgeTests`)
//   - levels and thresholds in dB, 0-1 amounts as percent
//   - set-once controls fold into `AdvancedGroup` (`AdvancedControls.keys`)
//   - mechanism and standards in tooltips, not labels

struct ProcessingCoreTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card {
            // AM Output is mono by construction (L+R are summed ahead of the
            // chain), so the toggle has nothing to switch there.
            if ChainFeature.stereoProgram.applies(in: model.config.operatingMode) {
                SettingToggle(
                    "Mono Mode", setting: model.setting(\.monoMode, .restart),
                    tooltip: model.processedAudioOutputActive
                        ? "Sums left and right to mono. The full chain still runs; the processed output is identical on both channels."
                        : "Transmits a true mono composite. The full chain still runs; only the 19 kHz pilot, the 38 kHz stereo subcarrier and RDS are left out of the composite.")
            }
            DoubleSliderRow(
                title: "High-Pass Filter", setting: model.setting(\.hpfHz, .restart),
                range: 10...180, format: "%.0f Hz",
                tooltip: "Cut-off of the high-pass filter on the input. Removes DC, rumble and very low frequencies that would waste headroom downstream. 30 Hz is the ITU-R BS.450 lower audio limit; raise it to 50-80 Hz for sources with hum or rumble.",
                defaultValue: model.resetValue(\.hpfHz))
            AdvancedGroup {
                DoubleSliderRow(
                    title: "HF Trim", setting: model.setting(\.hfTrimDB, .restart),
                    range: -12...12, format: "%.1f dB",
                    tooltip: "High-frequency shelf ahead of the multiband. Negative values tame harsh sources; positive values brighten dull ones. Use it sparingly: station-wide tone shaping is the Parametric EQ's job.",
                    defaultValue: model.resetValue(\.hfTrimDB))
                DoubleSliderRow(
                    title: "HF Trim Frequency", setting: model.setting(\.hfTrimHz, .restart),
                    range: 1_000...12_000, format: "%.0f Hz",
                    tooltip: "Centre frequency of the HF Trim shelf. The 4 kHz default targets vocal presence and cymbal sheen.",
                    defaultValue: model.resetValue(\.hfTrimHz))
                DoubleSliderRow(
                    title: "Programme Lowpass", setting: model.setting(\.programLowpassHz, .restart),
                    range: 8_000...(model.config.processedAudioDigitalDelivery ? 20_000 : 16_000), format: "%.0f Hz",
                    tooltip: lowpassTooltip,
                    defaultValue: model.resetValue(\.programLowpassHz))
            }
        }
    }

    private var lowpassTooltip: String {
        if model.config.operatingMode == .am {
            return "Audio bandwidth. In AM Output the narrower of this and the AM Bandwidth on Audio I/O applies, so leave this wide and set the bandwidth there."
        }
        if model.processedAudioOutputActive {
            return "Audio bandwidth of the processed output. ITU-R BS.450 specifies 30 Hz to 15 kHz for FM; the 16 kHz default band-limits the feed to your external coder. Lower it for talk."
        }
        return "Audio bandwidth ahead of the stereo encoder. ITU-R BS.450 specifies 30 Hz to 15 kHz for FM stereo; the 16 kHz default leaves room for the encoder filter's roll-off before the 19 kHz pilot. Lower it for talk."
    }
}

struct ProcessingAGCTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card {
            SettingToggle("Enable AGC", setting: model.setting(\.widebandAGCEnabled, .live))
                .toggleStyle(.switch)
            DoubleSliderRow(
                title: "Target Level", setting: model.setting(\.widebandAGCTargetDB, .live),
                range: -36 ... -6, format: "%.1f dB",
                tooltip: "The average level the AGC rides towards. Lower means more gain reduction on loud programme; higher means less AGC action. This is the level platform for the multiband, not the final loudness.",
                defaultValue: model.resetValue(\.widebandAGCTargetDB))
            AdvancedGroup {
                DoubleSliderRow(
                    title: "Attack", setting: model.setting(\.widebandAGCAttackMS, .live),
                    range: 1...500, format: "%.1f ms",
                    tooltip: "How quickly the AGC pulls the gain down when the programme rises above the target. Faster means tighter control but more pumping on transients.",
                    defaultValue: model.resetValue(\.widebandAGCAttackMS))
                DoubleSliderRow(
                    title: "Release", setting: model.setting(\.widebandAGCReleaseMS, .live),
                    range: 40...5000, format: "%.0f ms",
                    tooltip: "How quickly the AGC restores the gain when the programme falls below the target. Slower is smoother, with less noise pumping in quiet passages.",
                    defaultValue: model.resetValue(\.widebandAGCReleaseMS))
                DoubleSliderRow(
                    title: "Max Gain", setting: model.setting(\.widebandAGCMaxGainDB, .live),
                    range: 0...24, format: "%.1f dB",
                    tooltip: "The most gain the AGC adds to quiet material. Too high lifts noise and hiss in silences.",
                    defaultValue: model.resetValue(\.widebandAGCMaxGainDB))
                DoubleSliderRow(
                    title: "Min Gain", setting: model.setting(\.widebandAGCMinGainDB, .live),
                    range: -24...0, format: "%.1f dB",
                    tooltip: "The most the AGC attenuates loud material before the stages downstream take over.",
                    defaultValue: model.resetValue(\.widebandAGCMinGainDB))
                SettingToggle(
                    "K-Weighted Detector", setting: model.setting(\.widebandAGCKWeightingEnabled, .live),
                    tooltip: "Weights the detector like ITU-R BS.1770 (high-pass near 38 Hz, +4 dB shelf above 1.5 kHz), so it follows perceived loudness rather than flat RMS. The audio itself is not filtered. On by default.")
                SettingToggle(
                    "Programme-Dependent Release", setting: model.setting(\.widebandAGCReleaseProgramDependent, .live),
                    tooltip: "Slows the release up to three times on dense programme and returns to the set rate on sparse programme. Less pumping without slow defaults. On by default.")
                SettingToggle(
                    "Ignore Bass in Detector", setting: model.setting(\.widebandAGCBassDesensitizeEnabled, .live),
                    tooltip: "Cuts the low frequencies out of the detector so a kick drum or heavy bass line cannot drive the level reading and pump the whole chain (after US 4,249,042 and US 3,790,896). The audio itself is not filtered. Very bass-heavy programme then reads quieter, so the AGC adds more gain. Off by default.")
            }
        }
    }
}

struct ProcessingPrimeBassTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PageLayout.cardSpacing) {
            Card(title: "Enhancement") {
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
                SettingToggle("Enable PrimeBass", setting: model.setting(\.primeBassEnabled, .live))
                    .toggleStyle(.switch)
                DoubleSliderRow(
                    title: "Amount", setting: model.percentSetting(\.primeBassAmount, .live),
                    range: 0...50, format: "%.0f%%",
                    tooltip: "Strength of the bass enhancement. Too much brings pumping and an obvious low-frequency colour.",
                    defaultValue: model.resetValue(\.primeBassAmount) * 100)
                DoubleSliderRow(
                    title: "Frequency", setting: model.setting(\.primeBassFreqHz, .live),
                    range: 40...120, format: "%.0f Hz",
                    tooltip: "Corner frequency of the enhancement. Lower emphasises sub-bass; higher emphasises upper bass.",
                    defaultValue: model.resetValue(\.primeBassFreqHz))
                AdvancedGroup {
                    DoubleSliderRow(
                        title: "Harmonics", setting: model.percentSetting(\.primeBassHarmonics, .live),
                        range: 0...50, format: "%.0f%%",
                        tooltip: "Adds restrained overtones so the bass stays audible on small speakers that cannot reproduce the fundamental (harmonic synthesis after the MaxxBass principle).",
                        defaultValue: model.resetValue(\.primeBassHarmonics) * 100)
                    DoubleSliderRow(
                        title: "Drive", setting: model.percentSetting(\.primeBassDrive, .live),
                        range: 20...150, format: "%.0f%%",
                        tooltip: "Level into the harmonic generator. More drive gives stronger harmonics and a denser bass.",
                        defaultValue: model.resetValue(\.primeBassDrive) * 100)
                    DoubleSliderRow(
                        title: "Density", setting: model.percentSetting(\.primeBassDensity, .live),
                        range: 0...100, format: "%.0f%%",
                        tooltip: "Smooths the enhancement envelope. Higher density softens low-frequency attacks for a more sustained feel.",
                        defaultValue: model.resetValue(\.primeBassDensity) * 100)
                    SettingToggle("Enable Subharmonics", setting: model.setting(\.primeBassSubharmonicsEnabled, .live))
                    DoubleSliderRow(
                        title: "Subharmonic Amount", setting: model.percentSetting(\.primeBassSubharmonicsAmount, .live),
                        range: 0...40, format: "%.0f%%",
                        tooltip: "Adds reinforcement an octave below the fundamental. Use sparingly: it easily overdoes content below 40 Hz.",
                        defaultValue: model.resetValue(\.primeBassSubharmonicsAmount) * 100)
                    .disabled(!model.config.primeBassSubharmonicsEnabled)
                }
            }
            // Mono Bass sits here because both are bass-domain controls.
            if ChainFeature.stereoProgram.applies(in: model.config.operatingMode) {
                Card(title: "Mono Bass") {
                    SettingToggle(
                        "Enable Mono Bass", setting: model.setting(\.monoBassEnabled, .live),
                        tooltip: "Sums left and right to mono below the chosen frequency. Sub-bass side energy wastes deviation for no audible width and upsets mono compatibility on FM; every shipped profile keeps this on.")
                    DoubleSliderRow(
                        title: "Mono Below", setting: model.setting(\.monoBassFreqHz, .live),
                        range: 70...220, format: "%.0f Hz",
                        tooltip: "Below this frequency left and right are summed to mono. 110-140 Hz is usual; the profiles use 140 Hz (clean, speech, classical) and 115 Hz (loud).",
                        defaultValue: model.resetValue(\.monoBassFreqHz))
                    .disabled(!model.config.monoBassEnabled)
                }
            }
        }
    }
}

struct ProcessingMultibandTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    /// The band counts the engine runs (AppConfig folds anything else onto
    /// 3). The dashboard offers the same two (`LayoutSoundTests`).
    static let bandChoices = [3, 5]

    var body: some View {
        Card {
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
            .pickerStyle(.menu)
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
            SettingToggle("Enable Multiband", setting: model.setting(\.multibandEnabled, .live))
                .toggleStyle(.switch)
            SettingPicker("Bands", setting: model.setting(\.multibandMode, .live)) {
                ForEach(Self.bandChoices, id: \.self) { count in
                    Text("\(count) Bands").tag(count)
                }
            }
            .pickerStyle(.segmented)

            Divider().padding(.vertical, 6)

            // One set of per-band controls, re-targeted by the Active Band
            // picker. The engine stores three sets (low, mid, high); with 5
            // bands, bands 2 and 4 take the values halfway between their
            // neighbours (MPXGenerator's five-band set-up), so the picker
            // names the band each set drives.
            Picker("Active Band", selection: $model.activeMultibandBand) {
                ForEach(Array(activeBandTitles.enumerated()), id: \.offset) { index, title in
                    Text(title).tag(index)
                }
            }
            .pickerStyle(.segmented)
            if model.config.multibandMode == 5 {
                Text("With 5 bands, bands 2 and 4 take the values halfway between their neighbours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch model.activeMultibandBand {
            case 0:
                bandRows(threshold: \.multibandLowThresholdDB, ratio: \.multibandLowRatio,
                         thresholdTip: "Low band compression threshold. Programme above it is reduced by the ratio.",
                         ratioTip: "Low band compression ratio. 1:1 is no compression; higher ratios flatten the dynamics more.")
            case 2:
                bandRows(threshold: \.multibandHighThresholdDB, ratio: \.multibandHighRatio,
                         thresholdTip: "High band compression threshold. Programme above it is reduced by the ratio.",
                         ratioTip: "High band compression ratio. Controls sibilance and cymbal energy.")
            default:
                bandRows(threshold: \.multibandMidThresholdDB, ratio: \.multibandMidRatio,
                         thresholdTip: "Mid band compression threshold. Programme above it is reduced by the ratio.",
                         ratioTip: "Mid band compression ratio. Vocals live here; 2:1 to 4:1 is typical.")
            }

            Divider().padding(.vertical, 6)

            DoubleSliderRow(
                title: "Makeup", setting: model.setting(\.multibandMakeupDB, .live),
                range: -12...18, format: "%.1f dB",
                tooltip: "Gain after the multiband, to make up the average level the compression takes away. Not a loudness control.",
                defaultValue: model.resetValue(\.multibandMakeupDB))

            AdvancedGroup {
                switch model.activeMultibandBand {
                case 0:
                    timeRows(attack: \.multibandLowAttackMS, release: \.multibandLowReleaseMS,
                             attackTip: "Low band attack. Slow attacks keep transients; fast attacks tighten the low end.",
                             releaseTip: "Low band release. Longer release avoids bass pumping at the cost of slower level recovery.")
                case 2:
                    timeRows(attack: \.multibandHighAttackMS, release: \.multibandHighReleaseMS,
                             attackTip: "High band attack. Fast attack tames sibilance; slow attack keeps air.",
                             releaseTip: "High band release. Shorter release brightens; longer keeps the top smooth.")
                default:
                    timeRows(attack: \.multibandMidAttackMS, release: \.multibandMidReleaseMS,
                             attackTip: "Mid band attack. Slower values keep vocal consonants; faster values increase density.",
                             releaseTip: "Mid band release. Shorter means more density; longer is more transparent.")
                }
                DoubleSliderRow(
                    title: "Knee", setting: model.setting(\.multibandKneeDB, .live),
                    range: 0...12, format: "%.1f dB",
                    tooltip: "Width of the soft transition around each band's threshold. A wider knee starts compressing more gently.",
                    defaultValue: model.resetValue(\.multibandKneeDB))
                if ChainFeature.stereoProgram.applies(in: model.config.operatingMode) {
                    DoubleSliderRow(
                        title: "Stereo Link", setting: model.percentSetting(\.multibandLinkStrength, .live),
                        range: 0...100, format: "%.0f%%",
                        tooltip: "How much the left and right channels share one gain reduction in each band. 0 = each channel compressed on its own, 1 = fully linked (stereo image held exactly).",
                        defaultValue: model.resetValue(\.multibandLinkStrength) * 100)
                }
                SettingToggle("Programme-Dependent Release", setting: model.setting(\.multibandReleaseProgramDependent, .live))
                SettingToggle(
                    "Transient-Aware Attack", setting: model.setting(\.multibandTransientAwareAttackEnabled, .live),
                    tooltip: "Uses a peak/RMS detector and briefly slows the attack on percussive fronts, so kicks and snares are not over-squashed.")
                SettingToggle(
                    "Inter-Band Coupling", setting: model.setting(\.multibandInterBandCouplingEnabled, .live),
                    tooltip: "Low-band gain reduction gently lowers the upper bands' thresholds, so bass-heavy passages stay tonally glued.")
            }

            AdvancedGroup("Crossovers") {
                crossoverRow("X1 (Low / Low-Mid)", \.multibandX1Hz, 30...300,
                             "Low / low-mid crossover. Separates kick and bass from the low-mid body.")
                crossoverRow("X2 (Low-Mid / Mid)", \.multibandX2Hz, 120...1200,
                             "Low-mid / mid crossover. Separates the body from the upper vocal and presence region.")
                crossoverRow("X3 (Mid / High-Mid)", \.multibandX3Hz, 600...4000,
                             "Mid / high-mid crossover. Separates vocal presence from upper consonants and sibilance.")
                crossoverRow("X4 (High-Mid / High)", \.multibandX4Hz, 2500...12000,
                             "High-mid / high crossover. Separates the sibilance region from the air.")
            }
        }
    }

    private var activeBandTitles: [String] {
        model.config.multibandMode == 5
            ? ["Low (Band 1)", "Mid (Band 3)", "High (Band 5)"]
            : ["Low", "Mid", "High"]
    }

    @ViewBuilder
    private func bandRows(threshold: WritableKeyPath<AppConfig, Double>, ratio: WritableKeyPath<AppConfig, Double>,
                          thresholdTip: String, ratioTip: String) -> some View {
        DoubleSliderRow(
            title: "Threshold", setting: model.setting(threshold, .live),
            range: (-40)...(-6), format: "%.1f dB", tooltip: thresholdTip,
            defaultValue: model.resetValue(threshold))
        DoubleSliderRow(
            title: "Ratio", setting: model.setting(ratio, .live),
            range: 1...8, format: "%.1f:1", tooltip: ratioTip,
            defaultValue: model.resetValue(ratio))
    }

    @ViewBuilder
    private func timeRows(attack: WritableKeyPath<AppConfig, Double>, release: WritableKeyPath<AppConfig, Double>,
                          attackTip: String, releaseTip: String) -> some View {
        DoubleSliderRow(
            title: "Attack", setting: model.setting(attack, .live),
            range: 1...120, format: "%.1f ms", tooltip: attackTip,
            defaultValue: model.resetValue(attack))
        DoubleSliderRow(
            title: "Release", setting: model.setting(release, .live),
            range: 40...1200, format: "%.0f ms", tooltip: releaseTip,
            defaultValue: model.resetValue(release))
        Text("Attack and Release follow the Active Band.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func crossoverRow(_ title: String, _ keyPath: WritableKeyPath<AppConfig, Double>,
                              _ range: ClosedRange<Double>, _ tip: String) -> some View {
        DoubleSliderRow(
            title: title, setting: model.setting(keyPath, .live),
            range: range, format: "%.0f Hz", tooltip: tip,
            defaultValue: model.resetValue(keyPath))
    }
}

struct ProcessingLimiterTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let disabled = !model.config.preEncodeAudioLimiterEnabled
        Card {
            SettingToggle("Enable Audio Limiter", setting: model.setting(\.preEncodeAudioLimiterEnabled, .live))
                .toggleStyle(.switch)
            DoubleSliderRow(
                title: "Threshold", setting: model.dbSetting(\.preEncodeThreshold, .live),
                range: -6.0 ... -0.01, format: "%.1f dBFS",
                tooltip: "Ceiling of the oversampled true-peak limiter. Lower leaves more headroom for the stages that follow and limits more peaks.",
                defaultValue: MPXPrimeViewModel.dBFS(fromLinear: model.resetValue(\.preEncodeThreshold))
            ).disabled(disabled)
            DoubleSliderRow(
                title: "Release", setting: model.setting(\.preEncodeReleaseMS, .live),
                range: 10...200, format: "%.0f ms",
                tooltip: "Release of the limiter. Faster recovers loudness sooner but may pump; slower is cleaner but holds the gain reduction longer.",
                defaultValue: model.resetValue(\.preEncodeReleaseMS)
            ).disabled(disabled)
            DoubleSliderRow(
                title: "Look-Ahead", setting: model.setting(\.preEncodeLookaheadMS, .restart),
                range: 0...5, format: "%.2f ms",
                tooltip: "Lets the gain start falling before the peak arrives. 0 ms is feedback only; 1-2 ms handles high-frequency transients on pre-emphasised programme (cymbals, sibilance) more cleanly. Adds the same latency to the chain.",
                defaultValue: model.resetValue(\.preEncodeLookaheadMS)
            ).disabled(disabled)
            AdvancedGroup {
                SettingToggle(
                    "Reduce Clipping Distortion", setting: model.setting(\.preEncodeBandlimitedResidualEnabled, .live),
                    tooltip: "Shapes the limiter's clipping residual to suppress aliasing and intermodulation, instead of the classic soft ceiling. Off keeps the classic behaviour.")
                SettingToggle(
                    "Look-Ahead on HF Transients Only", setting: model.setting(\.preEncodeLookaheadHFOnly, .restart),
                    tooltip: "Uses the look-ahead only on high-frequency transients, where pre-emphasis concentrates the peaks, and leaves low-frequency punch untouched. Needs a Look-Ahead above 0.")
                .disabled(model.config.preEncodeLookaheadMS <= 0.0)
                DoubleSliderRow(
                    title: "HF Detector Cutoff", setting: model.setting(\.preEncodeLookaheadHFCutoffHz, .restart),
                    range: 1_000...12_000, format: "%.0f Hz",
                    tooltip: "High-pass cut-off of the transient detector. 4 kHz by default; lower (2-3 kHz) catches more sibilance, higher (6-8 kHz) only cymbals and hi-hats.",
                    defaultValue: model.resetValue(\.preEncodeLookaheadHFCutoffHz)
                ).disabled(!model.config.preEncodeLookaheadHFOnly || model.config.preEncodeLookaheadMS <= 0.0)
            }
            .disabled(disabled)
        }
    }
}

struct ProcessingFinalStageTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PageLayout.cardSpacing) {
            Card(title: "Loudness") {
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
                .help("Sets the AGC target and Final Drive together.")
                DoubleSliderRow(
                    title: "Final Drive", setting: model.setting(\.finalDriveDB, .live),
                    range: 0...12, format: "%.1f dB",
                    tooltip: "Drive into the composite clipper: the primary loudness control. More drive is louder and clips more; sustained heavy gain reduction means too hot.",
                    defaultValue: model.resetValue(\.finalDriveDB))
            }
            Card(title: "Safety Limiter") {
                SettingToggle(
                    "Enable Safety Limiter", setting: model.setting(\.limitMPX, .restart),
                    tooltip: "Look-ahead peak limiter on the final multiplex, the last safety net. Pilot and RDS bypass it so the subcarriers stay at a constant level.")
                    .toggleStyle(.switch)
                let disabled = !model.config.limitMPX
                AdvancedGroup {
                    DoubleSliderRow(
                        title: "Threshold", setting: model.dbSetting(\.limitThreshold, .restart),
                        range: -6.0 ... -0.01, format: "%.1f dBFS",
                        tooltip: "Ceiling of the safety limiter. Below it the limiter does nothing; above it the look-ahead lowers the gain to keep peaks under the ceiling.",
                        defaultValue: MPXPrimeViewModel.dBFS(fromLinear: model.resetValue(\.limitThreshold))
                    ).disabled(disabled)
                    SettingToggle(
                        "Enable Look-Ahead", setting: model.setting(\.limitLookaheadEnabled, .restart),
                        tooltip: "Lets the limiter see peaks coming and reduce the gain smoothly before they arrive. Off makes it purely reactive, with more overshoot.")
                    .disabled(disabled)
                    DoubleSliderRow(
                        title: "Look-Ahead", setting: model.setting(\.limitLookaheadMS, .restart),
                        range: 0...20, format: "%.1f ms",
                        tooltip: "How far ahead the limiter looks. 5 ms is standard; longer is smoother at the cost of latency.",
                        defaultValue: model.resetValue(\.limitLookaheadMS)
                    ).disabled(disabled || !model.config.limitLookaheadEnabled)
                }
            }
        }
    }
}

struct ProcessingPhaseRotatorTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card {
            SettingToggle("Enable Phase Rotator", setting: model.setting(\.phaseRotationEnabled, .live))
                .toggleStyle(.switch)
            DoubleSliderRow(
                title: "Frequency", setting: model.setting(\.phaseRotationFreqHz, .live),
                range: 50...500, format: "%.0f Hz",
                tooltip: "Centre frequency of the 4-pole all-pass chain. 200 Hz is typical; lower values suit male voices, higher values female voices.",
                defaultValue: model.resetValue(\.phaseRotationFreqHz)
            )
            .disabled(!model.config.phaseRotationEnabled)
        }
    }
}

struct ProcessingParametricEQTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let disabled = !model.config.parametricEQEnabled
        VStack(alignment: .leading, spacing: PageLayout.cardSpacing) {
            Card {
                SettingToggle("Enable Parametric EQ", setting: model.setting(\.parametricEQEnabled, .live))
                    .toggleStyle(.switch)
            }
            Card(title: "Band 1: Low Shelf") {
                freq(\.peqB1FreqHz, 20...500, "Corner frequency of the low shelf. Programme below it is boosted or cut by the shelf gain.")
                gain(\.peqB1GainDB, "Boost or cut below the shelf frequency. Positive adds warmth; negative tightens the bass.")
            }
            .disabled(disabled)
            Card(title: "Band 2: Peaking") {
                freq(\.peqB2FreqHz, 100...5000, "Centre frequency of this peaking band.")
                gain(\.peqB2GainDB, "Boost or cut at the centre frequency.")
                q(\.peqB2Q)
            }
            .disabled(disabled)
            Card(title: "Band 3: Peaking") {
                freq(\.peqB3FreqHz, 500...12000, "Centre frequency of this peaking band.")
                gain(\.peqB3GainDB, "Boost or cut at the centre frequency.")
                q(\.peqB3Q)
            }
            .disabled(disabled)
            Card(title: "Band 4: High Shelf") {
                freq(\.peqB4FreqHz, 1000...16000, "Corner frequency of the high shelf. Programme above it is boosted or cut by the shelf gain.")
                gain(\.peqB4GainDB, "Boost or cut above the shelf frequency. Positive adds air; negative softens harshness.")
            }
            .disabled(disabled)
        }
    }

    private func freq(_ kp: WritableKeyPath<AppConfig, Double>, _ range: ClosedRange<Double>, _ tip: String) -> some View {
        DoubleSliderRow(title: "Frequency", setting: model.setting(kp, .live), range: range, format: "%.0f Hz",
                        tooltip: tip, defaultValue: model.resetValue(kp))
    }

    private func gain(_ kp: WritableKeyPath<AppConfig, Double>, _ tip: String) -> some View {
        DoubleSliderRow(title: "Gain", setting: model.setting(kp, .live), range: -12...12, format: "%.1f dB",
                        tooltip: tip, defaultValue: model.resetValue(kp))
    }

    private func q(_ kp: WritableKeyPath<AppConfig, Double>) -> some View {
        DoubleSliderRow(title: "Q", setting: model.setting(kp, .live), range: 0.1...10, format: "%.2f",
                        tooltip: "Bandwidth of the peaking filter. Low Q is broad and musical; high Q is narrow and surgical.",
                        defaultValue: model.resetValue(kp))
    }
}

struct ProcessingMultibandLimiterTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let disabled = !model.config.multibandLimiterEnabled
        Card {
            SettingToggle("Enable Band Limiter", setting: model.setting(\.multibandLimiterEnabled, .live))
                .toggleStyle(.switch)
            DoubleSliderRow(
                title: "Threshold", setting: model.setting(\.multibandLimiterThresholdDB, .live),
                range: -20...0, format: "%.1f dB",
                tooltip: "Per-band peak ceiling. Peaks above it are held down whatever the compressor ratio.",
                defaultValue: model.resetValue(\.multibandLimiterThresholdDB)
            )
            .disabled(disabled)
            AdvancedGroup {
                DoubleSliderRow(
                    title: "Attack", setting: model.setting(\.multibandLimiterAttackMS, .live),
                    range: 0.01...10, format: "%.2f ms",
                    tooltip: "Limiter attack. Sub-millisecond attack catches fast transients cleanly at the cost of some distortion.",
                    defaultValue: model.resetValue(\.multibandLimiterAttackMS)
                )
                .disabled(disabled)
                DoubleSliderRow(
                    title: "Release", setting: model.setting(\.multibandLimiterReleaseMS, .live),
                    range: 10...500, format: "%.0f ms",
                    tooltip: "Limiter release. Short release means more density; long release is more transparent.",
                    defaultValue: model.resetValue(\.multibandLimiterReleaseMS)
                )
                .disabled(disabled)
            }
        }
    }
}

struct ProcessingExpanderTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let disabled = !model.config.downwardExpanderEnabled
        Card {
            SettingToggle("Enable Expander", setting: model.setting(\.downwardExpanderEnabled, .live))
                .toggleStyle(.switch)
            DoubleSliderRow(
                title: "Threshold", setting: model.setting(\.expanderThresholdDB, .live),
                range: -60...(-20), format: "%.1f dB",
                tooltip: "Level below which the gain starts to fall. Set it just above the noise floor of the programme.",
                defaultValue: model.resetValue(\.expanderThresholdDB)).disabled(disabled)
            DoubleSliderRow(
                title: "Ratio", setting: model.setting(\.expanderRatio, .live),
                range: 1...8, format: "%.1f:1",
                tooltip: "Expansion ratio below the threshold. A higher ratio attenuates quiet material more deeply.",
                defaultValue: model.resetValue(\.expanderRatio)).disabled(disabled)
            AdvancedGroup {
                DoubleSliderRow(
                    title: "Attack", setting: model.setting(\.expanderAttackMS, .live),
                    range: 0.1...100, format: "%.1f ms",
                    tooltip: "Time to open again once the programme rises above the threshold. Fast attack keeps the first transient.",
                    defaultValue: model.resetValue(\.expanderAttackMS)).disabled(disabled)
                DoubleSliderRow(
                    title: "Release", setting: model.setting(\.expanderReleaseMS, .live),
                    range: 10...2000, format: "%.0f ms",
                    tooltip: "Time to close once the programme falls below the threshold. Longer release avoids chattering on quiet sustained sources.",
                    defaultValue: model.resetValue(\.expanderReleaseMS)).disabled(disabled)
            }
        }
    }
}

struct ProcessingBassClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let disabled = !model.config.bassClipperEnabled
        Card {
            SettingToggle("Enable Bass Clipper", setting: model.setting(\.bassClipperEnabled, .live))
                .toggleStyle(.switch)
            DoubleSliderRow(
                title: "Threshold", setting: model.setting(\.bassClipperThresholdDB, .live),
                range: -12...0, format: "%.1f dB",
                tooltip: "Clipping threshold for the low band. Lower clips the bass harder and reduces bass-induced intermodulation in the stages that follow.",
                defaultValue: model.resetValue(\.bassClipperThresholdDB)).disabled(disabled)
            DoubleSliderRow(
                title: "Drive", setting: model.percentSetting(\.bassClipperDrive, .live),
                range: 50...300, format: "%.0f%%",
                tooltip: "Gain into the clipper on the low band. More drive increases density and clipping distortion.",
                defaultValue: model.resetValue(\.bassClipperDrive) * 100).disabled(disabled)
            AdvancedGroup {
                DoubleSliderRow(
                    title: "Crossover", setting: model.setting(\.bassClipperCrossoverHz, .live),
                    range: 60...300, format: "%.0f Hz",
                    tooltip: "Splits off the low band for clipping. Below it is clipped; above it passes untouched.",
                    defaultValue: model.resetValue(\.bassClipperCrossoverHz)).disabled(disabled)
            }
        }
    }
}

struct ProcessingHFLimiterTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // The HF limiter rides the pre-emphasis BOOST, so with nothing to
        // ride it is an identity whatever these say (`ChainFeature.hfLimiter`).
        if ChainFeature.hfLimiter.applies(in: model.config.operatingMode) {
            let disabled = !model.config.hfLimiterEnabled
            Card {
                SettingToggle(
                    "Enable HF Limiter", setting: model.setting(\.hfLimiterEnabled, .live),
                    tooltip: "Rides only the pre-emphasis boost, so overshooting cymbals and hi-hats briefly lose part of their boost instead of being clipped (the Optimod HF-limiter topology, Orban US 4,103,243, expired). Peaks the boost did not cause are left to the Audio Limiter.")
                    .toggleStyle(.switch)
                DoubleSliderRow(
                    title: "Threshold", setting: model.setting(\.hfLimiterThresholdDB, .live),
                    range: -12...0, format: "%.1f dB",
                    tooltip: "Pre-emphasised peak that starts the HF ride. It sits 0.5 dB above the Audio Limiter's threshold, so the ride only acts on HF excess the limiter would otherwise clip.",
                    defaultValue: model.resetValue(\.hfLimiterThresholdDB)).disabled(disabled)
                AdvancedGroup {
                    DoubleSliderRow(
                        title: "Top Threshold", setting: model.setting(\.hfLimiterTopThresholdDB, .live),
                        range: -12...0, format: "%.1f dB",
                        tooltip: "The same ceiling for boost above 13 kHz (cymbals, the top octave); 1 dB under Threshold by default. The detector slides between the two with the share of the boost above 13 kHz.",
                        defaultValue: model.resetValue(\.hfLimiterTopThresholdDB)).disabled(disabled)
                    DoubleSliderRow(
                        title: "Attack", setting: model.setting(\.hfLimiterAttackMS, .live),
                        range: 0.2...20, format: "%.2f ms",
                        tooltip: "How fast the boost is pulled down. 1-3 ms: the Audio Limiter's look-ahead catches what leaks during the attack.",
                        defaultValue: model.resetValue(\.hfLimiterAttackMS)).disabled(disabled)
                    DoubleSliderRow(
                        title: "Release", setting: model.setting(\.hfLimiterReleaseMS, .live),
                        range: 5...500, format: "%.0f ms",
                        tooltip: "How fast the full pre-emphasis returns. 10-50 ms keeps the HF dip brief; longer trades sparkle for density.",
                        defaultValue: model.resetValue(\.hfLimiterReleaseMS)).disabled(disabled)
                    DoubleSliderRow(
                        title: "Max Reduction", setting: model.setting(\.hfLimiterMaxReductionDB, .live),
                        range: 1...24, format: "%.1f dB",
                        tooltip: "Limit on how much of the pre-emphasis boost may be removed. The stage never cuts the highs below the flat, un-emphasised level.",
                        defaultValue: model.resetValue(\.hfLimiterMaxReductionDB)).disabled(disabled)
                }
            }
        }
    }
}

struct ProcessingAdvancedDynamicsTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card {
            // No enable toggle: the Levelling engine picker on the Overview is
            // the one switch, and this page exists only while it says
            // Advanced Dynamics. One usage tip (the help box says what it is).
            Text("Start with the defaults, then raise Density for a more competitive sound. The bands follow the Multiband crossovers; to edit them, switch to AGC + Multiband on the Overview.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DoubleSliderRow(
                title: "Target Level", setting: model.setting(\.advancedDynamicsTargetDB, .live),
                range: -30...(-6), format: "%.1f dB",
                tooltip: "The level every band is brought towards. Lower means more headroom and a gentler sound; higher is denser and louder into the clippers.",
                defaultValue: model.resetValue(\.advancedDynamicsTargetDB))
            DoubleSliderRow(
                title: "Density", setting: model.percentSetting(\.advancedDynamicsDensity, .live),
                range: 0...100, format: "%.0f%%",
                tooltip: "How tightly the leveller holds the programme at the target. Higher is denser and more processed; lower leaves more dynamics intact.",
                defaultValue: model.resetValue(\.advancedDynamicsDensity) * 100)
            DoubleSliderRow(
                title: "Bass Balance", setting: model.setting(\.advancedDynamicsLowOffsetDB, .live),
                range: -6...6, format: "%.1f dB",
                tooltip: "Low-band target relative to Target Level. The five bands interpolate between the Bass, Mid and Treble anchors, setting the tonal balance on air.",
                defaultValue: model.resetValue(\.advancedDynamicsLowOffsetDB))
            DoubleSliderRow(
                title: "Mid Balance", setting: model.setting(\.advancedDynamicsMidOffsetDB, .live),
                range: -6...6, format: "%.1f dB",
                tooltip: "Mid-band target relative to Target Level.",
                defaultValue: model.resetValue(\.advancedDynamicsMidOffsetDB))
            DoubleSliderRow(
                title: "Treble Balance", setting: model.setting(\.advancedDynamicsHighOffsetDB, .live),
                range: -6...6, format: "%.1f dB",
                tooltip: "High-band target relative to Target Level. The default approximates a natural music spectrum; raise it for a brighter sound on air.",
                defaultValue: model.resetValue(\.advancedDynamicsHighOffsetDB))
            AdvancedGroup {
                DoubleSliderRow(
                    title: "Speed", setting: model.setting(\.advancedDynamicsSpeed, .live),
                    range: 0.25...4, format: "%.2fx",
                    tooltip: "Scales every time constant. The stage adapts its own attack and release to the programme; this makes that faster or slower.",
                    defaultValue: model.resetValue(\.advancedDynamicsSpeed))
                DoubleSliderRow(
                    title: "Max Boost", setting: model.setting(\.advancedDynamicsMaxGainDB, .live),
                    range: 0...24, format: "%.1f dB",
                    tooltip: "The most gain added to quiet programme per band. The reduction side is fixed at 24 dB, so the range absorbs large level jumps within a song.",
                    defaultValue: model.resetValue(\.advancedDynamicsMaxGainDB))
            }
        }
    }
}

struct ProcessingDCClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let disabled = !model.config.dcClipperEnabled
        Card {
            SettingToggle("Enable Audio Clipper", setting: model.setting(\.dcClipperEnabled, .live))
                .toggleStyle(.switch)
            DoubleSliderRow(
                title: "Ceiling", setting: model.setting(\.dcClipperCeilingDB, .live),
                range: -6...0, format: "%.1f dB",
                tooltip: "Clipping ceiling. A lower ceiling is denser but brings more clipping artefacts.",
                defaultValue: model.resetValue(\.dcClipperCeilingDB)).disabled(disabled)
            AdvancedGroup {
                DoubleSliderRow(
                    title: "Cancellation Frequency", setting: model.setting(\.dcClipperCancelFreqHz, .live),
                    range: 500...4000, format: "%.0f Hz",
                    tooltip: "Clipping distortion below this frequency is cancelled (subtracted by a low-pass error filter); above it, it is left to be masked by the programme.",
                    defaultValue: model.resetValue(\.dcClipperCancelFreqHz)).disabled(disabled)
            }
        }
    }
}

struct ProcessingBS412Tab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card {
            SettingToggle("Enable BS.412", setting: model.setting(\.bs412Enabled, .live))
                .toggleStyle(.switch)
            DoubleSliderRow(
                title: "Ceiling", setting: model.setting(\.bs412CeilingDBr, .live),
                range: -10...0, format: "%.1f dBr",
                tooltip: "Average power of the complete multiplex, pilot and RDS included, over any 60 seconds. 0 dBr is the ITU-R BS.412 limit (the power of a sine at 19 kHz deviation); set it lower only to keep a margin below the limit.",
                defaultValue: model.resetValue(\.bs412CeilingDBr)).disabled(!model.config.bs412Enabled)
        }
    }
}

struct ProcessingStereoCoderTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card {
            // Pilot level follows ITU-R BS.450 (8-10% of deviation); 0-12%
            // leaves room either side, and 0 mutes it. Composite only.
            if !model.processedAudioOutputActive {
                DoubleSliderRow(
                    title: "Pilot Level", setting: model.percentSetting(\.pilotLevel, .live),
                    range: 0...12, format: "%.1f%%",
                    tooltip: "Pilot injection as a share of the deviation. ITU-R BS.450 specifies 8-10%; 9% is usual.",
                    defaultValue: model.resetValue(\.pilotLevel) * 100.0)
                .disabled(model.config.monoMode)
            }
            SettingToggle(
                "Enable SSB Stereo", setting: model.setting(\.ssbStereoEnabled, .live),
                tooltip: "Leans the 38 kHz stereo subcarrier towards single sideband, keeping whichever sideband currently peaks lower, to reclaim composite headroom ahead of the clipper. Independent of the Composite Clipper.")
            // A safety one-liner: receivers differ.
            Text("Standard receivers decode SSB stereo fine (81 dB separation measured); a receiver with an imperfect phase response may lose a little separation, so check it on your own receivers.")
                .font(.caption)
                .foregroundStyle(.secondary)
            AdvancedGroup {
                DoubleSliderRow(
                    title: "SSB Amount", setting: model.percentSetting(\.ssbStereoAmount, .live),
                    range: 0...100, format: "%.0f%%",
                    tooltip: "How far the subcarrier leans towards single sideband. 0% is classic double sideband; 100% is full SSB (most headroom, most receiver-sensitive). Start around 50-70%.",
                    defaultValue: model.resetValue(\.ssbStereoAmount) * 100)
                    .disabled(!model.config.ssbStereoEnabled)
            }
        }
    }
}

struct ProcessingCompositeClipperTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        let disabled = !model.config.compositeClipperEnabled
        Card {
            SettingToggle("Enable Composite Clipper", setting: model.setting(\.compositeClipperEnabled, .live))
                .toggleStyle(.switch)
            DoubleSliderRow(
                title: "Threshold", setting: model.setting(\.compositeClipperThresholdDB, .live),
                range: -12...0, format: "%.1f dB",
                tooltip: "Onset of soft clipping on the audio composite (not the pilot or RDS). The main loudness control while the clipper is on.",
                defaultValue: model.resetValue(\.compositeClipperThresholdDB)).disabled(disabled)
            DoubleSliderRow(
                title: "Ceiling", setting: model.setting(\.compositeClipperCeilingDB, .live),
                range: -6...0, format: "%.1f dB",
                tooltip: "Highest level after clipping. It stays below 0 dBFS to leave room for the pilot and RDS.",
                defaultValue: model.resetValue(\.compositeClipperCeilingDB)).disabled(disabled)
            // Replaces the old "leave it off" tip: every Format Profile turns
            // the clipper on, and the app warns when both peak controllers
            // are off. This is the one actionable line the help box lacks.
            Text("Every Format Profile turns the composite clipper on. If the highs sound harsh, turn on Protect Audio Highs under Advanced: cleaner highs for a little loudness.")
                .font(.caption)
                .foregroundStyle(.secondary)
            AdvancedGroup {
                DoubleSliderRow(
                    title: "Look-Ahead", setting: model.setting(\.compositeClipperLookaheadMS, .live),
                    range: 0...5, format: "%.1f ms",
                    tooltip: "Predictive peak shaving ahead of the clipper. 0 ms is off; 2 ms is the recommended preset. Holds overshoot tighter than soft clipping alone, at the cost of the same added latency.",
                    defaultValue: model.resetValue(\.compositeClipperLookaheadMS)).disabled(disabled)
                LabeledContent("Look-Ahead Gain Reduction") {
                    LiveObservationView(telemetry: model.telemetry) { t in
                        Text(String(format: "%5.1f dB", Double(t.compositeClipperLookaheadGainReductionDBValue)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                SettingPicker(
                    "Oversampling", setting: model.setting(\.compositeClipperOversampling, .live),
                    tooltip: "16x is the usual choice. 8x halves this stage's processor load for slightly more aliasing (older Macs); 32x doubles it for slightly less."
                ) {
                    Text("8x").tag(8)
                    Text("16x").tag(16)
                    Text("32x").tag(32)
                }
                .pickerStyle(.segmented)
                Text("Protection")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                SettingToggle(
                    "Protect Audio Highs", setting: model.setting(\.compositeClipperCancelAudio, .live),
                    tooltip: "Off (default): full clipping in the audio band for the most loudness. On: removes the clipping distortion in the audio band for cleaner highs, at the cost of some peak control and loudness.")
                .disabled(disabled)
                SettingToggle(
                    "Protect Stereo Pilot", setting: model.setting(\.compositeClipperCancelPilot, .live),
                    tooltip: "Keeps clipping distortion out of the 19 kHz pilot region so receivers decode stereo cleanly. Leave it on except for an A/B test.")
                .disabled(disabled)
                DoubleSliderRow(
                    title: "Protect Stereo Subcarrier", setting: model.percentSetting(\.compositeClipperStereoGuard, .live),
                    range: 0...100, format: "%.0f%%",
                    tooltip: "How much of the clipping distortion is kept out of the 22-53 kHz stereo subcarrier. 100% leaves the subcarrier untouched: best high-frequency separation, but the clipper then only clips the mono share of a peak and the safety limiter rides the rest. 0% clips the full composite as most processors do: most loudness, least separation on dense programme.",
                    defaultValue: model.resetValue(\.compositeClipperStereoGuard) * 100).disabled(disabled)
                SettingToggle(
                    "Protect RDS", setting: model.setting(\.compositeClipperCancelRDS, .live),
                    tooltip: "Keeps clipping distortion out of the 57 kHz RDS region so receivers do not see clipper noise on the RDS subcarrier. Leave it on except for an A/B test.")
                .disabled(disabled)
            }
        }
    }
}

#endif  // os(macOS)
