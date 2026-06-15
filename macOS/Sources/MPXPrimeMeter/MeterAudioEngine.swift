import Atomics
import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore

/// Which input channel carries the composite. A composite is a single real
/// signal patched to one channel of the interface (varies by hardware -- e.g.
/// some USB DACs expose it on the right channel).
enum MeterChannel: String {
    case left, right, mix
}

/// Live capture wiring: `MPXInputSource` (AUHAL @ device rate) -> lock-free
/// `StereoInputRingBuffer` -> a background analysis thread that drains the ring
/// and runs `MeterAnalysis`. The latest snapshot is published under a lock for
/// the (CLI main-thread) display loop.
///
/// The composite is mono on the selected `channel`. The decoders assume the
/// configured `sampleRate` matches the device format (192 kHz for a real
/// composite — RDS at 57 kHz needs Nyquist > 57 kHz, so >= 128 kHz).
final class MeterAudioEngine: @unchecked Sendable {
    private static let maxSliceFrames = 4096

    private let input: MPXInputSource
    private let ring: StereoInputRingBuffer
    private let analysis: MeterAnalysis
    private let blockFrames: Int
    private let channel: MeterChannel
    private let sampleRate: Float
    // Pre-allocated scratch for the .mix sum so the capture-thread sink never
    // allocates.
    private let mixScratch: UnsafeMutablePointer<Float>
    private let mixScratchCap: Int

    // Monitor (decoded-audio playback). nil when monitoring is disabled.
    private let monitorEnabled: Bool
    private let monitorGain: Float
    private let monitorRing: StereoInputRingBuffer
    private var monitor: MeterMonitor?

    // Optional WAV capture of the decoded audio.
    private let wavURL: URL?
    private var recorder: MeterRecorder?

    private var consumer: Thread?
    private let runningFlag = ManagedAtomic<Bool>(false)
    private let consumerDone = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var published = MeterSnapshot()

    init(
        sampleRate: Float,
        channel: MeterChannel = .left,
        monitorEnabled: Bool = false,
        monitorGain: Float = 1.0,
        pilotRefKHz: Float = 6.75,
        fullScaleKHz: Float? = nil,
        wavURL: URL? = nil,
        input: MPXInputSource
    ) {
        self.input = input
        self.ring = StereoInputRingBuffer(capacityFrames: 1 << 16)
        self.analysis = MeterAnalysis(
            sampleRate: sampleRate, pilotRefKHz: pilotRefKHz, fullScaleKHz: fullScaleKHz)
        self.blockFrames = 8192
        self.channel = channel
        self.sampleRate = sampleRate
        self.mixScratchCap = Self.maxSliceFrames
        self.mixScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxSliceFrames)
        self.mixScratch.initialize(repeating: 0.0, count: Self.maxSliceFrames)
        self.monitorEnabled = monitorEnabled
        self.monitorGain = monitorGain
        self.monitorRing = StereoInputRingBuffer(capacityFrames: 1 << 15)
        self.wavURL = wavURL
    }

    deinit {
        mixScratch.deinitialize(count: mixScratchCap)
        mixScratch.deallocate()
    }

    @discardableResult
    func start(monitorDeviceID: AudioDeviceID? = nil) throws -> (sampleRate: Double, channels: Int) {
        let ring = self.ring
        let channel = self.channel
        let scratch = self.mixScratch
        let scratchCap = self.mixScratchCap
        input.frameSink = { left, right, frames in
            switch channel {
            case .left:
                ring.writeMono(mono: left, frameCount: frames)
            case .right:
                ring.writeMono(mono: right, frameCount: frames)
            case .mix:
                let n = min(frames, scratchCap)
                for i in 0..<n { scratch[i] = 0.5 * (left[i] + right[i]) }
                ring.writeMono(mono: scratch, frameCount: n)
            }
        }
        let fmt = try input.start()

        if monitorEnabled {
            let mon = MeterMonitor(ring: monitorRing, sampleRate: Double(sampleRate), gain: monitorGain)
            try mon.start(outputDeviceID: monitorDeviceID)
            monitor = mon
        }

        if let wavURL {
            recorder = try MeterRecorder(url: wavURL, sampleRate: Double(sampleRate))
        }

        runningFlag.store(true, ordering: .relaxed)
        let t = Thread { [weak self] in self?.consumeLoop() }
        t.name = "com.mpxprime.meter.analysis"
        t.qualityOfService = .userInitiated
        t.start()
        consumer = t
        return fmt
    }

    func stop() {
        runningFlag.store(false, ordering: .relaxed)
        input.stop()
        // Wait for the consumer thread to actually exit before tearing down
        // the monitor/recorder it touches -- a bare sleep races (TSan-flagged);
        // the semaphore is a real happens-before handshake.
        _ = consumerDone.wait(timeout: .now() + 1.0)
        consumer = nil
        monitor?.stop()
        monitor = nil
        // Release the recorder so AVAudioFile finalizes the WAV header.
        recorder = nil
    }

    func snapshot() -> MeterSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    /// Reset the deviation peak-hold + best-separation accumulators.
    func resetPeaks() { analysis.requestPeakReset() }

    /// Raise an input device to the best capture rate before opening it: 192 kHz
    /// if supported, else the highest supported rate >= 128 kHz (RDS at 57 kHz
    /// needs Nyquist > 57 kHz). The AUHAL cannot sample-rate-convert, so it
    /// captures at whatever rate the device is currently set to -- we must set
    /// the device's nominal rate ourselves. Returns the rate the device ended
    /// up at, the prior rate (pass to `restoreInputRate` on stop), and an
    /// optional warning when nothing >= 128 kHz is available.
    static func prepareInputRate(
        deviceID: AudioDeviceID, preferred: Double = 192_000
    ) -> (rate: Double, prior: Double?, warning: String?) {
        let available = AudioDevices.availableNominalSampleRates(deviceID: deviceID)
        let prior = AudioDevices.currentNominalSampleRate(deviceID: deviceID)
        var target = preferred
        var warning: String?
        if available.contains(where: { abs($0 - preferred) < 1.0 }) {
            target = preferred
        } else if let best = available.filter({ $0 >= 128_000 }).max() {
            target = best
        } else if let highest = available.max() {
            target = highest
            warning = "device max \(Int(highest)) Hz < 128 kHz -- RDS (57 kHz) cannot decode"
        } else {
            target = prior ?? preferred  // couldn't enumerate; keep current
        }
        let actual = AudioDevices.setNominalSampleRate(deviceID: deviceID, target)
            ?? prior ?? target
        return (actual, prior, warning)
    }

    /// Restore a device's nominal rate (best-effort) saved by `prepareInputRate`.
    static func restoreInputRate(deviceID: AudioDeviceID, to prior: Double?) {
        guard let prior else { return }
        _ = AudioDevices.setNominalSampleRate(deviceID: deviceID, prior)
    }

    private func consumeLoop() {
        defer { consumerDone.signal() }
        var left = [Float](repeating: 0.0, count: blockFrames)
        var right = [Float](repeating: 0.0, count: blockFrames)
        while runningFlag.load(ordering: .relaxed) {
            let missing = left.withUnsafeMutableBufferPointer { lp -> Int in
                right.withUnsafeMutableBufferPointer { rp -> Int in
                    guard let lb = lp.baseAddress, let rb = rp.baseAddress else {
                        return blockFrames
                    }
                    return ring.read(intoLeft: lb, outRight: rb, frameCount: blockFrames)
                }
            }
            let got = blockFrames - missing
            if got > 0 {
                left.withUnsafeBufferPointer { lp in
                    analysis.process(UnsafeBufferPointer(start: lp.baseAddress, count: got))
                }
                let count = analysis.lastBlockCount
                if monitorEnabled {
                    analysis.decodedL.withUnsafeBufferPointer { lp in
                        analysis.decodedR.withUnsafeBufferPointer { rp in
                            if let lb = lp.baseAddress, let rb = rp.baseAddress {
                                monitorRing.write(left: lb, right: rb, frameCount: count)
                            }
                        }
                    }
                }
                recorder?.write(left: analysis.decodedL, right: analysis.decodedR, count: count)
                // Isolated copy: the snapshot crosses to the display thread,
                // and the decoder keeps mutating its CoW buffers each block.
                let s = analysis.isolatedSnapshot()
                lock.lock()
                published = s
                lock.unlock()
            }
            if got < blockFrames {
                // Ring drained: wait for the capture thread to refill.
                usleep(20_000)
            }
        }
    }
}
