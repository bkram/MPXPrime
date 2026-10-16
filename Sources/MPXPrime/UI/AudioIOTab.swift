#if os(macOS)
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI

/// Audio I/O -- the installation page: where the signal enters and leaves the
/// app. Devices, the operating mode, and level CALIBRATION live here,
/// deliberately separated from the DSP tabs so profiles, presets, and
/// per-tab resets never touch the rig's plumbing. The Output card's levels
/// are remembered PER DEVICE and recalled when the selection changes.
///
/// Each device row is an `AudioDeviceSelector`: the device plus WHICH of its
/// channels carry the signal, so a 4/8/16-channel interface is usable. The
/// Devices button in the header row lists every interface the last scan
/// found (hot-plug rescans automatically; Rescan is the manual way).
struct AudioIOTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PageLayout.cardSpacing) {
            HStack {
                Spacer()
                DevicesButton(
                    devices: model.allDevices,
                    lastScan: model.lastDeviceScan,
                    rescan: { model.rescanDevices() })
                .buttonStyle(.bordered)
            }
            Card(title: "Operating Mode") {
                OperatingModeCardContent(model: model)
            }
            Card(title: "Input") {
                AudioIOInputCardContent(model: model)
            }
            Card(title: "Output") {
                AudioIOOutputCardContent(model: model)
            }
            Card(title: "Monitor") {
                AudioIOMonitorCardContent(model: model)
            }
            Card(title: "Engine") {
                AudioIOEngineCardContent(model: model)
            }
        }
    }
}

/// The operating mode: ONE four-way choice (`operating_mode`). Every
/// follow-up control shown here is one that has a function in the selected
/// mode -- the applicability rules live in `ChainFeature`, not in this view.
/// Pre-emphasis lives here in every mode that has it (MPX and FM; AM has its
/// own NRSC curve), so it never moves between pages with the mode.
struct OperatingModeCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    private var mode: AppConfig.OperatingMode { model.config.operatingMode }

    private var modeBinding: Binding<AppConfig.OperatingMode> {
        Binding(
            get: { model.config.operatingMode },
            set: { newMode in
                guard newMode != model.config.operatingMode else { return }
                let oldProcessed = model.config.processedAudioOutput
                model.setting(\.operatingMode, .restart).binding.wrappedValue = newMode
                // Visibility follows the selected configuration immediately,
                // even though the signal-path change itself waits for restart.
                // Do not leave a now-hidden DSP page displayed in the detail
                // pane while its sidebar row has already disappeared.
                model.normalizeSelection()
                // The mode changes what output_gain_db MEANS, so recall the
                // output device's per-mode calibration and persist it.
                model.recallCalibrationIfDeviceChanged(
                    oldInputUID: model.config.inputDeviceUID,
                    oldOutputUID: model.config.outputDeviceUID,
                    oldProcessed: oldProcessed)
                model.persistBasicConfig()
            }
        )
    }

    /// Pre-emphasis for the FM curve, in every mode that pre-emphasises (MPX
    /// and FM Output). In FM Output the external coder may apply it instead,
    /// and exactly one device may.
    @ViewBuilder private var preemphasisPicker: some View {
        let coderMode = mode == .fm
        SettingPicker(
            "Pre-emphasis",
            setting: model.setting(\.preemphasisUS, .restart),
            tooltip: coderMode
                ? "Exactly one device may apply pre-emphasis. If your stereo coder has none (or it is switched off), pick 50 or 75 us here so MPX Prime applies it. If the coder applies it, pick Off. Never both: two stages in series over-deviate."
                : "The FM pre-emphasis curve: 50 us in Europe and most of the world, 75 us in the Americas and South Korea. Off only for measurements."
        ) {
            Text(coderMode ? "Off (Coder Applies It)" : "Off").tag(0)
            Text("50 us").tag(50)
            Text("75 us").tag(75)
        }
        .pickerStyle(.segmented)
    }

    var body: some View {
        // The mode is stored under two legacy keys as well, so the engine
        // classifier cannot probe it; it is restart-class (the signal path is
        // rebuilt), stated here once.
        Picker(selection: modeBinding) {
            ForEach(AppConfig.OperatingMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        } label: {
            SettingLabel(title: "Mode", restartRequired: true)
        }
        .pickerStyle(.segmented)
        .help("MPX Output: the FM multiplex (pilot, stereo and RDS) for an exciter. FM Output: FM-shaped stereo L/R for an external stereo coder and RDS encoder. HD Output: processing for streaming or digital radio (DAB+, AAC), flat with a true-peak ceiling. AM Output: mono processing for an AM transmitter.")

        // The card's one caption: what the selected mode is for.
        Text(mode.subtitle + ".")
            .font(.caption)
            .foregroundStyle(.secondary)

        if ChainFeature.preemphasis.applies(in: mode) {
            Divider()
            preemphasisPicker
        }

        if ChainFeature.digitalCeiling.applies(in: mode) {
            Divider()
            DoubleSliderRow(
                title: "True-Peak Ceiling",
                setting: model.setting(\.processedAudioCeilingDBTP, .live),
                range: -6...0,
                format: "%.1f dBTP",
                tooltip: "Where peaks are held for the encoder downstream. -1.0 dBTP is the shared recommendation of EBU R128, AES TD1008 and the streaming platforms; use -2.0 when the next box is a data-reduction codec (DAB+, AAC), because lossy encoding pushes inter-sample peaks up. Loudness is set upstream by the AGC target, not here: aim for about -16 LUFS for a stream, or -23 LUFS under EBU R128 for DAB.",
                defaultValue: model.resetValue(\.processedAudioCeilingDBTP))
        }

        if ChainFeature.amShaping.applies(in: mode) {
            Divider()
            AMOutputControls(model: model)
        }

        if ChainFeature.coderFinalClipper.applies(in: mode) {
            Divider()
            SettingToggle(
                "Coder Has Its Own Clipper",
                setting: model.setting(\.processedAudioCoderHasClipper, .live),
                tooltip: "The same one-stage rule as pre-emphasis, for clipping. Leave on if your stereo coder clips or limits its own input. Turn it off only if it does not: MPX Prime then adds a final loudness clipper so the feed is denser. Two clippers in series sound harsh.")

            if !model.config.processedAudioCoderHasClipper {
                DoubleSliderRow(
                    title: "Final Clipper Drive",
                    setting: model.setting(\.processedAudioFinalClipDriveDB, .live),
                    range: 0...12,
                    format: "%.1f dB",
                    tooltip: "How hard the processed L/R is driven into MPX Prime's final loudness clipper. More drive is louder and denser, with more clipping character. Start low and listen on a receiver; make sure the external coder is not also clipping its input.",
                    defaultValue: model.resetValue(\.processedAudioFinalClipDriveDB))
            }
        }
    }
}

/// AM Output follow-ups: the NRSC shaping and the asymmetry an AM transmitter
/// feed needs. Shown only in AM, where they have a function.
struct AMOutputControls: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingPicker(
            "AM Pre-emphasis",
            setting: model.setting(\.amPreemphasisUS, .restart),
            tooltip: "NRSC-1 pre-emphasis, the curve an NRSC receiver de-emphasises. Switch it off only when the transmitter or an outboard box already applies it."
        ) {
            Text("Off (Flat)").tag(0)
            Text("75 us (NRSC)").tag(75)
        }
        .pickerStyle(.segmented)

        DoubleSliderRow(
            title: "AM Bandwidth",
            setting: model.setting(\.amLowpassHz, .restart),
            range: 3_000...10_000,
            format: "%.0f Hz",
            tooltip: "Audio bandwidth of the AM feed. NRSC-1 specifies 10 kHz; many stations run 4.5 to 6 kHz to fit the channel and the receiver.",
            defaultValue: model.resetValue(\.amLowpassHz))

        DoubleSliderRow(
            title: "Positive Peak Headroom",
            setting: model.setting(\.amPositivePeakPct, .live),
            range: 100...125,
            format: "%.0f%%",
            tooltip: "Asymmetric modulation: positive peaks may reach 125% where the regulator allows it, while negative peaks stay at 100%. At 125 the negative side is held 1.9 dB below full scale so the positive side can use the rest; calibrate the transmitter so the negative peak reads 100% modulation.",
            defaultValue: model.resetValue(\.amPositivePeakPct))
    }
}

struct AudioIOInputCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel
    /// Input meters before or after Input Gain; a viewing preference, kept per user.
    @AppStorage("audioIO.inputMetersPostGain") private var metersPostGain = true

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                // persistBasicConfig recalls the per-device calibration when
                // the device changed, exactly as the old Picker did.
                LabeledContent {
                    AudioDeviceSelector(
                        title: "Input Device",
                        role: .input,
                        devices: model.inputDevices,
                        selectedUID: Binding(
                            get: { model.selectedInputUID },
                            set: {
                                model.selectedInputUID = $0
                                model.persistBasicConfig()
                            }
                        ),
                        channels: Binding(
                            get: { model.selectedInputChannels },
                            set: {
                                model.selectedInputChannels = $0
                                model.persistBasicConfig()
                            }
                        ),
                        noneLabel: "System Default",
                        footnote: "Changing the device or channels restarts the engine.")
                } label: {
                    SettingLabel(title: "Input Device", restartRequired: true)
                }

                DoubleSliderRow(title: "Input Gain", value: Binding(
                    get: { model.inputGainDB },
                    set: { model.setInputGainLive($0) }
                ), range: -24...24, format: "%.1f dB",
                tooltip: "Pre-chain trim on the L/R input: calibration for this input device, remembered per device. It is not the loudness control; the AGC normalises from here.",
                defaultValue: model.resetValue(\.inputGainDB))

                Text("Aim for peaks between -12 and -6 dBFS on busy programme, read on the Post meters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                Picker("Input Meters", selection: $metersPostGain) {
                    Text("Pre").tag(false)
                    Text("Post").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Pre shows what the input device delivers. Post shows it after Input Gain: "
                    + "the level the processing receives, which is what the -12 to -6 dBFS aim refers to.")
                LiveObservationView(telemetry: model.telemetry) { t in
                    LadderMeterView(
                        left: metersPostGain ? t.inputPostLeft : t.inputPreLeft,
                        right: metersPostGain ? t.inputPostRight : t.inputPreRight,
                        height: 170)
                }
            }
        }
    }
}

struct AudioIOOutputCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    private var mode: AppConfig.OperatingMode { model.config.operatingMode }

    var body: some View {
        let composite = !model.processedAudioOutputActive
        // persistBasicConfig recalls the per-device calibration when the
        // device changed, exactly as the old Picker did.
        LabeledContent {
            AudioDeviceSelector(
                title: composite ? "MPX Output Device" : "Output Device",
                role: .output,
                devices: model.outputDevices,
                selectedUID: Binding(
                    get: { model.selectedOutputUID },
                    set: {
                        model.selectedOutputUID = $0
                        model.persistBasicConfig()
                    }
                ),
                channels: Binding(
                    get: { model.selectedOutputChannels },
                    set: {
                        model.selectedOutputChannels = $0
                        model.persistBasicConfig()
                    }
                ),
                noneLabel: "System Default",
                footnote: "Changing the device or channels restarts the engine.")
        } label: {
            SettingLabel(title: composite ? "MPX Output Device" : "Output Device", restartRequired: true)
        }

        DoubleSliderRow(
            title: Self.outputLevelTitle(mode),
            setting: model.setting(\.outputGainDB, .live),
            range: Self.outputLevelRange(mode),
            format: "%.1f dB",
            tooltip: outputLevelTooltip,
            defaultValue: model.resetValue(\.outputGainDB)
        )
        if composite {
            DoubleSliderRow(
                title: "Line Output",
                setting: model.setting(\.mpxLineOutputDBFS, .live),
                range: -40...0,
                format: "%.1f dBFS",
                tooltip: "Absolute DAC level of 100% modulation: calibrate it to the exciter's input sensitivity (remembered per device). Applied at the converter after all processing and metering. Keep the system or interface volume at 0 dB and set the level here. Values above 0 are impossible at a DAC; an under-driven exciter needs its input sensitivity trimmed instead.",
                defaultValue: model.resetValue(\.mpxLineOutputDBFS)
            )
            LiveObservationView(telemetry: model.telemetry) { t in
                LabeledContent("DAC Peak") {
                    Text(t.dacPeakText)
                        .font(.system(.body, design: .monospaced))
                }
                .help("The peak actually presented to the converter, after MPX Output Level and Line Output: the electrical headroom. The deviation meter stays in the modulation domain (the trims are divided back out).")
            }
        }
        if ChainFeature.finalStage.applies(in: mode) {
            DoubleSliderRow(
                title: "Composite Deviation",
                setting: model.setting(\.mpxDeviationKHz, .live),
                range: 40...90,
                format: "%.1f kHz",
                tooltip: "Target peak FM deviation of the complete multiplex. 75 kHz is the ITU-R BS.450 and US figure; some regulators mandate less. Pilot and RDS keep their share of it.",
                defaultValue: model.resetValue(\.mpxDeviationKHz))
        }
        // The card's one caption.
        Text("Input Gain, Output Level and Line Output are rig calibration, remembered per device: switching devices recalls each device's own values, and profiles, presets and page resets never change them.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// One name per mode: the composite level in MPX Output, the processed
    /// feed's level otherwise.
    static func outputLevelTitle(_ mode: AppConfig.OperatingMode) -> String {
        mode.isAudioOutput ? "Output Level" : "MPX Output Level"
    }

    /// Attenuation only for the composite (0 dB is the full budget); a trim
    /// either way for a processed feed.
    static func outputLevelRange(_ mode: AppConfig.OperatingMode) -> ClosedRange<Double> {
        mode.isAudioOutput ? -18...18 : -18...0
    }

    private var outputLevelTooltip: String {
        switch mode {
        case .mpx:
            return "Attenuation-only trim on the composite before the audio device (0 dB is the full composite budget): deviation calibration for this exciter, remembered per device. DAC Peak shows what actually leaves the converter."
        case .fm:
            return "Level of the processed L/R feed for this device, remembered per device. Set the peaks to the stereo coder's reference level, switch the coder's own pre-emphasis off, then set its audio deviation with a test tone. The reset arrow gives -9 dB, a common coder reference."
        case .hd, .am:
            return "Level of the processed feed for this output device, remembered per device. The limiter ceiling sits at about 0 dBFS when this is 0 dB."
        }
    }
}

/// The operator's listening output: a SECOND device, playing alongside the
/// transmitter feed, in every operating mode. What it plays is conditioned to
/// sound like the receiving end (`MonitorConditioner`), so it is a reference
/// for the ear, never the signal on air.
struct AudioIOMonitorCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    /// What the operator will hear in the current mode.
    private var monitorDescription: String {
        switch model.config.operatingMode {
        case .mpx:
            return "Plays the composite decoded back to audio, the way an FM receiver would: pilot, stereo and de-emphasis included."
        case .fm:
            return model.config.preemphasisUS > 0
                ? "Plays the processed feed with the pre-emphasis taken back out, so it sounds like the receiving end rather than the wire."
                : "Plays the processed feed as it leaves the output."
        case .hd:
            return "Plays the processed feed as it leaves the output: flat, full bandwidth, the way the encoder receives it."
        case .am:
            return "Plays the mono AM feed with the NRSC pre-emphasis taken back out, the way an AM receiver plays it."
        }
    }

    var body: some View {
        // Live: the monitor runs alongside the transmitter feed, so turning
        // it on or off never restarts the engine (no restart badge).
        Toggle("Enable Monitor", isOn: Binding(
            get: { model.monitorEnabled },
            set: { model.monitorEnabled = $0; model.persistMonitorSettings() }))
            .toggleStyle(.switch)
            .help("A separate listening output on its own device. It runs alongside the transmitter feed: turning it on never interrupts what is on air. Pick a device that is not the transmitter output, or other channels of the same interface.")
        LabeledContent("Monitor Device") {
            AudioDeviceSelector(
                title: "Monitor Device",
                role: .output,
                devices: model.outputDevices,
                selectedUID: Binding(
                    get: { model.selectedMonitorUID },
                    set: {
                        model.selectedMonitorUID = $0
                        model.persistMonitorSettings()
                    }
                ),
                channels: Binding(
                    get: { model.selectedMonitorChannels },
                    set: {
                        model.selectedMonitorChannels = $0
                        model.persistMonitorSettings()
                    }
                ),
                noneLabel: "System Default",
                footnote: "Applies live; only the monitor player restarts.")
        }
        .disabled(!model.monitorEnabled)
        DoubleSliderRow(
            title: "Monitor Level",
            setting: model.setting(\.monitorGainDB, .live),
            range: -40...6,
            format: "%.1f dB",
            tooltip: "Headphone or speaker level for the monitor only. It cannot change what is transmitted.",
            defaultValue: model.resetValue(\.monitorGainDB)
        )
        .disabled(!model.monitorEnabled)
        // The card's one caption.
        Text(monitorDescription + " A listening aid, a few tens of milliseconds behind the output, never the on-air signal.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct AudioIOEngineCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    static let sampleRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    static let blockSizes: [Int] = [256, 512, 1024, 2048, 4096, 8192]

    var body: some View {
        SettingPicker(
            "Sample Rate",
            setting: model.setting(\.sampleRate, .restart),
            tooltip: "The engine's processing and output rate. MPX Output with RDS needs 192 kHz. Stop the engine to change it."
        ) {
            ForEach(Self.sampleRates, id: \.self) { rate in
                Text(Self.rateLabel(rate)).tag(rate)
            }
        }
        .pickerStyle(.menu)
        .disabled(model.isRunning)

        SettingPicker(
            "Block Size",
            setting: model.setting(\.blockSize, .restart),
            tooltip: "Samples per audio callback. Larger blocks are safer on a busy machine and add latency."
        ) {
            ForEach(Self.blockSizes, id: \.self) { size in
                Text("\(size) Samples").tag(size)
            }
        }
        .pickerStyle(.menu)

        SettingToggle(
            "Start Engine at Launch",
            setting: model.setting(\.rdsAutoStart, .none),
            tooltip: "Starts the engine as soon as the app opens, for an unattended installation.")

        AudioIOEngineAdvancedContent(model: model)
    }

    /// Rates in kHz, as the status bar shows them ("44.1 kHz", "192 kHz").
    static func rateLabel(_ rate: Double) -> String {
        let kHz = rate / 1_000
        return kHz == kHz.rounded() ? "\(Int(kHz)) kHz" : String(format: "%.1f kHz", kHz)
    }
}

/// Set-once engine choices: the filter topologies and the spectrum span.
struct AudioIOEngineAdvancedContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        AdvancedGroup {
            SettingPicker(
                "Encoder Lowpass",
                setting: model.setting(\.encoderFIREnabled, .restart),
                tooltip: "The 15 kHz audio-bandwidth lowpass. Linear Phase (default): a Kaiser-windowed linear-phase FIR, more than 80 dB stop-band, about 1.7 ms latency at 192 kHz. Low Latency: a 12th-order Butterworth cascade, about 0.2 ms latency and 40 dB stop-band."
            ) {
                Text("Linear Phase").tag(true)
                Text("Low Latency").tag(false)
            }
            .pickerStyle(.segmented)
            SettingPicker(
                "Multiband Crossovers",
                setting: model.setting(\.multibandFIREnabled, .restart),
                tooltip: "The multiband band splitters. Linear Phase (default): FIR splitters that sum flat with every band sharing one delay (no transient smear between bands), about 5.3 ms latency at 192 kHz. Low Latency: Linkwitz-Riley IIR crossovers, with their phase shifts between bands."
            ) {
                Text("Linear Phase").tag(true)
                Text("Low Latency").tag(false)
            }
            .pickerStyle(.segmented)
            SettingToggle(
                "96 kHz Spectrum",
                setting: model.setting(\.fftWindow96kHz, .restart),
                tooltip: "On: the MPX Spectrum shows the full 96 kHz span. Off: it shows the 60 kHz FM baseband.")
        }
    }
}

#endif  // os(macOS)
