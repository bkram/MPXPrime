// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MPXPrimeViewModel: ObservableObject {
    private struct RuntimeSnapshot {
        var config: AppConfig
        var sourceMode: String
        var monitorEnabled: Bool
        var processingBypass: Bool
        var inputGainDB: Double
        var selectedInputUID: String
        var selectedOutputUID: String
        var selectedMonitorUID: String
    }

    // Active = main window foreground/key, not minimized, not fully
    // occluded. Idle = app inactive / occluded / minimized. The idle
    // rate stays > 0 so the meter ballistics state remains warm and the
    // UI resumes immediately on bring-forward.
    //
    // Active rate held at 30 Hz: per-tick work in
    // `refreshMonitoringSnapshot` (5 String(format:) calls + 59
    // @Published writes + SwiftUI re-renders) runs on the main thread.
    // Pushing the timer to 60 Hz can preempt the audio render thread on
    // busy machines and cause input-ring / output-buffer drops.
    // Inline spectrum bumped 12 → 24 Hz for a visible smoothness win
    // without doubling main-thread cost; windowed visualizers stay at
    // 30 Hz which is comfortably smooth for the dedicated detached
    // panels.
    // GUI refresh profile is arch-tiered. SwiftUI scope/spectrum Path drawing is
    // main-thread bound, and older Intel Macs (every x86_64 host here) have far
    // lower per-core throughput than Apple Silicon, so the full-rate profile pegs
    // one core and the graphs lag (observed on an i7-9750H). The x86_64 slice
    // therefore runs a lighter profile (lower refresh rates + fewer inline spectrum
    // points); the arm64 slice keeps the original full-rate profile unchanged. This
    // is compile-time per universal-binary slice, so Apple Silicon carries zero
    // runtime cost or behaviour change.
    #if arch(x86_64)
    private static let monitoringRefreshHzActive: Double = 20.0
    private static let monitoringRefreshHzIdle: Double = 12.0
    private static let inlineMPXSpectrumRefreshHz: Double = 15.0
    private static let windowMPXSpectrumRefreshHz: Double = 20.0
    private static let windowPreMPXSpectrumRefreshHz: Double = 20.0
    private static let inlineMPXSpectrumBins: Int = 256
    private static let windowMPXSpectrumBins: Int = 384
    private static let preMPXSpectrumBins: Int = 128
    #else
    private static let monitoringRefreshHzActive: Double = 30.0
    // Idle rate (window occluded / app backgrounded / minimized). 20 Hz
    // keeps VU meters visibly responsive when glancing at the window from
    // another app while adjusting source levels. Well below the 60 Hz
    // preemption threshold for audio-thread safety.
    private static let monitoringRefreshHzIdle: Double = 20.0
    private static let inlineMPXSpectrumRefreshHz: Double = 24.0
    private static let windowMPXSpectrumRefreshHz: Double = 30.0
    private static let windowPreMPXSpectrumRefreshHz: Double = 30.0
    private static let inlineMPXSpectrumBins: Int = 384
    private static let windowMPXSpectrumBins: Int = 512
    private static let preMPXSpectrumBins: Int = 128
    #endif
    private static let meterAttackMS: Float = 18.0
    private static let meterReleaseMS: Float = 110.0
    private static let audioPeakMeterAttackMS: Float = 1.0
    private static let audioPeakMeterReleaseMS: Float = 180.0

    @Published var selectedSection: AppSection = .monitoring
    @Published var selectedProcessingTab: ProcessingTab = .overview
    @Published var selectedRDSTab: RDSTab = .control
    /// Phase 1 sidebar selection. `didSet` keeps the legacy enums in sync so
    /// the existing per-tab views (and any code branching on
    /// `selectedSection`) keep working without modification.
    @Published var selectedStage: Stage = .monitoring {
        didSet {
            if selectedSection != selectedStage.legacySection {
                selectedSection = selectedStage.legacySection
            }
            if let pt = selectedStage.legacyProcessingTab,
               selectedProcessingTab != pt {
                selectedProcessingTab = pt
            }
            if let rt = selectedStage.legacyRDSTab,
               selectedRDSTab != rt {
                selectedRDSTab = rt
            }
            lastStageInGroup[selectedStage.group] = selectedStage
        }
    }

    /// Whether processed-audio output mode is the selected output (drives UI
    /// gating of composite/RDS surfaces). Reflects the persisted config value.
    var processedAudioOutputActive: Bool { config.processedAudioOutput }

    /// A sidebar stage is hidden when processed-audio output is active and the
    /// stage only makes sense in the composite domain (RDS, composite clipper,
    /// BS.412). See `Stage.hiddenInProcessedAudio`.
    func isStageVisible(_ stage: Stage) -> Bool {
        !(processedAudioOutputActive && stage.hiddenInProcessedAudio)
    }

    /// If the current selection points at a stage hidden by the active output
    /// mode, snap back to the Processing overview. Called on engine (re)start so
    /// switching into processed-audio mode never leaves a stale RDS/composite pane.
    func normalizeSelectionForOutputMode() {
        if !isStageVisible(selectedStage) {
            selectedStage = .processingOverview
        }
    }
    /// Remembers the last visited stage per sidebar group so the
    /// ⌘1-⌘4 "Go to <Section>" shortcuts restore the sub-tab the user
    /// was last on in that group instead of always snapping to the
    /// group home. Seeded with each group's landing stage so a first
    /// jump lands somewhere sensible.
    private var lastStageInGroup: [Stage.Group: Stage] = [
        .monitoring: .monitoring,
        .processing: .processingOverview,
        .rds: .rdsControl,
        .tools: .testTone
    ]
    /// Whether a given sidebar stage has a "currently active" concept and,
    /// if so, whether it is on. Returns nil for stages with no single
    /// enable toggle (Monitoring, Overview, Core, Format Profile, Final
    /// Stage, Snapshots, RDS sub-tabs that inherit the master) — those
    /// rows never render an enabled-state dot. Mirrors Mail's pattern:
    /// only the section landing carries the badge.
    func isStageEnabled(_ stage: Stage) -> Bool? {
        switch stage {
        case .monitoring, .processingOverview, .processingFormatProfile,
             .processingCore, .processingFinalStage, .snapshots,
             .rdsProgram, .rdsRadiotext, .rdsLongPS, .rdsAF,
             .rdsSchedule, .rdsCarrier:
            return nil
        case .processingPhaseRotator: return config.phaseRotationEnabled
        // AGC / Multiband (and the per-band Expander + MB Limiter that run
        // inside the multiband stage) are bypassed while Advanced Dynamics
        // is enabled -- the dot shows the EFFECTIVE state, not the stored
        // flag, so a bypassed stage reads as off in the sidebar.
        case .processingAGC:
            return config.widebandAGCEnabled && !config.advancedDynamicsEnabled
        case .processingParametricEQ: return config.parametricEQEnabled
        case .processingMultiband:
            return config.multibandEnabled && !config.advancedDynamicsEnabled
        case .processingAdvancedDynamics: return config.advancedDynamicsEnabled
        case .processingExpander:
            return config.downwardExpanderEnabled && !config.advancedDynamicsEnabled
        case .processingMBLimiter:
            return config.multibandLimiterEnabled && !config.advancedDynamicsEnabled
        case .processingWidener: return config.stereoWidenEnabled
        case .processingPrimeBass: return config.primeBassEnabled
        case .processingBassClipper: return config.bassClipperEnabled
        case .processingDCClipper: return config.dcClipperEnabled
        case .processingHFClipper: return config.hfLimiterEnabled || config.hfClipperEnabled
        case .processingLimiter: return config.preEncodeAudioLimiterEnabled
        case .processingStereoCoder: return config.ssbStereoEnabled
        case .processingCompositeClipper: return config.compositeClipperEnabled
        case .processingBS412: return config.bs412Enabled
        case .rdsControl: return config.enRDS
        case .testTone: return config.sourceMode == "tone"
        }
    }

    /// Jump to the given sidebar group. If the user has visited a
    /// sub-tab in that group during this session, restore it;
    /// otherwise land on the group's home stage.
    func goToGroup(_ group: Stage.Group) {
        let target = lastStageInGroup[group] ?? {
            switch group {
            case .monitoring: return .monitoring
            case .processing: return .processingOverview
            case .rds: return .rdsControl
            case .tools: return .testTone
            }
        }()
        if selectedStage != target {
            selectedStage = target
        }
    }
    /// Phase 3 inspector visibility. Toggleable from View > Inspector.
    /// Defaults off so the redesign progressively reveals features —
    /// users who don't need the advanced cancel toggles or per-band
    /// detail panels never see the column.
    @Published var inspectorVisible: Bool = false
    /// Phase 4 active-band selector for the new Multiband editor —
    /// controls which band the per-band Threshold / Ratio / Attack /
    /// Release sliders re-target. 0 = Low, 1 = Mid, 2 = High.
    @Published var activeMultibandBand: Int = 1
    @Published var statusText: String = "Idle"
    /// Start-refusal message shown as an alert: statusText has no on-screen
    /// surface in Studio, and refusing to start MUST be visible (the user
    /// clicked Start and nothing began).
    @Published var startBlockedMessage: String?
    @Published var pendingRuntimeApply: Bool = false

    // Named snapshot slots — persistent operator-saved setups beyond
    // format profiles. Stored on disk as JSON alongside the INI; survive
    // app upgrades. 8 fixed slots; nil = empty. Operator names each save
    // ("Morning Show", "Saturday Night", "Live Sports").
    @Published var snapshots: [ConfigSnapshot?] = Array(repeating: nil, count: MPXPrimeViewModel.snapshotSlotCount)

    // Which snapshot's config is currently live (set on load + save), so the UI
    // can show which slot is active. nil = the live config came from the main
    // INI, not a snapshot. `activeSnapshotModified` flips true once any config
    // edit diverges from that snapshot.
    @Published var activeSnapshotID: UUID?
    @Published var activeSnapshotModified = false
    // The exact config the active snapshot holds. `activeSnapshotModified`
    // flips only when the live config actually differs from this baseline --
    // an EXACT comparison, replacing an earlier 0.6 s timer window that raced
    // against slow onChange settling after a programmatic load and produced
    // false "edited since loaded" flags.
    private var activeSnapshotBaselineConfig: AppConfig?

    static let snapshotSlotCount: Int = SnapshotStore.slotCount

    /// Snapshot file path derived from the config file path. Sibling
    /// file with `.snapshots.json` suffix so each distinct config gets
    /// its own snapshot file — important for `--config` overrides and
    /// for test isolation (concurrent tests with unique temp config
    /// paths get isolated snapshot files, not a shared one in the
    /// directory).
    var snapshotsFilePath: String {
        configPath + ".snapshots.json"
    }

    @Published var sourceMode: String
    @Published var monitorEnabled: Bool
    @Published var processingBypass: Bool
    @Published var inputGainDB: Double

    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputUID: String = ""
    @Published var selectedOutputUID: String = ""
    @Published var selectedMonitorUID: String = ""

    @Published var isRunning: Bool = false
    @Published var isTransitioning: Bool = false
    var runtimeText: String { get { telemetry.runtimeText } set { telemetry.runtimeText = newValue } }
    // Live monitoring telemetry lives on its own observable so a metering
    // tick does not invalidate the whole view model. These forward to it;
    // writer code in the update methods is unchanged. See LiveTelemetry.
    let telemetry = LiveTelemetry()
    var inputRingText: String { get { telemetry.inputRingText } set { telemetry.inputRingText = newValue } }
    var inputBufferValue: Double { get { telemetry.inputBufferValue } set { telemetry.inputBufferValue = newValue } }
    var inputBufferMax: Double { get { telemetry.inputBufferMax } set { telemetry.inputBufferMax = newValue } }
    var inputBufferWarning: Double { get { telemetry.inputBufferWarning } set { telemetry.inputBufferWarning = newValue } }
    var inputBufferCritical: Double { get { telemetry.inputBufferCritical } set { telemetry.inputBufferCritical = newValue } }
    /// Low-passed (~10 s time constant) version of `inputBufferValue /
    /// inputBufferMax`. Used by the Monitoring buffer-fill bar so the
    /// display shows trend rather than tick-by-tick wobble; raw
    /// `inputBufferValue` keeps its 30 Hz cadence for any logic that
    /// needs the instantaneous reading.
    var bufferFillSmoothed: Double { get { telemetry.bufferFillSmoothed } set { telemetry.bufferFillSmoothed = newValue } }
    var streamHealth: MonitoringStreamHealth { get { telemetry.streamHealth } set { telemetry.streamHealth = newValue } }

    var inputLLevel: Double { get { telemetry.inputLLevel } set { telemetry.inputLLevel = newValue } }
    var inputRLevel: Double { get { telemetry.inputRLevel } set { telemetry.inputRLevel = newValue } }
    var agcOutputLLevel: Double { get { telemetry.agcOutputLLevel } set { telemetry.agcOutputLLevel = newValue } }
    var agcOutputRLevel: Double { get { telemetry.agcOutputRLevel } set { telemetry.agcOutputRLevel = newValue } }
    var outputLevel: Double { get { telemetry.outputLevel } set { telemetry.outputLevel = newValue } }
    var modulationLevel: Double { get { telemetry.modulationLevel } set { telemetry.modulationLevel = newValue } }
    var inputLPeakHoldLevel: Double { get { telemetry.inputLPeakHoldLevel } set { telemetry.inputLPeakHoldLevel = newValue } }
    var inputRPeakHoldLevel: Double { get { telemetry.inputRPeakHoldLevel } set { telemetry.inputRPeakHoldLevel = newValue } }
    var agcOutputLPeakHoldLevel: Double { get { telemetry.agcOutputLPeakHoldLevel } set { telemetry.agcOutputLPeakHoldLevel = newValue } }
    var agcOutputRPeakHoldLevel: Double { get { telemetry.agcOutputRPeakHoldLevel } set { telemetry.agcOutputRPeakHoldLevel = newValue } }
    var outputPeakHoldLevel: Double { get { telemetry.outputPeakHoldLevel } set { telemetry.outputPeakHoldLevel = newValue } }
    var modulationPeakHoldLevel: Double { get { telemetry.modulationPeakHoldLevel } set { telemetry.modulationPeakHoldLevel = newValue } }
    @Published var stickyPeaksEnabled: Bool = true
    @Published var meterPeakHoldSeconds: Double = 1.5
    @Published var meterPeakFallDBPerSecond: Double = 18.0

    var inputLText: String { get { telemetry.inputLText } set { telemetry.inputLText = newValue } }
    var inputRText: String { get { telemetry.inputRText } set { telemetry.inputRText = newValue } }
    var agcOutputLText: String { get { telemetry.agcOutputLText } set { telemetry.agcOutputLText = newValue } }
    var agcOutputRText: String { get { telemetry.agcOutputRText } set { telemetry.agcOutputRText = newValue } }
    var outputText: String { get { telemetry.outputText } set { telemetry.outputText = newValue } }
    var modulationText: String { get { telemetry.modulationText } set { telemetry.modulationText = newValue } }

    var limiterStateText: String { get { telemetry.limiterStateText } set { telemetry.limiterStateText = newValue } }
    var limiterDetailText: String { get { telemetry.limiterDetailText } set { telemetry.limiterDetailText = newValue } }
    var compositeBudgetStateText: String { get { telemetry.compositeBudgetStateText } set { telemetry.compositeBudgetStateText = newValue } }
    var compositeCalibrationText: String { get { telemetry.compositeCalibrationText } set { telemetry.compositeCalibrationText = newValue } }
    var estimatedDeviationPeakKHz: Float { get { telemetry.estimatedDeviationPeakKHz } set { telemetry.estimatedDeviationPeakKHz = newValue } }
    var pilotInjectionPercentValue: Float { get { telemetry.pilotInjectionPercentValue } set { telemetry.pilotInjectionPercentValue = newValue } }
    var rdsInjectionPercentValue: Float { get { telemetry.rdsInjectionPercentValue } set { telemetry.rdsInjectionPercentValue = newValue } }
    var audioCompositePeakLinear: Float { get { telemetry.audioCompositePeakLinear } set { telemetry.audioCompositePeakLinear = newValue } }
    var compositeBudgetMarginDBValue: Float { get { telemetry.compositeBudgetMarginDBValue } set { telemetry.compositeBudgetMarginDBValue = newValue } }
    /// Post-injection overshoot envelope (from `CompositeCalibrationStatus`).
    /// Non-zero ⇒ pilot/RDS subcarriers are clipping at the final
    /// ±1.0 clamp because audio + subcarrier × outputGain exceeds
    /// budget. UI surfaces this as an over-budget warning so the
    /// operator can reduce outputGain / pilot / RDS levels.
    var postInjectionOvershootValue: Float { get { telemetry.postInjectionOvershootValue } set { telemetry.postInjectionOvershootValue = newValue } }
    /// True when the composite budget governor has muted the audio
    /// path — outputGain × subcarrier reservation left no headroom.
    var compositeOverBudget: Bool { get { telemetry.compositeOverBudget } set { telemetry.compositeOverBudget = newValue } }
    var compositeClipperGainReductionDBValue: Float { get { telemetry.compositeClipperGainReductionDBValue } set { telemetry.compositeClipperGainReductionDBValue = newValue } }
    var compositeClipperLookaheadGainReductionDBValue: Float { get { telemetry.compositeClipperLookaheadGainReductionDBValue } set { telemetry.compositeClipperLookaheadGainReductionDBValue = newValue } }
    var preEncodeLimiterGainReductionDBValue: Float { get { telemetry.preEncodeLimiterGainReductionDBValue } set { telemetry.preEncodeLimiterGainReductionDBValue = newValue } }
    var safetyLimiterGainReductionDBValue: Float { get { telemetry.safetyLimiterGainReductionDBValue } set { telemetry.safetyLimiterGainReductionDBValue = newValue } }
    var safetyClipDBValue: Float { get { telemetry.safetyClipDBValue } set { telemetry.safetyClipDBValue = newValue } }
    var stereoImageText: String { get { telemetry.stereoImageText } set { telemetry.stereoImageText = newValue } }
    var agcStateText: String { get { telemetry.agcStateText } set { telemetry.agcStateText = newValue } }
    var agcDetailText: String { get { telemetry.agcDetailText } set { telemetry.agcDetailText = newValue } }
    var advancedDynamicsActive: Bool { get { telemetry.advancedDynamicsActive } set { telemetry.advancedDynamicsActive = newValue } }
    var advancedDynamicsDetailText: String { get { telemetry.advancedDynamicsDetailText } set { telemetry.advancedDynamicsDetailText = newValue } }
    var multibandStateText: String { get { telemetry.multibandStateText } set { telemetry.multibandStateText = newValue } }
    var primeBassStateText: String { get { telemetry.primeBassStateText } set { telemetry.primeBassStateText = newValue } }
    var widenerStateText: String { get { telemetry.widenerStateText } set { telemetry.widenerStateText = newValue } }

    var rdsPS: String { get { telemetry.rdsPS } set { telemetry.rdsPS = newValue } }
    var rdsPI: String { get { telemetry.rdsPI } set { telemetry.rdsPI = newValue } }
    var rdsPTY: String { get { telemetry.rdsPTY } set { telemetry.rdsPTY = newValue } }
    var rdsPTYN: String { get { telemetry.rdsPTYN } set { telemetry.rdsPTYN = newValue } }
    var rdsAID: String { get { telemetry.rdsAID } set { telemetry.rdsAID = newValue } }
    var rdsLongPS: String { get { telemetry.rdsLongPS } set { telemetry.rdsLongPS = newValue } }
    var rdsRadiotext: String { get { telemetry.rdsRadiotext } set { telemetry.rdsRadiotext = newValue } }
    var rdsNowPlayingStatus: String { get { telemetry.rdsNowPlayingStatus } set { telemetry.rdsNowPlayingStatus = newValue } }

    var inputScopeLeft: [Float] { get { telemetry.inputScopeLeft } set { telemetry.inputScopeLeft = newValue } }
    var inputScopeRight: [Float] { get { telemetry.inputScopeRight } set { telemetry.inputScopeRight = newValue } }
    var outputScope: [Float] { get { telemetry.outputScope } set { telemetry.outputScope = newValue } }
    @Published var scopeTimebaseMS: Double = 10.0
    @Published var scopeAutoGainEnabled: Bool = true
    var mpxSpectrumDB: [Float] { get { telemetry.mpxSpectrumDB } set { telemetry.mpxSpectrumDB = newValue } }
    var mpxSpectrumMaxHz: Double { get { telemetry.mpxSpectrumMaxHz } set { telemetry.mpxSpectrumMaxHz = newValue } }
    var mpxSpectrumNyquistHz: Double { get { telemetry.mpxSpectrumNyquistHz } set { telemetry.mpxSpectrumNyquistHz = newValue } }
    @Published var scopesWindowVisible: Bool = false
    @Published var spectrumWindowVisible: Bool = false
    var preMPXSpectrumLeftDB: [Float] { get { telemetry.preMPXSpectrumLeftDB } set { telemetry.preMPXSpectrumLeftDB = newValue } }
    var preMPXSpectrumRightDB: [Float] { get { telemetry.preMPXSpectrumRightDB } set { telemetry.preMPXSpectrumRightDB = newValue } }
    var preMPXSpectrumMaxHz: Double { get { telemetry.preMPXSpectrumMaxHz } set { telemetry.preMPXSpectrumMaxHz = newValue } }
    var preMPXSpectrumNyquistHz: Double { get { telemetry.preMPXSpectrumNyquistHz } set { telemetry.preMPXSpectrumNyquistHz = newValue } }
    @Published var preMPXSpectrumWindowVisible: Bool = false
    @Published var levelsWindowVisible: Bool = false

    private let configPath: String
    private let nowPlayingState: NowPlayingState
    private let nowPlayingRunner: NowPlayingScriptRunner
    var config: AppConfig
    private var runningEngine: AudioOutputEngine?
    private var controlServerTask: Task<Void, Never>?
    private var activeRuntimeSnapshot: RuntimeSnapshot?
    private var monitorTimer: Timer?
    private var lastMonitorRefreshTime: TimeInterval?
    private var engineStartReference: TimeInterval?

    // Visibility state — drives the adaptive `monitorTimer` rate. The
    // timer fires at `monitoringRefreshHzActive` only when all three
    // are in the on-screen position; otherwise drops to
    // `monitoringRefreshHzIdle` so the smoothing state stays warm
    // without burning cycles when no pixels are being drawn.
    private var appIsActive: Bool = true
    private var mainWindowIsOccluded: Bool = false
    private var mainWindowIsMinimized: Bool = false
    private var lastAppliedRefreshHz: Double = 0.0

    private var desiredMonitoringRefreshHz: Double {
        let onScreen = appIsActive && !mainWindowIsOccluded && !mainWindowIsMinimized
        return onScreen ? Self.monitoringRefreshHzActive : Self.monitoringRefreshHzIdle
    }

    private var vuInputL: Float = 0.0
    private var vuInputR: Float = 0.0
    private var vuAGCOutputL: Float = 0.0
    private var vuAGCOutputR: Float = 0.0
    private var vuOutput: Float = 0.0
    private var vuModulation: Float = 0.0
    private var peakHoldInputL = AudioPeakHoldState()
    private var peakHoldInputR = AudioPeakHoldState()
    private var peakHoldAGCOutputL = AudioPeakHoldState()
    private var peakHoldAGCOutputR = AudioPeakHoldState()
    private var peakHoldOutput = AudioPeakHoldState()
    private var peakHoldModulation = PeakHoldState()
    private var limiterGRPeakHoldDB: Float = 0.0
    private var limiterGRPeakHoldRemaining: Double = 0.0

    private var smoothedInputScopeLeft: [Float] = Array(repeating: 0.0, count: 128)
    private var smoothedInputScopeRight: [Float] = Array(repeating: 0.0, count: 128)
    private var smoothedOutputScope: [Float] = Array(repeating: 0.0, count: 128)
    private var inputScopeLeftGain: Float = 1.0
    private var inputScopeRightGain: Float = 1.0
    private var outputScopeGain: Float = 1.0
    private var overflowHistory: [(time: TimeInterval, overflows: UInt64, underflows: UInt64)] = []
    private var lastOverflowTotal: UInt64 = 0
    private var lastUnderflowTotal: UInt64 = 0
    private var pendingConfigSnapshot: AppConfig?
    private var configSaveInFlight: Bool = false
    private var configWatchFD: Int32 = -1
    private var configWatchSource: DispatchSourceFileSystemObject?
    private var configReloadWorkItem: DispatchWorkItem?
    private var ignoreConfigReloadUntil: TimeInterval = 0.0
    private var lastSpectrumRefreshTime: TimeInterval?
    private var spectrumUpdateInFlight: Bool = false
    private var lastPreMPXSpectrumRefreshTime: TimeInterval?
    private var preMPXSpectrumUpdateInFlight: Bool = false
    private let spectrumQueue = DispatchQueue(label: "MPXPrime.MPXSpectrum", qos: .userInitiated)
    private let spectrumAnalyzer = MPXSpectrumAnalyzer()
    private let preMPXSpectrumAnalyzer = MPXSpectrumAnalyzer()
    private var spectrumInputScratch: [Float] = Array(repeating: 0.0, count: 4096)
    private var preMPXSpectrumLeftScratch: [Float] = Array(
        repeating: 0.0,
        count: AudioOutputEngine.preMPXSpectrumFrameCount
    )
    private var preMPXSpectrumRightScratch: [Float] = Array(
        repeating: 0.0,
        count: AudioOutputEngine.preMPXSpectrumFrameCount
    )

    /// Source of audio devices. The app passes the CoreAudio enumerator;
    /// unit tests pass a stub so a headless `swift test` never touches the
    /// audio HAL (and cannot provoke system dialogs about missing devices).
    private let deviceLister: () throws -> [AudioDevice]

    init(configPath: String,
         deviceLister: @escaping () throws -> [AudioDevice] = { try AudioDevices.list() }) {
        self.configPath = configPath
        self.deviceLister = deviceLister
        let loadedConfig: AppConfig
        var legacyProfileReset: String?
        do {
            let loaded = try AppConfig.loadReportingMigration(fromINI: configPath)
            loadedConfig = loaded.config
            legacyProfileReset = loaded.legacyProfileID
            if legacyProfileReset != nil {
                // Persist the reset so the station does not re-migrate on
                // every launch and the INI on disk matches what runs.
                try? loadedConfig.save(toINI: configPath)
            }
        } catch {
            loadedConfig = AppConfig()
            try? loadedConfig.save(toINI: configPath)
        }
        self.config = loadedConfig

        self.sourceMode = loadedConfig.sourceMode
        self.monitorEnabled = loadedConfig.monitorEnabled
        self.processingBypass = loadedConfig.processingBypass
        self.inputGainDB = loadedConfig.inputGainDB
        self.nowPlayingState = NowPlayingState()
        self.nowPlayingRunner = NowPlayingScriptRunner(state: self.nowPlayingState)
        self.nowPlayingRunner.setStatusHandler { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rdsNowPlayingStatus = status
                self.refreshMonitoringSnapshot()
            }
        }

        refreshDevices()
        nowPlayingRunner.updateConfig(loadedConfig)
        startConfigWatcher()
        if let legacy = legacyProfileReset {
            statusText =
                "Pre-0.45 config (profile '\(legacy)'): processing reset to the "
                + "'\(loadedConfig.formatProfileID)' Format Profile; RDS, interfaces and "
                + "calibration kept."
        } else if loadedConfig.safetyClipsAreThePeakController {
            // Same warning the headless runtime prints: nothing upstream of
            // the safety soft-clips controls peaks in this config.
            statusText =
                "Warning: Audio Limiter and Composite Clipper are both off -- the safety "
                + "soft-clips are the only peak controller. Re-apply a Format Profile."
        }
        loadSnapshotsFromDisk()
        refreshMonitoringSnapshot()
        startControlServerIfEnabled()
    }

    var autoStartEnabled: Bool { config.rdsAutoStart }

    var isBusy: Bool { isTransitioning }

    var configFilePath: String { configPath }

    var runtimeApplyPending: Bool { isRunning && pendingRuntimeApply }

    var runtimeApplyButtonTitle: String { "Apply Restart" }

    var runtimeApplyHintText: String {
        "Pending changes affect engine, routing, or encoder structure and require a restart to take effect."
    }

    var restartRequiredSettingsListText: String { kRestartRequiredSettingsListText }

    var ptyChoices: [(Int, String)] {
        Self.ptyNames(rbds: config.rdsPtyRBDS).enumerated().map { ($0.offset, $0.element) }
    }

    var primeBassPresetChoices: [PresetChoice] {
        PresetCatalog.primeBassPresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var widenerPresetChoices: [PresetChoice] {
        [PresetChoice(id: "custom", title: "Custom")]
            + PresetCatalog.widenerPresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var multibandPresetChoices: [PresetChoice] {
        PresetCatalog.multibandPresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var finalStagePresetChoices: [PresetChoice] {
        Self.finalStagePresets.map { PresetChoice(id: $0.id, title: $0.title) }
    }

    var rdsRows: [(String, String)] {
        [
            ("PS", rdsPS),
            ("PI", rdsPI),
            ("PTY", rdsPTY),
            ("PTYN", rdsPTYN),
            ("RT+ App ID", rdsAID),
            ("Long PS", rdsLongPS),
            ("Radiotext", rdsRadiotext),
            ("Now Playing", rdsNowPlayingStatus.replacingOccurrences(of: "Now Playing: ", with: ""))
        ]
    }

    func startMonitoringTimer() {
        applyMonitoringRefreshRate()
    }

    /// Recreate `monitorTimer` at the rate dictated by current visibility
    /// state. Called from `startMonitoringTimer()` and from each
    /// visibility-change setter; early-returns when the desired rate
    /// matches the currently-active rate to avoid timer-recreate churn
    /// on no-op state transitions.
    private func applyMonitoringRefreshRate() {
        let target = desiredMonitoringRefreshHz
        if target == lastAppliedRefreshHz, monitorTimer != nil {
            return
        }
        monitorTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / target, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMonitoringSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
        lastAppliedRefreshHz = target
        timer.fire()
    }

    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        applyMonitoringRefreshRate()
    }

    func setMainWindowOccluded(_ occluded: Bool) {
        guard mainWindowIsOccluded != occluded else { return }
        mainWindowIsOccluded = occluded
        applyMonitoringRefreshRate()
    }

    func setMainWindowMinimized(_ minimized: Bool) {
        guard mainWindowIsMinimized != minimized else { return }
        mainWindowIsMinimized = minimized
        applyMonitoringRefreshRate()
    }

    func shutdown() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        lastMonitorRefreshTime = nil
        nowPlayingRunner.stop()
        stopConfigWatcher()
        stopEngineIfNeeded()
    }

    func refreshDevices() {
        do {
            let devices = try deviceLister()
            inputDevices = devices.filter { $0.hasInput }
            outputDevices = devices.filter { $0.hasOutput }
            selectedInputUID = selectUID(uid: config.inputDeviceUID, name: config.inputDeviceName, from: inputDevices)
            selectedOutputUID = selectUID(uid: config.outputDeviceUID, name: config.outputDeviceName, from: outputDevices)
            selectedMonitorUID = selectUID(uid: config.monitorDeviceUID, name: config.monitorDeviceName, from: outputDevices)
            warnAboutUnavailablePreferredDevices()
        } catch {
            statusText = "Device scan failed: \(error)"
            inputDevices = []
            outputDevices = []
            selectedInputUID = ""
            selectedOutputUID = ""
            selectedMonitorUID = ""
        }
    }

    /// Status note when a remembered device isn't present, so the user knows we
    /// kept their choice (and did NOT silently switch to a different device).
    private func warnAboutUnavailablePreferredDevices() {
        var missing: [String] = []
        if !selectedInputUID.isEmpty, !inputDevices.contains(where: { $0.uid == selectedInputUID }) {
            missing.append("input \"\(config.inputDeviceName ?? selectedInputUID)\"")
        }
        if !selectedOutputUID.isEmpty, !outputDevices.contains(where: { $0.uid == selectedOutputUID }) {
            missing.append("output \"\(config.outputDeviceName ?? selectedOutputUID)\"")
        }
        if monitorEnabled, !selectedMonitorUID.isEmpty,
           !outputDevices.contains(where: { $0.uid == selectedMonitorUID }) {
            missing.append("monitor \"\(config.monitorDeviceName ?? selectedMonitorUID)\"")
        }
        if !missing.isEmpty {
            statusText = "Preferred \(missing.joined(separator: ", ")) device not connected -- "
                + "selection kept; reconnect it or pick another."
        }
    }

    func persistBasicConfig() {
        config.sourceMode = sourceMode
        config.monitorEnabled = monitorEnabled
        config.processingBypass = processingBypass
        config.inputGainDB = inputGainDB
        config.inputDeviceUID = selectedInputUID.isEmpty ? nil : selectedInputUID
        config.outputDeviceUID = selectedOutputUID.isEmpty ? nil : selectedOutputUID
        config.monitorDeviceUID = selectedMonitorUID.isEmpty ? nil : selectedMonitorUID
        // Remember the name only while the device is actually present, so an
        // unplugged device keeps its last-known name for re-matching.
        if let d = inputDevices.first(where: { $0.uid == selectedInputUID }) { config.inputDeviceName = d.name }
        if let d = outputDevices.first(where: { $0.uid == selectedOutputUID }) { config.outputDeviceName = d.name }
        if let d = outputDevices.first(where: { $0.uid == selectedMonitorUID }) { config.monitorDeviceName = d.name }
        saveConfig(restartRequired: isRunning)
    }

    func applyPendingRuntimeChanges() {
        guard runtimeApplyPending else { return }
        pendingRuntimeApply = false
        restartEngineWithStatus("Config changes")
    }

    func value<T>(for keyPath: KeyPath<AppConfig, T>) -> T {
        config[keyPath: keyPath]
    }

    func setConfigValue<T>(
        _ keyPath: WritableKeyPath<AppConfig, T>,
        _ value: T,
        runtimeDisposition: RuntimeChangeDisposition = .restart
    ) {
        publishConfigChange()
        config[keyPath: keyPath] = value
        saveConfig(restartRequired: runtimeDisposition == .restart)
        switch runtimeDisposition {
        case .live:
            applyLiveRuntimeConfigIfRunning()
        case .liveRDS:
            applyLiveRDSConfigIfRunning()
        case .restart, .none:
            break
        }
        updateNowPlayingRunner()
    }

    func configBinding<T>(
        _ keyPath: WritableKeyPath<AppConfig, T>,
        runtimeDisposition: RuntimeChangeDisposition = .restart
    ) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.setConfigValue(keyPath, $0, runtimeDisposition: runtimeDisposition) }
        )
    }

    func ptyBinding() -> Binding<Int> {
        Binding(
            get: { self.config.rdsPTY },
            set: { self.setConfigValue(\.rdsPTY, max(0, min(31, $0)), runtimeDisposition: .liveRDS) }
        )
    }

    func piBinding() -> Binding<String> {
        Binding(
            get: { self.config.rdsPI },
            set: {
                self.setConfigValue(\.rdsPI, Self.sanitizeHex($0, width: 4), runtimeDisposition: .liveRDS)
            }
        )
    }

    func hexByteBinding(_ keyPath: WritableKeyPath<AppConfig, String>) -> Binding<String> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: {
                self.setConfigValue(keyPath, Self.sanitizeHex($0, width: 2), runtimeDisposition: .liveRDS)
            }
        )
    }

    /// RDS injection level expressed as % of total FM deviation. Industry
    /// convention is to talk about RDS as "4 %", "5 %" etc. (Inovonics,
    /// Audemat, DEVA, BW Broadcast displays all use %). The INI key
    /// `rds_level` stays in kHz per EN 50067 / IEC 62106-2 so existing
    /// configs are back-compat; the GUI just shows the user-friendly unit.
    /// Mapping: % = kHz / 75 * 100 (75 kHz is total FM deviation).
    func rdsLevelPercentBinding() -> Binding<Double> {
        Binding(
            get: { self.config.rdsLevel / 75.0 * 100.0 },
            set: { newPercent in
                let kHz = max(0.0, min(7.5, newPercent / 100.0 * 75.0))
                self.setConfigValue(\.rdsLevel, kHz, runtimeDisposition: .restart)
            }
        )
    }

    /// Pilot tone level expressed as % of total FM deviation. ITU-R
    /// BS.450 / FCC §73.322 / EN 50067 all specify 8-10 % deviation;
    /// pro processors display this in %. The INI key `pilot_level` stays
    /// as the linear amplitude fraction (0.0..0.12) for back-compat with
    /// the underlying audio math. Mapping: % = fraction * 100.
    func pilotLevelPercentBinding() -> Binding<Double> {
        Binding(
            get: { self.config.pilotLevel * 100.0 },
            set: { newPercent in
                let fraction = max(0.0, min(0.12, newPercent / 100.0))
                self.setConfigValue(\.pilotLevel, fraction, runtimeDisposition: .live)
            }
        )
    }

    func oddTapBinding() -> Binding<Int> {
        Binding(
            get: { self.config.rdsGaussianTaps },
            set: { raw in
                let clamped = max(9, min(401, raw))
                let odd =
                    (clamped % 2 == 0) ? (clamped + 1 <= 401 ? clamped + 1 : clamped - 1) : clamped
                self.setConfigValue(\.rdsGaussianTaps, odd, runtimeDisposition: .restart)
            }
        )
    }

    func rtBufferTextBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { self.rtBufferText(at: index) },
            set: { self.setRTBufferText(at: index, text: $0) }
        )
    }

    func rtBufferEnabledBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { self.rtBufferEnabled(at: index) },
            set: { self.setRTBufferEnabled(at: index, enabled: $0) }
        )
    }

    func rtBufferLabel(_ index: Int) -> String {
        String(UnicodeScalar(65 + max(0, min(3, index))) ?? "A")
    }

    var enabledRTBufferIndices: [Int] {
        (0..<4).filter { index in
            rtBufferEnabled(at: index)
                && !rtBufferText(at: index).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func rtBufferText(at index: Int) -> String {
        switch index {
        case 0: return config.rdsRTA
        case 1: return config.rdsRTB
        case 2: return config.rdsRTC
        case 3: return config.rdsRTD
        default: return ""
        }
    }

    private func rtBufferEnabled(at index: Int) -> Bool {
        switch index {
        case 0: return config.rdsRTBufferAEnabled
        case 1: return config.rdsRTBufferBEnabled
        case 2: return config.rdsRTBufferCEnabled
        case 3: return config.rdsRTBufferDEnabled
        default: return false
        }
    }

    private func setRTBufferText(at index: Int, text: String) {
        publishConfigChange()
        switch index {
        case 0: config.rdsRTA = text
        case 1: config.rdsRTB = text
        case 2: config.rdsRTC = text
        case 3: config.rdsRTD = text
        default: break
        }
        saveConfig(restartRequired: false)
        applyLiveRDSConfigIfRunning()
    }

    private func setRTBufferEnabled(at index: Int, enabled: Bool) {
        publishConfigChange()
        switch index {
        case 0: config.rdsRTBufferAEnabled = enabled
        case 1: config.rdsRTBufferBEnabled = enabled
        case 2: config.rdsRTBufferCEnabled = enabled
        case 3: config.rdsRTBufferDEnabled = enabled
        default: break
        }
        let enabledBuffers = enabledRTBufferIndices
        if enabledBuffers.isEmpty {
            config.rdsRTActiveBuffer = 0
        } else if !enabledBuffers.contains(config.rdsRTActiveBuffer) {
            config.rdsRTActiveBuffer = enabledBuffers[0]
        }
        saveConfig(restartRequired: false)
        applyLiveRDSConfigIfRunning()
    }

    /// Apply a top-level "Station Format" profile. Atomic across the four
    /// per-stage preset systems (multiband / final-stage / PrimeBass /
    /// stereo widener) plus composite-clipper threshold/ceiling and final
    /// drive. Each per-stage apply call already routes through saveConfig
    /// + applyLiveRuntimeConfigIfRunning, so the chain is fully reconciled
    /// when this method returns.
    ///
    /// Per-stage knobs remain editable after a profile is applied; the
    /// stored `formatProfileID` is a cosmetic label (no "dirty" / modified
    /// indicator in v1 — the operator can re-pick the profile to restore
    /// its defaults).
    func applyFormatProfile(_ id: String) {
        publishConfigChange()
        guard let title = PresetCatalog.applyFormatProfile(id: id, to: &config) else {
            statusText = "Unknown format profile: \(id)"
            return
        }
        saveConfig(restartRequired: false)
        if id == "custom" {
            // Sentinel: label recorded, nothing else changed.
            statusText =
                isRunning
                ? "Format profile set to Custom (no settings changed)."
                : "Format profile set to Custom."
            return
        }
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded format profile \(title) live."
            : "Loaded format profile \(title)."
    }

    func formatProfileBinding() -> Binding<String> {
        Binding(
            get: { self.config.formatProfileID },
            set: { self.applyFormatProfile($0) }
        )
    }

    // MARK: - A/B compare

    // MARK: - Named snapshots

    /// Load persisted snapshots from disk into the in-memory `snapshots`
    /// array. Called from init. Missing or corrupt file → silent reset
    /// to empty slots (operator can still save new ones).
    func loadSnapshotsFromDisk() {
        // Delegates to the shared SnapshotStore (also used by the headless
        // backend's /api/snapshots) so the two stay one implementation.
        let file = SnapshotStore.load(configPath: configPath)
        self.snapshots = file.slots
        self.activeSnapshotID = file.activeID
        self.activeSnapshotModified = file.activeModified ?? false
        // Rebuild the exact-comparison baseline for the restored active slot.
        if let active = file.activeID,
           let snap = file.slots.compactMap({ $0 }).first(where: { $0.id == active }) {
            self.activeSnapshotBaselineConfig = try? AppConfig.loadFromINIString(snap.configINIText)
        } else {
            self.activeSnapshotBaselineConfig = nil
        }
    }

    /// Persist all slots to disk. JSON envelope wraps the per-slot
    /// `ConfigSnapshot` objects (which embed the config as INI text so
    /// schema migrations stay handled by the existing INI parser's
    /// defaults).
    func writeSnapshotsToDisk() {
        let file = SnapshotFile(
            slots: snapshots, activeID: activeSnapshotID, activeModified: activeSnapshotModified)
        do {
            try SnapshotStore.write(file, configPath: configPath)
        } catch {
            statusText = "Failed to write presets: \(error.localizedDescription)"
        }
    }

    /// Capture the current config into slot `slot` with the given name
    /// (empty → "Preset N"). Writes the file immediately so a crash
    /// doesn't lose the operator's save.
    func saveSnapshot(slot: Int, name: String) {
        guard (0..<snapshots.count).contains(slot) else { return }
        publishConfigChange()
        do {
            let ini = try config.captureAsINIString()
            let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = ConfigSnapshot(
                id: UUID(),
                name: resolvedName.isEmpty ? "Preset \(slot + 1)" : resolvedName,
                savedAt: Date(),
                configINIText: ini
            )
            snapshots[slot] = saved
            // The just-saved slot now mirrors the live config exactly.
            activeSnapshotID = saved.id
            activeSnapshotModified = false
            // Baseline is the ROUND-TRIPPED config (parse of what was written)
            // so later comparisons see exactly what a reload would produce.
            activeSnapshotBaselineConfig = try AppConfig.loadFromINIString(ini)
            writeSnapshotsToDisk()
            statusText = "Saved preset to slot \(slot + 1)."
        } catch {
            statusText = "Failed to save preset: \(error.localizedDescription)"
        }
    }

    /// Apply the snapshot in `slot` to the current config. Routes
    /// through `applyLoadedConfig` so live-apply / restart-required
    /// dispatching matches a normal disk load.
    func loadSnapshot(slot: Int) {
        guard (0..<snapshots.count).contains(slot),
              let snapshot = snapshots[slot] else { return }
        do {
            let loaded = try AppConfig.loadFromINIString(snapshot.configINIText)
            let outcome = applyLoadedConfig(loaded, origin: .manual)
            activeSnapshotID = snapshot.id
            activeSnapshotModified = false
            activeSnapshotBaselineConfig = loaded
            // Persist the loaded config to the main INI so disk == live, and
            // record the active preset so the "Loaded" marker survives relaunch.
            enqueueConfigSave(snapshot: config)
            writeSnapshotsToDisk()
            switch outcome {
            case .noChanges:
                statusText = "Loaded preset \"\(snapshot.name)\" - no changes."
            case .appliedLive:
                statusText = "Loaded preset \"\(snapshot.name)\" - applied live."
            case .restartPending:
                statusText = "Loaded preset \"\(snapshot.name)\". Restart-required changes are pending; use Apply Restart in Monitoring."
            case .storedWhileStopped:
                statusText = "Loaded preset \"\(snapshot.name)\"."
            }
        } catch {
            statusText = "Failed to load preset: \(error.localizedDescription)"
        }
    }

    /// Export the preset in `slot` to a file. The stored config IS a complete
    /// MPX Prime Studio INI, so the exported file doubles as a shareable config
    /// (loadable via --config or Import). Returns true on success.
    @discardableResult
    func exportSnapshot(slot: Int, to url: URL) -> Bool {
        guard (0..<snapshots.count).contains(slot), let snap = snapshots[slot] else { return false }
        do {
            try snap.configINIText.write(to: url, atomically: true, encoding: .utf8)
            statusText = "Exported preset \"\(snap.name)\" to \(url.lastPathComponent)."
            return true
        } catch {
            statusText = "Failed to export preset: \(error.localizedDescription)"
            return false
        }
    }

    /// Import an INI file into preset `slot`. Validates it parses, normalises it
    /// through the canonical writer, and names the preset from the filename.
    /// Populates the slot only (does not load it into the engine). Returns true
    /// on success.
    @discardableResult
    func importSnapshot(slot: Int, from url: URL) -> Bool {
        guard (0..<snapshots.count).contains(slot) else { return false }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try AppConfig.loadFromINIString(text)  // validate
            let canonical = try parsed.captureAsINIString()     // normalise
            let rawName = url.deletingPathExtension().lastPathComponent
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let imported = ConfigSnapshot(
                id: UUID(),
                name: name.isEmpty ? "Preset \(slot + 1)" : name,
                savedAt: Date(),
                configINIText: canonical)
            // Overwriting the active slot's content untethers the live config.
            if snapshots[slot]?.id == activeSnapshotID {
                activeSnapshotID = nil
                activeSnapshotModified = false
                activeSnapshotBaselineConfig = nil
            }
            snapshots[slot] = imported
            writeSnapshotsToDisk()
            statusText = "Imported preset \"\(imported.name)\" into slot \(slot + 1)."
            return true
        } catch {
            statusText = "Failed to import preset: \(error.localizedDescription)"
            return false
        }
    }

    /// A filesystem-safe default filename for exporting the preset in `slot`.
    func exportFilename(slot: Int) -> String {
        let base = snapshots[slot]?.name ?? "Preset \(slot + 1)"
        let safe = base.map { "/\\:?%*|\"<>".contains($0) ? "-" : $0 }
        let trimmed = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "Preset \(slot + 1)" : trimmed) + ".ini"
    }

    /// Drop the snapshot in `slot` and persist the empty state.
    func clearSnapshot(slot: Int) {
        guard (0..<snapshots.count).contains(slot) else { return }
        if snapshots[slot]?.id == activeSnapshotID {
            activeSnapshotID = nil
            activeSnapshotModified = false
            activeSnapshotBaselineConfig = nil
        }
        snapshots[slot] = nil
        writeSnapshotsToDisk()
        statusText = "Cleared preset slot \(slot + 1)."
    }

    /// Rename an existing snapshot in place (doesn't touch the stored
    /// config text — just the operator-facing label). Persists on
    /// every keystroke; the operator gets immediate save semantics
    /// without an explicit confirm button.
    func renameSnapshot(slot: Int, name: String) {
        guard (0..<snapshots.count).contains(slot),
              var snapshot = snapshots[slot] else { return }
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.name = resolvedName.isEmpty ? "Preset \(slot + 1)" : resolvedName
        snapshots[slot] = snapshot
        writeSnapshotsToDisk()
    }

    /// One-line description of the currently selected format profile,
    /// or a fallback string if the stored ID doesn't match any known
    /// profile (operator typed a custom value into INI).
    var currentFormatProfileSummary: String {
        Self.formatProfile(forID: config.formatProfileID)?.summary
            ?? "Custom (no matching format profile)."
    }

    func applyPrimeBassPreset(id: String) {
        // Parameter sets live in PresetCatalog (shared with the remote API).
        publishConfigChange()
        guard let title = PresetCatalog.applyPrimeBass(id: id, to: &config) else { return }
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded PrimeBass preset \(title) live."
            : "Loaded PrimeBass preset \(title)."
    }

    var currentWidenerPresetID: String {
        PresetCatalog.currentWidenerPresetID(of: config)
    }

    func applyWidenerPreset(id: String) {
        publishConfigChange()
        guard let title = PresetCatalog.applyWidener(id: id, to: &config) else { return }
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded image preset \(title) live."
            : "Loaded image preset \(title)."
    }

    func applyMultibandPreset(id: String, intensity: MultibandPresetIntensity) {
        publishConfigChange()
        guard let title = PresetCatalog.applyMultiband(id: id, intensity: intensity, to: &config)
        else { return }
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded Multiband preset \(title) (\(intensity.title)) live."
            : "Loaded Multiband preset \(title) (\(intensity.title))."
    }

    func applyFinalStagePreset(id: String) {
        publishConfigChange()
        guard let title = PresetCatalog.applyFinalStage(id: id, to: &config) else { return }
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
        statusText =
            isRunning
            ? "Loaded final-stage preset \(title) live."
            : "Loaded final-stage preset \(title)."
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)])
    }

    func reloadConfigFromDisk() {
        do {
            applyLoadedConfig(try AppConfig.load(fromINI: configPath), origin: .manual)
        } catch {
            statusText = "Config reload failed: \(error)"
        }
    }

    func resetToDefaults() {
        let savedSourceMode = sourceMode
        do {
            var defaults = AppConfig()
            defaults.sourceMode = savedSourceMode
            defaults.inputDeviceUID = selectedInputUID.isEmpty ? nil : selectedInputUID
            defaults.outputDeviceUID = selectedOutputUID.isEmpty ? nil : selectedOutputUID
            defaults.monitorEnabled = monitorEnabled
            defaults.monitorDeviceUID = selectedMonitorUID.isEmpty ? nil : selectedMonitorUID
            defaults.inputDeviceName = config.inputDeviceName
            defaults.outputDeviceName = config.outputDeviceName
            defaults.monitorDeviceName = config.monitorDeviceName
            try defaults.save(toINI: configPath)
            config = defaults
            sourceMode = config.sourceMode
            processingBypass = config.processingBypass
            inputGainDB = config.inputGainDB
            updateNowPlayingRunner()
            applyPendingRuntimeChanges()
            statusText = "Reset to defaults"
        } catch {
            statusText = "Reset failed: \(error)"
        }
    }

    func resetCurrentProcessingTabToDefaults() {
        publishConfigChange()
        let defaults = AppConfig()

        switch selectedProcessingTab {
        case .overview:
            // Overview has no detail parameters of its own — nothing to reset.
            return
        case .formatProfile:
            // Reset the format profile selector to the shipping default
            // (Community Radio); applies the matching per-stage settings
            // atomically through `applyFormatProfile`.
            applyFormatProfile(defaults.formatProfileID)
            return
        case .core:
            processingBypass = defaults.processingBypass
            inputGainDB = defaults.inputGainDB
            config.processingBypass = defaults.processingBypass
            config.inputGainDB = defaults.inputGainDB
            config.outputGainDB = defaults.outputGainDB
            config.monoMode = defaults.monoMode
            config.preemphasisUS = defaults.preemphasisUS
            config.hpfHz = defaults.hpfHz
            config.hfTrimDB = defaults.hfTrimDB
            config.hfTrimHz = defaults.hfTrimHz
            config.programLowpassHz = defaults.programLowpassHz
        case .agc:
            config.widebandAGCEnabled = defaults.widebandAGCEnabled
            config.widebandAGCTargetDB = defaults.widebandAGCTargetDB
            config.widebandAGCAttackMS = defaults.widebandAGCAttackMS
            config.widebandAGCReleaseMS = defaults.widebandAGCReleaseMS
            config.widebandAGCMaxGainDB = defaults.widebandAGCMaxGainDB
            config.widebandAGCMinGainDB = defaults.widebandAGCMinGainDB
        case .primeBass:
            config.primeBassEnabled = defaults.primeBassEnabled
            config.primeBassPresetID = defaults.primeBassPresetID
            config.primeBassAmount = defaults.primeBassAmount
            config.primeBassFreqHz = defaults.primeBassFreqHz
            config.primeBassHarmonics = defaults.primeBassHarmonics
            config.primeBassDrive = defaults.primeBassDrive
            config.primeBassDensity = defaults.primeBassDensity
            config.primeBassSubharmonicsEnabled = defaults.primeBassSubharmonicsEnabled
            config.primeBassSubharmonicsAmount = defaults.primeBassSubharmonicsAmount
        case .multiband:
            config.multibandEnabled = defaults.multibandEnabled
            config.multibandMode = defaults.multibandMode
            config.multibandPresetID = defaults.multibandPresetID
            config.multibandIntensity = defaults.multibandIntensity
            config.multibandX1Hz = defaults.multibandX1Hz
            config.multibandX2Hz = defaults.multibandX2Hz
            config.multibandX3Hz = defaults.multibandX3Hz
            config.multibandX4Hz = defaults.multibandX4Hz
            config.multibandLowThresholdDB = defaults.multibandLowThresholdDB
            config.multibandMidThresholdDB = defaults.multibandMidThresholdDB
            config.multibandHighThresholdDB = defaults.multibandHighThresholdDB
            config.multibandLowRatio = defaults.multibandLowRatio
            config.multibandMidRatio = defaults.multibandMidRatio
            config.multibandHighRatio = defaults.multibandHighRatio
            config.multibandLowAttackMS = defaults.multibandLowAttackMS
            config.multibandMidAttackMS = defaults.multibandMidAttackMS
            config.multibandHighAttackMS = defaults.multibandHighAttackMS
            config.multibandLowReleaseMS = defaults.multibandLowReleaseMS
            config.multibandMidReleaseMS = defaults.multibandMidReleaseMS
            config.multibandHighReleaseMS = defaults.multibandHighReleaseMS
            config.multibandKneeDB = defaults.multibandKneeDB
            config.multibandLinkStrength = defaults.multibandLinkStrength
            config.multibandReleaseProgramDependent = defaults.multibandReleaseProgramDependent
            config.multibandMakeupDB = defaults.multibandMakeupDB
        case .advancedDynamics:
            config.advancedDynamicsEnabled = defaults.advancedDynamicsEnabled
            config.advancedDynamicsTargetDB = defaults.advancedDynamicsTargetDB
            config.advancedDynamicsLowOffsetDB = defaults.advancedDynamicsLowOffsetDB
            config.advancedDynamicsMidOffsetDB = defaults.advancedDynamicsMidOffsetDB
            config.advancedDynamicsHighOffsetDB = defaults.advancedDynamicsHighOffsetDB
            config.advancedDynamicsMaxGainDB = defaults.advancedDynamicsMaxGainDB
            config.advancedDynamicsDensity = defaults.advancedDynamicsDensity
            config.advancedDynamicsSpeed = defaults.advancedDynamicsSpeed
        case .widener:
            config.stereoWidenEnabled = defaults.stereoWidenEnabled
            config.monoBassEnabled = defaults.monoBassEnabled
            config.monoBassFreqHz = defaults.monoBassFreqHz
            config.stereoWidenWidth = defaults.stereoWidenWidth
            config.stereoWidenCenter = defaults.stereoWidenCenter
            config.stereoWidenMix = defaults.stereoWidenMix
        case .limiter:
            config.preEncodeAudioLimiterEnabled = defaults.preEncodeAudioLimiterEnabled
            config.preEncodeThreshold = defaults.preEncodeThreshold
            config.preEncodeReleaseMS = defaults.preEncodeReleaseMS
            config.preEncodeLookaheadMS = defaults.preEncodeLookaheadMS
            config.preEncodeLookaheadHFOnly = defaults.preEncodeLookaheadHFOnly
            config.preEncodeLookaheadHFCutoffHz = defaults.preEncodeLookaheadHFCutoffHz
        case .finalStage:
            config.finalStagePresetID = defaults.finalStagePresetID
            config.finalDriveDB = defaults.finalDriveDB
            config.mpxDeviationKHz = defaults.mpxDeviationKHz
        case .stereoCoder:
            config.ssbStereoEnabled = defaults.ssbStereoEnabled
            config.ssbStereoAmount = defaults.ssbStereoAmount
        case .phaseRotator:
            config.phaseRotationEnabled = defaults.phaseRotationEnabled
            config.phaseRotationFreqHz = defaults.phaseRotationFreqHz
        case .parametricEQ:
            config.parametricEQEnabled = defaults.parametricEQEnabled
            config.peqB1FreqHz = defaults.peqB1FreqHz
            config.peqB1GainDB = defaults.peqB1GainDB
            config.peqB2FreqHz = defaults.peqB2FreqHz
            config.peqB2GainDB = defaults.peqB2GainDB
            config.peqB2Q = defaults.peqB2Q
            config.peqB3FreqHz = defaults.peqB3FreqHz
            config.peqB3GainDB = defaults.peqB3GainDB
            config.peqB3Q = defaults.peqB3Q
            config.peqB4FreqHz = defaults.peqB4FreqHz
            config.peqB4GainDB = defaults.peqB4GainDB
        case .mbLimiter:
            config.multibandLimiterEnabled = defaults.multibandLimiterEnabled
            config.multibandLimiterThresholdDB = defaults.multibandLimiterThresholdDB
            config.multibandLimiterAttackMS = defaults.multibandLimiterAttackMS
            config.multibandLimiterReleaseMS = defaults.multibandLimiterReleaseMS
        case .expander:
            config.downwardExpanderEnabled = defaults.downwardExpanderEnabled
            config.expanderThresholdDB = defaults.expanderThresholdDB
            config.expanderRatio = defaults.expanderRatio
            config.expanderAttackMS = defaults.expanderAttackMS
            config.expanderReleaseMS = defaults.expanderReleaseMS
        case .bassClipper:
            config.bassClipperEnabled = defaults.bassClipperEnabled
            config.bassClipperCrossoverHz = defaults.bassClipperCrossoverHz
            config.bassClipperThresholdDB = defaults.bassClipperThresholdDB
            config.bassClipperDrive = defaults.bassClipperDrive
        case .dcClipper:
            config.dcClipperEnabled = defaults.dcClipperEnabled
            config.dcClipperCeilingDB = defaults.dcClipperCeilingDB
            config.dcClipperCancelFreqHz = defaults.dcClipperCancelFreqHz
        case .hfClipper:
            config.hfClipperEnabled = defaults.hfClipperEnabled
            config.hfClipperCrossoverHz = defaults.hfClipperCrossoverHz
            config.hfClipperThresholdDB = defaults.hfClipperThresholdDB
            config.hfClipperDrive = defaults.hfClipperDrive
            config.hfLimiterEnabled = defaults.hfLimiterEnabled
            config.hfLimiterThresholdDB = defaults.hfLimiterThresholdDB
            config.hfLimiterAttackMS = defaults.hfLimiterAttackMS
            config.hfLimiterReleaseMS = defaults.hfLimiterReleaseMS
            config.hfLimiterMaxReductionDB = defaults.hfLimiterMaxReductionDB
        case .bs412:
            config.bs412Enabled = defaults.bs412Enabled
            config.bs412ThresholdDB = defaults.bs412ThresholdDB
            config.bs412WindowSeconds = defaults.bs412WindowSeconds
        case .compositeClipper:
            config.compositeClipperEnabled = defaults.compositeClipperEnabled
            config.compositeClipperThresholdDB = defaults.compositeClipperThresholdDB
            config.compositeClipperCeilingDB = defaults.compositeClipperCeilingDB
        }

        let runtimeDisposition: RuntimeChangeDisposition
        switch selectedProcessingTab {
        case .core:
            runtimeDisposition = .restart
        case .overview, .formatProfile,
             .phaseRotator, .agc, .parametricEQ,
             .multiband, .advancedDynamics, .mbLimiter, .expander,
             .widener, .primeBass,
             .bassClipper, .dcClipper, .hfClipper, .limiter,
             .stereoCoder, .compositeClipper, .bs412,
             .finalStage:
            runtimeDisposition = .live
        }

        saveConfig(restartRequired: runtimeDisposition == .restart)
        if runtimeDisposition == .restart {
            applyPendingRuntimeChanges()
        } else {
            applyLiveRuntimeConfigIfRunning()
        }
        statusText = selectedProcessingTab.resetStatusText
    }

    func resetCurrentRDSTabToDefaults() {
        publishConfigChange()
        let defaults = AppConfig()

        switch selectedRDSTab {
        case .control:
            // Control tab — operationally toggled state. Reset puts
            // master + flags back to library defaults.
            config.enRDS = defaults.enRDS
            config.rdsTP = defaults.rdsTP
            config.rdsTA = defaults.rdsTA
            config.rdsMS = defaults.rdsMS
            config.rdsDI_STEREO = defaults.rdsDI_STEREO
            config.rdsDI_HEAD = defaults.rdsDI_HEAD
            config.rdsDI_COMP = defaults.rdsDI_COMP
            config.rdsDI_DYN = defaults.rdsDI_DYN
        case .program:
            // enRDS lives on the Control tab; not reset here.
            config.rdsPI = defaults.rdsPI
            config.rdsECC = defaults.rdsECC
            config.rdsPTY = defaults.rdsPTY
            config.rdsPSA = defaults.rdsPSA
            config.rdsPSB = defaults.rdsPSB
            config.rdsPSC = defaults.rdsPSC
            config.rdsPSD = defaults.rdsPSD
            config.rdsPSActiveBank = defaults.rdsPSActiveBank
            config.rdsPSCentered = defaults.rdsPSCentered
            config.rdsEnablePTYN = defaults.rdsEnablePTYN
            config.rdsPTYN = defaults.rdsPTYN
            config.rdsPTYNCentered = defaults.rdsPTYNCentered
        case .radiotext:
            config.rdsRTText = defaults.rdsRTText
            config.rdsRTManualBuffers = defaults.rdsRTManualBuffers
            config.rdsRTCycleAB = defaults.rdsRTCycleAB
            config.rdsRTA = defaults.rdsRTA
            config.rdsRTB = defaults.rdsRTB
            config.rdsRTC = defaults.rdsRTC
            config.rdsRTD = defaults.rdsRTD
            config.rdsRTBufferAEnabled = defaults.rdsRTBufferAEnabled
            config.rdsRTBufferBEnabled = defaults.rdsRTBufferBEnabled
            config.rdsRTBufferCEnabled = defaults.rdsRTBufferCEnabled
            config.rdsRTBufferDEnabled = defaults.rdsRTBufferDEnabled
            config.rdsRTCR = defaults.rdsRTCR
            config.rdsRTCentered = defaults.rdsRTCentered
            config.rdsRTMode = defaults.rdsRTMode
            config.rdsRTCycle = defaults.rdsRTCycle
            config.rdsRTCycleTime = defaults.rdsRTCycleTime
            config.rdsRTActiveBuffer = defaults.rdsRTActiveBuffer
            config.rdsRTABCycleCount = defaults.rdsRTABCycleCount
            config.rdsEnableRTPlus = defaults.rdsEnableRTPlus
            config.rdsRTPlusFormatA = defaults.rdsRTPlusFormatA
            config.rdsRTPlusFormatB = defaults.rdsRTPlusFormatB
            config.rdsNowPlayingEnabled = defaults.rdsNowPlayingEnabled
            config.rdsNowPlayingScript = defaults.rdsNowPlayingScript
            config.rdsNowPlayingPollSeconds = defaults.rdsNowPlayingPollSeconds
            config.rdsNowPlayingTimeoutSeconds = defaults.rdsNowPlayingTimeoutSeconds
        case .longPS:
            config.rdsLongPS32 = defaults.rdsLongPS32
            config.rdsEnableLPS = defaults.rdsEnableLPS
            config.rdsLPSCentered = defaults.rdsLPSCentered
            config.rdsLPSCR = defaults.rdsLPSCR
        case .af:
            config.rdsEnableAF = defaults.rdsEnableAF
            config.rdsAFList = defaults.rdsAFList
            config.rdsAFMethod = defaults.rdsAFMethod
        case .schedule:
            config.rdsGroupSequence = defaults.rdsGroupSequence
            config.rdsSchedulerAuto = defaults.rdsSchedulerAuto
            config.rdsSchedulerStandard = defaults.rdsSchedulerStandard
            config.rdsSchedulerStandardLPS = defaults.rdsSchedulerStandardLPS
            config.rdsEnableCT = defaults.rdsEnableCT
            config.rdsEnableID = defaults.rdsEnableID
            config.rdsTZOffset = defaults.rdsTZOffset
            config.rdsLIC = defaults.rdsLIC
        case .carrier:
            config.rdsLevel = defaults.rdsLevel
            config.rdsGaussianEnabled = defaults.rdsGaussianEnabled
            config.rdsGaussianBWHZ = defaults.rdsGaussianBWHZ
            config.rdsGaussianTaps = defaults.rdsGaussianTaps
        }

        updateNowPlayingRunner()
        saveConfig(restartRequired: true)
        applyPendingRuntimeChanges()
        statusText = selectedRDSTab.resetStatusText
    }

    func loadConfigFromFile(_ path: String) {
        do {
            config = try AppConfig.load(fromINI: path)
            sourceMode = config.sourceMode
            monitorEnabled = config.monitorEnabled
            processingBypass = config.processingBypass
            inputGainDB = config.inputGainDB
            pendingRuntimeApply = false
            refreshDevices()
            updateNowPlayingRunner()
            statusText = "Config loaded: \(URL(fileURLWithPath: path).lastPathComponent)"
        } catch {
            statusText = "Config load failed: \(error)"
        }
    }

    func saveCurrentConfig() {
        saveConfig(restartRequired: false)
        statusText = "Config saved"
    }

    func saveConfigToFile(_ path: String) {
        do {
            try config.save(toINI: path)
            statusText = "Config saved: \(URL(fileURLWithPath: path).lastPathComponent)"
        } catch {
            statusText = "Config save failed: \(error)"
        }
    }

    func chooseNowPlayingScript() {
        let openPanel = NSOpenPanel()
        openPanel.message = "Choose a script to use for now playing metadata"
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose Script"
        if !config.rdsNowPlayingScript.isEmpty {
            let currentPath = NowPlayingFormatter.normalizeScriptPath(config.rdsNowPlayingScript)
            openPanel.directoryURL = URL(fileURLWithPath: (currentPath as NSString).deletingLastPathComponent)
            openPanel.nameFieldStringValue = URL(fileURLWithPath: currentPath).lastPathComponent
        }

        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            Task { @MainActor in
                self?.setConfigValue(\.rdsNowPlayingScript, url.path, runtimeDisposition: .none)
            }
        }
    }

    func startOrStopTransport(forceStart: Bool? = nil) {
        let shouldStart = forceStart ?? !isRunning
        if shouldStart {
            startEngine()
        } else {
            stopEngine()
        }
    }

    func toggleBypass() {
        processingBypass.toggle()
        persistBasicConfig()
        if isRunning {
            restartEngineWithStatus("Bypass updated")
        }
    }

    func resetPeaks() {
        clearPeakHolds()
        statusText = "Monitoring peaks reset"
    }

    func setInputGainLive(_ value: Double) {
        inputGainDB = value
        config.inputGainDB = value
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
    }

    /// Push the current `config.testTone*` and `config.sourceMode`
    /// values to the running engine via live-apply. Used by the Test
    /// Tone tab's bindings — every control there mutates the underlying
    /// AppConfig and then asks for the change to land on the running
    /// engine without restart. The view-model's own `sourceMode`
    /// mirror is updated first so `applyLiveRuntimeConfigIfRunning`'s
    /// override at line 2580 doesn't snap the runtime config back to
    /// the previous source.
    func applyLiveTestToneIfRunning() {
        sourceMode = config.sourceMode
        saveConfig(restartRequired: false)
        applyLiveRuntimeConfigIfRunning()
    }

    // MARK: - Remote control (REST API surface; called via GUIControlBackend)

    /// Whole-config apply for the remote API -- setConfigValue's semantics at
    /// patch granularity: mutate config, sync the VM runtime mirrors, save,
    /// hot-apply the classified planes, refresh now-playing.
    func applyRemoteConfigPatch(_ patch: [String: String]) throws -> ConfigApplyResult {
        let (newConfig, outcomes, planes) = try ConfigPatch.apply(patch, to: config)
        publishConfigChange()
        config = newConfig
        // The live-apply overlay reads these VM mirrors; sync them so
        // remote changes to the mirrored keys actually land.
        sourceMode = newConfig.sourceMode
        monitorEnabled = newConfig.monitorEnabled
        inputGainDB = newConfig.inputGainDB
        saveConfig(restartRequired: planes.restartRequired)
        if planes.dspLive { applyLiveRuntimeConfigIfRunning() }
        if planes.rdsLive { applyLiveRDSConfigIfRunning() }
        updateNowPlayingRunner()
        statusText = "Remote control: applied \(patch.count) setting(s)"
        return ConfigApplyResult(
            outcomes: outcomes,
            appliedLive: (planes.dspLive || planes.rdsLive) && isRunning,
            restartPending: runtimeApplyPending
        )
    }

    func remoteTelemetry(windowMS: Double) -> ControlTelemetry? {
        runningEngine?.controlTelemetry(windowMS: windowMS)
    }

    func remoteSnapshots() -> ControlSnapshots {
        ControlSnapshots(slots: snapshots.enumerated().map { i, snap in
            ControlSnapshotSlot(
                slot: i,
                name: snap?.name,
                savedAt: snap?.savedAt,
                active: snap != nil && snap?.id == activeSnapshotID,
                modified: snap != nil && snap?.id == activeSnapshotID && activeSnapshotModified)
        })
    }

    func remoteSnapshotExport(slot: Int) -> String? {
        guard snapshots.indices.contains(slot) else { return nil }
        return snapshots[slot]?.configINIText
    }

    func remoteSnapshotImport(slot: Int, name: String?, iniText: String) throws {
        guard snapshots.indices.contains(slot) else {
            throw ControlError.invalidRequest("slot out of range")
        }
        let parsed = try AppConfig.loadFromINIString(iniText)  // validate
        let canonical = try parsed.captureAsINIString()        // normalize
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let imported = ConfigSnapshot(
            id: UUID(),
            name: trimmed.isEmpty ? SnapshotStore.defaultName(slot: slot) : trimmed,
            savedAt: Date(),
            configINIText: canonical)
        if snapshots[slot]?.id == activeSnapshotID {
            activeSnapshotID = nil
            activeSnapshotModified = false
        }
        snapshots[slot] = imported
        writeSnapshotsToDisk()
        statusText = "Imported preset \"\(imported.name)\" into slot \(slot + 1) (remote)."
    }

    func remoteStatus() -> ControlStatus {
        ControlStatus(
            running: isRunning,
            platform: "macOS (GUI)",
            version: AppConfig.appVersion,
            sampleRateHz: config.sampleRate,
            uptimeSeconds: engineStartReference.map {
                Date().timeIntervalSinceReferenceDate - $0
            },
            restartPending: runtimeApplyPending,
            sourceMode: config.sourceMode,
            outputMode: config.processedAudioOutput ? "processedAudio" : "mpxComposite",
            notes: statusText.isEmpty ? [] : [statusText]
        )
    }

    func remoteMeters() -> ControlMeters? {
        runningEngine?.controlMeters
    }

    func remoteDevices() -> ControlDevices {
        ControlDevices(
            inputs: inputDevices.map {
                ControlDevice(id: $0.uid, name: $0.name, canInput: true, canOutput: $0.hasOutput)
            },
            outputs: outputDevices.map {
                ControlDevice(id: $0.uid, name: $0.name, canInput: $0.hasInput, canOutput: true)
            },
            selectedInput: config.inputDeviceUID ?? "",
            selectedOutput: config.outputDeviceUID ?? "",
            selectedMonitor: selectedMonitorUID,
            monitorEnabled: monitorEnabled,
            note: "")
    }

    func remoteRDS() -> ControlRDS {
        let live = runningEngine?.currentRDSLiveSnapshot
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

    /// API now-playing push -> the shared NowPlayingState (same sink as the
    /// local script poller). Returns whether now-playing rendering is on so
    /// the client can warn. The generator picks up the new snapshot live.
    func applyRemoteNowPlaying(artist: String, title: String, display: String) -> Bool {
        nowPlayingState.update(display: display, artist: artist, title: title)
        return config.rdsNowPlayingEnabled
    }

    func remoteTransport(_ action: TransportAction) -> ControlStatus {
        switch action {
        case .start: startOrStopTransport(forceStart: true)
        case .stop: startOrStopTransport(forceStart: false)
        case .restart: restartEngineWithStatus("Remote restart")
        }
        return remoteStatus()
    }

    func remotePresets() -> [String: [String]] {
        [
            "primebass": PresetCatalog.primeBassPresets.map(\.id),
            "widener": PresetCatalog.widenerPresets.map(\.id),
            "multiband": PresetCatalog.multibandPresets.map(\.id),
            "finalstage": PresetCatalog.finalStagePresets.map(\.id),
            "format_profile": PresetCatalog.formatProfiles.map(\.id)
        ]
    }

    func remoteApplyPreset(kind: String, id: String, intensity: Double?) throws {
        switch kind.lowercased() {
        case "primebass":
            guard PresetCatalog.primeBassPresets.contains(where: { $0.id == id }) else {
                throw ControlError.invalidRequest("unknown primebass preset '\(id)'")
            }
            applyPrimeBassPreset(id: id)
        case "widener":
            guard PresetCatalog.widenerPresets.contains(where: { $0.id == id }) else {
                throw ControlError.invalidRequest("unknown widener preset '\(id)'")
            }
            applyWidenerPreset(id: id)
        case "multiband":
            guard PresetCatalog.multibandPresets.contains(where: { $0.id == id }) else {
                throw ControlError.invalidRequest("unknown multiband preset '\(id)'")
            }
            let level: MultibandPresetIntensity
            switch intensity {
            case .some(let v) where v < 0.75: level = .light
            case .some(let v) where v > 1.25: level = .heavy
            default: level = .normal
            }
            applyMultibandPreset(id: id, intensity: level)
        case "finalstage":
            guard PresetCatalog.finalStagePresets.contains(where: { $0.id == id }) else {
                throw ControlError.invalidRequest("unknown finalstage preset '\(id)'")
            }
            applyFinalStagePreset(id: id)
        case "format_profile":
            guard Self.formatProfile(forID: id) != nil else {
                throw ControlError.invalidRequest("unknown format profile '\(id)'")
            }
            applyFormatProfile(id)
        default:
            throw ControlError.invalidRequest("unknown preset kind '\(kind)'")
        }
    }

    /// Start the control server once at launch when [CONTROL] enables it.
    /// Settings changes take effect at the next app launch (documented in
    /// the Settings card).
    func startControlServerIfEnabled() {
        guard config.controlEnabled, controlServerTask == nil else { return }
        let settings = ControlServerSettings(config: config)
        let backend = GUIControlBackend(vm: self)
        statusText = "Remote control: http://\(settings.host):\(settings.port)/"
        controlServerTask = Task {
            do {
                try await ControlServer.run(backend: backend, settings: settings)
            } catch {
                await MainActor.run {
                    self.statusText = "Remote control server failed: \(error)"
                }
            }
        }
    }

    private func applyLiveRuntimeConfigIfRunning() {
        guard isRunning, let runningEngine else { return }
        var runtimeConfig = config
        runtimeConfig.sourceMode = sourceMode
        runtimeConfig.monitorEnabled = monitorEnabled
        runtimeConfig.processingBypass = processingBypass
        runtimeConfig.inputGainDB = inputGainDB
        runningEngine.applyRuntimeConfig(runtimeConfig)
        pendingRuntimeApply = false
        statusText = "Live DSP parameters applied"
    }

    private func applyLiveRDSConfigIfRunning() {
        guard isRunning, let runningEngine else { return }
        runningEngine.applyRDSRuntimeConfig(config)
        pendingRuntimeApply = false
        statusText = "Live RDS text parameters applied"
    }

    private func captureRuntimeSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            config: config,
            sourceMode: sourceMode,
            monitorEnabled: monitorEnabled,
            processingBypass: processingBypass,
            inputGainDB: inputGainDB,
            selectedInputUID: selectedInputUID,
            selectedOutputUID: selectedOutputUID,
            selectedMonitorUID: selectedMonitorUID
        )
    }

    private func restoreRuntimeSnapshot(_ snapshot: RuntimeSnapshot) {
        config = snapshot.config
        sourceMode = snapshot.sourceMode
        monitorEnabled = snapshot.monitorEnabled
        processingBypass = snapshot.processingBypass
        inputGainDB = snapshot.inputGainDB
        selectedInputUID = snapshot.selectedInputUID
        selectedOutputUID = snapshot.selectedOutputUID
        selectedMonitorUID = snapshot.selectedMonitorUID
        updateNowPlayingRunner()
    }

    private func restartEngineWithStatus(_ status: String) {
        let wasRunning = isRunning
        let desiredSnapshot = captureRuntimeSnapshot()
        let fallbackSnapshot = activeRuntimeSnapshot
        stopEngine()
        if wasRunning {
            startEngine()
            if isRunning {
                statusText = "\(status) and applied"
                return
            }
            if let fallbackSnapshot {
                restoreRuntimeSnapshot(fallbackSnapshot)
                startEngine()
                if isRunning {
                    activeRuntimeSnapshot = fallbackSnapshot
                    restoreRuntimeSnapshot(desiredSnapshot)
                    pendingRuntimeApply = true
                    statusText = "\(status) failed; previous runtime restored. Pending changes kept."
                    return
                }
            }
            statusText = "\(status) failed; output remains stopped."
        }
    }

    private func startEngine() {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        stopEngineIfNeeded()
        persistBasicConfig()

        var runConfig = config
        runConfig.sourceMode = sourceMode
        runConfig.monitorEnabled = monitorEnabled
        runConfig.processingBypass = processingBypass
        runConfig.inputGainDB = inputGainDB

        let inputID: AudioDeviceID? = {
            guard runConfig.sourceMode.lowercased() == "input" else { return nil }
            return inputDevices.first(where: { $0.uid == selectedInputUID })?.id
        }()

        // Processed-audio output takes precedence over the decoded-MPX monitor
        // (the monitor is meaningless when no composite is generated). It uses the
        // main output device, not the monitor device.
        let processedAudio = runConfig.processedAudioOutput
        let useMonitor = monitorEnabled && !processedAudio
        let selectedOutUID = useMonitor ? selectedMonitorUID : selectedOutputUID
        let outputID: AudioDeviceID? = outputDevices.first(where: { $0.uid == selectedOutUID })?.id
        let outputMode: AudioOutputMode =
            processedAudio ? .processedAudio : (useMonitor ? .monitorAudio : .mpxComposite)

        // REFUSE to start when a PREFERRED device is unplugged, instead of
        // silently streaming to whatever the OS default happens to be (a
        // broadcast chain must never swap its transmitter feed unannounced;
        // matches the keep-the-selection convention of selectUID / the
        // device-scan warning). An empty UID (no preference ever chosen)
        // keeps the default-device behavior.
        var missingAtStart: [String] = []
        if runConfig.sourceMode.lowercased() == "input",
           !selectedInputUID.isEmpty, inputID == nil {
            missingAtStart.append("input \"\(config.inputDeviceName ?? selectedInputUID)\"")
        }
        if !selectedOutUID.isEmpty, outputID == nil {
            let roleName = useMonitor ? "monitor" : "output"
            let name = useMonitor
                ? (config.monitorDeviceName ?? selectedOutUID)
                : (config.outputDeviceName ?? selectedOutUID)
            missingAtStart.append("\(roleName) \"\(name)\"")
        }
        if !missingAtStart.isEmpty {
            let list = missingAtStart.joined(separator: ", ")
            statusText = "Not started: preferred \(list) device not connected -- "
                + "reconnect it or pick another device."
            startBlockedMessage = "The preferred \(list) device is not connected.\n\n"
                + "MPX Prime Studio will not silently use a different device: "
                + "reconnect the device, or choose another one in Settings, "
                + "then press Start again."
            isRunning = false
            return
        }

        let generator = MPXGenerator(
            config: runConfig,
            sampleRate: runConfig.sampleRate,
            nowPlayingState: nowPlayingState
        )
        let engine = AudioOutputEngine(
            generator: generator,
            config: runConfig,
            inputDeviceID: inputID,
            outputDeviceID: outputID,
            outputMode: outputMode
        )
        overflowHistory.removeAll(keepingCapacity: true)
        lastOverflowTotal = 0
        lastUnderflowTotal = 0
        clearPeakHolds()

        do {
            try engine.start()
            // Restart-equals-live, same guarantee as
            // HeadlessControlBackend.startEngine(): the generator/coder inits
            // are hand-written duplicates of the canonical RuntimeConfig /
            // RDSRuntimeConfig mappings, and nothing else pins them together.
            // Applying both planes to the fresh engine makes a rebuilt engine
            // equal to a live-applied one by construction (idempotent: the
            // engine was built from this same runConfig).
            engine.applyRuntimeConfig(runConfig)
            engine.applyRDSRuntimeConfig(runConfig)
            runningEngine = engine
            isRunning = true
            pendingRuntimeApply = false
            normalizeSelectionForOutputMode()
            if runConfig.processedAudioOutput {
                NSApp.sendAction(#selector(AppDelegate.closeCompositeOnlyAuxWindows), to: nil, from: nil)
            }
            activeRuntimeSnapshot = captureRuntimeSnapshot()
            engineStartReference = Date().timeIntervalSinceReferenceDate
            let mode = processedAudio ? "processed-audio" : (useMonitor ? "monitor" : "output")
            var line =
                "Running source=\(runConfig.sourceMode) mode=\(mode) "
                + "render=\(Int(engine.renderSampleRate))Hz hw=\(Int(engine.hardwareSampleRate))Hz"
            if let note = engine.deviceRoutingNote {
                line += " (\(note))"
            }
            statusText = line
            refreshMonitoringSnapshot()
        } catch AudioEngineError.inputPermissionDenied {
            statusText =
                "Microphone access denied. Open System Settings > Privacy & Security > Microphone "
                + "and enable MPX Prime, then press Start again."
            runningEngine = nil
            isRunning = false
        } catch {
            statusText = "Start failed: \(error)"
            runningEngine = nil
            isRunning = false
        }
    }

    private func stopEngine() {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        stopEngineIfNeeded()
        isRunning = false
        pendingRuntimeApply = false
        engineStartReference = nil
        overflowHistory.removeAll(keepingCapacity: true)
        lastOverflowTotal = 0
        lastUnderflowTotal = 0
        statusText = "Stopped"
        refreshMonitoringSnapshot()
    }

    private func stopEngineIfNeeded() {
        if let engine = runningEngine {
            engine.stop()
            runningEngine = nil
        }
    }

    /// Assign only when the value actually changed, so the slow-moving
    /// readout strings refreshed every monitor tick (20-30 Hz) don't fire
    /// objectWillChange when nothing moved -- Combine does not diff Equatable
    /// @Published values, so an unchanged write still invalidates every
    /// observing view. KeyPath-based rather than inout: an inout helper would
    /// write back through the @Published setter on every call and defeat the
    /// guard.
    @inline(__always)
    private func assignIfChanged<T: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<MPXPrimeViewModel, T>, _ value: T
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func refreshMonitoringSnapshot() {
        let now = Date().timeIntervalSinceReferenceDate
        let activeHz = desiredMonitoringRefreshHz
        let minRefreshInterval = 1.0 / activeHz
        if let last = lastMonitorRefreshTime, (now - last) < minRefreshInterval {
            return
        }

        // dt clamp for meter ballistics — independent of the active timer
        // rate. Lower bound is 1/120 s (8.3 ms) so a hypothetical 120 Hz
        // tick can't push smoothing below the per-step floor; upper bound
        // is 250 ms so a long pause (e.g. app backgrounded) doesn't make
        // the next on-screen tick look like an instantaneous jump.
        let fallbackInterval = 1.0 / activeHz
        let dt = max(
            1.0 / 120.0,
            min(0.25, now - (lastMonitorRefreshTime ?? (now - fallbackInterval)))
        )
        lastMonitorRefreshTime = now

        var inputPeak: Float = 0.0
        var outputPeak: Float = 0.0
        var deviationKHz: Float = 0.0
        var currentInputLeftPeak: Float = 0.0
        var currentInputRightPeak: Float = 0.0
        var currentAGCOutputLeftPeak: Float = 0.0
        var currentAGCOutputRightPeak: Float = 0.0
        var currentOutputPeak: Float = 0.0
        var liveInputLeftPeak: Float = 0.0
        var liveInputRightPeak: Float = 0.0
        var liveAGCOutputLeftPeak: Float = 0.0
        var liveAGCOutputRightPeak: Float = 0.0
        var liveOutputPeak: Float = 0.0
        var liveDeviationKHz: Float = 0.0
        var hasCapture = false
        var agcDetectorDB: Float = -120.0
        var agcGainDB: Float = 0.0
        var agcGateActive: Bool = false
        var advDynActive = false
        var advDynDensityDB: Float = 0.0
        var advDynBandGainsDB: (Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0)
        var compositeClipperGainReductionDB: Float = 0.0
        var compositeClipperLookaheadGainReductionDB: Float = 0.0
        var preEncodeAudioLimiterGainReductionDB: Float = 0.0
        var mpxSafetyLimiterGainReductionDB: Float = 0.0
        var mpxSafetyClipDB: Float = 0.0
        var pilotInjectionPercent: Float = 0.0
        var rdsInjectionPercent: Float = 0.0
        var audioCompositePeak: Float = 0.0
        var compositeBudgetMarginDB: Float = 0.0
        var postInjectionOvershoot: Float = 0.0
        var compositeOverBudget: Bool = false
        var outputStereoCorrelation: Float = 1.0
        var outputSideToMidRatio: Float = 0.0
        var health = MonitoringStreamHealth.stopped

        if let engine = runningEngine {
            updateEngineAnalysisCapture(engine: engine)
            let cap = engine.captureStats
            var runtime =
                "Running · Render \(Int(engine.renderSampleRate)) Hz · Hardware \(Int(engine.hardwareSampleRate)) Hz"
            if let inRate = engine.inputSampleRate {
                runtime += " · Input \(Int(inRate)) Hz"
            }
            runtime += " · Source \(engine.sourceDescription)"
            runtime += " · Applies \(engine.liveRuntimeApplyCount)"
            runtime += " · Skipped \(engine.skippedRuntimeApplyCount)"
            if let transport = engine.transportSnapshot {
                runtime += String(
                    format: " · Path %@ step %.4fx trim %.4f",
                    transport.resampleMode,
                    transport.sampleStep,
                    transport.ratioTrim
                )
            }
            runtimeText = runtime
            health.isRunning = true
            health.inputName =
                sourceMode.lowercased() == "tone"
                ? "Tone Generator"
                : (inputDevices.first(where: { $0.uid == selectedInputUID })?.name.ifEmpty("None")
                    ?? "None")
            health.renderHz = Int(engine.renderSampleRate.rounded())
            health.inputHz = Int((engine.inputSampleRate ?? 0).rounded())
            health.blockFrames = engine.blockSize

            if let stats = engine.inputStats {
                if let transport = engine.transportSnapshot {
                    inputRingText = String(
                        format: "Input Ring: %d frames buffered · Prime %d · Target %d · Overflows %llu · Underflows %llu · %@ %.4fx trim %.4f",
                        stats.bufferedFrames,
                        engine.inputPrimeFrames,
                        engine.inputTargetFrames,
                        stats.overflows,
                        stats.underflows,
                        transport.resampleMode,
                        transport.sampleStep,
                        transport.ratioTrim
                    )
                } else {
                    inputRingText =
                        "Input Ring: \(stats.bufferedFrames) frames buffered · Prime \(engine.inputPrimeFrames) · Target \(engine.inputTargetFrames) · Overflows \(stats.overflows) · Underflows \(stats.underflows)"
                }
                let target = max(1, engine.inputTargetFrames)
                inputBufferMax = Double(target * 2)
                inputBufferWarning = Double(target)
                inputBufferCritical = Double(target * 3 / 2)
                inputBufferValue = Double(stats.bufferedFrames)

                // Low-pass the displayed buffer fill (~10 s time
                // constant) so the Monitoring bar shows trend, not
                // tick-by-tick jitter. The buffer normally sits within
                // a few frames of target; operators care about
                // "trending up / down / steady," not the millisecond-
                // level wobble. Raw `inputBufferValue` is still
                // updated above and the delay text (`delayText`)
                // shows the instantaneous reading for any operator
                // who needs it. Cost of the longer τ: a real buffer
                // drop takes ~10 s to fully reflect on the bar; an
                // underflow event would also show up in `Dropouts`
                // tile much sooner, so this is OK.
                let rawFill = Double(stats.bufferedFrames) / max(1.0, inputBufferMax)
                let alpha = max(0.0, min(1.0, dt / (dt + 10.0)))
                bufferFillSmoothed =
                    (1.0 - alpha) * bufferFillSmoothed + alpha * rawFill

                let deltaOverflows =
                    stats.overflows >= lastOverflowTotal ? (stats.overflows - lastOverflowTotal) : 0
                let deltaUnderflows =
                    stats.underflows >= lastUnderflowTotal
                    ? (stats.underflows - lastUnderflowTotal) : 0
                lastOverflowTotal = stats.overflows
                lastUnderflowTotal = stats.underflows
                if deltaOverflows > 0 || deltaUnderflows > 0 {
                    overflowHistory.append((now, deltaOverflows, deltaUnderflows))
                }
                overflowHistory.removeAll { now - $0.time > 10.0 }

                health.ringFrames = stats.bufferedFrames
                health.ringCapacity = target * 2
                let recentOverflows = overflowHistory.reduce(UInt64(0)) { $0 + $1.overflows }
                let recentUnderflows = overflowHistory.reduce(UInt64(0)) { $0 + $1.underflows }
                health.overflowsRecent = Int(min(UInt64(Int.max), recentOverflows))
                health.underflowsRecent = Int(min(UInt64(Int.max), recentUnderflows))
                health.overflowsTotal = Int(min(UInt64(Int.max), stats.overflows))
                health.underflowsTotal = Int(min(UInt64(Int.max), stats.underflows))
            } else {
                inputRingText =
                    "Input Ring: inactive (tone source) · Capture callbacks \(cap.callbacks)"
                inputBufferValue = 0
                inputBufferMax = 1
                inputBufferWarning = 0.7
                inputBufferCritical = 0.9
                overflowHistory.removeAll(keepingCapacity: true)
                lastOverflowTotal = 0
                lastUnderflowTotal = 0
            }

            let meters = engine.meters
            hasCapture = cap.callbacks > 0
            inputPeak = hasCapture ? meters.inputPeak : meters.outputPeak
            outputPeak = meters.outputPeak
            deviationKHz = meters.deviationKHzPeak
            currentInputLeftPeak = hasCapture ? meters.inputLeftPeak : meters.outputPeak
            currentInputRightPeak = hasCapture ? meters.inputRightPeak : meters.outputPeak
            currentAGCOutputLeftPeak = meters.postAGCLeftPeak
            currentAGCOutputRightPeak = meters.postAGCRightPeak
            currentOutputPeak = meters.outputPeak
            liveInputLeftPeak = hasCapture ? meters.liveInputLeftPeak : meters.liveOutputPeak
            liveInputRightPeak = hasCapture ? meters.liveInputRightPeak : meters.liveOutputPeak
            liveAGCOutputLeftPeak = meters.livePostAGCLeftPeak
            liveAGCOutputRightPeak = meters.livePostAGCRightPeak
            liveOutputPeak = meters.liveOutputPeak
            liveDeviationKHz = meters.liveDeviationKHzPeak
            agcDetectorDB = meters.agcDetectorDB
            agcGainDB = meters.agcGainDB
            agcGateActive = meters.agcGateActive
            advDynActive = meters.advancedDynamicsActive
            advDynDensityDB = meters.advancedDynamicsDensityDB
            advDynBandGainsDB = (meters.adBandGain1DB, meters.adBandGain2DB,
                                 meters.adBandGain3DB, meters.adBandGain4DB,
                                 meters.adBandGain5DB)
            compositeClipperGainReductionDB = meters.compositeClipperGainReductionDB
            compositeClipperLookaheadGainReductionDB = meters.compositeClipperLookaheadGainReductionDB
            preEncodeAudioLimiterGainReductionDB = meters.preEncodeAudioLimiterGainReductionDB
            mpxSafetyLimiterGainReductionDB = meters.mpxSafetyLimiterGainReductionDB
            mpxSafetyClipDB = meters.mpxSafetyClipDB
            pilotInjectionPercent = meters.pilotInjectionPercent
            rdsInjectionPercent = meters.rdsInjectionPercent
            audioCompositePeak = meters.audioCompositePeak
            compositeBudgetMarginDB = meters.compositeBudgetMarginDB
            postInjectionOvershoot = meters.postInjectionOvershoot
            compositeOverBudget = meters.compositeOverBudget
            outputStereoCorrelation = meters.outputStereoCorrelation
            outputSideToMidRatio = meters.outputSideToMidRatio

            if engineStartReference == nil {
                engineStartReference = now
            }

            let scopesVisible = selectedSection == .monitoring || scopesWindowVisible
            if scopesVisible {
                updateScopes(engine: engine, inputPeak: inputPeak, outputPeak: outputPeak)
            }
            if selectedSection == .monitoring || spectrumWindowVisible {
                updateMPXSpectrum(engine: engine, now: now)
            }
            if preMPXSpectrumWindowVisible {
                updatePreMPXSpectrum(engine: engine, now: now)
            }
        } else {
            runtimeText = "Not running"
            inputRingText = "Input Ring: n/a"
            inputBufferValue = 0
            inputBufferMax = 1
            inputBufferWarning = 0.7
            inputBufferCritical = 0.9
            bufferFillSmoothed = 0.0
            engineStartReference = nil
            lastMonitorRefreshTime = now
            inputScopeLeft = Array(repeating: 0.0, count: 128)
            inputScopeRight = Array(repeating: 0.0, count: 128)
            outputScope = Array(repeating: 0.0, count: 128)
            smoothedInputScopeLeft = Array(repeating: 0.0, count: 128)
            smoothedInputScopeRight = Array(repeating: 0.0, count: 128)
            smoothedOutputScope = Array(repeating: 0.0, count: 128)
            inputScopeLeftGain = 1.0
            inputScopeRightGain = 1.0
            outputScopeGain = 1.0
            mpxSpectrumDB = Array(repeating: -100.0, count: Self.windowMPXSpectrumBins)
            mpxSpectrumMaxHz = 92_000.0
            mpxSpectrumNyquistHz = 0.0
            preMPXSpectrumLeftDB = Array(repeating: -100.0, count: Self.preMPXSpectrumBins)
            preMPXSpectrumRightDB = Array(repeating: -100.0, count: Self.preMPXSpectrumBins)
            preMPXSpectrumMaxHz = 16_000.0
            preMPXSpectrumNyquistHz = 0.0
            lastSpectrumRefreshTime = nil
            spectrumUpdateInFlight = false
            lastPreMPXSpectrumRefreshTime = nil
            preMPXSpectrumUpdateInFlight = false
            vuInputL = 0.0
            vuInputR = 0.0
            vuAGCOutputL = 0.0
            vuAGCOutputR = 0.0
            vuOutput = 0.0
            vuModulation = 0.0
            clearPeakHolds()
            limiterDetailText = String(
                format: "Drive %.1f dB • GR 0.0 dB • Max 0.0 dB • Safe 0.0 dB • Peak %@",
                config.finalDriveDB,
                Self.dbfsString(0.0)
            )
            compositeBudgetStateText = "Off"
            compositeCalibrationText = "Pilot 0.0% • RDS 0.0% • Audio -inf dBFS • Margin 0.0 dB"
            estimatedDeviationPeakKHz = 0.0
            pilotInjectionPercentValue = 0.0
            rdsInjectionPercentValue = 0.0
            audioCompositePeakLinear = 0.0
            compositeBudgetMarginDBValue = 0.0
            postInjectionOvershootValue = 0.0
            compositeOverBudget = false
            compositeClipperGainReductionDBValue = 0.0
            compositeClipperLookaheadGainReductionDBValue = 0.0
            preEncodeLimiterGainReductionDBValue = 0.0
            safetyLimiterGainReductionDBValue = 0.0
            safetyClipDBValue = 0.0
            stereoImageText = "Corr +1.00 • Side 0.00x"
            widenerStateText = "Off"
            overflowHistory.removeAll(keepingCapacity: true)
            lastOverflowTotal = 0
            lastUnderflowTotal = 0
        }
        streamHealth = health

        let modulationNorm = max(0.0, min(1.0, deviationKHz / 100.0))
        let inputLTarget = Self.levelMeterScale(currentInputLeftPeak)
        let inputRTarget = Self.levelMeterScale(currentInputRightPeak)
        let agcOutputLTarget = Self.levelMeterScale(currentAGCOutputLeftPeak)
        let agcOutputRTarget = Self.levelMeterScale(currentAGCOutputRightPeak)
        let outputTarget = Self.levelMeterScale(currentOutputPeak)
        let modulationTarget = modulationNorm

        vuInputL = smoothPeakProgramMeter(
            current: vuInputL,
            target: inputLTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuInputR = smoothPeakProgramMeter(
            current: vuInputR,
            target: inputRTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuAGCOutputL = smoothPeakProgramMeter(
            current: vuAGCOutputL,
            target: agcOutputLTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuAGCOutputR = smoothPeakProgramMeter(
            current: vuAGCOutputR,
            target: agcOutputRTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuOutput = smoothPeakProgramMeter(
            current: vuOutput,
            target: outputTarget,
            dt: dt,
            releaseMS: Self.audioPeakMeterReleaseMS
        )
        vuModulation = smoothMeter(
            current: vuModulation,
            target: modulationTarget,
            dt: dt,
            attackMS: Self.meterAttackMS,
            releaseMS: Self.meterReleaseMS
        )

        inputLLevel = Double(max(0.0, min(1.0, vuInputL)))
        inputRLevel = Double(max(0.0, min(1.0, vuInputR)))
        agcOutputLLevel = Double(max(0.0, min(1.0, vuAGCOutputL)))
        agcOutputRLevel = Double(max(0.0, min(1.0, vuAGCOutputR)))
        outputLevel = Double(max(0.0, min(1.0, vuOutput)))
        modulationLevel = Double(max(0.0, min(1.0, vuModulation)))

        let inputLPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveInputLeftPeak,
            state: &peakHoldInputL,
            dt: dt
        )
        let inputRPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveInputRightPeak,
            state: &peakHoldInputR,
            dt: dt
        )
        let agcOutputLPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveAGCOutputLeftPeak,
            state: &peakHoldAGCOutputL,
            dt: dt
        )
        let agcOutputRPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveAGCOutputRightPeak,
            state: &peakHoldAGCOutputR,
            dt: dt
        )
        let outputPeakHoldDB = updateAudioPeakHold(
            livePeakLinear: liveOutputPeak,
            state: &peakHoldOutput,
            dt: dt
        )
        inputLPeakHoldLevel = Double(Self.levelMeterScale(dbfs: inputLPeakHoldDB))
        inputRPeakHoldLevel = Double(Self.levelMeterScale(dbfs: inputRPeakHoldDB))
        agcOutputLPeakHoldLevel = Double(Self.levelMeterScale(dbfs: agcOutputLPeakHoldDB))
        agcOutputRPeakHoldLevel = Double(Self.levelMeterScale(dbfs: agcOutputRPeakHoldDB))
        outputPeakHoldLevel = Double(Self.levelMeterScale(dbfs: outputPeakHoldDB))
        modulationPeakHoldLevel = Double(
            updatePeakHold(
                livePeak: max(0.0, min(1.0, liveDeviationKHz / 100.0)),
                state: &peakHoldModulation,
                dt: dt
            ))
        let limiterGRPeakHold = updateLimiterGRPeakHold(
            liveValueDB: preEncodeAudioLimiterGainReductionDB,
            dt: dt
        )

        inputLText = Self.peakMeterString(currentPeak: currentInputLeftPeak, peakHoldDB: inputLPeakHoldDB)
        inputRText = Self.peakMeterString(currentPeak: currentInputRightPeak, peakHoldDB: inputRPeakHoldDB)
        agcOutputLText = Self.peakMeterString(currentPeak: currentAGCOutputLeftPeak, peakHoldDB: agcOutputLPeakHoldDB)
        agcOutputRText = Self.peakMeterString(currentPeak: currentAGCOutputRightPeak, peakHoldDB: agcOutputRPeakHoldDB)
        outputText = Self.peakMeterString(currentPeak: currentOutputPeak, peakHoldDB: outputPeakHoldDB)
        modulationText = String(format: "%5.1f kHz", deviationKHz)
        estimatedDeviationPeakKHz = deviationKHz
        pilotInjectionPercentValue = pilotInjectionPercent
        rdsInjectionPercentValue = rdsInjectionPercent
        audioCompositePeakLinear = audioCompositePeak
        compositeBudgetMarginDBValue = compositeBudgetMarginDB
        postInjectionOvershootValue = postInjectionOvershoot
        self.compositeOverBudget = compositeOverBudget
        compositeClipperGainReductionDBValue = compositeClipperGainReductionDB
        compositeClipperLookaheadGainReductionDBValue = compositeClipperLookaheadGainReductionDB
        preEncodeLimiterGainReductionDBValue = preEncodeAudioLimiterGainReductionDB
        safetyLimiterGainReductionDBValue = mpxSafetyLimiterGainReductionDB
        safetyClipDBValue = mpxSafetyClipDB

        let limiterState =
            config.preEncodeAudioLimiterEnabled
            ? (preEncodeAudioLimiterGainReductionDB >= 0.2 ? "Active" : "Idle") : "Off"
        assignIfChanged(\.limiterStateText, limiterState)
        assignIfChanged(\.limiterDetailText, String(
            format: "Drive %.1f dB • Pre-Enc GR %.1f dB • Max %.1f dB • Safe %.1f dB • Peak %@",
            config.finalDriveDB,
            preEncodeAudioLimiterGainReductionDB,
            limiterGRPeakHold,
            mpxSafetyLimiterGainReductionDB,
            Self.dbfsString(outputPeak)
        ))
        let compositeBudgetState: String
        if !isRunning {
            compositeBudgetState = "Off"
        } else if compositeBudgetMarginDB >= 3.0 {
            compositeBudgetState = "Safe"
        } else if compositeBudgetMarginDB >= 1.0 {
            compositeBudgetState = "Tight"
        } else {
            compositeBudgetState = "Risk"
        }
        assignIfChanged(\.compositeBudgetStateText, compositeBudgetState)
        assignIfChanged(\.compositeCalibrationText, String(
            format: "Pilot %.1f%% • RDS %.1f%% • Audio %@ • Margin %.1f dB",
            pilotInjectionPercent,
            rdsInjectionPercent,
            Self.dbfsString(audioCompositePeak),
            compositeBudgetMarginDB
        ))
        assignIfChanged(\.stereoImageText, String(
            format: "Corr %@%.2f • Side %.2fx",
            outputStereoCorrelation >= 0 ? "+" : "",
            outputStereoCorrelation,
            outputSideToMidRatio
        ))
        let agcState: String
        if config.widebandAGCEnabled && !config.advancedDynamicsEnabled && !processingBypass {
            agcState = agcGateActive ? "Gate" : "On"
        } else {
            agcState = "Off"
        }
        assignIfChanged(\.agcStateText, agcState)
        assignIfChanged(\.agcDetailText, String(
            format: "Detector %.1f dB • Gain %.1f dB",
            agcDetectorDB,
            agcGainDB
        ) + (agcGateActive ? " • Gate" : ""))
        assignIfChanged(\.advancedDynamicsActive, advDynActive)
        if advDynActive {
            assignIfChanged(\.advancedDynamicsDetailText, String(
                format: "Density %.1f dB • Gain %.1f/%.1f/%.1f/%.1f/%.1f dB",
                advDynDensityDB,
                advDynBandGainsDB.0, advDynBandGainsDB.1, advDynBandGainsDB.2,
                advDynBandGainsDB.3, advDynBandGainsDB.4
            ))
        }
        assignIfChanged(\.multibandStateText, config.multibandEnabled ? "On" : "Off")
        assignIfChanged(\.primeBassStateText, config.primeBassEnabled ? "On" : "Off")
        let widenerState: String
        if !config.stereoWidenEnabled || config.monoMode {
            widenerState = "Off"
        } else if outputStereoCorrelation < 0.0 || outputSideToMidRatio > 0.85 {
            widenerState = "Risk"
        } else if outputStereoCorrelation < 0.30 || outputSideToMidRatio > 0.55 {
            widenerState = "Wide"
        } else {
            widenerState = "Safe"
        }
        assignIfChanged(\.widenerStateText, widenerState)

        let elapsed = max(0.0, now - (engineStartReference ?? now))
        updateRDSFields(elapsed: elapsed)
    }

    private func updateEngineAnalysisCapture(engine: AudioOutputEngine) {
        let scopesVisible = selectedSection == .monitoring || scopesWindowVisible
        let inputHistoryVisible = scopesVisible || preMPXSpectrumWindowVisible
        let outputHistoryVisible = scopesVisible || spectrumWindowVisible
        engine.setAnalysisCapture(
            inputScope: inputHistoryVisible,
            outputHistory: outputHistoryVisible,
            preMPXHistory: preMPXSpectrumWindowVisible,
            outputImageMetrics: selectedSection == .monitoring
        )
    }

    private func updateScopes(engine: AudioOutputEngine, inputPeak: Float, outputPeak: Float) {
        let snapshot = engine.scopeSnapshot(windowMS: scopeTimebaseMS)
        if snapshot.inputLeft.isEmpty || snapshot.inputRight.isEmpty || snapshot.output.isEmpty {
            inputScopeLeft = Array(repeating: 0.0, count: 128)
            inputScopeRight = Array(repeating: 0.0, count: 128)
            outputScope = Array(repeating: 0.0, count: 128)
            smoothedInputScopeLeft = inputScopeLeft
            smoothedInputScopeRight = inputScopeRight
            smoothedOutputScope = outputScope
            inputScopeLeftGain = 1.0
            inputScopeRightGain = 1.0
            outputScopeGain = 1.0
            return
        }

        inputScopeLeft = smoothedScopeSamples(
            snapshot.inputLeft,
            fallbackPeak: inputPeak,
            previous: &smoothedInputScopeLeft,
            gainState: &inputScopeLeftGain,
            autoGain: scopeAutoGainEnabled
        )
        inputScopeRight = smoothedScopeSamples(
            snapshot.inputRight,
            fallbackPeak: inputPeak,
            previous: &smoothedInputScopeRight,
            gainState: &inputScopeRightGain,
            autoGain: scopeAutoGainEnabled
        )
        outputScope = smoothedScopeSamples(
            snapshot.output,
            fallbackPeak: outputPeak,
            previous: &smoothedOutputScope,
            gainState: &outputScopeGain,
            autoGain: scopeAutoGainEnabled
        )
    }

    private func updateMPXSpectrum(engine: AudioOutputEngine, now: TimeInterval) {
        let refreshHz =
            spectrumWindowVisible ? Self.windowMPXSpectrumRefreshHz : Self.inlineMPXSpectrumRefreshHz
        let refreshInterval = 1.0 / refreshHz
        if let last = lastSpectrumRefreshTime, (now - last) < refreshInterval {
            return
        }
        guard !spectrumUpdateInFlight else { return }
        lastSpectrumRefreshTime = now
        spectrumUpdateInFlight = true
        let raw = engine.outputSignalWindow(into: &spectrumInputScratch, frameCount: 4096)
        let sampleRate = raw.sampleRate
        let validCount = raw.count

        let maxDisplayHz: Double = config.fftWindow96kHz ? 96_000.0 : 60_000.0
        let displayBins =
            spectrumWindowVisible ? Self.windowMPXSpectrumBins : Self.inlineMPXSpectrumBins
        let analyzer = spectrumAnalyzer
        let samples = spectrumInputScratch
        spectrumQueue.async { [weak self] in
            let spectrum = analyzer.compute(
                samples: samples,
                validCount: validCount,
                sampleRate: sampleRate,
                displayBins: displayBins,
                maxDisplayHz: maxDisplayHz
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.mpxSpectrumDB = spectrum.dbBins
                self.mpxSpectrumMaxHz = spectrum.maxHz
                self.mpxSpectrumNyquistHz = spectrum.nyquistHz
                self.spectrumUpdateInFlight = false
            }
        }
    }

    private func updatePreMPXSpectrum(engine: AudioOutputEngine, now: TimeInterval) {
        let refreshInterval = 1.0 / Self.windowPreMPXSpectrumRefreshHz
        if let last = lastPreMPXSpectrumRefreshTime, (now - last) < refreshInterval {
            return
        }
        guard !preMPXSpectrumUpdateInFlight else { return }
        lastPreMPXSpectrumRefreshTime = now
        preMPXSpectrumUpdateInFlight = true
        let raw = engine.inputStereoWindow(
            intoLeft: &preMPXSpectrumLeftScratch,
            right: &preMPXSpectrumRightScratch,
            frameCount: AudioOutputEngine.preMPXSpectrumFrameCount
        )
        let sampleRate = raw.sampleRate
        let validCount = raw.count
        let leftSamples = preMPXSpectrumLeftScratch
        let rightSamples = preMPXSpectrumRightScratch
        let displayBins = Self.preMPXSpectrumBins
        let analyzer = preMPXSpectrumAnalyzer
        spectrumQueue.async { [weak self] in
            let maxDisplayHz = min(16_000.0, sampleRate * 0.5)
            let leftSpectrum = analyzer.compute(
                samples: leftSamples,
                validCount: validCount,
                sampleRate: sampleRate,
                displayBins: displayBins,
                maxDisplayHz: maxDisplayHz
            )
            let rightSpectrum = analyzer.compute(
                samples: rightSamples,
                validCount: validCount,
                sampleRate: sampleRate,
                displayBins: displayBins,
                maxDisplayHz: maxDisplayHz
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.preMPXSpectrumLeftDB = leftSpectrum.dbBins
                self.preMPXSpectrumRightDB = rightSpectrum.dbBins
                self.preMPXSpectrumMaxHz = leftSpectrum.maxHz
                self.preMPXSpectrumNyquistHz = leftSpectrum.nyquistHz
                self.preMPXSpectrumUpdateInFlight = false
            }
        }
    }

    private func smoothedScopeSamples(
        _ samples: [Float],
        fallbackPeak: Float,
        previous: inout [Float],
        gainState: inout Float,
        autoGain: Bool
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        if previous.count != samples.count {
            previous = Array(repeating: 0.0, count: samples.count)
        }

        let targetScale: Float
        if autoGain {
            let measuredPeak = samples.reduce(Float(0.0)) { current, value in
                max(current, fabsf(value.isFinite ? value : 0.0))
            }
            let fallback = fallbackPeak.isFinite ? max(0.0, min(2.0, fallbackPeak)) : 0.0
            // Target ~85% vertical utilization with bounded auto-gain.
            let referencePeak = max(0.01, min(1.2, max(measuredPeak, fallback * 0.55)))
            targetScale = min(8.0, max(1.0, 0.85 / referencePeak))
        } else {
            targetScale = 1.0
        }
        gainState = (gainState * 0.82) + (targetScale * 0.18)

        var smoothed = previous
        for i in samples.indices {
            let raw = samples[i].isFinite ? samples[i] : 0.0
            var sample = max(-1.2, min(1.2, raw)) * gainState
            if autoGain, fabsf(sample) < 0.0015 {
                sample *= 0.7
            }
            sample = max(-1.0, min(1.0, sample))
            smoothed[i] = (smoothed[i] * 0.62) + (sample * 0.38)
        }
        if smoothed.count > 2 {
            var spatial = smoothed
            for i in 1..<(smoothed.count - 1) {
                spatial[i] =
                    (smoothed[i - 1] * 0.12) + (smoothed[i] * 0.76) + (smoothed[i + 1] * 0.12)
            }
            smoothed = spatial
        }
        previous = smoothed
        return smoothed
    }

    private func updateRDSFields(elapsed: Double) {
        // Prefer the live snapshot from the running RDS coder when available,
        // so what's shown is exactly what's being transmitted (including PS
        // scroll windows, Nt: advance, now-playing macro resolution). Fall
        // back to the config-derived preview when the engine is offline.
        let live = runningEngine?.currentRDSLiveSnapshot

        if let live, !live.ps.isEmpty {
            assignIfChanged(\.rdsPS, live.ps)
        } else {
            assignIfChanged(\.rdsPS, Self.currentTimedDisplayText(config.activePSBankText, elapsed: elapsed).ifEmpty("-"))
        }
        assignIfChanged(\.rdsPI, config.rdsPI)
        assignIfChanged(\.rdsPTY, Self.ptyName(for: config.rdsPTY, rbds: config.rdsPtyRBDS))
        if let live, !live.ptyn.isEmpty {
            assignIfChanged(\.rdsPTYN, live.ptyn)
        } else {
            assignIfChanged(\.rdsPTYN, Self.currentTimedDisplayText(config.rdsPTYN, elapsed: elapsed).ifEmpty("-"))
        }
        assignIfChanged(\.rdsAID, config.rdsEnableRTPlus ? "AID: 4BD7 (GROUP 11A)" : "AID: OFF")
        if let live, !live.longPS.isEmpty {
            assignIfChanged(\.rdsLongPS, live.longPS)
        } else {
            assignIfChanged(\.rdsLongPS, Self.currentTimedDisplayText(config.rdsLongPS32, elapsed: elapsed).ifEmpty("-"))
        }
        if let live, !live.rt.isEmpty {
            // Trim trailing CR terminator (0x0D) that prepareRTFrame appends
            // for the 2A "end of text" marker so the on-screen readout is clean.
            assignIfChanged(\.rdsRadiotext, live.rt
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .ifEmpty("-"))
        } else {
            assignIfChanged(\.rdsRadiotext, currentRTText(elapsed: elapsed).ifEmpty("-"))
        }
    }

    private func currentRTText(elapsed: Double) -> String {
        let nowPlayingSnapshot = nowPlayingState.currentSnapshot()
        let enabledBuffers = enabledRTBufferIndices
        let text: String
        if !enabledBuffers.isEmpty {
            var sequence: [(duration: Double, text: String)] = []
            for index in enabledBuffers {
                let raw = rtBufferText(at: index)
                let expanded = NowPlayingFormatter.expandTemplate(raw, snapshot: nowPlayingSnapshot)
                sequence.append(
                    contentsOf: Self.parseRTBufferDisplaySequence(
                        expanded,
                        defaultDuration: max(1.0, config.rdsRTCycleTime)
                    )
                )
            }
            text = Self.currentTimedDisplayText(sequence: sequence, elapsed: elapsed)
        } else {
            let expanded = NowPlayingFormatter.expandTemplate(config.rdsRTText, snapshot: nowPlayingSnapshot)
            text = Self.currentTimedDisplayText(expanded, elapsed: elapsed)
        }
        let width = config.rdsRTMode.uppercased() == "2B" ? 32 : 64
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= width {
            return trimmed
        }
        return String(trimmed.prefix(width))
    }

    private static func currentTimedDisplayText(_ raw: String, elapsed: Double) -> String {
        let seq = parseTimedDisplaySequence(raw)
        return currentTimedDisplayText(sequence: seq, elapsed: elapsed)
    }

    private static func currentTimedDisplayText(
        sequence seq: [(duration: Double, text: String)],
        elapsed: Double
    ) -> String {
        guard !seq.isEmpty else { return "" }
        if seq.count == 1 {
            return seq[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let total = seq.reduce(0.0) { $0 + max(0.1, $1.duration) }
        let t = elapsed.truncatingRemainder(dividingBy: total)
        var acc: Double = 0.0
        for item in seq {
            acc += max(0.1, item.duration)
            if t <= acc {
                return item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return seq.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func parseRTBufferDisplaySequence(
        _ raw: String,
        defaultDuration: Double
    ) -> [(duration: Double, text: String)] {
        let sequence = parseTimedDisplaySequence(raw)
        guard !containsTimedDisplayCommand(raw) else { return sequence }
        let duration = max(0.1, defaultDuration)
        return sequence.map { (duration, $0.text) }
    }

    private static func containsTimedDisplayCommand(_ raw: String) -> Bool {
        raw.range(of: #"(^|[\s/])\d+(?:\.\d+)?s:"#, options: .regularExpression) != nil
    }

    private static let timedPrefixRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^([0-9]+(?:\.[0-9]+)?)s:"#, options: [])
    private static let timedTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"([0-9]+(?:\.[0-9]+)?)s:"#, options: [])

    private static func parseTimedDisplaySequence(_ raw: String) -> [(
        duration: Double, text: String
    )] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [(10.0, "")]
        }

        let slashParts = trimmed.split(separator: "/").map(String.init)
        if slashParts.count > 1 {
            var out: [(Double, String)] = []
            let prefixRegex = timedPrefixRegex
            for part in slashParts {
                let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if p.isEmpty { continue }
                if let prefixRegex {
                    let ns = p as NSString
                    if let match = prefixRegex.firstMatch(
                        in: p, options: [], range: NSRange(location: 0, length: ns.length)),
                        match.range.location == 0 {
                        let dur = Double(ns.substring(with: match.range(at: 1))) ?? 2.5
                        let textStart = match.range.location + match.range.length
                        let text = textStart < ns.length ? ns.substring(from: textStart) : ""
                        out.append((dur, text))
                        continue
                    }
                }
                out.append((2.5, p))
            }
            return out.isEmpty ? [(10.0, trimmed)] : out
        }

        if let tokenRegex = timedTokenRegex {
            let ns = trimmed as NSString
            let matches = tokenRegex.matches(
                in: trimmed, options: [], range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty, matches[0].range.location == 0 {
                var out: [(Double, String)] = []
                for (idx, match) in matches.enumerated() {
                    let durRange = match.range(at: 1)
                    let duration = Double(ns.substring(with: durRange)) ?? 2.5
                    let textStart = match.range.location + match.range.length
                    let textEnd =
                        (idx + 1 < matches.count) ? matches[idx + 1].range.location : ns.length
                    let textRange = NSRange(
                        location: textStart, length: max(0, textEnd - textStart))
                    let text = ns.substring(with: textRange).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    out.append((duration, text))
                }
                if !out.isEmpty {
                    return out
                }
            }
        }

        return [(10.0, trimmed)]
    }

    // Europe (RDS, EN 50067 / IEC 62106) PTY 0..31.
    private static let ptyNamesRDS: [String] = [
        "None", "News", "Current Affairs", "Information", "Sport", "Education", "Drama", "Culture",
        "Science", "Varied", "Pop Music", "Rock Music", "Easy Music", "Light Classical",
        "Serious Classical",
        "Other Music", "Weather", "Finance", "Children's", "Social Affairs", "Religion", "Phone-In",
        "Travel", "Leisure", "Jazz", "Country", "National Music", "Oldies", "Folk Music",
        "Documentary",
        "Alarm Test", "Alarm"
    ]

    // North America (RBDS, NRSC-4-B) PTY 0..31. Same 5-bit code as RDS, but
    // receivers in the US / Canada / Mexico / South Korea label it from this
    // table. Selected via the PTY region toggle (config.rdsPtyRBDS).
    private static let ptyNamesRBDS: [String] = [
        "None", "News", "Information", "Sports", "Talk", "Rock", "Classic Rock",
        "Adult Hits", "Soft Rock", "Top 40", "Country", "Oldies", "Soft", "Nostalgia", "Jazz",
        "Classical", "Rhythm and Blues", "Soft R&B", "Language", "Religious Music",
        "Religious Talk", "Personality", "Public", "College", "Spanish Talk", "Spanish Music",
        "Hip-Hop", "Unassigned", "Unassigned", "Weather", "Emergency Test", "Emergency"
    ]

    static func ptyNames(rbds: Bool) -> [String] { rbds ? ptyNamesRBDS : ptyNamesRDS }

    // Final-stage presets live in PresetCatalog (shared with the headless
    // backend's "finalstage" preset kind); forwarded for the picker.
    static var finalStagePresets: [PresetCatalog.FinalStagePreset] { PresetCatalog.finalStagePresets }

    // MARK: - Format Profiles (top-level "Station Format" selector)

    /// Format profiles live in PresetCatalog (shared with the headless
    /// backend's "format_profile" preset kind); forwarded for the picker
    /// and the tests.
    typealias FormatProfile = PresetCatalog.FormatProfile

    static var formatProfiles: [FormatProfile] { PresetCatalog.formatProfiles }

    static func formatProfile(forID id: String) -> FormatProfile? {
        PresetCatalog.formatProfile(forID: id)
    }

    private static func ptyName(for pty: Int, rbds: Bool) -> String {
        let names = ptyNames(rbds: rbds)
        if names.indices.contains(pty) {
            return names[pty]
        }
        return names[0]
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    private static func approxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func sanitizeHex(_ raw: String, width: Int) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let filtered = upper.filter { ch in
            switch ch {
            case "0"..."9", "A"..."F":
                return true
            default:
                return false
            }
        }
        if filtered.isEmpty {
            return String(repeating: "0", count: width)
        }
        if filtered.count >= width {
            return String(filtered.suffix(width))
        }
        return String(repeating: "0", count: width - filtered.count) + filtered
    }

    private func saveConfig(restartRequired: Bool) {
        // A user edit diverges the live config from the loaded preset. Flip
        // "edited since loaded" only when the config ACTUALLY differs from the
        // snapshot baseline -- binding churn after a programmatic load rewrites
        // identical values and must not flip it. Persist the flip once.
        if activeSnapshotID != nil, !activeSnapshotModified,
           let baseline = activeSnapshotBaselineConfig, config != baseline {
            activeSnapshotModified = true
            writeSnapshotsToDisk()
        }
        enqueueConfigSave(snapshot: config)
        if restartRequired && isRunning {
            if !pendingRuntimeApply {
                statusText = "Restart required for engine, routing, or encoder-structure changes. Use Apply Restart in Monitoring."
            }
            pendingRuntimeApply = true
        }
    }

    private func updateNowPlayingRunner() {
        nowPlayingRunner.updateConfig(config)
    }

    enum ConfigReloadOrigin {
        case manual
        case external
    }

    enum RuntimeChangeDisposition {
        /// Setting requires the engine to be stopped and restarted to take effect.
        case restart
        /// Setting flows through the DSP runtime config and applies live.
        case live
        /// Setting flows through the RDS runtime config and applies live.
        case liveRDS
        /// Setting takes effect via a side channel (e.g. Now Playing
        /// script reload) that doesn't need either runtime apply.
        case none
    }

    /// Outcome of a programmatic config swap, so callers (preset load,
    /// disk reload) can phrase their status line around what actually
    /// happened instead of a blanket "changes pending".
    enum ConfigLoadOutcome {
        case noChanges
        case appliedLive
        case restartPending
        case storedWhileStopped
    }

    @discardableResult
    func applyLoadedConfig(_ loadedConfig: AppConfig, origin: ConfigReloadOrigin) -> ConfigLoadOutcome {
        // Classify the ACTUAL diff with the canonical derived classifier
        // (ConfigPatch, the same one the REST API uses) instead of blanket
        // "restart-required": a load that changes nothing says so, a load
        // that only moves live/live-RDS keys applies live with no restart
        // nag, and only a genuine restart-class diff arms Apply Restart.
        let oldConfig = config
        var planes = ConfigChangePlanes()
        var changedAnything = loadedConfig != oldConfig
        if changedAnything, let old = try? ConfigPatch.sectionedValues(of: oldConfig),
           let new = try? ConfigPatch.sectionedValues(of: loadedConfig) {
            var patch: [String: String] = [:]
            for (section, bucket) in new {
                for (key, value) in bucket where old[section]?[key] != value {
                    patch[key] = value
                }
            }
            if let outcome = try? ConfigPatch.apply(patch, to: oldConfig) {
                planes = outcome.planes
            } else {
                planes.restartRequired = true   // classification failed: be safe
            }
        } else if changedAnything {
            planes.restartRequired = true       // serialization failed: be safe
        } else {
            changedAnything = false
        }

        config = loadedConfig
        sourceMode = config.sourceMode
        monitorEnabled = config.monitorEnabled
        processingBypass = config.processingBypass
        inputGainDB = config.inputGainDB
        refreshDevices()
        updateNowPlayingRunner()

        let source = origin == .external ? "Config reloaded from disk" : "Config reloaded"
        if !changedAnything {
            statusText = "\(source) - no changes."
            return .noChanges
        } else if isRunning && !planes.restartRequired {
            if planes.dspLive { applyLiveRuntimeConfigIfRunning() }
            if planes.rdsLive { applyLiveRDSConfigIfRunning() }
            statusText = "\(source) - applied live."
            return .appliedLive
        } else if isRunning {
            pendingRuntimeApply = true
            statusText = "\(source). Restart-required changes are pending; use Apply Restart in Monitoring."
            return .restartPending
        } else {
            pendingRuntimeApply = false
            statusText = source
            return .storedWhileStopped
        }
    }

    private func startConfigWatcher() {
        stopConfigWatcher()
        let directory = (configPath as NSString).deletingLastPathComponent
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        configWatchFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleExternalConfigReloadIfNeeded()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.configWatchFD >= 0 {
                close(self.configWatchFD)
                self.configWatchFD = -1
            }
        }
        configWatchSource = source
        source.resume()
    }

    private func stopConfigWatcher() {
        configReloadWorkItem?.cancel()
        configReloadWorkItem = nil
        configWatchSource?.cancel()
        configWatchSource = nil
        if configWatchFD >= 0 {
            close(configWatchFD)
            configWatchFD = -1
        }
    }

    private func scheduleExternalConfigReloadIfNeeded() {
        let now = Date().timeIntervalSinceReferenceDate
        if now < ignoreConfigReloadUntil {
            return
        }
        configReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            if now < self.ignoreConfigReloadUntil {
                return
            }
            do {
                try self.applyExternalConfigReloadIfChanged()
            } catch {
                self.statusText = "Config reload failed: \(error)"
            }
        }
        configReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func applyExternalConfigReloadIfChanged() throws {
        let loaded = try AppConfig.load(fromINI: configPath)
        applyLoadedConfig(loaded, origin: .external)
    }

    private func publishConfigChange() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func enqueueConfigSave(snapshot: AppConfig) {
        pendingConfigSnapshot = snapshot
        guard !configSaveInFlight else { return }
        configSaveInFlight = true
        processPendingConfigSave()
    }

    private func processPendingConfigSave() {
        guard let snapshot = pendingConfigSnapshot else {
            configSaveInFlight = false
            return
        }
        pendingConfigSnapshot = nil
        let path = configPath

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var saveError: Error?
            do {
                try snapshot.save(toINI: path)
            } catch {
                saveError = error
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if let saveError {
                    self.statusText = "Config save failed: \(saveError)"
                } else {
                    self.ignoreConfigReloadUntil = Date().timeIntervalSinceReferenceDate + 0.75
                }
                self.processPendingConfigSave()
            }
        }
    }

    /// Resolve which device UID to select, preferring stability over convenience:
    /// 1. exact UID match; 2. same device on a different port (UID changed, name
    /// matches) -> adopt its new UID; 3. a device WAS chosen but isn't connected
    /// -> keep the preference so it reconnects (do NOT silently switch to another
    /// device); 4. only with no prior preference at all, default to the first.
    private func selectUID(uid: String?, name: String?, from devices: [AudioDevice]) -> String {
        if let uid, !uid.isEmpty, devices.contains(where: { $0.uid == uid }) {
            return uid
        }
        if let name, !name.isEmpty, let byName = devices.first(where: { $0.name == name }) {
            return byName.uid
        }
        if let uid, !uid.isEmpty {
            return uid   // remembered device is unplugged -- keep it, don't substitute
        }
        return devices.first?.uid ?? ""
    }

    private func clearPeakHolds() {
        peakHoldInputL = AudioPeakHoldState()
        peakHoldInputR = AudioPeakHoldState()
        peakHoldAGCOutputL = AudioPeakHoldState()
        peakHoldAGCOutputR = AudioPeakHoldState()
        peakHoldOutput = AudioPeakHoldState()
        peakHoldModulation = PeakHoldState()
        limiterGRPeakHoldDB = 0.0
        limiterGRPeakHoldRemaining = 0.0
        inputLPeakHoldLevel = 0.0
        inputRPeakHoldLevel = 0.0
        agcOutputLPeakHoldLevel = 0.0
        agcOutputRPeakHoldLevel = 0.0
        outputPeakHoldLevel = 0.0
        modulationPeakHoldLevel = 0.0
    }

    private func updatePeakHold(livePeak: Float, state: inout PeakHoldState, dt: Double) -> Float {
        let live = max(0.0, min(1.0, livePeak.isFinite ? livePeak : 0.0))
        if !stickyPeaksEnabled {
            state.value = live
            state.holdRemaining = 0.0
            return live
        }
        if live >= state.value {
            state.value = live
            state.holdRemaining = max(0.0, meterPeakHoldSeconds)
            return state.value
        }
        if state.holdRemaining > 0.0 {
            state.holdRemaining = max(0.0, state.holdRemaining - dt)
            return state.value
        }
        let fallRate = max(1.0, meterPeakFallDBPerSecond)
        let fallFactor = powf(10.0, Float(-(fallRate * dt) / 20.0))
        state.value = max(live, state.value * fallFactor)
        if state.value < 1e-6 {
            state.value = 0.0
        }
        return state.value
    }

    private func updateAudioPeakHold(
        livePeakLinear: Float,
        state: inout AudioPeakHoldState,
        dt: Double
    ) -> Float {
        let liveDB = Self.dbfsValue(livePeakLinear)
        if !stickyPeaksEnabled {
            state.db = liveDB
            state.holdRemaining = 0.0
            return liveDB
        }
        if liveDB >= state.db {
            state.db = liveDB
            state.holdRemaining = max(0.0, meterPeakHoldSeconds)
            return state.db
        }
        if state.holdRemaining > 0.0 {
            state.holdRemaining = max(0.0, state.holdRemaining - dt)
            return state.db
        }
        let fallRate = max(1.0, meterPeakFallDBPerSecond)
        state.db = max(liveDB, state.db - Float(fallRate * dt))
        return state.db
    }

    private func updateLimiterGRPeakHold(liveValueDB: Float, dt: Double) -> Float {
        let live = max(0.0, liveValueDB.isFinite ? liveValueDB : 0.0)
        if !stickyPeaksEnabled {
            limiterGRPeakHoldDB = live
            limiterGRPeakHoldRemaining = 0.0
            return live
        }
        if live >= limiterGRPeakHoldDB {
            limiterGRPeakHoldDB = live
            limiterGRPeakHoldRemaining = max(0.0, meterPeakHoldSeconds)
            return limiterGRPeakHoldDB
        }
        if limiterGRPeakHoldRemaining > 0.0 {
            limiterGRPeakHoldRemaining = max(0.0, limiterGRPeakHoldRemaining - dt)
            return limiterGRPeakHoldDB
        }
        let fallRate = max(1.0, meterPeakFallDBPerSecond)
        limiterGRPeakHoldDB = max(live, limiterGRPeakHoldDB - Float(fallRate * dt))
        if limiterGRPeakHoldDB < 0.01 {
            limiterGRPeakHoldDB = 0.0
        }
        return limiterGRPeakHoldDB
    }

    private func smoothMeter(
        current: Float, target: Float, dt: Double, attackMS: Float, releaseMS: Float
    ) -> Float {
        let clampedTarget = max(0.0, min(1.0, target.isFinite ? target : 0.0))
        let tauMS = clampedTarget >= current ? max(1.0, attackMS) : max(5.0, releaseMS)
        let alpha = 1.0 - exp(-dt / (Double(tauMS) * 0.001))
        return current + ((clampedTarget - current) * Float(alpha))
    }

    private func smoothPeakProgramMeter(
        current: Float,
        target: Float,
        dt: Double,
        releaseMS: Float
    ) -> Float {
        // Peak-program ballistics: fixed fast attack, configurable release.
        // smoothMeter() already selects attack-vs-release internally from the
        // rising/falling direction and clamps the target, so this is a thin
        // wrapper that pins the attack to the peak-meter constant. (The prior
        // if/else had two identical branches.)
        smoothMeter(
            current: current,
            target: target,
            dt: dt,
            attackMS: Self.audioPeakMeterAttackMS,
            releaseMS: releaseMS
        )
    }

    private static func dbfsValue(_ linear: Float) -> Float {
        guard linear.isFinite, linear > 1e-9 else { return -120.0 }
        return 20.0 * log10f(linear)
    }

    private static func levelMeterScale(dbfs db: Float) -> Float {
        let floorDB: Float = -36.0
        let norm = max(0.0, min(1.0, (db - floorDB) / -floorDB))
        return norm
    }

    private static func levelMeterScale(_ linear: Float) -> Float {
        levelMeterScale(dbfs: dbfsValue(linear))
    }

    private static func dbfsString(_ linear: Float) -> String {
        // Right-justified to a constant 6-char numeric field so the
        // monospaced readout never changes width as the value moves between
        // 1/2/3-digit magnitudes ("-6.2" vs "-12.4" vs "-120.0") -- avoids
        // the layout jitter that variable-length numbers cause.
        guard linear > 1e-9 else { return "  -inf dBFS" }
        let db = 20.0 * log10(Double(linear))
        return String(format: "%6.1f dBFS", db)
    }

    private static func meterMetaString(rms: Float, peak: Float, peakHoldDB: Float? = nil) -> String {
        let rmsString = dbfsString(rms)
        let displayPeakDB: Double
        if let peakHold = peakHoldDB {
            displayPeakDB = Double(peakHold)
        } else {
            displayPeakDB = peak > 1e-9 ? (20.0 * log10(Double(peak))) : -120.0
        }
        return "\(rmsString)   \(String(format: "%6.1f", displayPeakDB)) pk"
    }

    private static func peakMeterString(currentPeak: Float, peakHoldDB: Float? = nil) -> String {
        let currentString = dbfsString(currentPeak)
        guard let peakHoldDB else { return currentString }
        return "\(currentString)   \(String(format: "%6.1f", peakHoldDB)) pk"
    }

    private static func lufsString(_ value: Float) -> String {
        guard value.isFinite, value > -119.5 else { return "—" }
        return String(format: "%.1f LUFS", value)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Strip the trailing "   N.N pk" suffix produced by `peakMeterString`
    /// so the vertical meter strip only renders the current value. The
    /// peak-hold position is already shown as the white tick on the strip,
    /// so duplicating it as text only adds clutter and overflows the
    /// 58 pt column.
    var meterCurrentOnly: String {
        // The current value ends at its unit suffix; split there so leading
        // field-padding spaces in the value (now right-justified to a fixed
        // width) aren't mistaken for the "   " peak separator.
        if let r = range(of: " dBFS") { return String(self[..<r.upperBound]) }
        if let r = range(of: " LUFS") { return String(self[..<r.upperBound]) }
        if let r = range(of: "   ") { return String(self[..<r.lowerBound]) }
        return self
    }
}

#endif  // os(macOS)
