import Foundation
import MPXPrimeCore

// ControlBackend for the headless runtimes (--nogui on macOS and the Linux
// CLI). Owns the AppConfig and the engine lifecycle; main.swift hands it a
// platform-specific engine factory and runs the process event loop around
// it. All state is actor-isolated; engine `apply*` calls are thread-safe
// producers so calling them from the actor executor is fine.

/// Builds a fresh generator+engine for the current config. Platform-specific
/// (device resolution on macOS, ALSA PCM names on Linux); provided by
/// main.swift. Must return a STOPPED engine; the backend starts it.
typealias ControlEngineFactory = @Sendable (AppConfig) throws -> any ControlledEngine

actor HeadlessControlBackend: ControlBackend {
    private var config: AppConfig
    private let configPath: String
    private var engine: (any ControlledEngine)?
    private let makeEngine: ControlEngineFactory
    private var startedAt: Date?
    private var restartPending = false
    private var notes: [String] = []
    /// Desired transport state (reconciliation target). True from boot so the
    /// encoder auto-starts and keeps RETRYING when the device is missing --
    /// the box comes up the moment the device appears (boot ordering / USB
    /// hot-plug) without any intervention. A user Stop sets this false so the
    /// retry loop leaves it alone; a user Start/Restart sets it true again.
    private var desiredRunning = true
    private var retries = 0
    /// Side effects on config change (now-playing runner reconfigure).
    private let onConfigChange: (@Sendable (AppConfig) -> Void)?
    /// Sink for API now-playing pushes (display, artist, title) -> the shared
    /// NowPlayingState owned by main.swift.
    private let onNowPlaying: (@Sendable (String, String, String) -> Void)?
    /// Device enumeration, injected so tests never touch the HAL (the same
    /// rule as the GUI's deviceLister). Production default is the real one.
    private let enumerateDevices:
        @Sendable () -> (inputs: [ControlDevice], outputs: [ControlDevice], note: String)

    init(
        config: AppConfig,
        configPath: String,
        engine: (any ControlledEngine)?,
        engineFactory: @escaping ControlEngineFactory,
        onConfigChange: (@Sendable (AppConfig) -> Void)? = nil,
        onNowPlaying: (@Sendable (String, String, String) -> Void)? = nil,
        deviceEnumerator: @escaping @Sendable ()
            -> (inputs: [ControlDevice], outputs: [ControlDevice], note: String)
            = { AudioDeviceListing.enumerate() }
    ) {
        self.config = config
        self.configPath = configPath
        self.engine = engine
        self.makeEngine = engineFactory
        self.onConfigChange = onConfigChange
        self.onNowPlaying = onNowPlaying
        self.enumerateDevices = deviceEnumerator
        self.startedAt = engine != nil ? Date() : nil
    }

    // MARK: - ControlBackend

    func status() -> ControlStatus {
        ControlStatus(
            running: engine != nil,
            platform: platformName(),
            version: AppConfig.appVersion,
            sampleRateHz: config.sampleRate,
            uptimeSeconds: startedAt.map { Date().timeIntervalSince($0) },
            restartPending: restartPending,
            sourceMode: config.sourceMode,
            outputMode: config.resolvedOutputMode(allowMonitor: false).statusString,
            notes: notes
        )
    }

    func meters() -> ControlMeters? {
        engine?.controlMeters
    }

    func telemetry(windowMS: Double) -> ControlTelemetry? {
        engine?.controlTelemetry(windowMS: windowMS)
    }

    func rds() -> ControlRDS {
        let live = engine?.rdsLiveSnapshotForControl
        return ControlRDS(
            enabled: config.enRDS,
            pi: config.rdsPI,
            pty: config.rdsPTY,
            ta: config.rdsTA,
            tp: config.rdsTP,
            livePS: live?.ps,
            liveRT: live?.rt,
            livePTYN: live?.ptyn,
            liveLongPS: live?.longPS,
            configuredRT: config.rdsRTText,
            configuredPSActiveBank: config.rdsPSActiveBank
        )
    }

    func devices() -> ControlDevices {
        let (inputs, outputs, note) = AudioDeviceListing.enumerate()
        return ControlDevices(
            inputs: inputs, outputs: outputs,
            selectedInput: config.inputDeviceUID ?? "",
            selectedOutput: config.outputDeviceUID ?? "",
            selectedMonitor: config.monitorDeviceUID ?? "",
            monitorEnabled: config.monitorEnabled,
            note: note)
    }

    func configSections() throws -> [String: [String: String]] {
        try ConfigPatch.sectionedValues(of: config)
    }

    func applyConfigPatch(_ patch: [String: String]) throws -> ConfigApplyResult {
        let oldInputUID = config.inputDeviceUID
        let oldOutputUID = config.outputDeviceUID
        let oldProcessed = config.processedAudioOutput
        var (newConfig, outcomes, planes) = try ConfigPatch.apply(patch, to: config)
        // Per-device calibration recall (Audio I/O): a device/mode change
        // pulls the new device's remembered levels into the config BEFORE it
        // commits. The planes were classified from the PATCH, so a pure
        // device change never live-applies the recalled levels -- they land
        // with the restart, atomically with the new device. Explicitly
        // patched level keys win over recall.
        recallCalibrationIfDeviceChanged(
            oldInputUID: oldInputUID, oldOutputUID: oldOutputUID,
            oldProcessed: oldProcessed, into: &newConfig, patchKeys: Set(patch.keys))
        config = newConfig
        if let engine {
            if planes.dspLive { engine.applyRuntimeConfig(newConfig) }
            if planes.rdsLive { engine.applyRDSRuntimeConfig(newConfig) }
            if planes.restartRequired { restartPending = true }
        }
        persist()
        markActiveSnapshotModified()
        onConfigChange?(newConfig)
        return ConfigApplyResult(
            outcomes: outcomes,
            appliedLive: (planes.dspLive || planes.rdsLive) && engine != nil,
            restartPending: restartPending
        )
    }

    func transport(_ action: TransportAction) throws -> ControlStatus {
        switch action {
        case .start:
            desiredRunning = true
            if engine == nil { try startEngine() }
        case .stop:
            desiredRunning = false
            stopEngine()
        case .restart:
            desiredRunning = true
            stopEngine()
            try startEngine()
        }
        return status()
    }

    /// Reconcile toward the desired state: if the operator wants it running
    /// and it isn't, (re)try the start. Called on a timer from the headless
    /// runtime so a missing device is never fatal -- the engine comes up as
    /// soon as the device is available. A user Stop clears `desiredRunning`,
    /// so this never fights a deliberate stop.
    func reconcile() {
        guard desiredRunning, engine == nil else { return }
        retries += 1
        startEngineTolerant()
    }

    func presets() -> [String: [String]] {
        [
            "primebass": PresetCatalog.primeBassPresets.map(\.id),
            "multiband": PresetCatalog.multibandPresets.map(\.id),
            "finalstage": PresetCatalog.finalStagePresets.map(\.id),
            "format_profile": PresetCatalog.formatProfiles.map(\.id)
        ]
    }

    func applyPreset(kind: String, id: String, intensity: Double?) throws -> ConfigApplyResult {
        var newConfig = config
        let title: String?
        switch kind.lowercased() {
        case "primebass":
            title = PresetCatalog.applyPrimeBass(id: id, to: &newConfig)
        case "finalstage":
            title = PresetCatalog.applyFinalStage(id: id, to: &newConfig)
        case "format_profile":
            title = PresetCatalog.applyFormatProfile(id: id, to: &newConfig)
        case "multiband":
            let level: MultibandPresetIntensity
            switch intensity {
            case .some(let v) where v < 0.75: level = .light
            case .some(let v) where v > 1.25: level = .heavy
            default: level = .normal
            }
            title = PresetCatalog.applyMultiband(id: id, intensity: level, to: &newConfig)
        default:
            throw ControlError.invalidRequest("unknown preset kind '\(kind)'")
        }
        guard title != nil else {
            throw ControlError.invalidRequest("unknown \(kind) preset '\(id)'")
        }
        config = newConfig
        engine?.applyRuntimeConfig(newConfig)
        persist()
        markActiveSnapshotModified()
        onConfigChange?(newConfig)
        return ConfigApplyResult(
            outcomes: [], appliedLive: engine != nil, restartPending: restartPending)
    }

    // MARK: - Snapshot slots (shared SnapshotStore)

    private func snapshotDTO(_ file: SnapshotFile) -> ControlSnapshots {
        ControlSnapshots(slots: file.slots.enumerated().map { i, snap in
            ControlSnapshotSlot(
                slot: i,
                name: snap?.name,
                savedAt: snap?.savedAt,
                active: snap != nil && snap?.id == file.activeID,
                modified: snap != nil && snap?.id == file.activeID
                    && (file.activeModified ?? false))
        })
    }

    func snapshots() -> ControlSnapshots {
        snapshotDTO(SnapshotStore.load(configPath: configPath))
    }

    func snapshotSave(slot: Int, name: String) throws -> ControlSnapshots {
        var file = SnapshotStore.load(configPath: configPath)
        guard file.slots.indices.contains(slot) else {
            throw ControlError.invalidRequest("slot out of range")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let snap = ConfigSnapshot(
            id: UUID(),
            name: trimmed.isEmpty ? SnapshotStore.defaultName(slot: slot) : trimmed,
            savedAt: Date(),
            configINIText: try config.captureAsINIString())
        file.slots[slot] = snap
        file.activeID = snap.id
        file.activeModified = false
        try SnapshotStore.write(file, configPath: configPath)
        return snapshotDTO(file)
    }

    func snapshotLoad(slot: Int) throws -> ConfigApplyResult {
        var file = SnapshotStore.load(configPath: configPath)
        guard file.slots.indices.contains(slot), let snap = file.slots[slot] else {
            throw ControlError.invalidRequest("empty or invalid slot")
        }
        // Apply as a FULL config patch so every changed key goes through the
        // canonical live/liveRDS/restart classification -- a snapshot load is
        // just a big PATCH, and behaves exactly like one. Installation keys
        // (devices, engine format, mode, calibration, control server) are
        // preserved from the live config first: snapshots restore the sound,
        // not the wiring (and a remote load must never strand the box by
        // turning its own control server off).
        let loaded = AppConfig.applyingSnapshot(
            iniText: snap.configINIText, preservingInstallationFrom: config)
        let patch = try ConfigPatch.sectionedValues(of: loaded)
            .values.reduce(into: [String: String]()) { $0.merge($1) { a, _ in a } }
        let result = try applyConfigPatch(patch)
        file.activeID = snap.id
        file.activeModified = false
        try SnapshotStore.write(file, configPath: configPath)
        return result
    }

    func snapshotRename(slot: Int, name: String) throws -> ControlSnapshots {
        var file = SnapshotStore.load(configPath: configPath)
        guard file.slots.indices.contains(slot), var snap = file.slots[slot] else {
            throw ControlError.invalidRequest("empty or invalid slot")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snap.name = trimmed.isEmpty ? SnapshotStore.defaultName(slot: slot) : trimmed
        file.slots[slot] = snap
        try SnapshotStore.write(file, configPath: configPath)
        return snapshotDTO(file)
    }

    func snapshotClear(slot: Int) throws -> ControlSnapshots {
        var file = SnapshotStore.load(configPath: configPath)
        guard file.slots.indices.contains(slot) else {
            throw ControlError.invalidRequest("slot out of range")
        }
        if file.slots[slot]?.id == file.activeID {
            file.activeID = nil
            file.activeModified = false
        }
        file.slots[slot] = nil
        try SnapshotStore.write(file, configPath: configPath)
        return snapshotDTO(file)
    }

    func snapshotExport(slot: Int) -> String? {
        let file = SnapshotStore.load(configPath: configPath)
        guard file.slots.indices.contains(slot) else { return nil }
        return file.slots[slot]?.configINIText
    }

    func snapshotImport(slot: Int, name: String?, iniText: String) throws -> ControlSnapshots {
        var file = SnapshotStore.load(configPath: configPath)
        guard file.slots.indices.contains(slot) else {
            throw ControlError.invalidRequest("slot out of range")
        }
        // Validate + normalize through the canonical writer, like the GUI.
        let parsed = try AppConfig.loadFromINIString(iniText)
        let canonical = try parsed.captureAsINIString()
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let snap = ConfigSnapshot(
            id: UUID(),
            name: trimmed.isEmpty ? SnapshotStore.defaultName(slot: slot) : trimmed,
            savedAt: Date(),
            configINIText: canonical)
        if file.slots[slot]?.id == file.activeID {
            file.activeID = nil
            file.activeModified = false
        }
        file.slots[slot] = snap
        try SnapshotStore.write(file, configPath: configPath)
        return snapshotDTO(file)
    }

    func setNowPlaying(artist: String, title: String, display: String) -> Bool {
        onNowPlaying?(display, artist, title)
        return config.rdsNowPlayingEnabled
    }

    // MARK: - Lifecycle

    private func startEngine() throws {
        do {
            let fresh = try makeEngine(config)
            try fresh.start()
            // Re-apply both runtime planes to the freshly built engine. The
            // engine factory already constructed it FROM `config`, so this is
            // idempotent today -- but the coder/generator inits are separate
            // hand-written AppConfig mappings from the canonical
            // RuntimeConfig/RDSRuntimeConfig factories the live-apply path
            // uses, and nothing pins them together. Applying the canonical
            // planes here makes restart-equals-live true BY CONSTRUCTION for
            // every current and future key (the issues.txt report of
            // now-playing off after an API restart is exactly this failure
            // class). Both calls are thread-safe producers; on a just-started
            // engine they are the ordinary live-apply path.
            fresh.applyRuntimeConfig(config)
            fresh.applyRDSRuntimeConfig(config)
            engine = fresh
            startedAt = Date()
            restartPending = false
            notes = []
        } catch {
            // Record the reason so GET /api/status (and the dashboard) explain
            // why the engine is stopped -- typically a missing/renamed audio
            // device the operator can fix from the Interfaces page, then Start.
            let msg = String(describing: error)
            notes = ["audio engine not started: \(msg) "
                + "(retrying automatically; pick a present device on the Interfaces page to change it)"]
            throw ControlError.engineFailure(msg)
        }
    }

    /// Best-effort initial start used at boot: attempts to start the engine
    /// but never throws, so a missing device leaves the process (and the
    /// control server) alive for remote recovery. Returns whether it started.
    @discardableResult
    func startEngineTolerant() -> Bool {
        do {
            try startEngine()
            return true
        } catch {
            return false
        }
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
        startedAt = nil
    }

    /// Adopt an engine main.swift already started (initial boot path) --
    /// covered by init; used for shutdown from signal handlers.
    func shutdown() {
        stopEngine()
    }

    /// The GUI flips its "Loaded - edited" marker on any config change;
    /// mirror that here so the API's `modified` flag means the same thing.
    private func markActiveSnapshotModified() {
        var file = SnapshotStore.load(configPath: configPath)
        guard file.activeID != nil, file.activeModified != true else { return }
        file.activeModified = true
        try? SnapshotStore.write(file, configPath: configPath)
    }

    private func persist() {
        do {
            try config.save(toINI: configPath)
        } catch {
            notes = ["config save failed: \(error)"]
        }
        captureDeviceCalibration()
    }

    // MARK: - Per-device calibration memory (Audio I/O sidecar)

    /// Write-through: record the config's levels under its selected devices.
    /// Device names / the connected set come from a best-effort enumeration
    /// (headless PATCHes never update the `*_device_name` mirrors); an empty
    /// enumeration just skips the UID-drift dedupe for this pass.
    private func captureDeviceCalibration() {
        var store = DeviceCalibrationStore.load(configPath: configPath)
        let listing = enumerateDevices()
        let connected = Set(listing.inputs.map(\.id) + listing.outputs.map(\.id))
        let changed = store.capture(
            from: config,
            inputName: listing.inputs.first(where: { $0.id == config.inputDeviceUID })?.name,
            outputName: listing.outputs.first(where: { $0.id == config.outputDeviceUID })?.name,
            connectedUIDs: connected)
        guard changed else { return }
        do {
            try DeviceCalibrationStore.write(store, configPath: configPath)
        } catch {
            notes.append("device calibration memory write failed: \(error)")
        }
    }

    private func recallCalibrationIfDeviceChanged(
        oldInputUID: String?, oldOutputUID: String?, oldProcessed: Bool,
        into newConfig: inout AppConfig, patchKeys: Set<String>
    ) {
        let inputChanged = (newConfig.inputDeviceUID ?? "") != (oldInputUID ?? "")
        let outputChanged = (newConfig.outputDeviceUID ?? "") != (oldOutputUID ?? "")
            || newConfig.processedAudioOutput != oldProcessed
        guard inputChanged || outputChanged else { return }
        let store = DeviceCalibrationStore.load(configPath: configPath)
        var recalled = newConfig
        // Name fallback rides the config's *_device_name mirrors (the store
        // falls back to them when the explicit names are nil).
        _ = store.recall(
            into: &recalled,
            recallInput: inputChanged,
            recallOutput: outputChanged,
            inputName: nil,
            outputName: nil)
        if patchKeys.contains("input_gain_db") { recalled.inputGainDB = newConfig.inputGainDB }
        if patchKeys.contains("output_gain_db") { recalled.outputGainDB = newConfig.outputGainDB }
        if patchKeys.contains("mpx_line_output_dbfs") {
            recalled.mpxLineOutputDBFS = newConfig.mpxLineOutputDBFS
        }
        recalled.validate()
        if recalled != newConfig {
            newConfig = recalled
            notes.append("Recalled per-device calibration for the new device selection.")
        }
    }

    private func platformName() -> String {
        #if os(Linux)
        return "linux"
        #else
        return "macOS"
        #endif
    }
}

// MARK: - Engine conformances

#if os(macOS)
extension AudioOutputEngine: ControlledEngine {
    /// Scope waveforms straight from the engine's meter histories + an MPX
    /// spectrum computed here with the shared MPXSpectrumAnalyzer. Called at
    /// the dashboard's poll rate (4-7 Hz), not per tick: a fresh 4096-point
    /// vDSP FFT per request is sub-millisecond and keeps this reentrant
    /// (no shared analyzer state to lock).
    func controlTelemetry(windowMS: Double) -> ControlTelemetry? {
        let clampedWindow = max(1.0, min(100.0, windowMS))
        let scopes = scopeSnapshot(windowMS: clampedWindow)
        guard !scopes.output.isEmpty else { return nil }
        var scratch = [Float](repeating: 0.0, count: 4096)
        let raw = outputSignalWindow(into: &scratch, frameCount: 4096)
        let spectrum = MPXSpectrumAnalyzer().compute(
            samples: scratch,
            validCount: raw.count,
            sampleRate: raw.sampleRate,
            displayBins: 256,
            maxDisplayHz: 96_000.0
        )
        func decimate(_ src: [Float], to n: Int = 160) -> [Float] {
            guard src.count > n else { return src }
            return (0..<n).map { src[($0 * src.count) / n] }
        }
        return ControlTelemetry(
            windowMS: clampedWindow,
            inputLeft: decimate(scopes.inputLeft),
            inputRight: decimate(scopes.inputRight),
            output: decimate(scopes.output),
            spectrumDB: spectrum.dbBins,
            spectrumMaxHz: spectrum.maxHz,
            spectrumNyquistHz: spectrum.nyquistHz
        )
    }

    var controlMeters: ControlMeters? {
        let m = meters
        // Ring-transport diagnostics: the level meters cannot distinguish
        // loud static from loud program (both peg the peak/deviation reads),
        // so clock-drift dropout is invisible there. These counters are the
        // definitive signal. captureXruns rolls up the ring over/underflows.
        let t = transportSnapshot
        return ControlMeters(
            inputLeftPeak: m.inputLeftPeak,
            inputRightPeak: m.inputRightPeak,
            outputPeak: m.outputPeak,
            deviationKHzPeak: m.deviationKHzPeak,
            dacPeakDBFS: m.dacPeak > 0.0 ? 20.0 * log10f(m.dacPeak) : -120.0,
            agcGainDB: m.agcGainDB,
            advancedDynamicsActive: m.advancedDynamicsActive,
            advancedDynamicsBandGainsDB: m.advancedDynamicsActive
                ? [m.adBandGain1DB, m.adBandGain2DB, m.adBandGain3DB,
                   m.adBandGain4DB, m.adBandGain5DB] : nil,
            advancedDynamicsDensityDB: m.advancedDynamicsActive
                ? m.advancedDynamicsDensityDB : nil,
            compositeClipperGainReductionDB: m.compositeClipperGainReductionDB,
            preEncodeLimiterGainReductionDB: m.preEncodeAudioLimiterGainReductionDB,
            safetyLimiterGainReductionDB: m.mpxSafetyLimiterGainReductionDB,
            safetyClipDB: m.mpxSafetyClipDB,
            pilotInjectionPercent: m.pilotInjectionPercent,
            rdsInjectionPercent: m.rdsInjectionPercent,
            compositeBudgetMarginDB: m.compositeBudgetMarginDB,
            compositeOverBudget: m.compositeOverBudget,
            stereoCorrelation: m.outputStereoCorrelation,
            renderXruns: nil,
            captureXruns: t.map { Int(clamping: $0.overflows &+ $0.underflows) },
            inputRingBufferedFrames: t?.bufferedFrames,
            inputRingOverflows: t.map { Int(clamping: $0.overflows) },
            inputRingUnderflows: t.map { Int(clamping: $0.underflows) },
            inputRingTornReads: t.map { Int(clamping: $0.tornReads) },
            inputResampleMode: t?.resampleMode,
            inputRatioTrim: t?.ratioTrim
        )
    }

    var rdsLiveSnapshotForControl: BasicRDSCoder.LiveSnapshot? {
        currentRDSLiveSnapshot
    }
}
#else
extension ALSAAudioEngine: ControlledEngine {
    var controlMeters: ControlMeters? {
        let peaks = peakMeters
        let xruns = xrunCounts
        let state = fullMeterState
        return ControlMeters(
            inputLeftPeak: peaks.inputL,
            inputRightPeak: peaks.inputR,
            outputPeak: peaks.output,
            deviationKHzPeak: state.deviationKHzPeak,
            dacPeakDBFS: state.dacPeak > 0.0 ? 20.0 * log10f(state.dacPeak) : -120.0,
            agcGainDB: state.agcGainDB,
            advancedDynamicsActive: state.advancedDynamicsActive,
            advancedDynamicsBandGainsDB: state.advancedDynamicsActive
                ? [state.adBandGain1DB, state.adBandGain2DB, state.adBandGain3DB,
                   state.adBandGain4DB, state.adBandGain5DB] : nil,
            advancedDynamicsDensityDB: state.advancedDynamicsActive
                ? state.advancedDynamicsDensityDB : nil,
            compositeClipperGainReductionDB: state.clipperGRDB,
            preEncodeLimiterGainReductionDB: state.preEncodeGRDB,
            safetyLimiterGainReductionDB: state.safetyGRDB,
            safetyClipDB: state.safetyClipDB,
            pilotInjectionPercent: state.pilotPercent,
            rdsInjectionPercent: state.rdsPercent,
            compositeBudgetMarginDB: state.budgetMarginDB,
            compositeOverBudget: state.overBudget,
            stereoCorrelation: nil,
            renderXruns: xruns.render,
            captureXruns: xruns.capture
        )
    }

    var rdsLiveSnapshotForControl: BasicRDSCoder.LiveSnapshot? {
        currentRDSLiveSnapshot
    }
}
#endif
