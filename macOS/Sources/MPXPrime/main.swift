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
    var verifyCompositeMultibandClipper: Bool = false
    var verifyMultibandCoupling: Bool = false
    var verifyAdvancedDynamics: Bool = false
    var captureBaseline: Bool = false
    var strictBaseline: Bool = false
    var bench: Bool = false
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
        case "--verify-composite-multiband":
            options.verify = true
            options.verifyCompositeMultibandClipper = true
            options.gui = false
        case "--verify-multiband-coupling":
            options.verify = true
            options.verifyMultibandCoupling = true
            options.gui = false
        case "--verify-advanced-dynamics":
            options.verify = true
            options.verifyAdvancedDynamics = true
            options.gui = false
        case "--capture-baseline":
            options.verify = true
            options.captureBaseline = true
            options.gui = false
        case "--baseline-strict":
            options.strictBaseline = true
        case "--bench":
            options.bench = true
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
            break
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
          MPXPrime [--config <path>] --verify-composite-multiband [--seconds 5]
          MPXPrime [--config <path>] --verify-multiband-coupling [--seconds 5]
          MPXPrime [--config <path>] --verify-advanced-dynamics [--seconds 5]
          MPXPrime --bench

        Options:
          --config   Path to macOS INI config (default: ~/Library/Application Support/MPX Prime/MPX Prime.ini)
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
          --verify-composite-multiband  A/B the experimental composite multiband clipper toggle
          --verify-multiband-coupling  A/B the experimental multiband inter-band coupling toggle
          --verify-advanced-dynamics  A/B the experimental single-stage Advanced Dynamics leveler
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
        return try AppConfig.load(fromINI: path)
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
        let report = BenchmarkRunner().run()
        print(report)
        exit(0)
    }
    if options.verify {
        let defaultDuration = options.verifyLong ? 30.0 : 5.0
        let duration = max(1.0, options.runSeconds ?? defaultDuration)
        exit(
            try runVerificationHarness(
                configPath: configPath,
                durationSeconds: duration,
                presetSweep: options.verifyPresets,
                longRun: options.verifyLong,
                receiverModel: options.verifyReceiver,
                compositeMultibandClipperComparison: options.verifyCompositeMultibandClipper,
                multibandCouplingComparison: options.verifyMultibandCoupling,
                advancedDynamicsComparison: options.verifyAdvancedDynamics,
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
            outputMode: cfg.processedAudioOutput ? .processedAudio : .mpxComposite
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
            outputMode: cfg.processedAudioOutput ? .processedAudio : .mpxComposite
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
