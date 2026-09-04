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
    // it does not trim. These MUST be sized against the PRODUCER'S BURST, not
    // against the output callback: the analysis thread writes decoded audio
    // in blocks of up to `MeterAudioEngine.blockFrames` (8192) frames, so the
    // instantaneous fill sawtooths ~+/-4096 around whatever average the
    // adaptive loop pins. The original 2048-frame target sat BELOW that swing,
    // so the loop dutifully dragged the sawtooth's floor through zero and the
    // monitor clicked on every burst cycle -- on ALL stations, while the air
    // was clean (found 2026-08-31; the pre-adaptive plain read only clicked
    // rarely, on accumulated clock drift, which is why the monitor "used to
    // sound high-end"). 12288 +/- 3072 keeps the worst-case floor at
    // 12288 - 3072 - 4096 = 5120 frames (~27 ms of scheduling margin) and the
    // ceiling well inside the 32768-frame ring. The added ~64 ms of monitor /
    // pass-through latency is irrelevant for listening and relay use.
    private static let adaptiveTargetFrames = 12288
    private static let adaptiveDeadbandFrames = 3072

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
