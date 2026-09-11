// Capture stereo program audio from a CoreAudio input device (default:
// BlackHole 2ch) to a WAV file, for building the --verify-program-ab
// real-music corpus. Compiled on demand by scripts/capture-program.sh:
//   swiftc -O -o capture-to-wav scripts/CaptureToWav.swift
// Usage:
//   capture-to-wav --out <path.wav> [--device-uid BlackHole2ch_UID]
//                  [--seconds 60]
//
// Known sharp edge: AVAudioEngine's FIRST start on a non-default input
// device can silently deliver no tap callbacks (the bug that moved MPX
// Prime Studio's capture to direct AUHAL). This tool watchdogs the first
// buffers and restarts the engine up to 3 times.

import AVFoundation
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("capture-to-wav: " + message + "\n").utf8))
    exit(1)
}

func deviceID(forUID uid: String) -> AudioDeviceID? {
    var deviceID = kAudioObjectUnknown
    var cfUID = uid as CFString
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
    }
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

var outPath: String?
var uid = "BlackHole2ch_UID"
var seconds = 60.0
var i = 1
let args = CommandLine.arguments
while i < args.count {
    switch args[i] {
    case "--out":
        if i + 1 < args.count { outPath = args[i + 1]; i += 1 }
    case "--device-uid":
        if i + 1 < args.count { uid = args[i + 1]; i += 1 }
    case "--seconds":
        if i + 1 < args.count, let s = Double(args[i + 1]), s > 0 { seconds = s; i += 1 }
    default:
        fail("unknown argument \(args[i])")
    }
    i += 1
}
guard let outPath else { fail("--out <path.wav> is required") }
guard let captureDevice = deviceID(forUID: uid) else {
    fail("input device with UID '\(uid)' not found (is BlackHole installed?)")
}

let url = URL(fileURLWithPath: outPath)

final class CaptureBox: @unchecked Sendable {
    let engine = AVAudioEngine()
    var file: AVAudioFile?
    var frames: Int64 = 0
    let lock = NSLock()
}
let box = CaptureBox()

func startEngine() throws {
    let input = box.engine.inputNode
    guard let unit = input.audioUnit else { fail("input node has no audio unit") }
    var device = captureDevice
    let status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else { fail("could not select device (OSStatus \(status))") }

    let format = input.inputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
        fail("device reports no input format (rate \(format.sampleRate))")
    }
    if box.file == nil {
        box.file = try AVAudioFile(forWriting: url, settings: format.settings)
        print("Recording \(Int(seconds)) s from '\(uid)' at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        print("-> \(outPath)")
    }
    input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
        box.lock.lock()
        defer { box.lock.unlock() }
        guard let file = box.file, Double(box.frames) < seconds * format.sampleRate else { return }
        do {
            try file.write(from: buffer)
            box.frames += Int64(buffer.frameLength)
        } catch {
            fail("write failed: \(error)")
        }
    }
    try box.engine.start()
}

try startEngine()

// Watchdog: restart on the silent-first-start bug.
var attempts = 1
var lastStart = Date()
let deadline = Date().addingTimeInterval(seconds + 20.0)
while true {
    Thread.sleep(forTimeInterval: 0.25)
    box.lock.lock()
    let frames = box.frames
    box.lock.unlock()
    let format = box.engine.inputNode.inputFormat(forBus: 0)
    if Double(frames) >= seconds * format.sampleRate { break }
    if frames == 0, Date().timeIntervalSince(lastStart) > 3.0 {
        if attempts >= 3 { fail("no audio arriving from '\(uid)' after \(attempts) starts") }
        attempts += 1
        box.engine.inputNode.removeTap(onBus: 0)
        box.engine.stop()
        try startEngine()
        lastStart = Date()
    }
    if Date() > deadline { fail("timed out waiting for \(Int(seconds)) s of audio") }
}

box.engine.inputNode.removeTap(onBus: 0)
box.engine.stop()
box.lock.lock()
let total = box.frames
box.file = nil  // closes the file
box.lock.unlock()
print("Done: \(total) frames written.")
