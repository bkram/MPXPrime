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
      --seconds N        Run for N seconds then exit (default: until Ctrl-C;
                         --selftest defaults to 2 s).
      --selftest         No hardware: synthesize a pilot + mono-audio composite
                         and run the analysis path. (RDS/stereo decode is
                         covered by the unit tests; this is a pipeline smoke.)
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

private func statusLine(_ s: MeterSnapshot) -> String {
    let pilot = s.pilotPresent
        ? String(format: "lock %.1f%%", s.pilotPercent)
        : "--"
    let pi = s.rds.pi.map { String(format: "%04X", $0) } ?? "----"
    let ps = "\"\(s.rds.programService)\""
    let ber = String(format: "%.1f%%", s.rds.blockErrorRate * 100.0)
    // "sync" only on real block synchronization. The front-end's bit-phase
    // lock fires on any present pilot (even with no RDS), so it would
    // overclaim here -- a high BER alongside "----" is the no-RDS signature.
    let rdsSync = s.rds.synced ? "sync" : "----"
    return String(
        format:
            "in %6.1f dBFS | pilot %@ | L %6.1f R %6.1f corr %+.2f | "
            + "RDS %@ PI=%@ PS=%@ PTY=%@ TP=%@ TA=%@ MS=%@ BER=%@",
        s.inputPeakDBFS, pilot,
        s.leftRMSDBFS, s.rightRMSDBFS, s.stereoCorrelation,
        rdsSync, pi, ps, ptyLabel(s.rds.pty),
        boolField(s.rds.tp), boolField(s.rds.ta), boolField(s.rds.ms), ber)
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
    return nil
}

private func runLive(deviceSpec: String?, channel: MeterChannel, seconds: Double?) -> Int32 {
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

    let engine = MeterAudioEngine(sampleRate: Float(rate), channel: channel)
    do {
        let fmt = try engine.start(deviceID: deviceID)
        print(String(format: "Capturing at %.0f Hz, %d ch, composite on %@ channel. Ctrl-C to stop.\n",
                     fmt.sampleRate, fmt.channels, channel.rawValue))
    } catch {
        FileHandle.standardError.write(Data("Failed to start capture: \(error)\n".utf8))
        return 1
    }

    signal(SIGINT, handleSigint)
    let deadline = seconds.map { Date().addingTimeInterval($0) }
    while gStop == 0 {
        if let deadline, Date() >= deadline { break }
        print("\r" + statusLine(engine.snapshot()), terminator: "")
        fflush(stdout)
        usleep(500_000)
    }
    print("")
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
            print("\r" + statusLine(analysis.snapshot()), terminator: "")
            fflush(stdout)
        }
    }
    print("\n" + statusLine(analysis.snapshot()))
    print("Self-test done (pilot should read present; RDS stays '----').")
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

let args = CommandLine.arguments
let exitCode: Int32
if args.contains("--help") || args.contains("-h") {
    printUsage()
    exitCode = 0
} else if args.contains("--list-devices") {
    exitCode = listDevices()
} else if args.contains("--selftest") {
    exitCode = runSelftest(seconds: parseSeconds(args) ?? 2.0)
} else {
    exitCode = runLive(
        deviceSpec: parseDevice(args),
        channel: parseChannel(args),
        seconds: parseSeconds(args))
}
exit(exitCode)
