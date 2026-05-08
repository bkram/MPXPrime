import AVFoundation
import AudioToolbox
import Foundation
import Accelerate
import Atomics
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
}

final class AudioOutputEngine {
    private static let scopeSampleCount = 128
    private static let scopeHistorySeconds: Double = 0.25
    static let preMPXSpectrumFrameCount = 4096
    private static let preMPXHistoryFrameCount = preMPXSpectrumFrameCount * 2
    private static let meterUpdateIntervalFrames: Int = 512

    struct InputTransportSnapshot {
        let overflows: UInt64
        let underflows: UInt64
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
        var liveInputPeak: Float
        var liveInputLeftPeak: Float
        var liveInputRightPeak: Float
        var livePostAGCLeftPeak: Float
        var livePostAGCRightPeak: Float
        var liveOutputPeak: Float
        var liveDeviationKHzPeak: Float
        var agcDetectorDB: Float
        var agcGainDB: Float
        var agcGateActive: Bool
        var compositeClipperGainReductionDB: Float
        var preEncodeAudioLimiterGainReductionDB: Float
        var mpxSafetyLimiterGainReductionDB: Float
        var pilotInjectionPercent: Float
        var rdsInjectionPercent: Float
        var audioCompositePeak: Float
        var compositeBudgetMarginDB: Float
        var outputStereoCorrelation: Float
        var outputSideToMidRatio: Float
    }

    private let engine = AVAudioEngine()
    private var captureEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private let generator: MPXGenerator
    private let useInputSource: Bool
    private let requestedSampleRate: Double
    private let requestedBlockSize: Int
    private let requestedInputDeviceID: AudioDeviceID?
    private let requestedOutputDeviceID: AudioDeviceID?
    private let outputMode: AudioOutputMode
    private var targetDeviationKHz: Float
    private var configuredRenderSampleRate: Double = 0.0
    private var inputRing: StereoInputRingBuffer?
    private var captureTapInstalled = false
    private var configuredInputSampleRate: Double?
    private var inputToRenderRatio: Double = 1.0
    private var inputPrefillFrames = 0
    private var inputPrimeThresholdFrames = 0
    private var inputPrimed = false
    private var inputTargetBufferedFrames = 0
    private var inputBufferedDeadbandFrames = 0
    private var routingNote: String?
    private var captureCallbackCount: UInt64 = 0
    private var captureFrameCount: UInt64 = 0
    private var captureFrameCounter: Int = 0
    private let meterLock = NSLock()
    private let runtimeConfigLock = NSLock()
    private let runtimeConfigPending = ManagedAtomic<Bool>(false)
    private let rdsRuntimeConfigPending = ManagedAtomic<Bool>(false)
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
        liveInputPeak: 0.0,
        liveInputLeftPeak: 0.0,
        liveInputRightPeak: 0.0,
        livePostAGCLeftPeak: 0.0,
        livePostAGCRightPeak: 0.0,
        liveOutputPeak: 0.0,
        liveDeviationKHzPeak: 0.0,
        agcDetectorDB: -120.0,
        agcGainDB: 0.0,
        agcGateActive: false,
        compositeClipperGainReductionDB: 0.0,
        preEncodeAudioLimiterGainReductionDB: 0.0,
        mpxSafetyLimiterGainReductionDB: 0.0,
        pilotInjectionPercent: 0.0,
        rdsInjectionPercent: 0.0,
        audioCompositePeak: 0.0,
        compositeBudgetMarginDB: 0.0,
        outputStereoCorrelation: 1.0,
        outputSideToMidRatio: 0.0
    )
    private var pendingInputPeak: Float = 0.0
    private var pendingInputLeftPeak: Float = 0.0
    private var pendingInputRightPeak: Float = 0.0
    private var pendingPostAGCLeftPeak: Float = 0.0
    private var pendingPostAGCRightPeak: Float = 0.0
    private var pendingOutputPeak: Float = 0.0
    private var lastMeterReadUptime: TimeInterval?
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
    private var postAGCLeftScratch: [Float] = []
    private var postAGCRightScratch: [Float] = []
    private var preMPXLeftScratch: [Float] = []
    private var preMPXRightScratch: [Float] = []
    private var isShuttingDown = false
    private var frameCounter: Int = 0
    private var meteringEnabled: Bool = true
    private var inputConversionBufferStereoL: [Float] = []
    private var inputConversionBufferStereoR: [Float] = []
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
        outputMode: AudioOutputMode = .mpxComposite
    ) {
        self.generator = generator
        self.useInputSource = config.sourceMode.lowercased() == "input"
        self.requestedSampleRate = config.sampleRate
        self.requestedBlockSize = config.blockSize
        self.requestedInputDeviceID = inputDeviceID
        self.requestedOutputDeviceID = outputDeviceID
        self.outputMode = outputMode
        self.targetDeviationKHz = Float(max(1.0, config.mpxDeviationKHz))
        self.encoderFIREnabled = config.encoderFIREnabled
        self.multibandFIREnabled = config.multibandFIREnabled
    }

    private let encoderFIREnabled: Bool
    private let multibandFIREnabled: Bool

    func start() throws {
        isShuttingDown = false
        meteringEnabled = true
        try applyOutputDeviceSelection()
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let requestedRate = max(8_000.0, requestedSampleRate)
        let renderRate = (outputMode == .monitorAudio) ? requestedRate : outputRate
        if useInputSource {
            try ensureMicrophoneAuthorization()
            try setupInputCapture(targetSampleRate: renderRate)
        }
        if outputMode == .mpxComposite, outputRate < 110_000.0 {
            appendRoutingNote(
                "Output sample rate is too low for stereo MPX. Use a 192 kHz-capable output device."
            )
        }
        if outputMode == .monitorAudio, fabs(outputRate - renderRate) > 1.0 {
            appendRoutingNote(
                "Monitor hardware is \(Int(outputRate.rounded())) Hz; internal MPX render remains \(Int(renderRate.rounded())) Hz."
            )
        }
        configuredRenderSampleRate = renderRate
        generator.setSampleRate(renderRate)
        // TX-grade FIR encoder bandwidth guard only runs in composite output
        // mode; monitor mode keeps the low-latency Butterworth so operator
        // monitoring stays snappy.
        generator.setEncoderFIREnabled(outputMode == .mpxComposite && encoderFIREnabled)
        // Linear-phase FIR multiband crossovers — same TX-only pattern as
        // the encoder FIR. Phase-flat band reconstruction prevents the
        // transient smear / inter-band pumping that makes IIR-LR4
        // multiband sound worse than single-band on percussive content.
        generator.setMultibandFIREnabled(outputMode == .mpxComposite && multibandFIREnabled)
        configureScopeHistory(renderRate: renderRate, inputRate: configuredInputSampleRate)
        preAllocateBuffers(maxFrames: Int(max(renderRate, 192000.0) * 0.1))

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: renderRate,
            channels: 2,
            interleaved: false
        )
        guard let sourceFormat = format else {
            throw AudioEngineError.sourceNodeFormatUnavailable
        }
        let node = AVAudioSourceNode(format: sourceFormat) {
            [weak self] _, _, frameCount, audioBufferList -> OSStatus in
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
            if buffers.count >= 2,
                let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                let rightData = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            {
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
                    self.withOptionalAnalysisBuffers(frames: frames, enabled: needsAnalysisBuffers) { analysis in
                        if self.outputMode == .monitorAudio {
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
                    self.withOptionalAnalysisBuffers(frames: frames, enabled: needsAnalysisBuffers) { analysis in
                        if self.outputMode == .monitorAudio {
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
                return noErr
            }
            if buffers.count == 1,
                let data = buffers[0].mData?.assumingMemoryBound(to: Float.self)
            {
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
        engine.mainMixerNode.outputVolume = 1.0
        sourceNode = node

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
        inputRing = nil
        engine.stop()
        engine.reset()
        if let capture = captureEngine {
            capture.stop()
            if captureTapInstalled {
                capture.inputNode.removeTap(onBus: 0)
                captureTapInstalled = false
            }
            capture.reset()
            captureEngine = nil
        }
        inputPrimed = false
        configuredInputSampleRate = nil
        inputToRenderRatio = 1.0
        sourceNode = nil
        frameCounter = 0
        captureFrameCounter = 0
        meterLock.lock()
        pendingInputPeak = 0.0
        pendingInputLeftPeak = 0.0
        pendingInputRightPeak = 0.0
        pendingPostAGCLeftPeak = 0.0
        pendingPostAGCRightPeak = 0.0
        pendingOutputPeak = 0.0
        lastMeterReadUptime = nil
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
        meterSnapshot.agcDetectorDB = -120.0
        meterSnapshot.agcGainDB = 0.0
        meterSnapshot.agcGateActive = false
        meterSnapshot.compositeClipperGainReductionDB = 0.0
        meterSnapshot.preEncodeAudioLimiterGainReductionDB = 0.0
        meterSnapshot.mpxSafetyLimiterGainReductionDB = 0.0
        meterSnapshot.pilotInjectionPercent = 0.0
        meterSnapshot.rdsInjectionPercent = 0.0
        meterSnapshot.audioCompositePeak = 0.0
        meterSnapshot.compositeBudgetMarginDB = 0.0
        meterSnapshot.outputStereoCorrelation = 1.0
        meterSnapshot.outputSideToMidRatio = 0.0
        meterSnapshot.liveInputPeak = 0.0
        meterSnapshot.liveInputLeftPeak = 0.0
        meterSnapshot.liveInputRightPeak = 0.0
        meterSnapshot.livePostAGCLeftPeak = 0.0
        meterSnapshot.livePostAGCRightPeak = 0.0
        meterSnapshot.liveOutputPeak = 0.0
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
                applyHALBufferSize(deviceID: outputID, role: "output")
            } catch {
                routingNote =
                    "Requested output device could not be opened by AVAudioEngine; using macOS default output."
            }
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
        let capture = AVAudioEngine()
        if let inputID = requestedInputDeviceID {
            try setCurrentDevice(inputID, for: capture.inputNode, role: "input")
            applyHALBufferSize(deviceID: inputID, role: "input")
            captureLog.info("setupInputCapture: setCurrentDevice ok deviceID=\(inputID, privacy: .public)")
        } else {
            captureLog.info("setupInputCapture: no requestedInputDeviceID; using AVAudioEngine default input")
        }
        let inFormat = capture.inputNode.inputFormat(forBus: 0)
        captureLog.info("setupInputCapture: inputFormat sampleRate=\(inFormat.sampleRate, privacy: .public) channels=\(inFormat.channelCount, privacy: .public)")
        if inFormat.channelCount < 1 {
            captureLog.error("setupInputCapture: input format has no channels — throwing inputFormatUnavailable")
            throw AudioEngineError.inputFormatUnavailable
        }
        configuredInputSampleRate = inFormat.sampleRate
        if targetSampleRate > 1.0 {
            inputToRenderRatio = max(0.25, min(4.0, inFormat.sampleRate / targetSampleRate))
        } else {
            inputToRenderRatio = 1.0
        }
        let captureBlockFrames = min(2048, max(256, requestedBlockSize))
        let ringFrames = max(captureBlockFrames * 128, Int(inFormat.sampleRate * 1.0))
        let ring = StereoInputRingBuffer(capacityFrames: ringFrames)
        inputRing = ring
        inputPrefillFrames = max(captureBlockFrames * 12, 4096)
        // Time-based floor on buffered frames so small block sizes still
        // get enough cushion to absorb scheduling jitter. 100 ms at the
        // input rate ≈ 19 200 frames at 192 kHz; gives ~37 callback worth
        // of headroom at block=512 (matches the headroom block=2048 had
        // before the time-based floor was added).
        let timeBasedTargetFloor = Int(inFormat.sampleRate * 0.100)
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
        let tapFormat = inFormat
        let firstTapLogged = ManagedAtomic<Bool>(false)
        capture.inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(captureBlockFrames),
            format: tapFormat
        ) { [weak self] buffer, _ in
            guard let self, let activeRing = self.inputRing else { return }
            if firstTapLogged.compareExchange(
                expected: false, desired: true,
                ordering: .acquiringAndReleasing).exchanged
            {
                let frames = Int(buffer.frameLength)
                var peak: Float = 0
                if let ch = buffer.floatChannelData?[0] {
                    for i in 0..<frames { peak = max(peak, fabsf(ch[i])) }
                }
                captureLog.info("first tap callback frames=\(frames, privacy: .public) peak=\(peak, privacy: .public)")
            }
            self.pushInputBufferToRing(buffer, ring: activeRing)
        }
        captureTapInstalled = true
        captureLog.info("tap installed bufferSize=\(captureBlockFrames, privacy: .public) ringCapacity=\(ringFrames, privacy: .public)")
        do {
            try capture.start()
        } catch {
            captureLog.error("capture.start threw: \(error.localizedDescription, privacy: .public)")
            throw AudioEngineError.engineStartFailed(
                "input capture start failed: \(error.localizedDescription)")
        }
        captureEngine = capture
        captureLog.info("capture.start ok isRunning=\(capture.isRunning, privacy: .public)")
        // One-shot diagnostic: warn (don't fail) if the tap hasn't fired
        // within 2s of capture.start. Surfaces "Transport: Running but ring
        // stays at 0" silent stalls in Console.app for diagnosis without
        // breaking workflows where the source genuinely takes longer to
        // produce (BlackHole waiting for an upstream producer, sleeping mics).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
            if !firstTapLogged.load(ordering: .acquiring) {
                captureLog.warning("2s after start, tap has NOT fired. Likely causes: virtual-device with no upstream producer (BlackHole), sleeping mic, sandboxed-input mismatch.")
            } else {
                captureLog.info("2s after start, tap is delivering normally.")
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

    private func ensureMonitorScratchCapacity(frames: Int) {
        guard frames > 0 else { return }
        if monitorMPXLeftScratch.count < frames {
            monitorMPXLeftScratch = Array(repeating: 0.0, count: frames)
        }
        if monitorMPXRightScratch.count < frames {
            monitorMPXRightScratch = Array(repeating: 0.0, count: frames)
        }
    }

    private func ensureAnalysisScratchCapacity(frames: Int) {
        guard frames > 0 else { return }
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
        inputConversionBufferStereoL = [Float](repeating: 0.0, count: safeFrames)
        inputConversionBufferStereoR = [Float](repeating: 0.0, count: safeFrames)
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

    private func ensureInputConversionCapacity(frames: Int) {
        guard frames > 0 else { return }
        if inputConversionBufferStereoL.count < frames {
            inputConversionBufferStereoL = [Float](repeating: 0.0, count: frames)
        }
        if inputConversionBufferStereoR.count < frames {
            inputConversionBufferStereoR = [Float](repeating: 0.0, count: frames)
        }
    }

    private func processConvertedInput(
        ring: StereoInputRingBuffer,
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        throttled: Bool,
        captureInputScope: Bool
    ) {
        ring.write(left: left, right: right, frameCount: frameCount)
        if throttled {
            let meter = Self.computeStereoLevels(left: left, right: right, frameCount: frameCount)
            updateInputMeters(
                inputRMS: meter.rms,
                inputPeak: meter.peak,
                inputLeftRMS: meter.leftRMS,
                inputRightRMS: meter.rightRMS,
                inputLeftPeak: meter.leftPeak,
                inputRightPeak: meter.rightPeak
            )
            if captureInputScope {
                updateInputScopeSnapshot(left: left, right: right, frameCount: frameCount)
            }
        }
    }

    private func processConvertedMonoInput(
        ring: StereoInputRingBuffer,
        samples: UnsafePointer<Float>,
        frameCount: Int,
        throttled: Bool,
        captureInputScope: Bool
    ) {
        ring.writeMono(mono: samples, frameCount: frameCount)
        if throttled {
            let meter = Self.computeMonoMeter(samples: samples, frameCount: frameCount)
            updateInputMeters(
                inputRMS: meter.rms,
                inputPeak: meter.peak,
                inputLeftRMS: meter.rms,
                inputRightRMS: meter.rms,
                inputLeftPeak: meter.peak,
                inputRightPeak: meter.peak
            )
            if captureInputScope {
                updateInputScopeSnapshot(mono: samples, frameCount: frameCount)
            }
        }
    }

    private func withInputConversionBuffers<R>(frames: Int, _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> R)
        -> R?
    {
        ensureInputConversionCapacity(frames: frames)
        return inputConversionBufferStereoL.withUnsafeMutableBufferPointer { leftBuffer in
            inputConversionBufferStereoR.withUnsafeMutableBufferPointer { rightBuffer in
                guard let left = leftBuffer.baseAddress,
                    let right = rightBuffer.baseAddress
                else {
                    return nil
                }
                return body(left, right)
            }
        }
    }

    private func withInputMonoConversionBuffer<R>(
        frames: Int,
        _ body: (UnsafeMutablePointer<Float>) -> R
    ) -> R?
    {
        ensureInputConversionCapacity(frames: frames)
        return inputConversionBufferStereoL.withUnsafeMutableBufferPointer { buffer in
            guard let samples = buffer.baseAddress else {
                return nil
            }
            return body(samples)
        }
    }

    private func convertInt16ToFloat(
        source: UnsafePointer<Int16>,
        sourceStride: Int,
        frameCount: Int,
        destination: UnsafeMutablePointer<Float>
    ) {
        var scale: Float = 1.0 / 32768.0
        vDSP_vflt16(source, vDSP_Stride(sourceStride), destination, 1, vDSP_Length(frameCount))
        vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(frameCount))
    }

    private func convertInt32ToFloat(
        source: UnsafePointer<Int32>,
        sourceStride: Int,
        frameCount: Int,
        destination: UnsafeMutablePointer<Float>
    ) {
        var scale: Float = 1.0 / 2147483648.0
        vDSP_vflt32(source, vDSP_Stride(sourceStride), destination, 1, vDSP_Length(frameCount))
        vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(frameCount))
    }

    private func convertPlanarInt16ToStereoFloat(
        left sourceLeft: UnsafePointer<Int16>,
        right sourceRight: UnsafePointer<Int16>,
        frameCount: Int,
        destinationLeft: UnsafeMutablePointer<Float>,
        destinationRight: UnsafeMutablePointer<Float>
    ) {
        convertInt16ToFloat(
            source: sourceLeft,
            sourceStride: 1,
            frameCount: frameCount,
            destination: destinationLeft
        )
        convertInt16ToFloat(
            source: sourceRight,
            sourceStride: 1,
            frameCount: frameCount,
            destination: destinationRight
        )
    }

    private func convertPlanarInt32ToStereoFloat(
        left sourceLeft: UnsafePointer<Int32>,
        right sourceRight: UnsafePointer<Int32>,
        frameCount: Int,
        destinationLeft: UnsafeMutablePointer<Float>,
        destinationRight: UnsafeMutablePointer<Float>
    ) {
        convertInt32ToFloat(
            source: sourceLeft,
            sourceStride: 1,
            frameCount: frameCount,
            destination: destinationLeft
        )
        convertInt32ToFloat(
            source: sourceRight,
            sourceStride: 1,
            frameCount: frameCount,
            destination: destinationRight
        )
    }

    private func deinterleaveFloatToStereo(
        interleaved source: UnsafePointer<Float>,
        channelCount: Int,
        frameCount: Int,
        destinationLeft: UnsafeMutablePointer<Float>,
        destinationRight: UnsafeMutablePointer<Float>
    ) {
        var zero: Float = 0.0
        vDSP_vsadd(
            source,
            vDSP_Stride(channelCount),
            &zero,
            destinationLeft,
            1,
            vDSP_Length(frameCount)
        )
        if channelCount >= 2 {
            vDSP_vsadd(
                source.advanced(by: 1),
                vDSP_Stride(channelCount),
                &zero,
                destinationRight,
                1,
                vDSP_Length(frameCount)
            )
        } else {
            vDSP_vsadd(destinationLeft, 1, &zero, destinationRight, 1, vDSP_Length(frameCount))
        }
    }

    private func deinterleaveInt16ToStereoFloat(
        interleaved source: UnsafePointer<Int16>,
        channelCount: Int,
        frameCount: Int,
        destinationLeft: UnsafeMutablePointer<Float>,
        destinationRight: UnsafeMutablePointer<Float>
    ) {
        var scale: Float = 1.0 / 32768.0
        var zero: Float = 0.0
        vDSP_vflt16(source, vDSP_Stride(channelCount), destinationLeft, 1, vDSP_Length(frameCount))
        vDSP_vsmul(destinationLeft, 1, &scale, destinationLeft, 1, vDSP_Length(frameCount))
        if channelCount >= 2 {
            vDSP_vflt16(
                source.advanced(by: 1),
                vDSP_Stride(channelCount),
                destinationRight,
                1,
                vDSP_Length(frameCount)
            )
            vDSP_vsmul(destinationRight, 1, &scale, destinationRight, 1, vDSP_Length(frameCount))
        } else {
            vDSP_vsadd(destinationLeft, 1, &zero, destinationRight, 1, vDSP_Length(frameCount))
        }
    }

    private func deinterleaveInt32ToStereoFloat(
        interleaved source: UnsafePointer<Int32>,
        channelCount: Int,
        frameCount: Int,
        destinationLeft: UnsafeMutablePointer<Float>,
        destinationRight: UnsafeMutablePointer<Float>
    ) {
        var scale: Float = 1.0 / 2147483648.0
        var zero: Float = 0.0
        vDSP_vflt32(source, vDSP_Stride(channelCount), destinationLeft, 1, vDSP_Length(frameCount))
        vDSP_vsmul(destinationLeft, 1, &scale, destinationLeft, 1, vDSP_Length(frameCount))
        if channelCount >= 2 {
            vDSP_vflt32(
                source.advanced(by: 1),
                vDSP_Stride(channelCount),
                destinationRight,
                1,
                vDSP_Length(frameCount)
            )
            vDSP_vsmul(destinationRight, 1, &scale, destinationRight, 1, vDSP_Length(frameCount))
        } else {
            vDSP_vsadd(destinationLeft, 1, &zero, destinationRight, 1, vDSP_Length(frameCount))
        }
    }

    private func appendRoutingNote(_ note: String) {
        if let current = routingNote, !current.isEmpty {
            routingNote = current + " " + note
        } else {
            routingNote = note
        }
    }

    private func pushInputBufferToRing(_ buffer: AVAudioPCMBuffer, ring: StereoInputRingBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        captureCallbackCount += 1
        captureFrameCount += UInt64(frames)
        captureFrameCounter += frames
        let throttled = meteringEnabled && ((captureFrameCounter % Self.meterUpdateIntervalFrames) < frames)
        let captureInputScope =
            throttled && inputScopeCaptureEnabled.load(ordering: .relaxed)
        let chanCount = Int(buffer.format.channelCount)
        let isInterleaved = buffer.format.isInterleaved
        if let channels = buffer.floatChannelData {
            if chanCount >= 2 {
                ring.write(left: channels[0], right: channels[1], frameCount: frames)
                if throttled {
                    let meter = Self.computeStereoLevels(
                        left: channels[0], right: channels[1], frameCount: frames)
                    updateInputMeters(
                        inputRMS: meter.rms,
                        inputPeak: meter.peak,
                        inputLeftRMS: meter.leftRMS,
                        inputRightRMS: meter.rightRMS,
                        inputLeftPeak: meter.leftPeak,
                        inputRightPeak: meter.rightPeak
                    )
                    if captureInputScope {
                        updateInputScopeSnapshot(left: channels[0], right: channels[1], frameCount: frames)
                    }
                }
            } else {
                ring.writeMono(mono: channels[0], frameCount: frames)
                if throttled {
                    let meter = Self.computeMonoMeter(samples: channels[0], frameCount: frames)
                    updateInputMeters(
                        inputRMS: meter.rms,
                        inputPeak: meter.peak,
                        inputLeftRMS: meter.rms,
                        inputRightRMS: meter.rms,
                        inputLeftPeak: meter.peak,
                        inputRightPeak: meter.peak
                    )
                    if captureInputScope {
                        updateInputScopeSnapshot(mono: channels[0], frameCount: frames)
                    }
                }
            }
            return
        }
        if let channels = buffer.int16ChannelData {
            if chanCount >= 2 {
                _ = withInputConversionBuffers(frames: frames) { left, right in
                    convertPlanarInt16ToStereoFloat(
                        left: channels[0],
                        right: channels[1],
                        frameCount: frames,
                        destinationLeft: left,
                        destinationRight: right
                    )
                    processConvertedInput(
                        ring: ring,
                        left: left,
                        right: right,
                        frameCount: frames,
                        throttled: throttled,
                        captureInputScope: captureInputScope
                    )
                }
            } else {
                _ = withInputMonoConversionBuffer(frames: frames) { mono in
                    convertInt16ToFloat(
                        source: channels[0],
                        sourceStride: 1,
                        frameCount: frames,
                        destination: mono
                    )
                    processConvertedMonoInput(
                        ring: ring,
                        samples: mono,
                        frameCount: frames,
                        throttled: throttled,
                        captureInputScope: captureInputScope
                    )
                }
            }
            return
        }
        if let channels = buffer.int32ChannelData {
            if chanCount >= 2 {
                _ = withInputConversionBuffers(frames: frames) { left, right in
                    convertPlanarInt32ToStereoFloat(
                        left: channels[0],
                        right: channels[1],
                        frameCount: frames,
                        destinationLeft: left,
                        destinationRight: right
                    )
                    processConvertedInput(
                        ring: ring,
                        left: left,
                        right: right,
                        frameCount: frames,
                        throttled: throttled,
                        captureInputScope: captureInputScope
                    )
                }
            } else {
                _ = withInputMonoConversionBuffer(frames: frames) { mono in
                    convertInt32ToFloat(
                        source: channels[0],
                        sourceStride: 1,
                        frameCount: frames,
                        destination: mono
                    )
                    processConvertedMonoInput(
                        ring: ring,
                        samples: mono,
                        frameCount: frames,
                        throttled: throttled,
                        captureInputScope: captureInputScope
                    )
                }
            }
            return
        }
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        if isInterleaved, audioBuffers.count == 1, let mData = audioBuffers[0].mData {
            if chanCount == 1 {
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:
                    let mono = mData.assumingMemoryBound(to: Float.self)
                    processConvertedMonoInput(
                        ring: ring,
                        samples: mono,
                        frameCount: frames,
                        throttled: throttled,
                        captureInputScope: captureInputScope
                    )
                case .pcmFormatInt16:
                    _ = withInputMonoConversionBuffer(frames: frames) { mono in
                        convertInt16ToFloat(
                            source: mData.assumingMemoryBound(to: Int16.self),
                            sourceStride: 1,
                            frameCount: frames,
                            destination: mono
                        )
                        processConvertedMonoInput(
                            ring: ring,
                            samples: mono,
                            frameCount: frames,
                            throttled: throttled,
                            captureInputScope: captureInputScope
                        )
                    }
                case .pcmFormatInt32:
                    _ = withInputMonoConversionBuffer(frames: frames) { mono in
                        convertInt32ToFloat(
                            source: mData.assumingMemoryBound(to: Int32.self),
                            sourceStride: 1,
                            frameCount: frames,
                            destination: mono
                        )
                        processConvertedMonoInput(
                            ring: ring,
                            samples: mono,
                            frameCount: frames,
                            throttled: throttled,
                            captureInputScope: captureInputScope
                        )
                    }
                default:
                    return
                }
            } else {
                _ = withInputConversionBuffers(frames: frames) { left, right in
                    switch buffer.format.commonFormat {
                    case .pcmFormatFloat32:
                        deinterleaveFloatToStereo(
                            interleaved: mData.assumingMemoryBound(to: Float.self),
                            channelCount: chanCount,
                            frameCount: frames,
                            destinationLeft: left,
                            destinationRight: right
                        )
                    case .pcmFormatInt16:
                        deinterleaveInt16ToStereoFloat(
                            interleaved: mData.assumingMemoryBound(to: Int16.self),
                            channelCount: chanCount,
                            frameCount: frames,
                            destinationLeft: left,
                            destinationRight: right
                        )
                    case .pcmFormatInt32:
                        deinterleaveInt32ToStereoFloat(
                            interleaved: mData.assumingMemoryBound(to: Int32.self),
                            channelCount: chanCount,
                            frameCount: frames,
                            destinationLeft: left,
                            destinationRight: right
                        )
                    default:
                        return
                    }
                    processConvertedInput(
                        ring: ring,
                        left: left,
                        right: right,
                        frameCount: frames,
                        throttled: throttled,
                        captureInputScope: captureInputScope
                    )
                }
            }
        }
    }

    private func setCurrentDevice(_ deviceID: AudioDeviceID, for node: AVAudioIONode, role: String)
        throws
    {
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
            let c1 = Character(UnicodeScalar((be >> 24) & 0xFF)!)
            let c2 = Character(UnicodeScalar((be >> 16) & 0xFF)!)
            let c3 = Character(UnicodeScalar((be >> 8) & 0xFF)!)
            let c4 = Character(UnicodeScalar(be & 0xFF)!)
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
        let runtime = MPXGenerator.RuntimeConfig(
            inputGainDB: Float(config.inputGainDB),
            outputGainDB: Float(config.outputGainDB),
            finalDriveDB: Float(config.finalDriveDB),
            widebandAGCEnabled: config.widebandAGCEnabled,
            widebandAGCTargetDB: Float(config.widebandAGCTargetDB),
            widebandAGCMaxGainDB: Float(config.widebandAGCMaxGainDB),
            widebandAGCMinGainDB: Float(config.widebandAGCMinGainDB),
            widebandAGCAttackMS: Float(config.widebandAGCAttackMS),
            widebandAGCReleaseMS: Float(config.widebandAGCReleaseMS),
            widebandAGCKWeightingEnabled: config.widebandAGCKWeightingEnabled,
            widebandAGCReleaseProgramDependent: config.widebandAGCReleaseProgramDependent,
            preEncodeAudioLimiterEnabled: config.preEncodeAudioLimiterEnabled,
            mpxDeviationKHz: Float(config.mpxDeviationKHz),
            orbassEnabled: config.orbassEnabled,
            orbassAmount: Float(config.orbassAmount),
            orbassHarmonics: Float(config.orbassHarmonics),
            orbassDrive: Float(config.orbassDrive),
            orbassDensity: Float(config.orbassDensity),
            orbassSubharmonicsEnabled: config.orbassSubharmonicsEnabled,
            orbassSubharmonicsAmount: Float(config.orbassSubharmonicsAmount),
            orbassFreqHz: Float(config.orbassFreqHz),
            stereoWidenEnabled: config.stereoWidenEnabled,
            monoBassEnabled: config.monoBassEnabled,
            monoBassFreqHz: Float(config.monoBassFreqHz),
            widenWidth: Float(config.stereoWidenWidth),
            widenCenter: Float(config.stereoWidenCenter),
            widenMix: Float(config.stereoWidenMix),
            multibandEnabled: config.multibandEnabled,
            multibandMode: config.multibandMode,
            multibandMakeupDB: Float(config.multibandMakeupDB),
            multibandKneeDB: Float(config.multibandKneeDB),
            multibandLinkStrength: Float(config.multibandLinkStrength),
            multibandReleaseProgramDependent: config.multibandReleaseProgramDependent,
            multibandX1Hz: Float(config.multibandX1Hz),
            multibandX2Hz: Float(config.multibandX2Hz),
            multibandX3Hz: Float(config.multibandX3Hz),
            multibandX4Hz: Float(config.multibandX4Hz),
            multibandLowThresholdDB: Float(config.multibandLowThresholdDB),
            multibandMidThresholdDB: Float(config.multibandMidThresholdDB),
            multibandHighThresholdDB: Float(config.multibandHighThresholdDB),
            multibandLowRatio: Float(config.multibandLowRatio),
            multibandMidRatio: Float(config.multibandMidRatio),
            multibandHighRatio: Float(config.multibandHighRatio),
            multibandLowAttackMS: Float(config.multibandLowAttackMS),
            multibandMidAttackMS: Float(config.multibandMidAttackMS),
            multibandHighAttackMS: Float(config.multibandHighAttackMS),
            multibandLowReleaseMS: Float(config.multibandLowReleaseMS),
            multibandMidReleaseMS: Float(config.multibandMidReleaseMS),
            multibandHighReleaseMS: Float(config.multibandHighReleaseMS),
            phaseRotationEnabled: config.phaseRotationEnabled,
            phaseRotationFreqHz: Float(config.phaseRotationFreqHz),
            parametricEQEnabled: config.parametricEQEnabled,
            peqB1FreqHz: Float(config.peqB1FreqHz),
            peqB1GainDB: Float(config.peqB1GainDB),
            peqB2FreqHz: Float(config.peqB2FreqHz),
            peqB2GainDB: Float(config.peqB2GainDB),
            peqB2Q: Float(config.peqB2Q),
            peqB3FreqHz: Float(config.peqB3FreqHz),
            peqB3GainDB: Float(config.peqB3GainDB),
            peqB3Q: Float(config.peqB3Q),
            peqB4FreqHz: Float(config.peqB4FreqHz),
            peqB4GainDB: Float(config.peqB4GainDB),
            multibandLimiterEnabled: config.multibandLimiterEnabled,
            multibandLimiterThresholdDB: Float(config.multibandLimiterThresholdDB),
            multibandLimiterAttackMS: Float(config.multibandLimiterAttackMS),
            multibandLimiterReleaseMS: Float(config.multibandLimiterReleaseMS),
            downwardExpanderEnabled: config.downwardExpanderEnabled,
            expanderThresholdDB: Float(config.expanderThresholdDB),
            expanderRatio: Float(config.expanderRatio),
            expanderAttackMS: Float(config.expanderAttackMS),
            expanderReleaseMS: Float(config.expanderReleaseMS),
            bassClipperEnabled: config.bassClipperEnabled,
            bassClipperCrossoverHz: Float(config.bassClipperCrossoverHz),
            bassClipperThresholdDB: Float(config.bassClipperThresholdDB),
            bassClipperDrive: Float(config.bassClipperDrive),
            dcClipperEnabled: config.dcClipperEnabled,
            dcClipperCeilingDB: Float(config.dcClipperCeilingDB),
            dcClipperCancelFreqHz: Float(config.dcClipperCancelFreqHz),
            bs412Enabled: config.bs412Enabled,
            bs412ThresholdDB: Float(config.bs412ThresholdDB),
            bs412WindowSeconds: Float(config.bs412WindowSeconds),
            compositeClipperEnabled: config.compositeClipperEnabled,
            compositeClipperThresholdDB: Float(config.compositeClipperThresholdDB),
            compositeClipperCeilingDB: Float(config.compositeClipperCeilingDB),
            compositeClipperCancelAudio: config.compositeClipperCancelAudio,
            compositeClipperCancelStereo: config.compositeClipperCancelStereo,
            compositeClipperCancelPilot: config.compositeClipperCancelPilot,
            compositeClipperCancelRDS: config.compositeClipperCancelRDS
        )
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

    var meters: MeterSnapshot {
        meterLock.lock()
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let dt = max(0.0, min(1.0, nowUptime - (lastMeterReadUptime ?? (nowUptime - 0.2))))
        lastMeterReadUptime = nowUptime
        // Keep peak hold decay stable regardless of UI polling frequency.
        let decayPerSecond: Float = 0.47
        let decayFactor = powf(decayPerSecond, Float(dt))
        let pendingInput = pendingInputPeak.isFinite ? max(0.0, pendingInputPeak) : 0.0
        let pendingInputLeft = pendingInputLeftPeak.isFinite ? max(0.0, pendingInputLeftPeak) : 0.0
        let pendingInputRight =
            pendingInputRightPeak.isFinite ? max(0.0, pendingInputRightPeak) : 0.0
        let pendingPostAGCLeft =
            pendingPostAGCLeftPeak.isFinite ? max(0.0, pendingPostAGCLeftPeak) : 0.0
        let pendingPostAGCRight =
            pendingPostAGCRightPeak.isFinite ? max(0.0, pendingPostAGCRightPeak) : 0.0
        let pendingOutput = pendingOutputPeak.isFinite ? max(0.0, pendingOutputPeak) : 0.0
        let decayedInput =
            meterSnapshot.inputPeak.isFinite ? max(0.0, meterSnapshot.inputPeak * decayFactor) : 0.0
        let decayedInputLeft =
            meterSnapshot.inputLeftPeak.isFinite
            ? max(0.0, meterSnapshot.inputLeftPeak * decayFactor) : 0.0
        let decayedInputRight =
            meterSnapshot.inputRightPeak.isFinite
            ? max(0.0, meterSnapshot.inputRightPeak * decayFactor) : 0.0
        let decayedPostAGCLeft =
            meterSnapshot.postAGCLeftPeak.isFinite
            ? max(0.0, meterSnapshot.postAGCLeftPeak * decayFactor) : 0.0
        let decayedPostAGCRight =
            meterSnapshot.postAGCRightPeak.isFinite
            ? max(0.0, meterSnapshot.postAGCRightPeak * decayFactor) : 0.0
        let decayedOutput =
            meterSnapshot.outputPeak.isFinite
            ? max(0.0, meterSnapshot.outputPeak * decayFactor) : 0.0
        let inputPeak = max(pendingInput, decayedInput)
        let inputLeftPeak = max(pendingInputLeft, decayedInputLeft)
        let inputRightPeak = max(pendingInputRight, decayedInputRight)
        let postAGCLeftPeak = max(pendingPostAGCLeft, decayedPostAGCLeft)
        let postAGCRightPeak = max(pendingPostAGCRight, decayedPostAGCRight)
        let outputPeak = max(pendingOutput, decayedOutput)
        meterSnapshot.inputRMS =
            meterSnapshot.inputRMS.isFinite ? max(0.0, meterSnapshot.inputRMS) : 0.0
        meterSnapshot.inputLeftRMS =
            meterSnapshot.inputLeftRMS.isFinite ? max(0.0, meterSnapshot.inputLeftRMS) : 0.0
        meterSnapshot.inputRightRMS =
            meterSnapshot.inputRightRMS.isFinite ? max(0.0, meterSnapshot.inputRightRMS) : 0.0
        meterSnapshot.postAGCLeftRMS =
            meterSnapshot.postAGCLeftRMS.isFinite ? max(0.0, meterSnapshot.postAGCLeftRMS) : 0.0
        meterSnapshot.postAGCRightRMS =
            meterSnapshot.postAGCRightRMS.isFinite ? max(0.0, meterSnapshot.postAGCRightRMS) : 0.0
        meterSnapshot.outputRMS =
            meterSnapshot.outputRMS.isFinite ? max(0.0, meterSnapshot.outputRMS) : 0.0
        meterSnapshot.inputPeak = inputPeak
        meterSnapshot.inputLeftPeak = inputLeftPeak
        meterSnapshot.inputRightPeak = inputRightPeak
        meterSnapshot.postAGCLeftPeak = postAGCLeftPeak
        meterSnapshot.postAGCRightPeak = postAGCRightPeak
        meterSnapshot.outputPeak = outputPeak
        meterSnapshot.deviationKHzPeak = outputPeak * targetDeviationKHz
        meterSnapshot.liveInputPeak = pendingInput
        meterSnapshot.liveInputLeftPeak = pendingInputLeft
        meterSnapshot.liveInputRightPeak = pendingInputRight
        meterSnapshot.livePostAGCLeftPeak = pendingPostAGCLeft
        meterSnapshot.livePostAGCRightPeak = pendingPostAGCRight
        meterSnapshot.liveOutputPeak = pendingOutput
        meterSnapshot.liveDeviationKHzPeak = pendingOutput * targetDeviationKHz
        pendingInputPeak = 0.0
        pendingInputLeftPeak = 0.0
        pendingInputRightPeak = 0.0
        pendingPostAGCLeftPeak = 0.0
        pendingPostAGCRightPeak = 0.0
        pendingOutputPeak = 0.0
        let snapshot = meterSnapshot
        meterLock.unlock()
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
            bufferedFrames: snapshot.bufferedFrames,
            resampleMode: snapshot.resampleMode,
            ratioTrim: snapshot.ratioTrim,
            sampleStep: snapshot.sampleStep
        )
    }

    private func updateMeters(
        inputRMS: Float, inputPeak: Float, outputRMS: Float, outputPeak: Float
    ) {
        let agc = generator.agcStatus
        let limiter = generator.finalLimiterStatus
        let calibration = generator.compositeCalibrationStatus
        meterSnapshot = MeterSnapshot(
            inputRMS: inputRMS,
            inputPeak: inputPeak,
            inputLeftRMS: inputRMS,
            inputRightRMS: inputRMS,
            inputLeftPeak: inputPeak,
            inputRightPeak: inputPeak,
            postAGCLeftRMS: 0.0,
            postAGCRightRMS: 0.0,
            postAGCLeftPeak: 0.0,
            postAGCRightPeak: 0.0,
            outputRMS: outputRMS,
            outputPeak: outputPeak,
            deviationKHzPeak: outputPeak * targetDeviationKHz,
            liveInputPeak: inputPeak,
            liveInputLeftPeak: inputPeak,
            liveInputRightPeak: inputPeak,
            livePostAGCLeftPeak: 0.0,
            livePostAGCRightPeak: 0.0,
            liveOutputPeak: outputPeak,
            liveDeviationKHzPeak: outputPeak * targetDeviationKHz,
            agcDetectorDB: agc.detectorDB,
            agcGainDB: agc.gainDB,
            agcGateActive: agc.gateActive,
            compositeClipperGainReductionDB: limiter.gainReductionDB,
            preEncodeAudioLimiterGainReductionDB: limiter.preEncodeGainReductionDB,
            mpxSafetyLimiterGainReductionDB: limiter.safetyGainReductionDB,
            pilotInjectionPercent: calibration.pilotPercent,
            rdsInjectionPercent: calibration.rdsPercent,
            audioCompositePeak: calibration.audioPeak,
            compositeBudgetMarginDB: calibration.budgetMarginDB,
            outputStereoCorrelation: 1.0,
            outputSideToMidRatio: 0.0
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
        if safePeak > pendingInputPeak {
            pendingInputPeak = safePeak
        }
        if safeLeftPeak > pendingInputLeftPeak {
            pendingInputLeftPeak = safeLeftPeak
        }
        if safeRightPeak > pendingInputRightPeak {
            pendingInputRightPeak = safeRightPeak
        }
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
        if safeLeftPeak > pendingPostAGCLeftPeak {
            pendingPostAGCLeftPeak = safeLeftPeak
        }
        if safeRightPeak > pendingPostAGCRightPeak {
            pendingPostAGCRightPeak = safeRightPeak
        }
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
            let postAGCRight = analysis.postAGCRight
        {
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
        updateOutputMeters(outputRMS: outMeter.rms, outputPeak: outMeter.peak)
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
            let preRight = analysis.preMPXRight
        {
            updatePreMPXHistory(
                left: preLeft,
                right: preRight,
                frameCount: frameCount
            )
        }
    }

    private func updateOutputMeters(outputRMS: Float, outputPeak: Float) {
        meterSnapshot.outputRMS = outputRMS
        let agc = generator.agcStatus
        let limiter = generator.finalLimiterStatus
        let calibration = generator.compositeCalibrationStatus
        meterSnapshot.agcDetectorDB = agc.detectorDB
        meterSnapshot.agcGainDB = agc.gainDB
        meterSnapshot.agcGateActive = agc.gateActive
        meterSnapshot.compositeClipperGainReductionDB = limiter.gainReductionDB
        meterSnapshot.preEncodeAudioLimiterGainReductionDB = limiter.preEncodeGainReductionDB
        meterSnapshot.mpxSafetyLimiterGainReductionDB = limiter.safetyGainReductionDB
        meterSnapshot.pilotInjectionPercent = calibration.pilotPercent
        meterSnapshot.rdsInjectionPercent = calibration.rdsPercent
        meterSnapshot.audioCompositePeak = calibration.audioPeak
        meterSnapshot.compositeBudgetMarginDB = calibration.budgetMarginDB
        if outputPeak > pendingOutputPeak {
            pendingOutputPeak = outputPeak
        }
    }

    private func applyPendingRuntimeConfigIfNeeded() {
        guard runtimeConfigPending.load(ordering: .acquiring) else { return }
        runtimeConfigLock.lock()
        let runtime = pendingRuntimeConfig
        pendingRuntimeConfig = nil
        if runtime == lastQueuedRuntimeConfig {
            lastQueuedRuntimeConfig = nil
        }
        runtimeConfigPending.store(false, ordering: .relaxed)
        runtimeConfigLock.unlock()
        if let runtime {
            generator.applyRuntimeConfig(runtime)
            targetDeviationKHz = max(1.0, runtime.mpxDeviationKHz)
            runtimeConfigApplyCount.wrappingIncrement(by: 1, ordering: .relaxed)
        }
    }

    private func applyPendingRDSRuntimeConfigIfNeeded() {
        guard rdsRuntimeConfigPending.load(ordering: .acquiring) else { return }
        runtimeConfigLock.lock()
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

    private func appendMonoScopeSamples(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        into history: inout [Float],
        writeIndex: inout Int,
        validFrames: inout Int
    ) {
        guard !history.isEmpty, frameCount > 0 else { return }
        var low: Float = -1.0
        var high: Float = 1.0
        var remaining = frameCount
        var sourceOffset = 0
        var idx = writeIndex
        let historyCount = history.count
        history.withUnsafeMutableBufferPointer { buffer in
            guard let destination = buffer.baseAddress else { return }
            while remaining > 0 {
                let chunk = min(remaining, historyCount - idx)
                let out = destination.advanced(by: idx)
                out.update(from: samples.advanced(by: sourceOffset), count: chunk)
                vDSP_vclip(out, 1, &low, &high, out, 1, vDSP_Length(chunk))
                idx = (idx + chunk) % historyCount
                sourceOffset += chunk
                remaining -= chunk
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
        if buffers.count >= 2,
            let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
            let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        {
            vDSP_vclr(left, 1, vDSP_Length(frameCount))
            vDSP_vclr(right, 1, vDSP_Length(frameCount))
            return
        }
        if buffers.count == 1,
            let mono = buffers[0].mData?.assumingMemoryBound(to: Float.self)
        {
            vDSP_vclr(mono, 1, vDSP_Length(frameCount * 2))
        }
    }

    private static func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        return max(lo, min(hi, x))
    }
}
