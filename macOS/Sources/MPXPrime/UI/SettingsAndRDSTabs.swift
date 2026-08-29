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

struct LevelsOnlyView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MonitoringWindowHeader(
                    title: kLevelsWindowTitle,
                    subtitle: "Input, post-AGC, and output meters."
                )
                LevelsCardView(model: model)
            }
            .padding(20)
        }
    }
}

struct SystemSettingsSectionContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    private let sampleRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    private let blockSizes: [Int] = [256, 512, 1024, 2048, 4096, 8192]

    var body: some View {
        Group {
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

            // Mono Mode lives in the sidebar footer. Pilot Level is the
            // only stereo-encoder-structure parameter exposed here.
            // Sum/diff matrix gains are spec-fixed (M=(L+R)/2, S=(L-R)/2
            // per ITU-R BS.450 / EN 50067) and not user-configurable;
            // INI keys `sum_level` / `diff_level` remain for lab/debug use.
            // Pilot Level range follows ITU-R BS.450-4 / FCC 73.322 (8-10%
            // deviation); slider permits 0-12% for headroom and 0 = mute.
            // Pilot is a composite-only subcarrier; no pilot in processed-audio output.
            if !model.processedAudioOutputActive {
                DoubleSliderRow(
                    title: "Pilot Level", value: model.pilotLevelPercentBinding(),
                    range: 0...12, format: "%.1f %%",
                    restartRequired: true)
                .disabled(model.config.monoMode)
            }

            InlineRestartRequiredNote(
                text: model.processedAudioOutputActive
                    ? "Sample rate, block size, output mode, pre-emphasis, program lowpass, and other encoder-structure changes."
                    : "Sample rate, block size, mono mode, pre-emphasis, pilot level, program lowpass, and other encoder-structure changes."
            )
        }
    }
}

struct InterfacesSettingsSectionContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Group {
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

                Picker(
                    "MPX Output Device",
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

            Picker(
                "Monitor Output Device (Decoded MPX Simulation)",
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

            Toggle(
                "Enable Monitor Output",
                isOn: Binding(
                    get: { model.monitorEnabled },
                    set: {
                        model.monitorEnabled = $0
                        model.persistBasicConfig()
                    }
                ))

            Text("When Enable Monitor Output is on, this device is used for decoded MPX monitoring.")
                .font(.caption)
                .foregroundStyle(.secondary)

            InlineRestartRequiredNote(
                text: "Source mode, monitor output routing, and input/output/monitor device changes."
            )
        }
    }
}

struct RDSProgramTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Program Service") {
            PSBankRow(letter: "A", model: model, path: \.rdsPSA)
            PSBankRow(letter: "B", model: model, path: \.rdsPSB)
            PSBankRow(letter: "C", model: model, path: \.rdsPSC)
            PSBankRow(letter: "D", model: model, path: \.rdsPSD)
            Picker("Program Type (PTY)", selection: model.ptyBinding()) {
                ForEach(model.ptyChoices, id: \.0) { pty in
                    Text("\(pty.0) · \(pty.1)").tag(pty.0)
                }
            }
            DisclosureGroup("PS Display") {
                Toggle("Center PS", isOn: model.configBinding(\.rdsPSCentered, runtimeDisposition: .liveRDS))
                DoubleSliderRow(
                    title: "PS Frame",
                    value: model.configBinding(\.rdsPSFrameSeconds, runtimeDisposition: .liveRDS),
                    range: 0.5...10.0,
                    format: "%.1f s")
                .help("Default seconds each PS chunk is shown when the source has no explicit Ns: timing marker. Typical broadcast cadence is 3 s. Per-segment markers like 4s:NEWS still override this.")
                Toggle("Enable PTYN", isOn: model.configBinding(\.rdsEnablePTYN, runtimeDisposition: .liveRDS))
                RDSCountedField(placeholder: "PTYN", text: model.configBinding(\.rdsPTYN, runtimeDisposition: .liveRDS), maxChars: 8)
                Toggle("Center PTYN", isOn: model.configBinding(\.rdsPTYNCentered, runtimeDisposition: .liveRDS))
            }
            DisclosureGroup("Station Identity") {
                LabeledContent("PI Code") {
                    HexCodeField(text: model.piBinding(), placeholder: "0000", width: 72)
                }
                .help("Program Identification: the unique 16-bit hex station ID a receiver uses to recognize this station and follow it across alternative frequencies (AF). Assigned by your national broadcast authority; in RBDS it is derived from the call sign.")
                LabeledContent("ECC") {
                    HexCodeField(text: model.hexByteBinding(\.rdsECC), placeholder: "E3", width: 54)
                }
                .help("Extended Country Code: one hex byte that, combined with the PI country nibble, uniquely identifies the country. Lets receivers distinguish countries that share a PI prefix. Default E3 is the Netherlands; set the value for your country (e.g. E0 Italy, E1 UK/France, E2 Spain).")
                LabeledContent("LIC") {
                    HexCodeField(text: model.hexByteBinding(\.rdsLIC), placeholder: "1D", width: 54)
                }
                .help("Language Identification Code: one hex byte naming the programme language, sent in Group 1A alongside the ECC. Independent of country. Default 1D is Dutch; e.g. 15 Italian, 09 English, 0F French, 08 German, 0A Spanish.")
                Toggle("Enable PIN (1A)", isOn: model.configBinding(\.rdsEnablePIN, runtimeDisposition: .liveRDS))
                    .help("Programme Item Number, Group 1A block 4: the scheduled start (day-of-month / hour / minute) of the current programme item. Legacy -- rarely decoded by modern receivers; off transmits 0.")
                if model.config.rdsEnablePIN {
                    HStack(spacing: 14) {
                        Stepper("Day \(model.config.rdsPINDay)",
                                value: model.configBinding(\.rdsPINDay, runtimeDisposition: .liveRDS), in: 1...31)
                        Stepper("Hour \(model.config.rdsPINHour)",
                                value: model.configBinding(\.rdsPINHour, runtimeDisposition: .liveRDS), in: 0...23)
                        Stepper("Min \(model.config.rdsPINMinute)",
                                value: model.configBinding(\.rdsPINMinute, runtimeDisposition: .liveRDS), in: 0...59)
                    }
                    .font(.callout)
                }
                Picker("PTY Region", selection: model.configBinding(\.rdsPtyRBDS, runtimeDisposition: .none)) {
                    Text("Europe (RDS)").tag(false)
                    Text("USA (RBDS)").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Selects which genre table labels the PTY code above. The transmitted 5-bit PTY value is identical either way -- Europe (RDS, EN 50067) and North America (RBDS, NRSC-4) just name the same code differently, and receivers pick the table by region. Same number, different genre: e.g. 10 reads as Pop Music on RDS but Country on RBDS.")
            }
        }

        // Per-program operational flags. Live-applied; UECP MEC 0x0E
        // (TA) flips edge-triggered during a traffic announcement.
        // Commercial RDS encoder convention (P164, SmartGen, Audemat,
        // every UECP encoder) places these alongside PI / PS / PTY in
        // the Basic/Identity tab — they describe "what this station is
        // broadcasting right now", not encoder control.
        Card(title: "Runtime Flags") {
            LazyVGrid(columns: [
                GridItem(.flexible(minimum: 100)),
                GridItem(.flexible(minimum: 100)),
                GridItem(.flexible(minimum: 100))
            ], alignment: .leading, spacing: 8) {
                Toggle("TP", isOn: model.configBinding(\.rdsTP, runtimeDisposition: .liveRDS))
                    .help("Traffic Program: this station carries traffic announcements from time to time.")
                Toggle("TA", isOn: model.configBinding(\.rdsTA, runtimeDisposition: .liveRDS))
                    .help("Traffic Announcement: flip on for the duration of a traffic bulletin so TA-enabled receivers switch to it, then flip off.")
                Toggle("MS", isOn: model.configBinding(\.rdsMS, runtimeDisposition: .liveRDS))
                    .help("Music / Speech: tells receivers whether the current program is music (on) or speech (off).")
            }
            .toggleStyle(.switch)
            DisclosureGroup("Decoder Info (DI)") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("DI Stereo", isOn: model.configBinding(\.rdsDI_STEREO, runtimeDisposition: .liveRDS))
                        .help("Decoder Identification: tells receivers the broadcast is stereo (off = mono). Set this to match the actual program.")
                    Toggle("DI Head", isOn: model.configBinding(\.rdsDI_HEAD, runtimeDisposition: .liveRDS))
                        .help("Decoder Identification: signals artificial-head (binaural) audio. Leave off for normal stereo program.")
                    Toggle("DI Comp", isOn: model.configBinding(\.rdsDI_COMP, runtimeDisposition: .liveRDS))
                        .help("Decoder Identification: signals the audio is compressed/companded (an obsolete noise-reduction scheme). Leave off for normal program.")
                    Toggle("DI Dyn PTY", isOn: model.configBinding(\.rdsDI_DYN, runtimeDisposition: .liveRDS))
                        .help("Decoder Identification: marks the Program Type as dynamically changing (varies through the broadcast) rather than fixed for the station.")
                }
                .toggleStyle(.switch)
            }
            Text("Per-program flags. Applied live without restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct PSBankRow: View {
    let letter: String
    @ObservedObject var model: MPXPrimeViewModel
    let path: WritableKeyPath<AppConfig, String>

    var body: some View {
        let isActive = model.config.rdsPSActiveBank.uppercased() == letter
        HStack(spacing: 10) {
            Button {
                model.setConfigValue(\.rdsPSActiveBank, letter, runtimeDisposition: .liveRDS)
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive ? "PS bank \(letter) active" : "Activate PS bank \(letter)")
            .help("Make PS \(letter) the active bank")

            Text("PS \(letter)")
                .frame(width: 40, alignment: .leading)
                .font(.callout.monospaced())
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

            RDSCountedField(placeholder: "", text: model.configBinding(path, runtimeDisposition: .liveRDS), maxChars: 8)
        }
    }
}

/// RDS text entry with a live character counter. RDS fields have hard
/// length limits (PS 8, PTYN 8, Long PS 32, RadioText 64); past the limit
/// the encoder silently truncates. The trailing `n/max` counter turns amber
/// once the field reaches the limit so the operator sees it before air.
struct RDSCountedField: View {
    let placeholder: String
    let text: Binding<String>
    let maxChars: Int

    var body: some View {
        let count = text.wrappedValue.count
        let atLimit = count >= maxChars
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            Text("\(count)/\(maxChars)")
                .font(BroadcastStyle.scaleLabel)
                .monospacedDigit()
                .foregroundStyle(atLimit ? BroadcastStyle.tightAmber : .secondary)
                .accessibilityLabel("\(count) of \(maxChars) characters")
        }
    }
}

struct HexCodeField: View {
    let text: Binding<String>
    let placeholder: String
    let width: CGFloat

    var body: some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.tertiary))
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width)
            .background(BroadcastStyle.meterSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(BroadcastStyle.panelBorder, lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .textSelection(.enabled)
    }
}

struct RDSRadiotextTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Radiotext & RT+") {
            RDSCountedField(placeholder: "Single Radiotext", text: model.configBinding(\.rdsRTText, runtimeDisposition: .liveRDS), maxChars: 64)
            Text("Used when no RT buffer entries are checked.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("RT Buffers")
                    .font(.headline)
                Text("Checked messages are active. If multiple are checked, they rotate in order using Cycle Time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        Toggle(
                            "Msg \(index + 1)",
                            isOn: model.rtBufferEnabledBinding(index)
                        )
                        .toggleStyle(.checkbox)
                        .frame(width: 72, alignment: .leading)
                        TextField(
                            "Radiotext message \(index + 1)",
                            text: model.rtBufferTextBinding(index)
                        )
                    }
                }
                if model.enabledRTBufferIndices.isEmpty {
                    Text("No checked RT messages. Legacy single-field Radiotext will be used until you enable one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            Picker("RT Mode", selection: model.configBinding(\.rdsRTMode, runtimeDisposition: .liveRDS)) {
                Text("2A (64 chars)").tag("2A")
                Text("2B (32 chars)").tag("2B")
            }
            .pickerStyle(.segmented)
            DoubleSliderRow(
                title: "Cycle Time", value: model.configBinding(\.rdsRTCycleTime, runtimeDisposition: .liveRDS),
                range: 1...20, format: "%.1f s")
            Toggle("Center RT", isOn: model.configBinding(\.rdsRTCentered, runtimeDisposition: .liveRDS))
            Toggle("Append CR", isOn: model.configBinding(\.rdsRTCR, runtimeDisposition: .liveRDS))
            Toggle("Enable RT+", isOn: model.configBinding(\.rdsEnableRTPlus, runtimeDisposition: .liveRDS))
            Text(
                "RT+ tags the song inside the RadioText -- by the RDS standard it cannot send "
                + "Artist/Title unless that text is actually in an RT message. To show Artist/Title "
                + "on receivers: (1) enable the Now Playing Script below, and (2) put "
                + "\"{artist} - {title}\" (or {now_playing}) in the Single Radiotext field or one of "
                + "the RT Buffer messages above. RT+ receivers then show Artist and Title in their "
                + "own fields (and cache them while other messages scroll). Tip: keep always-on "
                + "station identity in PS / Long PS, not RadioText."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            Toggle(
                "Enable Now Playing Script",
                isOn: model.configBinding(\.rdsNowPlayingEnabled, runtimeDisposition: .none))
            LabeledContent("Script Path") {
                HStack(spacing: 8) {
                    TextField(
                        "",
                        text: model.configBinding(\.rdsNowPlayingScript, runtimeDisposition: .none)
                    )
                    Button("Browse") {
                        model.chooseNowPlayingScript()
                    }
                    .buttonStyle(.bordered)
                }
            }
            DoubleSliderRow(
                title: "Poll Interval",
                value: model.configBinding(\.rdsNowPlayingPollSeconds, runtimeDisposition: .none),
                range: 1...60,
                format: "%.1f s"
            )
            DoubleSliderRow(
                title: "Script Timeout",
                value: model.configBinding(\.rdsNowPlayingTimeoutSeconds, runtimeDisposition: .none),
                range: 0.2...10,
                format: "%.1f s"
            )
            Text("Macros: {now_playing}, {artist}, {title}, {display}, {date}, {time}")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.value(for: \.rdsNowPlayingEnabled) {
                Text("The now-playing script fills the {artist} / {title} macros; RT+ tags them wherever they appear in your RadioText (Single Radiotext or an RT Buffer).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("RT+ Format A", text: model.configBinding(\.rdsRTPlusFormatA, runtimeDisposition: .liveRDS))
                TextField("RT+ Format B", text: model.configBinding(\.rdsRTPlusFormatB, runtimeDisposition: .liveRDS))
            }
            LiveObservationView(telemetry: model.telemetry) { t in
                Text(t.rdsNowPlayingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct RDSLongPSTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Long PS") {
            Toggle("Enable Long PS (15A)", isOn: model.configBinding(\.rdsEnableLPS, runtimeDisposition: .liveRDS))
            RDSCountedField(placeholder: "Long PS Text", text: model.configBinding(\.rdsLongPS32, runtimeDisposition: .liveRDS), maxChars: 32)
            Toggle("Center Long PS", isOn: model.configBinding(\.rdsLPSCentered, runtimeDisposition: .liveRDS))
            Toggle("Append CR", isOn: model.configBinding(\.rdsLPSCR, runtimeDisposition: .liveRDS))
        }
    }
}

struct RDSCarrierTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // Physical-layer settings for the 57 kHz subcarrier:
        // amplitude (injection level), frequency, and Gaussian shaping.
        // All restart-required; live-apply RDS data lives on the
        // Identity / Radiotext / Schedule tabs.
        Card(title: "Subcarrier") {
            DoubleSliderRow(
                title: "Injection Level",
                value: model.rdsLevelPercentBinding(),
                range: 0...10, format: "%.1f %%",
                restartRequired: true)
            Text("RDS subcarrier pulse shaping (enable / bandwidth / taps) is tuned at the defaults (on, 2400 Hz, 81 taps) and not exposed in the GUI — power users can adjust via INI keys `rds_gaussian_enabled` / `rds_gaussian_bw_hz` / `rds_gaussian_taps`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Group scheduling, scheduler policy, clock-time (4A) settings.
/// Splits out from the legacy Carrier tab so physical-layer (which
/// requires restart) and group-sequence policy (live-applied via
/// RDSRuntimeConfig) are clearly separated.
struct RDSScheduleTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    // Automatic (recommended) vs Custom. Automatic uses the standard
    // IEC 62106 schedule, auto-derived from the enabled RDS features; Custom
    // uses the manual group sequence. Mapped onto the existing scheduler
    // flags so existing INIs keep working unchanged -- the manual sequence is
    // active only when both Standard and Auto are off.
    private var useCustomSequence: Binding<Bool> {
        Binding(
            get: { !model.config.rdsSchedulerStandard && !model.config.rdsSchedulerAuto },
            set: { custom in
                model.setConfigValue(\.rdsSchedulerStandard, !custom, runtimeDisposition: .liveRDS)
                model.setConfigValue(\.rdsSchedulerAuto, !custom, runtimeDisposition: .liveRDS)
            }
        )
    }

    var body: some View {
        Card(title: "Group Schedule") {
            Toggle("Custom group sequence", isOn: useCustomSequence)
                .help("Off (recommended): MPX Prime schedules RDS groups automatically at IEC 62106 group rates, derived from the features you enable (PS, RadioText, RT+, Clock-Time, AF, PTYN, Long PS). On: transmit exactly the group list you specify.")
            if useCustomSequence.wrappedValue {
                TextField(
                    "Group Sequence",
                    text: model.configBinding(\.rdsGroupSequence, runtimeDisposition: .liveRDS))
                    .textFieldStyle(.roundedBorder)
                Text("Space-separated groups, e.g. 0A 0A 2A 3A 11A. Advanced override -- you are responsible for including every group your enabled features need.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Automatic (recommended): the group mix follows IEC 62106 group rates and updates as you enable RDS features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Card(title: "Clock Time (4A)") {
            Toggle("Enable CT (4A)", isOn: model.configBinding(\.rdsEnableCT, runtimeDisposition: .liveRDS))
            Toggle("Enable ID (1A)", isOn: model.configBinding(\.rdsEnableID, runtimeDisposition: .liveRDS))
            DoubleSliderRow(
                title: "Clock Offset",
                value: model.configBinding(\.rdsTZOffset, runtimeDisposition: .liveRDS),
                range: -12...14, format: "%.1f h")
        }
    }
}

/// Alternative Frequencies (AF). Split out from the legacy Flags tab
/// because UECP makes AF a peer of PS (its own MEC), not a Flags
/// sibling. Method A vs B + comma-separated frequency list.
struct RDSAFTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Card(title: "Alternative Frequencies") {
            Toggle(
                "Enable AF",
                isOn: model.configBinding(\.rdsEnableAF, runtimeDisposition: .liveRDS))
            HStack(spacing: 12) {
                Picker(
                    "AF Method",
                    selection: model.configBinding(\.rdsAFMethod, runtimeDisposition: .liveRDS)
                ) {
                    Text("Method A").tag("A")
                    Text("Method B").tag("B")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                TextField(
                    "AF List",
                    text: model.configBinding(\.rdsAFList, runtimeDisposition: .liveRDS)
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }
}

/// Status-first dashboard for the RDS subsystem. Operationally the
/// landing page: master Enable, current modulation %, live PI / PS /
/// RT readout, and operator toggles for TP / TA / MS / DI flags +
/// RT+ Item Toggle / Item Running. Detail tabs handle setup; this
/// tab handles "is it working right now".
struct RDSStatusTab: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        // Master kill switch + live monitoring view. Commercial
        // RDS-encoder convention (DEVA SmartGen, RDS Manager,
        // Audemat) calls this tab "Status". Per-program flags now
        // live on Identity; subcarrier injection now lives on
        // Subcarrier.
        Card(title: "Master") {
            Toggle(
                "Enable RDS",
                isOn: model.configBinding(\.enRDS, runtimeDisposition: .liveRDS))
            Text("Master enable applies live. Subcarrier-physical-layer settings (injection level, frequency, pulse shaping) live on the Subcarrier tab and require a transport restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Card(title: "Snapshot", style: .meter) {
            RDSLivePreviewPlate(model: model)
        }
    }
}

/// Output-mode selector: FM composite (default) vs processed stereo audio for
/// feeding an external stereo coder. Restart-required. When processed-audio is
/// selected, the composite clipper / BS.412 / RDS surfaces are hidden elsewhere
/// in the UI, and the pre-emphasis-ownership guidance below becomes critical.
struct OutputModeSettingsSectionContent: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Picker(
            selection: model.configBinding(\.processedAudioOutput, runtimeDisposition: .restart)
        ) {
            Text("MPX Composite").tag(false)
            Text("Processed Audio").tag(true)
        } label: {
            HStack(spacing: 6) {
                Text("Output")
                RestartBadge()
            }
        }
        .pickerStyle(.segmented)
        .help("MPX Composite: the FM multiplex (pilot + stereo + RDS) for a transmitter / exciter that accepts composite. Processed Audio: processed stereo L/R for an external stereo coder + RDS encoder. Restart required.")

        if model.processedAudioOutputActive {
            Text("Emitting processed stereo L/R for an external stereo coder. The composite clipper, BS.412, pilot, and RDS are bypassed and hidden. Recommended output: 48 kHz / 24-bit.")
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
    }
}

struct SettingsSectionView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        Form {
            Section("Configuration") {
                LabeledContent("Path") {
                    Text(model.configFilePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Button("Reveal Config") { model.revealConfigInFinder() }
                        .buttonStyle(.bordered)
                    Button("Reload Config") { model.reloadConfigFromDisk() }
                        .buttonStyle(.bordered)
                    Button("Refresh Devices") { model.refreshDevices() }
                        .buttonStyle(.bordered)
                }
            }

            Section("Interfaces") {
                InterfacesSettingsSectionContent(model: model)
            }

            Section("Output Mode") {
                OutputModeSettingsSectionContent(model: model)
            }

            Section("Audio Engine") {
                SystemSettingsSectionContent(model: model)
            }

            Section("Spectrum") {
                Toggle("96 kHz Window", isOn: model.configBinding(\.fftWindow96kHz))
                Text("When enabled, shows full 96 kHz spectrum. When disabled, shows the 60 kHz FM band.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remote Control") {
                Toggle(
                    "Enable REST API + Web Dashboard",
                    isOn: model.configBinding(\.controlEnabled, runtimeDisposition: .none)
                )
                .help("Serves a control API and web dashboard over HTTP. Applied at the next app launch.")
                LabeledContent("Address") {
                    TextField(
                        "127.0.0.1",
                        text: model.configBinding(\.controlBind, runtimeDisposition: .none)
                    )
                    .frame(maxWidth: 180)
                    .help("Interface to listen on. 127.0.0.1 = this Mac only; 0.0.0.0 = all interfaces (requires an API key).")
                }
                LabeledContent("Port") {
                    TextField(
                        "8737",
                        value: model.configBinding(\.controlPort, runtimeDisposition: .none),
                        format: .number.grouping(.never)
                    )
                    .frame(maxWidth: 100)
                    .help("TCP port for the control server (default 8737).")
                }
                LabeledContent("API Key") {
                    TextField(
                        "required for non-local access",
                        text: model.configBinding(\.controlAPIKey, runtimeDisposition: .none)
                    )
                    .frame(maxWidth: 260)
                    .help("Clients send this as 'Authorization: Bearer <key>' or 'X-API-Key'. Mandatory when the address is not 127.0.0.1; the server refuses to start remote-exposed without one.")
                }
                Text("Changes take effect at the next app launch. For access beyond the local network, front with a TLS reverse proxy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 920, alignment: .topLeading)
        .padding(.horizontal, 10)
        .controlSize(.small)
    }
}

struct SettingsWindowView: View {
    @ObservedObject var model: MPXPrimeViewModel

    var body: some View {
        SettingsSectionView(model: model)
            .navigationTitle("Settings")
    }
}

#endif  // os(macOS)
