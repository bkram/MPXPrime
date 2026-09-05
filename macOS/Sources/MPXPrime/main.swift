#if os(macOS)
import AppKit
import CoreAudio
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import MPXPrimeCore

#if !canImport(Darwin)
// Glibc imports C's `stderr` as a mutable global, which Swift 6 strict
// concurrency rejects at use sites. Rebind file-locally to a fresh
// unbuffered FILE* on fd 2 (identical behavior: stderr is unbuffered).
nonisolated(unsafe) private let stderr: UnsafeMutablePointer<FILE> = {
    guard let f = fdopen(2, "w") else { fatalError("fdopen(2) failed") }
    setvbuf(f, nil, _IONBF, 0)
    return f
}()
#endif

#if os(macOS)
@discardableResult
func applyRealtimePriorityHints() -> Bool {
    var qosApplied = false

    // Request the highest practical QoS for control-thread work.
    if pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) == 0 {
        qosApplied = true
    }
    return qosApplied
}
#endif

struct CLIOptions {
    var configPath: String = AppConfig.defaultINIPath
    var configPathExplicit: Bool = false
    var runSeconds: Double?
    // The GUI is macOS-only; Linux defaults to headless (a bare `MPXPrime`
    // there behaves like `--nogui`, and an explicit `--gui` is rejected).
    #if os(macOS)
    var gui: Bool = true
    #else
    var gui: Bool = false
    #endif
    var verify: Bool = false
    var verifyPresets: Bool = false
    var verifyLong: Bool = false
    var verifyReceiver: Bool = false
    var verifyMultibandCoupling: Bool = false
    var verifyAdvancedDynamics: Bool = false
    var verifySSBStereo: Bool = false
    var verifyHFTransients: Bool = false
    var verifyStereoGuard: Bool = false
    var verifyFinalRide: Bool = false
    var verifyProgramAB: Bool = false
    var programABPath: String = ""
    var programABProfile: String = "music_clean"
    var programABCSV: String?
    var captureBaseline: Bool = false
    var strictBaseline: Bool = false
    var bench: Bool = false
    var benchBlocksOnly: Bool = false
    // Remote-control server overrides (headless runs). nil = use the INI's
    // [CONTROL] settings; --control enables with INI/default bind+port;
    // --control-port N enables on that port.
    var controlEnabled: Bool?
    var controlPort: Int?
}

func defaultVerificationConfigPath() -> String {
    let launchDirectory =
        ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
    let candidates = [
        ((launchDirectory as NSString).appendingPathComponent("macOS/Verification.ini")
            as NSString).standardizingPath,
        ((launchDirectory as NSString).appendingPathComponent("Verification.ini")
            as NSString).standardizingPath
    ]
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
        return candidate
    }
    // No silent fallback to the LIVE user config: a verifier that quietly
    // measures the operator's station INI produces official-looking TIGHT/
    // WARN verdicts about the wrong thing (pilot/RDS levels, clipper
    // enables, AGC -- all operator-set). Verification runs are only
    // meaningful against the pinned macOS/Verification.ini, so demand it.
    fputs(
        """
        MPX Prime: macOS/Verification.ini not found from the current directory.
        Verification must run against the pinned config -- run from the repo
        root, or pass --config <path> explicitly to verify a specific INI.
        """ + "\n",
        stderr)
    exit(64)  // EX_USAGE: distinct from the verifier's 0/1/2 verdicts
}

func normalizeConfigPath(_ rawPath: String) -> String {
    let expanded = (rawPath as NSString).expandingTildeInPath
    let expandedNSString = expanded as NSString
    if expandedNSString.isAbsolutePath {
        return expandedNSString.standardizingPath
    }
    let launchDirectory =
        ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
    let combined = (launchDirectory as NSString).appendingPathComponent(expanded)
    return (combined as NSString).standardizingPath
}

func parseCLI() -> CLIOptions {
    var options = CLIOptions()
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--config":
            if i + 1 < args.count {
                options.configPath = normalizeConfigPath(args[i + 1])
                options.configPathExplicit = true
                i += 1
            }
        case "--seconds":
            if i + 1 < args.count, let sec = Double(args[i + 1]), sec > 0 {
                options.runSeconds = sec
                i += 1
            }
        case "--gui":
            options.gui = true
        case "--nogui":
            options.gui = false
        case "--verify":
            options.verify = true
            options.gui = false
        case "--verify-presets":
            options.verify = true
            options.verifyPresets = true
            options.gui = false
        case "--verify-long":
            options.verify = true
            options.verifyLong = true
            options.gui = false
        case "--verify-receiver":
            options.verify = true
            options.verifyReceiver = true
            options.gui = false
        case "--verify-multiband-coupling":
            options.verify = true
            options.verifyMultibandCoupling = true
            options.gui = false
        case "--verify-advanced-dynamics":
            options.verify = true
            options.verifyAdvancedDynamics = true
            options.gui = false
        case "--verify-ssb-stereo":
            options.verify = true
            options.verifySSBStereo = true
            options.gui = false
        case "--verify-hf-transients":
            options.verify = true
            options.verifyHFTransients = true
            options.gui = false
        case "--verify-stereo-guard":
            options.verify = true
            options.verifyStereoGuard = true
            options.gui = false
        case "--verify-final-ride":
            options.verify = true
            options.verifyFinalRide = true
            options.gui = false
        case "--verify-program-ab":
            if i + 1 < args.count {
                options.verify = true
                options.verifyProgramAB = true
                options.programABPath = normalizeConfigPath(args[i + 1])
                options.gui = false
                i += 1
            }
        case "--ab-profile":
            if i + 1 < args.count {
                options.programABProfile = args[i + 1]
                i += 1
            }
        case "--ab-csv":
            if i + 1 < args.count {
                options.programABCSV = normalizeConfigPath(args[i + 1])
                i += 1
            }
        case "--capture-baseline":
            options.verify = true
            options.captureBaseline = true
            options.gui = false
        case "--baseline-strict":
            options.strictBaseline = true
        case "--bench":
            options.bench = true
            options.gui = false
        case "--bench-blocks":
            options.bench = true
            options.benchBlocksOnly = true
            options.gui = false
        case "--control", "--web":
            // Control flags describe a headless run: MPXPrime --web serves
            // the dashboard without opening the GUI window.
            options.controlEnabled = true
            options.gui = false
        case "--control-port":
            if i + 1 < args.count, let port = Int(args[i + 1]), port > 0, port < 65536 {
                options.controlEnabled = true
                options.controlPort = port
                options.gui = false
                i += 1
            }
        default:
            // An UNRECOGNISED argument is a usage error, never something to
            // ignore. Ignoring it is how `MPXPrime "--verify --seconds 5"`
            // (one quoted argument -- a shell that does not word-split, e.g.
            // zsh passing an unsplit variable) silently launched the LIVE GUI
            // ENCODER instead of the offline verifier: a debug build then
            // pegs a core, grabs the audio devices and fails on buffers,
            // while the caller reports a passing "gate". Fail loudly instead.
            fputs("MPX Prime: unrecognised argument: \(arg)\n", stderr)
            printUsage()
            exit(64)  // EX_USAGE
        }
        i += 1
    }
    return options
}

func printUsage() {
    let text = """
        MPX Prime

        Usage:
          MPXPrime [--config <path>] [--seconds 30] [--gui|--nogui]
          MPXPrime [--config <path>] --verify [--seconds 5]
          MPXPrime [--config <path>] --verify-presets [--seconds 5]
          MPXPrime [--config <path>] --verify-long [--seconds 30]
          MPXPrime [--config <path>] --verify-receiver [--seconds 5]
          MPXPrime [--config <path>] --verify-multiband-coupling [--seconds 5]
          MPXPrime [--config <path>] --verify-advanced-dynamics [--seconds 5]
          MPXPrime [--config <path>] --verify-ssb-stereo [--seconds 5]
          MPXPrime [--config <path>] --verify-hf-transients [--seconds 5]
          MPXPrime [--config <path>] --verify-stereo-guard [--seconds 5]
          MPXPrime [--config <path>] --verify-final-ride [--seconds 4]
          MPXPrime --verify-program-ab <file-or-dir> [--ab-profile music_clean] [--ab-csv out.csv] [--seconds 30]
          MPXPrime --bench
          MPXPrime --bench-blocks

        Options:
          --config   Path to the INI config (default: ~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini; Linux: ~/.local/share/MPX Prime Studio/MPX Prime Studio.ini)
          --seconds  Auto-stop after N seconds (GUI or headless)
          --gui      Launch native SwiftUI macOS window (default)
          --nogui    Run headless
          --verify   Run the offline MPX verification harness
                     Uses macOS/Verification.ini by default when available
                     Compares against macOS/verifier_baselines/default.json if present.
          --capture-baseline  Run --verify and write measurements to the baseline file.
          --baseline-strict   Any baseline drift elevates exit code to WARN (2).
          --verify-presets  Sweep key multiband presets through the offline verification harness
          --verify-long  Run the longer focused compliance/regression verifier
          --verify-receiver  Run offline receiver-model decode checks
          --verify-multiband-coupling  A/B the experimental multiband inter-band coupling toggle
          --verify-advanced-dynamics  A/B the experimental single-stage Advanced Dynamics leveler
          --verify-ssb-stereo  A/B the experimental SSB Stereo encoder (SSB-leaning stereo encoding)
          --verify-hf-transients  Hi-hat / cymbal distortion gate: receiver-side HF SINAD, HF crest,
                     15-23 kHz composite spill per chain variant (field chain, every Format Profile,
                     per-stage isolation)
          --verify-stereo-guard  Sweep the composite clipper's stereo guard share (0, 0.25, 0.5, 0.75, 1)
                     on the Music - Loud profile: clipper / final-limiter duty, peak, deviation,
                     14 kHz separation, hard-panned S/M, hat / ride HF SINAD -- the table the
                     shipped `mpx_clipper_stereo_guard` default is picked from
          --verify-final-ride  Attribute the Final-MPX limiter's duty: one composite-clipper candidate
                     switched off per row (pilot / RDS / stereo guard, oversampling, knee, look-ahead,
                     limiter, shaper) on a hot chain and on Music - Loud, every peak controller's duty printed
          --verify-program-ab <file-or-dir>  Real-music A/B: render each audio file through the shipped
                     Format Profile with AGC+multiband (A) vs Advanced Dynamics (B), measured with the
                     Meter engine (BS.412 power, deviation, exceedance) plus decoded crest / image /
                     band-balance / pumping deltas. macOS only (AVFoundation decode).
                     --ab-profile <id>  Format Profile for both chains (default music_clean)
                     --ab-csv <path>    Also write one CSV row per track x chain
                     --seconds N        Excerpt length per track (default 30; excerpts cap at the
                                        track length, so a large N measures full tracks)
          --bench-blocks  Only the block (buffer) size sweep: worst-block cost vs block duration,
                     I/O latency, bit-identity across sizes, device HAL buffer range (~15 s).
          --bench    Run the DSP benchmark (rate sweep / OS sweep / dual-rate sweep / per-stage A/B);
                     prints a markdown report to stdout. Use a release build for valid numbers.
          --control, --web  Run headless with the remote-control REST API + web
                            dashboard (implies --nogui; overrides [CONTROL]
                            control_enabled). For the GUI app, enable the server
                            in Settings instead.
          --control-port N  Enable the control server on port N (default 8737).
                            Binding beyond 127.0.0.1 requires control_api_key.
        """
    print(text)
}

#if os(macOS)
func buildDeviceInfo(inputID: AudioDeviceID?, outputID: AudioDeviceID?, allDevices: [AudioDevice])
    -> String {
    var parts: [String] = []
    if let inputID = inputID {
        if let device = allDevices.first(where: { $0.id == inputID }) {
            parts.append("input=\(device.name)")
        } else {
            parts.append("input_id=\(inputID)")
        }
    }
    if let outputID = outputID {
        if let device = allDevices.first(where: { $0.id == outputID }) {
            parts.append("output=\(device.name)")
        } else {
            parts.append("output_id=\(outputID)")
        }
    }
    return parts.isEmpty ? "" : "devices: \(parts.joined(separator: ", "))"
}
#endif

/// Launch the control server as a detached task when enabled via the INI's
/// [CONTROL] section or the --control/--control-port flags. A startup
/// failure (port in use, remote bind without key) must be LOUD but must not
/// take the encoder down.
func startControlServerIfEnabled(
    config: AppConfig, options: CLIOptions, backend: HeadlessControlBackend
) {
    let enabled = options.controlEnabled ?? config.controlEnabled
    guard enabled else { return }
    var settings = ControlServerSettings(config: config)
    if let port = options.controlPort {
        settings.port = port
    }
    print("Control server: http://\(settings.host):\(settings.port)/")
    Task {
        do {
            try await ControlServer.run(backend: backend, settings: settings)
        } catch {
            fputs("[Control] server failed: \(error)\n", stderr)
        }
    }
}

/// Load the headless run's config. A missing file at the DEFAULT path is
/// first-run, not an error: create it with defaults (like the GUI does) so
/// `MPXPrime --web` works out of the box. An explicit --config path that
/// does not exist stays a hard error (probably a typo).
func loadOrCreateHeadlessConfig(path: String, explicit: Bool) throws -> AppConfig {
    if FileManager.default.fileExists(atPath: path) {
        let loaded = try AppConfig.loadReportingMigration(fromINI: path)
        let config = loaded.config
        if let legacy = loaded.legacyProfileID {
            fputs(
                "MPX Prime: pre-0.45 config (profile '\(legacy)') -- processing reset to the "
                    + "'\(config.formatProfileID)' Format Profile; RDS, interfaces, control server and "
                    + "calibration (pilot, deviation, output level, pre-emphasis) kept. Saved.\n",
                stderr)
            try? config.save(toINI: path)
        }
        if config.safetyClipsAreThePeakController {
            fputs(
                "MPX Prime: WARNING pre-encode limiter and composite clipper are both OFF -- "
                    + "the safety soft-clips are the only peak controller (audible distortion on "
                    + "loud/bright program). Re-apply a Format Profile or enable the composite clipper.\n",
                stderr)
        }
        return config
    }
    if explicit {
        throw INIParserError.unreadableFile(path)
    }
    let config = AppConfig()
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
    do {
        try config.save(toINI: path)
        fputs("MPX Prime: created default config at \(path)\n", stderr)
    } catch {
        fputs("MPX Prime: running on defaults (could not write \(path): \(error))\n", stderr)
    }
    return config
}

let options = parseCLI()
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    printUsage()
    exit(0)
}
let configPath = options.configPathExplicit
    ? options.configPath
    : (options.verify ? defaultVerificationConfigPath() : AppConfig.defaultINIPath)

do {
    if options.bench {
        var runner = BenchmarkRunner()
        runner.blockSweepOnly = options.benchBlocksOnly
        let report = runner.run()
        print(report)
        exit(0)
    }
    if options.verify {
        let defaultDuration = (options.verifyLong || options.verifyProgramAB) ? 30.0 : 5.0
        let duration = max(1.0, options.runSeconds ?? defaultDuration)
        exit(
            try runVerificationHarness(
                configPath: configPath,
                durationSeconds: duration,
                presetSweep: options.verifyPresets,
                longRun: options.verifyLong,
                receiverModel: options.verifyReceiver,
                multibandCouplingComparison: options.verifyMultibandCoupling,
                advancedDynamicsComparison: options.verifyAdvancedDynamics,
                ssbStereoComparison: options.verifySSBStereo,
                hfTransientsComparison: options.verifyHFTransients,
                stereoGuardSweep: options.verifyStereoGuard,
                finalRideIsolation: options.verifyFinalRide,
                programAB: options.verifyProgramAB,
                programABPath: options.programABPath,
                programABProfile: options.programABProfile,
                programABCSV: options.programABCSV,
                captureBaseline: options.captureBaseline,
                strictBaseline: options.strictBaseline
            )
        )
    }

    #if os(macOS)
    let qosApplied = applyRealtimePriorityHints()
    if !qosApplied {
        fputs("MPX Prime: unable to apply QoS hint\n", stderr)
    }

    if options.gui {
        let app = NSApplication.shared
        let delegate = AppDelegate(configPath: configPath, runSeconds: options.runSeconds)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
    let config = try loadOrCreateHeadlessConfig(
        path: configPath, explicit: options.configPathExplicit)
    fputs("MPX Prime: config \(configPath)\n", stderr)
    let nowPlayingState = NowPlayingState()
    let nowPlayingRunner = NowPlayingScriptRunner(state: nowPlayingState) { status in
        fputs("[NowPlaying] \(status)\n", stderr)
    }
    nowPlayingRunner.updateConfig(config)

    // Engine factory: device resolution + construction, used for the initial
    // start here and for API-triggered restarts in the control backend.
    let makeMacEngine: ControlEngineFactory = { cfg in
        let generator = MPXGenerator(
            config: cfg,
            sampleRate: cfg.sampleRate,
            nowPlayingState: nowPlayingState
        )
        // Minimal-I/O device lookup, silent on failure (system defaults).
        var inputID: AudioDeviceID?
        var outputID: AudioDeviceID?
        if let allDevices = try? AudioDevices.list() {
            if cfg.sourceMode.lowercased() == "input", let uid = cfg.inputDeviceUID {
                inputID = allDevices.first(where: { $0.uid == uid })?.id
            }
            if let uid = cfg.outputDeviceUID {
                outputID = allDevices.first(where: { $0.uid == uid })?.id
            }
        }
        return AudioOutputEngine(
            generator: generator,
            config: cfg,
            inputDeviceID: inputID,
            outputDeviceID: outputID,
            outputMode: cfg.operatingMode.isAudioOutput ? .processedAudio : .mpxComposite
        )
    }

    guard let audioEngine = try makeMacEngine(config) as? AudioOutputEngine else {
        fatalError("engine factory returned unexpected type")
    }
    try audioEngine.start()

    // Brief debug output about output setup
    fputs("[Render] Actual render sample rate: \(audioEngine.renderSampleRate) Hz\n", stderr)
    fputs("[Render] Hardware sample rate: \(audioEngine.hardwareSampleRate) Hz\n", stderr)

    let backend = HeadlessControlBackend(
        config: config,
        configPath: configPath,
        engine: audioEngine,
        engineFactory: makeMacEngine,
        onConfigChange: { newConfig in nowPlayingRunner.updateConfig(newConfig) },
        onNowPlaying: { display, artist, title in
            nowPlayingState.update(display: display, artist: artist, title: title)
        }
    )
    startControlServerIfEnabled(config: config, options: options, backend: backend)

    // Use NSApplication event loop with proper setup just like GUI mode does
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)  // Invisible: no dock icon, no window
    app.activate(ignoringOtherApps: true)

    signal(SIGINT, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let shutdown: @Sendable () -> Void = {
        nowPlayingRunner.stop()
        Task {
            await backend.shutdown()
            exit(0)
        }
    }
    signalSource.setEventHandler(handler: DispatchWorkItem { shutdown() })
    signalSource.resume()

    if let secs = options.runSeconds {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + secs,
            execute: DispatchWorkItem { shutdown() })
    }

    print("MPX Prime running. Press Ctrl-C to stop.")

    // Run the application event loop - same as GUI does
    app.run()
    #else
    // Linux CLI runtime: headless encoder into an ALSA device. The GUI does
    // not exist here; --verify/--bench were dispatched above.
    if options.gui {
        fputs("MPX Prime: the GUI is macOS-only; this Linux build is CLI-only (--nogui).\n", stderr)
        exit(1)
    }
    let config = try loadOrCreateHeadlessConfig(
        path: configPath, explicit: options.configPathExplicit)
    fputs("MPX Prime: config \(configPath)\n", stderr)
    let nowPlayingState = NowPlayingState()
    let nowPlayingRunner = NowPlayingScriptRunner(state: nowPlayingState) { status in
        fputs("[NowPlaying] \(status)\n", stderr)
    }
    nowPlayingRunner.updateConfig(config)

    // Device names are ALSA PCM names ("default", "hw:0,0", "plughw:...")
    // carried in the same INI keys that hold CoreAudio UIDs on macOS.
    let makeLinuxEngine: ControlEngineFactory = { cfg in
        let generator = MPXGenerator(
            config: cfg,
            sampleRate: cfg.sampleRate,
            nowPlayingState: nowPlayingState
        )
        return ALSAAudioEngine(
            generator: generator,
            config: cfg,
            outputMode: cfg.operatingMode.isAudioOutput ? .processedAudio : .mpxComposite
        )
    }
    // Build the backend WITHOUT a pre-started engine, bring the control
    // server up first, then attempt the engine start tolerantly. A missing
    // or renamed ALSA device must NOT take the process down (it used to
    // exit(1) -> systemd crash-loop): the server stays reachable so the
    // operator can pick a device on the dashboard's Interfaces page and
    // press Start. Only when the control server is disabled is a failed
    // start fatal (there is nothing to stay alive for).
    let backend = HeadlessControlBackend(
        config: config,
        configPath: configPath,
        engine: nil,
        engineFactory: makeLinuxEngine,
        onConfigChange: { newConfig in nowPlayingRunner.updateConfig(newConfig) },
        onNowPlaying: { display, artist, title in
            nowPlayingState.update(display: display, artist: artist, title: title)
        }
    )
    let controlEnabled = options.controlEnabled ?? config.controlEnabled
    startControlServerIfEnabled(config: config, options: options, backend: backend)

    // Initial start attempt + reconciliation timer. A missing audio device is
    // NEVER fatal: the engine start is retried every few seconds, so the
    // encoder comes up the moment the device is available (boot ordering, USB
    // hot-plug) with no intervention -- and the dashboard (when enabled) lets
    // the operator point at a different device meanwhile.
    Task {
        if await backend.startEngineTolerant() {
            print("MPX Prime running. Press Ctrl-C to stop.")
        } else {
            let settings = ControlServerSettings(config: config)
            let where_ = controlEnabled
                ? "Open http://\(settings.host):\(settings.port)/ to pick a device, or wait"
                : "Will keep retrying"
            fputs(
                "MPX Prime: audio device not available yet. \(where_) -- the engine "
                    + "starts automatically as soon as the device appears.\n", stderr)
        }
    }
    let reconcileTimer = DispatchSource.makeTimerSource(queue: .global())
    reconcileTimer.schedule(deadline: .now() + 5, repeating: 5.0)
    reconcileTimer.setEventHandler { Task { await backend.reconcile() } }
    reconcileTimer.resume()

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let shutdown: @Sendable () -> Void = {
        nowPlayingRunner.stop()
        Task {
            await backend.shutdown()
            exit(0)
        }
    }
    sigintSource.setEventHandler(handler: DispatchWorkItem { shutdown() })
    sigtermSource.setEventHandler(handler: DispatchWorkItem { shutdown() })
    sigintSource.resume()
    sigtermSource.resume()

    if let secs = options.runSeconds {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + secs,
            execute: DispatchWorkItem { shutdown() })
    }

    dispatchMain()
    #endif
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
