import CoreAudio
import MPXPrimeUI
import SwiftUI

// Single-window Meter dashboard: input controls, level meters + deviation,
// scopes, spectrum, and an RDS panel. Per-tick graphics are wrapped in
// LiveTelemetryView(vm.telemetry) so a 25 Hz refresh repaints only those
// Canvas leaves, not the window (the freeze-prevention rule).
struct RootMeterView: View {
    @ObservedObject var vm: MeterViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inputBar
                HStack(alignment: .top, spacing: 14) {
                    audioSection
                    vectorscopeSection
                    rdsSection
                        .frame(minWidth: 260, maxWidth: .infinity)
                }
                modulationSection
                scopesSection
                spectrumSection
            }
            .padding(16)
        }
        .frame(minWidth: 900, minHeight: 680)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        GroupBox {
            HStack(spacing: 12) {
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

                if vm.inputKind == .audioDevice {
                    Picker("Input", selection: $vm.selectedInputID) {
                        ForEach(vm.inputDevices) { dev in
                            Text(dev.name).tag(Optional(dev.id))
                        }
                    }
                    .frame(maxWidth: 220)
                    .onChange(of: vm.selectedInputID) { _, _ in vm.restartIfRunning() }

                    Picker("Ch", selection: $vm.channel) {
                        Text("L").tag(MeterChannel.left)
                        Text("R").tag(MeterChannel.right)
                        Text("Mix").tag(MeterChannel.mix)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: vm.channel) { _, _ in vm.restartIfRunning() }
                } else {
                    HStack(spacing: 4) {
                        Text("Freq")
                        TextField("MHz", value: $vm.frequencyMHz, format: .number.precision(.fractionLength(1)))
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { vm.restartIfRunning() }
                        Text("MHz")
                        Stepper("", value: $vm.frequencyMHz, in: 64.0...108.0, step: 0.1)
                            .labelsHidden()
                            .onChange(of: vm.frequencyMHz) { _, _ in vm.restartIfRunning() }
                    }
                    .help("FM broadcast frequency to tune (RTL-SDR).")
                }

                Toggle("Monitor", isOn: $vm.monitorEnabled)
                    .onChange(of: vm.monitorEnabled) { _, _ in vm.restartIfRunning() }

                Button(vm.running ? "Stop" : "Start") {
                    vm.running ? vm.stop() : vm.start()
                }
                .buttonStyle(.borderedProminent)

                Spacer()
                Text(vm.statusText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(6)
        }
    }

    // MARK: - Audio levels

    private var audioSection: some View {
        GroupBox("Audio") {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
                HStack(alignment: .top, spacing: 10) {
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
                    Divider().frame(height: 170)
                    VStack(spacing: 6) {
                        Text("CORR").font(BroadcastStyle.chipLabel).foregroundStyle(.secondary)
                        Text(t.correlationText).font(BroadcastStyle.heroReadout)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 64)
                    .help("L/R correlation: +1 = mono, ~0 = wide stereo. Negative means L and R "
                        + "are out of phase -- a mono-compatibility risk; keep it positive.")
                }
                .frame(height: 210)
                .padding(6)
            }
        }
    }

    // MARK: - Stereo vectorscope

    private var vectorscopeSection: some View {
        GroupBox("Vectorscope") {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
                VectorscopeView(left: t.decodedLScope, right: t.decodedRScope)
                    .frame(width: 196, height: 196)
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
        VerticalMeterStrip(
            label: label, valueText: value, level: level, peakLevel: nil, scale: scale, help: help)
    }

    // MARK: - Modulation (BS.412 power, peak-hold, separation, trends)

    private var modulationSection: some View {
        GroupBox("Modulation") {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
                HStack(alignment: .top, spacing: 16) {
                    // Deviation / subcarrier meters.
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
                    .frame(height: 210)

                    Divider().frame(height: 190)

                    // Numeric readouts + reset.
                    VStack(alignment: .leading, spacing: 10) {
                        readout("MPX POWER", t.mpxPowerText,
                                help: "ITU-R BS.412 multiplex power, integrated over ~60 s. "
                                    + "0 dBr is the power of a +/-19 kHz sine; the regulatory "
                                    + "limit is 0 dBr. Needs a calibrated scale (SDR / pilot lock).")
                        readout("PEAK +", "\(t.posPeakText) kHz",
                                help: "Positive deviation peak, held since the last reset.")
                        readout("PEAK -", "\(t.negPeakText) kHz",
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
                    .frame(width: 168, height: 210, alignment: .topLeading)

                    Divider().frame(height: 190)

                    // Trends.
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
                    .frame(maxWidth: .infinity)
                }
                .padding(6)
            }
        }
    }

    private func readout(_ label: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(BroadcastStyle.chipLabel).foregroundStyle(.secondary)
            Text(value).font(BroadcastStyle.valueReadout)
        }
        .help(help)
    }

    // MARK: - Scopes

    private var scopesSection: some View {
        GroupBox("Scopes") {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
                HStack(alignment: .top, spacing: 12) {
                    labeled("Composite") {
                        ScopeView(samples: t.compositeScope, accessibilityName: "Composite waveform scope")
                    }
                    .frame(maxWidth: .infinity)
                    labeled("Decoded L") {
                        ScopeView(samples: t.decodedLScope, accessibilityName: "Decoded left waveform scope")
                    }
                    .frame(maxWidth: .infinity)
                    labeled("Decoded R") {
                        ScopeView(samples: t.decodedRScope, accessibilityName: "Decoded right waveform scope")
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(6)
            }
        }
    }

    // MARK: - Spectrum

    private var spectrumSection: some View {
        GroupBox("Spectrum (0–100 kHz)") {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
                MPXSpectrumView(
                    dbBins: t.spectrumDB, maxHz: t.spectrumMaxHz,
                    nyquistHz: t.spectrumNyquistHz, markersHz: [19_000, 38_000, 57_000]
                )
                .padding(6)
            }
        }
    }

    // MARK: - RDS

    private var rdsSection: some View {
        GroupBox("RDS") {
            VStack(alignment: .leading, spacing: 4) {
                rdsRow("RDS", vm.rdsText,
                       "Decoder status: sync, Program ID (PI), Program Type (PTY), TP/TA/MS "
                        + "flags and live block-error rate. BER under ~5% is a clean link.")
                rdsRow("PS", vm.psText, "Program Service name (8 characters) -- the static station name.")
                rdsRow("RT", vm.rtText, "RadioText (up to 64 characters) -- now-playing / scrolling text.")
                rdsRow("RT+", vm.rtPlusText, "RadioText+ tags marking artist / title inside the RadioText.")
                rdsRow("LongPS", vm.longPSText, "Long Program Service name (UTF-8, longer than the 8-char PS).")
                rdsRow("CT", vm.ctText, "Clock Time + date sent by the station (UTC plus local offset).")
                rdsRow("AF", vm.afText, "Alternative Frequencies carrying the same program for retuning.")
                rdsRow("Groups", vm.groupText,
                       "RDS group types received and their counts (0A = PS/AF, 2A = RadioText, 4A = CT...).")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func rdsRow(_ label: String, _ value: String, _ help: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
