import AppKit
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
      --gui              Open the graphical dashboard window (also the default
                         when launched with no arguments, e.g. the .app bundle).
      --sdr-freq <MHz>   Open the GUI pre-tuned to this RTL-SDR frequency and
                         start capturing (used by run-meter-sdr.sh --gui).
      --stdin            Read the MPX composite from stdin (a WAV stream or raw
                         little-endian int16 mono) instead of an audio device.
                         For piping an external tuner -- see run-meter-sdr.sh.
      --sample-rate <Hz> Sample rate for --stdin raw/WAV input (default 192000).
      --full-scale-khz <kHz>
                         Absolute calibration for an audio-device or --stdin
                         input: digital full scale equals this many kHz of FM
                         deviation (FM-SDR-Tuner at its default -6 dB MPX gain:
                         150). PILOT then becomes a real measurement instead of
                         an assumed reference. The startup line names the
                         convention actually in use.
      --deemphasis <us>  Receiver de-emphasis for the DECODED audio: 50
                         (default; ITU Region 1) or 75 (the Americas, Japan,
                         Korea). Affects the monitor, the WAV recording and the
                         decoded levels only -- deviation, pilot, RDS and MPX
                         power are measured ahead of it.
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

/// Bucket index (`groupType * 2 + versionB`) as "0A" / "11B".
private func groupLabel(_ bucket: Int) -> String {
    "\(bucket / 2)\(bucket % 2 == 0 ? "A" : "B")"
}

/// Counts AND shares: the share is what says whether the mix is sane.
private func groupSummary(_ counts: [Int]) -> String {
    let total = counts.reduce(0, +)
    guard total > 0 else { return "--" }
    var parts: [String] = []
    for bucket in 0..<min(32, counts.count) where counts[bucket] > 0 {
        let pct = Double(counts[bucket]) / Double(total) * 100.0
        parts.append(String(format: "%@:%d(%.0f%%)", groupLabel(bucket), counts[bucket], pct))
    }
    return parts.isEmpty ? "--" : parts.joined(separator: " ")
}

/// The last groups in transmission order -- the scheduler's interleave.
private func groupOrderSummary(_ order: [Int]) -> String {
    order.isEmpty ? "--" : order.map(groupLabel).joined(separator: " ")
}

/// Word for the 0..4 signal-quality scale.
private func qualityWord(_ level: Int) -> String {
    switch level {
    case 4: return "Excellent"
    case 3: return "Good"
    case 2: return "Usable"
    case 1: return "Poor"
    default: return "Unusable"
    }
}

// RT+ content-type class names (ETSI TS 101 499 / IEC 62106-2). Index = code.
private let rtPlusClassNames = [
    "DUMMY", "TITLE", "ALBUM", "TRACK", "ARTIST", "COMPOSITION", "MOVEMENT",
    "CONDUCTOR", "COMPOSER", "BAND", "COMMENT", "GENRE", "NEWS", "NEWS.LOCAL",
    "STOCK", "SPORT", "LOTTERY", "HOROSCOPE", "DIVERSION", "HEALTH", "EVENT",
    "SCENE", "CINEMA", "TV", "DATETIME", "WEATHER", "TRAFFIC", "ALARM", "AD",
    "URL", "OTHER", "STATION.SHORT", "STATION.LONG", "NOW", "NEXT", "PART",
    "HOST", "EDITORIAL", "FREQUENCY", "HOMEPAGE", "SUBCHANNEL"
]

private func rtPlusClassName(_ t: Int) -> String {
    (t >= 0 && t < rtPlusClassNames.count) ? rtPlusClassNames[t] : "T\(t)"
}

/// RT+ tags as `CLASS="text"` pairs (e.g. `ARTIST="..." TITLE="..."`), or "--".
private func rtPlusSummary(_ tags: [RDSRTPlusTag]) -> String {
    if tags.isEmpty { return "--" }
    return tags.map { "\(rtPlusClassName($0.contentType))=\"\($0.text)\"" }
        .joined(separator: "  ")
}

/// Fixed-height SFP-style panel. Always the same line count so the live TTY
/// refresh can move the cursor up a constant amount.
private func dashboard(
    _ s: MeterSnapshot, sampleRate: Double, channel: String, calLabel: String = "pilot=ref"
) -> [String] {
    let pi = s.rds.pi.map { String(format: "%04X", $0) } ?? "----"
    let sync = s.rds.synced ? "sync" : "----"
    let psLine = "\"\(s.rds.programService)\""
    let ptyn = s.rds.programTypeName.trimmingCharacters(in: .whitespaces)
    let eccStr = s.rds.ecc.map { String(format: "%02X", $0) } ?? "--"
    let rt = s.rds.radioText.isEmpty ? "--" : "\"\(s.rds.radioText)\""
    let lps = s.rds.longPS.isEmpty ? "--" : "\"\(s.rds.longPS)\""
    let ct = s.rds.clockTime.map(clockString) ?? "--"
    let af = s.rds.alternativeFrequenciesMHz.isEmpty
        ? "--"
        : s.rds.alternativeFrequenciesMHz.prefix(12).map { String(format: "%.1f", $0) }
            .joined(separator: " ") + " MHz"

    return [
        String(format: "INPUT  %6.1f dBFS   %.0f kHz   ch:%@",
               s.inputPeakDBFS, sampleRate / 1000.0, channel),
        // RDS phase (EN 50067 sec 1.2) rides the deviation line: it belongs
        // with the subcarrier's injection level, and the panel's line count
        // must stay constant for the in-place ANSI refresh.
        String(format: "DEV    PILOT %.2f   RDS %.2f   MAX %5.1f kHz   PHASE %@   (%@)",
               s.pilotDevKHz, s.rdsDevKHz, s.maxDevKHz,
               s.pilotRDSPhaseValid
                   ? String(format: "%2.0f deg %@", s.pilotRDSPhaseDeg,
                            s.pilotRDSPhase.label)
                   : "--",
               calLabel),
        // Modulation compliance: BS.412 sliding-60s MPX power (+ worst window
        // since start), 60 s +/- deviation peaks, SM.1268-5 >77 kHz share.
        String(format: "MOD    MPX %@ dBr (max %@)   PK %+.1f/%+.1f kHz   >77k %@",
               s.mpxPowerValid ? String(format: "%+.1f", s.mpxPowerDBr) : "--",
               s.mpxPowerMaxValid ? String(format: "%+.1f", s.mpxPowerMaxDBr) : "--",
               s.posPeakDevKHz, s.negPeakDevKHz,
               s.exceedanceValid
                   ? (s.exceedancePct <= 0.0
                       ? "0%" : String(format: "%.5f%%", s.exceedancePct))
                   : "--"),
        // Deviation statistics + the accumulated distribution's headline
        // figures: the highest bin ever filled and the share at/over 75 kHz.
        String(format: "DIST   AVE %5.1f  MIN %5.1f kHz   hist peak %3.0f kHz  >=75k %@  n=%@",
               s.aveDevKHz, s.minDevKHz, s.devHistogramMaxKHz,
               s.devHistogramSamples > 0
                   ? String(format: "%.2f%%", Double(s.devDistributionAtOrAbove(75.0)) * 100.0)
                   : "--",
               s.devHistogramSamples > 0 ? "\(s.devHistogramSamples)" : "--"),
        // Reception / chain quality.
        String(format: "QUAL   %@   noise %@   offset %@   L/R %@",
               s.basebandNoiseValid ? qualityWord(s.signalQuality) : "--",
               s.basebandNoiseValid
                   ? String(format: "%.2f kHz", s.basebandNoiseKHz) : "--",
               s.carrierOffsetValid
                   ? String(format: "%+.1f kHz", s.carrierOffsetKHz) : "--",
               s.stereoBalanceValid
                   ? String(format: "%+.1f dB", s.stereoBalanceDB) : "--"),
        String(format: "STEREO L %6.1f  R %6.1f dBFS   corr %+.2f",
               s.leftRMSDBFS, s.rightRMSDBFS, s.stereoCorrelation),
        String(format: "RDS    %@  PI %@  PTY %@ (%@)  TP%@ TA%@ MS%@  BER %.1f%%",
               sync, pi, ptyLabel(s.rds.pty), ptyName(s.rds.pty),
               boolField(s.rds.tp), boolField(s.rds.ta), boolField(s.rds.ms),
               s.recentBlockErrorRate * 100.0),
        "PS     \(psLine)   PTYN \"\(ptyn)\"   ECC \(eccStr)",
        "LPS    \(lps)",
        "RT     \(rt)",
        "RT+    \(rtPlusSummary(s.rds.rtPlusTags))",
        "CT     \(ct)",
        "AF     \(af)",
        "GRP    \(groupSummary(s.rds.groupCounts))",
        "ORDER  \(groupOrderSummary(s.rds.groupOrder))"
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
    fullScaleKHz: Float?,
    preemphasisUS: Int,
    wavPath: String?,
    seconds: Double?
) -> Int32 {
    guard let deviceID = resolveDevice(deviceSpec) else {
        FileHandle.standardError.write(Data("No matching input device (try --list-devices).\n".utf8))
        return 1
    }
    // Raise the device to 192 kHz (or its best rate) before opening; the AUHAL
    // captures at whatever the device is currently set to.
    let prep = MeterAudioEngine.prepareInputRate(deviceID: deviceID)
    if let warning = prep.warning { print("WARNING: \(warning).") }
    let rate = prep.rate

    let monitorDeviceID = resolveOutputDevice(monitorDeviceSpec)
    let gainLinear = powf(10.0, monitorGainDB / 20.0)
    let wavURL = wavPath.map { URL(fileURLWithPath: $0) }
    let engine = MeterAudioEngine(
        sampleRate: Float(rate), channel: channel,
        monitorEnabled: monitor, monitorGain: gainLinear, pilotRefKHz: pilotRefKHz,
        fullScaleKHz: fullScaleKHz, preemphasisUS: preemphasisUS,
        wavURL: wavURL,
        input: AUHALInputSource(deviceID: deviceID,
                                maxFramesPerSlice: MeterAudioEngine.maxSliceFrames))
    var captureRate = rate
    do {
        let fmt = try engine.start(monitorDeviceID: monitorDeviceID)
        captureRate = fmt.sampleRate
        if abs(fmt.sampleRate - rate) > 1.0 {
            print(String(format: "WARNING: device opened at %.0f Hz, not the requested %.0f Hz.",
                         fmt.sampleRate, rate))
        }
        let mon = monitor ? "monitor ON" : "monitor off"
        let rec = wavPath.map { " recording -> \($0)." } ?? ""
        // Name the calibration convention actually in effect: --full-scale-khz
        // used to be accepted on this path and silently ignored, so the
        // numbers were pilot-referenced when absolute was asked for.
        let cal = fullScaleKHz.map { String(format: "absolute cal 0 dBFS = %.0f kHz", $0) }
            ?? String(format: "pilot ref %.2f kHz", pilotRefKHz)
        print(String(format: "Capturing %.0f Hz, %d ch, composite on %@ channel. %@. %@, de-emphasis %d us.%@ Ctrl-C to stop.",
                     fmt.sampleRate, fmt.channels, channel.rawValue, mon, cal,
                     preemphasisUS, rec))
    } catch {
        FileHandle.standardError.write(Data("Failed to start capture: \(error)\n".utf8))
        MeterAudioEngine.restoreInputRate(deviceID: deviceID, to: prep.prior)
        return 1
    }

    signal(SIGINT, handleSigint)
    var firstRender = true
    let deadline = seconds.map { Date().addingTimeInterval($0) }
    while gStop == 0 {
        if let deadline, Date() >= deadline { break }
        renderPanel(dashboard(engine.snapshot(), sampleRate: captureRate, channel: channel.rawValue),
                    firstRender: &firstRender)
        fflush(stdout)
        usleep(500_000)
    }
    engine.stop()
    MeterAudioEngine.restoreInputRate(deviceID: deviceID, to: prep.prior)
    return 0
}

private func runPipe(
    channel: MeterChannel,
    monitor: Bool,
    monitorDeviceSpec: String?,
    monitorGainDB: Float,
    pilotRefKHz: Float,
    fullScaleKHz: Float?,
    preemphasisUS: Int,
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
        fullScaleKHz: fullScaleKHz, preemphasisUS: preemphasisUS,
        wavURL: wavURL, input: source)
    do {
        try engine.start(monitorDeviceID: monitorDeviceID)
        let mon = monitor ? "monitor ON" : "monitor off"
        let rec = wavPath.map { " recording -> \($0)." } ?? ""
        let cal = fullScaleKHz.map { String(format: "abs cal FS=%.0f kHz", $0) }
            ?? String(format: "pilot ref %.2f kHz", pilotRefKHz)
        print(String(format: "Reading MPX from stdin @ %.0f Hz. %@. %@.%@ Ctrl-C to stop.",
                     sampleRate, mon, cal, rec))
    } catch {
        FileHandle.standardError.write(Data("Failed to start pipe input: \(error)\n".utf8))
        return 1
    }

    let calLabel = fullScaleKHz != nil ? "abs cal" : "pilot=ref"
    signal(SIGINT, handleSigint)
    var firstRender = true
    let deadline = seconds.map { Date().addingTimeInterval($0) }
    while gStop == 0 {
        usleep(500_000)  // let the analysis thread accumulate before rendering
        renderPanel(dashboard(engine.snapshot(), sampleRate: sampleRate, channel: "pipe", calLabel: calLabel),
                    firstRender: &firstRender)
        fflush(stdout)
        if source.finished { break }       // writer closed the pipe
        if let deadline, Date() >= deadline { break }
    }
    usleep(200_000)  // drain
    renderPanel(dashboard(engine.snapshot(), sampleRate: sampleRate, channel: "pipe", calLabel: calLabel),
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

/// Launch the SwiftUI dashboard window (blocks until the app quits). When
/// `sdrFreqMHz` is set, the window opens pre-tuned to that SDR frequency and
/// starts capturing immediately (used by run-meter-sdr.sh --gui).
@MainActor
private func runGUI(sdrFreqMHz: Double?) -> Int32 {
    let app = NSApplication.shared
    let delegate = MeterAppDelegate(autoStartSDRFreqMHz: sdrFreqMHz)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    return 0
}

// Headless capture/control flags. Their presence selects a CLI mode; their
// absence (or an explicit --gui) opens the window.
private let liveFlags = [
    "--device", "--channel", "--seconds", "--no-monitor",
    "--monitor-device", "--monitor-gain", "--wav", "--pilot-ref-khz",
    "--full-scale-khz", "--deemphasis"
]

/// `--deemphasis <50|75>`: receiver de-emphasis time constant for the decode
/// path. Anything other than 75 means the 50 us default.
private func parseDeemphasisUS(_ args: [String]) -> Int {
    parseValue(args, "--deemphasis").flatMap { Int($0) } == 75 ? 75 : 50
}

let args = CommandLine.arguments
let userArgs = Array(args.dropFirst())
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
        fullScaleKHz: parseValue(args, "--full-scale-khz").flatMap { Float($0) },
        preemphasisUS: parseDeemphasisUS(args),
        wavPath: parseValue(args, "--wav"),
        sampleRate: parseValue(args, "--sample-rate").flatMap { Double($0) } ?? 192_000.0,
        seconds: parseSeconds(args))
} else if args.contains("--gui") || args.contains("--sdr-freq")
            || userArgs.isEmpty || !liveFlags.contains(where: args.contains) {
    // Explicit --gui, no arguments at all (double-clicked .app), or no
    // headless capture flag present -> open the dashboard window. --sdr-freq
    // additionally pre-tunes the SDR and auto-starts.
    exitCode = runGUI(sdrFreqMHz: parseValue(args, "--sdr-freq").flatMap { Double($0) })
} else {
    exitCode = runLive(
        deviceSpec: parseDevice(args),
        channel: parseChannel(args),
        monitor: !args.contains("--no-monitor"),
        monitorDeviceSpec: parseValue(args, "--monitor-device"),
        monitorGainDB: parseValue(args, "--monitor-gain").flatMap { Float($0) } ?? 0.0,
        pilotRefKHz: parseValue(args, "--pilot-ref-khz").flatMap { Float($0) } ?? 6.75,
        fullScaleKHz: parseValue(args, "--full-scale-khz").flatMap { Float($0) },
        preemphasisUS: parseDeemphasisUS(args),
        wavPath: parseValue(args, "--wav"),
        seconds: parseSeconds(args))
}
exit(exitCode)
