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
    /// Side effects on config change (now-playing runner reconfigure).
    private let onConfigChange: (@Sendable (AppConfig) -> Void)?

    init(
        config: AppConfig,
        configPath: String,
        engine: (any ControlledEngine)?,
        engineFactory: @escaping ControlEngineFactory,
        onConfigChange: (@Sendable (AppConfig) -> Void)? = nil
    ) {
        self.config = config
        self.configPath = configPath
        self.engine = engine
        self.makeEngine = engineFactory
        self.onConfigChange = onConfigChange
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
            if engine == nil { try startEngine() }
        case .stop:
            stopEngine()
        case .restart:
            stopEngine()
            try startEngine()
        }
        return status()
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

    // MARK: - Lifecycle

    private func startEngine() throws {
        do {
            let fresh = try makeEngine(config)
            try fresh.start()
            engine = fresh
            startedAt = Date()
            restartPending = false
            notes = []
        } catch {
            throw ControlError.engineFailure(String(describing: error))
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
            captureXruns: nil
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
