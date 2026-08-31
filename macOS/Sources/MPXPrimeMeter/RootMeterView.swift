import CoreAudio
import MPXPrimeUI
import SwiftUI

// Single-window Meter dashboard: input controls, level meters + deviation,
// scopes, spectrum, and an RDS panel. Per-tick graphics are wrapped in
// LiveObservationView(vm.telemetry) so a 25 Hz refresh repaints only those
// Canvas leaves, not the window (the freeze-prevention rule).
struct RootMeterView: View {
    @ObservedObject var vm: MeterViewModel

    // Click a decoded scope to switch it between waveform and audio spectrum.
    @State private var decodedLSpectrum = false
    @State private var decodedRSpectrum = false
    @State private var showOutputs = false

    // Bridge an Int binding to the Double-valued ScrollableNumericField so the
    // integer SDR steppers (LNA, PPM) also adjust on scroll, like Frequency/Gain.
    private static func intBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) },
                set: { b.wrappedValue = Int($0.rounded()) })
    }

    var body: some View {
        // Fluid, non-scrolling dashboard: fixed-height analysis rows on top,
        // the MPX spectrum (the centerpiece) takes ALL remaining height. The
        // ScrollView only engages as a fallback when the window is squeezed
        // below the content minimum -- on a normal screen nothing scrolls.
        GeometryReader { geo in
            VStack(spacing: 0) {
                inputConfigBar
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            audioSection
                            deviationSection
                            // Two-column grid, sized so the widest readouts
                            // ("+12.0 dBr  max +12.0" / "+199.9 / -199.9 kHz")
                            // never truncate.
                            metricsSection
                                .frame(width: 420)
                            // RDS is a key/value text grid: cap it at a
                            // comfortable reading width instead of swallowing
                            // all remaining row width on wide displays.
                            rdsSection
                                .frame(minWidth: 260, maxWidth: 760)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 220)
                        HStack(alignment: .top, spacing: 12) {
                            vectorscopeSection
                            // Reception/chain quality: three scalars, fixed
                            // width so the trends keep the flexible space.
                            qualitySection
                                .frame(width: 210)
                            trendsSection
                                .frame(maxWidth: .infinity)
                        }
                        .frame(height: 248)
                        scopesSection
                        spectrumSection
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    }
                    .padding(12)
                    .frame(minWidth: 1260, minHeight: max(760, geo.size.height - 44))
                }
            }
        }
        .toolbar { toolbarContent }
    }

    // MARK: - Input configuration bar
    //
    // Per-source input settings live here in the content area, not the title
    // bar (HIG: the toolbar carries the few frequent commands -- Start/Stop,
    // Source, Monitor -- while the source's detailed parameters belong in the
    // window). A translucent `.bar` material separates it from the dashboard
    // without painting a hard slab.

    private var inputConfigBar: some View {
        HStack(spacing: 12) {
            if vm.inputKind == .audioDevice {
                Label("Device", systemImage: "waveform")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                Picker("Input", selection: $vm.selectedInputID) {
                    ForEach(vm.inputDevices) { dev in
                        Text(dev.name).tag(Optional(dev.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .help("Audio input device carrying the MPX composite.")
                .onChange(of: vm.selectedInputID) { _, _ in vm.restartIfRunning() }

                Picker("Channel", selection: $vm.channel) {
                    Text("L").tag(MeterChannel.left)
                    Text("R").tag(MeterChannel.right)
                    Text("Mix").tag(MeterChannel.mix)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Which input channel carries the composite (Mix averages both).")
                .onChange(of: vm.channel) { _, _ in vm.restartIfRunning() }

                Divider().frame(height: 16)

                // Audio deviation calibration. The audio-input path has no
                // absolute level reference, so deviation must be anchored either
                // to the pilot (assumed kHz) or to an absolute "0 dBFS = N kHz"
                // scale set against a known input level (the robust mode -- it is
                // independent of pilot recovery, as MPXTool-style monitors do).
                Picker("Calibrate", selection: $vm.audioAbsoluteCal) {
                    Text("Pilot").tag(false)
                    Text("0 dBFS").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .help("Deviation calibration for the audio input. Pilot: scale from "
                    + "the 19 kHz pilot's assumed deviation. 0 dBFS: absolute scale "
                    + "from a known input level (independent of pilot recovery). "
                    + "The SDR path is always absolute and ignores this.")
                .onChange(of: vm.audioAbsoluteCal) { _, _ in vm.applyCalibrationChange() }

                if vm.audioAbsoluteCal {
                    HStack(spacing: 4) {
                        Text("0 dBFS =").foregroundStyle(.secondary)
                        ScrollableNumericField(value: $vm.audioFullScaleKHz,
                                               range: 50.0...300.0, step: 1.0, decimals: 0)
                            .frame(width: 50)
                        Text("kHz").foregroundStyle(.secondary)
                            .fixedSize()
                        Stepper("Full scale", value: $vm.audioFullScaleKHz,
                                in: 50.0...300.0, step: 1.0)
                            .labelsHidden()
                    }
                    .onChange(of: vm.audioFullScaleKHz) { _, _ in vm.applyCalibrationChange() }
                    .help("Absolute scale: the FM deviation when the composite hits "
                        + "0 dBFS. Feed 75 kHz at -6 dBFS -> set 150. Deviation then "
                        + "comes straight off the input level. Scroll to step. Live.")
                } else {
                    HStack(spacing: 4) {
                        Text("Pilot Ref").foregroundStyle(.secondary)
                        ScrollableNumericField(value: $vm.pilotRefKHz,
                                               range: 4.0...9.0, step: 0.05, decimals: 2)
                            .frame(width: 48)
                        Text("kHz").foregroundStyle(.secondary)
                            .fixedSize()
                        Stepper("Pilot Ref", value: $vm.pilotRefKHz, in: 4.0...9.0, step: 0.05)
                            .labelsHidden()
                    }
                    .onChange(of: vm.pilotRefKHz) { _, _ in vm.applyPilotRefChange() }
                    .help("Pilot deviation the audio-input path scales from. Set it to "
                        + "the source's real pilot deviation -- 6.75 kHz is 9%, but "
                        + "many stations differ. Scroll to step. Applied live.")
                }
            } else {
                if vm.sdrDevices.count > 1 {
                    // Multi-SDR bench: pick the unit (persisted by serial, so
                    // the choice survives replug; two Meter instances can each
                    // grab a different unit).
                    Label("SDR", systemImage: "dot.radiowaves.left.and.right")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                    Picker("SDR device", selection: $vm.selectedSDRID) {
                        Text("Auto").tag(String?.none)
                        ForEach(vm.sdrDevices) { dev in
                            Text(dev.displayName).tag(Optional(dev.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .help("Which SDR to capture from when several are attached "
                        + "(multiple RSPs / RTL dongles supported). Remembered by "
                        + "serial number. Auto prefers SDRplay. Launch the app "
                        + "twice to run two meters on two units.")
                    .onChange(of: vm.selectedSDRID) { _, _ in vm.applySDRDeviceChange() }
                    Divider().frame(height: 16)
                } else if !vm.sdrDeviceName.isEmpty {
                    Label(vm.sdrDeviceName, systemImage: "dot.radiowaves.left.and.right")
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.semibold))
                        .help("Active SDR device (auto-selected).")
                    Divider().frame(height: 16)
                } else {
                    Label("Frequency", systemImage: "dot.radiowaves.left.and.right")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
                frequencyField

                Divider().frame(height: 16)

                Toggle("Auto Gain", isOn: $vm.sdrAutoGain)
                    .toggleStyle(.switch)
                    .help(vm.sdrIsSDRplay
                        ? "SDRplay AGC on the IF gain. The LNA is set separately. Applied live."
                        : "Tuner automatic gain. Off = manual gain (dB field). Applied live.")
                    .onChange(of: vm.sdrAutoGain) { _, _ in vm.applyGainChange() }
                // Manual gain when Auto Gain is off: RTL tuner gain (dB), or
                // SDRplay IF gain. (SDRplay's front-end LNA has its own stepper.)
                if !vm.sdrAutoGain {
                    HStack(spacing: 4) {
                        ScrollableNumericField(value: $vm.sdrGainDB,
                                               range: 0.0...50.0, step: 1.0, decimals: 1)
                            .frame(width: 52)
                        Text(vm.sdrIsSDRplay ? "IF" : "dB").foregroundStyle(.secondary)
                            .fixedSize()
                        Stepper("Gain", value: $vm.sdrGainDB, in: 0.0...50.0, step: 1.0)
                            .labelsHidden()
                    }
                    .onChange(of: vm.sdrGainDB) { _, _ in vm.applyGainChange() }
                    .help(vm.sdrIsSDRplay
                        ? "Manual IF gain (higher = more gain). Scroll to step. Applied live."
                        : "Manual RTL-SDR tuner gain in dB. Scroll to step. Applied live.")
                }
                // SDRplay front-end LNA step (independent of AGC; raise to fix overload).
                if vm.sdrIsSDRplay {
                    HStack(spacing: 4) {
                        Text("LNA").foregroundStyle(.secondary)
                        ScrollableNumericField(value: Self.intBinding($vm.sdrLnaState),
                                               range: 0...27, step: 1, decimals: 0)
                            .frame(width: 34)
                        Stepper("LNA", value: $vm.sdrLnaState, in: 0...27, step: 1)
                            .labelsHidden()
                    }
                    .onChange(of: vm.sdrLnaState) { _, _ in vm.applyLnaChange() }
                    .help("LNA state: front-end gain-reduction step (0 = most gain). "
                        + "Raise it to relieve overload on strong signals. Scroll to step. "
                        + "Applied live.")
                }

                Divider().frame(height: 16)

                // SDRplay exposes its analog IF filter widths; RTL uses the demod
                // channel-FIR steps. Scrollable so the IF can be dialled in/out
                // without opening the menu.
                ScrollableMenuPicker(
                    options: [(label: "Auto", tag: 0)]
                        + (vm.sdrIsSDRplay ? [1536, 600, 300, 200]
                                           : [311, 254, 200, 168, 133, 114, 84, 56])
                            .map { (label: "\($0) kHz", tag: $0) },
                    selection: $vm.sdrBandwidthKHz)
                    .fixedSize()
                    .help(vm.sdrIsSDRplay
                    ? "SDRplay analog IF bandwidth. Narrower rejects adjacent-station "
                        + "interference; 300 kHz still passes the full composite, 200 kHz "
                        + "starts to roll off the top (SCA / high RDS). Auto = 600 kHz."
                    : "IF channel bandwidth. Wide passes the full composite (RDS/SCA) with "
                        + "more noise; narrow rejects adjacent channels but rolls off the "
                        + "composite top. Auto = widest.")
                .onChange(of: vm.sdrBandwidthKHz) { _, _ in vm.applyBandwidthChange() }

                if vm.sdrIsSDRplay && vm.sdrAntennaCount > 1 {
                    Divider().frame(height: 16)
                    Picker("Antenna", selection: $vm.sdrAntenna) {
                        ForEach(0..<vm.sdrAntennaCount, id: \.self) { i in
                            Text("Ant \(["A", "B", "C"][min(i, 2)])").tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .labelsHidden()
                    .help("SDRplay antenna input.")
                    .onChange(of: vm.sdrAntenna) { _, _ in vm.applyAntennaChange() }
                }

                Divider().frame(height: 16)

                if !vm.sdrIsSDRplay {
                    HStack(spacing: 4) {
                        Text("PPM").foregroundStyle(.secondary)
                        ScrollableNumericField(value: Self.intBinding($vm.sdrPPM),
                                               range: -200...200, step: 1, decimals: 0)
                            .frame(width: 44)
                        Stepper("PPM", value: $vm.sdrPPM, in: -200...200, step: 1)
                            .labelsHidden()
                    }
                    .onChange(of: vm.sdrPPM) { _, _ in vm.applyPPMChange() }
                    .help("Frequency-error correction in ppm. Scroll to step. Applied live.")
                }

                // Signal-level units + the calibration that makes the
                // absolute ones absolute. Sits with the other SDR front-end
                // controls, mirroring the audio path's Calibrate picker.
                HStack(spacing: 4) {
                    Text("Signal").foregroundStyle(.secondary).fixedSize()
                    Picker("Signal unit", selection: $vm.signalUnit) {
                        ForEach(SignalUnit.allCases) { u in
                            Text(u.label).tag(u)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if vm.signalUnit.isAbsolute {
                        ScrollableNumericField(value: $vm.signalCalibrationDB,
                                               range: -60.0...60.0, step: 0.5, decimals: 1)
                            .frame(width: 52)
                        Text("cal").foregroundStyle(.secondary).fixedSize()
                    }
                }
                .help(Self.signalUnitHelp)

                // IQ capture rate = the RF spectrum's span. RESTART-required
                // (the device is reconfigured at open), like the device picker.
                // It cannot move the MPX measurements: the demod chain runs at
                // its own fixed rate behind a decimator.
                HStack(spacing: 4) {
                    Text("Sample Rate").foregroundStyle(.secondary).fixedSize()
                    Picker("Sample Rate", selection: $vm.sdrIQRateKHz) {
                        Text("Narrow").tag(0)
                        Text("1 MSPS").tag(1000)
                        Text("2 MSPS").tag(2000)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .help(Self.sampleRateHelp)
                .onChange(of: vm.sdrIQRateKHz) { _, _ in vm.restartIfRunning() }

                Toggle("Bias-T", isOn: $vm.sdrBiasTee)
                    .fixedSize()
                    .toggleStyle(.switch)
                    .help("5V bias tee: powers an active antenna / inline LNA. "
                        + "Leave off unless your antenna needs it (never into a DC short). "
                        + "Applied live.")
                    .onChange(of: vm.sdrBiasTee) { _, _ in vm.applyBiasTeeChange() }

                if !vm.sdrIsSDRplay {
                    Toggle("RTL AGC", isOn: $vm.sdrRTLAGC)
                        .toggleStyle(.switch)
                        .help("RTL2832 digital AGC, separate from the tuner gain above. "
                            + "Applied live.")
                        .onChange(of: vm.sdrRTLAGC) { _, _ in vm.applyRTLAGCChange() }
                }
            }
            Spacer()

            dcBlockToggle

            Divider().frame(height: 16)

            // Output routing (both source modes), consolidated in a popover:
            // the decoded-monitor device, and the MPX pass-through (raw
            // composite to its own device). All live-apply.
            Button {
                showOutputs.toggle()
            } label: {
                Label("Outputs", systemImage: "speaker.wave.2")
            }
            .buttonStyle(.bordered)
            .help("Output routing: decoded monitor device, and MPX "
                + "pass-through (raw composite to a second device).")
            .popover(isPresented: $showOutputs, arrowEdge: .bottom) {
                outputsPopover
            }

            Divider().frame(height: 16)

            // Recording: pick the format, then Record to a WAV file.
            Picker("Record format", selection: $vm.recordMPX) {
                Text("Stereo").tag(false)
                Text("MPX").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .disabled(vm.isRecording)
            .help("What Record writes: decoded stereo audio, or the raw MPX composite (mono).")
            Button {
                vm.toggleRecording()
            } label: {
                Label(vm.isRecording ? "Stop" : "Record",
                      systemImage: vm.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(vm.isRecording ? .red : nil)
            .disabled(!vm.running)
            .help("Record the selected format to a WAV file (24-bit, capture rate).")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BroadcastStyle.panelBorder).frame(height: 1)
        }
    }

    // MARK: - Toolbar (HIG: frequent commands live in the unified title bar)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                vm.running ? vm.stop() : vm.start()
            } label: {
                Label(vm.running ? "Stop" : "Start",
                      systemImage: vm.running ? "stop.fill" : "play.fill")
            }
            .help(vm.running ? "Stop capturing (Command-Return)"
                             : "Start capturing (Command-Return)")
            .keyboardShortcut(.return, modifiers: .command)

            Toggle(isOn: $vm.monitorEnabled) {
                Label("Monitor", systemImage: vm.monitorEnabled
                    ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .toggleStyle(.button)
            .help("Play the decoded audio so you hear what a receiver hears.")
            .onChange(of: vm.monitorEnabled) { _, _ in vm.restartIfRunning() }
        }
        ToolbarItemGroup(placement: .principal) {
            if vm.sdrAvailable {
                Picker("Source", selection: $vm.inputKind) {
                    Text("Audio").tag(MeterViewModel.InputKind.audioDevice)
                    Text("SDR").tag(MeterViewModel.InputKind.sdr)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Audio: a Core Audio input device. SDR: a live RTL-SDR "
                    + "station via FM-SDR-Tuner (mono MPX, absolute calibration).")
                .onChange(of: vm.inputKind) { _, _ in vm.restartIfRunning() }
            }
        }
    }

    // MARK: - Audio levels

    private var audioSection: some View {
        GroupBox("Audio (dBFS)") {
            LiveObservationView(telemetry: vm.telemetry) { t in
                HStack(alignment: .top, spacing: 10) {
                    MeterScaleRuler(scale: .dbfs)   // one shared dBFS scale for the group
                    strip("IN", t.inputText, t.inputNorm, .dbfs,
                          "Composite input level (dBFS). Aim for roughly -12 to -6 dBFS peaks; "
                            + "approaching 0 dBFS clips the capture and corrupts every reading.")
                    strip("L", t.leftText, t.leftNorm, .dbfs,
                          "Decoded left-channel audio level (dBFS RMS).")
                    strip("R", t.rightText, t.rightNorm, .dbfs,
                          "Decoded right-channel audio level (dBFS RMS).")
                    strip("M", t.midText, t.midNorm, .dbfs,
                          "Mid / sum (L+R) level. The mono component most receivers hear.")
                    strip("S", t.sideText, t.sideNorm, .dbfs,
                          "Side / difference (L-R) level. Well below Mid = mostly mono; "
                            + "approaching Mid = very wide stereo.")
                    Divider()
                    VStack(spacing: 6) {
                        Text("PHASE CORR").font(BroadcastStyle.chipLabel).foregroundStyle(.secondary)
                        // Hardware-correlation-meter color language: green-ish
                        // (normal) while safely positive, amber near zero, red
                        // when negative (out of phase = mono-compatibility risk).
                        Text(t.correlationText).font(BroadcastStyle.heroReadout)
                            .foregroundColor(
                                t.correlation < 0 ? BroadcastStyle.overRed
                                    : (t.correlation < 0.3 ? BroadcastStyle.tightAmber
                                        : BroadcastStyle.readoutPrimary))
                        Spacer(minLength: 0)
                    }
                    .frame(width: 74)
                    .help("Left/right phase correlation: +1 = mono, ~+0.7-0.95 = normal stereo, "
                        + "~0 = very wide. Negative means L and R are out of phase -- mono "
                        + "receivers cancel the audio; keep it positive.")
                }
                .frame(maxHeight: .infinity)
                .padding(6)
            }
        }
    }

    // MARK: - Stereo vectorscope

    private var vectorscopeSection: some View {
        GroupBox {
            LiveObservationView(telemetry: vm.telemetry) { t in
                VectorscopeView(left: t.decodedLScope, right: t.decodedRScope,
                                zoom: t.vectorZoom)
                    .frame(width: 240)
                    .frame(maxHeight: .infinity)
                    .padding(6)
                    .help("Stereo goniometer of decoded L/R. Vertical line = mono, a tilted "
                        + "line = single channel, a filled field = wide stereo. A horizontal "
                        + "spread warns of out-of-phase (mono-incompatible) audio. The display "
                        + "gain auto-rides the program level so the figure fills the scope "
                        + "(hardware-goniometer style); points past full scale saturate at "
                        + "the field edge.")
            }
        } label: {
            Text("Vectorscope")
        }
    }

    private func strip(
        _ label: String, _ value: String, _ level: Double, _ scale: VerticalMeterStrip.Scale,
        _ help: String = ""
    ) -> some View {
        // Meter strips are scale-less: the Audio group shares one MeterScaleRuler
        // and the deviation bars rely on their limit line + the kHz value below
        // (their three ranges differ, so no single ruler fits).
        VerticalMeterStrip(
            label: label, valueText: value, level: level, peakLevel: nil,
            scale: scale, showScale: false, help: help)
    }

    // MARK: - Deviation meters (pilot / RDS / total)

    private var deviationSection: some View {
        GroupBox("Deviation (kHz)") {
            LiveObservationView(telemetry: vm.telemetry) { t in
                VStack(spacing: 4) {
                HStack(spacing: 10) {
                    strip("PILOT", t.pilotText, t.pilotNorm,
                          .modulationKHz(fullScale: MeterScale.pilotFullKHz, limit: MeterScale.pilotLimitKHz),
                          "19 kHz stereo pilot deviation. Safe range ~6.75-7.5 kHz (8-10% of "
                            + "75 kHz); too low loses stereo lock, too high steals modulation.")
                    strip("RDS", t.rdsText, t.rdsNorm,
                          .modulationKHz(fullScale: MeterScale.rdsFullKHz, limit: nil),
                          "57 kHz RDS subcarrier deviation. Typical 2-4 kHz (~3-5%); below ~1.5 "
                            + "kHz decodes poorly, above ~7.5 kHz wastes deviation.")
                    strip("MAX", t.maxDevText, t.maxDevNorm,
                          .modulationKHz(fullScale: MeterScale.maxFullKHz, limit: MeterScale.maxLimitKHz),
                          "Peak total deviation: the highest excursion in the last second "
                            + "(50 ms peak-hold slots, ITU-R SM.1268 display convention). "
                            + "Must stay at or below 75 kHz; sustained excursions above "
                            + "are over-modulation.")
                }
                .frame(maxHeight: .infinity)
                // AVE / MIN of the same trailing-second slot array MAX comes
                // from. A caption rather than two more bars: they are context
                // for MAX, not independently-scanned levels, and the strips
                // must keep the height.
                Text("AVE / MIN  \(t.aveMinDevText)")
                    .font(BroadcastStyle.chipLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .help("Mean and lowest of the last second's 50 ms peak-hold "
                        + "slots, alongside MAX above. MAX far above AVE means a "
                        + "peaky, lightly-processed signal; MAX close to AVE means "
                        + "a densely-processed one running near its ceiling "
                        + "continuously.")
                }
                .padding(6)
            }
        }
    }

    // MARK: - Reception / chain quality

    private var qualitySection: some View {
        GroupBox("Quality") {
            LiveObservationView(telemetry: vm.telemetry) { t in
                VStack(alignment: .leading, spacing: 12) {
                    if t.inputStalled {
                        Text("NO INPUT")
                            .font(BroadcastStyle.chipLabel)
                            .foregroundColor(BroadcastStyle.overRed)
                            .help("The input device stopped delivering samples while "
                                + "capture is still running (USB power-save, a stalled "
                                + "SDR stream). The readings below are frozen, not live.")
                            .accessibilityLabel("No input: the device stopped delivering samples")
                    }
                    if let warning = t.dropWarningText {
                        Text("SAMPLES DROPPED")
                            .font(BroadcastStyle.chipLabel)
                            .foregroundColor(BroadcastStyle.overRed)
                            .help(warning)
                            .accessibilityLabel(warning)
                    }
                    if t.monoDecode {
                        Text("MONO DECODE")
                            .font(BroadcastStyle.chipLabel)
                            .foregroundColor(BroadcastStyle.tightAmber)
                            .help("A signal is present but the 19 kHz pilot is too weak "
                                + "to recover the stereo subcarrier, so the decoded "
                                + "audio is mono (M only). Deviation, pilot and MPX "
                                + "power stay valid; separation, balance and phase "
                                + "correlation read '--' because they would only "
                                + "describe the mono decode, not the broadcast. A "
                                + "genuinely mono station reads this too.")
                            .accessibilityLabel("Mono decode: pilot too weak for stereo, "
                                + "stereo readouts unavailable")
                    }
                    readout("SIGNAL QUALITY", t.qualityText,
                            valueTint: Self.qualityTint(t.qualityLevel),
                            help: "How much energy sits ABOVE the modulated baseband "
                                + "(over 60 kHz), where nothing is legitimately "
                                + "transmitted -- so it is demod noise and "
                                + "interference, and it is what decides whether the "
                                + "other readings can be trusted. An FM demod's noise "
                                + "rises steeply with frequency, so this band goes bad "
                                + "first: deviation and RDS level lose accuracy before "
                                + "pilot and MPX power do. Reposition the antenna to "
                                + "improve it.")
                    readout("CARRIER OFFSET", t.carrierOffsetText,
                            valueTint: t.carrierOffsetValid
                                ? limitTint(abs(t.carrierOffsetKHz), limit: 2.0, warn: 1.0)
                                : BroadcastStyle.readoutPrimary,
                            help: "Transmitter carrier frequency error: an FM demod "
                                + "turns an offset carrier into composite DC, so this "
                                + "reads it directly. On an audio input it is whatever "
                                + "DC the interface presents instead. Deviation "
                                + "measurements are DC-corrected either way.")
                    if vm.inputKind == .sdr {
                        readout("SYSTEM GAIN", t.systemGainText,
                                help: "Total gain the tuner reports right now -- the term "
                                    + "that converts the channel power into an absolute "
                                    + "dBm / dBuV reading. It moves as AGC and LNA move, "
                                    + "which is why the absolute reading stays valid. "
                                    + "SDRplay reports a true system gain; RTL reports its "
                                    + "tuner stage only.")
                    }
                    readout("L / R BALANCE", t.balanceText,
                            help: "Standing level difference between the decoded "
                                + "channels, heavily smoothed (+ = left louder). Real "
                                + "programme averages to about 0 dB; a persistent "
                                + "offset means the stereo encoder or the audio "
                                + "feeding it is lopsided.")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(6)
            }
        }
    }

    /// Tint for the 0..4 signal-quality scale (higher is better).
    private static func qualityTint(_ level: Int) -> Color {
        switch level {
        case 4, 3: return BroadcastStyle.safeGreen
        case 2: return BroadcastStyle.tightAmber
        default: return BroadcastStyle.overRed
        }
    }

    // Full tuning range of the ACTIVE tuner, not just the 87.5-108 MHz
    // broadcast band: FM-stereo MPX also rides analog audio links and
    // license-exempt stereo transmitters well outside it (e.g. 863-865 /
    // 886 MHz). RTL-SDR (R820T-class) tunes ~24-1766 MHz; SDRplay RSPs go
    // from 1 kHz to 2 GHz. Unsupported tunes fail gracefully in the driver.
    private var tuneRangeMHz: ClosedRange<Double> {
        vm.sdrIsSDRplay ? 0.1...2000.0 : 24.0...1766.0
    }

    private var frequencyHelp: String {
        let range = vm.sdrIsSDRplay
            ? "SDRplay RSP: 0.1-2000 MHz" : "RTL-SDR: 24-1766 MHz"
        return "Tune frequency in MHz, 1 kHz resolution -- the FM broadcast "
            + "band, or any FM-stereo signal in the active tuner's range "
            + "(audio links / license-exempt transmitters, e.g. 864.540). "
            + "\(range). Type with '.' or ',' (scroll steps 0.1 MHz). "
            + "Retunes live, no restart."
    }

    private var frequencyField: some View {
        HStack(spacing: 4) {
            // decimals: 3 gives 1 kHz typing resolution -- broadcast sits on
            // the 100 kHz raster, but audio links do not (e.g. 864.540).
            // Scroll/stepper keep the 0.1 MHz step for band-surfing.
            ScrollableNumericField(value: $vm.frequencyMHz,
                                   range: tuneRangeMHz, step: 0.1, decimals: 3)
                .frame(width: 76)
            Text("MHz").foregroundStyle(.secondary)
                .fixedSize()
            Stepper("Frequency", value: $vm.frequencyMHz,
                    in: tuneRangeMHz, step: 0.1)
                .labelsHidden()
        }
        .onChange(of: vm.frequencyMHz) { _, _ in vm.applyFrequencyChange() }
        .help(frequencyHelp)
    }

    private static let dcBlockHelp = "Remove DC offset from the decoded "
        + "audio (default on). A transmitter carrier offset becomes DC after "
        + "FM demod -- an off-center vectorscope, offset waveforms, and DC in "
        + "the monitor/recordings; common on wireless audio links. Broadcast "
        + "FM has no legitimate DC, so leave it on. Deviation measurements "
        + "are always DC-tracked separately. Applies live."

    private var dcBlockToggle: some View {
        Toggle("DC block", isOn: $vm.dcBlockEnabled)
            .toggleStyle(.checkbox)
            .fixedSize()
            .help(Self.dcBlockHelp)
            .onChange(of: vm.dcBlockEnabled) { _, _ in vm.applyDCBlockChange() }
    }

    // MARK: - Output routing popover

    private var outputsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Monitor (decoded audio)").font(.headline)
                Picker("Monitor output", selection: $vm.selectedOutputID) {
                    Text("System Default").tag(AudioDeviceID?.none)
                    ForEach(vm.outputDevices) { dev in
                        Text(dev.name).tag(Optional(dev.id))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                .help("Where the decoded stereo audio plays. Applies live.")
                .onChange(of: vm.selectedOutputID) { _, _ in vm.applyOutputDeviceChange() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("MPX pass-through (raw composite)", isOn: $vm.mpxPassEnabled)
                    .toggleStyle(.switch)
                    .help("Play the received MPX composite -- pilot, stereo "
                        + "subcarrier, RDS and all -- to its own output device, "
                        + "in addition to the decoded monitor. Feed a 192 kHz "
                        + "DAC into an exciter (rebroadcast/translator) or a "
                        + "hardware analyzer.")
                    .onChange(of: vm.mpxPassEnabled) { _, _ in vm.applyMPXPassChange() }
                Picker("MPX output", selection: $vm.selectedMPXOutID) {
                    Text("System Default").tag(AudioDeviceID?.none)
                    ForEach(vm.outputDevices) { dev in
                        Text(dev.name).tag(Optional(dev.id))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                .disabled(!vm.mpxPassEnabled)
                .help("Where the raw composite plays -- use a genuinely "
                    + "192 kHz-capable interface (its rate is forced to the "
                    + "capture rate while the pass-through runs, and restored "
                    + "after). Applies live; remembered by device UID.")
                .onChange(of: vm.selectedMPXOutID) { _, _ in vm.applyMPXPassChange() }
                HStack(spacing: 4) {
                    Text("Gain").foregroundStyle(.secondary)
                    ScrollableNumericField(value: $vm.mpxPassGainDB,
                                           range: 0.0...12.0, step: 0.5, decimals: 1)
                        .frame(width: 48)
                    Text("dB").foregroundStyle(.secondary).fixedSize()
                    Stepper("MPX gain", value: $vm.mpxPassGainDB,
                            in: 0.0...12.0, step: 0.5)
                        .labelsHidden()
                }
                .disabled(!vm.mpxPassEnabled)
                .onChange(of: vm.mpxPassGainDB) { _, _ in vm.applyMPXPassChange() }
                .help("Output level into the analyzer/exciter. 0 dB = the SDR "
                    + "scaling (0 dBFS = 150 kHz; a 75 kHz station peaks at "
                    + "-6 dBFS). +6 dB puts 75 kHz at digital full scale -- "
                    + "deviation beyond that clips the DAC, so leave ~1 dB "
                    + "headroom (+5 dB covers peaks to ~84 kHz). Applies live.")
                Text("The device is switched to the capture rate (192 kHz) "
                    + "while the pass-through runs, and restored after -- a "
                    + "48 kHz output would lose the pilot and subcarriers. "
                    + "Scale: 0 dBFS = 150 kHz at 0 dB gain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    // Lives in the Modulation card only, with the other standards-compliance
    // readouts -- it was briefly duplicated into the RDS panel too, which just
    // showed the same number twice.
    private static let rdsPhaseHelp = "Angle between the 57 kHz RDS subcarrier "
        + "and the third harmonic of the 19 kHz pilot (EN 50067 sec 1.2). Two "
        + "answers are correct: 0 deg (in phase, the common convention) or "
        + "90 deg (quadrature, BBC practice), each within 10 deg. Anything in "
        + "between means the encoder is not truly pilot-locked -- worth a trim, "
        + "though most receivers recover the subcarrier themselves and decode "
        + "fine either way. Measured off the subcarrier itself, so it reads "
        + "even when the RDS decode is gated; needs a pilot and at least "
        + "0.8 kHz of RDS. Judge a transmitter by it only allowing for the "
        + "path: the standard's tolerance applies at the transmitter's MPX "
        + "input, not off-air."

    // MARK: - Modulation metrics (BS.412 power, peak-hold, separation)

    private var metricsSection: some View {
        GroupBox("Modulation") {
            LiveObservationView(telemetry: vm.telemetry) { t in
                // Two-column grid so the card fills the fixed-height top row
                // compactly instead of stacking one tall airy column (which
                // pushed Reset Peaks below the card). SDR adds SIGNAL as a
                // sixth cell; audio input leaves that cell empty.
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 12) {
                        GridRow {
                            readout("MPX POWER",
                                    t.mpxPowerValid
                                        ? String(format: "%+.1f dBr", t.mpxPowerDBr)
                                            + (t.mpxPowerMaxValid
                                                ? String(format: "  max %+.1f", t.mpxPowerMaxDBr)
                                                : "")
                                        : "--",
                                    valueTint: t.mpxPowerValid
                                        ? limitTint(
                                            max(t.mpxPowerDBr,
                                                t.mpxPowerMaxValid ? t.mpxPowerMaxDBr : -120.0),
                                            limit: 0.0, warn: -1.0)
                                        : BroadcastStyle.readoutPrimary,
                                    help: "ITU-R BS.412 multiplex power: uniform sliding 60 s "
                                        + "window, and (max) the worst 60 s window since reset "
                                        + "-- the number compliance is judged on; it needs a "
                                        + "full 60 s of signal before it reads. 0 dBr is the "
                                        + "power of a +/-19 kHz sine; the regulatory limit is "
                                        + "0 dBr. Needs a calibrated scale (SDR / pilot lock).")
                            readout("PEAK + / -", "\(t.posPeakText) / \(t.negPeakText) kHz",
                                    valueTint: limitTint(max(t.posPeakKHz, -t.negPeakKHz),
                                                         limit: 75.0, warn: 71.0),
                                    help: "Highest positive / negative deviation in the last "
                                        + "60 s (50 ms peak-hold slots, measuring-receiver "
                                        + "style; a single impulse ages out instead of pinning "
                                        + "the reading). A persistent +/- asymmetry suggests a "
                                        + "carrier offset or one-sided clipping.")
                        }
                        GridRow {
                            readout("OVER 77 kHz", t.exceedanceText,
                                    valueTint: t.exceedanceValid
                                        ? limitTint(t.exceedancePct, limit: 0.0001, warn: 0.00005)
                                        : BroadcastStyle.readoutPrimary,
                                    help: "ITU-R SM.1268 deviation compliance: the share of "
                                        + "measured samples above 77 kHz (75 kHz + 2 kHz "
                                        + "tolerance) since the last reset. Regulators treat "
                                        + "more than 0.0001 % as over-deviation; rare single "
                                        + "peaks are not a violation.")
                            readout("SEPARATION", t.separationText,
                                    help: "Best stereo separation observed since reset. Truest "
                                        + "during single-channel / test-tone content; panned "
                                        + "program reads low.")
                        }
                        GridRow {
                            // An RDS parameter, but it belongs with the other
                            // standards-compliance readouts rather than in the
                            // RDS decode panel -- and it is where an operator
                            // coming from a Belar / DEVA looks for it.
                            readout("RDS PHASE", t.rdsPhaseText,
                                    valueTint: t.rdsPhaseOutOfSpec
                                        ? BroadcastStyle.tightAmber
                                        : BroadcastStyle.readoutPrimary,
                                    help: Self.rdsPhaseHelp)
                            if vm.inputKind == .sdr {
                                readout("SIGNAL", t.rssiValid ? t.rssiText : "--",
                                        valueTint: t.rssiValid ? signalTint(t.rssiNorm)
                                            : BroadcastStyle.readoutPrimary,
                                        help: "Relative received signal level (filtered IQ "
                                            + "channel, dBFS). Higher is stronger; most "
                                            + "meaningful with Auto Gain off. A valid BS.412 "
                                            + "MPX-power reading needs a strong, clean signal "
                                            + "-- see the manual.")
                            } else {
                                Color.clear.frame(width: 1, height: 1)
                            }
                        }
                        GridRow {
                            Button("Reset Peaks") { vm.resetPeaks() }
                                .buttonStyle(.bordered)
                                .disabled(!vm.running)
                                .gridColumnAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(6)
            }
        }
    }

    // MARK: - Trends (deviation + MPX power over ~60 s)

    private var trendsSection: some View {
        GroupBox("Trends") {
            LiveObservationView(telemetry: vm.telemetry) { t in
                VStack(spacing: 8) {
                    labeled("Deviation (kHz, ~60 s)") {
                        TrendView(samples: t.devHistoryKHz, minValue: 0, maxValue: 90,
                                  limit: 75, accessibilityName: "Deviation over time")
                    }
                    labeled("MPX Power (dBr, ~60 s)") {
                        TrendView(samples: t.mpxPowerHistoryDBr, minValue: -12, maxValue: 3,
                                  limit: 0, accessibilityName: "MPX power over time")
                    }
                    // Accumulated deviation distribution since the last reset:
                    // the one view that answers "how much of the programme
                    // gets near the limit", which no single MAX number can.
                    distributionRow(t)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(6)
            }
        }
    }

    private static let distributionHelp = "Share of the programme reaching "
        + "each deviation or more, accumulated since the last Reset from the "
        + "same 50 ms peak-hold slots MAX uses. Read it at the 75 kHz line: "
        + "that is how much of the signal is at or over the limit. Needs "
        + "15-60 minutes of programme to be representative -- a single MAX "
        + "number cannot describe modulation the way this can."

    /// Split out of `trendsSection`: inlined, the interpolated label plus the
    /// long help string pushed the body past the type-checker's budget.
    private func distributionRow(_ t: MeterTelemetry) -> some View {
        labeled("Deviation Distribution   " + t.distributionSummaryText) {
            DeviationDistributionView(
                counts: t.devHistogram, totalSamples: t.devHistogramSamples,
                maxKHz: 90, limit: 75,
                accessibilityName: "Accumulated deviation distribution")
        }
        .help(Self.distributionHelp)
    }

    private func readout(
        _ label: String, _ value: String, valueTint: Color = BroadcastStyle.readoutPrimary,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(BroadcastStyle.chipLabel).foregroundStyle(.secondary)
            // A measurement readout must never ellipsize ("+7.1 dBr max +7..."
            // hides the compliance figure); shrink slightly instead if an
            // extreme value outgrows the panel.
            Text(value).font(BroadcastStyle.valueReadout).foregroundColor(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .help(help)
    }

    /// Color a numeric readout by how close it is to a ceiling: red at/over the
    /// limit, amber within the warn band, normal otherwise.
    private func limitTint(_ value: Double, limit: Double, warn: Double) -> Color {
        if value >= limit { return BroadcastStyle.overRed }
        if value >= warn { return BroadcastStyle.tightAmber }
        return BroadcastStyle.readoutPrimary
    }

    /// Signal-strength tint (higher is better): green strong, amber moderate,
    /// red weak. `norm` is the 0..1 RSSI over the -80..0 dBFS range.
    private func signalTint(_ norm: Double) -> Color {
        if norm >= 0.5 { return BroadcastStyle.safeGreen }   // >= -40 dBFS
        if norm >= 0.28 { return BroadcastStyle.tightAmber }  // >= ~ -58 dBFS
        return BroadcastStyle.overRed
    }

    // MARK: - Scopes

    private var scopesSection: some View {
        GroupBox("Scopes") {
            LiveObservationView(telemetry: vm.telemetry) { t in
                HStack(alignment: .top, spacing: 12) {
                    labeled("Composite") {
                        ScopeView(samples: t.compositeScope,
                                  accessibilityName: "Composite waveform scope",
                                  minHeight: 84, idealHeight: 100)
                    }
                    .frame(maxWidth: .infinity)
                    labeled(decodedLSpectrum ? "Decoded L (spectrum)" : "Decoded L") {
                        decodedView(spectrum: decodedLSpectrum, wave: t.decodedLScope,
                                    spectrumDB: t.decodedLSpectrumDB,
                                    maxHz: t.audioSpectrumMaxHz, nyquistHz: t.audioSpectrumNyquistHz,
                                    channel: "left")
                            .contentShape(Rectangle())
                            .onTapGesture { decodedLSpectrum.toggle() }
                            .accessibilityAddTraits(.isButton)
                            .help("Click to toggle between waveform and audio spectrum (0-20 kHz).")
                    }
                    .frame(maxWidth: .infinity)
                    labeled(decodedRSpectrum ? "Decoded R (spectrum)" : "Decoded R") {
                        decodedView(spectrum: decodedRSpectrum, wave: t.decodedRScope,
                                    spectrumDB: t.decodedRSpectrumDB,
                                    maxHz: t.audioSpectrumMaxHz, nyquistHz: t.audioSpectrumNyquistHz,
                                    channel: "right")
                            .contentShape(Rectangle())
                            .onTapGesture { decodedRSpectrum.toggle() }
                            .accessibilityAddTraits(.isButton)
                            .help("Click to toggle between waveform and audio spectrum (0-20 kHz).")
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(6)
            }
        }
    }

    /// A decoded channel display: waveform scope, or (when toggled) its audio
    /// spectrum (0-20 kHz) drawn with the same gradient FFT graphic as the main
    /// spectrum, sized to the scope slot.
    @ViewBuilder
    private func decodedView(
        spectrum: Bool, wave: [Float], spectrumDB: [Float],
        maxHz: Double, nyquistHz: Double, channel: String
    ) -> some View {
        if spectrum {
            MPXSpectrumView(dbBins: spectrumDB, maxHz: maxHz, nyquistHz: nyquistHz,
                            minHeight: 84, idealHeight: 100)
        } else {
            ScopeView(samples: wave,
                      accessibilityName: "Decoded \(channel) waveform scope",
                      minHeight: 84, idealHeight: 100)
        }
    }

    // MARK: - Spectrum

    private static let signalUnitHelp = "Unit for the SIGNAL readout. dBFS is "
        + "the raw relative level and always works. dBm / dBuV are absolute: "
        + "the reading is the channel power minus the gain the tuner reports, "
        + "so it stays correct as AGC and LNA move -- but neither an RSP nor an "
        + "RTL dongle carries a factory power calibration, so the absolute "
        + "reference is the 'cal' offset. Set it once against a known signal "
        + "or a calibrated receiver (dBuV in 50 ohm is dBm + 107) and it holds. "
        + "SDRplay reports a true system gain; on RTL only the tuner stage is "
        + "known, so treat that as indicative."

    private static let sampleRateHelp = "IQ capture rate -- it sets the RF "
        + "spectrum's span (1 MSPS shows about +/-0.5 MHz, enough for the "
        + "adjacent channels; Narrow is the minimum the demodulator needs and "
        + "shows only the tuned carrier). The FM demod always runs at its own "
        + "rate behind a decimator, so this cannot change any MPX measurement "
        + "-- it only costs USB bandwidth and CPU. Restarts the capture."

    private static let rfSpectrumHelp = "RF spectrum around the tuned carrier, "
        + "from the tuner's IQ -- the band view an SDR application shows. Unlike "
        + "MPX (the demodulated baseband), this is what is on the air: the "
        + "station's own RF footprint, its neighbours on the 100/200 kHz raster, "
        + "and any splatter between them. Use it to spot an adjacent channel "
        + "that is degrading reception. The span is the IQ capture rate, set by "
        + "Sample Rate in the input bar."

    private var spectrumSection: some View {
        GroupBox {
            LiveObservationView(telemetry: vm.telemetry) { t in
                Group {
                    if showRFSpectrum {
                        RFSpectrumView(
                            bins: t.rfSpectrumDB, spanHz: t.rfSpanHz,
                            centerMHz: vm.frequencyMHz)
                    } else {
                        // Clip the 0..spectrumMaxHz bins to the selected display
                        // span (the view maps the bins it is given linearly
                        // across maxHz).
                        let span = Double(vm.spectrumSpanKHz) * 1000.0
                        let full = max(1.0, t.spectrumMaxHz)
                        let frac = min(1.0, span / full)
                        let count = max(2, Int((Double(t.spectrumDB.count) * frac).rounded()))
                        MPXSpectrumView(
                            dbBins: Array(t.spectrumDB.prefix(count)), maxHz: min(span, full),
                            nyquistHz: t.spectrumNyquistHz, showBandLabels: true)
                    }
                }
                .padding(6)
            }
        } label: {
            HStack {
                Text("Spectrum")
                Spacer()
                // RF is an SDR-only view (there is no IQ on an audio input), so
                // the source switch only appears there.
                if vm.inputKind == .sdr {
                    Picker("Source", selection: $vm.spectrumShowsRF) {
                        Text("MPX").tag(false)
                        Text("RF").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("MPX: the demodulated baseband (L+R / pilot / L-R / RDS). "
                        + "RF: the band around the tuned carrier, from the IQ.")
                }
                if showRFSpectrum {
                    Text("span \(rfSpanLabel)")
                        .font(BroadcastStyle.chipLabel)
                        .foregroundStyle(.secondary)
                        .help(Self.rfSpectrumHelp)
                } else {
                    Picker("Span", selection: $vm.spectrumSpanKHz) {
                        Text("60 kHz").tag(60)
                        Text("100 kHz").tag(100)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Spectrum display span. 60 kHz focuses on the modulated bands "
                        + "(L+R / pilot / L-R / RDS); 100 kHz shows the full baseband incl. SCA.")
                }
            }
        }
    }

    private var showRFSpectrum: Bool { vm.inputKind == .sdr && vm.spectrumShowsRF }

    private var rfSpanLabel: String {
        let hz = vm.telemetry.rfSpanHz
        guard hz > 0 else { return "--" }
        return hz >= 1e6 ? String(format: "%.2f MHz", hz / 1e6)
                         : String(format: "%.0f kHz", hz / 1e3)
    }

    // MARK: - RDS

    private var rdsSection: some View {
        GroupBox {
            // Native key/value grid: the label column auto-sizes to the widest
            // label and values share one baseline-aligned column (HIG key-value
            // layout) instead of a hand-tuned fixed-width HStack.
            // Wrapped in LiveObservationView: the group counters advance with
            // every received RDS group (~10/s), and these strings live on the
            // telemetry object so the updates re-evaluate ONLY this grid --
            // never the window body/toolbar (the 0.34 toolbar-relayout leak).
            LiveObservationView(telemetry: vm.telemetry) { t in
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    rdsRow("RDS", t.rdsStatusText,
                           "Decoder status: sync, Program ID (PI), TP/TA/MS flags and live "
                            + "block-error rate. BER under ~5% is a clean link.")
                    rdsRow("PTY", t.ptyText, "Program Type: the format code and its name (e.g. Pop Music).")
                    rdsRow("PTYN", t.ptynText, "Program Type Name (group 10A) -- an 8-char free-text refinement of PTY.")
                    rdsRow("ECC", t.eccText, "Extended Country Code (group 1A) -- with the PI's top nibble identifies the country.")
                    rdsRow("PS", t.psText, "Program Service name (8 characters) -- the static station name.")
                    rdsRow("RT", t.rtText, "RadioText (up to 64 characters) -- now-playing / scrolling text.")
                    rdsRow("RT+", t.rtPlusText, "RadioText+ tags marking artist / title inside the RadioText.")
                    rdsRow("LongPS", t.longPSText, "Long Program Service name (UTF-8, longer than the 8-char PS).")
                    rdsRow("CT", t.ctText, "Clock Time + date sent by the station (UTC plus local offset).")
                    rdsRow("AF", t.afText, "Alternative Frequencies carrying the same program for retuning.")
                    rdsRow("Groups", t.groupText,
                           "RDS group types received, with counts and their share of the "
                            + "stream (0A = PS/AF, 2A = RadioText, 4A = CT...).")
                    rdsRow("Order", t.groupOrderText,
                           "The last 18 groups in the order they were transmitted. The "
                            + "counts say what the encoder sends; the order shows how it "
                            + "interleaves them -- a repeating scheduler pattern, a "
                            + "starved group type, or one type bursting and crowding "
                            + "out the rest.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(6)
            }
        } label: {
            HStack {
                Text("RDS")
                Spacer()
                Toggle("Force", isOn: $vm.forceRDS)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Bypass the RDS reception-quality gate and show the raw "
                        + "decoder output even when BER is high or the 57 kHz "
                        + "subcarrier is weak -- expect garbage on noise (random "
                        + "PI/PTY). Diagnostics only; deviation measurements are "
                        + "unaffected. Applies live.")
                    .onChange(of: vm.forceRDS) { _, _ in vm.applyForceRDSChange() }
            }
        }
    }

    private func rdsRow(_ label: String, _ value: String, _ help: String = "") -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(help)
    }

    private func labeled<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(BroadcastStyle.chipLabel).foregroundStyle(.secondary)
            content()
        }
    }
}
