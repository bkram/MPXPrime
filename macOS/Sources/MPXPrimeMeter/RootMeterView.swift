import CoreAudio
import MPXPrimeUI
import SwiftUI

// Single-window Meter dashboard: input controls, level meters + deviation,
// scopes, spectrum, and an RDS panel. Per-tick graphics are wrapped in
// LiveTelemetryView(vm.telemetry) so a 25 Hz refresh repaints only those
// Canvas leaves, not the window (the freeze-prevention rule).
struct RootMeterView: View {
    @ObservedObject var vm: MeterViewModel

    // Frequency is edited as text so it always shows a "." decimal (not the
    // locale comma) and accepts a typed comma (converted to "."). Kept in sync
    // with the Stepper-driven vm.frequencyMHz.
    @State private var freqText = ""
    @FocusState private var freqFocused: Bool

    private static func formatFreq(_ v: Double) -> String { String(format: "%.1f", v) }

    private func commitFreq() {
        let normalized = freqText.replacingOccurrences(of: ",", with: ".")
        if let v = Double(normalized), v >= 64.0, v <= 108.0 {
            vm.frequencyMHz = (v * 10).rounded() / 10
            vm.applyFrequencyChange()
        }
        freqText = Self.formatFreq(vm.frequencyMHz)
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
                            metricsSection
                                .frame(width: 150)
                            rdsSection
                                .frame(minWidth: 260, maxWidth: .infinity)
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
            } else {
                Label("Frequency", systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField("MHz", text: $freqText)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .focused($freqFocused)
                        .onSubmit { commitFreq() }
                        .onChange(of: freqFocused) { _, focused in if !focused { commitFreq() } }
                        .onChange(of: vm.frequencyMHz) { _, v in
                            if !freqFocused { freqText = Self.formatFreq(v) }
                        }
                        .onAppear { freqText = Self.formatFreq(vm.frequencyMHz) }
                    Text("MHz").foregroundStyle(.secondary)
                    Stepper("Frequency", value: $vm.frequencyMHz, in: 64.0...108.0, step: 0.1)
                        .labelsHidden()
                        .onChange(of: vm.frequencyMHz) { _, _ in vm.applyFrequencyChange() }
                }
                .help("FM broadcast frequency (RTL-SDR). Type with '.' or ',' -- "
                    + "both are accepted. Retunes live, no restart.")

                Divider().frame(height: 16)

                Toggle("Auto Gain", isOn: $vm.sdrAutoGain)
                    .toggleStyle(.switch)
                    .help("Tuner automatic gain. Off = manual gain (dB field). Applied live.")
                    .onChange(of: vm.sdrAutoGain) { _, _ in vm.applyGainChange() }
                if !vm.sdrAutoGain {
                    HStack(spacing: 4) {
                        TextField("dB", value: $vm.sdrGainDB,
                                  format: .number.precision(.fractionLength(1)))
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { vm.applyGainChange() }
                        Text("dB").foregroundStyle(.secondary)
                        Stepper("Gain", value: $vm.sdrGainDB, in: 0.0...50.0, step: 1.0)
                            .labelsHidden()
                            .onChange(of: vm.sdrGainDB) { _, _ in vm.applyGainChange() }
                    }
                    .help("Manual RTL-SDR tuner gain in dB (applied live).")
                }

                Divider().frame(height: 16)

                Picker("IF BW", selection: $vm.sdrBandwidthKHz) {
                    Text("Auto").tag(0)
                    ForEach([311, 254, 200, 168, 133, 114, 84, 56], id: \.self) { bw in
                        Text("\(bw) kHz").tag(bw)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("IF channel bandwidth. Wide passes the full composite (RDS/SCA) "
                    + "with more noise; narrow rejects adjacent channels but rolls off "
                    + "the composite top. Auto = widest. Applied live.")
                .onChange(of: vm.sdrBandwidthKHz) { _, _ in vm.applyBandwidthChange() }

                Divider().frame(height: 16)

                HStack(spacing: 4) {
                    Text("PPM").foregroundStyle(.secondary)
                    TextField("ppm", value: $vm.sdrPPM, format: .number)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { vm.applyPPMChange() }
                    Stepper("PPM", value: $vm.sdrPPM, in: -200...200, step: 1)
                        .labelsHidden()
                        .onChange(of: vm.sdrPPM) { _, _ in vm.applyPPMChange() }
                }
                .help("Frequency-error correction in ppm. Applied live.")

                Toggle("Bias-T", isOn: $vm.sdrBiasTee)
                    .toggleStyle(.switch)
                    .help("RTL-SDR v3 5V bias tee: powers an active antenna / inline LNA. "
                        + "Leave off unless your antenna needs it (never into a DC short). "
                        + "Applied live.")
                    .onChange(of: vm.sdrBiasTee) { _, _ in vm.applyBiasTeeChange() }

                Toggle("RTL AGC", isOn: $vm.sdrRTLAGC)
                    .toggleStyle(.switch)
                    .help("RTL2832 digital AGC, separate from the tuner gain above. "
                        + "Applied live.")
                    .onChange(of: vm.sdrRTLAGC) { _, _ in vm.applyRTLAGCChange() }
            }
            Spacer()
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
            LiveTelemetryView(telemetry: vm.telemetry) { t in
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
                        Text("CORR").font(BroadcastStyle.chipLabel).foregroundStyle(.secondary)
                        Text(t.correlationText).font(BroadcastStyle.heroReadout)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 64)
                    .help("L/R correlation: +1 = mono, ~0 = wide stereo. Negative means L and R "
                        + "are out of phase -- a mono-compatibility risk; keep it positive.")
                }
                .frame(maxHeight: .infinity)
                .padding(6)
            }
        }
    }

    // MARK: - Stereo vectorscope

    private var vectorscopeSection: some View {
        GroupBox("Vectorscope") {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
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
            LiveTelemetryView(telemetry: vm.telemetry) { t in
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
                          "Peak total deviation (2 s hold). Must stay at or below 75 kHz; "
                            + "sustained excursions above are over-modulation.")
                }
                .frame(maxHeight: .infinity)
                .padding(6)
            }
        }
    }

    // MARK: - Modulation metrics (BS.412 power, peak-hold, separation)

    private var metricsSection: some View {
        GroupBox("Modulation") {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
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
                    readout("MPX POWER", t.mpxPowerText,
                            valueTint: t.mpxPowerValid
                                ? limitTint(t.mpxPowerDBr, limit: 0.0, warn: -1.0)
                                : BroadcastStyle.readoutPrimary,
                            help: "ITU-R BS.412 multiplex power, integrated over ~60 s. "
                                + "0 dBr is the power of a +/-19 kHz sine; the regulatory "
                                + "limit is 0 dBr. Needs a calibrated scale (SDR / pilot lock).")
                    readout("PEAK +", "\(t.posPeakText) kHz",
                            valueTint: limitTint(t.posPeakKHz, limit: 75.0, warn: 71.0),
                            help: "Positive deviation peak, held since the last reset.")
                    readout("PEAK -", "\(t.negPeakText) kHz",
                            valueTint: limitTint(-t.negPeakKHz, limit: 75.0, warn: 71.0),
                            help: "Negative deviation peak, held since the last reset.")
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
            LiveTelemetryView(telemetry: vm.telemetry) { t in
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
            Text(value).font(BroadcastStyle.valueReadout).foregroundColor(valueTint)
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
            LiveTelemetryView(telemetry: vm.telemetry) { t in
                HStack(alignment: .top, spacing: 12) {
                    labeled("Composite") {
                        ScopeView(samples: t.compositeScope,
                                  accessibilityName: "Composite waveform scope",
                                  minHeight: 84, idealHeight: 100)
                    }
                    .frame(maxWidth: .infinity)
                    labeled("Decoded L") {
                        ScopeView(samples: t.decodedLScope,
                                  accessibilityName: "Decoded left waveform scope",
                                  minHeight: 84, idealHeight: 100)
                    }
                    .frame(maxWidth: .infinity)
                    labeled("Decoded R") {
                        ScopeView(samples: t.decodedRScope,
                                  accessibilityName: "Decoded right waveform scope",
                                  minHeight: 84, idealHeight: 100)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(6)
            }
        }
    }

    // MARK: - Spectrum

    private var spectrumSection: some View {
        GroupBox {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
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
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                rdsRow("RDS", vm.rdsText,
                       "Decoder status: sync, Program ID (PI), TP/TA/MS flags and live "
                        + "block-error rate. BER under ~5% is a clean link.")
                rdsRow("PTY", vm.ptyText, "Program Type: the format code and its name (e.g. Pop Music).")
                rdsRow("PTYN", vm.ptynText, "Program Type Name (group 10A) -- an 8-char free-text refinement of PTY.")
                rdsRow("ECC", vm.eccText, "Extended Country Code (group 1A) -- with the PI's top nibble identifies the country.")
                rdsRow("PS", vm.psText, "Program Service name (8 characters) -- the static station name.")
                rdsRow("RT", vm.rtText, "RadioText (up to 64 characters) -- now-playing / scrolling text.")
                rdsRow("RT+", vm.rtPlusText, "RadioText+ tags marking artist / title inside the RadioText.")
                rdsRow("LongPS", vm.longPSText, "Long Program Service name (UTF-8, longer than the 8-char PS).")
                rdsRow("CT", vm.ctText, "Clock Time + date sent by the station (UTC plus local offset).")
                rdsRow("AF", vm.afText, "Alternative Frequencies carrying the same program for retuning.")
                rdsRow("Groups", vm.groupText,
                       "RDS group types received and their counts (0A = PS/AF, 2A = RadioText, 4A = CT...).")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(6)
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
