// macOS-only (AVAudioEngine output; Linux uses ALSAAudioEngine): the Linux CLI build excludes this file.
#if os(macOS)

import AVFoundation
import AudioToolbox
import Foundation
import Accelerate
import Atomics
import MPXPrimeCore
import MPXPrimeNative
import os

private let captureLog = Logger(subsystem: "com.mpxprime.app", category: "input-capture")

enum AudioEngineError: Error {
    case sourceNodeFormatUnavailable
    case engineStartFailed(String)
    case inputFormatUnavailable
    case deviceSelectionFailed(String)
    case inputPermissionDenied
}

enum AudioOutputMode {
    case mpxComposite
    case monitorAudio
    // Processed stereo L/R audio (post pre-encode limiter), for feeding an
    // external stereo coder. No composite / pilot / subcarrier / RDS.
    case processedAudio
}

final class AudioOutputEngine {
    private static let scopeSampleCount = 128
    private static let scopeHistorySeconds: Double = 0.25
    static let preMPXSpectrumFrameCount = 4096
    /// The processed-audio (Post) spectrum runs at the render rate: 16384
    /// frames is 85 ms at 192 kHz, the same ~12 Hz resolution the 4096-frame
    /// input (Pre) window has at 48 kHz.
    static let processedSpectrumFrameCount = 16_384
    private static let preMPXHistoryFrameCount = processedSpectrumFrameCount * 2
    private static let meterUpdateIntervalFrames: Int = 512
    private static let peakReaderSlots = 8

    /// The peak channels the render / capture callbacks publish.
    private enum PeakChannel: Int, CaseIterable {
        case input, inputLeft, inputRight, postAGCLeft, postAGCRight, output, outputLeft, outputRight
    }

    /// One reader's decaying peak hold (reader side only).
    private struct PeakHold {
        var input: Float = 0
        var inputLeft: Float = 0
        var inputRight: Float = 0
        var postAGCLeft: Float = 0
        var postAGCRight: Float = 0
        var output: Float = 0
        var lastReadUptime: TimeInterval?
    }

    struct InputTransportSnapshot {
        let overflows: UInt64
        let underflows: UInt64
        let tornReads: UInt64
        let bufferedFrames: Int
        let resampleMode: String
        let ratioTrim: Double
        let sampleStep: Double
    }

    struct MeterSnapshot {
        var inputRMS: Float
        var inputPeak: Float
        var inputLeftRMS: Float
        var inputRightRMS: Float
        var inputLeftPeak: Float
        var inputRightPeak: Float
        var postAGCLeftRMS: Float
        var postAGCRightRMS: Float
        var postAGCLeftPeak: Float
        var postAGCRightPeak: Float
        var outputRMS: Float
        var outputPeak: Float
        var deviationKHzPeak: Float
        /// Peak actually presented to the converter: post `output_gain_db`
        /// AND post `mpx_line_output_dbfs` (composite mode). The electrical
        /// headroom readout, complementing the modulation-domain deviation.
        var dacPeak: Float
        var liveInputPeak: Float
        var liveInputLeftPeak: Float
        var liveInputRightPeak: Float
        var livePostAGCLeftPeak: Float
        var livePostAGCRightPeak: Float
        var liveOutputPeak: Float
        /// Per-channel output peaks: the processed L / R feed outside MPX
        /// mode (in MPX both channels carry the same composite).
        var liveOutputLeftPeak: Float
        var liveOutputRightPeak: Float
        var liveDeviationKHzPeak: Float
        var agcDetectorDB: Float
        var agcGainDB: Float
        var agcGateActive: Bool
        var advancedDynamicsActive: Bool
        var advancedDynamicsDensityDB: Float
        /// Per-band leveler gains, low to high; fixed scalars because this
        /// struct is written on the render thread (no arrays).
        var adBandGain1DB: Float
        var adBandGain2DB: Float
        var adBandGain3DB: Float
        var adBandGain4DB: Float
        var adBandGain5DB: Float
        var compositeClipperGainReductionDB: Float
        var compositeClipperLookaheadGainReductionDB: Float
        var preEncodeAudioLimiterGainReductionDB: Float
        var mpxSafetyLimiterGainReductionDB: Float
        var mpxSafetyClipDB: Float
        var bs412: BS412Status
        var nonFiniteInputSamples: UInt64
        var pilotInjectionPercent: Float
        var rdsInjectionPercent: Float
        var audioCompositePeak: Float
        var compositeBudgetMarginDB: Float
        /// Post-injection overshoot envelope — non-zero means the chain
        /// is operating over-budget at the operator's current config
        /// (output gain × subcarrier reservation > 1.0). Surfaces what
        /// would otherwise be silent pilot/RDS distortion.
        var postInjectionOvershoot: Float
        /// True when the composite budget governor has muted the
        /// audio path because outputGain × subcarrier reservation
        /// left no headroom. Operator must reduce outputGain,
        /// pilot/RDS injection levels, or deviation.
        var compositeOverBudget: Bool
        var outputStereoCorrelation: Float
        var outputSideToMidRatio: Float
    }

    private let engine = AVAudioEngine()
    /// Direct AUHAL input-capture path. Replaces the prior
    /// `captureEngine: AVAudioEngine?` to escape AVAudioEngine's
    /// first-start failure on non-default input devices — the
    /// dedicated input-node binding intermittently failed to deliver
    /// tap callbacks on cold start. AUHAL is TN2091's documented
    /// answer to that bug.
    private var inputAU: InputAUHAL?
    private let generator: MPXGenerator
    /// Tracks whether the engine is currently rendering live input
    /// (`true`) or the test tone (`false`). Mutable so the Test Tone
    /// tab's Enable toggle can flip the source live via
    /// `applyRuntimeConfig`. Render callback reads this each block.
    private var useInputSource: Bool
    private let requestedSampleRate: Double
    private let requestedBlockSize: Int
    private let requestedInputDeviceID: AudioDeviceID?
    private let requestedOutputDeviceID: AudioDeviceID?
    // Output device whose nominal rate we forced to the configured rate, plus its
    // prior rate to restore on stop (composite MPX needs the device actually
    // running at e.g. 192 kHz, not Core Audio SRC'ing behind our back).
    private var forcedOutputRate: (deviceID: AudioDeviceID, priorRate: Double)?
    private let outputMode: AudioOutputMode
    /// Apply the composite line-output trim in place: scale, and when the trim
    /// is positive, clamp deterministically rather than leave the overshoot to
    /// the converter. Pure and allocation-free so the render path can call it
    /// and `LineOutputCalibrationTests` can pin it.
    @inline(__always)
    static func applyLineOutput(
        scale: Float,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0, scale != 1.0 else { return }
        var s = scale
        vDSP_vsmul(left, 1, &s, left, 1, vDSP_Length(frameCount))
        vDSP_vsmul(right, 1, &s, right, 1, vDSP_Length(frameCount))
        if s > 1.0 {
            var lo: Float = -1.0
            var hi: Float = 1.0
            vDSP_vclip(left, 1, &lo, &hi, left, 1, vDSP_Length(frameCount))
            vDSP_vclip(right, 1, &lo, &hi, right, 1, vDSP_Length(frameCount))
        }
    }

    /// Line output calibration: linear scale applied to the composite at the
    /// DAC write, after every meter/scope capture (those stay in the
    /// 0 dBFS = 100% modulation domain). Exactly 1 outside composite mode
    /// (`OutputWiring.lineOutputScale`). Render-thread only after start.
    private var lineOutputScale: Float
    /// Divides `output_gain_db` back out of the metered composite so the
    /// deviation readout stays in the modulation domain (composite mode; 1.0
    /// otherwise). Updated with the runtime config on the render thread.
    private var modulationReferenceScale: Float
    private var configuredRenderSampleRate: Double = 0.0
    private var inputRing: StereoInputRingBuffer?
    private var configuredInputSampleRate: Double?
    private var inputToRenderRatio: Double = 1.0
    private var inputPrefillFrames = 0
    private var inputPrimeThresholdFrames = 0
    private var inputPrimed = false
    private var inputTargetBufferedFrames = 0
    private var inputBufferedDeadbandFrames = 0
    private var routingNote: String?
    /// The operator's channel choice per device (nil = channels 1, 2).
    private let requestedInputChannels: ChannelPair?
    private let requestedOutputChannels: ChannelPair?
    /// What `start` actually applied (after `ChannelPair.resolve` against
    /// the real device), for the status line; nil while stopped.
    private(set) var appliedInputChannels: ChannelPair?
    private(set) var appliedOutputChannels: ChannelPair?
    /// Where the RIGHT side of the render lands for a MONO output pair: the
    /// chain always renders two channels and only the left one reaches the
    /// device (for the composite both carry the same signal anyway).
    /// Allocated by `start` on the multichannel path, freed by `stop`, nil
    /// on the 2-channel path; read on the render thread, never resized.
    private var outputMonoSink: UnsafeMutablePointer<Float>?
    private var outputMonoSinkFrames = 0
    private var captureCallbackCount: UInt64 = 0
    private var captureFrameCount: UInt64 = 0
    private var captureFrameCounter: Int = 0
    private let meterLock = NSLock()
    // Render-thread config handoff. The two consumers run on the audio
    // render thread and must never block, so they take the lock with
    // `lockIfAvailable()` (try-lock) and skip-apply-this-block on
    // contention -- the pending flag stays set and the apply lands on the
    // next block. Producers (UI thread) and stop() take it with the
    // blocking `lock()`. os_unfair_lock avoids the NSLock priority-
    // inversion window the render thread previously had.
    private let runtimeConfigLock = OSAllocatedUnfairLock()
    private let runtimeConfigPending = ManagedAtomic<Bool>(false)
    private let rdsRuntimeConfigPending = ManagedAtomic<Bool>(false)
    /// Largest render-block frame count CoreAudio has actually delivered,
    /// tracked lock-free for out-of-band visibility into whether the
    /// engine-start pre-allocation (preAllocateBuffers) was sized large
    /// enough. Read off the render path via `maxObservedRenderFrameCount`.
    private let maxObservedRenderFrames = ManagedAtomic<Int>(0)
    private var meterSnapshot = MeterSnapshot(
        inputRMS: 0.0,
        inputPeak: 0.0,
        inputLeftRMS: 0.0,
        inputRightRMS: 0.0,
        inputLeftPeak: 0.0,
        inputRightPeak: 0.0,
        postAGCLeftRMS: 0.0,
        postAGCRightRMS: 0.0,
        postAGCLeftPeak: 0.0,
        postAGCRightPeak: 0.0,
        outputRMS: 0.0,
        outputPeak: 0.0,
        deviationKHzPeak: 0.0,
        dacPeak: 0.0,
        liveInputPeak: 0.0,
        liveInputLeftPeak: 0.0,
        liveInputRightPeak: 0.0,
        livePostAGCLeftPeak: 0.0,
        livePostAGCRightPeak: 0.0,
        liveOutputPeak: 0.0,
        liveOutputLeftPeak: 0.0,
        liveOutputRightPeak: 0.0,
        liveDeviationKHzPeak: 0.0,
        agcDetectorDB: -120.0,
        agcGainDB: 0.0,
        agcGateActive: false,
        advancedDynamicsActive: false,
        advancedDynamicsDensityDB: 0.0,
        adBandGain1DB: 0.0,
        adBandGain2DB: 0.0,
        adBandGain3DB: 0.0,
        adBandGain4DB: 0.0,
        adBandGain5DB: 0.0,
        compositeClipperGainReductionDB: 0.0,
        compositeClipperLookaheadGainReductionDB: 0.0,
        preEncodeAudioLimiterGainReductionDB: 0.0,
        mpxSafetyLimiterGainReductionDB: 0.0,
        mpxSafetyClipDB: 0.0,
        bs412: BS412Status(),
        nonFiniteInputSamples: 0,
        pilotInjectionPercent: 0.0,
        rdsInjectionPercent: 0.0,
        audioCompositePeak: 0.0,
        compositeBudgetMarginDB: 0.0,
        postInjectionOvershoot: 0.0,
        compositeOverBudget: false,
        outputStereoCorrelation: 1.0,
        outputSideToMidRatio: 0.0
    )
    /// Peak-since-last-read per consumer (GUI, each web meter stream, the
    /// headless status tick): a read by one never clears another's. Written
    /// lock-free by the render and capture callbacks.
    private let peakReaders = MultiReaderPeakAccumulator(
        channels: PeakChannel.allCases.count, slots: AudioOutputEngine.peakReaderSlots)
    /// Each reader slot's decaying hold, reader side, under `meterLock`.
    private var peakHolds = [PeakHold](
        repeating: PeakHold(), count: AudioOutputEngine.peakReaderSlots)
    /// Control-API telemetry FFT, built once and reused (it was a fresh
    /// FFT setup per /api/telemetry request).
    let controlTelemetrySpectrum = ControlTelemetrySpectrum()
    private var inputScopeLeftHistory: [Float] = []
    private var inputScopeRightHistory: [Float] = []
    private var outputScopeHistory: [Float] = []
    private var preMPXLeftHistory: [Float] = []
    private var preMPXRightHistory: [Float] = []
    private var inputScopeWriteIndex: Int = 0
    private var outputScopeWriteIndex: Int = 0
    private var preMPXWriteIndex: Int = 0
    private var inputScopeValidFrames: Int = 0
    private var outputScopeValidFrames: Int = 0
    private var preMPXValidFrames: Int = 0
    private var inputScopeSampleRate: Double = 0.0
    private var outputScopeSampleRate: Double = 0.0
    private var preMPXSampleRate: Double = 0.0
    private var monitorMPXLeftScratch: [Float] = []
    private var monitorMPXRightScratch: [Float] = []
    /// The concurrent listening output: its own device, its own engine, fed by
    /// a lock-free ring this engine writes one block at a time. The
    /// transmitter feed never depends on it.
    /// The config the engine started with. Kept whole for the monitor, which
    /// needs the OPERATING mode (fm / hd / am all arrive here as
    /// `.processedAudio`) and the pre-emphasis the chain actually applied.
    private let startConfig: AppConfig
    private let monitorOutput = MonitorOutput()
    private var monitorConditioner = MonitorConditioner()
    /// Monitor level published by the control side, consumed by the render
    /// thread. Float bit pattern; the conditioner ramps to it.
    private let pendingMonitorGain = ManagedAtomic<UInt32>(Float(1.0).bitPattern)
    private var monitorRing: StereoInputRingBuffer?
    private var postAGCLeftScratch: [Float] = []
    private var postAGCRightScratch: [Float] = []
    private var preMPXLeftScratch: [Float] = []
    private var preMPXRightScratch: [Float] = []
    private var isShuttingDown = false
    private var frameCounter: Int = 0
    /// Written by start/stop and by the UI when the window is hidden, read
    /// on the render and capture callbacks -- an atomic, not a plain Bool
    /// (0.65 audit, P0-5).
    private let meteringEnabledFlag = ManagedAtomic<Bool>(true)
    private var meteringEnabled: Bool {
        get { meteringEnabledFlag.load(ordering: .relaxed) }
        set { meteringEnabledFlag.store(newValue, ordering: .relaxed) }
    }
    private var pendingRuntimeConfig: MPXGenerator.RuntimeConfig?
    private var lastQueuedRuntimeConfig: MPXGenerator.RuntimeConfig?
    private var pendingRDSRuntimeConfig: MPXGenerator.RDSRuntimeConfig?
    private var lastQueuedRDSRuntimeConfig: MPXGenerator.RDSRuntimeConfig?
    private let inputScopeCaptureEnabled = ManagedAtomic<Bool>(true)
    private let outputHistoryCaptureEnabled = ManagedAtomic<Bool>(true)
    private let preMPXHistoryCaptureEnabled = ManagedAtomic<Bool>(true)
    private let outputImageMetricsEnabled = ManagedAtomic<Bool>(true)
    private let runtimeConfigApplyCount = ManagedAtomic<UInt64>(0)
    private let runtimeConfigSkipCount = ManagedAtomic<UInt64>(0)

    init(
        generator: MPXGenerator,
        config: AppConfig,
        inputDeviceID: AudioDeviceID? = nil,
        outputDeviceID: AudioDeviceID? = nil,
        outputMode: AudioOutputMode = .mpxComposite,
        inputChannels: ChannelPair? = nil,
        outputChannels: ChannelPair? = nil
    ) {
        self.generator = generator
        self.startConfig = config
        self.useInputSource = config.sourceMode.lowercased() == "input"
        self.requestedSampleRate = config.sampleRate
        self.requestedBlockSize = config.blockSize
        self.requestedInputDeviceID = inputDeviceID
        self.requestedOutputDeviceID = outputDeviceID
        self.requestedInputChannels = inputChannels
        self.requestedOutputChannels = outputChannels
        self.outputMode = outputMode
        // Both scales come from OutputWiring, which the Linux engine calls
        // too and RobustnessOutputWiringTests pins (review finding 10).
        self.lineOutputScale = OutputWiring.lineOutputScale(
            lineOutputDBFS: Float(config.mpxLineOutputDBFS), mode: outputMode)
        self.modulationReferenceScale = OutputWiring.modulationReferenceScale(
            outputGainDB: Float(config.outputGainDB), mode: outputMode)
        self.encoderFIREnabled = config.encoderFIREnabled
        self.multibandFIREnabled = config.multibandFIREnabled
    }

    /// Bring up the listening output for this run. Never fails the start: a
    /// monitor that cannot run is a note in the status line, not an
    /// interruption of the air chain.
    private func startMonitorOutput(renderRate: Double) {
        guard outputMode != .monitorAudio else { return }
        let ring = monitorOutput.prepare(sampleRate: renderRate, blockFrames: requestedBlockSize)
        monitorRing = ring
        // Configures AND publishes the configured level BEFORE anything can
        // render, or the render thread's first block reads the atomic's unity
        // default and ramps the monitor away from the level it was just given.
        OutputWiring.configureMonitor(
            &monitorConditioner,
            shape: MonitorConditioner.shape(for: startConfig.operatingMode, config: startConfig),
            sampleRate: Float(renderRate),
            gainDB: startConfig.monitorGainDB,
            pendingGain: pendingMonitorGain)
        monitorOutput.reconcile(
            enabled: startConfig.monitorEnabled,
            monitorUID: startConfig.monitorDeviceUID,
            monitorChannels: startConfig.monitorChannels,
            txDeviceID: requestedOutputDeviceID ?? AudioDevices.defaultOutputDeviceID(),
            txChannels: appliedOutputChannels ?? requestedOutputChannels)
        if let note = monitorOutput.note, startConfig.monitorEnabled {
            appendRoutingNote(note)
        }
    }

    /// Live-apply the monitor: level, device, on/off. Never restarts the
    /// transmitter -- swapping the monitor device stops only its player.
    func applyMonitorSettings(_ config: AppConfig) {
        guard outputMode != .monitorAudio else { return }
        // The conditioner belongs to the render thread. Publish the level
        // and let that thread pick it up at its next block (0.65 audit,
        // P0-5) -- writing into the struct from here raced every block.
        pendingMonitorGain.store(
            OutputWiring.monitorGainBitPattern(gainDB: config.monitorGainDB), ordering: .relaxed)
        monitorOutput.reconcile(
            enabled: config.monitorEnabled,
            monitorUID: config.monitorDeviceUID,
            monitorChannels: config.monitorChannels,
            txDeviceID: requestedOutputDeviceID ?? AudioDevices.defaultOutputDeviceID(),
            txChannels: appliedOutputChannels ?? requestedOutputChannels)
    }

    /// The processed feed (fm / hd / am) is what leaves the output device, so
    /// the monitor listens to a COPY of it -- conditioned, never touched in
    /// place, or the transmitter would hear the de-emphasis too.
    @inline(__always)
    private func tapProcessedFeedToMonitor(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        monitorMPXLeftScratch.withUnsafeMutableBufferPointer { monL in
            monitorMPXRightScratch.withUnsafeMutableBufferPointer { monR in
                guard let ml = monL.baseAddress, let mr = monR.baseAddress else { return }
                ml.update(from: left, count: frameCount)
                mr.update(from: right, count: frameCount)
                writeMonitorBlock(left: ml, right: mr, frameCount: frameCount)
            }
        }
    }

    /// Copy one rendered block into the monitor ring, conditioned for the mode.
    /// `left`/`right` already hold what the operator should hear (decoded audio
    /// in composite mode, the processed feed otherwise).
    @inline(__always)
    private func writeMonitorBlock(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        monitorConditioner.setTargetGain(
            Float(bitPattern: pendingMonitorGain.load(ordering: .relaxed)))
        monitorConditioner.process(left: left, right: right, frameCount: frameCount)
        monitorRing?.write(left: left, right: right, frameCount: frameCount)
    }

    private let encoderFIREnabled: Bool
    private let multibandFIREnabled: Bool

    /// Is the operator's listening output actually playing?
    var monitorActive: Bool { monitorOutput.isRunning }
    var monitorActiveForControl: Bool { monitorOutput.isRunning }
    /// Why it is not, when it is not.
    var monitorNote: String? { monitorOutput.note }

    func start() throws {
        isShuttingDown = false
        meteringEnabled = true
        try applyOutputDeviceSelection()
        let hardwareOutputFormat = engine.outputNode.outputFormat(forBus: 0)
        let outputRate = hardwareOutputFormat.sampleRate
        // Which device channels carry the feed, resolved against the REAL
        // device (read after it is set): a pair the device lacks falls back
        // to 1, 2 with a routing note instead of a silent transmitter.
        let outputChannelCount = Int(hardwareOutputFormat.channelCount)
        let resolvedOutput = ChannelPair.resolve(
            requested: requestedOutputChannels, channelCount: outputChannelCount, role: "Output")
        appliedOutputChannels = resolvedOutput.pair
        if let note = resolvedOutput.note {
            appendRoutingNote(note)
        }
        // The multichannel path exists only where it is needed: a device
        // with more than two channels AND a pair other than 1, 2. Everything
        // else runs the 2-channel path exactly as it always has.
        // Any pair other than 1, 2 takes the discrete path, a 2-channel device
        // included (mono on channel 2). Everything else -- the default pair,
        // and a 1-channel device, which AVAudioEngine feeds from a stereo
        // source by downmixing -- keeps the historical 0 / 1 buffers.
        let wideOutput = outputChannelCount >= 2 && resolvedOutput.pair != .stereoDefault
        let outLeft = wideOutput ? resolvedOutput.pair.left : 0
        let outRight = wideOutput ? resolvedOutput.pair.right : 1
        let requestedRate = max(8_000.0, requestedSampleRate)
        let renderRate = (outputMode == .monitorAudio) ? requestedRate : outputRate
        if useInputSource {
            try ensureMicrophoneAuthorization()
            try setupInputCapture(targetSampleRate: renderRate)
        }
        // Below 111 kHz the upper stereo sideband folds about Nyquist, and
        // below 118.8 kHz RDS does: the generator switches those services off
        // (`MPXGenerator.compositeRateSupport`) and the operator is told why.
        if outputMode == .mpxComposite, let note = MPXGenerator.compositeRateNote(sampleRate: renderRate) {
            appendRoutingNote(note)
        }
        if outputMode == .monitorAudio, fabs(outputRate - renderRate) > 1.0 {
            appendRoutingNote(
                "Monitor hardware is \(Int(outputRate.rounded())) Hz; internal MPX render remains \(Int(renderRate.rounded())) Hz."
            )
        }
        if outputMode == .processedAudio {
            appendRoutingNote(
                "Processed-audio output: emitting stereo L/R (no composite/pilot/RDS) at \(Int(outputRate.rounded())) Hz for an external stereo coder."
            )
        }
        configuredRenderSampleRate = renderRate
        // Audio-only mode must be set before setSampleRate so the dual-rate
        // boundary is computed with it off (whole engine runs at the audio rate).
        generator.setAudioOutputOnly(outputMode == .processedAudio)
        generator.setSampleRate(renderRate)
        // TX-grade FIR encoder bandwidth guard only runs in composite output
        // mode; monitor mode keeps the low-latency Butterworth so operator
        // monitoring stays snappy.
        // The encoder program lowpass is the audio-domain 15 kHz band-limit (it
        // runs in `processProgramStereo`, upstream of composite assembly), so the
        // linear-phase FIR brickwall is wanted in processed-audio mode too — the
        // output handed to an external coder must be cleanly band-limited. Only the
        // low-latency monitor keeps the gentle IIR fallback.
        generator.setEncoderFIREnabled(outputMode != .monitorAudio && encoderFIREnabled)
        // Linear-phase FIR multiband crossovers — phase-flat band reconstruction
        // prevents the transient smear / inter-band pumping that makes IIR-LR4
        // multiband sound worse than single-band on percussive content. This is an
        // audio-domain quality stage, so it runs in both composite AND
        // processed-audio output (a real TX-feeding output deserves the FIR path);
        // only the low-latency monitor keeps the IIR crossovers.
        generator.setMultibandFIREnabled(outputMode != .monitorAudio && multibandFIREnabled)
        configureScopeHistory(renderRate: renderRate, inputRate: configuredInputSampleRate)
        preAllocateBuffers(maxFrames: Int(max(renderRate, 192000.0) * 0.1))
        startMonitorOutput(renderRate: renderRate)

        let format: AVAudioFormat?
        var wideOutputFormat: AVAudioFormat?
        if wideOutput {
            // The source node speaks the device's full channel count,
            // discrete and in order, so the mixer passes channels through
            // 1:1 instead of matrixing by layout (RingBufferPlayer's recipe).
            guard let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(outputChannelCount))
            else {
                throw AudioEngineError.sourceNodeFormatUnavailable
            }
            format = AVAudioFormat(standardFormatWithSampleRate: renderRate, channelLayout: layout)
            wideOutputFormat = AVAudioFormat(
                standardFormatWithSampleRate: outputRate > 0 ? outputRate : renderRate,
                channelLayout: layout)
            if resolvedOutput.pair.isMono {
                let sinkFrames = max(512, Int(max(renderRate, 192000.0) * 0.1))
                let sink = UnsafeMutablePointer<Float>.allocate(capacity: sinkFrames)
                sink.initialize(repeating: 0, count: sinkFrames)
                outputMonoSink = sink
                outputMonoSinkFrames = sinkFrames
            }
        } else {
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: renderRate,
                channels: 2,
                interleaved: false
            )
        }
        guard let sourceFormat = format else {
            throw AudioEngineError.sourceNodeFormatUnavailable
        }
        let node = AVAudioSourceNode(format: sourceFormat) {
            [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            // FTZ + DAZ on the audio thread, every callback. Without
            // these flags on Intel (x86_64) denormal floats are
            // processed 10-100x slower than normal-range math, and
            // long-running envelope/integrator state in the chain
            // eventually drifts into denormal territory after minutes
            // of operation — the render thread then misses the
            // CoreAudio deadline, samples are dropped, and the output
            // goes to broadband noise / silence at the receiver. The
            // bug reproduces on a real i7-9750H after "a couple of
            // songs" and recovers on engine restart (which resets the
            // accumulated state). Setting MXCSR FTZ + DAZ in hardware
            // bypasses the slow denormal path. ARM64 (Apple Silicon)
            // doesn't suffer from this but setting FPCR FZ here keeps
            // behaviour consistent across architectures.
            mpx_enable_flush_to_zero()
            guard let self else {
                Self.clearBuffers(audioBufferList, frameCount: Int(frameCount))
                return noErr
            }
            if self.isShuttingDown {
                Self.clearBuffers(audioBufferList, frameCount: Int(frameCount))
                return noErr
            }
            self.applyPendingRuntimeConfigIfNeeded()
            self.applyPendingRDSRuntimeConfigIfNeeded()
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            var monoSink: UnsafeMutablePointer<Float>?
            if wideOutput {
                // Multichannel device: every buffer the pair does not name is
                // silence, and so is everything when the list is narrower than
                // the pair (a device format change under a running engine) or
                // a mono pair has nowhere to put its right side.
                Self.clearBuffers(audioBufferList, frameCount: frames)
                guard buffers.count > max(outLeft, outRight) else { return noErr }
                if outLeft == outRight {
                    guard let sink = self.outputMonoSink, frames <= self.outputMonoSinkFrames
                    else { return noErr }
                    monoSink = sink
                }
            }
            self.frameCounter += frames
            let throttled = self.meteringEnabled && ((self.frameCounter % Self.meterUpdateIntervalFrames) < frames)
            let captureInputScope =
                throttled && self.inputScopeCaptureEnabled.load(ordering: .relaxed)
            let captureOutputHistory =
                throttled && self.outputHistoryCaptureEnabled.load(ordering: .relaxed)
            let capturePreMPXHistory =
                throttled && self.preMPXHistoryCaptureEnabled.load(ordering: .relaxed)
            let captureOutputImageMetrics =
                throttled && self.outputImageMetricsEnabled.load(ordering: .relaxed)
            let needsAnalysisBuffers = throttled || capturePreMPXHistory
            // outLeft / outRight are 0 / 1 on the 2-channel path; on the
            // multichannel path they are the chosen device channels, and a
            // mono pair renders its right side into the sink (discarded).
            if buffers.count >= 2,
                let leftData = buffers[outLeft].mData?.assumingMemoryBound(to: Float.self),
                let rightData = monoSink ?? buffers[outRight].mData?.assumingMemoryBound(to: Float.self) {
                if self.useInputSource, let ring = self.inputRing {
                    if !self.inputPrimed {
                        if ring.bufferedFrames() < self.inputPrimeThresholdFrames {
                            for i in 0..<frames {
                                leftData[i] = 0.0
                                rightData[i] = 0.0
                            }
                            return noErr
                        }
                        self.inputPrimed = true
                        // While we output silence waiting to prime, the input
                        // device free-runs and piles frames into the ring, so
                        // it overshoots well past the prime depth by the time
                        // we notice. Snap back to prime depth (same RT-safe
                        // call the tone->input warm restart uses) so a cold
                        // start settles at the same low latency instead of
                        // carrying the startup overshoot as standing delay.
                        ring.dropToTargetBufferedFrames(self.inputPrimeThresholdFrames)
                    }
                    let missing = ring.readAdaptive(
                        intoLeft: leftData,
                        outRight: rightData,
                        frameCount: frames,
                        nominalConsume: max(
                            1, Int((Double(frames) * self.inputToRenderRatio).rounded())),
                        targetBuffered: self.inputTargetBufferedFrames,
                        deadband: self.inputBufferedDeadbandFrames
                    )
                    let bufferedAfterRead = ring.bufferedFrames()
                    let rePrimeThreshold = max(
                        self.inputBufferedDeadbandFrames,
                        min(self.inputPrefillFrames, self.inputTargetBufferedFrames / 2)
                    )
                    if missing >= frames || (missing > 0 && bufferedAfterRead <= rePrimeThreshold) {
                        self.inputPrimed = false
                    }
                    let monitorOn = self.monitorOutput.isRunning
                    if monitorOn { self.ensureMonitorScratchCapacity(frames: frames) }
                    self.withOptionalAnalysisBuffers(frames: frames, enabled: needsAnalysisBuffers) { analysis in
                        if self.outputMode == .processedAudio {
                            self.generator.renderAudioOnlyFromInputInPlace(
                                frameCount: frames,
                                left: leftData,
                                right: rightData,
                                analysis: analysis
                            )
                            if monitorOn { self.tapProcessedFeedToMonitor(left: leftData, right: rightData, frameCount: frames) }
                            if throttled {
                                self.updateThrottledRenderAnalysis(
                                    outputLeft: leftData,
                                    outputRight: rightData,
                                    frameCount: frames,
                                    analysis: analysis,
                                    captureOutputImageMetrics: captureOutputImageMetrics,
                                    captureOutputHistory: captureOutputHistory,
                                    capturePreMPXHistory: capturePreMPXHistory
                                )
                            }
                        } else if self.outputMode == .monitorAudio {
                            if self.generator.isProcessingBypassEnabled {
                                self.generator.renderMonitorFromInputInPlace(
                                    frameCount: frames,
                                    left: leftData,
                                    right: rightData,
                                    analysis: analysis
                                )
                                if throttled {
                                    self.updateThrottledRenderAnalysis(
                                        outputLeft: leftData,
                                        outputRight: rightData,
                                        frameCount: frames,
                                        analysis: analysis,
                                        captureOutputImageMetrics: captureOutputImageMetrics,
                                        captureOutputHistory: captureOutputHistory,
                                        capturePreMPXHistory: capturePreMPXHistory
                                    )
                                }
                            } else {
                                self.ensureMonitorScratchCapacity(frames: frames)
                                self.monitorMPXLeftScratch.withUnsafeMutableBufferPointer { mpxL in
                                    self.monitorMPXRightScratch.withUnsafeMutableBufferPointer { mpxR in
                                        guard let mpxLeft = mpxL.baseAddress,
                                            let mpxRight = mpxR.baseAddress
                                        else { return }
                                        self.generator.renderFromInputAndMonitorInPlace(
                                            frameCount: frames,
                                            left: leftData,
                                            right: rightData,
                                            mpxLeft: mpxLeft,
                                            mpxRight: mpxRight,
                                            analysis: analysis
                                        )
                                        if throttled {
                                            self.updateThrottledRenderAnalysis(
                                                outputLeft: mpxLeft,
                                                outputRight: mpxRight,
                                                frameCount: frames,
                                                analysis: analysis,
                                                captureOutputImageMetrics: captureOutputImageMetrics,
                                                captureOutputHistory: captureOutputHistory,
                                                capturePreMPXHistory: capturePreMPXHistory
                                            )
                                        }
                                    }
                                }
                            }
                        } else if monitorOn, self.outputMode == .mpxComposite {
                            // Composite to the transmitter AND the decoded
                            // audio to the monitor, in one pass. The decode
                            // cannot move the composite.
                            self.monitorMPXLeftScratch.withUnsafeMutableBufferPointer { monL in
                                self.monitorMPXRightScratch.withUnsafeMutableBufferPointer { monR in
                                    guard let ml = monL.baseAddress, let mr = monR.baseAddress else { return }
                                    self.generator.renderFromInputInPlace(
                                        frameCount: frames,
                                        left: leftData,
                                        right: rightData,
                                        analysis: analysis,
                                        monitorLeft: ml,
                                        monitorRight: mr
                                    )
                                    self.writeMonitorBlock(left: ml, right: mr, frameCount: frames)
                                }
                            }
                            if throttled {
                                self.updateThrottledRenderAnalysis(
                                    outputLeft: leftData,
                                    outputRight: rightData,
                                    frameCount: frames,
                                    analysis: analysis,
                                    captureOutputImageMetrics: captureOutputImageMetrics,
                                    captureOutputHistory: captureOutputHistory,
                                    capturePreMPXHistory: capturePreMPXHistory
                                )
                            }
                        } else {
                            self.generator.renderFromInputInPlace(
                                frameCount: frames,
                                left: leftData,
                                right: rightData,
                                analysis: analysis
                            )
                            if throttled {
                                self.updateThrottledRenderAnalysis(
                                    outputLeft: leftData,
                                    outputRight: rightData,
                                    frameCount: frames,
                                    analysis: analysis,
                                    captureOutputImageMetrics: captureOutputImageMetrics,
                                    captureOutputHistory: captureOutputHistory,
                                    capturePreMPXHistory: capturePreMPXHistory
                                )
                            }
                        }
                    }
                    if captureInputScope, !self.useInputSource {
                        self.updateInputScopeSnapshot(
                            left: leftData, right: rightData, frameCount: frames)
                    }
                } else {
                    let monitorOn = self.monitorOutput.isRunning
                    if monitorOn { self.ensureMonitorScratchCapacity(frames: frames) }
                    self.withOptionalAnalysisBuffers(frames: frames, enabled: needsAnalysisBuffers) { analysis in
                        if self.outputMode == .processedAudio {
                            self.generator.renderAudioOnlyToneNonInterleaved(
                                frameCount: frames,
                                left: leftData,
                                right: rightData,
                                analysis: analysis
                            )
                            if monitorOn { self.tapProcessedFeedToMonitor(left: leftData, right: rightData, frameCount: frames) }
                            if throttled {
                                self.updateThrottledRenderAnalysis(
                                    outputLeft: leftData,
                                    outputRight: rightData,
                                    frameCount: frames,
                                    analysis: analysis,
                                    captureOutputImageMetrics: captureOutputImageMetrics,
                                    captureOutputHistory: captureOutputHistory,
                                    capturePreMPXHistory: capturePreMPXHistory
                                )
                            }
                        } else if self.outputMode == .monitorAudio {
                            if self.generator.isProcessingBypassEnabled {
                                self.generator.renderMonitorToneNonInterleaved(
                                    frameCount: frames,
                                    left: leftData,
                                    right: rightData,
                                    analysis: analysis
                                )
                                if throttled {
                                    self.updateThrottledRenderAnalysis(
                                        outputLeft: leftData,
                                        outputRight: rightData,
                                        frameCount: frames,
                                        analysis: analysis,
                                        captureOutputImageMetrics: captureOutputImageMetrics,
                                        captureOutputHistory: captureOutputHistory,
                                        capturePreMPXHistory: capturePreMPXHistory
                                    )
                                }
                            } else {
                                self.ensureMonitorScratchCapacity(frames: frames)
                                self.monitorMPXLeftScratch.withUnsafeMutableBufferPointer { mpxL in
                                    self.monitorMPXRightScratch.withUnsafeMutableBufferPointer { mpxR in
                                        guard let mpxLeft = mpxL.baseAddress,
                                            let mpxRight = mpxR.baseAddress
                                        else { return }
                                        self.generator.renderToneAndMonitorNonInterleaved(
                                            frameCount: frames,
                                            left: leftData,
                                            right: rightData,
                                            mpxLeft: mpxLeft,
                                            mpxRight: mpxRight,
                                            analysis: analysis
                                        )
                                        if throttled {
                                            self.updateThrottledRenderAnalysis(
                                                outputLeft: mpxLeft,
                                                outputRight: mpxRight,
                                                frameCount: frames,
                                                analysis: analysis,
                                                captureOutputImageMetrics: captureOutputImageMetrics,
                                                captureOutputHistory: captureOutputHistory,
                                                capturePreMPXHistory: capturePreMPXHistory
                                            )
                                        }
                                    }
                                }
                            }
                        } else if monitorOn, self.outputMode == .mpxComposite {
                            self.monitorMPXLeftScratch.withUnsafeMutableBufferPointer { monL in
                                self.monitorMPXRightScratch.withUnsafeMutableBufferPointer { monR in
                                    guard let ml = monL.baseAddress, let mr = monR.baseAddress else { return }
                                    self.generator.renderNonInterleaved(
                                        frameCount: frames,
                                        left: leftData,
                                        right: rightData,
                                        analysis: analysis,
                                        monitorLeft: ml,
                                        monitorRight: mr
                                    )
                                    self.writeMonitorBlock(left: ml, right: mr, frameCount: frames)
                                }
                            }
                            if throttled {
                                self.updateThrottledRenderAnalysis(
                                    outputLeft: leftData,
                                    outputRight: rightData,
                                    frameCount: frames,
                                    analysis: analysis,
                                    captureOutputImageMetrics: captureOutputImageMetrics,
                                    captureOutputHistory: captureOutputHistory,
                                    capturePreMPXHistory: capturePreMPXHistory
                                )
                            }
                        } else {
                            self.generator.renderNonInterleaved(
                                frameCount: frames,
                                left: leftData,
                                right: rightData,
                                analysis: analysis
                            )
                            if throttled {
                                self.updateThrottledRenderAnalysis(
                                    outputLeft: leftData,
                                    outputRight: rightData,
                                    frameCount: frames,
                                    analysis: analysis,
                                    captureOutputImageMetrics: captureOutputImageMetrics,
                                    captureOutputHistory: captureOutputHistory,
                                    capturePreMPXHistory: capturePreMPXHistory
                                )
                            }
                        }
                    }
                    if captureInputScope, !self.useInputSource {
                        self.updateInputScopeSnapshot(
                            left: leftData, right: rightData, frameCount: frames)
                    }
                }
                // Line output calibration: the LAST operation before the DAC,
                // after meters/scopes captured the composite-domain signal,
                // and for BOTH branches above -- it lived inside the tone
                // branch until 0.50, so the operator's line trim was silently
                // inert on air while the DAC Peak readout assumed it applied.
                // Exact 1.0 (the 0 dBFS default, and every mode but composite:
                // OutputWiring.lineOutputScale) is skipped, so the historical
                // path stays bit-identical.
                if self.lineOutputScale != 1.0 {
                    Self.applyLineOutput(
                        scale: self.lineOutputScale,
                        left: leftData, right: rightData, frameCount: frames)
                }
                return noErr
            }
            if buffers.count == 1,
                let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                // Interleaved fallback path.
                for i in 0..<(frames * 2) {
                    data[i] = 0.0
                }
                return noErr
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
        if let wideOutputFormat {
            // Mixer -> output explicitly in the same discrete layout at the
            // hardware rate, so no layout matrixing happens on the way out.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: wideOutputFormat)
        }
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
        } catch {
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        // Mark shutdown BEFORE tearing down so any in-flight render callback
        // hits the silence guard at the top of the source node and does not
        // touch state (inputRing, scratch buffers, pending configs) that is
        // about to be freed. Without this, quick stop-start cycles can
        // present as clicks, garbled buffers, or stale data leaking into the
        // next run's first few frames.
        isShuttingDown = true
        meteringEnabled = false
        // The monitor goes first: its player holds the ring this engine's
        // render callback writes into.
        monitorOutput.shutdown()
        monitorRing = nil
        inputRing = nil
        engine.stop()
        engine.reset()
        if let sink = outputMonoSink {
            sink.deallocate()
            outputMonoSink = nil
            outputMonoSinkFrames = 0
        }
        appliedInputChannels = nil
        appliedOutputChannels = nil
        // Restore the output device's prior nominal rate if we forced it.
        if let forced = forcedOutputRate {
            _ = AudioDevices.setNominalSampleRate(deviceID: forced.deviceID, forced.priorRate)
            forcedOutputRate = nil
        }
        if let inputAU {
            inputAU.stop()
            self.inputAU = nil
        }
        inputPrimed = false
        configuredInputSampleRate = nil
        inputToRenderRatio = 1.0
        frameCounter = 0
        captureFrameCounter = 0
        meterLock.lock()
        peakReaders.reset()
        peakHolds = [PeakHold](repeating: PeakHold(), count: Self.peakReaderSlots)
        runtimeConfigLock.lock()
        pendingRuntimeConfig = nil
        lastQueuedRuntimeConfig = nil
        pendingRDSRuntimeConfig = nil
        lastQueuedRDSRuntimeConfig = nil
        runtimeConfigPending.store(false, ordering: .relaxed)
        rdsRuntimeConfigPending.store(false, ordering: .relaxed)
        runtimeConfigLock.unlock()
        meterSnapshot.inputRMS = 0.0
        meterSnapshot.inputPeak = 0.0
        meterSnapshot.inputLeftRMS = 0.0
        meterSnapshot.inputRightRMS = 0.0
        meterSnapshot.inputLeftPeak = 0.0
        meterSnapshot.inputRightPeak = 0.0
        meterSnapshot.postAGCLeftRMS = 0.0
        meterSnapshot.postAGCRightRMS = 0.0
        meterSnapshot.postAGCLeftPeak = 0.0
        meterSnapshot.postAGCRightPeak = 0.0
        meterSnapshot.outputRMS = 0.0
        meterSnapshot.outputPeak = 0.0
        meterSnapshot.deviationKHzPeak = 0.0
        meterSnapshot.dacPeak = 0.0
        meterSnapshot.agcDetectorDB = -120.0
        meterSnapshot.agcGainDB = 0.0
        meterSnapshot.agcGateActive = false
        meterSnapshot.advancedDynamicsActive = false
        meterSnapshot.advancedDynamicsDensityDB = 0.0
        meterSnapshot.adBandGain1DB = 0.0
        meterSnapshot.adBandGain2DB = 0.0
        meterSnapshot.adBandGain3DB = 0.0
        meterSnapshot.adBandGain4DB = 0.0
        meterSnapshot.adBandGain5DB = 0.0
        meterSnapshot.compositeClipperGainReductionDB = 0.0
        meterSnapshot.compositeClipperLookaheadGainReductionDB = 0.0
        meterSnapshot.preEncodeAudioLimiterGainReductionDB = 0.0
        meterSnapshot.mpxSafetyLimiterGainReductionDB = 0.0
        meterSnapshot.mpxSafetyClipDB = 0.0
        meterSnapshot.pilotInjectionPercent = 0.0
        meterSnapshot.rdsInjectionPercent = 0.0
        meterSnapshot.audioCompositePeak = 0.0
        meterSnapshot.compositeBudgetMarginDB = 0.0
        meterSnapshot.postInjectionOvershoot = 0.0
        meterSnapshot.compositeOverBudget = false
        meterSnapshot.outputStereoCorrelation = 1.0
        meterSnapshot.outputSideToMidRatio = 0.0
        meterSnapshot.liveInputPeak = 0.0
        meterSnapshot.liveInputLeftPeak = 0.0
        meterSnapshot.liveInputRightPeak = 0.0
        meterSnapshot.livePostAGCLeftPeak = 0.0
        meterSnapshot.livePostAGCRightPeak = 0.0
        meterSnapshot.liveOutputPeak = 0.0
        meterSnapshot.liveOutputLeftPeak = 0.0
        meterSnapshot.liveOutputRightPeak = 0.0
        meterSnapshot.liveDeviationKHzPeak = 0.0
        inputScopeLeftHistory = []
        inputScopeRightHistory = []
        outputScopeHistory = []
        preMPXLeftHistory = []
        preMPXRightHistory = []
        inputScopeWriteIndex = 0
        outputScopeWriteIndex = 0
        preMPXWriteIndex = 0
        inputScopeValidFrames = 0
        outputScopeValidFrames = 0
        preMPXValidFrames = 0
        inputScopeSampleRate = 0.0
        outputScopeSampleRate = 0.0
        preMPXSampleRate = 0.0
        monitorMPXLeftScratch = []
        monitorMPXRightScratch = []
        postAGCLeftScratch = []
        postAGCRightScratch = []
        preMPXLeftScratch = []
        preMPXRightScratch = []
        meterLock.unlock()
        isShuttingDown = false
    }

    private func applyOutputDeviceSelection() throws {
        routingNote = nil
        if let outputID = requestedOutputDeviceID {
            do {
                try setCurrentDevice(outputID, for: engine.outputNode, role: "output")
                forceOutputDeviceRate(deviceID: outputID)
                applyHALBufferSize(deviceID: outputID, role: "output")
            } catch {
                routingNote =
                    "Requested output device could not be opened by AVAudioEngine; using macOS default output."
            }
        }
    }

    /// Force the MPX output device to the configured render rate (e.g. 192 kHz)
    /// before AVAudioEngine reads its format, so the composite is emitted at full
    /// rate instead of being silently sample-rate-converted by Core Audio (which
    /// also starves the render thread). Warns if the device can't run that rate;
    /// the prior rate is restored on stop. Composite / processed-audio only --
    /// the monitor path intentionally tracks the monitor hardware's own rate.
    private func forceOutputDeviceRate(deviceID: AudioDeviceID) {
        guard outputMode != .monitorAudio else { return }
        let target = max(8_000.0, requestedSampleRate)
        let available = AudioDevices.availableNominalSampleRates(deviceID: deviceID)
        let current = AudioDevices.currentNominalSampleRate(deviceID: deviceID)
        // Already at the target (within 1 Hz): nothing to force or restore.
        if let current, abs(current - target) < 1.0 { return }
        guard available.isEmpty || available.contains(where: { abs($0 - target) < 1.0 }) else {
            appendRoutingNote(
                "Output device cannot run at \(Int(target.rounded())) Hz "
                + "(supports \(available.map { String(Int($0.rounded())) }.joined(separator: "/")) Hz). "
                + "Set it to \(Int(target.rounded())) Hz in Audio MIDI Setup; the composite will be "
                + "sample-rate-converted and may not carry RDS / clean subcarriers otherwise.")
            return
        }
        let prior = current
        let actual = AudioDevices.setNominalSampleRate(deviceID: deviceID, target)
        if let actual, abs(actual - target) < 1.0 {
            if let prior { forcedOutputRate = (deviceID, prior) }
        } else {
            appendRoutingNote(
                "Could not set the output device to \(Int(target.rounded())) Hz; "
                + "set it manually in Audio MIDI Setup.")
        }
    }

    /// Lock the device's HAL buffer frame size to our requested block size.
    /// Without this, AVAudioEngine takes the device's preferred buffer size
    /// (often 1024+ even when we ask for 512), which causes scheduling-
    /// pressure WARNs even when the chain has plenty of CPU headroom.
    /// Clamped to the device's reported allowed range; if the device
    /// can't honour the request we log a routing note and let it run at
    /// the device's nearest legal value.
    private func applyHALBufferSize(deviceID: AudioDeviceID, role: String) {
        let requested = UInt32(max(64, requestedBlockSize))
        guard let actual = AudioDevices.setBufferFrameSize(
            deviceID: deviceID, requested: requested
        ) else {
            return
        }
        if actual != requested {
            appendRoutingNote(
                "\(role.capitalized) device clamped HAL buffer to \(actual) frames (requested \(requested))."
            )
        }
    }

    private func setupInputCapture(targetSampleRate: Double) throws {
        captureLog.info("setupInputCapture: requestedInputDeviceID=\(self.requestedInputDeviceID.map { String($0) } ?? "nil", privacy: .public) targetSampleRate=\(targetSampleRate, privacy: .public)")

        // AUHAL needs an explicit AudioDeviceID — unlike AVAudioEngine,
        // it cannot infer the system default implicitly. Resolve to
        // the HAL default when the operator hasn't selected a device.
        let deviceID: AudioDeviceID
        if let requested = requestedInputDeviceID {
            deviceID = requested
            captureLog.info("setupInputCapture: using requested deviceID=\(requested, privacy: .public)")
        } else if let resolved = AudioDevices.defaultInputDeviceID() {
            deviceID = resolved
            captureLog.info("setupInputCapture: no requestedInputDeviceID; resolved system default deviceID=\(resolved, privacy: .public)")
        } else {
            captureLog.error("setupInputCapture: no input device available")
            throw AudioEngineError.inputFormatUnavailable
        }

        applyHALBufferSize(deviceID: deviceID, role: "input")

        let inputAU = InputAUHAL()
        let firstFrameLogged = ManagedAtomic<Bool>(false)
        // Capture only the input ring + the diagnostic flag, both
        // through `[unowned self]`. The frame sink is invoked from
        // the AUHAL real-time thread; closure body must stay
        // allocation-free and lock-free (matches the prior tap
        // contract). `[weak self]` would add an optional-unwrap on
        // every render slice — `unowned` is intentional and safe
        // because the AudioOutputEngine instance owns inputAU and
        // clears frameSink before deinit.
        // swiftlint:disable:next unowned_variable_capture
        inputAU.frameSink = { [unowned self] left, right, frames in
            // RT-safe first-frame marker for the off-thread 2 s watchdog
            // below: a single releasing store, no scalar peak loop or
            // os_log on the AUHAL render thread. Input level is already
            // metered on the throttled path (handleInputAUHALFrames ->
            // computeStereoLevels), so the prior per-first-frame leftPeak
            // log was redundant with the normal input meters.
            firstFrameLogged.store(true, ordering: .releasing)
            self.handleInputAUHALFrames(left: left, right: right, frameCount: frames)
        }

        // MaxFramesPerSlice sized for the worst case (display-sleep
        // wake delivers one large slice) — matches the prior tap
        // bufferSize ceiling but generous.
        let captureBlockFrames = min(2048, max(256, requestedBlockSize))
        let mfps = max(4096, captureBlockFrames * 2)

        let format: InputAUHAL.Format
        do {
            format = try inputAU.start(
                deviceID: deviceID, channels: requestedInputChannels, maxFramesPerSlice: mfps)
        } catch {
            captureLog.error("AUHAL input start failed: \(String(describing: error), privacy: .public)")
            throw AudioEngineError.engineStartFailed(
                "input capture start failed: \(String(describing: error))")
        }

        captureLog.info("AUHAL input running deviceRate=\(format.deviceSampleRate, privacy: .public) deviceChannels=\(format.deviceChannelCount, privacy: .public) channels=\(format.channels.iniValue, privacy: .public)")
        appliedInputChannels = format.channels
        if let note = format.channelNote {
            appendRoutingNote(note)
        }

        configuredInputSampleRate = format.deviceSampleRate
        if targetSampleRate > 1.0 {
            inputToRenderRatio = max(0.25, min(4.0, format.deviceSampleRate / targetSampleRate))
        } else {
            inputToRenderRatio = 1.0
        }

        let ringFrames = max(captureBlockFrames * 128, Int(format.deviceSampleRate * 1.0))
        let ring = StereoInputRingBuffer(capacityFrames: ringFrames)
        inputRing = ring
        inputPrefillFrames = max(captureBlockFrames * 12, 4096)
        // Time-based floor on buffered frames so small block sizes still
        // get enough cushion to absorb scheduling jitter. 100 ms at the
        // input rate ≈ 19 200 frames at 192 kHz; gives ~37 callbacks
        // worth of headroom at block=512 (matches the headroom
        // block=2048 had before the time-based floor was added).
        let timeBasedTargetFloor = Int(format.deviceSampleRate * 0.100)
        inputTargetBufferedFrames = max(
            inputPrefillFrames * 2,
            captureBlockFrames * 24,
            timeBasedTargetFloor
        )
        inputBufferedDeadbandFrames = max(captureBlockFrames * 4, 1024)
        inputPrimeThresholdFrames = max(
            inputPrefillFrames,
            inputTargetBufferedFrames - inputBufferedDeadbandFrames
        )
        inputPrimed = false
        self.inputAU = inputAU

        // One-shot diagnostic: warn (don't fail) if no AUHAL frame
        // has arrived within 2 s of start. Surfaces "Transport:
        // Running but ring stays at 0" silent stalls in Console.app
        // — same diagnostic the prior AVAudioEngine path emitted.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            if !firstFrameLogged.load(ordering: .acquiring) {
                captureLog.warning("2s after start, AUHAL input has NOT delivered a frame. Likely causes: virtual-device with no upstream producer (BlackHole), sleeping mic, missing TCC entitlement.")
            } else {
                captureLog.info("2s after start, AUHAL input is delivering normally.")
            }
        }
    }

    /// Frame-sink for the AUHAL input callback. RT-safe: no
    /// allocations, no locks, no Obj-C runtime, no logging on the
    /// hot path. Counterpart to the prior `pushInputBufferToRing`
    /// fast-path; the AUHAL client format is fixed at planar
    /// Float32 / 2 channels / device sample rate, so all the Int16
    /// / Int32 / interleaved conversion paths the AVAudioEngine tap
    /// needed are gone.
    private func handleInputAUHALFrames(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0, let ring = inputRing else { return }
        captureCallbackCount += 1
        captureFrameCount += UInt64(frameCount)
        captureFrameCounter += frameCount
        let throttled = meteringEnabled
            && ((captureFrameCounter % Self.meterUpdateIntervalFrames) < frameCount)
        let captureInputScope =
            throttled && inputScopeCaptureEnabled.load(ordering: .relaxed)
        ring.write(left: left, right: right, frameCount: frameCount)
        if throttled {
            let meter = Self.computeStereoLevels(
                left: left, right: right, frameCount: frameCount)
            updateInputMeters(
                inputRMS: meter.rms,
                inputPeak: meter.peak,
                inputLeftRMS: meter.leftRMS,
                inputRightRMS: meter.rightRMS,
                inputLeftPeak: meter.leftPeak,
                inputRightPeak: meter.rightPeak
            )
            if captureInputScope {
                updateInputScopeSnapshot(
                    left: left, right: right, frameCount: frameCount)
            }
        }
    }

    private func ensureMicrophoneAuthorization() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        captureLog.info("microphone authorization status=\(String(describing: status), privacy: .public)")
        switch status {
        case .authorized:
            return
        case .denied, .restricted:
            throw AudioEngineError.inputPermissionDenied
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            let granted = ManagedAtomic<Bool>(false)
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted.store(ok, ordering: .releasing)
                semaphore.signal()
            }
            semaphore.wait()
            let ok = granted.load(ordering: .acquiring)
            captureLog.info("microphone authorization request returned granted=\(ok, privacy: .public)")
            if !ok {
                throw AudioEngineError.inputPermissionDenied
            }
        @unknown default:
            throw AudioEngineError.inputPermissionDenied
        }
    }

    /// Largest render-block frame count seen since engine start. Safe to
    /// read from any thread; updated lock-free on the render path.
    var maxObservedRenderFrameCount: Int {
        maxObservedRenderFrames.load(ordering: .relaxed)
    }

    /// Lock-free monotonic max-tracking of the render block size, so an
    /// under-sized pre-allocation is diagnosable without touching the
    /// fast-path. Called on the render thread.
    @inline(__always)
    private func recordObservedRenderFrames(_ frames: Int) {
        var current = maxObservedRenderFrames.load(ordering: .relaxed)
        while frames > current {
            let (exchanged, original) = maxObservedRenderFrames.compareExchange(
                expected: current, desired: frames, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }

    private func ensureMonitorScratchCapacity(frames: Int) {
        guard frames > 0 else { return }
        recordObservedRenderFrames(frames)
        guard monitorMPXLeftScratch.count < frames || monitorMPXRightScratch.count < frames
        else { return }
        // preAllocateBuffers(maxFrames:) sizes these to ~100 ms of audio at
        // engine start -- far above any real CoreAudio block -- so this
        // branch is meant to be unreachable. Reaching it means we are about
        // to allocate on the render thread. Trap in debug so an under-sized
        // pre-allocation is fixed at the source; in release, grow once as a
        // graceful fallback (a single malloc beats glitching the monitor
        // block) -- maxObservedRenderFrameCount surfaces that it happened.
        assertionFailure(
            "render-thread monitor scratch grow: frames=\(frames) "
            + "cap=\(monitorMPXLeftScratch.count); raise preAllocateBuffers")
        if monitorMPXLeftScratch.count < frames {
            monitorMPXLeftScratch = Array(repeating: 0.0, count: frames)
        }
        if monitorMPXRightScratch.count < frames {
            monitorMPXRightScratch = Array(repeating: 0.0, count: frames)
        }
    }

    private func ensureAnalysisScratchCapacity(frames: Int) {
        guard frames > 0 else { return }
        recordObservedRenderFrames(frames)
        guard postAGCLeftScratch.count < frames || postAGCRightScratch.count < frames
            || preMPXLeftScratch.count < frames || preMPXRightScratch.count < frames
        else { return }
        // See ensureMonitorScratchCapacity: meant to be unreachable; debug
        // trap + release-only graceful grow.
        assertionFailure(
            "render-thread analysis scratch grow: frames=\(frames) "
            + "cap=\(postAGCLeftScratch.count); raise preAllocateBuffers")
        if postAGCLeftScratch.count < frames {
            postAGCLeftScratch = Array(repeating: 0.0, count: frames)
        }
        if postAGCRightScratch.count < frames {
            postAGCRightScratch = Array(repeating: 0.0, count: frames)
        }
        if preMPXLeftScratch.count < frames {
            preMPXLeftScratch = Array(repeating: 0.0, count: frames)
        }
        if preMPXRightScratch.count < frames {
            preMPXRightScratch = Array(repeating: 0.0, count: frames)
        }
    }

    private func preAllocateBuffers(maxFrames: Int) {
        let safeFrames = max(512, maxFrames)
        monitorMPXLeftScratch = [Float](repeating: 0.0, count: safeFrames)
        monitorMPXRightScratch = [Float](repeating: 0.0, count: safeFrames)
        postAGCLeftScratch = [Float](repeating: 0.0, count: safeFrames)
        postAGCRightScratch = [Float](repeating: 0.0, count: safeFrames)
        preMPXLeftScratch = [Float](repeating: 0.0, count: safeFrames)
        preMPXRightScratch = [Float](repeating: 0.0, count: safeFrames)
    }

    private func withAnalysisBuffers<R>(
        frames: Int,
        _ body: (MPXGenerator.AnalysisBuffers) -> R
    ) -> R? {
        guard frames > 0 else { return nil }
        ensureAnalysisScratchCapacity(frames: frames)
        return postAGCLeftScratch.withUnsafeMutableBufferPointer { postL in
            postAGCRightScratch.withUnsafeMutableBufferPointer { postR in
                preMPXLeftScratch.withUnsafeMutableBufferPointer { preL in
                    preMPXRightScratch.withUnsafeMutableBufferPointer { preR in
                        guard let postLeft = postL.baseAddress,
                            let postRight = postR.baseAddress,
                            let preLeft = preL.baseAddress,
                            let preRight = preR.baseAddress
                        else {
                            return nil
                        }
                        return body(
                            MPXGenerator.AnalysisBuffers(
                                postAGCLeft: postLeft,
                                postAGCRight: postRight,
                                preMPXLeft: preLeft,
                                preMPXRight: preRight
                            )
                        )
                    }
                }
            }
        }
    }

    private func withOptionalAnalysisBuffers(
        frames: Int,
        enabled: Bool,
        _ body: (MPXGenerator.AnalysisBuffers) -> Void
    ) {
        if enabled {
            _ = withAnalysisBuffers(frames: frames, body)
        } else {
            body(.none)
        }
    }

    private func appendRoutingNote(_ note: String) {
        if let current = routingNote, !current.isEmpty {
            routingNote = current + " " + note
        } else {
            routingNote = note
        }
    }

    private func setCurrentDevice(_ deviceID: AudioDeviceID, for node: AVAudioIONode, role: String)
        throws {
        guard let audioUnit = node.audioUnit else {
            throw AudioEngineError.deviceSelectionFailed("\(role) audio unit unavailable")
        }
        var mutableID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            size
        )
        if status != noErr {
            let be = UInt32(bitPattern: status)
            let c1 = Character(UnicodeScalar(UInt8((be >> 24) & 0xFF)))
            let c2 = Character(UnicodeScalar(UInt8((be >> 16) & 0xFF)))
            let c3 = Character(UnicodeScalar(UInt8((be >> 8) & 0xFF)))
            let c4 = Character(UnicodeScalar(UInt8(be & 0xFF)))
            throw AudioEngineError.deviceSelectionFailed(
                "\(role) device set failed status=\(status) fourcc=\(c1)\(c2)\(c3)\(c4)"
            )
        }
    }

    var hardwareSampleRate: Double {
        engine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    var hardwareChannels: Int {
        Int(engine.outputNode.outputFormat(forBus: 0).channelCount)
    }

    var blockSize: Int {
        requestedBlockSize
    }

    var renderSampleRate: Double {
        configuredRenderSampleRate > 0 ? configuredRenderSampleRate : requestedSampleRate
    }

    var inputSampleRate: Double? {
        configuredInputSampleRate
    }

    var inputStats: (overflows: UInt64, underflows: UInt64, bufferedFrames: Int)? {
        inputRing?.stats()
    }

    var inputTargetFrames: Int {
        inputTargetBufferedFrames
    }

    var inputPrimeFrames: Int {
        inputPrimeThresholdFrames
    }

    var liveRuntimeApplyCount: UInt64 {
        runtimeConfigApplyCount.load(ordering: .relaxed)
    }

    var skippedRuntimeApplyCount: UInt64 {
        runtimeConfigSkipCount.load(ordering: .relaxed)
    }

    func setMeteringEnabled(_ enabled: Bool) {
        meteringEnabled = enabled
    }

    func setAnalysisCapture(
        inputScope: Bool,
        outputHistory: Bool,
        preMPXHistory: Bool,
        outputImageMetrics: Bool
    ) {
        inputScopeCaptureEnabled.store(inputScope, ordering: .relaxed)
        outputHistoryCaptureEnabled.store(outputHistory, ordering: .relaxed)
        preMPXHistoryCaptureEnabled.store(preMPXHistory, ordering: .relaxed)
        outputImageMetricsEnabled.store(outputImageMetrics, ordering: .relaxed)
    }

    func applyRuntimeConfig(_ config: AppConfig) {
        // The monitor first, and OUTSIDE the equality early-return below: its
        // settings are not part of the DSP runtime config, and starting or
        // stopping a second audio device is caller-thread work, never render
        // work. The transmitter engine is untouched either way.
        applyMonitorSettings(config)
        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        runtimeConfigLock.lock()
        if lastQueuedRuntimeConfig == runtime {
            runtimeConfigSkipCount.wrappingIncrement(by: 1, ordering: .relaxed)
            runtimeConfigLock.unlock()
            return
        }
        pendingRuntimeConfig = runtime
        lastQueuedRuntimeConfig = runtime
        runtimeConfigPending.store(true, ordering: .relaxed)
        runtimeConfigLock.unlock()
    }

    var currentRDSLiveSnapshot: BasicRDSCoder.LiveSnapshot? {
        generator.currentRDSLiveSnapshot()
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

    /// The shared (anonymous) reader's meters. Consumers that read
    /// repeatedly pass their own `MeterPeakReader` to `meters(for:)`, so the
    /// GUI tick and a web meter stream do not take each other's peaks.
    var meters: MeterSnapshot { meters(for: .shared) }

    func meters(for reader: MeterPeakReader) -> MeterSnapshot {
        meterLock.lock()
        defer { meterLock.unlock() }
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let take = peakReaders.take(reader, now: nowUptime)
        var hold = take.claimedNow ? PeakHold() : peakHolds[take.slot]
        // Elapsed time since this reader's last read, so the hold decays by
        // wall clock whatever the caller's rate. The old 1 s clamp made a
        // client polling every 15 s see the held peak fall 6.6 dB PER POLL --
        // a tone that had stepped from -24 to -60 dBFS read -31, -38, -44
        // over 45 s on the Intel box. A long gap now decays the hold to
        // nothing, which is what a peak hold means after 15 s.
        let dt = max(0.0, min(60.0, nowUptime - (hold.lastReadUptime ?? (nowUptime - 0.2))))
        hold.lastReadUptime = nowUptime
        // Keep peak hold decay stable regardless of polling frequency.
        let decayPerSecond: Float = 0.47
        let decayFactor = powf(decayPerSecond, Float(dt))
        func pending(_ channel: PeakChannel) -> Float {
            let v = take.peaks[channel.rawValue]
            return v.isFinite ? max(0.0, v) : 0.0
        }
        func held(_ value: Float, _ live: Float) -> Float {
            let decayed = value.isFinite ? max(0.0, value * decayFactor) : 0.0
            return max(live, decayed)
        }
        let pendingInput = pending(.input)
        let pendingInputLeft = pending(.inputLeft)
        let pendingInputRight = pending(.inputRight)
        let pendingPostAGCLeft = pending(.postAGCLeft)
        let pendingPostAGCRight = pending(.postAGCRight)
        let pendingOutput = pending(.output)
        hold.input = held(hold.input, pendingInput)
        hold.inputLeft = held(hold.inputLeft, pendingInputLeft)
        hold.inputRight = held(hold.inputRight, pendingInputRight)
        hold.postAGCLeft = held(hold.postAGCLeft, pendingPostAGCLeft)
        hold.postAGCRight = held(hold.postAGCRight, pendingPostAGCRight)
        hold.output = held(hold.output, pendingOutput)
        peakHolds[take.slot] = hold

        var snapshot = meterSnapshot
        snapshot.inputRMS = snapshot.inputRMS.isFinite ? max(0.0, snapshot.inputRMS) : 0.0
        snapshot.inputLeftRMS = snapshot.inputLeftRMS.isFinite ? max(0.0, snapshot.inputLeftRMS) : 0.0
        snapshot.inputRightRMS = snapshot.inputRightRMS.isFinite ? max(0.0, snapshot.inputRightRMS) : 0.0
        snapshot.postAGCLeftRMS =
            snapshot.postAGCLeftRMS.isFinite ? max(0.0, snapshot.postAGCLeftRMS) : 0.0
        snapshot.postAGCRightRMS =
            snapshot.postAGCRightRMS.isFinite ? max(0.0, snapshot.postAGCRightRMS) : 0.0
        snapshot.outputRMS = snapshot.outputRMS.isFinite ? max(0.0, snapshot.outputRMS) : 0.0
        snapshot.inputPeak = hold.input
        snapshot.inputLeftPeak = hold.inputLeft
        snapshot.inputRightPeak = hold.inputRight
        snapshot.postAGCLeftPeak = hold.postAGCLeft
        snapshot.postAGCRightPeak = hold.postAGCRight
        snapshot.outputPeak = hold.output
        snapshot.deviationKHzPeak = DeviationReadout.kilohertz(
            compositePeak: hold.output, modulationReferenceScale: modulationReferenceScale)
        snapshot.dacPeak = OutputWiring.dacPeak(
            compositePeak: hold.output, lineOutputScale: lineOutputScale)
        snapshot.liveInputPeak = pendingInput
        snapshot.liveInputLeftPeak = pendingInputLeft
        snapshot.liveInputRightPeak = pendingInputRight
        snapshot.livePostAGCLeftPeak = pendingPostAGCLeft
        snapshot.livePostAGCRightPeak = pendingPostAGCRight
        snapshot.liveOutputPeak = pendingOutput
        snapshot.liveOutputLeftPeak = pending(.outputLeft)
        snapshot.liveOutputRightPeak = pending(.outputRight)
        snapshot.liveDeviationKHzPeak = DeviationReadout.kilohertz(
            compositePeak: pendingOutput, modulationReferenceScale: modulationReferenceScale)
        return snapshot
    }

    var captureStats: (callbacks: UInt64, frames: UInt64) {
        meterLock.lock()
        let cbs = captureCallbackCount
        let fr = captureFrameCount
        meterLock.unlock()
        return (cbs, fr)
    }

    var scopeSnapshot: (inputLeft: [Float], inputRight: [Float], output: [Float]) {
        scopeSnapshot(windowMS: 20.0)
    }

    func scopeSnapshot(windowMS: Double) -> (inputLeft: [Float], inputRight: [Float], output: [Float]) {
        meterLock.lock()
        let inputLeft = Self.renderScopeWindow(
            from: inputScopeLeftHistory,
            writeIndex: inputScopeWriteIndex,
            validFrames: inputScopeValidFrames,
            sampleRate: inputScopeSampleRate,
            windowMS: windowMS
        )
        let inputRight = Self.renderScopeWindow(
            from: inputScopeRightHistory,
            writeIndex: inputScopeWriteIndex,
            validFrames: inputScopeValidFrames,
            sampleRate: inputScopeSampleRate,
            windowMS: windowMS
        )
        let output = Self.renderScopeWindow(
            from: outputScopeHistory,
            writeIndex: outputScopeWriteIndex,
            validFrames: outputScopeValidFrames,
            sampleRate: outputScopeSampleRate,
            windowMS: windowMS
        )
        meterLock.unlock()
        return (inputLeft, inputRight, output)
    }

    func outputSignalWindow(into destination: inout [Float], frameCount: Int) -> (count: Int, sampleRate: Double) {
        meterLock.lock()
        let sr = max(1_000.0, outputScopeSampleRate)
        let count = Self.renderRawWindow(
            from: outputScopeHistory,
            writeIndex: outputScopeWriteIndex,
            validFrames: outputScopeValidFrames,
            frameCount: frameCount,
            into: &destination
        )
        meterLock.unlock()
        return (count, sr)
    }

    func inputStereoWindow(
        intoLeft leftDestination: inout [Float],
        right rightDestination: inout [Float],
        frameCount: Int
    ) -> (count: Int, sampleRate: Double) {
        meterLock.lock()
        let sr = max(1_000.0, inputScopeSampleRate)
        let count = Self.renderRawWindow(
            from: inputScopeLeftHistory,
            writeIndex: inputScopeWriteIndex,
            validFrames: inputScopeValidFrames,
            frameCount: frameCount,
            into: &leftDestination
        )
        _ = Self.renderRawWindow(
            from: inputScopeRightHistory,
            writeIndex: inputScopeWriteIndex,
            validFrames: inputScopeValidFrames,
            frameCount: count,
            into: &rightDestination
        )
        meterLock.unlock()
        return (count, sr)
    }

    func preMPXStereoWindow(
        intoLeft leftDestination: inout [Float],
        right rightDestination: inout [Float],
        frameCount: Int
    ) -> (count: Int, sampleRate: Double) {
        meterLock.lock()
        let sr = max(1_000.0, preMPXSampleRate)
        let count = Self.renderRawWindow(
            from: preMPXLeftHistory,
            writeIndex: preMPXWriteIndex,
            validFrames: preMPXValidFrames,
            frameCount: frameCount,
            into: &leftDestination
        )
        _ = Self.renderRawWindow(
            from: preMPXRightHistory,
            writeIndex: preMPXWriteIndex,
            validFrames: preMPXValidFrames,
            frameCount: count,
            into: &rightDestination
        )
        meterLock.unlock()
        return (count, sr)
    }

    var sourceDescription: String {
        useInputSource ? "input" : "tone"
    }

    var deviceRoutingNote: String? {
        routingNote
    }

    var transportSnapshot: InputTransportSnapshot? {
        guard let snapshot = inputRing?.transportSnapshot() else { return nil }
        return InputTransportSnapshot(
            overflows: snapshot.overflows,
            underflows: snapshot.underflows,
            tornReads: snapshot.tornReads,
            bufferedFrames: snapshot.bufferedFrames,
            resampleMode: snapshot.resampleMode,
            ratioTrim: snapshot.ratioTrim,
            sampleStep: snapshot.sampleStep
        )
    }

    private func updateInputMeters(
        inputRMS: Float,
        inputPeak: Float,
        inputLeftRMS: Float,
        inputRightRMS: Float,
        inputLeftPeak: Float,
        inputRightPeak: Float
    ) {
        meterSnapshot.inputRMS = inputRMS.isFinite ? max(0.0, inputRMS) : 0.0
        meterSnapshot.inputLeftRMS = inputLeftRMS.isFinite ? max(0.0, inputLeftRMS) : 0.0
        meterSnapshot.inputRightRMS = inputRightRMS.isFinite ? max(0.0, inputRightRMS) : 0.0
        let safePeak = inputPeak.isFinite ? max(0.0, inputPeak) : 0.0
        let safeLeftPeak = inputLeftPeak.isFinite ? max(0.0, inputLeftPeak) : 0.0
        let safeRightPeak = inputRightPeak.isFinite ? max(0.0, inputRightPeak) : 0.0
        peakReaders.record(channel: PeakChannel.input.rawValue, peak: safePeak)
        peakReaders.record(channel: PeakChannel.inputLeft.rawValue, peak: safeLeftPeak)
        peakReaders.record(channel: PeakChannel.inputRight.rawValue, peak: safeRightPeak)
    }

    private func updatePostAGCMeters(
        leftRMS: Float,
        rightRMS: Float,
        leftPeak: Float,
        rightPeak: Float
    ) {
        meterSnapshot.postAGCLeftRMS = leftRMS.isFinite ? max(0.0, leftRMS) : 0.0
        meterSnapshot.postAGCRightRMS = rightRMS.isFinite ? max(0.0, rightRMS) : 0.0
        let safeLeftPeak = leftPeak.isFinite ? max(0.0, leftPeak) : 0.0
        let safeRightPeak = rightPeak.isFinite ? max(0.0, rightPeak) : 0.0
        peakReaders.record(channel: PeakChannel.postAGCLeft.rawValue, peak: safeLeftPeak)
        peakReaders.record(channel: PeakChannel.postAGCRight.rawValue, peak: safeRightPeak)
    }

    private func updateThrottledRenderAnalysis(
        outputLeft: UnsafePointer<Float>,
        outputRight: UnsafePointer<Float>,
        frameCount: Int,
        analysis: MPXGenerator.AnalysisBuffers,
        captureOutputImageMetrics: Bool,
        captureOutputHistory: Bool,
        capturePreMPXHistory: Bool
    ) {
        let outMeter = Self.computeStereoLevels(
            left: outputLeft,
            right: outputRight,
            frameCount: frameCount
        )
        if let postAGCLeft = analysis.postAGCLeft,
            let postAGCRight = analysis.postAGCRight {
            let agcMeter = Self.computeStereoLevels(
                left: postAGCLeft,
                right: postAGCRight,
                frameCount: frameCount
            )
            updatePostAGCMeters(
                leftRMS: agcMeter.leftRMS,
                rightRMS: agcMeter.rightRMS,
                leftPeak: agcMeter.leftPeak,
                rightPeak: agcMeter.rightPeak
            )
        }
        updateOutputMeters(
            outputRMS: outMeter.rms, outputPeak: outMeter.peak,
            leftPeak: outMeter.leftPeak, rightPeak: outMeter.rightPeak)
        if captureOutputImageMetrics {
            let imageMetrics = Self.computeStereoImageMetrics(
                left: outputLeft,
                right: outputRight,
                frameCount: frameCount,
                leftEnergy: outMeter.leftEnergy,
                rightEnergy: outMeter.rightEnergy
            )
            updateOutputImageMetrics(
                correlation: imageMetrics.correlation,
                sideToMidRatio: imageMetrics.sideToMidRatio
            )
        }
        if captureOutputHistory {
            updateOutputScopeSnapshot(
                left: outputLeft,
                right: outputRight,
                frameCount: frameCount
            )
        }
        if capturePreMPXHistory,
            let preLeft = analysis.preMPXLeft,
            let preRight = analysis.preMPXRight {
            updatePreMPXHistory(
                left: preLeft,
                right: preRight,
                frameCount: frameCount
            )
        }
    }

    private func updateOutputMeters(
        outputRMS: Float, outputPeak: Float, leftPeak: Float, rightPeak: Float
    ) {
        meterSnapshot.outputRMS = outputRMS
        let agc = generator.agcStatus
        let limiter = generator.finalLimiterStatus
        let calibration = generator.compositeCalibrationStatus
        meterSnapshot.agcDetectorDB = agc.detectorDB
        meterSnapshot.agcGainDB = agc.gainDB
        meterSnapshot.agcGateActive = agc.gateActive
        let advDyn = generator.advancedDynamicsStatus
        meterSnapshot.advancedDynamicsActive = advDyn.enabled
        meterSnapshot.advancedDynamicsDensityDB = advDyn.densityDB
        meterSnapshot.adBandGain1DB = advDyn.bandGainsDB.0
        meterSnapshot.adBandGain2DB = advDyn.bandGainsDB.1
        meterSnapshot.adBandGain3DB = advDyn.bandGainsDB.2
        meterSnapshot.adBandGain4DB = advDyn.bandGainsDB.3
        meterSnapshot.adBandGain5DB = advDyn.bandGainsDB.4
        meterSnapshot.compositeClipperGainReductionDB = limiter.gainReductionDB
        meterSnapshot.compositeClipperLookaheadGainReductionDB = limiter.compositeLookaheadGainReductionDB
        meterSnapshot.preEncodeAudioLimiterGainReductionDB = limiter.preEncodeGainReductionDB
        meterSnapshot.mpxSafetyLimiterGainReductionDB = limiter.safetyGainReductionDB
        meterSnapshot.mpxSafetyClipDB = limiter.safetyClipDB
        meterSnapshot.bs412 = generator.bs412Status
        meterSnapshot.nonFiniteInputSamples = generator.nonFiniteInputSampleCount
        meterSnapshot.pilotInjectionPercent = calibration.pilotPercent
        meterSnapshot.rdsInjectionPercent = calibration.rdsPercent
        meterSnapshot.audioCompositePeak = calibration.audioPeak
        meterSnapshot.compositeBudgetMarginDB = calibration.budgetMarginDB
        meterSnapshot.postInjectionOvershoot = calibration.postInjectionOvershoot
        meterSnapshot.compositeOverBudget = calibration.overBudget
        peakReaders.record(channel: PeakChannel.output.rawValue, peak: outputPeak)
        peakReaders.record(channel: PeakChannel.outputLeft.rawValue, peak: leftPeak)
        peakReaders.record(channel: PeakChannel.outputRight.rawValue, peak: rightPeak)
    }

    private func applyPendingRuntimeConfigIfNeeded() {
        guard runtimeConfigPending.load(ordering: .acquiring) else { return }
        // Never block the render thread: if a producer holds the lock
        // mid-write, skip this block. The pending flag stays set, so the
        // apply retries on the next render block (already the "lands within
        // ~one block" semantics).
        guard runtimeConfigLock.lockIfAvailable() else { return }
        let runtime = pendingRuntimeConfig
        pendingRuntimeConfig = nil
        if runtime == lastQueuedRuntimeConfig {
            lastQueuedRuntimeConfig = nil
        }
        runtimeConfigPending.store(false, ordering: .relaxed)
        runtimeConfigLock.unlock()
        if let runtime {
            generator.applyRuntimeConfig(runtime)
            lineOutputScale = OutputWiring.lineOutputScale(
                lineOutputDBFS: runtime.mpxLineOutputDBFS, mode: outputMode)
            modulationReferenceScale = OutputWiring.modulationReferenceScale(
                outputGainDB: runtime.outputGainDB, mode: outputMode)
            // Flip the source-mode branch live. The render callback
            // reads `useInputSource` at the start of each block; this
            // write lands within ~one block of the toggle on the GUI.
            let nextUseInput = runtime.sourceMode.lowercased() == "input"
            // On tone → input transition, drain the input ring back
            // to its prime / target depth. The input tap kept writing
            // to the ring while the tone source was active — without
            // this drain the ring would be at full capacity (red
            // state on the Monitoring buffer-fill bar) the moment the
            // input render path starts pulling, with `targetFrames`
            // worth of stale audio already queued. Snapping to prime
            // depth restores normal ring behaviour immediately.
            if nextUseInput, !useInputSource, let ring = inputRing {
                ring.dropToTargetBufferedFrames(inputPrimeFrames)
            }
            useInputSource = nextUseInput
            runtimeConfigApplyCount.wrappingIncrement(by: 1, ordering: .relaxed)
        }
    }

    private func applyPendingRDSRuntimeConfigIfNeeded() {
        guard rdsRuntimeConfigPending.load(ordering: .acquiring) else { return }
        // Try-lock only; never block the render thread (see
        // applyPendingRuntimeConfigIfNeeded).
        guard runtimeConfigLock.lockIfAvailable() else { return }
        let runtime = pendingRDSRuntimeConfig
        pendingRDSRuntimeConfig = nil
        if runtime == lastQueuedRDSRuntimeConfig {
            lastQueuedRDSRuntimeConfig = nil
        }
        rdsRuntimeConfigPending.store(false, ordering: .relaxed)
        runtimeConfigLock.unlock()
        if let runtime {
            generator.applyRDSRuntimeConfig(runtime)
        }
    }

    private func updateOutputImageMetrics(correlation: Float, sideToMidRatio: Float) {
        meterSnapshot.outputStereoCorrelation =
            correlation.isFinite ? Self.clamp(correlation, -1.0, 1.0) : 0.0
        meterSnapshot.outputSideToMidRatio = sideToMidRatio.isFinite ? max(0.0, sideToMidRatio) : 0.0
    }

    private func updateInputScopeSnapshot(
        left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        appendStereoRawSamples(
            left: left,
            right: right,
            frameCount: frameCount,
            leftHistory: &inputScopeLeftHistory,
            rightHistory: &inputScopeRightHistory,
            writeIndex: &inputScopeWriteIndex,
            validFrames: &inputScopeValidFrames
        )
    }

    private func updateInputScopeSnapshot(mono: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        appendStereoRawSamples(
            left: mono,
            right: mono,
            frameCount: frameCount,
            leftHistory: &inputScopeLeftHistory,
            rightHistory: &inputScopeRightHistory,
            writeIndex: &inputScopeWriteIndex,
            validFrames: &inputScopeValidFrames
        )
    }

    private func updateOutputScopeSnapshot(
        left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        appendStereoScopeSamples(
            left: left,
            right: right,
            frameCount: frameCount,
            into: &outputScopeHistory,
            writeIndex: &outputScopeWriteIndex,
            validFrames: &outputScopeValidFrames
        )
    }

    private func updatePreMPXHistory(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        appendStereoRawSamples(
            left: left,
            right: right,
            frameCount: frameCount,
            leftHistory: &preMPXLeftHistory,
            rightHistory: &preMPXRightHistory,
            writeIndex: &preMPXWriteIndex,
            validFrames: &preMPXValidFrames
        )
    }

    private func configureScopeHistory(renderRate: Double, inputRate: Double?) {
        let safeRenderRate = max(1_000.0, renderRate)
        let safeInputRate = max(1_000.0, inputRate ?? renderRate)
        let outputCapacity = max(
            Self.scopeSampleCount * 8, Int((safeRenderRate * Self.scopeHistorySeconds).rounded()))
        let preMPXCapacity = max(Self.scopeSampleCount * 8, Self.preMPXHistoryFrameCount)
        let inputCapacity = max(
            Self.scopeSampleCount * 8, Int((safeInputRate * Self.scopeHistorySeconds).rounded()))

        meterLock.lock()
        outputScopeHistory = Array(repeating: 0.0, count: outputCapacity)
        outputScopeWriteIndex = 0
        outputScopeValidFrames = 0
        outputScopeSampleRate = safeRenderRate
        preMPXLeftHistory = Array(repeating: 0.0, count: preMPXCapacity)
        preMPXRightHistory = Array(repeating: 0.0, count: preMPXCapacity)
        preMPXWriteIndex = 0
        preMPXValidFrames = 0
        preMPXSampleRate = safeRenderRate

        inputScopeLeftHistory = Array(repeating: 0.0, count: inputCapacity)
        inputScopeRightHistory = Array(repeating: 0.0, count: inputCapacity)
        inputScopeWriteIndex = 0
        inputScopeValidFrames = 0
        inputScopeSampleRate = safeInputRate
        meterLock.unlock()
    }

    private func appendStereoScopeSamples(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        into history: inout [Float],
        writeIndex: inout Int,
        validFrames: inout Int
    ) {
        guard !history.isEmpty, frameCount > 0 else { return }
        var low: Float = -1.0
        var high: Float = 1.0
        var half: Float = 0.5
        var remaining = frameCount
        var sourceOffset = 0
        var idx = writeIndex
        let historyCount = history.count
        history.withUnsafeMutableBufferPointer { buffer in
            guard let destination = buffer.baseAddress else { return }
            while remaining > 0 {
                let chunk = min(remaining, historyCount - idx)
                let out = destination.advanced(by: idx)
                vDSP_vadd(
                    left.advanced(by: sourceOffset),
                    1,
                    right.advanced(by: sourceOffset),
                    1,
                    out,
                    1,
                    vDSP_Length(chunk)
                )
                vDSP_vsmul(out, 1, &half, out, 1, vDSP_Length(chunk))
                vDSP_vclip(out, 1, &low, &high, out, 1, vDSP_Length(chunk))
                idx = (idx + chunk) % historyCount
                sourceOffset += chunk
                remaining -= chunk
            }
        }
        writeIndex = idx
        validFrames = min(historyCount, validFrames + frameCount)
    }

    private func appendStereoRawSamples(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        leftHistory: inout [Float],
        rightHistory: inout [Float],
        writeIndex: inout Int,
        validFrames: inout Int
    ) {
        guard !leftHistory.isEmpty, leftHistory.count == rightHistory.count, frameCount > 0 else { return }
        var low: Float = -1.0
        var high: Float = 1.0
        var remaining = frameCount
        var sourceOffset = 0
        var idx = writeIndex
        let historyCount = leftHistory.count
        leftHistory.withUnsafeMutableBufferPointer { leftBuffer in
            rightHistory.withUnsafeMutableBufferPointer { rightBuffer in
                guard let leftDestination = leftBuffer.baseAddress,
                    let rightDestination = rightBuffer.baseAddress
                else { return }
                while remaining > 0 {
                    let chunk = min(remaining, historyCount - idx)
                    let leftOut = leftDestination.advanced(by: idx)
                    let rightOut = rightDestination.advanced(by: idx)
                    leftOut.update(from: left.advanced(by: sourceOffset), count: chunk)
                    rightOut.update(from: right.advanced(by: sourceOffset), count: chunk)
                    vDSP_vclip(leftOut, 1, &low, &high, leftOut, 1, vDSP_Length(chunk))
                    vDSP_vclip(rightOut, 1, &low, &high, rightOut, 1, vDSP_Length(chunk))
                    idx = (idx + chunk) % historyCount
                    sourceOffset += chunk
                    remaining -= chunk
                }
            }
        }
        writeIndex = idx
        validFrames = min(historyCount, validFrames + frameCount)
    }

    private static func renderScopeWindow(
        from history: [Float],
        writeIndex: Int,
        validFrames: Int,
        sampleRate: Double,
        windowMS: Double
    ) -> [Float] {
        guard !history.isEmpty, validFrames > 1 else {
            return Array(repeating: 0.0, count: scopeSampleCount)
        }

        let sr = max(1_000.0, sampleRate)
        let clampedWindowMS = max(1.0, min(250.0, windowMS))
        let requestedFrames = Int(((clampedWindowMS / 1000.0) * sr).rounded())
        let windowFrames = max(scopeSampleCount, min(validFrames, requestedFrames))
        let historyCount = history.count
        let windowStart = (writeIndex - windowFrames + historyCount) % historyCount

        var output = Array(repeating: Float.zero, count: scopeSampleCount)
        output.withUnsafeMutableBufferPointer { outputBuffer in
            guard let outputBase = outputBuffer.baseAddress else { return }
            history.withUnsafeBufferPointer { historyBuffer in
                guard let historyBase = historyBuffer.baseAddress else { return }
                var start = 0
                for bucket in 0..<scopeSampleCount {
                    let next = max(start + 1, ((bucket + 1) * windowFrames) / scopeSampleCount)
                    let length = min(windowFrames, next) - start
                    outputBase[bucket] = representativeSample(
                        from: historyBase,
                        historyCount: historyCount,
                        start: (windowStart + start) % historyCount,
                        length: length
                    )
                    start = next
                }
            }
        }
        return output
    }

    private static func representativeSample(
        from history: UnsafePointer<Float>,
        historyCount: Int,
        start: Int,
        length: Int
    ) -> Float {
        guard historyCount > 0, length > 0 else { return 0.0 }
        var representative: Float = 0.0
        var remaining = length
        var idx = start
        while remaining > 0 {
            let chunk = min(remaining, historyCount - idx)
            var samplePointer = history.advanced(by: idx)
            for _ in 0..<chunk {
                let sample = samplePointer.pointee
                if fabsf(sample) > fabsf(representative) {
                    representative = sample
                }
                samplePointer = samplePointer.advanced(by: 1)
            }
            remaining -= chunk
            idx = 0
        }
        return representative
    }

    private static func renderRawWindow(
        from history: [Float],
        writeIndex: Int,
        validFrames: Int,
        frameCount: Int,
        into destination: inout [Float]
    ) -> Int {
        guard !history.isEmpty, validFrames > 0, frameCount > 0 else {
            destination.removeAll(keepingCapacity: true)
            return 0
        }
        let n = max(1, min(validFrames, frameCount))
        if destination.count != n {
            destination = Array(repeating: 0.0, count: n)
        }
        let start = (writeIndex - n + history.count) % history.count
        let historyCount = history.count
        let firstChunk = min(n, historyCount - start)
        destination.withUnsafeMutableBufferPointer { destinationBuffer in
            guard let destinationBase = destinationBuffer.baseAddress else { return }
            history.withUnsafeBufferPointer { historyBuffer in
                guard let historyBase = historyBuffer.baseAddress else { return }
                destinationBase.update(from: historyBase.advanced(by: start), count: firstChunk)
                if firstChunk < n {
                    destinationBase.advanced(by: firstChunk).update(
                        from: historyBase,
                        count: n - firstChunk
                    )
                }
            }
        }
        return n
    }

    private static func computeStereoMeter(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) -> (
        rms: Float,
        peak: Float,
        leftRMS: Float,
        rightRMS: Float,
        leftPeak: Float,
        rightPeak: Float,
        correlation: Float,
        sideToMidRatio: Float
    ) {
        let levels = computeStereoLevels(left: left, right: right, frameCount: frameCount)
        let imageMetrics = computeStereoImageMetrics(
            left: left,
            right: right,
            frameCount: frameCount,
            leftEnergy: levels.leftEnergy,
            rightEnergy: levels.rightEnergy
        )
        return (
            levels.rms,
            levels.peak,
            levels.leftRMS,
            levels.rightRMS,
            levels.leftPeak,
            levels.rightPeak,
            imageMetrics.correlation,
            imageMetrics.sideToMidRatio
        )
    }

    private static func computeStereoLevels(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) -> (
        rms: Float,
        peak: Float,
        leftRMS: Float,
        rightRMS: Float,
        leftPeak: Float,
        rightPeak: Float,
        leftEnergy: Float,
        rightEnergy: Float
    ) {
        guard frameCount > 0 else { return (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) }

        var sumL: Float = 0.0
        var sumR: Float = 0.0
        var peakL: Float = 0.0
        var peakR: Float = 0.0

        vDSP_svesq(left, 1, &sumL, vDSP_Length(frameCount))
        vDSP_svesq(right, 1, &sumR, vDSP_Length(frameCount))
        vDSP_maxmgv(left, 1, &peakL, vDSP_Length(frameCount))
        vDSP_maxmgv(right, 1, &peakR, vDSP_Length(frameCount))

        let rmsL = sqrtf(sumL / Float(frameCount))
        let rmsR = sqrtf(sumR / Float(frameCount))
        return (
            sqrtf((rmsL * rmsL + rmsR * rmsR) * 0.5),
            max(peakL, peakR),
            rmsL,
            rmsR,
            peakL,
            peakR,
            sumL,
            sumR
        )
    }

    private static func computeStereoImageMetrics(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        leftEnergy: Float,
        rightEnergy: Float
    ) -> (correlation: Float, sideToMidRatio: Float) {
        guard frameCount > 0 else { return (0.0, 0.0) }

        var dotLR: Float = 0.0

        vDSP_dotpr(left, 1, right, 1, &dotLR, vDSP_Length(frameCount))
        let totalEnergy = leftEnergy + rightEnergy
        let midEnergy = max(0.0, 0.25 * (totalEnergy + (2.0 * dotLR)))
        let sideEnergy = max(0.0, 0.25 * (totalEnergy - (2.0 * dotLR)))

        return (
            dotLR / max(1e-9, sqrtf(leftEnergy * rightEnergy)),
            sqrtf(sideEnergy / max(1e-9, midEnergy))
        )
    }

    @inline(__always)
    private static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        return max(lo, min(hi, x))
    }

    private static func computeMonoMeter(
        samples: UnsafePointer<Float>,
        frameCount: Int
    ) -> (rms: Float, peak: Float) {
        guard frameCount > 0 else { return (0.0, 0.0) }

        var sum: Float = 0.0
        var peak: Float = 0.0

        vDSP_svesq(samples, 1, &sum, vDSP_Length(frameCount))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameCount))

        return (sqrtf(sum / Float(frameCount)), peak)
    }

    private static func clearBuffers(
        _ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard frameCount > 0 else { return }
        if buffers.count >= 2 {
            // Every planar buffer: two on the stereo path, the device's full
            // channel count on the multichannel path.
            for i in 0..<buffers.count {
                if let data = buffers[i].mData?.assumingMemoryBound(to: Float.self) {
                    vDSP_vclr(data, 1, vDSP_Length(frameCount))
                }
            }
            return
        }
        if buffers.count == 1,
            let mono = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            vDSP_vclr(mono, 1, vDSP_Length(frameCount * 2))
        }
    }

    private static func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        return max(lo, min(hi, x))
    }
}

#endif  // os(macOS)
