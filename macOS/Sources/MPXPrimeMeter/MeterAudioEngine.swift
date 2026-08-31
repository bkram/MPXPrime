import Atomics
import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore
import MPXPrimeRecording

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
    /// Callers constructing an `AUHALInputSource` must pass this as its
    /// `maxFramesPerSlice` -- the `.mix` scratch is sized from it, and a larger
    /// AUHAL slice would silently truncate frames.
    static let maxSliceFrames = 4096

    /// The capture rate could not support composite measurement.
    struct UnsupportedRateError: LocalizedError {
        let rate: Double
        var errorDescription: String? {
            String(format: "capture rate %.0f Hz is too low for composite measurement "
                   + "(needs >= 128 kHz: the measurement band is 0-60 kHz and RDS sits at 57 kHz) "
                   + "-- set the device to 192 kHz in Audio MIDI Setup", rate)
        }
    }

    private let input: MPXInputSource
    private let ring: StereoInputRingBuffer
    // Rebuilt in start() when the device's ACTUAL rate differs from the
    // predicted one -- see start().
    private var analysis: MeterAnalysis
    private let blockFrames: Int
    private let channel: MeterChannel
    private var sampleRate: Float
    // Calibration the analyzer was built with, kept so a rate rebuild
    // preserves it.
    private let initialPilotRefKHz: Float
    private let initialFullScaleKHz: Float?
    // Pre-allocated scratch for the .mix sum so the capture-thread sink never
    // allocates.
    private let mixScratch: UnsafeMutablePointer<Float>
    private let mixScratchCap: Int

    // Monitor (decoded-audio playback). nil when monitoring is disabled.
    private let monitorEnabled: Bool
    private let monitorGain: Float
    private let monitorRing: StereoInputRingBuffer
    // MPX pass-through: the RAW composite duplicated to both channels of its
    // own ring, played to a user-chosen output device (e.g. a 192 kHz DAC
    // feeding an exciter or a hardware analyzer). Independent of the decoded
    // monitor. The flag is read on the analysis thread.
    private let mpxRing: StereoInputRingBuffer
    private var mpxMonitor: MeterMonitor?
    private let mpxPassOn = ManagedAtomic<Bool>(false)
    private var mpxOutDeviceID: AudioDeviceID?
    private var mpxOutPriorRate: Double?
    private var monitor: MeterMonitor?

    // WAV capture. `wavURL` is the CLI's record-on-start path (decoded stereo);
    // the GUI starts/stops dynamically via startRecording/stopRecording. The
    // recorder is touched by the analysis thread (writes) and the main thread
    // (start/stop), so guard it with recordLock.
    private let wavURL: URL?
    private let recordLock = NSLock()
    private var recorder: MeterRecorder?
    private var recordMPX = false

    // Uptime nanoseconds of the last non-empty frame delivery from the input
    // (capture thread). 0 = nothing delivered yet. The liveness watchdog: a
    // wedged device (USB power-save, SDR stream stall) keeps `isRunning` true
    // while delivering nothing, and the panel would show frozen readings that
    // look live.
    private let lastDeliveryNS = ManagedAtomic<UInt64>(0)

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
        preemphasisUS: Int = 50,
        wavURL: URL? = nil,
        input: MPXInputSource
    ) {
        self.input = input
        self.ring = StereoInputRingBuffer(capacityFrames: 1 << 16)
        self.analysis = MeterAnalysis(
            sampleRate: sampleRate, preemphasisUS: preemphasisUS,
            pilotRefKHz: pilotRefKHz, fullScaleKHz: fullScaleKHz)
        self.blockFrames = 8192
        self.channel = channel
        self.sampleRate = sampleRate
        self.initialPilotRefKHz = pilotRefKHz
        self.initialFullScaleKHz = fullScaleKHz
        self.mixScratchCap = Self.maxSliceFrames
        self.mixScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxSliceFrames)
        self.mixScratch.initialize(repeating: 0.0, count: Self.maxSliceFrames)
        self.monitorEnabled = monitorEnabled
        self.monitorGain = monitorGain
        self.monitorRing = StereoInputRingBuffer(capacityFrames: 1 << 15)
        self.mpxRing = StereoInputRingBuffer(capacityFrames: 1 << 15)
        self.wavURL = wavURL
    }

    deinit {
        // Stop the input BEFORE freeing the scratch buffer the frame sink
        // writes into. An engine released without an explicit stop() (an early
        // return on a start failure, a view model replacing it) otherwise let
        // the still-running capture callback write into freed memory (audit
        // B9). `stop()` is idempotent, and both it and `input.stop()` are safe
        // to call on an engine that never started.
        if runningFlag.load(ordering: .relaxed) {
            stop()
        } else {
            input.stop()
        }
        mixScratch.deinitialize(count: mixScratchCap)
        mixScratch.deallocate()
    }

    /// Live-update the pilot reference (kHz) for the pilot-referenced audio path.
    func setPilotRefKHz(_ k: Float) { analysis.setPilotRefKHz(k) }

    /// Decode-path DC blocker (live).
    func setDCBlock(_ on: Bool) { analysis.setDCBlock(on) }

    /// Receiver de-emphasis time constant in us (50 = Region 1, 75 = the
    /// Americas / Japan / Korea). Live; only reconfigures on a real change.
    func setPreemphasisUS(_ us: Int) { analysis.setPreemphasisUS(us) }

    /// Bypass the RDS reception-quality gate (live).
    func setForceRDS(_ on: Bool) { analysis.setForceRDS(on) }

    /// Live-switch the audio path between absolute ("0 dBFS = k kHz") and
    /// pilot-referenced (nil) deviation scaling.
    func setFullScaleKHz(_ k: Float?) { analysis.setFullScaleKHz(k) }

    @discardableResult
    func start(monitorDeviceID: AudioDeviceID? = nil) throws -> (sampleRate: Double, channels: Int) {
        let ring = self.ring
        let channel = self.channel
        let scratch = self.mixScratch
        let scratchCap = self.mixScratchCap
        let lastDeliveryNS = self.lastDeliveryNS
        // Back-pressure for sources that can wait (the stdin/file replay path):
        // hold off once the ring is more than half full, so a file read cannot
        // overwrite samples the analysis thread has not consumed. Real-time
        // sources ignore this.
        let backPressureLimit = ring.capacityFrames / 2
        input.canAcceptFrames = { [weak ring] in
            guard let ring else { return true }
            return ring.bufferedFrames() < backPressureLimit
        }
        input.frameSink = { left, right, frames in
            if frames > 0 {
                lastDeliveryNS.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
            }
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

        // The analyzer (and everything downstream: monitor, recorder, WAV
        // header) must run at the rate the device ACTUALLY opened at, not the
        // one predicted before opening -- prepareInputRate's 1.5 s
        // setNominalSampleRate timeout can fire on a slow USB rate switch and
        // the device then finishes switching after AUHAL opens. Before 0.45
        // the analyzer kept the predicted rate: 48 kHz math on a 192 kHz
        // stream (pilot PLL, RDS mixer, FIR, spectrum axis all 4x off) while
        // the GUI displayed the correct rate it wasn't using.
        if fmt.sampleRate < 128_000 {
            input.stop()
            throw UnsupportedRateError(rate: fmt.sampleRate)
        }
        if abs(fmt.sampleRate - Double(sampleRate)) > 0.5 {
            sampleRate = Float(fmt.sampleRate)
            analysis = MeterAnalysis(
                sampleRate: sampleRate, preemphasisUS: analysis.preemphasisUS,
                pilotRefKHz: initialPilotRefKHz,
                fullScaleKHz: initialFullScaleKHz)
        }

        if monitorEnabled {
            let mon = MeterMonitor(ring: monitorRing, sampleRate: Double(sampleRate), gain: monitorGain)
            try mon.start(outputDeviceID: monitorDeviceID)
            monitor = mon
        }

        if let wavURL {
            recorder = try MeterRecorder(url: wavURL, sampleRate: Double(sampleRate), channels: 2)
        }

        runningFlag.store(true, ordering: .relaxed)
        let t = Thread { [weak self] in self?.consumeLoop() }
        t.name = "com.mpxprime.meter.analysis"
        t.qualityOfService = .userInitiated
        t.start()
        consumer = t
        return fmt
    }

    func stop(forTermination: Bool = false) {
        runningFlag.store(false, ordering: .relaxed)
        if forTermination, let sdr = input as? SDRLibraryInputSource {
            sdr.stopForTermination()
        } else {
            input.stop()
        }
        // Wait for the consumer thread to actually exit before tearing down
        // the monitor/recorder it touches -- a bare sleep races (TSan-flagged);
        // the semaphore is a real happens-before handshake.
        _ = consumerDone.wait(timeout: .now() + 1.0)
        consumer = nil
        // Report input-ring drops: a non-zero overflow count means the analysis
        // thread fell behind the real-time capture and the ring overwrote unread
        // samples -- the gap shows up as clicks (especially while recording).
        let st = ring.stats()
        if st.overflows > 0 || st.underflows > 0 {
            FileHandle.standardError.write(Data(
                "[Meter] input ring: overflows=\(st.overflows) underflows=\(st.underflows)\n".utf8))
        }
        monitor?.stop()
        monitor = nil
        mpxPassOn.store(false, ordering: .relaxed)
        mpxMonitor?.stop()
        mpxMonitor = nil
        if let dev = mpxOutDeviceID, let prior = mpxOutPriorRate {
            _ = AudioDevices.setNominalSampleRate(deviceID: dev, prior)
        }
        mpxOutDeviceID = nil
        mpxOutPriorRate = nil
        // Release the recorder so AVAudioFile finalizes the WAV header. The
        // consumer thread has exited (handshake above), so no lock is needed,
        // but take it for consistency with the dynamic start/stop path.
        recordLock.lock(); recorder = nil; recordLock.unlock()
    }

    /// Enable/disable the MPX pass-through or move it to another device,
    /// live: capture, analysis, decoded monitor, and recording are untouched.
    /// The composite needs the device at the capture rate (192 kHz -- a 48 kHz
    /// device would low-pass away the pilot/subcarriers in SRC), so the
    /// device's nominal rate is forced to the capture rate and restored when
    /// the pass-through stops (the Studio MPX-output convention).
    /// Returns a human-readable reason when the pass-through could not start
    /// (audit C12: it used to fail silently with the toggle still lit).
    @discardableResult
    func setMPXPassThrough(enabled: Bool, deviceID: AudioDeviceID?,
                           gainDB: Double = 0) -> String? {
        // Tear down the current player + restore the prior device rate.
        mpxPassOn.store(false, ordering: .relaxed)
        mpxMonitor?.stop()
        mpxMonitor = nil
        if let dev = mpxOutDeviceID, let prior = mpxOutPriorRate {
            _ = AudioDevices.setNominalSampleRate(deviceID: dev, prior)
        }
        mpxOutDeviceID = nil
        mpxOutPriorRate = nil
        guard enabled else { return nil }
        if let dev = deviceID {
            let prior = AudioDevices.currentNominalSampleRate(deviceID: dev)
            let got = AudioDevices.setNominalSampleRate(deviceID: dev, Double(sampleRate))
            if let got, abs(got - Double(sampleRate)) < 1.0 {
                mpxOutPriorRate = prior
            } else {
                FileHandle.standardError.write(Data(
                    "WARNING: MPX pass-through device would not switch to \(Int(sampleRate)) Hz; composite will be band-limited by SRC.\n".utf8))
            }
            mpxOutDeviceID = dev
        }
        // Output gain: 0 dB keeps the SDR scaling (0 dBFS = 150 kHz, so a
        // 75 kHz station peaks at -6 dBFS). Positive gain raises the analog
        // level into an analyzer/exciter -- at +6 dB, deviation above
        // 150/2 = 75 kHz clips the DAC, so keep a little headroom.
        let gain = Float(pow(10.0, gainDB / 20.0))
        let mon = MeterMonitor(ring: mpxRing, sampleRate: Double(sampleRate), gain: gain)
        do {
            try mon.start(outputDeviceID: deviceID)
            mpxMonitor = mon
            mpxPassOn.store(true, ordering: .relaxed)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Swap the monitor output device live: only the monitor restarts; the
    /// input source, ring, analysis thread, recorder -- and the MPX
    /// pass-through, which is an independent player on its own device -- are
    /// untouched. It used to tear the pass-through down here and never restore
    /// it, so changing the monitor device silently killed the composite feed
    /// while its toggle stayed lit (audit B18).
    ///
    /// Returns a human-readable reason when the new device could not be
    /// started, so the caller can say so instead of going quiet (audit C12).
    @discardableResult
    func setMonitorDevice(_ deviceID: AudioDeviceID?) -> String? {
        monitor?.stop()
        monitor = nil
        guard monitorEnabled else { return nil }
        let mon = MeterMonitor(ring: monitorRing, sampleRate: Double(sampleRate), gain: monitorGain)
        do {
            try mon.start(outputDeviceID: deviceID)
            monitor = mon
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func snapshot() -> MeterSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    // MARK: - Recording (dynamic, GUI)

    /// Begin recording to `url`: stereo (decoded L/R) or mono (raw MPX
    /// composite) at the capture sample rate. Replaces any active recording.
    func startRecording(url: URL, mpx: Bool) throws {
        let rec = try MeterRecorder(
            url: url, sampleRate: Double(sampleRate), channels: mpx ? 1 : 2)
        recordLock.lock()
        let replaced = recorder
        recorder = rec
        recordMPX = mpx
        recordLock.unlock()
        finalizeOffThread(replaced)
    }

    /// Stop recording and finalize the WAV header.
    func stopRecording() {
        recordLock.lock()
        let rec = recorder
        recorder = nil
        recordLock.unlock()
        finalizeOffThread(rec)
    }

    /// `finish()` blocks on a full flush of the pending disk queue, and the
    /// analysis thread takes `recordLock` on every block -- finalizing while
    /// holding the lock on the MAIN thread stalled analysis long enough on a
    /// slow disk for the input ring to overflow (the click class this recorder
    /// exists to prevent). Swap out under the lock, finalize detached.
    private func finalizeOffThread(_ rec: MeterRecorder?) {
        guard let rec else { return }
        DispatchQueue.global(qos: .utility).async { rec.finish() }
    }

    var isRecording: Bool {
        recordLock.lock(); defer { recordLock.unlock() }
        return recorder != nil
    }

    /// Non-nil once the active recording has stopped writing (disk error, the
    /// 4 GB WAV limit, misuse). The view model polls this each tick.
    var recordingFailureReason: String? {
        recordLock.lock(); defer { recordLock.unlock() }
        return recorder?.failureReason
    }

    /// Input-ring transport counters (overflows = the analysis thread fell
    /// behind and samples were DROPPED; torn reads = a concurrent-read race
    /// was detected). The view model polls the deltas each tick and raises the
    /// "samples dropped" badge -- a peak-hold instrument must not silently
    /// keep a number it computed across a gap.
    var inputTransport: StereoInputRingBuffer.TransportSnapshot {
        ring.transportSnapshot()
    }

    /// Seconds since the input last delivered frames; nil before the first
    /// delivery. > ~1 s while `running` means the device wedged without
    /// signalling failure.
    var secondsSinceLastDelivery: Double? {
        let ns = lastDeliveryNS.load(ordering: .relaxed)
        guard ns > 0 else { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds &- ns) / 1_000_000_000.0
    }

    /// Reset the deviation peak-hold + best-separation accumulators.
    func resetPeaks() { analysis.requestPeakReset() }

    /// Reset all transient meters + RDS for a retune (new station starts clean).
    func resetForRetune() { analysis.requestFullReset() }

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
                if mpxPassOn.load(ordering: .relaxed) {
                    left.withUnsafeBufferPointer { lp in
                        if let lb = lp.baseAddress {
                            mpxRing.write(left: lb, right: lb, frameCount: got)
                        }
                    }
                }
                recordLock.lock()
                if let rec = recorder {
                    if recordMPX {
                        rec.writeMono(left, count: got)        // raw composite
                    } else {
                        rec.write(left: analysis.decodedL, right: analysis.decodedR, count: count)
                    }
                }
                recordLock.unlock()
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
