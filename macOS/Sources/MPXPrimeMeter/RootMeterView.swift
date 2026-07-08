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
                            // Sized to the widest Modulation readout
                            // ("+12.0 dBr  max +12.0" / "+199.9 / -199.9 kHz")
                            // so values never truncate.
                            metricsSection
                                .frame(width: 210)
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
                    .frame(minWidth: 1020, minHeight: max(760, geo.size.height - 44))
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
                        Stepper("Pilot Ref", value: $vm.pilotRefKHz, in: 4.0...9.0, step: 0.05)
                            .labelsHidden()
                    }
                    .onChange(of: vm.pilotRefKHz) { _, _ in vm.applyPilotRefChange() }
                    .help("Pilot deviation the audio-input path scales from. Set it to "
                        + "the source's real pilot deviation -- 6.75 kHz is 9%, but "
                        + "many stations differ. Scroll to step. Applied live.")
                }
            } else {
                if !vm.sdrDeviceName.isEmpty {
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
                HStack(spacing: 4) {
                    ScrollableNumericField(value: $vm.frequencyMHz,
                                           range: 64.0...108.0, step: 0.1, decimals: 1)
                        .frame(width: 64)
                    Text("MHz").foregroundStyle(.secondary)
                    Stepper("Frequency", value: $vm.frequencyMHz, in: 64.0...108.0, step: 0.1)
                        .labelsHidden()
                }
                .onChange(of: vm.frequencyMHz) { _, _ in vm.applyFrequencyChange() }
                .help("FM broadcast frequency (RTL-SDR). Type with '.' or ',', or "
                    + "scroll over the field to step. Retunes live, no restart.")

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
                    .pickerStyle(.segmented)
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

                Toggle("Bias-T", isOn: $vm.sdrBiasTee)
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
        GroupBox("Vectorscope") {
            LiveObservationView(telemetry: vm.telemetry) { t in
                VectorscopeView(left: t.decodedLScope, right: t.decodedRScope)
                    .frame(width: 240)
                    .frame(maxHeight: .infinity)
                    .padding(6)
                    .help("Stereo goniometer of decoded L/R. Vertical line = mono, a tilted "
                        + "line = single channel, a filled field = wide stereo. A horizontal "
                        + "spread warns of out-of-phase (mono-incompatible) audio.")
            }
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
                .padding(6)
            }
        }
    }

    // MARK: - Modulation metrics (BS.412 power, peak-hold, separation)

    private var metricsSection: some View {
        GroupBox("Modulation") {
            LiveObservationView(telemetry: vm.telemetry) { t in
                VStack(alignment: .leading, spacing: 10) {
                    if vm.inputKind == .sdr {
                        readout("SIGNAL", t.rssiValid ? t.rssiText : "--",
                                valueTint: t.rssiValid ? signalTint(t.rssiNorm)
                                    : BroadcastStyle.readoutPrimary,
                                help: "Relative received signal level (filtered IQ channel, "
                                    + "dBFS). Higher is stronger; most meaningful with Auto Gain "
                                    + "off. A valid BS.412 MPX-power reading needs a strong, "
                                    + "clean signal -- see the manual.")
                    }
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
                    Spacer(minLength: 0)
                    Button("Reset Peaks") { vm.resetPeaks() }
                        .buttonStyle(.bordered)
                        .disabled(!vm.running)
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
                VStack(spacing: 10) {
                    labeled("Deviation (kHz, ~60 s)") {
                        TrendView(samples: t.devHistoryKHz, minValue: 0, maxValue: 90,
                                  limit: 75, accessibilityName: "Deviation over time")
                    }
                    labeled("MPX Power (dBr, ~60 s)") {
                        TrendView(samples: t.mpxPowerHistoryDBr, minValue: -12, maxValue: 3,
                                  limit: 0, accessibilityName: "MPX power over time")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(6)
            }
        }
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

    private var spectrumSection: some View {
        GroupBox {
            LiveObservationView(telemetry: vm.telemetry) { t in
                // Clip the 0..spectrumMaxHz bins to the selected display span
                // (the view maps the bins it is given linearly across maxHz).
                let span = Double(vm.spectrumSpanKHz) * 1000.0
                let full = max(1.0, t.spectrumMaxHz)
                let frac = min(1.0, span / full)
                let count = max(2, Int((Double(t.spectrumDB.count) * frac).rounded()))
                MPXSpectrumView(
                    dbBins: Array(t.spectrumDB.prefix(count)), maxHz: min(span, full),
                    nyquistHz: t.spectrumNyquistHz, showBandLabels: true
                )
                .padding(6)
            }
        } label: {
            HStack {
                Text("Spectrum")
                Spacer()
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

    // MARK: - RDS

    private var rdsSection: some View {
        GroupBox("RDS") {
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
                           "RDS group types received and their counts (0A = PS/AF, 2A = RadioText, 4A = CT...).")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(6)
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
