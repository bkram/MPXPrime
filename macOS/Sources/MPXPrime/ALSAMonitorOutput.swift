import Foundation
import MPXPrimeCore

/// The monitor's start/stop rules on Linux, where devices are ALSA PCM names
/// rather than CoreAudio ids. Kept platform-independent so the rules are
/// tested on the machine this is developed on; the player below is Linux-only.
///
/// Same intent as `MonitorOutput.decide` on macOS: every rule protects the
/// AIR feed. An empty selection is off, never "default" (the default PCM may
/// be the transmitter); the monitor refuses the transmitter's own device.
enum LinuxMonitorRules {
    enum Decision: Equatable {
        case run(device: String)
        case off(note: String?)
    }

    static func decide(enabled: Bool, monitorDevice: String?, outputDevice: String) -> Decision {
        guard enabled else { return .off(note: nil) }
        guard let dev = monitorDevice?.trimmingCharacters(in: .whitespaces), !dev.isEmpty else {
            return .off(note: "Monitor is on but no monitor device is selected.")
        }
        if dev == outputDevice || (dev == "default" && outputDevice == "default") {
            return .off(note: "The monitor device is the transmitter output; pick a different ALSA device.")
        }
        return .run(device: dev)
    }
}

#if os(Linux)
import Atomics
import CAlsa

/// The second output on Linux: plays the conditioned monitor feed from a ring
/// on its own ALSA device and its own thread, alongside the transmitter feed
/// -- the counterpart of the macOS `MonitorOutput` + `RingBufferPlayer`.
///
/// Producer is the render thread (one `write` per period); consumer is this
/// thread, draining with `readAdaptive` because the two PCMs run on different
/// clocks (a USB card and the onboard codec, or snd-aloop). Underflow pads
/// silence; the transmitter engine never learns the monitor exists.
///
/// Unlike the macOS engine, ALL monitor DSP runs HERE, not on the render
/// thread: the render thread copies the raw feed into the ring and nothing
/// else. Measured on the rig (Celeron J4105, 192 kHz, full chain): the render
/// thread already takes 95% of its core; decoding the composite alongside it
/// cost 34 xruns per 20 s, moving the decode here cost none. So the composite
/// is demodulated by a standalone `MPXDecoder` on its own PLL (the receiver
/// model the verifier uses) and the audio modes are de-emphasised by the
/// same `MonitorConditioner` the macOS monitor uses.
final class ALSAMonitorOutput: @unchecked Sendable {
    private var pcm: ALSAPCM?
    private var thread: Thread?
    private let running = ManagedAtomic<Bool>(false)
    private var ring: StereoInputRingBuffer?
    private var sampleRate = 48_000
    private var targetFrames = 12_288
    private var deadbandFrames = 3_072
    private var left: [Float] = []
    private var right: [Float] = []
    private var conditioner = MonitorConditioner()
    private var decoder = MPXDecoder()
    private var decodeComposite = false
    private var preemphasisUS = 50

    /// Read by the render thread once per period to decide whether to write.
    let active = ManagedAtomic<Bool>(false)
    private(set) var note: String?
    private(set) var runningDevice: String?

    var isRunning: Bool { active.load(ordering: .relaxed) }

    /// Allocate the ring for a run, sized against the PRODUCER's period, and
    /// set up what this thread does to the feed: `.decodedComposite` means
    /// the ring carries the composite and the decoder runs here.
    func prepare(
        sampleRate: Int, periodFrames: Int,
        shape: MonitorConditioner.Shape, preemphasisUS: Int, gainDB: Double
    ) -> StereoInputRingBuffer {
        let target = max(4 * periodFrames, Int(Double(sampleRate) * 0.04))
        let capacity = 1 << Int(ceil(log2(Double(max(1024, 4 * target)))))
        let ring = StereoInputRingBuffer(capacityFrames: capacity)
        self.ring = ring
        self.sampleRate = sampleRate
        self.targetFrames = target
        self.deadbandFrames = max(64, periodFrames)
        self.preemphasisUS = preemphasisUS
        decodeComposite = shape == .decodedComposite
        conditioner.configure(shape: shape, sampleRate: Float(sampleRate), gainDB: gainDB)
        conditioner.reset()
        return ring
    }

    /// Level only; a plain Float write the loop picks up on its next period.
    func setGain(dB: Double) {
        conditioner.gainLinear = powf(10.0, Float(dB) / 20.0)
    }

    /// Bring the monitor in line with the selection. Never throws into the
    /// caller: a monitor that cannot run is a note.
    func reconcile(enabled: Bool, monitorDevice: String?, outputDevice: String) {
        switch LinuxMonitorRules.decide(enabled: enabled, monitorDevice: monitorDevice, outputDevice: outputDevice) {
        case .off(let why):
            note = why
            stop()
        case .run(let device):
            note = nil
            if isRunning, runningDevice == device { return }
            stop()
            start(device: device)
        }
    }

    private func start(device: String) {
        guard let ring else {
            note = "The monitor could not start: the engine is not running."
            return
        }
        do {
            let out = try ALSAPCM(
                device: device, stream: SND_PCM_STREAM_PLAYBACK, rate: sampleRate,
                wantChannels: 2, wantPeriod: max(256, deadbandFrames), wantPeriods: 8)
            pcm = out
            left = [Float](repeating: 0, count: out.periodFrames)
            right = [Float](repeating: 0, count: out.periodFrames)
        } catch {
            note = "The monitor device could not be opened: \(String(describing: error))"
            pcm = nil
            return
        }
        ring.dropToTargetBufferedFrames(0)
        // Fresh decoder state per run: the PLL re-acquires in well under a
        // second, and stale lock from a previous device would decode garbage.
        decoder.configure(sampleRate: Float(sampleRate), preemphasisUS: preemphasisUS)
        conditioner.reset()
        runningDevice = device
        running.store(true, ordering: .releasing)
        active.store(true, ordering: .relaxed)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "alsa-monitor"
        t.stackSize = 1 << 20
        thread = t
        t.start()
        FileHandle.standardError.write(Data("[ALSA] monitor '\(device)' playing\n".utf8))
    }

    func stop() {
        active.store(false, ordering: .relaxed)
        running.store(false, ordering: .releasing)
        let deadline = Date().addingTimeInterval(2.0)
        while thread?.isFinished == false, Date() < deadline { usleep(10_000) }
        // `ALSAPCM.close()` is idempotent and its deinit calls it too; closing
        // the raw handle here as well was a double close (SIGABRT, measured).
        pcm?.close()
        pcm = nil
        thread = nil
        runningDevice = nil
    }

    func shutdown() {
        stop()
        ring = nil
        note = nil
    }

    private func loop() {
        guard let out = pcm, let ring else { return }
        let frames = out.periodFrames
        let ch = out.channels
        while running.load(ordering: .acquiring) {
            left.withUnsafeMutableBufferPointer { lb in
                right.withUnsafeMutableBufferPointer { rb in
                    guard let l = lb.baseAddress, let r = rb.baseAddress else { return }
                    _ = ring.readAdaptive(
                        intoLeft: l, outRight: r, frameCount: frames,
                        nominalConsume: frames,
                        targetBuffered: max(frames * 2, targetFrames),
                        deadband: max(frames / 2, deadbandFrames))
                    if decodeComposite {
                        // Composite in (both channels carry it), stereo out.
                        // The activity hint is the composite's own envelope;
                        // no side-channel expectation without the encoder.
                        for i in 0..<frames {
                            let mpx = l[i]
                            let decoded = decoder.process(
                                mpx, referenceSubcarrier: nil,
                                programActivity: fabsf(mpx), expectedSide: 0.0)
                            l[i] = decoded.0
                            r[i] = decoded.1
                        }
                    }
                    conditioner.process(left: l, right: r, frameCount: frames)
                }
            }
            @inline(__always) func clamp(_ v: Float) -> Float { max(-1.0, min(1.0, v)) }
            switch out.format {
            case SND_PCM_FORMAT_FLOAT_LE:
                for i in 0..<frames {
                    out.floatBuf[ch * i] = clamp(left[i])
                    if ch == 2 { out.floatBuf[2 * i + 1] = clamp(right[i]) }
                }
                if !write(out, out.floatBuf, frames) { return }
            case SND_PCM_FORMAT_S32_LE:
                let scale: Double = 2_147_483_520.0
                for i in 0..<frames {
                    out.int32Buf[ch * i] = Int32(Double(clamp(left[i])) * scale)
                    if ch == 2 { out.int32Buf[2 * i + 1] = Int32(Double(clamp(right[i])) * scale) }
                }
                if !write(out, out.int32Buf, frames) { return }
            default:
                let scale: Double = 32_767.0
                for i in 0..<frames {
                    out.int16Buf[ch * i] = Int16(Double(clamp(left[i])) * scale)
                    if ch == 2 { out.int16Buf[2 * i + 1] = Int16(Double(clamp(right[i])) * scale) }
                }
                if !write(out, out.int16Buf, frames) { return }
            }
        }
    }

    private func write<T>(_ out: ALSAPCM, _ buf: [T], _ frames: Int) -> Bool {
        var remaining = frames
        var offset = 0
        while remaining > 0, running.load(ordering: .relaxed) {
            let rc = buf.withUnsafeBytes { raw -> snd_pcm_sframes_t in
                // swiftlint:disable:next force_unwrapping
                let base = raw.baseAddress!.advanced(by: offset * out.channels * MemoryLayout<T>.stride)
                return snd_pcm_writei(out.pcm, base, snd_pcm_uframes_t(remaining))
            }
            if rc < 0 {
                if snd_pcm_recover(out.pcm, Int32(rc), 1) < 0 {
                    note = "The monitor device was lost: \(alsaErrorString(Int32(rc)))"
                    active.store(false, ordering: .relaxed)
                    running.store(false, ordering: .releasing)
                    return false
                }
                continue
            }
            remaining -= Int(rc)
            offset += Int(rc)
        }
        return true
    }
}
#endif
