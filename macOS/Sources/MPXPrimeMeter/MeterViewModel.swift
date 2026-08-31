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
/// Unit for the SDR signal-level readout. dBFS is the raw, always-available
/// relative figure; dBm and dBuV are absolute and derived as
/// `channel power dBFS - system gain + calibration offset`. The gain term is
/// read back from the tuner, so the reading tracks AGC and LNA changes; the
/// offset is the one thing no SDR can supply, because neither an RSP nor an
/// RTL dongle carries a factory power calibration. Null it once against a
/// known reference and it holds.
enum SignalUnit: Int, CaseIterable, Identifiable {
    case dBFS = 0, dBm = 1, dBuV = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .dBFS: return "dBFS"
        case .dBm: return "dBm"
        case .dBuV: return "dBuV"
        }
    }
    var isAbsolute: Bool { self != .dBFS }
    /// dBuV in 50 ohm is dBm + 107.
    var offsetFromDBm: Double { self == .dBuV ? 107.0 : 0.0 }
}

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
    /// Status line, shown in the native window subtitle. Deliberately NOT
    /// @Published: no SwiftUI body reads it, but a @Published write on this
    /// view model re-evaluates the whole window body INCLUDING the toolbar --
    /// the documented SwiftUI-on-macOS toolbar relayout leak (CHANGELOG 0.34),
    /// and this string changes on every retune (audit C17). It is published
    /// through a Combine subject the app delegate subscribes to instead.
    var statusText: String {
        get { statusSubject.value }
        set { statusSubject.value = newValue }
    }
    private let statusSubject = CurrentValueSubject<String, Never>("Stopped")
    var statusPublisher: AnyPublisher<String, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    /// The dashboard window, handed over by the app delegate. Used only to ask
    /// whether it is occluded: the tick used to gate on
    /// `NSApp.windows.first(where: visible || miniaturized)`, which can be a
    /// popover, a sheet or a save panel -- one of those being off-screen could
    /// silently freeze the whole display (audit C13).
    weak var mainWindow: NSWindow?
    /// WAV recording: format (false = decoded stereo, true = MPX composite) and
    /// live state.
    @Published var recordMPX = false
    @Published var isRecording = false
    /// Spectrum display span in kHz (60 = focus on the modulated bands, 100 =
    /// full incl. SCA). Display-only; changes only on toggle, never per tick.
    @Published var spectrumSpanKHz: Int = 60
    /// Which spectrum the big card shows: the demodulated MPX baseband, or the
    /// RF band around the tuned carrier (SDR only).
    @Published var spectrumShowsRF = false
    /// SDR IQ capture rate in kHz -- the RF spectrum's span. 0 = narrow (the
    /// demod rate itself). RESTART-REQUIRED: the device is reconfigured at
    /// open. The demod chain runs at its own rate behind a decimator, so this
    /// cannot move the MPX measurements.
    ///
    /// Defaults to 0 since 0.45: at factor 1 the RTL backend takes its
    /// original packed-uint8 path -- the byte-exact one the deviation and RDS
    /// conventions were validated against (SFP-X, 2026-07-07) -- while any
    /// wider rate routes through the newer complex path with its own
    /// decimator. A wider span is a spectrum FEATURE the operator opts into,
    /// not the shipped measurement default (audit B12).
    @Published var sdrIQRateKHz: Int = 0
    /// Unit for the SIGNAL readout, and the calibration offset that makes the
    /// absolute units absolute (see `SignalUnit`). Both persist.
    @Published var signalUnit: SignalUnit = .dBFS
    @Published var signalCalibrationDB: Double = 0
    /// Decode-path DC blocker: removes demod carrier-offset DC from the
    /// decoded audio (vectorscope centering, clean monitor/recordings).
    @Published var dcBlockEnabled = true
    /// Receiver de-emphasis time constant in microseconds: 50 (ITU Region 1 --
    /// Europe, Africa, most of Asia and Oceania) or 75 (the Americas, Japan,
    /// Korea). It shapes only the DECODE path: the monitor audio, stereo
    /// recordings, the decoded L/R strips and the audio spectrum. Persisted;
    /// live-applied. Before 0.45 it was hard-wired to 50, so a 75 us market
    /// heard and recorded ~3.5 dB too much 15 kHz.
    @Published var preemphasisUS: Int = 50
    /// Bypass the RDS reception-quality gate: show the raw decoder output
    /// even when reception is too poor to trust (expect garbage on noise).
    @Published var forceRDS = false

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
    // Smoothed vectorscope auto-gain (display-only): fast attack when the
    // figure would clip the field, slow release as program quiets.
    private var vectorAutoGain: Double = 1.0
    // Reused destination for the tuner's RF spectrum frame (matches the
    // tuner's FFT size; a short read is fine and just yields fewer bins).
    private static let rfSpectrumBins = 1024
    private var rfSpectrumScratch: [Float] = []

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
        static let spectrumRF = "meter.spectrumShowsRF"
        static let iqRate = "meter.sdrIQRateKHz"
        static let signalUnit = "meter.signalUnit"
        static let signalCal = "meter.signalCalibrationDB"
        static let inputUID = "meter.selectedInputUID"
        static let outputUID = "meter.selectedOutputUID"
        static let sdrDeviceID = "meter.selectedSDRDeviceID"
        static let mpxPass = "meter.mpxPassEnabled"
        static let mpxPassUID = "meter.mpxPassOutputUID"
        static let mpxPassGain = "meter.mpxPassGainDB"
        static let dcBlock = "meter.dcBlockEnabled"
        static let preemphasisUS = "meter.preemphasisUS"
        static let forceRDS = "meter.forceRDS"
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
        if d.object(forKey: Keys.spectrumRF) != nil { spectrumShowsRF = d.bool(forKey: Keys.spectrumRF) }
        if d.object(forKey: Keys.iqRate) != nil { sdrIQRateKHz = d.integer(forKey: Keys.iqRate) }
        if d.object(forKey: Keys.signalUnit) != nil,
           let u = SignalUnit(rawValue: d.integer(forKey: Keys.signalUnit)) { signalUnit = u }
        if d.object(forKey: Keys.signalCal) != nil {
            signalCalibrationDB = d.double(forKey: Keys.signalCal)
        }
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
        if d.object(forKey: Keys.dcBlock) != nil { dcBlockEnabled = d.bool(forKey: Keys.dcBlock) }
        if d.object(forKey: Keys.preemphasisUS) != nil {
            preemphasisUS = d.integer(forKey: Keys.preemphasisUS) == 75 ? 75 : 50
        }
        if d.object(forKey: Keys.forceRDS) != nil { forceRDS = d.bool(forKey: Keys.forceRDS) }
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
        d.set(spectrumShowsRF, forKey: Keys.spectrumRF)
        d.set(sdrIQRateKHz, forKey: Keys.iqRate)
        d.set(signalUnit.rawValue, forKey: Keys.signalUnit)
        d.set(signalCalibrationDB, forKey: Keys.signalCal)
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
        d.set(dcBlockEnabled, forKey: Keys.dcBlock)
        d.set(preemphasisUS, forKey: Keys.preemphasisUS)
        d.set(forceRDS, forKey: Keys.forceRDS)
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
            preemphasisUS: preemphasisUS,
            input: AUHALInputSource(deviceID: id,
                                    maxFramesPerSlice: MeterAudioEngine.maxSliceFrames))
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
            if !dcBlockEnabled { eng.setDCBlock(false) }
            if forceRDS { eng.setForceRDS(true) }
            startTimer()
        } catch {
            statusText = "Start failed: \(error.localizedDescription)"
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
            deviceBackend: backend, deviceSerial: serial, iqRateKHz: sdrIQRateKHz)
        let source = SDRLibraryInputSource(config: cfg)
        deviceID = nil
        priorDeviceRate = nil
        captureRate = 192_000
        let gainLinear = Float(pow(10.0, monitorGainDB / 20.0))
        let eng = MeterAudioEngine(
            sampleRate: 192_000, channel: channel,
            monitorEnabled: monitorEnabled, monitorGain: gainLinear,
            pilotRefKHz: Float(pilotRefKHz), fullScaleKHz: 150,
            preemphasisUS: preemphasisUS,
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
            if !dcBlockEnabled { eng.setDCBlock(false) }
            if forceRDS { eng.setForceRDS(true) }
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
        lastDropEvents = 0
        // Blank the dashboard: a stopped meter must not keep showing the last
        // captured frame as if it were live (audit C5).
        telemetry.reset()
        // Devices are all free now: refresh the picker with a full scan.
        refreshSDRDevices()
    }

    /// SDR unit changed: reopen on the chosen device (device open is not a
    /// live-tunable parameter).
    func applySDRDeviceChange() {
        saveSettings()
        restartIfRunning()
    }

    /// Decode-path DC blocker toggled: applies live.
    func applyDCBlockChange() {
        saveSettings()
        engine?.setDCBlock(dcBlockEnabled)
    }

    /// De-emphasis standard changed (50 / 75 us): applies live to the decode
    /// path. The analyzer reconfigures its decoder, which re-acquires the
    /// pilot lock over the next fraction of a second.
    func applyPreemphasisChange() {
        saveSettings()
        engine?.setPreemphasisUS(preemphasisUS)
    }

    /// Force-RDS toggled: applies live (bypasses the reception-quality gate).
    func applyForceRDSChange() {
        saveSettings()
        engine?.setForceRDS(forceRDS)
    }

    /// MPX pass-through toggled or its device changed: applies live.
    func applyMPXPassChange() {
        saveSettings()
        let failure = engine?.setMPXPassThrough(
            enabled: mpxPassEnabled, deviceID: selectedMPXOutID,
            gainDB: mpxPassGainDB)
        if let failure {
            // Do not leave the toggle lit over a dead player (audit C12).
            mpxPassEnabled = false
            statusText = "MPX pass-through failed: \(failure)"
            saveSettings()
        }
    }

    /// Monitor output device changed: swap just the monitor, live -- the
    /// capture, analysis, and recording are untouched.
    func applyOutputDeviceChange() {
        saveSettings()
        if let failure = engine?.setMonitorDevice(selectedOutputID) {
            statusText = "Monitor output failed: \(failure)"
        }
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
        // Every accumulated reading was measured at the OLD kHz-per-unit
        // scale: peak-hold, the exceedance count, the distribution and the
        // BS.412 max would otherwise blend two calibrations into one number
        // (a retune already resets them; a calibration change did not --
        // audit C4).
        resetPeaks()
    }

    /// Audio-path calibration changed (mode or absolute full-scale): live-apply.
    /// Absolute maps 0 dBFS to `audioFullScaleKHz` kHz; pilot-referenced passes
    /// nil so the analyzer falls back to the pilot reference.
    func applyCalibrationChange() {
        engine?.setFullScaleKHz(audioAbsoluteCal ? Float(audioFullScaleKHz) : nil)
        resetPeaks()  // same rescale-invalidates-accumulators rule as above (C4)
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

    /// Cumulative ring drop events (overflows + torn reads) already reported
    /// through the badge, so each tick only reacts to NEW drops.
    private var lastDropEvents: UInt64 = 0

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
        // Recording health -- BEFORE the occlusion gate, because recording
        // continues while the window is covered. A writer that stopped (disk
        // full, the 4 GB WAV limit) must not keep the red light on.
        if isRecording, let reason = engine?.recordingFailureReason {
            engine?.stopRecording()
            isRecording = false
            statusText = "Recording stopped: \(reason)"
        }
        // Measurement integrity -- also before the occlusion gate. Dropped
        // input samples poison every peak-hold / accumulated reading (MAX DEV,
        // histogram, BS.412 max, the SM.1268 exceedance count) with a gap
        // artefact; the badge stays until Reset Peaks. Before 0.45 the only
        // report was a stderr line at stop, which a .app sends nowhere.
        if running, let eng = engine {
            let t = eng.inputTransport
            // Drops happen at two layers and both poison the same
            // accumulators: the composite ring between capture and analysis,
            // and (SDR only) the tuner's own IQ ring between the USB/API
            // callback and the demod thread. Counting only the first would
            // miss a demod thread that cannot keep up with the capture rate.
            let dropEvents = t.overflows &+ t.tornReads
                &+ (sdrSource?.droppedIQSamples ?? 0)
            if dropEvents > lastDropEvents {
                lastDropEvents = dropEvents
                telemetry.dropWarningText =
                    "SAMPLES DROPPED -- peak / accumulated readings invalid; Reset Peaks to clear"
            }
            // Liveness watchdog: a device that wedged without signalling
            // failure delivers nothing while `running` stays true; the panel
            // must say so instead of showing frozen readings that look live.
            let stalled = (eng.secondsSinceLastDelivery ?? 0) > 1.0
            if stalled != telemetry.inputStalled { telemetry.inputStalled = stalled }
        }
        // Skip GUI pushes while the DASHBOARD window is minimized / fully
        // covered -- capture, analysis, and recording continue untouched (same
        // gating Studio applies to its monitoring windows). Gate on the real
        // window only: any other NSWindow in the app (a popover, a sheet, a
        // save panel) reports its own occlusion, and treating one of those as
        // the dashboard could freeze the display while it is plainly visible
        // (audit C13). With no window yet, do not gate.
        if let w = mainWindow, !w.occlusionState.contains(.visible) {
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
            let gain = source.systemGainDB
            telemetry.rssiValid = true
            // Absolute units need the gain term; without it fall back to the
            // relative reading rather than publish a wrong absolute number.
            if signalUnit.isAbsolute, let gain {
                let dbm = dbfs - gain + signalCalibrationDB
                telemetry.rssiText = String(format: "%.0f %@",
                                            dbm + signalUnit.offsetFromDBm,
                                            signalUnit.label)
            } else {
                telemetry.rssiText = String(format: "%.0f dBFS", dbfs)
            }
            telemetry.systemGainText = gain.map { String(format: "%.1f dB", $0) } ?? "--"
            telemetry.rssiNorm = max(0.0, min(1.0, (dbfs + 80.0) / 80.0))
        } else if telemetry.rssiValid {
            telemetry.rssiValid = false
            telemetry.rssiText = "--"
            telemetry.systemGainText = "--"
            telemetry.rssiNorm = 0
        }
        pushRFSpectrum()
    }

    /// Copy the tuner's latest RF spectrum frame into telemetry -- only while
    /// the card is actually showing it, so the copy costs nothing otherwise.
    /// "1.00 MHz" / "256 kHz" / "--" -- the RF span as the header chip shows it.
    static func rfSpanLabel(hz: Double) -> String {
        guard hz > 0 else { return "--" }
        return hz >= 1e6 ? String(format: "%.2f MHz", hz / 1e6)
                         : String(format: "%.0f kHz", hz / 1e3)
    }

    private func pushRFSpectrum() {
        guard inputKind == .sdr, spectrumShowsRF, let source = sdrSource else {
            if !telemetry.rfSpectrumDB.isEmpty {
                telemetry.rfSpectrumDB = []
                telemetry.rfSpanHz = 0
                put(\.rfSpanText, "--")
            }
            return
        }
        if rfSpectrumScratch.count != Self.rfSpectrumBins {
            rfSpectrumScratch = [Float](repeating: -140, count: Self.rfSpectrumBins)
        }
        let (count, span) = source.rfSpectrum(into: &rfSpectrumScratch)
        guard count > 0 else { return }
        telemetry.rfSpectrumDB = Array(rfSpectrumScratch[0..<count])
        telemetry.rfSpanHz = span
        // Formatted here and written through the change guard: the header chip
        // that shows it is outside the isolation wrapper (audit C1).
        put(\.rfSpanText, Self.rfSpanLabel(hz: span))
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

    /// Word for the 0..4 signal-quality scale (same rungs a Pira analyzer
    /// shows, in words rather than a bar-graph glyph).
    private static func qualityWord(_ level: Int) -> String {
        switch level {
        case 4: return "Excellent"
        case 3: return "Good"
        case 2: return "Usable"
        case 1: return "Poor"
        default: return "Unusable"
        }
    }

    /// Compact sample count for the distribution readout (12.3k, 1.2M).
    private static func compactCount(_ n: UInt64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1e3) }
        return "\(n)"
    }

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
        // An M-only decode has L == R exactly, so correlation is +1.00 by
        // construction -- report the decode state instead of that number
        // (audit M1). Separation and balance are gated in MeterAnalysis.
        let monoDecode = s.hasSignal && !s.stereoDecodeActive
        put(\.monoDecode, monoDecode)
        let corrValid = s.stereoCorrelationValid && !monoDecode
        put(\.correlationValid, corrValid)
        put(\.correlation, corrValid ? Double((s.stereoCorrelation * 100).rounded() / 100) : 0.0)
        put(\.correlationText, corrValid
            ? String(format: "%+.2f", s.stereoCorrelation) : "--")

        // Unitless values so they render at full size in the narrow scale-less
        // strips; the kHz unit is shown once in the group header.
        // Without a kHz-per-unit scale (uncalibrated input, no pilot lock)
        // these are not measurements -- they used to read a confident 0.00
        // (audit C14).
        let devText: (Float, String) -> String = { value, format in
            s.devScaleValid ? String(format: format, value) : "--"
        }
        put(\.pilotNorm, Self.qNorm(Double(s.pilotDevKHz) / MeterScale.pilotFullKHz))
        put(\.pilotText, devText(s.pilotDevKHz, "%.2f"))
        put(\.rdsNorm, Self.qNorm(Double(s.rdsDevKHz) / MeterScale.rdsFullKHz))
        put(\.rdsText, devText(s.rdsDevKHz, "%.2f"))
        put(\.maxDevNorm, Self.qNorm(Double(s.maxDevKHz) / MeterScale.maxFullKHz))
        put(\.maxDevText, devText(s.maxDevKHz, "%.1f"))
        put(\.aveMinDevText, s.devScaleValid
            ? String(format: "%.1f / %.1f", s.aveDevKHz, s.minDevKHz) : "-- / --")

        // EN 50067 sec 1.2 subcarrier phase. Whole degrees: that is the
        // resolution the +/- 10 deg tolerance is judged at, and a decimal
        // digit would only jitter. Lives on telemetry (not the RDS-panel
        // strings pushed at 2/s) because it updates with every tick.
        if s.pilotRDSPhaseValid {
            let verdict = s.pilotRDSPhase
            put(\.rdsPhaseText,
                String(format: "%.0f deg (%@)", s.pilotRDSPhaseDeg, verdict.label))
            put(\.rdsPhaseOutOfSpec, !verdict.isCompliant)
        } else {
            put(\.rdsPhaseText, "--")
            put(\.rdsPhaseOutOfSpec, false)
        }

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
        // peakValid is false when the deviation scale was lost: the peaks then
        // carry the LAST station's kHz and the view tinted them red as if they
        // were live over-deviation (audit M7 / C2).
        put(\.posPeakText, s.peakValid ? String(format: "%+.1f", s.posPeakDevKHz) : "--")
        put(\.negPeakText, s.peakValid ? String(format: "%+.1f", s.negPeakDevKHz) : "--")
        put(\.peakValid, s.peakValid)
        put(\.posPeakKHz, Double((s.posPeakDevKHz * 10).rounded() / 10))
        put(\.negPeakKHz, Double((s.negPeakDevKHz * 10).rounded() / 10))
        // SM.1268-5 exceedance readout: the compliance criterion is 1e-4 %,
        // so show enough digits for the tail (e.g. "0.00003 %"); an exact
        // zero displays as "0 %".
        if s.exceedanceValid {
            put(\.exceedanceText, s.exceedancePct <= 0.0
                ? "0 %" : String(format: "%.5f %%", s.exceedancePct))
        } else if s.exceedanceBoundPct > 0.0 {
            // Under a minute of samples the criterion (one sample in a
            // million) is finer than the window resolves, so publish the
            // upper bound the counted samples support instead of a figure
            // that cannot mean what it says (audit M6).
            put(\.exceedanceText, String(format: "< %.5f %%", s.exceedanceBoundPct))
        } else {
            put(\.exceedanceText, "--")
        }
        put(\.exceedancePct, Double(s.exceedancePct))
        put(\.exceedanceValid, s.exceedanceValid)
        put(\.mpxPowerMaxText, s.mpxPowerMaxValid
            ? String(format: "%+.1f dBr", s.mpxPowerMaxDBr) : "--")
        put(\.mpxPowerMaxDBr, Double((s.mpxPowerMaxDBr * 10).rounded() / 10))
        put(\.mpxPowerMaxValid, s.mpxPowerMaxValid)
        // Both describe the stereo image, so an M-only decode must not keep
        // showing the last stereo-era value (audit M1; the peak-hold and the
        // balance smoother hold their state across a lock loss).
        let monoDecodeNow = s.hasSignal && !s.stereoDecodeActive
        put(\.separationText, s.separationValid && !monoDecodeNow
            ? String(format: "%.0f dB", s.bestSeparationDB) : "--")

        // Reception / chain quality. `qualityValid` separates "no data yet"
        // from a measured Unusable -- both were level 0, so the card painted
        // its own warm-up red (audit C6).
        if s.basebandNoiseValid, s.hasSignal {
            put(\.qualityLevel, s.signalQuality)
            put(\.qualityValid, true)
            put(\.qualityText, String(format: "%@  %.2f kHz",
                                      Self.qualityWord(s.signalQuality), s.basebandNoiseKHz))
        } else {
            put(\.qualityLevel, 0)
            put(\.qualityValid, false)
            put(\.qualityText, "--")
        }
        put(\.carrierOffsetValid, s.carrierOffsetValid)
        put(\.carrierOffsetKHz, Double((s.carrierOffsetKHz * 10).rounded() / 10))
        put(\.carrierOffsetText, s.carrierOffsetValid
            ? String(format: "%+.1f kHz", s.carrierOffsetKHz) : "--")
        put(\.balanceText, s.stereoBalanceValid && !monoDecodeNow
            ? String(format: "%+.1f dB", s.stereoBalanceDB) : "--")

        // Deviation distribution: the curve plus the two figures that read off
        // it -- the highest bin ever filled, and the share of the programme at
        // or above the 75 kHz limit.
        put(\.devHistogram, s.devHistogram)
        put(\.devHistogramSamples, s.devHistogramSamples)
        if s.devHistogramSamples > 0 {
            let over = Double(s.devDistributionAtOrAbove(75.0)) * 100.0
            put(\.distributionSummaryText,
                String(format: "peak %.0f kHz   >=75 kHz %@   n=%@",
                       s.devHistogramMaxKHz,
                       over <= 0.0 ? "0 %" : String(format: "%.2f %%", over),
                       Self.compactCount(s.devHistogramSamples)))
        } else {
            put(\.distributionSummaryText, "--")
        }

        put(\.devHistoryKHz, s.devHistoryKHz)
        put(\.mpxPowerHistoryDBr, s.mpxPowerHistoryDBr)

        // Vectorscope display gain: target fills ~85% of the field at the
        // block's decoded peak; fast attack (shrink), slow release (grow).
        // Peak on the ROTATED goniometer axes (|L+R|, |L-R|, normalized /2):
        // a per-channel peak under-scales mono program (its energy lands
        // entirely on the L+R axis at twice the per-channel value), which
        // made near-mono signals overshoot the circle.
        var vsPeak: Float = 1e-3
        let vsN = min(s.decodedLScope.count, s.decodedRScope.count)
        for i in 0..<vsN {
            let l = s.decodedLScope[i]
            let r = s.decodedRScope[i]
            let m = max(abs(l + r), abs(l - r)) * 0.5
            if m > vsPeak { vsPeak = m }
        }
        let vsTarget = min(10.0, max(1.0, 0.85 / Double(vsPeak)))
        if vsTarget < vectorAutoGain {
            vectorAutoGain += 0.5 * (vsTarget - vectorAutoGain)   // fast shrink
        } else {
            vectorAutoGain += 0.03 * (vsTarget - vectorAutoGain)  // slow grow
        }
        put(\.vectorZoom, (vectorAutoGain * 20).rounded() / 20)

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

    /// Reset the deviation peak-hold + best-separation readouts. Also clears
    /// the samples-dropped badge: the accumulators start clean again.
    func resetPeaks() {
        engine?.resetPeaks()
        telemetry.dropWarningText = nil
        lastDropEvents = 0
        // With no engine (stopped) there is nothing to reset but the display,
        // which is the point of allowing the button there (audit C16).
        if !running { telemetry.reset() }
    }

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
        // While the reception-quality gate suppresses the readout, the status
        // line explains itself with the live evidence instead of blanks.
        let rds: String
        if s.rdsGated {
            rds = String(format: "no usable RDS — BER %.0f%% · %.1f kHz",
                         s.recentBlockErrorRate * 100, s.rdsDevKHz)
        } else {
            rds = "\(r.synced ? "sync" : "----")  PI \(pi)"
                + "  TP\(boolBit(r.tp)) TA\(boolBit(r.ta)) MS\(boolBit(r.ms))"
                + String(format: "  BER %.1f%%", s.recentBlockErrorRate * 100)
        }
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
        let order = Self.groupOrderSummary(r.groupOrder)

        let signature = [rds, pty, ptynOut, ecc, ps, rt, rtPlus, lps, ct, af, groups, order]
            .joined(separator: "|")
        guard signature != lastRDSSignature else { return }
        lastRDSSignature = signature
        lastRDSPush = now
        telemetry.rdsStatusText = rds; telemetry.ptyText = pty
        telemetry.ptynText = ptynOut; telemetry.eccText = ecc
        telemetry.psText = ps; telemetry.rtText = rt; telemetry.rtPlusText = rtPlus
        telemetry.longPSText = lps; telemetry.ctText = ct; telemetry.afText = af
        telemetry.groupText = groups
        telemetry.groupOrderText = order
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

    /// Group histogram as counts AND shares. The share is what tells an
    /// operator whether the mix is sane -- "0A 57%" is meaningful where
    /// "0A:119" only becomes meaningful after dividing by a total the panel
    /// never showed.
    private static func groupSummary(_ counts: [Int]) -> String {
        let total = counts.reduce(0, +)
        guard total > 0 else { return "--" }
        var parts: [String] = []
        for bucket in 0..<min(32, counts.count) where counts[bucket] > 0 {
            let pct = Double(counts[bucket]) / Double(total) * 100.0
            parts.append(String(format: "%@:%d (%.0f%%)",
                                groupLabel(bucket), counts[bucket], pct))
        }
        return parts.isEmpty ? "--" : parts.joined(separator: " ")
    }

    /// Groups in transmission order, oldest first -- the scheduler's actual
    /// interleave, which the counts cannot show.
    private static func groupOrderSummary(_ order: [Int]) -> String {
        guard !order.isEmpty else { return "--" }
        return order.map(groupLabel).joined(separator: " ")
    }

    /// Bucket index (`groupType * 2 + versionB`) as "0A" / "11B".
    private static func groupLabel(_ bucket: Int) -> String {
        "\(bucket / 2)\(bucket % 2 == 0 ? "A" : "B")"
    }
}
