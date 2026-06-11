import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore

// MPX Prime Meter -- headless CLI. Captures an FM MPX composite from a 192 kHz
// audio input, decodes stereo + RDS, and prints live measurements. A SwiftUI
// window is a later increment; this proves the capture -> decode -> measure
// chain end to end on real hardware (and offline via --selftest).

// MARK: - SIGINT

private nonisolated(unsafe) var gStop: sig_atomic_t = 0
private func handleSigint(_ signal: Int32) { gStop = 1 }

// MARK: - Helpers

private func nominalSampleRate(deviceID: AudioDeviceID) -> Double? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate)
    guard status == noErr, rate > 0 else { return nil }
    return rate
}

private func printUsage() {
    print("""
    MPX Prime Meter -- FM MPX composite analyzer (headless)

    Usage:
      MPXPrimeMeter --list-devices
      MPXPrimeMeter [--device <index|uid|name|default>] [--seconds N]
      MPXPrimeMeter --selftest [--seconds N]

    Options:
      --list-devices     List audio input devices and exit.
      --device <spec>    Input device: list index, device UID, a substring of
                         the name, or "default" (default: system default input).
      --channel <ch>     Which channel carries the composite: left | right |
                         mix (default: left). Many USB DACs feed it on right.
      --no-monitor       Do not play the decoded audio (monitor is ON by
                         default in live mode -- you hear what a receiver hears).
      --monitor-device <spec>
                         Output device for the monitor (index|uid|name);
                         default: system default output.
      --monitor-gain <dB>  Monitor gain in dB (default: 0).
      --pilot-ref-khz <kHz>
                         Pilot deviation used to calibrate the kHz readouts
                         (default: 6.75 = 9% of 75 kHz). Set it to your
                         modulator's known pilot injection; MAX DEV and RDS are
                         then measured relative to it.
      --wav <path>       Record the decoded stereo audio to a 24-bit WAV at the
                         input sample rate (high quality). Stops on Ctrl-C/exit.
      --seconds N        Run for N seconds then exit (default: until Ctrl-C;
                         --selftest defaults to 2 s).
      --selftest         No hardware: synthesize a pilot + mono-audio composite
                         and run the analysis path. (RDS/stereo decode is
                         covered by the unit tests; this is a pipeline smoke.)
      --stdin            Read the MPX composite from stdin (a WAV stream or raw
                         little-endian int16 mono) instead of an audio device.
                         For piping an external tuner -- see run-meter-sdr.sh.
      --sample-rate <Hz> Sample rate for --stdin raw/WAV input (default 192000).
      --help             Show this help.

    Feed the station composite (tuner MPX out / SDR demod / loopback) to one
    input channel and select it with --channel. RDS needs the device running
    at >= 128 kHz (57 kHz subcarrier); 192 kHz is recommended.
    """)
}

private func ptyLabel(_ pty: Int?) -> String {
    guard let pty else { return "--" }
    return String(pty)
}

private func boolField(_ value: Bool?) -> String {
    guard let value else { return "-" }
    return value ? "1" : "0"
}

// EU RDS programme types (EN 50067 Annex). RBDS (North America) differs.
private let ptyNamesEU = [
    "None", "News", "Current Affairs", "Info", "Sport", "Education", "Drama",
    "Culture", "Science", "Varied", "Pop M", "Rock M", "Easy Listening",
    "Light Classical", "Serious Classical", "Other Music", "Weather", "Finance",
    "Children", "Social Affairs", "Religion", "Phone In", "Travel", "Leisure",
    "Jazz", "Country", "National M", "Oldies M", "Folk M", "Documentary",
    "Alarm Test", "Alarm"
]

private func ptyName(_ pty: Int?) -> String {
    guard let pty, pty >= 0, pty < ptyNamesEU.count else { return "--" }
    return ptyNamesEU[pty]
}

private func clockString(_ ct: RDSClockTime) -> String {
    let offHours = Double(ct.offsetHalfHours) * 0.5
    return String(format: "%04d-%02d-%02d %02d:%02dZ %+.1fh",
                  ct.year, ct.month, ct.day, ct.hour, ct.minute, offHours)
}

private func groupSummary(_ counts: [Int]) -> String {
    var parts: [String] = []
    for type in 0..<16 {
        let a = counts[type * 2]
        let b = counts[type * 2 + 1]
        if a > 0 { parts.append("\(type)A:\(a)") }
        if b > 0 { parts.append("\(type)B:\(b)") }
    }
    return parts.isEmpty ? "--" : parts.joined(separator: " ")
}

/// Fixed 9-line SFP-style panel. Always the same line count so the live TTY
/// refresh can move the cursor up a constant amount.
private func dashboard(_ s: MeterSnapshot, sampleRate: Double, channel: String) -> [String] {
    let pi = s.rds.pi.map { String(format: "%04X", $0) } ?? "----"
    let sync = s.rds.synced ? "sync" : "----"
    let psLine = "\"\(s.rds.programService)\""
    let ptyn = s.rds.programTypeName.trimmingCharacters(in: .whitespaces)
    let eccStr = s.rds.ecc.map { String(format: "%02X", $0) } ?? "--"
    let rt = s.rds.radioText.isEmpty ? "--" : "\"\(s.rds.radioText)\""
    let ct = s.rds.clockTime.map(clockString) ?? "--"
    let af = s.rds.alternativeFrequenciesMHz.isEmpty
        ? "--"
        : s.rds.alternativeFrequenciesMHz.prefix(12).map { String(format: "%.1f", $0) }
            .joined(separator: " ") + " MHz"

    return [
        String(format: "INPUT  %6.1f dBFS   %.0f kHz   ch:%@",
               s.inputPeakDBFS, sampleRate / 1000.0, channel),
        String(format: "DEV    PILOT %.2f   RDS %.2f   MAX %5.1f kHz   (pilot=ref)",
               s.pilotDevKHz, s.rdsDevKHz, s.maxDevKHz),
        String(format: "STEREO L %6.1f  R %6.1f dBFS   corr %+.2f",
               s.leftRMSDBFS, s.rightRMSDBFS, s.stereoCorrelation),
        String(format: "RDS    %@  PI %@  PTY %@ (%@)  TP%@ TA%@ MS%@  BER %.1f%%",
               sync, pi, ptyLabel(s.rds.pty), ptyName(s.rds.pty),
               boolField(s.rds.tp), boolField(s.rds.ta), boolField(s.rds.ms),
               s.recentBlockErrorRate * 100.0),
        "PS     \(psLine)   PTYN \"\(ptyn)\"   ECC \(eccStr)",
        "RT     \(rt)",
        "CT     \(ct)",
        "AF     \(af)",
        "GRP    \(groupSummary(s.rds.groupCounts))"
    ]
}

private let stdoutIsTTY = isatty(fileno(stdout)) != 0

/// Render the panel: in-place ANSI refresh on a TTY, plain block otherwise.
private func renderPanel(_ lines: [String], firstRender: inout Bool) {
    if stdoutIsTTY {
        if !firstRender {
            print("\u{1b}[\(lines.count)A", terminator: "")  // cursor up N lines
        }
        for line in lines {
            print("\u{1b}[2K\(line)")  // clear line, print, newline
        }
    } else {
        for line in lines { print(line) }
        print("")
    }
    firstRender = false
}

// MARK: - Commands

private func listDevices() -> Int32 {
    do {
        let devices = try AudioDevices.inputDevices()
        if devices.isEmpty {
            print("No audio input devices found.")
            return 0
        }
        let defaultID = AudioDevices.defaultInputDeviceID()
        print("Input devices:")
        for (i, d) in devices.enumerated() {
            let rate = nominalSampleRate(deviceID: d.id).map { String(format: "%.0f Hz", $0) } ?? "?"
            let mark = (d.id == defaultID) ? " (default)" : ""
            print("  [\(i)] \(d.name)\(mark)  ch=\(d.inputChannels)  rate=\(rate)  uid=\(d.uid)")
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("Failed to enumerate devices: \(error)\n".utf8))
        return 1
    }
}

private func resolveDevice(_ spec: String?) -> AudioDeviceID? {
    guard let spec, spec != "default" else {
        return AudioDevices.defaultInputDeviceID()
    }
    let devices = (try? AudioDevices.inputDevices()) ?? []
    if let idx = Int(spec), idx >= 0, idx < devices.count {
        return devices[idx].id
    }
    if let byUID = devices.first(where: { $0.uid == spec }) {
        return byUID.id
    }
    if let byName = devices.first(where: { $0.name.localizedCaseInsensitiveContains(spec) }) {
        return byName.id
    }
    if let byUIDContains = devices.first(where: { $0.uid.localizedCaseInsensitiveContains(spec) }) {
        return byUIDContains.id
    }
    return nil
}

private func resolveOutputDevice(_ spec: String?) -> AudioDeviceID? {
    guard let spec, spec != "default" else { return nil }
    let devices = (try? AudioDevices.outputDevices()) ?? []
    if let idx = Int(spec), idx >= 0, idx < devices.count { return devices[idx].id }
    if let byUID = devices.first(where: { $0.uid == spec }) { return byUID.id }
    if let byName = devices.first(where: { $0.name.localizedCaseInsensitiveContains(spec) }) {
        return byName.id
    }
    return nil
}

private func runLive(
    deviceSpec: String?,
    channel: MeterChannel,
    monitor: Bool,
    monitorDeviceSpec: String?,
    monitorGainDB: Float,
    pilotRefKHz: Float,
    wavPath: String?,
    seconds: Double?
) -> Int32 {
    guard let deviceID = resolveDevice(deviceSpec) else {
        FileHandle.standardError.write(Data("No matching input device (try --list-devices).\n".utf8))
        return 1
    }
    guard let rate = nominalSampleRate(deviceID: deviceID) else {
        FileHandle.standardError.write(Data("Could not read device sample rate.\n".utf8))
        return 1
    }
    if rate < 128_000 {
        print("WARNING: device rate \(Int(rate)) Hz < 128 kHz -- RDS (57 kHz) is "
            + "above Nyquist and will not decode. Set 192 kHz in Audio MIDI Setup.")
    }

    let monitorDeviceID = resolveOutputDevice(monitorDeviceSpec)
    let gainLinear = powf(10.0, monitorGainDB / 20.0)
    let wavURL = wavPath.map { URL(fileURLWithPath: $0) }
    let engine = MeterAudioEngine(
        sampleRate: Float(rate), channel: channel,
        monitorEnabled: monitor, monitorGain: gainLinear, pilotRefKHz: pilotRefKHz,
        wavURL: wavURL, input: AUHALInputSource(deviceID: deviceID))
    do {
        let fmt = try engine.start(monitorDeviceID: monitorDeviceID)
        let mon = monitor ? "monitor ON" : "monitor off"
        let rec = wavPath.map { " recording -> \($0)." } ?? ""
        print(String(format: "Capturing %.0f Hz, %d ch, composite on %@ channel. %@. pilot ref %.2f kHz.%@ Ctrl-C to stop.",
                     fmt.sampleRate, fmt.channels, channel.rawValue, mon, pilotRefKHz, rec))
    } catch {
        FileHandle.standardError.write(Data("Failed to start capture: \(error)\n".utf8))
        return 1
    }

    signal(SIGINT, handleSigint)
    var firstRender = true
    let deadline = seconds.map { Date().addingTimeInterval($0) }
    while gStop == 0 {
        if let deadline, Date() >= deadline { break }
        renderPanel(dashboard(engine.snapshot(), sampleRate: rate, channel: channel.rawValue),
                    firstRender: &firstRender)
        fflush(stdout)
        usleep(500_000)
    }
    engine.stop()
    return 0
}

private func runPipe(
    channel: MeterChannel,
    monitor: Bool,
    monitorDeviceSpec: String?,
    monitorGainDB: Float,
    pilotRefKHz: Float,
    wavPath: String?,
    sampleRate: Double,
    seconds: Double?
) -> Int32 {
    let monitorDeviceID = resolveOutputDevice(monitorDeviceSpec)
    let gainLinear = powf(10.0, monitorGainDB / 20.0)
    let wavURL = wavPath.map { URL(fileURLWithPath: $0) }
    let source = StdinInputSource(sampleRate: sampleRate)
    let engine = MeterAudioEngine(
        sampleRate: Float(sampleRate), channel: channel,
        monitorEnabled: monitor, monitorGain: gainLinear, pilotRefKHz: pilotRefKHz,
        wavURL: wavURL, input: source)
    do {
        try engine.start(monitorDeviceID: monitorDeviceID)
        let mon = monitor ? "monitor ON" : "monitor off"
        let rec = wavPath.map { " recording -> \($0)." } ?? ""
        print(String(format: "Reading MPX from stdin @ %.0f Hz. %@. pilot ref %.2f kHz.%@ Ctrl-C to stop.",
                     sampleRate, mon, pilotRefKHz, rec))
    } catch {
        FileHandle.standardError.write(Data("Failed to start pipe input: \(error)\n".utf8))
        return 1
    }

    signal(SIGINT, handleSigint)
    var firstRender = true
    let deadline = seconds.map { Date().addingTimeInterval($0) }
    while gStop == 0 {
        usleep(500_000)  // let the analysis thread accumulate before rendering
        renderPanel(dashboard(engine.snapshot(), sampleRate: sampleRate, channel: "pipe"),
                    firstRender: &firstRender)
        fflush(stdout)
        if source.finished { break }       // writer closed the pipe
        if let deadline, Date() >= deadline { break }
    }
    usleep(200_000)  // drain
    renderPanel(dashboard(engine.snapshot(), sampleRate: sampleRate, channel: "pipe"),
                firstRender: &firstRender)
    engine.stop()
    return 0
}

private func runSelftest(seconds: Double) -> Int32 {
    let sampleRate: Float = 192_000.0
    print("Self-test: synthetic 19 kHz pilot + 1 kHz mono audio (no RDS/stereo content).")
    let analysis = MeterAnalysis(sampleRate: sampleRate)

    let twoPi = Float.pi * 2.0
    let pilotStep = twoPi * 19_000.0 / sampleRate
    let audioStep = twoPi * 1_000.0 / sampleRate
    var pilotPhase: Float = 0.0
    var audioPhase: Float = 0.0

    let block = 8192
    var buf = [Float](repeating: 0.0, count: block)
    let totalBlocks = max(1, Int((Double(sampleRate) * seconds) / Double(block)))
    var firstRender = true
    for b in 0..<totalBlocks {
        for i in 0..<block {
            let pilot: Float = 0.09 * sinf(pilotPhase)
            let audio: Float = 0.30 * sinf(audioPhase)
            buf[i] = pilot + audio
            pilotPhase += pilotStep
            if pilotPhase >= twoPi { pilotPhase -= twoPi }
            audioPhase += audioStep
            if audioPhase >= twoPi { audioPhase -= twoPi }
        }
        buf.withUnsafeBufferPointer { analysis.process($0) }
        if b % 2 == 0 {
            renderPanel(dashboard(analysis.snapshot(), sampleRate: Double(sampleRate), channel: "self"),
                        firstRender: &firstRender)
            fflush(stdout)
        }
    }
    renderPanel(dashboard(analysis.snapshot(), sampleRate: Double(sampleRate), channel: "self"),
                firstRender: &firstRender)
    print("Self-test done (pilot present; RDS stays '----').")
    return 0
}

// MARK: - Entry

private func parseSeconds(_ args: [String]) -> Double? {
    guard let idx = args.firstIndex(of: "--seconds"), idx + 1 < args.count else { return nil }
    return Double(args[idx + 1])
}

private func parseDevice(_ args: [String]) -> String? {
    guard let idx = args.firstIndex(of: "--device"), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

private func parseChannel(_ args: [String]) -> MeterChannel {
    guard let idx = args.firstIndex(of: "--channel"), idx + 1 < args.count,
          let ch = MeterChannel(rawValue: args[idx + 1].lowercased()) else { return .left }
    return ch
}

private func parseValue(_ args: [String], _ flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

let args = CommandLine.arguments
let exitCode: Int32
if args.contains("--help") || args.contains("-h") {
    printUsage()
    exitCode = 0
} else if args.contains("--list-devices") {
    exitCode = listDevices()
} else if args.contains("--selftest") {
    exitCode = runSelftest(seconds: parseSeconds(args) ?? 2.0)
} else if args.contains("--stdin") {
    exitCode = runPipe(
        channel: parseChannel(args),
        monitor: !args.contains("--no-monitor"),
        monitorDeviceSpec: parseValue(args, "--monitor-device"),
        monitorGainDB: parseValue(args, "--monitor-gain").flatMap { Float($0) } ?? 0.0,
        pilotRefKHz: parseValue(args, "--pilot-ref-khz").flatMap { Float($0) } ?? 6.75,
        wavPath: parseValue(args, "--wav"),
        sampleRate: parseValue(args, "--sample-rate").flatMap { Double($0) } ?? 192_000.0,
        seconds: parseSeconds(args))
} else {
    exitCode = runLive(
        deviceSpec: parseDevice(args),
        channel: parseChannel(args),
        monitor: !args.contains("--no-monitor"),
        monitorDeviceSpec: parseValue(args, "--monitor-device"),
        monitorGainDB: parseValue(args, "--monitor-gain").flatMap { Float($0) } ?? 0.0,
        pilotRefKHz: parseValue(args, "--pilot-ref-khz").flatMap { Float($0) } ?? 6.75,
        wavPath: parseValue(args, "--wav"),
        seconds: parseSeconds(args))
}
exit(exitCode)
