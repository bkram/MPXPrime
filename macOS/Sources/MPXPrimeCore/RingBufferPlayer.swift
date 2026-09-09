#if os(macOS)
import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// Plays a `StereoInputRingBuffer` out of a chosen audio device, on its own
/// `AVAudioEngine`, alongside whatever else the app is doing.
///
/// Both apps need exactly this: the Meter hears what a receiver hears while it
/// analyses, and Studio's operator hears the processed program on a second
/// device while the transmitter feed keeps going out of the first. It is one
/// class because two copies of a lock-free player is precisely the thing the
/// Meter's own bug history argues against (see the adaptive-read note below).
///
/// The producer writes into the ring from ITS thread (the analysis thread, or
/// the encoder's render callback); this class's render block drains it on the
/// output device's thread. One producer, one consumer, no locks.
public final class RingBufferPlayer: @unchecked Sendable {
    /// Default target ring fill for the adaptive read, and the deadband inside
    /// which it does not trim. These MUST be sized against the PRODUCER'S
    /// BURST, not against the output callback: a producer that writes in
    /// blocks of B frames makes the fill sawtooth ~+/-B/2 around whatever
    /// average the adaptive loop pins, so a target BELOW that swing drags the
    /// sawtooth's floor through zero and the monitor clicks on every burst
    /// cycle -- measured on the Meter 2026-08-31, on all stations, while the
    /// air was clean. Callers pass a target sized for their own block size.
    public static let defaultTargetFrames = 12288
    public static let defaultDeadbandFrames = 3072

    private let engine = AVAudioEngine()
    private let ring: StereoInputRingBuffer
    private let sampleRate: Double
    private let targetFrames: Int
    private let deadbandFrames: Int
    /// Constant playback gain applied in the render block. Studio leaves this
    /// at 1 and applies its (live) monitor level producer-side instead, where
    /// it can also clamp; the Meter sets it once at start.
    private let gain: Float
    private var sourceNode: AVAudioSourceNode?
    private var started = false

    public init(
        ring: StereoInputRingBuffer,
        sampleRate: Double,
        targetFrames: Int = RingBufferPlayer.defaultTargetFrames,
        deadbandFrames: Int = RingBufferPlayer.defaultDeadbandFrames,
        gain: Float = 1.0
    ) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.targetFrames = max(256, targetFrames)
        self.deadbandFrames = max(64, deadbandFrames)
        self.gain = gain
    }

    public var isRunning: Bool { started }

    /// Start playback. `outputDeviceID == nil` uses the system default output.
    public func start(outputDeviceID: AudioDeviceID?) throws {
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
            throw NSError(domain: "RingBufferPlayer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid monitor format"])
        }

        let ring = self.ring
        let target = self.targetFrames
        let deadband = self.deadbandFrames
        let gain = self.gain
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let n = Int(frameCount)
            guard abl.count >= 2,
                  let lraw = abl[0].mData,
                  let rraw = abl[1].mData else { return noErr }
            let lp = lraw.assumingMemoryBound(to: Float.self)
            let rp = rraw.assumingMemoryBound(to: Float.self)
            // Adaptive read, not a plain one: the producer's clock is
            // independent of this output device's clock, so consuming exactly
            // `n` frames per callback lets the buffered amount drift until it
            // underruns (a click every few minutes) or saturates.
            // `readAdaptive` micro-resamples to hold the target fill, the same
            // mechanism the encoder's input path uses. Underflow pads silence.
            _ = ring.readAdaptive(
                intoLeft: lp, outRight: rp, frameCount: n,
                nominalConsume: n,
                targetBuffered: max(n * 2, target),
                deadband: max(n / 2, deadband))
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

    public func stop() {
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
#endif
