import Foundation

// Shared contract between the control server (REST routes) and whatever owns
// the engine: the headless runtime (macOS + Linux) or the macOS GUI view
// model. Routes never touch engines or configs directly -- they speak this
// protocol, so the HTTP layer is testable against a mock and identical
// across run modes.

enum TransportAction: String, Codable, Sendable {
    case start
    case stop
    case restart
}

enum ControlError: Error, CustomStringConvertible {
    case engineFailure(String)
    case invalidRequest(String)

    var description: String {
        switch self {
        case .engineFailure(let why): return "engine failure: \(why)"
        case .invalidRequest(let why): return "invalid request: \(why)"
        }
    }
}

/// GET /api/status payload.
struct ControlStatus: Codable, Sendable {
    var running: Bool
    var platform: String
    var version: String
    var sampleRateHz: Double
    var uptimeSeconds: Double?
    var restartPending: Bool
    var sourceMode: String
    var outputMode: String
    var notes: [String]
}

/// GET /api/meters payload. All fields optional: platforms report what they
/// measure (full MeterSnapshot on macOS; peaks + xruns on the Linux ALSA
/// engine in this milestone). Levels are linear 0..1 unless suffixed.
struct ControlMeters: Codable, Sendable {
    var inputLeftPeak: Float?
    var inputRightPeak: Float?
    var outputPeak: Float?
    var deviationKHzPeak: Float?
    var agcGainDB: Float?
    var compositeClipperGainReductionDB: Float?
    var preEncodeLimiterGainReductionDB: Float?
    var safetyLimiterGainReductionDB: Float?
    var pilotInjectionPercent: Float?
    var rdsInjectionPercent: Float?
    var compositeBudgetMarginDB: Float?
    var compositeOverBudget: Bool?
    var stereoCorrelation: Float?
    var renderXruns: Int?
    var captureXruns: Int?
    // Input capture->render ring transport diagnostics (macOS input source).
    // The definitive signal for clock-drift faults between a virtual input
    // (e.g. BlackHole) and a hardware output: `overflows` climbs when the
    // input clock runs faster than render (ring fills), `underflows` when
    // slower (ring drains), `tornReads` on lock-free read collisions.
    // `bufferedFrames` should hover near the engine's target; a monotonic
    // drift toward 0 or capacity is what precedes audible dropout/static.
    // All nil in headless/ALSA and when no input source is running.
    var inputRingBufferedFrames: Int?
    var inputRingOverflows: Int?
    var inputRingUnderflows: Int?
    var inputRingTornReads: Int?
    var inputResampleMode: String?
    var inputRatioTrim: Double?
}

/// GET /api/rds payload: the live on-air snapshot plus the operational
/// config fields an automation system cares about.
struct ControlRDS: Codable, Sendable {
    var enabled: Bool
    var pi: String
    var pty: Int
    var ta: Bool
    var tp: Bool
    /// On-air text as the encoder is actually transmitting it right now
    /// (from BasicRDSCoder's snapshot; nil when the engine is stopped).
    var livePS: String?
    var liveRT: String?
    var livePTYN: String?
    var liveLongPS: String?
    /// Configured text sources (what live text is generated from).
    var configuredRT: String
    var configuredPSActiveBank: String
}

/// PATCH /api/config response.
struct ConfigApplyResult: Codable, Sendable {
    var outcomes: [ConfigKeyOutcome]
    var appliedLive: Bool
    var restartPending: Bool
}

/// One selectable audio device. `id` is what goes into the INI's
/// `*_device_uid` key -- a CoreAudio UID on macOS, an ALSA PCM name on
/// Linux (`hw:0,0`, `plughw:...`, `default`).
struct ControlDevice: Codable, Sendable {
    var id: String
    var name: String
    var canInput: Bool
    var canOutput: Bool
}

/// GET /api/devices payload: the pickable input/output lists plus which id
/// each `*_device_uid` currently names (empty = system default). Selecting a
/// device is a restart-class change (PATCH the uid key, then restart).
struct ControlDevices: Codable, Sendable {
    var inputs: [ControlDevice]
    var outputs: [ControlDevice]
    var selectedInput: String
    var selectedOutput: String
    /// Platform note the UI shows next to the pickers (e.g. Linux PCM-name
    /// convention). Empty on macOS.
    var note: String
}

/// The engine surface the headless backend drives. AudioOutputEngine (macOS)
/// and ALSAAudioEngine (Linux) both conform; both `apply*` entry points are
/// thread-safe producers consumed by the render thread.
protocol ControlledEngine: AnyObject {
    func start() throws
    func stop()
    func applyRuntimeConfig(_ config: AppConfig)
    func applyRDSRuntimeConfig(_ config: AppConfig)
    var controlMeters: ControlMeters? { get }
    var rdsLiveSnapshotForControl: BasicRDSCoder.LiveSnapshot? { get }
}

/// What the REST routes need from the run mode that owns the engine.
protocol ControlBackend: Sendable {
    func status() async -> ControlStatus
    func meters() async -> ControlMeters?
    func rds() async -> ControlRDS
    func devices() async -> ControlDevices
    func configSections() async throws -> [String: [String: String]]
    /// Apply an INI-key patch: classify, hot-apply live planes, persist,
    /// flag restart-required leftovers.
    func applyConfigPatch(_ patch: [String: String]) async throws -> ConfigApplyResult
    func transport(_ action: TransportAction) async throws -> ControlStatus
    /// Available preset ids by kind (primebass / widener / multiband /
    /// format_profile) -- and application thereof.
    func presets() async -> [String: [String]]
    func applyPreset(kind: String, id: String, intensity: Double?) async throws -> ConfigApplyResult
    /// Push now-playing metadata into the shared NowPlayingState (the same
    /// sink the local script poller feeds). Returns whether now-playing
    /// rendering is currently enabled, so the client can warn if pushes will
    /// not appear. artist/title drive the RT / PS / RT+ templates.
    func setNowPlaying(artist: String, title: String, display: String) async -> Bool
}
