#if os(macOS)
import MPXPrimeUI
import SwiftUI

/// Audio I/O — the installation page: where the signal enters and leaves the
/// app. Devices, the operating mode, and level CALIBRATION live here,
/// deliberately separated from the DSP tabs so profiles, presets, and
/// per-tab resets never touch the rig's plumbing. The Output card's levels
/// are remembered PER DEVICE and recalled when the selection changes.
struct AudioIOTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Operating Mode") {
                    OperatingModeCardContent(model: model)
                }
                Card(title: "Input") {
                    AudioIOInputCardContent(model: model)
                }
                Card(title: "Output") {
                    AudioIOOutputCardContent(model: model)
                }
                if !model.processedAudioOutputActive {
                    Card(title: "Monitor (Decoded MPX Simulation)") {
                        AudioIOMonitorCardContent(model: model)
                    }
                }
                Card(title: "Engine") {
                    AudioIOEngineCardContent(model: model)
                }
            }
            .frame(maxWidth: 1120, alignment: .topLeading)
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
    }
}

/// One segmented control over the two stored booleans
/// (`processed_audio_output` + `monitor_enabled` -- no new INI key): the
/// operating mode is a single decision, not two toggles in different places.
struct OperatingModeCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    private var modeBinding: Binding<AppConfig.ResolvedOutputMode> {
        Binding(
            get: { model.config.resolvedOutputMode(allowMonitor: true) },
            set: { mode in
                let oldProcessed = model.config.processedAudioOutput
                if model.monitorEnabled != (mode == .monitor) {
                    model.monitorEnabled = mode == .monitor
                    model.persistBasicConfig()
                }
                let processed = model.configBinding(
                    \.processedAudioOutput, runtimeDisposition: .restart)
                if processed.wrappedValue != (mode == .processedAudio) {
                    processed.wrappedValue = mode == .processedAudio
                    // The mode changes what output_gain_db MEANS, so recall
                    // the output device's per-mode calibration and persist it.
                    model.recallCalibrationIfDeviceChanged(
                        oldInputUID: model.config.inputDeviceUID,
                        oldOutputUID: model.config.outputDeviceUID,
                        oldProcessed: oldProcessed)
                    model.persistBasicConfig()
                }
            }
        )
    }

    var body: some View {
        Picker(selection: modeBinding) {
            Text("MPX Composite").tag(AppConfig.ResolvedOutputMode.composite)
            Text("Processed Audio").tag(AppConfig.ResolvedOutputMode.processedAudio)
            Text("Monitor").tag(AppConfig.ResolvedOutputMode.monitor)
        } label: {
            HStack(spacing: 6) {
                Text("Mode")
                RestartBadge()
            }
        }
        .pickerStyle(.segmented)
        .help("MPX Composite: the FM multiplex (pilot + stereo + RDS) for a transmitter / exciter. Processed Audio: processed stereo L/R for an external stereo coder + RDS encoder — MPX Prime as a plain audio processor. Monitor: decode the composite back to audio on the monitor device (simulate FM listening, no transmitter). Restart required.")

        if model.processedAudioOutputActive {
            Text("Emitting processed stereo L/R for an external stereo coder or streaming chain. The composite clipper, BS.412, pilot, and RDS are bypassed and hidden. Recommended output: 48 kHz / 24-bit.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Pre-emphasis", selection: model.configBinding(\.preemphasisUS)) {
                Text("Off (coder applies it)").tag(0)
                Text("50 us (EU)").tag(50)
                Text("75 us (US)").tag(75)
            }
            .pickerStyle(.segmented)
            Text("Exactly one device may apply pre-emphasis. If your stereo coder has none (or it is switched off), pick 50/75 us here so MPX Prime applies it. If the coder applies pre-emphasis, pick Off. Never both \u{2014} two stages in series over-deviate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("External coder has its own clipper",
                   isOn: model.configBinding(\.processedAudioCoderHasClipper, runtimeDisposition: .live))
                .help("Same one-stage rule as pre-emphasis, for clipping. Leave ON if your stereo coder clips/limits its own input. Turn OFF only if it does not \u{2014} then MPX Prime adds a final loudness clipper so the feed is denser. Two clippers in series sound harsh.")

            if !model.config.processedAudioCoderHasClipper {
                DoubleSliderRow(
                    title: "Final Clipper Drive",
                    value: model.configBinding(\.processedAudioFinalClipDriveDB, runtimeDisposition: .live),
                    range: 0...12,
                    format: "%.1f dB",
                    tooltip: "How hard the processed L/R is driven into MPX Prime's final loudness clipper. More drive = louder/denser but more clipping character. Start low and listen on a receiver.")
                Text("MPX Prime is applying a final loudness clipper to the processed-audio feed. Make sure your external coder is NOT also clipping the input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if model.config.resolvedOutputMode(allowMonitor: true) == .monitor {
            Text("The transmitter feed is REPLACED by decoded audio on the monitor device \u{2014} this mode is for auditioning the FM sound without a transmitter, not for being on air.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AudioIOInputCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    "Input Device",
                    selection: Binding(
                        get: { model.selectedInputUID },
                        set: {
                            model.selectedInputUID = $0
                            model.persistBasicConfig()
                        }
                    )
                ) {
                    if model.inputDevices.isEmpty {
                        Text("No input devices").tag("")
                    } else {
                        ForEach(model.inputDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
                .pickerStyle(.menu)

                DoubleSliderRow(title: "Input Gain", value: Binding(
                    get: { model.inputGainDB },
                    set: { model.setInputGainLive($0) }
                ), range: -24...24, format: "%.1f dB",
                tooltip: "Pre-chain trim on the L/R input -- calibration for THIS input device (remembered per device). Land your typical source peaks around -12 to -6 dBFS on the meters; the AGC normalizes from there. NOT the loudness knob.")

                Text("Aim for peaks between -12 and -6 dBFS on busy program.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LiveObservationView(telemetry: model.telemetry) { t in
                HStack(spacing: 10) {
                    VerticalMeterStrip(
                        label: "IN L",
                        valueText: t.inputLText.meterCurrentOnly,
                        level: t.inputLLevel,
                        peakLevel: t.inputLPeakHoldLevel,
                        scale: .dbfs
                    )
                    VerticalMeterStrip(
                        label: "IN R",
                        valueText: t.inputRText.meterCurrentOnly,
                        level: t.inputRLevel,
                        peakLevel: t.inputRPeakHoldLevel,
                        scale: .dbfs
                    )
                }
                .frame(height: 170)
            }
        }
    }
}

struct AudioIOOutputCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Picker(
            model.processedAudioOutputActive ? "Output Device" : "MPX Output Device",
            selection: Binding(
                get: { model.selectedOutputUID },
                set: {
                    model.selectedOutputUID = $0
                    model.persistBasicConfig()
                }
            )
        ) {
            if model.outputDevices.isEmpty {
                Text("No output devices").tag("")
            } else {
                ForEach(model.outputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
        }
        .pickerStyle(.menu)

        DoubleSliderRow(
            title: model.processedAudioOutputActive ? "Output Level" : "MPX Output Level",
            value: model.configBinding(\.outputGainDB, runtimeDisposition: .live),
            range: model.processedAudioOutputActive ? -18...18 : -18...0,
            format: "%.1f dB",
            tooltip: model.processedAudioOutputActive
                ? "Output level trim for the processed stereo L/R feed -- calibration for THIS output device (remembered per device). The pre-encode limiter ceiling is normalized to ~0 dBFS at 0 dB."
                : "Attenuation-only trim on the composite before the audio device (0 dB = full composite budget) -- deviation calibration for THIS exciter (remembered per device). The deviation readout stays in the modulation domain; DAC Peak below shows what actually leaves the converter."
        )
        if !model.processedAudioOutputActive {
            DoubleSliderRow(
                title: "Line Output",
                value: model.configBinding(\.mpxLineOutputDBFS, runtimeDisposition: .live),
                range: -40...0,
                format: "%.1f dBFS",
                tooltip: "Absolute DAC level of 100% modulation -- calibrate to the exciter's input sensitivity (remembered per device). Applied at the converter AFTER all processing and metering. Keep the OS/interface volume at 0 dB and set the level here. Values above 0 are impossible at a DAC; an under-driven exciter needs its input sensitivity trimmed instead."
            )
            LiveObservationView(telemetry: model.telemetry) { t in
                LabeledContent("DAC Peak") {
                    Text(t.dacPeakText)
                        .font(.system(.body, design: .monospaced))
                }
                .help("Peak actually presented to the converter: post MPX Output Level and post Line Output. The electrical headroom readout -- the deviation meter stays in the modulation domain (trims divided back out).")
            }
        }
        Text("These levels are rig calibration, remembered per device: switching output devices recalls each device's own calibration. Profiles, presets, and tab resets never change them.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct AudioIOMonitorCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Picker(
            "Monitor Output Device",
            selection: Binding(
                get: { model.selectedMonitorUID },
                set: {
                    model.selectedMonitorUID = $0
                    model.persistBasicConfig()
                }
            )
        ) {
            if model.outputDevices.isEmpty {
                Text("No output devices").tag("")
            } else {
                ForEach(model.outputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
        }
        .pickerStyle(.menu)
        Text("Used when the operating mode is Monitor: the composite is decoded back to audio on this device.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct AudioIOEngineCardContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    private let sampleRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    private let blockSizes: [Int] = [256, 512, 1024, 2048, 4096, 8192]

    var body: some View {
        Picker("Sample Rate", selection: model.configBinding(\.sampleRate)) {
            ForEach(sampleRates, id: \.self) { rate in
                Text("\(Int(rate)) Hz").tag(rate)
            }
        }
        .pickerStyle(.menu)
        .disabled(model.isRunning)

        Picker("Block Size", selection: model.configBinding(\.blockSize)) {
            ForEach(blockSizes, id: \.self) { size in
                Text("\(size)").tag(size)
            }
        }
        .pickerStyle(.menu)

        Toggle(
            "Auto Start at Launch",
            isOn: model.configBinding(\.rdsAutoStart, runtimeDisposition: .none))

        InlineRestartRequiredNote(
            text: "Sample rate, block size, operating mode, and input/output/monitor device changes."
        )
    }
}

#endif  // os(macOS)
