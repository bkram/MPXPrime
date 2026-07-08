import AppKit
import Combine
import CoreAudio
import Foundation
import MPXPrimeCore
import UniformTypeIdentifiers

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
    /// SDRplay antenna input index, and the active-backend facts read after
    /// start (drive which SDR controls the UI shows).
    @Published var sdrAntenna: Int = 0
    /// SDRplay LNA state (front-end gain reduction step; higher = less gain).
    @Published var sdrLnaState: Int = 4
    @Published var sdrIsSDRplay: Bool = false
    /// Attached SDRs (both backends) + the persisted selection (by
    /// backend+serial, stable across replug). nil = auto (SDRplay preferred).
    @Published var sdrDevices: [SDRLibraryInputSource.DeviceInfo] = []
    @Published var selectedSDRID: String?
    @Published var sdrAntennaCount: Int = 1
    /// Active SDR device label (e.g. "SDRplay RSPdx" / "RTL-SDR R820T").
    @Published var sdrDeviceName: String = ""
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?   // nil = system default
    @Published var channel: MeterChannel = .right
    /// True when SDR is supported (the tuner library is linked) -- gates the
    /// SDR input option.
    let sdrAvailable = SDRLibraryInputSource.isAvailable()
    // Monitor (decoded audio to the speakers) on by default -- pressing Start
    // should produce sound without an extra toggle.
    @Published var monitorEnabled = true
    /// MPX pass-through: play the RAW composite to its own output device
    /// (e.g. a 192 kHz DAC feeding an exciter / hardware analyzer), in
    /// addition to the decoded monitor.
    @Published var mpxPassEnabled = false
    @Published var selectedMPXOutID: AudioDeviceID?
    /// Pass-through output gain (dB). 0 = the SDR scaling (0 dBFS = 150 kHz;
    /// a 75 kHz station peaks at -6 dBFS). Raise to match an analyzer's or
    /// exciter's expected composite level; +6 dB puts 75 kHz at 0 dBFS (then
    /// deviation beyond 75 kHz clips the DAC -- keep some headroom).
    @Published var mpxPassGainDB: Double = 0
    @Published var monitorGainDB: Double = 0
    @Published var pilotRefKHz: Double = 6.75
    // Audio-path deviation calibration. Pilot-referenced (default) assumes the
    // 19 kHz pilot equals `pilotRefKHz`. Absolute maps a known input level to
    // kHz directly (0 dBFS = `audioFullScaleKHz`), independent of pilot recovery
    // -- the robust mode when the composite is fed at a known level. The SDR
    // path is always absolute (150) and ignores both.
    @Published var audioAbsoluteCal = false
    @Published var audioFullScaleKHz: Double = 150.0
    @Published var running = false
    @Published var statusText = "Stopped"
    /// WAV recording: format (false = decoded stereo, true = MPX composite) and
    /// live state.
    @Published var recordMPX = false
    @Published var isRecording = false
    /// Spectrum display span in kHz (60 = focus on the modulated bands, 100 =
    /// full incl. SCA). Display-only; changes only on toggle, never per tick.
    @Published var spectrumSpanKHz: Int = 60

    // RDS readout (changes per second; updated only when it actually changes).
    // RDS display strings live on MeterTelemetry (@Observable), NOT here:
    // the group-count line changes with every received RDS group (~10/s), and
    // a @Published write on this view model re-evaluates the whole window
    // body INCLUDING the toolbar -- the documented SwiftUI-on-macOS toolbar
    // relayout leak (CHANGELOG 0.34) that progressively saturated the main
    // thread and stuttered audio. Keep per-tick/high-frequency state off this
    // view model.

    private var engine: MeterAudioEngine?
    private var deviceID: AudioDeviceID?
    private var priorDeviceRate: Double?
    private var captureRate: Double = 192_000
    private var sdrSource: SDRLibraryInputSource?
    private var timer: Timer?
    private var lastRDSSignature = ""
    // RDS panel refresh throttle: the signature includes the live BER digit
    // and the group counters, which advance with every received group
    // (~10/s), but the text panel only needs a human reading rate. 2 Hz.
    private var lastRDSPush: TimeInterval = 0

    init() {
        refreshDevices()
        // Show the correct SDR controls before capture: the backend auto-prefers
        // SDRplay when an RSP is attached, so reflect that up front.
        sdrIsSDRplay = SDRLibraryInputSource.sdrplayPresent()
        refreshSDRDevices()
        // Restore the last-used settings; falls back to SDR-when-a-dongle-is-
        // present for the input source if nothing was saved.
        loadSettings(hasDongle: SDRLibraryInputSource.deviceCount() > 0)
    }

    /// Re-enumerate attached SDRs (cheap USB/API scan; no device is opened).
    /// While capturing, MERGE instead of replace: the SDRplay API omits
    /// in-use units from enumeration (including our own), so a mid-capture
    /// scan must never shrink the picker. A full replace happens only when
    /// idle (drops unplugged units).
    func refreshSDRDevices() {
        let scanned = SDRLibraryInputSource.listDevices()
        if running {
            var merged = sdrDevices
            for dev in scanned where !merged.contains(where: { $0.id == dev.id }) {
                merged.append(dev)
            }
            sdrDevices = merged
        } else {
            sdrDevices = scanned
        }
    }

    /// Ensure the unit we are actively capturing from is in the picker list
    /// (backend enumeration hides in-use devices).
    private func mergeActiveSDRDevice(_ source: SDRLibraryInputSource) {
        let serial = source.deviceSerial
        guard !serial.isEmpty else { return }
        let backend = source.isSDRplay ? 2 : 1
        let active = SDRLibraryInputSource.DeviceInfo(
            backend: backend, index: 0, name: source.deviceName, serial: serial)
        if !sdrDevices.contains(where: { $0.id == active.id }) {
            sdrDevices.append(active)
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

    // MARK: - Persistence (UserDefaults: ~/Library/Preferences/<bundle>.plist)

    private enum Keys {
        static let inputKind = "meter.inputKind"
        static let freq = "meter.frequencyMHz"
        static let autoGain = "meter.sdrAutoGain"
        static let gainDB = "meter.sdrGainDB"
        static let bw = "meter.sdrBandwidthKHz"
        static let biasTee = "meter.sdrBiasTee"
        static let ppm = "meter.sdrPPM"
        static let rtlAGC = "meter.sdrRTLAGC"
        static let antenna = "meter.sdrAntenna"
        static let lna = "meter.sdrLnaState"
        static let channel = "meter.channel"
        static let monitor = "meter.monitorEnabled"
        static let monitorGain = "meter.monitorGainDB"
        static let pilotRef = "meter.pilotRefKHz"
        static let absCal = "meter.audioAbsoluteCal"
        static let fullScale = "meter.audioFullScaleKHz"
        static let recordMPX = "meter.recordMPX"
        static let spectrumSpan = "meter.spectrumSpanKHz"
        static let inputUID = "meter.selectedInputUID"
        static let outputUID = "meter.selectedOutputUID"
        static let sdrDeviceID = "meter.selectedSDRDeviceID"
        static let mpxPass = "meter.mpxPassEnabled"
        static let mpxPassUID = "meter.mpxPassOutputUID"
        static let mpxPassGain = "meter.mpxPassGainDB"
    }

    /// Load the last-used settings. Devices are matched by their stable UID (the
    /// numeric AudioDeviceID is not stable across reconnects/reboots). `hasDongle`
    /// chooses the input-source default when nothing was saved.
    private func loadSettings(hasDongle: Bool) {
        let d = UserDefaults.standard
        if let s = d.string(forKey: Keys.inputKind) {
            inputKind = (s == "sdr" && hasDongle) ? .sdr : .audioDevice
        } else {
            inputKind = hasDongle ? .sdr : .audioDevice
        }
        if d.object(forKey: Keys.freq) != nil { frequencyMHz = d.double(forKey: Keys.freq) }
        if d.object(forKey: Keys.autoGain) != nil { sdrAutoGain = d.bool(forKey: Keys.autoGain) }
        if d.object(forKey: Keys.gainDB) != nil { sdrGainDB = d.double(forKey: Keys.gainDB) }
        if d.object(forKey: Keys.bw) != nil { sdrBandwidthKHz = d.integer(forKey: Keys.bw) }
        if d.object(forKey: Keys.biasTee) != nil { sdrBiasTee = d.bool(forKey: Keys.biasTee) }
        if d.object(forKey: Keys.ppm) != nil { sdrPPM = d.integer(forKey: Keys.ppm) }
        if d.object(forKey: Keys.rtlAGC) != nil { sdrRTLAGC = d.bool(forKey: Keys.rtlAGC) }
        if d.object(forKey: Keys.antenna) != nil { sdrAntenna = d.integer(forKey: Keys.antenna) }
        if d.object(forKey: Keys.lna) != nil { sdrLnaState = d.integer(forKey: Keys.lna) }
        if let c = d.string(forKey: Keys.channel), let mc = MeterChannel(rawValue: c) { channel = mc }
        if d.object(forKey: Keys.monitor) != nil { monitorEnabled = d.bool(forKey: Keys.monitor) }
        if d.object(forKey: Keys.monitorGain) != nil { monitorGainDB = d.double(forKey: Keys.monitorGain) }
        if d.object(forKey: Keys.pilotRef) != nil { pilotRefKHz = d.double(forKey: Keys.pilotRef) }
        if d.object(forKey: Keys.absCal) != nil { audioAbsoluteCal = d.bool(forKey: Keys.absCal) }
        if d.object(forKey: Keys.fullScale) != nil { audioFullScaleKHz = d.double(forKey: Keys.fullScale) }
        if d.object(forKey: Keys.recordMPX) != nil { recordMPX = d.bool(forKey: Keys.recordMPX) }
        if d.object(forKey: Keys.spectrumSpan) != nil { spectrumSpanKHz = d.integer(forKey: Keys.spectrumSpan) }
        if let uid = d.string(forKey: Keys.inputUID),
           let dev = inputDevices.first(where: { $0.uid == uid }) {
            selectedInputID = dev.id
        }
        if let uid = d.string(forKey: Keys.outputUID) {
            selectedOutputID = outputDevices.first(where: { $0.uid == uid })?.id
        }
        // SDR unit: keep the saved identity even if not currently attached
        // (same keep-the-selection convention as the audio devices).
        selectedSDRID = d.string(forKey: Keys.sdrDeviceID)
        if d.object(forKey: Keys.mpxPass) != nil { mpxPassEnabled = d.bool(forKey: Keys.mpxPass) }
        if d.object(forKey: Keys.mpxPassGain) != nil { mpxPassGainDB = d.double(forKey: Keys.mpxPassGain) }
        if let uid = d.string(forKey: Keys.mpxPassUID) {
            selectedMPXOutID = outputDevices.first(where: { $0.uid == uid })?.id
        }
    }

    /// Persist the current settings. Called on capture start and app quit.
    func saveSettings() {
        let d = UserDefaults.standard
        d.set(inputKind == .sdr ? "sdr" : "audio", forKey: Keys.inputKind)
        d.set(frequencyMHz, forKey: Keys.freq)
        d.set(sdrAutoGain, forKey: Keys.autoGain)
        d.set(sdrGainDB, forKey: Keys.gainDB)
        d.set(sdrBandwidthKHz, forKey: Keys.bw)
        d.set(sdrBiasTee, forKey: Keys.biasTee)
        d.set(sdrPPM, forKey: Keys.ppm)
        d.set(sdrRTLAGC, forKey: Keys.rtlAGC)
        d.set(sdrAntenna, forKey: Keys.antenna)
        d.set(sdrLnaState, forKey: Keys.lna)
        d.set(channel.rawValue, forKey: Keys.channel)
        d.set(monitorEnabled, forKey: Keys.monitor)
        d.set(monitorGainDB, forKey: Keys.monitorGain)
        d.set(pilotRefKHz, forKey: Keys.pilotRef)
        d.set(audioAbsoluteCal, forKey: Keys.absCal)
        d.set(audioFullScaleKHz, forKey: Keys.fullScale)
        d.set(recordMPX, forKey: Keys.recordMPX)
        d.set(spectrumSpanKHz, forKey: Keys.spectrumSpan)
        if let id = selectedInputID, let dev = inputDevices.first(where: { $0.id == id }) {
            d.set(dev.uid, forKey: Keys.inputUID)
        }
        if let id = selectedOutputID, let dev = outputDevices.first(where: { $0.id == id }) {
            d.set(dev.uid, forKey: Keys.outputUID)
        } else {
            d.removeObject(forKey: Keys.outputUID)   // nil = system default
        }
        if let id = selectedSDRID {
            d.set(id, forKey: Keys.sdrDeviceID)
        } else {
            d.removeObject(forKey: Keys.sdrDeviceID)  // nil = auto
        }
        d.set(mpxPassEnabled, forKey: Keys.mpxPass)
        d.set(mpxPassGainDB, forKey: Keys.mpxPassGain)
        if let id = selectedMPXOutID, let dev = outputDevices.first(where: { $0.id == id }) {
            d.set(dev.uid, forKey: Keys.mpxPassUID)
        } else {
            d.removeObject(forKey: Keys.mpxPassUID)
        }
    }

    // MARK: - Capture lifecycle

    func start() {
        guard !running else { return }
        saveSettings()   // checkpoint the config we're about to capture with
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
            fullScaleKHz: audioAbsoluteCal ? Float(audioFullScaleKHz) : nil,
            input: AUHALInputSource(deviceID: id))
        do {
            let fmt = try eng.start(monitorDeviceID: selectedOutputID)
            captureRate = fmt.sampleRate
            engine = eng
            running = true
            statusText = String(format: "Capturing %.0f kHz", fmt.sampleRate / 1000)
            if let w = prep.warning { statusText += " — \(w)" }
            if mpxPassEnabled {
                eng.setMPXPassThrough(enabled: true, deviceID: selectedMPXOutID,
                                      gainDB: mpxPassGainDB)
            }
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
        refreshSDRDevices()
        // Resolve the persisted unit selection (backend+serial). If the
        // selected unit is not attached, KEEP the selection but start on
        // auto with a status note -- never silently adopt another unit as
        // the new preference (the audio-device convention).
        var backend = 0
        var serial = ""
        var selectionNote: String?
        if let id = selectedSDRID {
            if let dev = sdrDevices.first(where: { $0.id == id }) {
                backend = dev.backend
                serial = dev.serial
            } else {
                selectionNote = "Selected SDR not attached -- using auto"
            }
        }
        let cfg = SDRLibraryInputSource.Config(
            frequencyKHz: Int((frequencyMHz * 1000).rounded()),
            autoGain: sdrAutoGain, gainDB: sdrGainDB,
            bandwidthKHz: sdrBandwidthKHz, biasTee: sdrBiasTee,
            ppm: sdrPPM, rtlAGC: sdrRTLAGC, antenna: sdrAntenna, lna: sdrLnaState,
            deviceBackend: backend, deviceSerial: serial)
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
            sdrIsSDRplay = source.isSDRplay
            sdrAntennaCount = source.antennaCount
            sdrDeviceName = source.deviceName
            mergeActiveSDRDevice(source)
            running = true
            let radio = source.isSDRplay ? "SDRplay" : "RTL-SDR"
            statusText = String(format: "Tuned %.2f MHz (%@, abs cal)", frequencyMHz, radio)
            if let selectionNote { statusText += " — \(selectionNote)" }
            if mpxPassEnabled {
                eng.setMPXPassThrough(enabled: true, deviceID: selectedMPXOutID,
                                      gainDB: mpxPassGainDB)
            }
            startTimer()
        } catch {
            statusText = error.localizedDescription
            source.stop()
            engine = nil
        }
    }

    func stop(forTermination: Bool = false) {
        guard running else { return }
        timer?.invalidate()
        timer = nil
        engine?.stop(forTermination: forTermination)   // also stops the input source + recorder
        engine = nil
        sdrSource = nil
        isRecording = false
        if let id = deviceID { MeterAudioEngine.restoreInputRate(deviceID: id, to: priorDeviceRate) }
        running = false
        statusText = "Stopped"
        // Devices are all free now: refresh the picker with a full scan.
        refreshSDRDevices()
    }

    /// SDR unit changed: reopen on the chosen device (device open is not a
    /// live-tunable parameter).
    func applySDRDeviceChange() {
        saveSettings()
        restartIfRunning()
    }

    /// MPX pass-through toggled or its device changed: applies live.
    func applyMPXPassChange() {
        saveSettings()
        engine?.setMPXPassThrough(
            enabled: mpxPassEnabled, deviceID: selectedMPXOutID,
            gainDB: mpxPassGainDB)
    }

    /// Monitor output device changed: swap just the monitor, live -- the
    /// capture, analysis, and recording are untouched.
    func applyOutputDeviceChange() {
        saveSettings()
        engine?.setMonitorDevice(selectedOutputID)
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

    /// Pilot reference (kHz) changed: live-apply to the pilot-referenced audio
    /// path so the deviation scale re-anchors to the true transmitted pilot
    /// without a restart. (The SDR path is absolutely calibrated and ignores it.)
    func applyPilotRefChange() {
        engine?.setPilotRefKHz(Float(pilotRefKHz))
    }

    /// Audio-path calibration changed (mode or absolute full-scale): live-apply.
    /// Absolute maps 0 dBFS to `audioFullScaleKHz` kHz; pilot-referenced passes
    /// nil so the analyzer falls back to the pilot reference.
    func applyCalibrationChange() {
        engine?.setFullScaleKHz(audioAbsoluteCal ? Float(audioFullScaleKHz) : nil)
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

    /// SDRplay antenna input changed. Live, no restart.
    func applyAntennaChange() {
        guard running, inputKind == .sdr, let source = sdrSource else { return }
        source.setAntenna(sdrAntenna)
    }

    /// SDRplay LNA state changed. Live, no restart.
    func applyLnaChange() {
        guard running, inputKind == .sdr, let source = sdrSource else { return }
        source.setLnaState(sdrLnaState)
    }

    // MARK: - Polling

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
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
            // The dead handle is deliberately abandoned (closing it would
            // crash in libusb), which keeps the unit's USB claim until the
            // dongle is replugged or the app restarts -- say so.
            statusText = "SDR stopped: device lost — replug the unit before "
                + "reusing it (its USB claim is held until replug or app restart)"
            return
        }
        // Skip GUI pushes while the window is minimized / fully covered --
        // capture, analysis, and recording continue untouched (same gating
        // Studio applies to its monitoring windows).
        if let w = NSApp.windows.first(where: { $0.isVisible || $0.isMiniaturized }),
           !w.occlusionState.contains(.visible) {
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

    // Change-guarded telemetry writes: with @Observable, every write fires the
    // observers of that property even if the value is identical, so a tick
    // that writes ~30 properties re-evaluates every wrapped leaf regardless.
    // Guarding on equality makes stable readouts cost zero per tick, and the
    // trend graphs drop to their real ~2/s data rate automatically. Bar norms
    // are quantized to display resolution first so sub-pixel changes don't
    // repaint a strip.
    @inline(__always)
    private func put<T: Equatable>(
        _ kp: ReferenceWritableKeyPath<MeterTelemetry, T>, _ v: T
    ) {
        if telemetry[keyPath: kp] != v { telemetry[keyPath: kp] = v }
    }

    /// Quantize a 0..1 bar level to ~1/500 (sub-pixel at meter sizes).
    @inline(__always)
    private static func qNorm(_ v: Double) -> Double { (v * 500).rounded() / 500 }

    private func pushTelemetry(_ s: MeterSnapshot) {
        put(\.inputNorm, Self.qNorm(Self.dbNorm(s.inputPeakDBFS)))
        put(\.inputText, Self.dbText(s.inputPeakDBFS))
        put(\.leftNorm, Self.qNorm(Self.dbNorm(s.leftRMSDBFS)))
        put(\.leftText, Self.dbText(s.leftRMSDBFS))
        put(\.rightNorm, Self.qNorm(Self.dbNorm(s.rightRMSDBFS)))
        put(\.rightText, Self.dbText(s.rightRMSDBFS))
        put(\.midNorm, Self.qNorm(Self.dbNorm(s.midRMSDBFS)))
        put(\.midText, Self.dbText(s.midRMSDBFS))
        put(\.sideNorm, Self.qNorm(Self.dbNorm(s.sideRMSDBFS)))
        put(\.sideText, Self.dbText(s.sideRMSDBFS))
        put(\.correlation, Double((s.stereoCorrelation * 100).rounded() / 100))
        put(\.correlationText, String(format: "%+.2f", s.stereoCorrelation))

        // Unitless values so they render at full size in the narrow scale-less
        // strips; the kHz unit is shown once in the group header.
        put(\.pilotNorm, Self.qNorm(Double(s.pilotDevKHz) / MeterScale.pilotFullKHz))
        put(\.pilotText, String(format: "%.2f", s.pilotDevKHz))
        put(\.rdsNorm, Self.qNorm(Double(s.rdsDevKHz) / MeterScale.rdsFullKHz))
        put(\.rdsText, String(format: "%.2f", s.rdsDevKHz))
        put(\.maxDevNorm, Self.qNorm(Double(s.maxDevKHz) / MeterScale.maxFullKHz))
        put(\.maxDevText, String(format: "%.1f", s.maxDevKHz))

        if s.mpxPowerValid {
            put(\.mpxPowerText, String(format: "%+.1f dBr", s.mpxPowerDBr))
            // Display range -12..+3 dBr (0 dBr = BS.412 limit).
            put(\.mpxPowerNorm, Self.qNorm(Double(max(0, min(1, (s.mpxPowerDBr + 12.0) / 15.0)))))
        } else {
            put(\.mpxPowerText, "--")
            put(\.mpxPowerNorm, 0)
        }
        put(\.mpxPowerDBr, Double((s.mpxPowerDBr * 10).rounded() / 10))
        put(\.mpxPowerValid, s.mpxPowerValid)
        put(\.posPeakText, String(format: "%+.1f", s.posPeakDevKHz))
        put(\.negPeakText, String(format: "%+.1f", s.negPeakDevKHz))
        put(\.posPeakKHz, Double((s.posPeakDevKHz * 10).rounded() / 10))
        put(\.negPeakKHz, Double((s.negPeakDevKHz * 10).rounded() / 10))
        // SM.1268-5 exceedance readout: the compliance criterion is 1e-4 %,
        // so show enough digits for the tail (e.g. "0.00003 %"); an exact
        // zero displays as "0 %".
        if s.exceedanceValid {
            put(\.exceedanceText, s.exceedancePct <= 0.0
                ? "0 %" : String(format: "%.5f %%", s.exceedancePct))
        } else {
            put(\.exceedanceText, "--")
        }
        put(\.exceedancePct, Double(s.exceedancePct))
        put(\.exceedanceValid, s.exceedanceValid)
        put(\.mpxPowerMaxText, s.mpxPowerMaxValid
            ? String(format: "%+.1f dBr", s.mpxPowerMaxDBr) : "--")
        put(\.mpxPowerMaxDBr, Double((s.mpxPowerMaxDBr * 10).rounded() / 10))
        put(\.mpxPowerMaxValid, s.mpxPowerMaxValid)
        put(\.separationText, s.separationValid
            ? String(format: "%.0f dB", s.bestSeparationDB) : "--")

        put(\.devHistoryKHz, s.devHistoryKHz)
        put(\.mpxPowerHistoryDBr, s.mpxPowerHistoryDBr)

        // Waveforms/spectra genuinely change every tick; write unguarded
        // (an equality compare of 512 floats that always differs is waste).
        telemetry.compositeScope = s.compositeScope
        telemetry.decodedLScope = s.decodedLScope
        telemetry.decodedRScope = s.decodedRScope
        telemetry.spectrumDB = s.spectrumDB
        put(\.spectrumMaxHz, s.spectrumMaxHz)
        put(\.spectrumNyquistHz, s.spectrumNyquistHz)
        telemetry.decodedLSpectrumDB = s.decodedLSpectrumDB
        telemetry.decodedRSpectrumDB = s.decodedRSpectrumDB
        put(\.audioSpectrumMaxHz, s.audioSpectrumMaxHz)
        put(\.audioSpectrumNyquistHz, s.audioSpectrumNyquistHz)
    }

    /// Reset the deviation peak-hold + best-separation readouts.
    func resetPeaks() { engine?.resetPeaks() }

    /// Start (with a Save panel) or stop recording. `recordMPX` selects the
    /// format: decoded stereo audio, or the raw MPX composite (mono).
    func toggleRecording() {
        guard running, let eng = engine else { return }
        if isRecording {
            eng.stopRecording()
            isRecording = false
            statusText = "Recording saved"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultRecordName()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try eng.startRecording(url: url, mpx: recordMPX)
            isRecording = true
            statusText = recordMPX ? "Recording MPX composite..." : "Recording stereo audio..."
        } catch {
            statusText = "Record failed: \(error.localizedDescription)"
        }
    }

    private func defaultRecordName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let kind = recordMPX ? "MPX" : "Stereo"
        let freq = inputKind == .sdr ? String(format: "%.1fMHz ", frequencyMHz) : ""
        return "MPX Prime \(freq)\(kind) \(f.string(from: Date())).wav"
    }

    private func pushRDSIfChanged(_ s: MeterSnapshot) {
        // Throttle to 2 Hz: the panel is text for humans; the fast movers
        // (BER digit, group counters) don't need the tick rate, and skipping
        // early avoids building eleven Strings per tick just to discard them.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRDSPush >= 0.5 else { return }
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
        lastRDSPush = now
        telemetry.rdsStatusText = rds; telemetry.ptyText = pty
        telemetry.ptynText = ptynOut; telemetry.eccText = ecc
        telemetry.psText = ps; telemetry.rtText = rt; telemetry.rtPlusText = rtPlus
        telemetry.longPSText = lps; telemetry.ctText = ct; telemetry.afText = af
        telemetry.groupText = groups
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
