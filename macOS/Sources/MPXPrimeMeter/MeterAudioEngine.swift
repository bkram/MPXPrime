import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore

/// Live capture wiring: `MPXInputSource` (AUHAL @ device rate) -> lock-free
/// `StereoInputRingBuffer` -> a background analysis thread that drains the ring
/// and runs `MeterAnalysis`. The latest snapshot is published under a lock for
/// the (CLI main-thread) display loop.
///
/// The composite is mono; the input's left channel is captured. The decoders
/// assume the configured `sampleRate` matches the device format (192 kHz for a
/// real composite — RDS at 57 kHz needs Nyquist > 57 kHz, so >= 128 kHz).
final class MeterAudioEngine: @unchecked Sendable {
    private let input: MPXInputSource
    private let ring: StereoInputRingBuffer
    private let analysis: MeterAnalysis
    private let blockFrames: Int

    private var consumer: Thread?
    private var running = false
    private let lock = NSLock()
    private var published = MeterSnapshot()

    init(sampleRate: Float, input: MPXInputSource = AUHALInputSource()) {
        self.input = input
        self.ring = StereoInputRingBuffer(capacityFrames: 1 << 16)
        self.analysis = MeterAnalysis(sampleRate: sampleRate)
        self.blockFrames = 8192
    }

    @discardableResult
    func start(deviceID: AudioDeviceID) throws -> (sampleRate: Double, channels: Int) {
        let ring = self.ring
        input.frameSink = { left, _, frames in
            ring.writeMono(mono: left, frameCount: frames)
        }
        let fmt = try input.start(deviceID: deviceID, maxFramesPerSlice: 4096)

        running = true
        let t = Thread { [weak self] in self?.consumeLoop() }
        t.name = "com.mpxprime.meter.analysis"
        t.qualityOfService = .userInitiated
        t.start()
        consumer = t
        return fmt
    }

    func stop() {
        running = false
        input.stop()
        // Give the consumer a beat to observe `running == false` and exit.
        usleep(50_000)
        consumer = nil
    }

    func snapshot() -> MeterSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    private func consumeLoop() {
        var left = [Float](repeating: 0.0, count: blockFrames)
        var right = [Float](repeating: 0.0, count: blockFrames)
        while running {
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
                let s = analysis.snapshot()
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
