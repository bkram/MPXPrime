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
    /// Right-side landing buffer for a mono pair on the multichannel path;
    /// nil on the stereo path. Owned here so the render block stays
    /// allocation-free; freed in `stop()` after the node is detached.
    private var monoScratch: UnsafeMutablePointer<Float>?

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

    /// The device channels the monitor actually plays on (zero-based),
    /// set by `start`; nil before the first start.
    public private(set) var appliedChannels: ChannelPair?
    /// Why `appliedChannels` differs from what was requested, or nil.
    public private(set) var channelNote: String?

    /// Start playback. `outputDeviceID == nil` uses the system default output.
    ///
    /// `channels` picks which device channels carry left and right (a mono
    /// pair gets the L+R downmix on one channel); nil is channels 1 and 2.
    /// On a device with one or two channels, or with the default pair, the
    /// node runs the 2-channel path exactly as it always has. On a wider
    /// device with another pair, the node's format has the device's channel
    /// count and the render block writes only the chosen buffers, zeroing
    /// the rest.
    public func start(outputDeviceID: AudioDeviceID?, channels: ChannelPair? = nil) throws {
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

        // The device's channel count, read AFTER the device is set so a
        // requested pair resolves against the real hardware.
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        let hardwareChannels = Int(hardwareFormat.channelCount)
        let resolved = ChannelPair.resolve(
            requested: channels, channelCount: hardwareChannels, role: "Monitor")
        appliedChannels = resolved.pair
        channelNote = resolved.note

        if hardwareChannels <= 2 || resolved.pair == .stereoDefault {
            try startStereo()
        } else {
            try startMultichannel(
                hardwareChannels: hardwareChannels, hardwareRate: hardwareFormat.sampleRate,
                pair: resolved.pair)
        }
    }

    /// The original 2-channel path, byte for byte: a stereo source node into
    /// the main mixer, which AVAudioEngine maps onto the device's first pair.
    private func startStereo() throws {
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

    /// A wider device with a pair other than 1, 2: the source node speaks
    /// the device's full channel count (discrete, in order, so the mixer
    /// passes channels through 1:1 instead of matrixing by layout) and the
    /// render block fills only the chosen buffers.
    private func startMultichannel(
        hardwareChannels: Int, hardwareRate: Double, pair: ChannelPair
    ) throws {
        guard let layout = AVAudioChannelLayout(
                  layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(hardwareChannels)) else {
            throw NSError(domain: "RingBufferPlayer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "invalid monitor channel layout"])
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        // The mixer does the rate conversion (as on the stereo path, where
        // AVAudioEngine's implicit mixer-to-output link is at the device rate).
        let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: hardwareRate > 0 ? hardwareRate : sampleRate,
            channelLayout: layout)

        let ring = self.ring
        let target = self.targetFrames
        let deadband = self.deadbandFrames
        let gain = self.gain
        let left = pair.left
        let right = pair.right
        let mono = pair.isMono
        // A mono pair needs somewhere to read the other side into; sized for
        // the engine's maximum slice so the render block never allocates.
        let scratchFrames = 8192
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)
        scratch.initialize(repeating: 0, count: scratchFrames)
        monoScratch = scratch
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let n = Int(frameCount)
            let bytes = n * MemoryLayout<Float>.size
            // Everything not chosen is silence; so is everything when the
            // list is narrower than the pair (a device format change under
            // a running engine) or the slice is wider than the scratch.
            for i in 0..<abl.count {
                if let raw = abl[i].mData {
                    memset(raw, 0, min(bytes, Int(abl[i].mDataByteSize)))
                }
            }
            guard abl.count > max(left, right), n <= scratchFrames,
                  let lraw = abl[left].mData,
                  let rraw = abl[right].mData else { return noErr }
            let lp = lraw.assumingMemoryBound(to: Float.self)
            let rp = mono ? scratch : rraw.assumingMemoryBound(to: Float.self)
            _ = ring.readAdaptive(
                intoLeft: lp, outRight: rp, frameCount: n,
                nominalConsume: n,
                targetBuffered: max(n * 2, target),
                deadband: max(n / 2, deadband))
            if mono {
                // One channel carries both sides: (L + R) / 2.
                vDSP_vadd(lp, 1, rp, 1, lp, 1, vDSP_Length(n))
                var half: Float = 0.5
                vDSP_vsmul(lp, 1, &half, lp, 1, vDSP_Length(n))
            }
            if gain != 1.0 {
                var g = gain
                vDSP_vsmul(lp, 1, &g, lp, 1, vDSP_Length(n))
                if !mono {
                    vDSP_vsmul(rp, 1, &g, rp, 1, vDSP_Length(n))
                }
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
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
        if let scratch = monoScratch {
            scratch.deallocate()
            monoScratch = nil
        }
    }

    deinit {
        stop()
    }
}
#endif
