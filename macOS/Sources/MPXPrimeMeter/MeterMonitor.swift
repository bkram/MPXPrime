import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import MPXPrimeCore

/// Plays the decoded L/R audio so the operator hears what a receiver hears.
///
/// Source: the analysis thread writes decoded audio (at the composite sample
/// rate) into a lock-free `StereoInputRingBuffer`. An `AVAudioSourceNode`
/// render block (audio output thread) drains it; `AVAudioEngine` resamples from
/// the composite rate to the chosen output device's rate. Two-ring SPSC: input
/// ring (capture -> analysis) and this monitor ring (analysis -> output) each
/// have exactly one producer and one consumer.
final class MeterMonitor: @unchecked Sendable {
    // Target ring fill the adaptive read holds, and the deadband inside which
    // it does not trim. ~10 ms / ~2.5 ms at 192 kHz: enough to absorb a
    // scheduling hiccup, small enough that the added monitor latency is
    // inaudible.
    private static let adaptiveTargetFrames = 2048
    private static let adaptiveDeadbandFrames = 512

    private let engine = AVAudioEngine()
    private let ring: StereoInputRingBuffer
    private let sampleRate: Double
    private let gain: Float
    private var sourceNode: AVAudioSourceNode?
    private var started = false

    init(ring: StereoInputRingBuffer, sampleRate: Double, gain: Float) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.gain = gain
    }

    /// Start playback. `outputDeviceID == nil` uses the system default output.
    func start(outputDeviceID: AudioDeviceID?) throws {
        // The output device must be set on the HAL output unit before the
        // engine starts. nil leaves AVAudioEngine on the default output.
        if let dev = outputDeviceID, let unit = engine.outputNode.audioUnit {
            var d = dev
            let st = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr {
                FileHandle.standardError.write(
                    Data("WARNING: could not set monitor output device (status \(st)); using default.\n".utf8))
            }
        }

        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw NSError(domain: "MeterMonitor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid monitor format"])
        }

        let ring = self.ring
        let gain = self.gain
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let n = Int(frameCount)
            guard abl.count >= 2,
                  let lraw = abl[0].mData,
                  let rraw = abl[1].mData else { return noErr }
            let lp = lraw.assumingMemoryBound(to: Float.self)
            let rp = rraw.assumingMemoryBound(to: Float.self)
            // Adaptive read, not a plain one: the producer clock (the capture
            // device or the SDR's own crystal) is independent of this output
            // device's clock, so consuming exactly `n` frames per callback
            // lets the buffered amount drift until it underruns (a click every
            // few minutes, straight into an exciter on the MPX pass-through)
            // or saturates. `readAdaptive` micro-resamples to hold the target
            // fill, the same mechanism the encoder's input path uses (audit
            // B17). Underflow still pads with silence.
            _ = ring.readAdaptive(
                intoLeft: lp, outRight: rp, frameCount: n,
                nominalConsume: n,
                targetBuffered: max(n * 2, Self.adaptiveTargetFrames),
                deadband: max(n / 2, Self.adaptiveDeadbandFrames))
            if gain != 1.0 {
                var g = gain
                vDSP_vsmul(lp, 1, &g, lp, 1, vDSP_Length(n))
                vDSP_vsmul(rp, 1, &g, rp, 1, vDSP_Length(n))
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try engine.start()
        started = true
    }

    func stop() {
        if started {
            engine.stop()
            started = false
        }
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
    }
}
