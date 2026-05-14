import AppKit
import CoreAudio
import Darwin
import Foundation

@discardableResult
func applyRealtimePriorityHints() -> Bool {
    var qosApplied = false

    // Request the highest practical QoS for control-thread work.
    if pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) == 0 {
        qosApplied = true
    }
    return qosApplied
}

struct CLIOptions {
    var configPath: String = AppConfig.defaultINIPath
    var configPathExplicit: Bool = false
    var runSeconds: Double?
    var gui: Bool = true
    var verify: Bool = false
    var verifyPresets: Bool = false
    var verifyLong: Bool = false
    var verifyReceiver: Bool = false
    var verifyCompositeMultibandClipper: Bool = false
    var verifyMultibandCoupling: Bool = false
    var captureBaseline: Bool = false
    var strictBaseline: Bool = false
}

func defaultVerificationConfigPath() -> String {
    let launchDirectory =
        ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
    let candidates = [
        ((launchDirectory as NSString).appendingPathComponent("macOS/Verification.ini")
            as NSString).standardizingPath,
        ((launchDirectory as NSString).appendingPathComponent("Verification.ini")
            as NSString).standardizingPath,
    ]
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
        return candidate
    }
    return AppConfig.defaultINIPath
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
        case "--capture-baseline":
            options.verify = true
            options.captureBaseline = true
            options.gui = false
        case "--baseline-strict":
            options.strictBaseline = true
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
        """
    print(text)
}

func buildDeviceInfo(inputID: AudioDeviceID?, outputID: AudioDeviceID?, allDevices: [AudioDevice])
    -> String
{
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

let options = parseCLI()
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    printUsage()
    exit(0)
}
let configPath = options.configPathExplicit
    ? options.configPath
    : (options.verify ? defaultVerificationConfigPath() : AppConfig.defaultINIPath)

do {
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
                captureBaseline: options.captureBaseline,
                strictBaseline: options.strictBaseline
            )
        )
    }

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
    let config = try AppConfig.load(fromINI: configPath)
    let nowPlayingState = NowPlayingState()
    let nowPlayingRunner = NowPlayingScriptRunner(state: nowPlayingState) { status in
        fputs("[NowPlaying] \(status)\n", stderr)
    }
    nowPlayingRunner.updateConfig(config)
    let generator = MPXGenerator(
        config: config,
        sampleRate: config.sampleRate,
        nowPlayingState: nowPlayingState
    )

    // Minimize blocking before audio engine start: do device lookup with minimal I/O and NO logging
    var allDevices: [AudioDevice] = []
    var inputID: AudioDeviceID? = nil
    var outputID: AudioDeviceID? = nil

    do {
        allDevices = try AudioDevices.list()

        // Resolve device UIDs to IDs quickly and silently - NO PRINT STATEMENTS
        if config.sourceMode.lowercased() == "input", let uid = config.inputDeviceUID {
            inputID = allDevices.first(where: { $0.uid == uid })?.id
        }
        if let uid = config.outputDeviceUID {
            outputID = allDevices.first(where: { $0.uid == uid })?.id
        }
    } catch {
        // Silent failure - will use system defaults
    }

    let audioEngine = AudioOutputEngine(
        generator: generator,
        config: config,
        inputDeviceID: inputID,
        outputDeviceID: outputID
    )
    try audioEngine.start()

    // Brief debug output about input setup
    fputs(
        "[Input] Device ID: \(inputID ?? 0), Sample rate requested: \(config.sampleRate)\n", stderr)
    if let inputRate = audioEngine.inputSampleRate {
        fputs("[Input] Actual input sample rate: \(inputRate)\n", stderr)
    }
    fputs("[Render] Actual render sample rate: \(audioEngine.renderSampleRate) Hz\n", stderr)
    fputs("[Render] Hardware sample rate: \(audioEngine.hardwareSampleRate) Hz\n", stderr)

    // Use NSApplication event loop with proper setup just like GUI mode does
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)  // Invisible: no dock icon, no window
    app.activate(ignoringOtherApps: true)

    signal(SIGINT, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signalSource.setEventHandler(
        handler: DispatchWorkItem {
            nowPlayingRunner.stop()
            audioEngine.stop()
            exit(0)
        })
    signalSource.resume()

    if let secs = options.runSeconds {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + secs,
            execute: DispatchWorkItem {
                nowPlayingRunner.stop()
                audioEngine.stop()
                exit(0)
            })
    }

    print("MPX Prime running. Press Ctrl-C to stop.")

    // Run the application event loop - same as GUI does
    app.run()
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
