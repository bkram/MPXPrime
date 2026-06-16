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
    /// RTL-SDR decoded in-process by the linked CMPXTuner library (mono MPX).
    enum InputKind: Hashable { case audioDevice, sdr }

    // Structural / control state (low frequency).
    @Published var inputKind: InputKind = .audioDevice
    @Published var frequencyMHz: Double = 88.6
    /// SDR tuner gain (dB) + auto gain. Applied live to the running tuner (no
    /// restart); default auto.
    @Published var sdrAutoGain: Bool = true
    @Published var sdrGainDB: Double = 30.0
    /// IF channel bandwidth in kHz (0 = auto / widest = full MPX). Narrower
    /// rejects adjacent channels at the cost of the composite top end.
    @Published var sdrBandwidthKHz: Int = 0
    /// RTL-SDR v3 5V bias tee (power an active antenna / inline LNA).
    @Published var sdrBiasTee: Bool = false
    /// Frequency-error correction in ppm.
    @Published var sdrPPM: Int = 0
    /// RTL2832 digital AGC (distinct from the tuner gain mode above).
    @Published var sdrRTLAGC: Bool = false
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?   // nil = system default
    @Published var channel: MeterChannel = .right
    /// True when SDR is supported (the tuner library is linked) -- gates the
    /// SDR input option.
    let sdrAvailable = SDRLibraryInputSource.isAvailable()
    @Published var monitorEnabled = false
    @Published var monitorGainDB: Double = 0
    @Published var pilotRefKHz: Double = 6.75
    @Published var running = false
    @Published var statusText = "Stopped"
    /// Spectrum display span in kHz (60 = focus on the modulated bands, 100 =
    /// full incl. SCA). Display-only; changes only on toggle, never per tick.
    @Published var spectrumSpanKHz: Int = 60

    // RDS readout (changes per second; updated only when it actually changes).
    @Published var rdsText = "--"
    @Published var ptyText = "--"
    @Published var ptynText = "--"
    @Published var eccText = "--"
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
    private var sdrSource: SDRLibraryInputSource?
    private var timer: Timer?
    private var lastRDSSignature = ""

    init() {
        refreshDevices()
        // Default to SDR when a dongle is detected at launch; audio otherwise.
        if SDRLibraryInputSource.deviceCount() > 0 {
            inputKind = .sdr
        }
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

    // Live RTL-SDR, decoded in-process by the linked CMPXTuner library: it
    // delivers mono MPX float blocks at 192 kHz straight to the engine. Absolute
    // calibration (full scale = 150 kHz, the -6 dB MPX gain) so PILOT/RDS/MAX are
    // real measurements, not pilot-referenced. No subprocess, no device rate to
    // restore.
    private func startSDR() {
        let cfg = SDRLibraryInputSource.Config(
            frequencyKHz: Int((frequencyMHz * 1000).rounded()),
            autoGain: sdrAutoGain, gainDB: sdrGainDB,
            bandwidthKHz: sdrBandwidthKHz, biasTee: sdrBiasTee,
            ppm: sdrPPM, rtlAGC: sdrRTLAGC)
        let source = SDRLibraryInputSource(config: cfg)
        deviceID = nil
        priorDeviceRate = nil
        captureRate = 192_000
        let gainLinear = Float(pow(10.0, monitorGainDB / 20.0))
        let eng = MeterAudioEngine(
            sampleRate: 192_000, channel: channel,
            monitorEnabled: monitorEnabled, monitorGain: gainLinear,
            pilotRefKHz: Float(pilotRefKHz), fullScaleKHz: 150,
            input: source)
        do {
            _ = try eng.start(monitorDeviceID: selectedOutputID)
            engine = eng
            sdrSource = source
            running = true
            statusText = String(format: "Tuned %.2f MHz (SDR, 192 kHz, abs cal)", frequencyMHz)
            startTimer()
        } catch {
            statusText = error.localizedDescription
            source.stop()
            engine = nil
        }
    }

    func stop() {
        guard running else { return }
        timer?.invalidate()
        timer = nil
        engine?.stop()   // also stops the input source (closes the tuner)
        engine = nil
        sdrSource = nil
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

    /// Frequency changed: live-retune the running tuner (no glitch, no device
    /// re-open). The in-process library always supports live control.
    func applyFrequencyChange() {
        guard running, inputKind == .sdr, let source = sdrSource else {
            restartIfRunning()
            return
        }
        source.setFrequencyKHz(Int((frequencyMHz * 1000).rounded()))
        // New station: clear the prior station's peaks / MPX power / BER / RDS.
        engine?.resetForRetune()
        statusText = String(format: "Tuned %.2f MHz (SDR, live)", frequencyMHz)
    }

    /// Gain / auto-gain changed: live-apply to the running tuner (no restart).
    func applyGainChange() {
        guard running, inputKind == .sdr, let source = sdrSource else { return }
        if sdrAutoGain { source.setGainAuto(true) } else { source.setGainDB(sdrGainDB) }
    }

    /// IF channel bandwidth changed (0 = auto). Live, no restart.
    func applyBandwidthChange() {
        guard running, inputKind == .sdr, let source = sdrSource else { return }
        source.setBandwidthKHz(sdrBandwidthKHz)
    }

    /// Bias tee toggled. Live, no restart.
    func applyBiasTeeChange() {
        guard running, inputKind == .sdr, let source = sdrSource else { return }
        source.setBiasTee(sdrBiasTee)
    }

    /// PPM frequency correction changed. Live, no restart.
    func applyPPMChange() {
        guard running, inputKind == .sdr, let source = sdrSource else { return }
        source.setPPM(sdrPPM)
    }

    /// RTL2832 digital AGC toggled. Live, no restart.
    func applyRTLAGCChange() {
        guard running, inputKind == .sdr, let source = sdrSource else { return }
        source.setRTLAGC(sdrRTLAGC)
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
        if inputKind == .sdr, let source = sdrSource, !source.isRunning {
            stop()
            statusText = "SDR stopped: device lost (RTL-SDR unplugged?)"
            return
        }
        guard let s = engine?.snapshot() else { return }
        pushTelemetry(s)
        pushRDSIfChanged(s)
        pushSignal()
    }

    /// Push the SDR relative-RSSI readout (no RF level on the audio path).
    private func pushSignal() {
        if inputKind == .sdr, let source = sdrSource {
            let dbfs = source.signalDBFS
            telemetry.rssiValid = true
            telemetry.rssiText = String(format: "%.0f dBFS", dbfs)
            telemetry.rssiNorm = max(0.0, min(1.0, (dbfs + 80.0) / 80.0))
        } else if telemetry.rssiValid {
            telemetry.rssiValid = false
            telemetry.rssiText = "--"
            telemetry.rssiNorm = 0
        }
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

        // Unitless values so they render at full size in the narrow scale-less
        // strips; the kHz unit is shown once in the group header.
        telemetry.pilotNorm = Double(s.pilotDevKHz) / MeterScale.pilotFullKHz
        telemetry.pilotText = String(format: "%.2f", s.pilotDevKHz)
        telemetry.rdsNorm = Double(s.rdsDevKHz) / MeterScale.rdsFullKHz
        telemetry.rdsText = String(format: "%.2f", s.rdsDevKHz)
        telemetry.maxDevNorm = Double(s.maxDevKHz) / MeterScale.maxFullKHz
        telemetry.maxDevText = String(format: "%.1f", s.maxDevKHz)

        if s.mpxPowerValid {
            telemetry.mpxPowerText = String(format: "%+.1f dBr", s.mpxPowerDBr)
            // Display range -12..+3 dBr (0 dBr = BS.412 limit).
            telemetry.mpxPowerNorm = Double(max(0, min(1, (s.mpxPowerDBr + 12.0) / 15.0)))
        } else {
            telemetry.mpxPowerText = "--"
            telemetry.mpxPowerNorm = 0
        }
        telemetry.mpxPowerDBr = Double(s.mpxPowerDBr)
        telemetry.mpxPowerValid = s.mpxPowerValid
        telemetry.posPeakText = String(format: "%+.1f", s.posPeakDevKHz)
        telemetry.negPeakText = String(format: "%+.1f", s.negPeakDevKHz)
        telemetry.posPeakKHz = Double(s.posPeakDevKHz)
        telemetry.negPeakKHz = Double(s.negPeakDevKHz)
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
        telemetry.decodedLSpectrumDB = s.decodedLSpectrumDB
        telemetry.decodedRSpectrumDB = s.decodedRSpectrumDB
        telemetry.audioSpectrumMaxHz = s.audioSpectrumMaxHz
        telemetry.audioSpectrumNyquistHz = s.audioSpectrumNyquistHz
    }

    /// Reset the deviation peak-hold + best-separation readouts.
    func resetPeaks() { engine?.resetPeaks() }

    private func pushRDSIfChanged(_ s: MeterSnapshot) {
        let r = s.rds
        let pi = r.pi.map { String(format: "%04X", $0) } ?? "----"
        let rds = "\(r.synced ? "sync" : "----")  PI \(pi)"
            + "  TP\(boolBit(r.tp)) TA\(boolBit(r.ta)) MS\(boolBit(r.ms))"
            + String(format: "  BER %.1f%%", s.recentBlockErrorRate * 100)
        let pty = r.pty.map { "\($0)  \(Self.ptyName($0))" } ?? "--"
        let ptyn = r.programTypeName.trimmingCharacters(in: .whitespaces)
        let ptynOut = ptyn.isEmpty ? "--" : "\"\(ptyn)\""
        let ecc = r.ecc.map { String(format: "0x%02X", $0) } ?? "--"
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

        let signature = [rds, pty, ptynOut, ecc, ps, rt, rtPlus, lps, ct, af, groups]
            .joined(separator: "|")
        guard signature != lastRDSSignature else { return }
        lastRDSSignature = signature
        rdsText = rds; ptyText = pty; ptynText = ptynOut; eccText = ecc
        psText = ps; rtText = rt; rtPlusText = rtPlus
        longPSText = lps; ctText = ct; afText = af; groupText = groups
    }

    /// EN 50067 Programme Type names (RDS / EU set, 0-31).
    private static let ptyNames: [String] = [
        "None", "News", "Current Affairs", "Information", "Sport", "Education",
        "Drama", "Culture", "Science", "Varied", "Pop Music", "Rock Music",
        "Easy Listening", "Light Classical", "Serious Classical", "Other Music",
        "Weather", "Finance", "Children's", "Social Affairs", "Religion",
        "Phone In", "Travel", "Leisure", "Jazz Music", "Country Music",
        "National Music", "Oldies Music", "Folk Music", "Documentary",
        "Alarm Test", "Alarm"
    ]

    private static func ptyName(_ pty: Int) -> String {
        (pty >= 0 && pty < ptyNames.count) ? ptyNames[pty] : "?"
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
