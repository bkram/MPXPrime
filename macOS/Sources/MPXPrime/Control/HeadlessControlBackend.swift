import Foundation

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

    init(
        config: AppConfig,
        configPath: String,
        engine: (any ControlledEngine)?,
        engineFactory: @escaping ControlEngineFactory,
        onConfigChange: (@Sendable (AppConfig) -> Void)? = nil,
        onNowPlaying: (@Sendable (String, String, String) -> Void)? = nil
    ) {
        self.config = config
        self.configPath = configPath
        self.engine = engine
        self.makeEngine = engineFactory
        self.onConfigChange = onConfigChange
        self.onNowPlaying = onNowPlaying
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
            outputMode: config.processedAudioOutput ? "processedAudio" : "mpxComposite",
            notes: notes
        )
    }

    func meters() -> ControlMeters? {
        engine?.controlMeters
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
            note: note)
    }

    func configSections() throws -> [String: [String: String]] {
        try ConfigPatch.sectionedValues(of: config)
    }

    func applyConfigPatch(_ patch: [String: String]) throws -> ConfigApplyResult {
        let (newConfig, outcomes, planes) = try ConfigPatch.apply(patch, to: config)
        config = newConfig
        if let engine {
            if planes.dspLive { engine.applyRuntimeConfig(newConfig) }
            if planes.rdsLive { engine.applyRDSRuntimeConfig(newConfig) }
            if planes.restartRequired { restartPending = true }
        }
        persist()
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
            "widener": PresetCatalog.widenerPresets.map(\.id),
            "multiband": PresetCatalog.multibandPresets.map(\.id)
        ]
    }

    func applyPreset(kind: String, id: String, intensity: Double?) throws -> ConfigApplyResult {
        var newConfig = config
        let title: String?
        switch kind.lowercased() {
        case "primebass":
            title = PresetCatalog.applyPrimeBass(id: id, to: &newConfig)
        case "widener":
            title = PresetCatalog.applyWidener(id: id, to: &newConfig)
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
        onConfigChange?(newConfig)
        return ConfigApplyResult(
            outcomes: [], appliedLive: engine != nil, restartPending: restartPending)
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

    private func persist() {
        do {
            try config.save(toINI: configPath)
        } catch {
            notes = ["config save failed: \(error)"]
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
            agcGainDB: m.agcGainDB,
            compositeClipperGainReductionDB: m.compositeClipperGainReductionDB,
            preEncodeLimiterGainReductionDB: m.preEncodeAudioLimiterGainReductionDB,
            safetyLimiterGainReductionDB: m.mpxSafetyLimiterGainReductionDB,
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
            agcGainDB: state.agcGainDB,
            compositeClipperGainReductionDB: state.clipperGRDB,
            preEncodeLimiterGainReductionDB: state.preEncodeGRDB,
            safetyLimiterGainReductionDB: state.safetyGRDB,
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
