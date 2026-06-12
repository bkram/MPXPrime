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
                levelsSection
                scopesSection
                spectrumSection
                rdsSection
            }
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 680)
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

    // MARK: - Levels

    private var levelsSection: some View {
        GroupBox("Levels") {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
                HStack(alignment: .top, spacing: 10) {
                    strip("IN", t.inputText, t.inputNorm, .dbfs)
                    strip("L", t.leftText, t.leftNorm, .dbfs)
                    strip("R", t.rightText, t.rightNorm, .dbfs)
                    strip("M", t.midText, t.midNorm, .dbfs)
                    strip("S", t.sideText, t.sideNorm, .dbfs)
                    Divider().frame(height: 150)
                    strip("PILOT", t.pilotText, t.pilotNorm, .modulationKHz(limit: 75))
                    strip("RDS", t.rdsText, t.rdsNorm, .modulationKHz(limit: 75))
                    strip("MAX", t.maxDevText, t.maxDevNorm, .modulationKHz(limit: 75))
                    Spacer()
                    VStack {
                        Text("CORR").font(BroadcastStyle.chipLabel).foregroundStyle(.secondary)
                        Text(t.correlationText).font(BroadcastStyle.heroReadout)
                    }
                }
                .frame(height: 180)
                .padding(6)
            }
        }
    }

    private func strip(
        _ label: String, _ value: String, _ level: Double, _ scale: VerticalMeterStrip.Scale
    ) -> some View {
        VerticalMeterStrip(label: label, valueText: value, level: level, peakLevel: nil, scale: scale)
    }

    // MARK: - Scopes

    private var scopesSection: some View {
        GroupBox("Scopes") {
            LiveTelemetryView(telemetry: vm.telemetry) { t in
                VStack(spacing: 10) {
                    labeled("Composite") { ScopeView(samples: t.compositeScope) }
                    labeled("Decoded L / R") {
                        ScopeView(samples: t.decodedLScope, secondarySamples: t.decodedRScope)
                    }
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
                rdsRow("RDS", vm.rdsText)
                rdsRow("PS", vm.psText)
                rdsRow("RT", vm.rtText)
                rdsRow("RT+", vm.rtPlusText)
                rdsRow("LongPS", vm.longPSText)
                rdsRow("CT", vm.ctText)
                rdsRow("AF", vm.afText)
                rdsRow("Groups", vm.groupText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func rdsRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(BroadcastStyle.chipLabel)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
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
