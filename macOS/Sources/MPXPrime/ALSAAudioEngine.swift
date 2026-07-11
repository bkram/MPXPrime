// Linux CLI audio engine: ALSA capture -> MPXGenerator -> ALSA playback.
//
// This is the Linux counterpart of AudioOutputEngine (which is
// AVFoundation/AUHAL and macOS-only). It follows the same structure and the
// same real-time discipline -- lock-free, allocation-free after start() --
// but only the surface the headless runtime needs: no metering, no live
// apply, no monitor path (the INI is read once at startup).
//
//   capture thread:  snd_pcm_readi -> deinterleave/convert -> ring.write
//   render thread:   ring.readAdaptive -> generator.render* -> interleave ->
//                    snd_pcm_writei (blocking; the device paces the loop)
//
// Device names come from the same INI keys that carry CoreAudio UIDs on
// macOS (input_device_uid / output_device_uid) and are passed verbatim to
// snd_pcm_open: "default", "hw:0,0", "plughw:CARD=Loopback,DEV=0", ...
// Empty means "default". The requested rate is the configured sample_rate,
// set exactly: a hw: device that cannot do it fails start() with a clear
// error (use plughw:/default to let alsa-lib convert, at SRC cost).
#if os(Linux)

import Atomics
import CAlsa
import Foundation
import Glibc
import MPXPrimeAcceleration   // OSAllocatedUnfairLock polyfill
import MPXPrimeCore
import MPXPrimeNative

#if !canImport(Darwin)
// Glibc imports C's `stderr` as a mutable global, which Swift 6 strict
// concurrency rejects at use sites. Rebind file-locally to a fresh
// unbuffered FILE* on fd 2 (identical behavior: stderr is unbuffered).
nonisolated(unsafe) private let stderr: UnsafeMutablePointer<FILE> = {
    guard let f = fdopen(2, "w") else { fatalError("fdopen(2) failed") }
    setvbuf(f, nil, _IONBF, 0)
    return f
}()
#endif

// Mirror of the macOS AudioOutputEngine's mode enum (that file is not
// compiled on Linux). Only .mpxComposite and .processedAudio are reachable
// from the CLI; .monitorAudio exists for signature parity.
enum AudioOutputMode {
    case mpxComposite
    case monitorAudio
    case processedAudio
}

enum ALSAEngineError: Error, CustomStringConvertible {
    case openFailed(device: String, code: Int32)
    case configureFailed(device: String, what: String, code: Int32)
    case rateUnsupported(device: String, rate: Int)

    var description: String {
        switch self {
        case .openFailed(let device, let code):
            return "ALSA open failed for '\(device)': \(alsaErrorString(code))"
        case .configureFailed(let device, let what, let code):
            return "ALSA configure failed for '\(device)' (\(what)): \(alsaErrorString(code))"
        case .rateUnsupported(let device, let rate):
            return "'\(device)' does not support \(rate) Hz natively. "
                + "Use a plug device (\"default\" or \"plughw:...\") to let "
                + "alsa-lib convert, or set sample_rate to a rate the "
                + "hardware supports."
        }
    }
}

private func alsaErrorString(_ code: Int32) -> String {
    guard let c = snd_strerror(code) else { return "error \(code)" }
    return String(cString: c)
}

/// One configured PCM direction: the device handle plus its negotiated
/// format and preallocated interleave/convert buffers.
private final class ALSAPCM {
    let pcm: OpaquePointer
    let device: String
    let format: snd_pcm_format_t
    let channels: Int
    let periodFrames: Int
    let bufferFrames: Int
    // Preallocated interleaved staging (sized for periodFrames * channels).
    var floatBuf: [Float]
    var int32Buf: [Int32]
    var int16Buf: [Int16]

    init(
        device: String, stream: snd_pcm_stream_t, rate: Int,
        wantChannels: Int, wantPeriod: Int, wantPeriods: Int
    ) throws {
        self.device = device
        var handle: OpaquePointer?
        let rcOpen = snd_pcm_open(&handle, device, stream, 0)
        guard rcOpen >= 0, let opened = handle else {
            throw ALSAEngineError.openFailed(device: device, code: rcOpen)
        }

        var params: OpaquePointer?
        snd_pcm_hw_params_malloc(&params)
        defer { snd_pcm_hw_params_free(params) }
        snd_pcm_hw_params_any(opened, params)

        var rc = snd_pcm_hw_params_set_access(
            opened, params, SND_PCM_ACCESS_RW_INTERLEAVED)
        guard rc >= 0 else {
            snd_pcm_close(opened)
            throw ALSAEngineError.configureFailed(
                device: device, what: "interleaved access", code: rc)
        }

        // Format preference: native float, then 32-bit, then 16-bit PCM.
        var chosen = SND_PCM_FORMAT_FLOAT_LE
        if snd_pcm_hw_params_set_format(opened, params, SND_PCM_FORMAT_FLOAT_LE) < 0 {
            if snd_pcm_hw_params_set_format(opened, params, SND_PCM_FORMAT_S32_LE) >= 0 {
                chosen = SND_PCM_FORMAT_S32_LE
            } else {
                rc = snd_pcm_hw_params_set_format(opened, params, SND_PCM_FORMAT_S16_LE)
                guard rc >= 0 else {
                    snd_pcm_close(opened)
                    throw ALSAEngineError.configureFailed(
                        device: device, what: "sample format", code: rc)
                }
                chosen = SND_PCM_FORMAT_S16_LE
            }
        }
        self.format = chosen

        var ch = wantChannels
        if snd_pcm_hw_params_set_channels(opened, params, UInt32(ch)) < 0 {
            ch = wantChannels == 2 ? 1 : 2
            rc = snd_pcm_hw_params_set_channels(opened, params, UInt32(ch))
            guard rc >= 0 else {
                snd_pcm_close(opened)
                throw ALSAEngineError.configureFailed(
                    device: device, what: "channel count", code: rc)
            }
        }
        self.channels = ch

        // Exact rate -- no silent hardware resampling on hw: devices.
        rc = snd_pcm_hw_params_set_rate(opened, params, UInt32(rate), 0)
        guard rc >= 0 else {
            snd_pcm_close(opened)
            throw ALSAEngineError.rateUnsupported(device: device, rate: rate)
        }

        var period = snd_pcm_uframes_t(wantPeriod)
        var dir: Int32 = 0
        snd_pcm_hw_params_set_period_size_near(opened, params, &period, &dir)
        var buffer = snd_pcm_uframes_t(Int(period) * wantPeriods)
        snd_pcm_hw_params_set_buffer_size_near(opened, params, &buffer)

        rc = snd_pcm_hw_params(opened, params)
        guard rc >= 0 else {
            snd_pcm_close(opened)
            throw ALSAEngineError.configureFailed(
                device: device, what: "hw params commit", code: rc)
        }

        var actualPeriod: snd_pcm_uframes_t = 0
        var actualBuffer: snd_pcm_uframes_t = 0
        snd_pcm_hw_params_get_period_size(params, &actualPeriod, &dir)
        snd_pcm_hw_params_get_buffer_size(params, &actualBuffer)
        self.periodFrames = Int(actualPeriod)
        self.bufferFrames = Int(actualBuffer)

        let slots = self.periodFrames * ch
        self.floatBuf = [Float](repeating: 0, count: slots)
        self.int32Buf = [Int32](repeating: 0, count: slots)
        self.int16Buf = [Int16](repeating: 0, count: slots)
        self.pcm = opened

        snd_pcm_prepare(opened)
    }

    func close() {
        snd_pcm_drop(pcm)
        snd_pcm_close(pcm)
    }

    var formatName: String {
        switch format {
        case SND_PCM_FORMAT_FLOAT_LE: return "FLOAT_LE"
        case SND_PCM_FORMAT_S32_LE: return "S32_LE"
        default: return "S16_LE"
        }
    }
}

/// Best-effort SCHED_FIFO for the audio threads. Needs an rtprio rlimit
/// (ulimit -r / limits.d); silently degrades to the default scheduler --
/// the xrun counters make starvation visible either way.
private func applyRealtimeThreadPriority(_ priority: Int32) {
    var param = sched_param()
    param.sched_priority = priority
    _ = pthread_setschedparam(pthread_self(), SCHED_FIFO, &param)
}

final class ALSAAudioEngine: @unchecked Sendable {
    private let generator: MPXGenerator
    private let outputMode: AudioOutputMode
    private let sampleRate: Double
    // Mutable: applyRuntimeConfig can flip tone<->input live when the
    // capture PCM was opened at start (render thread reads it per period).
    private var useInputSource: Bool
    private let inputDeviceName: String
    private let outputDeviceName: String

    private var output: ALSAPCM?
    private var input: ALSAPCM?
    private var inputRing: StereoInputRingBuffer?
    private var renderThread: Thread?
    private var captureThread: Thread?
    private let running = ManagedAtomic<Bool>(false)
    private let renderXruns = ManagedAtomic<Int>(0)
    private let captureXruns = ManagedAtomic<Int>(0)

    // Live-apply hand-off, mirroring AudioOutputEngine: any thread produces
    // a pending runtime struct under the lock; the render thread consumes it
    // at the top of each period with a try-lock (never blocks).
    private let runtimeConfigLock = OSAllocatedUnfairLock()
    private var pendingRuntimeConfig: MPXGenerator.RuntimeConfig?
    private var lastQueuedRuntimeConfig: MPXGenerator.RuntimeConfig?
    private var pendingRDSRuntimeConfig: MPXGenerator.RDSRuntimeConfig?
    private var lastQueuedRDSRuntimeConfig: MPXGenerator.RDSRuntimeConfig?
    private let runtimeConfigPending = ManagedAtomic<Bool>(false)
    private let rdsRuntimeConfigPending = ManagedAtomic<Bool>(false)

    // Minimal meters (milestone 1): per-period peaks published for the
    // remote API. Written by the audio threads, read at a few Hz.
    private let meterLock = OSAllocatedUnfairLock()
    private var meterInputLeftPeak: Float = 0
    private var meterInputRightPeak: Float = 0
    private var meterOutputPeak: Float = 0

    /// Line output calibration (dBFS at 100% modulation -> linear), applied
    /// during the interleave/convert step after peak metering. Render-thread
    /// only after start; updated via the pending-config hand-off.
    private var lineOutputScale: Float

    // Ring prime/regulate depths (same policy as the macOS engine, derived
    // from the period size at start()).
    private var inputPrefillFrames = 0
    private var inputPrimeThresholdFrames = 0
    private var inputTargetBufferedFrames = 0
    private var inputBufferedDeadbandFrames = 0
    private var inputPrimed = false

    // Non-interleaved render scratch (periodFrames each), allocated at start.
    private var renderLeft: [Float] = []
    private var renderRight: [Float] = []
    private var captureLeft: [Float] = []
    private var captureRight: [Float] = []

    var renderSampleRate: Double { sampleRate }

    init(generator: MPXGenerator, config: AppConfig, outputMode: AudioOutputMode) {
        precondition(outputMode != .monitorAudio, "monitor path is macOS-only")
        self.generator = generator
        self.outputMode = outputMode
        self.sampleRate = config.sampleRate
        self.useInputSource = config.sourceMode.lowercased() == "input"
        self.lineOutputScale = powf(10.0, Float(config.mpxLineOutputDBFS) / 20.0)
        let inputUID = config.inputDeviceUID ?? ""
        let outputUID = config.outputDeviceUID ?? ""
        self.inputDeviceName = inputUID.isEmpty ? "default" : inputUID
        self.outputDeviceName = outputUID.isEmpty ? "default" : outputUID
    }

    func start() throws {
        let rate = Int(sampleRate)
        // Deep buffers by design: this is a transmitter, not an interactive
        // path -- latency is irrelevant, underruns are on-air dropouts. Raw
        // hw: devices grant the request exactly (a 512x4 request = 10.7 ms
        // at 192k, which xrun-stormed on a 92%-loaded small CPU without RT
        // scheduling); 2048x8 = ~85 ms of scheduling slack.
        let out = try ALSAPCM(
            device: outputDeviceName, stream: SND_PCM_STREAM_PLAYBACK,
            rate: rate, wantChannels: 2, wantPeriod: 2048, wantPeriods: 8)
        output = out
        fputs(
            "[ALSA] output '\(out.device)': \(out.formatName) \(out.channels)ch "
                + "\(rate) Hz, period \(out.periodFrames), buffer \(out.bufferFrames)\n",
            stderr)
        if out.device.hasPrefix("plughw") || out.device == "default" {
            fputs(
                "[ALSA] note: plug-layer device; alsa-lib may sample-rate-convert "
                    + "if the hardware cannot do \(rate) Hz natively\n", stderr)
        }

        renderLeft = [Float](repeating: 0, count: out.periodFrames)
        renderRight = [Float](repeating: 0, count: out.periodFrames)

        if useInputSource {
            let inp = try ALSAPCM(
                device: inputDeviceName, stream: SND_PCM_STREAM_CAPTURE,
                rate: rate, wantChannels: 2, wantPeriod: 2048, wantPeriods: 8)
            input = inp
            fputs(
                "[ALSA] input '\(inp.device)': \(inp.formatName) \(inp.channels)ch "
                    + "\(rate) Hz, period \(inp.periodFrames), buffer \(inp.bufferFrames)\n",
                stderr)

            captureLeft = [Float](repeating: 0, count: inp.periodFrames)
            captureRight = [Float](repeating: 0, count: inp.periodFrames)

            let ringFrames = max(inp.periodFrames * 128, Int(sampleRate * 1.0))
            inputRing = StereoInputRingBuffer(capacityFrames: ringFrames)
            inputPrefillFrames = max(inp.periodFrames * 12, 4096)
            let timeBasedTargetFloor = Int(sampleRate * 0.100)
            inputTargetBufferedFrames = max(
                inputPrefillFrames * 2,
                inp.periodFrames * 24,
                timeBasedTargetFloor
            )
            inputBufferedDeadbandFrames = max(inp.periodFrames * 4, 1024)
            inputPrimeThresholdFrames = max(
                inputPrefillFrames,
                inputTargetBufferedFrames - inputBufferedDeadbandFrames
            )
        }

        running.store(true, ordering: .releasing)

        if useInputSource {
            let capture = Thread { [weak self] in self?.captureLoop() }
            capture.name = "alsa-capture"
            capture.stackSize = 1 << 20
            captureThread = capture
            capture.start()
        }

        let render = Thread { [weak self] in self?.renderLoop() }
        render.name = "alsa-render"
        render.stackSize = 1 << 20
        renderThread = render
        render.start()
    }

    func stop() {
        running.store(false, ordering: .releasing)
        // The loops exit at their next period boundary; blocking readi/writei
        // return within one period. Spin-wait briefly for both to finish.
        let deadline = Date().addingTimeInterval(2.0)
        while renderThread?.isFinished == false || captureThread?.isFinished == false,
            Date() < deadline {
            usleep(10_000)
        }
        if let out = output {
            snd_pcm_drain(out.pcm)
            out.close()
            output = nil
        }
        if let inp = input {
            inp.close()
            input = nil
        }
        let xr = renderXruns.load(ordering: .relaxed)
        let xc = captureXruns.load(ordering: .relaxed)
        fputs("[ALSA] stopped. xruns: render \(xr), capture \(xc)\n", stderr)
    }

    // MARK: - Live apply + telemetry (remote-control surface)

    /// Thread-safe producer; the render thread applies within ~one period.
    func applyRuntimeConfig(_ config: AppConfig) {
        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        runtimeConfigLock.lock()
        if lastQueuedRuntimeConfig == runtime {
            runtimeConfigLock.unlock()
            return
        }
        pendingRuntimeConfig = runtime
        lastQueuedRuntimeConfig = runtime
        runtimeConfigPending.store(true, ordering: .relaxed)
        runtimeConfigLock.unlock()
    }

    func applyRDSRuntimeConfig(_ config: AppConfig) {
        let runtime = MPXGenerator.RDSRuntimeConfig.make(from: config)
        runtimeConfigLock.lock()
        if lastQueuedRDSRuntimeConfig == runtime {
            runtimeConfigLock.unlock()
            return
        }
        pendingRDSRuntimeConfig = runtime
        lastQueuedRDSRuntimeConfig = runtime
        rdsRuntimeConfigPending.store(true, ordering: .relaxed)
        runtimeConfigLock.unlock()
    }

    var currentRDSLiveSnapshot: BasicRDSCoder.LiveSnapshot? {
        generator.currentRDSLiveSnapshot()
    }

    /// Peaks are per-period (no hold/decay smoothing in milestone 1).
    var peakMeters: (inputL: Float, inputR: Float, output: Float) {
        meterLock.lock()
        defer { meterLock.unlock() }
        return (meterInputLeftPeak, meterInputRightPeak, meterOutputPeak)
    }

    var xrunCounts: (render: Int, capture: Int) {
        (renderXruns.load(ordering: .relaxed), captureXruns.load(ordering: .relaxed))
    }

    /// Render-thread consumer (try-lock; never blocks the period deadline).
    private func applyPendingRuntimeConfigIfNeeded() {
        if runtimeConfigPending.load(ordering: .acquiring),
            runtimeConfigLock.lockIfAvailable() {
            let runtime = pendingRuntimeConfig
            pendingRuntimeConfig = nil
            runtimeConfigPending.store(false, ordering: .relaxed)
            runtimeConfigLock.unlock()
            if let runtime {
                generator.applyRuntimeConfig(runtime)
                if outputMode == .mpxComposite {
                    lineOutputScale = powf(10.0, runtime.mpxLineOutputDBFS / 20.0)
                }
                // Source flip is honoured only when the capture path exists
                // (capture PCM is opened at start; adding one mid-run is a
                // restart-class change on Linux).
                let nextUseInput = runtime.sourceMode.lowercased() == "input"
                if nextUseInput != useInputSource {
                    if input != nil || !nextUseInput {
                        if nextUseInput, let ring = inputRing {
                            ring.dropToTargetBufferedFrames(inputPrimeThresholdFrames)
                            inputPrimed = false
                        }
                        useInputSource = nextUseInput
                    }
                }
            }
        }
        if rdsRuntimeConfigPending.load(ordering: .acquiring),
            runtimeConfigLock.lockIfAvailable() {
            let runtime = pendingRDSRuntimeConfig
            pendingRDSRuntimeConfig = nil
            rdsRuntimeConfigPending.store(false, ordering: .relaxed)
            runtimeConfigLock.unlock()
            if let runtime {
                generator.applyRDSRuntimeConfig(runtime)
            }
        }
    }

    @inline(__always)
    private func publishPeaks(frames: Int) {
        // Output only: renderLeft belongs to this (render) thread. Input
        // peaks are published by the capture thread, which owns its buffers.
        var outPeak: Float = 0
        for i in 0..<frames {
            let m = abs(renderLeft[i])
            if m > outPeak { outPeak = m }
        }
        if meterLock.lockIfAvailable() {
            meterOutputPeak = outPeak
            meterLock.unlock()
        }
    }

    @inline(__always)
    private func publishInputPeaks(frames: Int) {
        var inL: Float = 0
        var inR: Float = 0
        for i in 0..<frames {
            let l = abs(captureLeft[i])
            let r = abs(captureRight[i])
            if l > inL { inL = l }
            if r > inR { inR = r }
        }
        if meterLock.lockIfAvailable() {
            meterInputLeftPeak = inL
            meterInputRightPeak = inR
            meterLock.unlock()
        }
    }

    // MARK: - Render loop (playback pacing)

    private func renderLoop() {
        guard let out = output else { return }
        mpx_enable_flush_to_zero()
        applyRealtimeThreadPriority(70)

        let frames = out.periodFrames
        while running.load(ordering: .acquiring) {
            applyPendingRuntimeConfigIfNeeded()
            renderLeft.withUnsafeMutableBufferPointer { lBuf in
                renderRight.withUnsafeMutableBufferPointer { rBuf in
                    // Preallocated at start() with periodFrames > 0 elements;
                    // baseAddress is non-nil for non-empty buffers.
                    // swiftlint:disable:next force_unwrapping
                    let left = lBuf.baseAddress!
                    // swiftlint:disable:next force_unwrapping
                    let right = rBuf.baseAddress!
                    if useInputSource, let ring = inputRing {
                        if !inputPrimed {
                            if ring.bufferedFrames() < inputPrimeThresholdFrames {
                                for i in 0..<frames {
                                    left[i] = 0
                                    right[i] = 0
                                }
                                renderProcessed(left: left, right: right, frames: frames)
                                return
                            }
                            inputPrimed = true
                            ring.dropToTargetBufferedFrames(inputPrimeThresholdFrames)
                        }
                        let missing = ring.readAdaptive(
                            intoLeft: left,
                            outRight: right,
                            frameCount: frames,
                            nominalConsume: frames,
                            targetBuffered: inputTargetBufferedFrames,
                            deadband: inputBufferedDeadbandFrames
                        )
                        let bufferedAfterRead = ring.bufferedFrames()
                        let rePrimeThreshold = max(
                            inputBufferedDeadbandFrames,
                            min(inputPrefillFrames, inputTargetBufferedFrames / 2)
                        )
                        if missing >= frames
                            || (missing > 0 && bufferedAfterRead <= rePrimeThreshold) {
                            inputPrimed = false
                        }
                        renderProcessed(left: left, right: right, frames: frames)
                    } else {
                        if outputMode == .processedAudio {
                            generator.renderAudioOnlyToneNonInterleaved(
                                frameCount: frames, left: left, right: right)
                        } else {
                            generator.renderNonInterleaved(
                                frameCount: frames, left: left, right: right)
                        }
                    }
                }
            }
            publishPeaks(frames: frames)
            if !writePeriod(out) { break }
        }
    }

    /// Process one primed/read input period through the generator in place.
    private func renderProcessed(
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int
    ) {
        if outputMode == .processedAudio {
            generator.renderAudioOnlyFromInputInPlace(
                frameCount: frames, left: left, right: right)
        } else {
            generator.renderFromInputInPlace(
                frameCount: frames, left: left, right: right)
        }
    }

    /// Interleave/convert the rendered period and write it; snd_pcm_recover
    /// handles xruns. Returns false when the device is unrecoverable.
    private func writePeriod(_ out: ALSAPCM) -> Bool {
        let frames = out.periodFrames
        let ch = out.channels
        // Line output calibration folds into the DAC conversion (peaks were
        // already published in the composite domain).
        let line = outputMode == .mpxComposite ? lineOutputScale : 1.0
        switch out.format {
        case SND_PCM_FORMAT_FLOAT_LE:
            for i in 0..<frames {
                if ch == 2 {
                    out.floatBuf[2 * i] = renderLeft[i] * line
                    out.floatBuf[2 * i + 1] = renderRight[i] * line
                } else {
                    out.floatBuf[i] = renderLeft[i] * line
                }
            }
            return writeInterleaved(out, out.floatBuf, frames)
        case SND_PCM_FORMAT_S32_LE:
            let scale = 2_147_483_520.0 * Double(line)
            for i in 0..<frames {
                let l = Int32(Double(max(-1.0, min(1.0, renderLeft[i]))) * scale)
                if ch == 2 {
                    let r = Int32(Double(max(-1.0, min(1.0, renderRight[i]))) * scale)
                    out.int32Buf[2 * i] = l
                    out.int32Buf[2 * i + 1] = r
                } else {
                    out.int32Buf[i] = l
                }
            }
            return writeInterleaved(out, out.int32Buf, frames)
        default:
            let scale = 32_767.0 * Double(line)
            for i in 0..<frames {
                let l = Int16(Double(max(-1.0, min(1.0, renderLeft[i]))) * scale)
                if ch == 2 {
                    let r = Int16(Double(max(-1.0, min(1.0, renderRight[i]))) * scale)
                    out.int16Buf[2 * i] = l
                    out.int16Buf[2 * i + 1] = r
                } else {
                    out.int16Buf[i] = l
                }
            }
            return writeInterleaved(out, out.int16Buf, frames)
        }
    }

    private func writeInterleaved<T>(_ out: ALSAPCM, _ buf: [T], _ frames: Int) -> Bool {
        var remaining = frames
        var offset = 0
        while remaining > 0, running.load(ordering: .relaxed) {
            let rc = buf.withUnsafeBytes { raw -> snd_pcm_sframes_t in
                // Staging buffers are non-empty (periodFrames * channels).
                // swiftlint:disable:next force_unwrapping
                let base = raw.baseAddress!
                    .advanced(by: offset * out.channels * MemoryLayout<T>.stride)
                return snd_pcm_writei(out.pcm, base, snd_pcm_uframes_t(remaining))
            }
            if rc < 0 {
                renderXruns.wrappingIncrement(ordering: .relaxed)
                if snd_pcm_recover(out.pcm, Int32(rc), 1) < 0 {
                    fputs(
                        "[ALSA] output device lost: \(alsaErrorString(Int32(rc)))\n",
                        stderr)
                    return false
                }
                continue
            }
            remaining -= Int(rc)
            offset += Int(rc)
        }
        return true
    }

    // MARK: - Capture loop (input pacing)

    private func captureLoop() {
        guard let inp = input, let ring = inputRing else { return }
        applyRealtimeThreadPriority(69)

        let frames = inp.periodFrames
        let ch = inp.channels
        while running.load(ordering: .acquiring) {
            let got: Int
            switch inp.format {
            case SND_PCM_FORMAT_FLOAT_LE:
                got = readPeriod(inp, into: &inp.floatBuf, frames: frames)
                guard got > 0 else { continue }
                for i in 0..<got {
                    if ch == 2 {
                        captureLeft[i] = inp.floatBuf[2 * i]
                        captureRight[i] = inp.floatBuf[2 * i + 1]
                    } else {
                        captureLeft[i] = inp.floatBuf[i]
                        captureRight[i] = inp.floatBuf[i]
                    }
                }
            case SND_PCM_FORMAT_S32_LE:
                got = readPeriod(inp, into: &inp.int32Buf, frames: frames)
                guard got > 0 else { continue }
                let scale = Float(1.0 / 2_147_483_648.0)
                for i in 0..<got {
                    if ch == 2 {
                        captureLeft[i] = Float(inp.int32Buf[2 * i]) * scale
                        captureRight[i] = Float(inp.int32Buf[2 * i + 1]) * scale
                    } else {
                        let v = Float(inp.int32Buf[i]) * scale
                        captureLeft[i] = v
                        captureRight[i] = v
                    }
                }
            default:
                got = readPeriod(inp, into: &inp.int16Buf, frames: frames)
                guard got > 0 else { continue }
                let scale = Float(1.0 / 32_768.0)
                for i in 0..<got {
                    if ch == 2 {
                        captureLeft[i] = Float(inp.int16Buf[2 * i]) * scale
                        captureRight[i] = Float(inp.int16Buf[2 * i + 1]) * scale
                    } else {
                        let v = Float(inp.int16Buf[i]) * scale
                        captureLeft[i] = v
                        captureRight[i] = v
                    }
                }
            }
            captureLeft.withUnsafeBufferPointer { lBuf in
                captureRight.withUnsafeBufferPointer { rBuf in
                    // Preallocated at start(); non-empty by construction.
                    // swiftlint:disable:next force_unwrapping
                    let leftBase = lBuf.baseAddress!
                    // swiftlint:disable:next force_unwrapping
                    let rightBase = rBuf.baseAddress!
                    ring.write(left: leftBase, right: rightBase, frameCount: got)
                }
            }
            publishInputPeaks(frames: got)
        }
    }

    /// Blocking read of up to one period. Returns frames read (0 after an
    /// xrun recovery or when stopping; negative never escapes).
    private func readPeriod<T>(_ inp: ALSAPCM, into buf: inout [T], frames: Int) -> Int {
        let rc = buf.withUnsafeMutableBytes { raw -> snd_pcm_sframes_t in
            // Staging buffers are non-empty (periodFrames * channels).
            // swiftlint:disable:next force_unwrapping
            snd_pcm_readi(inp.pcm, raw.baseAddress!, snd_pcm_uframes_t(frames))
        }
        if rc < 0 {
            captureXruns.wrappingIncrement(ordering: .relaxed)
            if snd_pcm_recover(inp.pcm, Int32(rc), 1) < 0 {
                fputs(
                    "[ALSA] input device lost: \(alsaErrorString(Int32(rc)))\n",
                    stderr)
                running.store(false, ordering: .releasing)
            }
            return 0
        }
        return Int(rc)
    }
}

#endif  // os(Linux)
