import Combine
import CoreAudio
import Foundation
import MPXPrimeCore

// Drives the Meter window. Owns the audio engine + device selection, polls the
// engine snapshot at 25 Hz, and routes values to the right observer:
//   - per-tick levels/scopes/spectrum -> `telemetry` (isolated; never the VM)
//   - slow, structural state (devices, running, RDS text) -> @Published here,
//     written only on change so a tick does not invalidate the window.
/// Per-meter full-scale ranges (kHz) for the deviation strips. Shared by the
/// view model (to normalize the reading) and RootMeterView (to label the
/// strip), so the divisor and the scale always match. Pilot/RDS use small
/// ranges so they read mid-scale instead of as a stub on a 0..100 scale.
enum MeterScale {
    static let pilotFullKHz = 12.0
    static let pilotLimitKHz = 7.5    // ~10% pilot injection ceiling
    static let rdsFullKHz = 8.0
    static let maxFullKHz = 100.0
    static let maxLimitKHz = 75.0     // total FM deviation limit
}

@MainActor
final class MeterViewModel: ObservableObject {
    let telemetry = MeterTelemetry()

    /// Where the composite comes from: a Core Audio input device, or a live
    /// RTL-SDR via the FM-SDR-Tuner subprocess (mono MPX over a FIFO).
    enum InputKind: Hashable { case audioDevice, sdr }

    // Structural / control state (low frequency).
    @Published var inputKind: InputKind = .audioDevice
    @Published var frequencyMHz: Double = 88.6
    /// SDR tuner gain (dB) + auto/AGC. Applied live over the control FIFO when
    /// the bundled mpx-tuner is running; default auto.
    @Published var sdrAutoGain: Bool = true
    @Published var sdrGainDB: Double = 30.0
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?   // nil = system default
    @Published var channel: MeterChannel = .right
    /// True when a tuner binary is resolvable -- gates the SDR input option.
    let sdrAvailable = SDRTunerProcess.isAvailable()
    @Published var monitorEnabled = false
    @Published var monitorGainDB: Double = 0
    @Published var pilotRefKHz: Double = 6.75
    @Published var running = false
    @Published var statusText = "Stopped"

    // RDS readout (changes per second; updated only when it actually changes).
    @Published var rdsText = "--"
    @Published var psText = "--"
    @Published var rtText = "--"
    @Published var rtPlusText = "--"
    @Published var longPSText = "--"
    @Published var ctText = "--"
    @Published var afText = "--"
    @Published var groupText = "--"

    private var engine: MeterAudioEngine?
    private var deviceID: AudioDeviceID?
    private var priorDeviceRate: Double?
    private var captureRate: Double = 192_000
    private var sdrTuner: SDRTunerProcess?
    private var timer: Timer?
    private var lastRDSSignature = ""

    init() {
        refreshDevices()
    }

    func refreshDevices() {
        inputDevices = (try? AudioDevices.inputDevices()) ?? []
        outputDevices = (try? AudioDevices.outputDevices()) ?? []
        if selectedInputID == nil {
            selectedInputID = Self.preferredDefaultInput(inputDevices)
                ?? AudioDevices.defaultInputDeviceID()
                ?? inputDevices.first?.id
        }
    }

    /// Default to a device that can actually carry an MPX composite. The
    /// system default input is usually the built-in microphone (96 kHz max),
    /// which can never decode RDS at 57 kHz -- prefer the first 192 kHz-capable
    /// device, then anything >= 128 kHz, then fall back to the system default.
    private static func preferredDefaultInput(_ devices: [AudioDevice]) -> AudioDeviceID? {
        var fallback: AudioDeviceID?
        for dev in devices {
            let rates = AudioDevices.availableNominalSampleRates(deviceID: dev.id)
            if rates.contains(where: { abs($0 - 192_000) < 1.0 }) { return dev.id }
            if fallback == nil, rates.contains(where: { $0 >= 128_000 }) { fallback = dev.id }
        }
        return fallback
    }

    // MARK: - Capture lifecycle

    func start() {
        guard !running else { return }
        switch inputKind {
        case .audioDevice: startAudioDevice()
        case .sdr: startSDR()
        }
    }

    private func startAudioDevice() {
        guard let id = selectedInputID else { return }
        let prep = MeterAudioEngine.prepareInputRate(deviceID: id)
        deviceID = id
        priorDeviceRate = prep.prior
        captureRate = prep.rate
        let gainLinear = Float(pow(10.0, monitorGainDB / 20.0))
        let eng = MeterAudioEngine(
            sampleRate: Float(prep.rate), channel: channel,
            monitorEnabled: monitorEnabled, monitorGain: gainLinear,
            pilotRefKHz: Float(pilotRefKHz),
            input: AUHALInputSource(deviceID: id))
        do {
            let fmt = try eng.start(monitorDeviceID: selectedOutputID)
            captureRate = fmt.sampleRate
            engine = eng
            running = true
            statusText = String(format: "Capturing %.0f kHz", fmt.sampleRate / 1000)
            if let w = prep.warning { statusText += " — \(w)" }
            startTimer()
        } catch {
            statusText = "Start failed: \(error)"
            MeterAudioEngine.restoreInputRate(deviceID: id, to: priorDeviceRate)
            engine = nil
        }
    }

    // Live RTL-SDR via FM-SDR-Tuner: spawn the tuner, read its mono MPX over a
    // FIFO at 192 kHz. Absolute calibration (full scale = 150 kHz) -- the
    // tuner's default -6 dB MPX gain -- so PILOT/RDS/MAX are real measurements,
    // not pilot-referenced. No device rate to restore.
    private func startSDR() {
        let khz = Int((frequencyMHz * 1000).rounded())
        let tuner: SDRTunerProcess
        do {
            tuner = try SDRTunerProcess(frequencyKHz: khz)
            try tuner.start()
        } catch {
            statusText = "SDR start failed: \(error.localizedDescription)"
            return
        }
        deviceID = nil
        priorDeviceRate = nil
        captureRate = 192_000
        let gainLinear = Float(pow(10.0, monitorGainDB / 20.0))
        let eng = MeterAudioEngine(
            sampleRate: 192_000, channel: channel,
            monitorEnabled: monitorEnabled, monitorGain: gainLinear,
            pilotRefKHz: Float(pilotRefKHz), fullScaleKHz: 150,
            input: StdinInputSource(fifoPath: tuner.fifoPath, sampleRate: 192_000))
        do {
            _ = try eng.start(monitorDeviceID: selectedOutputID)
            engine = eng
            sdrTuner = tuner
            running = true
            statusText = String(format: "Tuned %.2f MHz (SDR, 192 kHz, abs cal)", frequencyMHz)
            startTimer()
        } catch {
            statusText = "SDR start failed: \(error)"
            tuner.stop()
            engine = nil
        }
    }

    func stop() {
        guard running else { return }
        timer?.invalidate()
        timer = nil
        engine?.stop()
        engine = nil
        sdrTuner?.stop()
        sdrTuner = nil
        if let id = deviceID { MeterAudioEngine.restoreInputRate(deviceID: id, to: priorDeviceRate) }
        running = false
        statusText = "Stopped"
    }

    /// Apply a control change (device/channel/monitor/ref) by restarting.
    func restartIfRunning() {
        guard running else { return }
        stop()
        start()
    }

    /// Frequency changed: live-retune the running SDR helper if it supports a
    /// control channel (no glitch, no device re-open); otherwise restart.
    func applyFrequencyChange() {
        guard running, inputKind == .sdr,
              let tuner = sdrTuner, tuner.supportsLiveControl else {
            restartIfRunning()
            return
        }
        tuner.setFrequencyKHz(Int((frequencyMHz * 1000).rounded()))
        // New station: clear the prior station's peaks / MPX power / BER / RDS.
        engine?.resetForRetune()
        statusText = String(format: "Tuned %.2f MHz (SDR, live)", frequencyMHz)
    }

    /// Gain / AGC changed: live-apply to the running SDR helper (no restart).
    func applyGainChange() {
        guard running, inputKind == .sdr,
              let tuner = sdrTuner, tuner.supportsLiveControl else { return }
        if sdrAutoGain {
            tuner.setGainAuto(true)
        } else {
            tuner.setGainDB(sdrGainDB)
        }
    }

    // MARK: - Polling

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // Surface an early tuner exit (no RTL-SDR found / device lost) rather
        // than silently showing -120 dBFS as if "Tuned".
        if inputKind == .sdr, let t = sdrTuner, !t.isRunning {
            stop()
            statusText = "SDR stopped: tuner exited (no RTL-SDR found or device lost)"
            return
        }
        guard let s = engine?.snapshot() else { return }
        pushTelemetry(s)
        pushRDSIfChanged(s)
    }

    private func pushTelemetry(_ s: MeterSnapshot) {
        telemetry.inputNorm = Self.dbNorm(s.inputPeakDBFS)
        telemetry.inputText = Self.dbText(s.inputPeakDBFS)
        telemetry.leftNorm = Self.dbNorm(s.leftRMSDBFS)
        telemetry.leftText = Self.dbText(s.leftRMSDBFS)
        telemetry.rightNorm = Self.dbNorm(s.rightRMSDBFS)
        telemetry.rightText = Self.dbText(s.rightRMSDBFS)
        telemetry.midNorm = Self.dbNorm(s.midRMSDBFS)
        telemetry.midText = Self.dbText(s.midRMSDBFS)
        telemetry.sideNorm = Self.dbNorm(s.sideRMSDBFS)
        telemetry.sideText = Self.dbText(s.sideRMSDBFS)
        telemetry.correlation = Double(s.stereoCorrelation)
        telemetry.correlationText = String(format: "%+.2f", s.stereoCorrelation)

        telemetry.pilotNorm = Double(s.pilotDevKHz) / MeterScale.pilotFullKHz
        telemetry.pilotText = String(format: "%.2f kHz", s.pilotDevKHz)
        telemetry.rdsNorm = Double(s.rdsDevKHz) / MeterScale.rdsFullKHz
        telemetry.rdsText = String(format: "%.2f kHz", s.rdsDevKHz)
        telemetry.maxDevNorm = Double(s.maxDevKHz) / MeterScale.maxFullKHz
        telemetry.maxDevText = String(format: "%.1f kHz", s.maxDevKHz)

        if s.mpxPowerValid {
            telemetry.mpxPowerText = String(format: "%+.1f dBr", s.mpxPowerDBr)
            // Display range -12..+3 dBr (0 dBr = BS.412 limit).
            telemetry.mpxPowerNorm = Double(max(0, min(1, (s.mpxPowerDBr + 12.0) / 15.0)))
        } else {
            telemetry.mpxPowerText = "--"
            telemetry.mpxPowerNorm = 0
        }
        telemetry.posPeakText = String(format: "%+.1f", s.posPeakDevKHz)
        telemetry.negPeakText = String(format: "%+.1f", s.negPeakDevKHz)
        telemetry.separationText = s.separationValid
            ? String(format: "%.0f dB", s.bestSeparationDB) : "--"

        telemetry.devHistoryKHz = s.devHistoryKHz
        telemetry.mpxPowerHistoryDBr = s.mpxPowerHistoryDBr

        telemetry.compositeScope = s.compositeScope
        telemetry.decodedLScope = s.decodedLScope
        telemetry.decodedRScope = s.decodedRScope
        telemetry.spectrumDB = s.spectrumDB
        telemetry.spectrumMaxHz = s.spectrumMaxHz
        telemetry.spectrumNyquistHz = s.spectrumNyquistHz
    }

    /// Reset the deviation peak-hold + best-separation readouts.
    func resetPeaks() { engine?.resetPeaks() }

    private func pushRDSIfChanged(_ s: MeterSnapshot) {
        let r = s.rds
        let pi = r.pi.map { String(format: "%04X", $0) } ?? "----"
        let pty = r.pty.map { "\($0)" } ?? "--"
        let rds = "\(r.synced ? "sync" : "----")  PI \(pi)  PTY \(pty)"
            + "  TP\(boolBit(r.tp)) TA\(boolBit(r.ta)) MS\(boolBit(r.ms))"
            + String(format: "  BER %.1f%%", s.recentBlockErrorRate * 100)
        let ps = "\"\(r.programService)\""
        let rt = r.radioText.isEmpty ? "--" : "\"\(r.radioText)\""
        let rtPlus = r.rtPlusTags.isEmpty
            ? "--"
            : r.rtPlusTags.map { "[\($0.contentType)] \($0.text)" }.joined(separator: "  ")
        let lps = r.longPS.isEmpty ? "--" : "\"\(r.longPS)\""
        let ct = r.clockTime.map {
            String(format: "%04d-%02d-%02d %02d:%02dZ %+.1fh",
                   $0.year, $0.month, $0.day, $0.hour, $0.minute,
                   Double($0.offsetHalfHours) * 0.5)
        } ?? "--"
        let af = r.alternativeFrequenciesMHz.isEmpty
            ? "--"
            : r.alternativeFrequenciesMHz.prefix(12).map { String(format: "%.1f", $0) }
                .joined(separator: " ") + " MHz"
        let groups = Self.groupSummary(r.groupCounts)

        let signature = [rds, ps, rt, rtPlus, lps, ct, af, groups].joined(separator: "|")
        guard signature != lastRDSSignature else { return }
        lastRDSSignature = signature
        rdsText = rds; psText = ps; rtText = rt; rtPlusText = rtPlus
        longPSText = lps; ctText = ct; afText = af; groupText = groups
    }

    // MARK: - Formatting

    private func boolBit(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "-" }

    /// dBFS (-36..0) -> normalized 0..1 for the meter strips.
    private static func dbNorm(_ db: Float) -> Double {
        Double(max(0.0, min(1.0, (db + 36.0) / 36.0)))
    }

    private static func dbText(_ db: Float) -> String {
        db <= -120 ? "-inf" : String(format: "%.1f", db)
    }

    private static func groupSummary(_ counts: [Int]) -> String {
        var parts: [String] = []
        for type in 0..<16 {
            if counts.count > type * 2, counts[type * 2] > 0 { parts.append("\(type)A:\(counts[type * 2])") }
            if counts.count > type * 2 + 1, counts[type * 2 + 1] > 0 { parts.append("\(type)B:\(counts[type * 2 + 1])") }
        }
        return parts.isEmpty ? "--" : parts.joined(separator: " ")
    }
}
