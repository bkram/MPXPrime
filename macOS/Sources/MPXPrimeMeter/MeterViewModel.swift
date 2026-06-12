import Combine
import CoreAudio
import Foundation
import MPXPrimeCore

// Drives the Meter window. Owns the audio engine + device selection, polls the
// engine snapshot at 25 Hz, and routes values to the right observer:
//   - per-tick levels/scopes/spectrum -> `telemetry` (isolated; never the VM)
//   - slow, structural state (devices, running, RDS text) -> @Published here,
//     written only on change so a tick does not invalidate the window.
@MainActor
final class MeterViewModel: ObservableObject {
    let telemetry = MeterTelemetry()

    // Structural / control state (low frequency).
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?   // nil = system default
    @Published var channel: MeterChannel = .right
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
    private var timer: Timer?
    private var lastRDSSignature = ""

    init() {
        refreshDevices()
    }

    func refreshDevices() {
        inputDevices = (try? AudioDevices.inputDevices()) ?? []
        outputDevices = (try? AudioDevices.outputDevices()) ?? []
        if selectedInputID == nil {
            selectedInputID = AudioDevices.defaultInputDeviceID() ?? inputDevices.first?.id
        }
    }

    // MARK: - Capture lifecycle

    func start() {
        guard !running, let id = selectedInputID else { return }
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

    func stop() {
        guard running else { return }
        timer?.invalidate()
        timer = nil
        engine?.stop()
        engine = nil
        if let id = deviceID { MeterAudioEngine.restoreInputRate(deviceID: id, to: priorDeviceRate) }
        running = false
        statusText = "Stopped"
    }

    /// Apply a control change (device/channel/monitor/gain/ref) by restarting.
    func restartIfRunning() {
        guard running else { return }
        stop()
        start()
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

        telemetry.pilotNorm = Double(s.pilotDevKHz) / 100.0
        telemetry.pilotText = String(format: "%.2f kHz", s.pilotDevKHz)
        telemetry.rdsNorm = Double(s.rdsDevKHz) / 100.0
        telemetry.rdsText = String(format: "%.2f kHz", s.rdsDevKHz)
        telemetry.maxDevNorm = Double(s.maxDevKHz) / 100.0
        telemetry.maxDevText = String(format: "%.1f kHz", s.maxDevKHz)

        telemetry.compositeScope = s.compositeScope
        telemetry.decodedLScope = s.decodedLScope
        telemetry.decodedRScope = s.decodedRScope
        telemetry.spectrumDB = s.spectrumDB
        telemetry.spectrumMaxHz = s.spectrumMaxHz
        telemetry.spectrumNyquistHz = s.spectrumNyquistHz
    }

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
