import Atomics
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// One coherent snapshot of the meter's measurements, copied out for display.
public struct MeterSnapshot {
    public var hasSignal = false
    public var inputPeakDBFS: Float = -120.0
    public var inputRMSDBFS: Float = -120.0

    public var pilotPresent = false
    /// Pilot amplitude as a percentage of the composite peak. With the input
    /// driven near full scale this approximates pilot injection; it is a
    /// RELATIVE figure, not calibrated kHz of deviation.
    public var pilotPercent: Float = 0.0

    // Pilot-referenced deviation estimates (kHz). The operator's known pilot
    // injection anchors the scale (constant-amplitude pilot is the stable
    // reference); MAX DEV and RDS are then real measurements. PILOT echoes the
    // reference, confirming the calibration.
    public var pilotDevKHz: Float = 0.0
    public var rdsDevKHz: Float = 0.0

    // EN 50067 sec 1.2 subcarrier phase: the angle between the 57 kHz RDS
    // subcarrier and the third harmonic of the 19 kHz pilot, folded to
    // 0..90 deg (0 = in phase, 90 = quadrature -- the standard allows either,
    // +/- 10 deg). `pilotRDSPhaseValid` is false without a coherent
    // subcarrier and pilot; `pilotRDSPhaseCoherence` (0..1) is the estimate
    // quality behind that gate.
    public var pilotRDSPhaseDeg: Float = 0.0
    public var pilotRDSPhaseValid = false
    public var pilotRDSPhaseCoherence: Float = 0.0
    /// EN 50067 sec 1.2 verdict for `pilotRDSPhaseDeg` (meaningless unless
    /// `pilotRDSPhaseValid`).
    public var pilotRDSPhase: RDSPhaseCompliance { RDSPhaseCompliance(degrees: pilotRDSPhaseDeg) }
    /// Highest deviation in the trailing 1 s window (max of 50 ms peak-hold
    /// slots, the SM.1268-5 sec 5 display convention / Pira "MAX" reading).
    public var maxDevKHz: Float = 0.0
    /// Mean and lowest of the same trailing-1 s array of 50 ms peak-hold
    /// slots (the Pira "AVE" / "MIN" readings). AVE next to MAX says how hard
    /// the transmitter is driven on average, not just at its loudest instant;
    /// a MAX far above AVE is a peaky, under-processed signal.
    public var aveDevKHz: Float = 0.0
    public var minDevKHz: Float = 0.0

    // Total-deviation +/- peaks over the trailing peak window (default 60 s;
    // ring of 50 ms peak-hold slots). Self-recovering -- one impulse ages out
    // instead of pinning the reading until reset, matching how measuring
    // receivers display peak deviation. negPeakDevKHz is signed (<= 0).
    public var posPeakDevKHz: Float = 0.0
    public var negPeakDevKHz: Float = 0.0

    /// ITU-R SM.1268-5 sec 4 compliance statistic: the percentage of measured
    /// deviation samples exceeding 77 kHz (75 kHz + the 2 kHz measurement
    /// tolerance) since the last peak reset. The recommendation treats a
    /// transmitter as violating the deviation limit above 10^-4 % (1e-6).
    public var exceedancePct: Float = 0.0
    public var exceedanceValid = false

    /// Deviation histogram since the last peak reset: counts of 50 ms
    /// peak-hold slots per 1 kHz bin. Index i counts slots whose peak
    /// deviation is in [i, i+1) kHz; the last bin
    /// (`MeterAnalysis.histogramOverflowBin`) collects everything above the
    /// covered range. Accumulated left-to-right and normalized it gives the
    /// distribution plot -- what share of the programme reaches a given
    /// deviation. A single MAX number cannot describe modulation the way this
    /// does; it wants 15-60 minutes of programme to be representative.
    public var devHistogram: [UInt32] = []
    public var devHistogramSamples: UInt64 = 0

    /// Composite DC expressed as kHz of FM deviation. On the SDR path this is
    /// the transmitter's carrier frequency offset from the tuned frequency
    /// (an FM demod turns a carrier offset into DC); on an audio input it is
    /// whatever DC the interface presents. Signed.
    public var carrierOffsetKHz: Float = 0.0
    public var carrierOffsetValid = false

    /// RMS of everything ABOVE the modulated baseband (the complement of the
    /// 60 kHz measurement filter), in kHz of deviation. Nothing is legitimately
    /// modulated there, so it is demod noise + interference and is the primary
    /// indicator of whether the other measurements can be trusted -- an FM
    /// demod's noise density rises as f^2, so this band goes bad first.
    public var basebandNoiseKHz: Float = 0.0
    public var basebandNoiseValid = false

    /// Signal quality derived from `basebandNoiseKHz`, 0 (unusable) to 4
    /// (excellent) -- the same 5-step scale a Pira analyzer shows, so the
    /// operator knows when a reading is worth believing.
    public var signalQuality: Int = 0

    // MPX power per ITU-R BS.412: multiplex power integrated over a uniform
    // sliding 60 s window (ring of 1 s mean-squares -- the standard's "any
    // interval of 60 s", not an EMA), expressed in dBr where 0 dBr is the
    // power of a sine at +/-19 kHz deviation. Only meaningful with a known
    // kHz scale; `mpxPowerValid` is false otherwise.
    public var mpxPowerDBr: Float = -30.0
    public var mpxPowerValid = false
    /// Highest fully-primed 60 s sliding MPX power since reset (BS.412
    /// compliance is the max over all window placements).
    public var mpxPowerMaxDBr: Float = -30.0
    public var mpxPowerMaxValid = false

    // Best stereo separation (dB) observed since reset: 20*log10(stronger /
    // weaker decoded channel) sampled during strongly lateralized content
    // (a single-channel / test tone gives the truest reading). Peak-held
    // because panned program reads pessimistically low.
    public var bestSeparationDB: Float = 0.0
    public var separationValid = false

    public var leftRMSDBFS: Float = -120.0
    public var rightRMSDBFS: Float = -120.0
    public var midRMSDBFS: Float = -120.0
    public var sideRMSDBFS: Float = -120.0
    /// Decoded L/R correlation: ~+1 mono, lower for wide stereo.
    public var stereoCorrelation: Float = 0.0
    /// True while the decoder's pilot lock is strong enough for stereo decode;
    /// false = the decoded L/R (and side / correlation / balance) are M-only,
    /// not a measurement of the stereo image (0.45, audit M1).
    public var stereoDecodeActive = false
    /// Decoded L/R level balance in dB (positive = left louder), smoothed and
    /// only valid while both channels carry signal. 0 dB is the target; a
    /// standing offset means the stereo encoder or the audio chain feeding it
    /// is lopsided. Programme with real stereo content still averages to ~0.
    public var stereoBalanceDB: Float = 0.0
    public var stereoBalanceValid = false

    public var rdsLocked = false
    public var rds = RDSReceiverState()
    /// True while the RDS reception-quality gate is suppressing the decode
    /// readout (poor BER / weak subcarrier): `rds` above is blank, but
    /// `recentBlockErrorRate` and `rdsDevKHz` stay live as evidence.
    public var rdsGated = false
    /// Windowed block-error rate (~1 s smoothing). `rds.blockErrorRate` is
    /// cumulative since start and never recovers after a retune; this one
    /// reflects current link quality.
    public var recentBlockErrorRate: Float = 0.0

    // Display waveforms / spectrum for the GUI (empty for the headless CLI).
    // Downsampled to a fixed point count; cross-thread-copied in
    // `isolatedSnapshot()`.
    public var compositeScope: [Float] = []
    public var decodedLScope: [Float] = []
    public var decodedRScope: [Float] = []
    /// Composite spectrum (dB bins), 0..spectrumMaxHz.
    public var spectrumDB: [Float] = []
    public var spectrumMaxHz: Double = 100_000
    public var spectrumNyquistHz: Double = 0
    /// Decoded L / R audio spectra (dB bins), 0..audioSpectrumMaxHz. Shown when
    /// a decoded scope is clicked to switch from waveform to spectrum.
    public var decodedLSpectrumDB: [Float] = []
    public var decodedRSpectrumDB: [Float] = []
    public var audioSpectrumMaxHz: Double = 20_000
    public var audioSpectrumNyquistHz: Double = 0

    // Scrolling trend history (oldest -> newest), ~2 points/s. Deviation in kHz
    // and MPX power in dBr. Cross-thread-copied in `isolatedSnapshot()`.
    public var devHistoryKHz: [Float] = []
    public var mpxPowerHistoryDBr: [Float] = []

    /// Share (0..1) of histogram samples at or above `kHz` of deviation --
    /// the accumulated distribution, read from the right. "20 % of the
    /// programme reaches 45 kHz or more" is `devDistributionAtOrAbove(45)`.
    /// Zero when nothing has been collected yet.
    public func devDistributionAtOrAbove(_ kHz: Float) -> Float {
        guard devHistogramSamples > 0, !devHistogram.isEmpty else { return 0.0 }
        let first = max(0, min(devHistogram.count - 1, Int(kHz.rounded(.down))))
        var above: UInt64 = 0
        for i in first..<devHistogram.count { above &+= UInt64(devHistogram[i]) }
        return Float(Double(above) / Double(devHistogramSamples))
    }

    /// Highest deviation bin (kHz) with any samples in it since the last
    /// reset -- the histogram's own "MAX at" figure, immune to the trailing
    /// window that MAX DEV and PEAK +/- age out of.
    public var devHistogramMaxKHz: Float {
        guard devHistogramSamples > 0 else { return 0.0 }
        for i in stride(from: devHistogram.count - 1, through: 0, by: -1)
        where devHistogram[i] > 0 {
            return Float(i)
        }
        return 0.0
    }

    public init() {}
}

/// Drives the receive chain over blocks of composite samples and accumulates a
/// `MeterSnapshot`. Thread-confined: create and call `process` on one thread.
///
/// Measurement design (validated against ITU-R SM.1268-5 / BS.412-9 and
/// instrument practice -- see MeteringPrimitives.swift):
/// - deviation/power measured on a DC-tracked, linear-phase-FIR-bandlimited
///   (60 kHz) composite; scopes/spectrum/IN stay raw so noise stays visible
/// - MAX DEV = trailing 1 s max of 50 ms peak-hold slots; PEAK +/- = trailing
///   60 s max of the same slots (self-recovering, impulse-robust)
/// - exceedance % of samples > 77 kHz (the SM.1268-5 compliance statistic)
/// - MPX power = uniform sliding 60 s window (ring of 1 s mean-squares) +
///   max-over-placements since reset
/// - RDS deviation = coherent 57 kHz quadrature level (EN 50067 equivalent
///   unmodulated subcarrier, RMS-derived; envelope-invariant)
/// - RDS phase = angle to the pilot's third harmonic, EN 50067 sec 1.2
///   (0 or 90 deg, +/- 10)
public final class MeterAnalysis {
    /// SM.1268-5 deviation exceedance threshold (75 kHz + 2 kHz tolerance).
    public static let exceedanceThresholdKHz: Float = 77.0

    /// Deviation histogram geometry: 1 kHz bins covering 0..120 kHz, plus one
    /// overflow bin. 120 kHz is well past any legitimate transmission, so the
    /// overflow bin only fills on interference or a broken chain.
    public static let histogramBins = 122
    public static let histogramOverflowBin = 121

    /// Baseband-noise thresholds (kHz RMS above the 60 kHz measurement
    /// filter) for the 0..4 `signalQuality` scale. A clean strong signal sits
    /// far below 0.1 kHz; deviation and RDS-level accuracy degrade first, MPX
    /// power and pilot survive longer -- which is why the scale is advisory
    /// rather than a hard gate on the readings.
    public static let qualityNoiseThresholdsKHz: [Float] = [0.10, 0.35, 1.0, 3.0]

    private let sampleRate: Float
    // Pilot reference (kHz) for the pilot-referenced (audio-input) scaling. Live-
    // adjustable from the UI: the true transmitted pilot is not always 9% / 6.75
    // kHz, and an uncalibrated audio source must be anchored to its actual pilot
    // deviation. Stored as a bit pattern in an atomic so a UI write is visible to
    // the analysis thread; refreshed once per process() block. Ignored when
    // fullScaleKHz is set (the SDR path is absolutely calibrated).
    private var pilotRefKHz: Float
    private let pilotRefBits: ManagedAtomic<UInt32>
    // When non-nil, the source is absolutely calibrated: amplitude 1.0 == this
    // many kHz of FM deviation (e.g. FM-SDR-Tuner demod, 1.0 = 150 kHz). All
    // deviations are then measured directly and PILOT is a real reading. When
    // nil, fall back to pilot-referenced calibration (uncalibrated audio in).
    // Live-adjustable from the UI (audio path can switch between pilot-referenced
    // and an absolute "0 dBFS = N kHz" scale). Stored as a bit pattern in an
    // atomic; a NaN pattern means nil (pilot-referenced). Refreshed per block.
    private var fullScaleKHz: Float?
    private let fullScaleBits: ManagedAtomic<UInt32>
    private var pilot = PilotPLL()
    private var decoder = MPXDecoder()
    private let rds: RDSSubcarrierDecoder
    private var snap = MeterSnapshot()

    // Deviation/MPX-power measurement path: sub-Hz DC tracker (SDR demod
    // carrier-offset DC otherwise adds to one deviation polarity and biases
    // power) followed by a linear-phase FIR low-pass at 60 kHz. An FM demod's
    // noise density rises with f^2 (the noise triangle), so on a weak station
    // the 60..96 kHz band is pure demod noise that vector-sums into the raw
    // composite peaks; bandlimiting keeps everything really modulated (mono,
    // pilot, stereo, RDS) -- matching modulation-monitor practice. The FIR is
    // linear-phase (Kaiser sinc) because a steep IIR overshoots and rings on
    // a clipped composite's edges, manufacturing deviation the transmitter
    // never emitted. Scopes, spectrum, and IN stay raw.
    private var dcTracker: DCTracker
    // Decode-path DC blocker (live-toggleable, default on): a link
    // transmitter's carrier offset becomes DC after FM demod; the decoder
    // then puts that DC into both L and R (off-center vectorscope, offset
    // waveforms, DC in the monitor audio and recordings, inflated M level).
    // Broadcast FM carries no legitimate DC, so blocking is safe; the
    // checkbox exists for purists and A/B checks. The measurement path has
    // its own always-on tracker (above); composite scope/IN stay raw.
    private var decodeDC: DCTracker
    private let dcBlockOn = ManagedAtomic<Bool>(true)

    // RDS reception-quality gate: the stream decoder syncs on a single
    // accidental syndrome match and accepts PI/PTY from any single
    // CRC-passing block, so on noise it hallucinates data (random PI at
    // ~74% BER). Publish the decode readout only when reception is
    // plausible; keep measuring BER/level regardless so the gate can
    // reopen and the operator sees the evidence. Force (checkbox) bypasses
    // for diagnostics. Thresholds: clean links are <=5% BER, stressed-real
    // <=15% (test ceilings); EN 50067 minimum injection is 1.0 kHz and a
    // no-RDS noise floor reads ~0.5 kHz on the coherent level meter.
    private static let rdsGateBEROpen: Float = 0.15
    private static let rdsGateBERClose: Float = 0.25
    private static let rdsGateMinLevelKHz: Float = 0.8
    private static let rdsGateMinBlocksValid = 8
    private let forceRDSOn = ManagedAtomic<Bool>(false)
    private var rdsGateOpen = false
    private var rdsGateClosedSamples = 0
    private let measurementFIR: BlockFIRFilter
    private var dcBlock: [Float]
    private var measBlock: [Float]

    // Coherent RDS subcarrier level meter (see MeteringPrimitives.swift).
    private let rdsMeter: RDSSubcarrierLevelMeter
    // EN 50067 sec 1.2 pilot-to-RDS subcarrier phase (see MeteringPrimitives).
    private let phaseMeter: PilotRDSPhaseMeter

    // Warm-up gate: skip the peak / power / separation accumulators for the
    // first second after start so a tuner's pre-lock transient does not poison
    // the windows.
    private var warmupRemaining: Int

    // 50 ms peak-hold slot ring (Pira / SM.1268 heritage: 20 slots/s). MAX DEV
    // reads the trailing 1 s (20 slots), PEAK +/- the whole ring.
    private let slotLen: Int
    private let slotsPerSecond = 20
    private var posSlots: [Float]
    private var negSlots: [Float]
    private var slotWrite = 0
    private var slotsFilled = 0
    private var curPos: Float = 0.0
    private var curNeg: Float = 0.0
    private var slotSampleCount = 0

    // MPX power (BS.412): uniform sliding window of 1 s mean-squares.
    private let mpxWindowSeconds: Int
    private let secLen: Int
    private var mpxSlots: [Double]
    private var mpxSlotWrite = 0
    private var mpxSlotsFilled = 0
    private var curMpxSumSq: Double = 0.0
    private var mpxSampleCount = 0
    private var mpxPowerMaxMS: Double = -1.0

    // SM.1268-5 exceedance counters (since peak reset). The amplitude
    // threshold corresponding to 77 kHz uses the previous block's scale
    // (scale changes slowly; one block of lag is immaterial).
    private var exceedanceTotal: UInt64 = 0
    private var exceedanceOver: UInt64 = 0
    private var exceedanceThreshAmp: Float = 0.0

    // Deviation histogram (since peak reset), one sample per completed 50 ms
    // slot. Binned with the previous block's kHz scale, same one-block lag
    // rationale as the exceedance threshold above.
    private var histogram = [UInt32](repeating: 0, count: MeterAnalysis.histogramBins)
    private var histogramSamples: UInt64 = 0
    private var histogramScaleKHz: Float = 0.0

    // Baseband noise: the exact complement of the measurement FIR. The FIR
    // output lags its input by the filter's group delay, so a matching delay
    // line on the DC-tracked input lets `delayed - filtered` recover the
    // >60 kHz residual sample-for-sample (an allpass minus a lowpass IS the
    // complementary highpass). Cheaper and phase-exact compared with running
    // a second FIR.
    private var noiseDelay: [Float]
    private var noiseDelayWrite = 0
    private var noiseMeanSquare: Float = 0.0
    private var noisePrimed = false
    private let noiseAlphaPerBlockSample: Float

    // Stereo balance: EMA of the per-block L/R RMS ratio, gated on level.
    private var balanceDB: Float = 0.0
    private var balancePrimed = false

    // Best observed stereo separation (dB) since reset.
    private var bestSepDB: Float = 0.0
    private var sepValid = false
    // Trend ring (oldest -> newest), pushed ~2/s (every `trendStride` blocks).
    private static let trendPoints = 120
    private var devHistory = [Float](repeating: 0.0, count: trendPoints)
    private var powerHistory = [Float](repeating: -30.0, count: trendPoints)
    private var trendCounter = 0
    private let trendStride = 12
    // Reset flags requested from the UI thread, applied on this thread.
    // `resetRequested`: peak windows + exceedance + separation (the "Reset
    // Peaks" button). `fullResetRequested`: everything transient (peaks,
    // separation, MPX-power window, BER, trends, RDS decoder) + re-arm
    // warm-up -- used on retune so the previous station's accumulators don't
    // linger.
    private let resetRequested = ManagedAtomic<Bool>(false)
    private let fullResetRequested = ManagedAtomic<Bool>(false)

    // Windowed BER: diff the stream decoder's cumulative block counters per
    // process() call and smooth (~1 s) so the readout tracks current quality.
    private var prevBlocksReceived = 0
    private var prevBlocksValid = 0
    private var berEMA: Float = 0.0

    // Decoded L/R audio for the current block, for the monitor path. Filled by
    // `process`; valid for `[0..<lastBlockCount]`.
    public private(set) var decodedL: [Float]
    public private(set) var decodedR: [Float]
    public private(set) var lastBlockCount = 0

    // GUI display buffers (reused; copied into the snapshot each block).
    private static let scopePoints = 512
    private static let spectrumBins = 512
    private var scopeComposite = [Float](repeating: 0.0, count: scopePoints)
    private var scopeL = [Float](repeating: 0.0, count: scopePoints)
    private var scopeR = [Float](repeating: 0.0, count: scopePoints)
    private var spectrum = MPXSpectrumAnalyzer()
    private var spectrumL = MPXSpectrumAnalyzer()
    private var spectrumR = MPXSpectrumAnalyzer()
    private var spectrumInput: [Float] = []

    /// `mpxPowerWindowSeconds` / `peakWindowSeconds` exist so tests can use
    /// short windows; production uses the BS.412 60 s / instrument 60 s
    /// defaults.
    public init(
        sampleRate: Float, preemphasisUS: Int = 50, pilotRefKHz: Float = 6.75,
        fullScaleKHz: Float? = nil, maxBlock: Int = 16384,
        mpxPowerWindowSeconds: Int = 60, peakWindowSeconds: Int = 60
    ) {
        self.sampleRate = sampleRate
        self.pilotRefKHz = pilotRefKHz
        self.pilotRefBits = ManagedAtomic<UInt32>(pilotRefKHz.bitPattern)
        self.fullScaleKHz = fullScaleKHz
        self.fullScaleBits = ManagedAtomic<UInt32>((fullScaleKHz ?? Float.nan).bitPattern)
        pilot.configure(sampleRate: sampleRate)
        decoder.configure(sampleRate: sampleRate, preemphasisUS: preemphasisUS)
        rds = RDSSubcarrierDecoder(sampleRate: sampleRate)
        rdsMeter = RDSSubcarrierLevelMeter(sampleRate: sampleRate, maxBlock: maxBlock)
        phaseMeter = PilotRDSPhaseMeter(sampleRate: sampleRate, maxBlock: maxBlock)
        // Fast DC acquisition during the warm-up second (5 Hz corner), then
        // drop to 0.2 Hz for tracking -- otherwise the acquisition residual
        // of an SDR carrier offset lands in the peak windows.
        dcTracker = DCTracker(cutoffHz: 5.0, sampleRate: sampleRate)
        decodeDC = DCTracker(cutoffHz: 2.0, sampleRate: sampleRate)
        // Clamp below Nyquist for low-rate captures (no RDS there anyway).
        let cutoff = min(60_000.0, 0.45 * sampleRate)
        let transition = min(8_000.0, 0.5 * sampleRate - cutoff - 1.0)
        let measTaps = FIRDesign.kaiserLowpass(
            cutoffHz: cutoff, sampleRate: sampleRate,
            transitionHz: max(500.0, transition), stopbandDB: 80.0)
        measurementFIR = BlockFIRFilter(taps: measTaps, maxBlock: maxBlock)
        dcBlock = [Float](repeating: 0.0, count: maxBlock)
        measBlock = [Float](repeating: 0.0, count: maxBlock)
        // Ring of exactly D = (taps-1)/2 samples: reading then writing the
        // same index yields a delay of one full lap, i.e. the FIR's group
        // delay. (Sized from the local taps -- `self` is not fully
        // initialized here.)
        noiseDelay = [Float](repeating: 0.0, count: max(1, (measTaps.count - 1) / 2))
        // ~1 s smoothing of the noise power, applied per sample.
        noiseAlphaPerBlockSample = 1.0 - expf(-1.0 / max(1.0, sampleRate))
        warmupRemaining = Int(sampleRate)  // ~1 s
        slotLen = max(1, Int(sampleRate) / slotsPerSecond)  // 50 ms
        self.mpxWindowSeconds = max(1, mpxPowerWindowSeconds)
        let peakSlots = max(1, peakWindowSeconds) * slotsPerSecond
        posSlots = [Float](repeating: 0.0, count: peakSlots)
        negSlots = [Float](repeating: 0.0, count: peakSlots)
        secLen = max(1, Int(sampleRate))
        mpxSlots = [Double](repeating: 0.0, count: self.mpxWindowSeconds)
        decodedL = [Float](repeating: 0.0, count: maxBlock)
        decodedR = [Float](repeating: 0.0, count: maxBlock)
    }

    /// Clear the peak windows, exceedance counters, MPX-power max, and
    /// best-separation accumulators (UI "Reset"). Safe to call from any
    /// thread; applied at the top of the next `process`.
    public func requestPeakReset() { resetRequested.store(true, ordering: .relaxed) }

    /// Clear ALL transient accumulators + re-arm the warm-up gate + reset the
    /// RDS decoder. Use on retune so the prior station's peaks / MPX power /
    /// BER / RDS text don't carry over. Safe to call from any thread.
    public func requestFullReset() { fullResetRequested.store(true, ordering: .relaxed) }

    /// Enable/disable the decode-path DC blocker (live; default on).
    public func setDCBlock(_ on: Bool) { dcBlockOn.store(on, ordering: .relaxed) }

    /// Bypass the RDS reception-quality gate (live; default off): publish the
    /// raw decoder state even when reception is too poor to trust.
    public func setForceRDS(_ on: Bool) { forceRDSOn.store(on, ordering: .relaxed) }

    /// Set the pilot reference (kHz) used by the pilot-referenced audio path.
    /// Safe to call from any thread; picked up at the top of the next `process`.
    public func setPilotRefKHz(_ k: Float) { pilotRefBits.store(k.bitPattern, ordering: .relaxed) }

    /// Set the absolute deviation scale (amplitude 1.0 == k kHz), or nil to use
    /// pilot-referenced scaling. Safe from any thread; applied at the next block.
    public func setFullScaleKHz(_ k: Float?) {
        fullScaleBits.store((k ?? Float.nan).bitPattern, ordering: .relaxed)
    }

    private func resetPeakAccumulators() {
        for i in posSlots.indices { posSlots[i] = 0.0 }
        for i in negSlots.indices { negSlots[i] = 0.0 }
        slotWrite = 0
        slotsFilled = 0
        curPos = 0.0
        curNeg = 0.0
        slotSampleCount = 0
        exceedanceTotal = 0
        exceedanceOver = 0
        mpxPowerMaxMS = -1.0
        bestSepDB = 0.0
        sepValid = false
        // The histogram is a distribution accumulated since reset, exactly
        // like the exceedance counters -- it clears with them.
        for i in histogram.indices { histogram[i] = 0 }
        histogramSamples = 0
    }

    private func resetMPXWindow() {
        for i in mpxSlots.indices { mpxSlots[i] = 0.0 }
        mpxSlotWrite = 0
        mpxSlotsFilled = 0
        curMpxSumSq = 0.0
        mpxSampleCount = 0
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        pilotRefKHz = Float(bitPattern: pilotRefBits.load(ordering: .relaxed))
        let fs = Float(bitPattern: fullScaleBits.load(ordering: .relaxed))
        fullScaleKHz = fs.isNaN ? nil : fs
        let doFullReset = fullResetRequested.exchange(false, ordering: .relaxed)
        if doFullReset {
            // Everything transient -- the new station starts clean.
            resetMPXWindow()
            berEMA = 0.0
            prevBlocksReceived = 0
            prevBlocksValid = 0
            rdsMeter.reset()
            phaseMeter.reset()
            noiseMeanSquare = 0.0
            noisePrimed = false
            for i in noiseDelay.indices { noiseDelay[i] = 0.0 }
            noiseDelayWrite = 0
            balanceDB = 0.0
            balancePrimed = false
            dcTracker.reset()
            dcTracker.setCutoff(5.0, sampleRate: sampleRate)  // re-acquire
            measurementFIR.reset()
            for i in devHistory.indices { devHistory[i] = 0.0 }
            for i in powerHistory.indices { powerHistory[i] = -30.0 }
            warmupRemaining = Int(sampleRate)  // ~1 s -- skip the relock transient
            rds.reset()
            rdsGateOpen = false
            rdsGateClosedSamples = 0
        }
        if doFullReset || resetRequested.exchange(false, ordering: .relaxed) {
            resetPeakAccumulators()
        }
        let count = samples.count
        let n = Float(count)
        let cap = decodedL.count

        // Measurement path pre-pass: DC-track, then linear-phase FIR
        // bandlimit, both vectorized/block-wise ahead of the per-sample loop.
        for i in 0..<count { dcBlock[i] = dcTracker.process(samples[i]) }
        dcBlock.withUnsafeBufferPointer {
            measurementFIR.process(input: $0, output: &measBlock, count: count)
        }
        // Baseband noise: the complementary highpass, delayed-input minus
        // filtered. Done here, in the pre-pass, where `dcBlock` still means
        // the array (the per-sample loop below shadows the name with the
        // DC-block flag).
        if warmupRemaining <= 0 {
            let ring = noiseDelay.count
            for i in 0..<count {
                let delayed = noiseDelay[noiseDelayWrite]
                noiseDelay[noiseDelayWrite] = dcBlock[i]
                noiseDelayWrite = (noiseDelayWrite + 1) % ring
                let hp = delayed - measBlock[i]
                let p = hp * hp
                if noisePrimed {
                    noiseMeanSquare += noiseAlphaPerBlockSample * (p - noiseMeanSquare)
                } else {
                    noiseMeanSquare = p
                    noisePrimed = true
                }
            }
        } else {
            // Keep the delay line running so it is primed when warm-up ends.
            let ring = noiseDelay.count
            for i in 0..<count {
                noiseDelay[noiseDelayWrite] = dcBlock[i]
                noiseDelayWrite = (noiseDelayWrite + 1) % ring
            }
        }
        // Coherent RDS subcarrier level (57 kHz; DC-irrelevant, feed raw).
        rdsMeter.process(samples)
        // Pilot-to-RDS subcarrier phase. Also fed raw: it needs the pilot and
        // the subcarrier in their original phase relationship, and the
        // measurement FIR / DC path would only add delay to one of them.
        phaseMeter.process(samples)

        var peak: Float = 0.0
        var sumSq: Float = 0.0
        let inWarmup = warmupRemaining > 0
        var pilotMagMax: Float = 0.0
        var lSq: Float = 0.0
        var rSq: Float = 0.0
        var lr: Float = 0.0
        var mSq: Float = 0.0
        var sSq: Float = 0.0
        var over77 = 0
        let threshAmp = exceedanceThreshAmp
        let dcBlock = dcBlockOn.load(ordering: .relaxed)

        var i = 0
        for s in samples {
            let a = fabsf(s)
            if a > peak { peak = a }
            sumSq += s * s

            let m = measBlock[i]
            if !inWarmup {
                // 50 ms peak-hold slot accumulation (feeds MAX DEV + PEAK +/-).
                if m > curPos { curPos = m }
                if m < curNeg { curNeg = m }
                slotSampleCount += 1
                if slotSampleCount >= slotLen {
                    posSlots[slotWrite] = curPos
                    negSlots[slotWrite] = curNeg
                    slotWrite = (slotWrite + 1) % posSlots.count
                    if slotsFilled < posSlots.count { slotsFilled += 1 }
                    // Deviation histogram: one sample per completed slot,
                    // binned at 1 kHz. Needs an established kHz scale --
                    // without one the bin index would be meaningless.
                    if histogramScaleKHz > 0.0 {
                        let devKHz = max(curPos, -curNeg) * histogramScaleKHz
                        let bin = devKHz >= Float(Self.histogramOverflowBin)
                            ? Self.histogramOverflowBin
                            : max(0, Int(devKHz))
                        histogram[bin] &+= 1
                        histogramSamples &+= 1
                    }
                    curPos = 0.0
                    curNeg = 0.0
                    slotSampleCount = 0
                }
                // MPX power 1 s slot accumulation (sample-exact roll so the
                // sliding window is exactly BS.412's 60 s, not block-quantized).
                curMpxSumSq += Double(m * m)
                mpxSampleCount += 1
                if mpxSampleCount >= secLen {
                    mpxSlots[mpxSlotWrite] = curMpxSumSq / Double(mpxSampleCount)
                    mpxSlotWrite = (mpxSlotWrite + 1) % mpxSlots.count
                    if mpxSlotsFilled < mpxSlots.count { mpxSlotsFilled += 1 }
                    curMpxSumSq = 0.0
                    mpxSampleCount = 0
                }
                // SM.1268-5 exceedance count (threshold from last block's scale).
                if threshAmp > 0.0, fabsf(m) > threshAmp { over77 += 1 }
            }

            let p = pilot.process(s)
            if p.mag2 > pilotMagMax { pilotMagMax = p.mag2 }

            // expectedSide = 0 disables the decoder's stereo-collapse self-heal
            // (a meter must not silently reconfigure); programActivity = |s|
            // keeps the noise gate open while signal is present.
            let dIn = dcBlock ? decodeDC.process(s) : s
            let (l, r) = decoder.process(dIn, programActivity: a, expectedSide: 0.0)
            lSq += l * l
            rSq += r * r
            lr += l * r
            let mid = (l + r) * 0.5
            let side = (l - r) * 0.5
            mSq += mid * mid
            sSq += side * side
            if i < cap {
                decodedL[i] = l
                decodedR[i] = r
            }

            rds.process(s)
            i += 1
        }
        lastBlockCount = min(count, cap)
        if !inWarmup, threshAmp > 0.0 {
            exceedanceTotal += UInt64(count)
            exceedanceOver += UInt64(over77)
        }

        let rms = sqrtf(sumSq / n)
        // PilotPLL lock-in I/Q each converge to (A/2)*{cos,sin}(phi); |I,Q| = A/2.
        let pilotAmp = 2.0 * sqrtf(pilotMagMax)
        // Peak deviation amplitude of the 57 kHz subcarrier (the injection
        // level the encoder was set to -- encoders peak-normalize).
        let rdsEquivAmp = rdsMeter.peakAmplitude
        let corr: Float = (lSq > 1e-12 && rSq > 1e-12) ? (lr / sqrtf(lSq * rSq)) : 0.0

        snap.hasSignal = peak > 1e-4
        snap.inputPeakDBFS = Self.dbfs(peak)
        snap.inputRMSDBFS = Self.dbfs(rms)
        snap.pilotPresent = pilotMagMax > 1e-6
        snap.pilotPercent = peak > 1e-6 ? (pilotAmp / peak * 100.0) : 0.0

        // Windowed peak statistics from the 50 ms slot ring.
        // MAX DEV: trailing 1 s (20 slots). PEAK +/-: the whole ring.
        var max1s: Float = max(curPos, -curNeg)
        var posMax: Float = curPos
        var negMin: Float = curNeg
        // AVE / MIN over the same trailing-1 s slot array as MAX. The
        // in-progress slot is deliberately excluded from these two: it has
        // seen only part of its 50 ms and would drag AVE and MIN down.
        var sum1s: Float = 0.0
        var min1s: Float = .greatestFiniteMagnitude
        var counted1s = 0
        if slotsFilled > 0 {
            let recent = min(slotsPerSecond, slotsFilled)
            for k in 0..<slotsFilled {
                let idx = (slotWrite + posSlots.count - 1 - k) % posSlots.count
                let p = posSlots[idx]
                let q = negSlots[idx]
                if p > posMax { posMax = p }
                if q < negMin { negMin = q }
                if k < recent {
                    let m = max(p, -q)
                    if m > max1s { max1s = m }
                    sum1s += m
                    if m < min1s { min1s = m }
                    counted1s += 1
                }
            }
        }
        let ave1s = counted1s > 0 ? sum1s / Float(counted1s) : 0.0
        let low1s = counted1s > 0 ? min1s : 0.0

        // Pilot-referenced deviation: scale = pilotRef / pilotAmp. devScaleKHz
        // is the unified "kHz per unit composite amplitude" used by the
        // deviation, peak-hold and MPX-power metrics below; nil when no scale
        // is established (uncalibrated input with no pilot lock).
        let devScaleKHz: Float?
        if let fullScale = fullScaleKHz {
            // Absolutely calibrated source (e.g. FM-SDR-Tuner: 1.0 = 150 kHz
            // at its default -6 dB MPX gain). Everything is a direct
            // measurement -- including the pilot.
            snap.pilotDevKHz = pilotAmp * fullScale
            snap.rdsDevKHz = rdsEquivAmp * fullScale
            snap.maxDevKHz = max1s * fullScale
            snap.aveDevKHz = ave1s * fullScale
            snap.minDevKHz = low1s * fullScale
            devScaleKHz = fullScale
        } else if pilotAmp > 1e-5 {
            let scale = pilotRefKHz / pilotAmp
            snap.pilotDevKHz = pilotRefKHz
            // RDS equivalent-subcarrier amplitude referenced to the pilot
            // amplitude -- the basis measuring receivers use, so it matches
            // an SFP-style RDS readout.
            snap.rdsDevKHz = rdsEquivAmp * scale
            snap.maxDevKHz = max1s * scale
            snap.aveDevKHz = ave1s * scale
            snap.minDevKHz = low1s * scale
            devScaleKHz = scale
        } else {
            snap.pilotDevKHz = 0.0
            snap.rdsDevKHz = 0.0
            snap.maxDevKHz = 0.0
            snap.aveDevKHz = 0.0
            snap.minDevKHz = 0.0
            devScaleKHz = nil
        }

        // Carrier / DC offset and baseband noise, both in kHz of deviation.
        if let devScaleKHz {
            snap.carrierOffsetKHz = dcTracker.estimate * devScaleKHz
            snap.carrierOffsetValid = !inWarmup
            snap.basebandNoiseKHz = sqrtf(max(0.0, noiseMeanSquare)) * devScaleKHz
            snap.basebandNoiseValid = noisePrimed
        } else {
            snap.carrierOffsetValid = false
            snap.basebandNoiseValid = false
        }
        // Signal quality 0..4 from the noise floor above the modulated bands.
        if snap.basebandNoiseValid, snap.hasSignal {
            // One step down the 4..0 scale per threshold the noise exceeds.
            var exceeded = 0
            for limit in Self.qualityNoiseThresholdsKHz
            where snap.basebandNoiseKHz > limit {
                exceeded += 1
            }
            snap.signalQuality = Self.qualityNoiseThresholdsKHz.count - exceeded
        } else {
            snap.signalQuality = 0
        }
        // The histogram bins the NEXT block's slots with this block's scale
        // (same one-block lag as the exceedance threshold).
        histogramScaleKHz = inWarmup ? 0.0 : (devScaleKHz ?? 0.0)
        snap.devHistogram = histogram
        snap.devHistogramSamples = histogramSamples

        // EN 50067 sec 1.2 subcarrier phase. Three gates, all needed:
        // pilot presence (no pilot -> no third harmonic to reference), the
        // phase meter's own coherence, and an RDS LEVEL floor. The level gate
        // is not redundant: coherence is scale-free, and the residual pilot
        // leakage into the 57 kHz chain is perfectly coherent (it IS the
        // pilot), so a station with no RDS at all reads a confident angle on
        // ~0.01 kHz of leakage unless a real subcarrier is required.
        snap.pilotRDSPhaseDeg = phaseMeter.phaseDegrees
        snap.pilotRDSPhaseCoherence = phaseMeter.coherence
        snap.pilotRDSPhaseValid = phaseMeter.valid && snap.pilotPresent
            && devScaleKHz != nil && snap.rdsDevKHz >= Self.rdsGateMinLevelKHz

        // Total-deviation +/- windowed peaks (kHz) + exceedance statistic.
        if let devScaleKHz {
            snap.posPeakDevKHz = posMax * devScaleKHz
            snap.negPeakDevKHz = negMin * devScaleKHz
            exceedanceThreshAmp = Self.exceedanceThresholdKHz / devScaleKHz
        } else {
            exceedanceThreshAmp = 0.0
        }
        if exceedanceTotal > 0 {
            snap.exceedancePct =
                Float((Double(exceedanceOver) / Double(exceedanceTotal)) * 100.0)
            // Meaningful once at least ~1 s of samples has been counted.
            snap.exceedanceValid = exceedanceTotal >= UInt64(secLen)
        } else {
            snap.exceedancePct = 0.0
            snap.exceedanceValid = false
        }

        // MPX power (ITU-R BS.412): uniform mean over the sliding window in
        // dBr vs the power of a +/-19 kHz sine (mean-square 19^2/2 in the
        // kHz domain). The window is the current partial second + the filled
        // 1 s slots, with the OLDEST slot weighted by the partial's
        // complement -- a constant-length window of exactly 60 s once
        // primed, at any evaluation instant (BS.412's "any interval of
        // 60 s"), not 60..61 s.
        var windowSum = 0.0
        var windowWeight = 0.0
        let partialFrac = Double(mpxSampleCount) / Double(secLen)
        if mpxSampleCount > 0 {
            windowSum += (curMpxSumSq / Double(mpxSampleCount)) * partialFrac
            windowWeight += partialFrac
        }
        if mpxSlotsFilled > 0 {
            let ringLen = mpxSlots.count
            for k in 0..<mpxSlotsFilled {
                let idx = (mpxSlotWrite + ringLen - 1 - k) % ringLen
                var w = 1.0
                if k == mpxSlotsFilled - 1, mpxSlotsFilled == ringLen {
                    w = 1.0 - partialFrac  // trim the oldest slot to keep 60 s
                }
                windowSum += mpxSlots[idx] * w
                windowWeight += w
            }
        }
        if let devScaleKHz, windowWeight > 0.0 {
            let meanSq = windowSum / windowWeight
            let mpxMSkHz2 = meanSq * Double(devScaleKHz) * Double(devScaleKHz)
            let refMSkHz2 = 19.0 * 19.0 / 2.0
            snap.mpxPowerDBr = Float(10.0 * log10(max(1e-9, mpxMSkHz2 / refMSkHz2)))
            snap.mpxPowerValid = true
            // Compliance max: only once the window is fully primed (BS.412's
            // "any interval of 60 s" needs a full window).
            if mpxSlotsFilled >= mpxSlots.count, meanSq > mpxPowerMaxMS {
                mpxPowerMaxMS = meanSq
            }
            if mpxPowerMaxMS >= 0.0 {
                let maxKHz2 = mpxPowerMaxMS * Double(devScaleKHz) * Double(devScaleKHz)
                snap.mpxPowerMaxDBr = Float(10.0 * log10(max(1e-9, maxKHz2 / refMSkHz2)))
                snap.mpxPowerMaxValid = true
            } else {
                snap.mpxPowerMaxValid = false
            }
        } else {
            snap.mpxPowerValid = false
            snap.mpxPowerMaxValid = false
        }

        // Best stereo separation (dB): sample 20*log10(stronger/weaker) only on
        // real, lateralized content (a single-channel / test tone is truest),
        // and peak-hold it -- panned program reads pessimistically low.
        let lRMS = sqrtf(lSq / n)
        let rRMS = sqrtf(rSq / n)
        let hi = max(lRMS, rRMS)
        let lo = min(lRMS, rRMS)
        if !inWarmup, decoder.stereoDecodeActive, hi > 0.05, lo > 1e-4 {
            let sep = min(60.0, 20.0 * log10f(hi / lo))
            if sep > bestSepDB { bestSepDB = sep; sepValid = true }
        }
        snap.bestSeparationDB = bestSepDB
        snap.separationValid = sepValid

        // Stereo balance (dB, + = left louder). Smoothed hard (~3 s at 23
        // blocks/s) because real programme pans constantly -- the useful
        // reading is the standing offset, not the instantaneous one. Gated on
        // both channels carrying signal so silence cannot pin it, and on an
        // active stereo decode -- an M-only decode has L == R exactly, so it
        // would otherwise pin a confident +0.0 dB "balance" (audit M1).
        if !inWarmup, decoder.stereoDecodeActive, lRMS > 1e-3, rRMS > 1e-3 {
            let instant = 20.0 * log10f(lRMS / rRMS)
            if balancePrimed {
                balanceDB += 0.015 * (instant - balanceDB)
            } else {
                balanceDB = instant
                balancePrimed = true
            }
        }
        snap.stereoBalanceDB = balanceDB
        snap.stereoBalanceValid = balancePrimed
        if warmupRemaining > 0 {
            warmupRemaining = max(0, warmupRemaining - count)
            if warmupRemaining == 0 {
                // Acquisition done: switch the DC tracker to slow tracking.
                dcTracker.setCutoff(0.2, sampleRate: sampleRate)
            }
        }

        // Trend history (~2/s): push current peak deviation + MPX power.
        trendCounter += 1
        if trendCounter >= trendStride {
            trendCounter = 0
            devHistory.removeFirst()
            devHistory.append(snap.maxDevKHz)
            powerHistory.removeFirst()
            powerHistory.append(snap.mpxPowerValid ? snap.mpxPowerDBr : -30.0)
        }
        snap.devHistoryKHz = devHistory
        snap.mpxPowerHistoryDBr = powerHistory
        snap.leftRMSDBFS = Self.dbfs(sqrtf(lSq / n))
        snap.rightRMSDBFS = Self.dbfs(sqrtf(rSq / n))
        snap.midRMSDBFS = Self.dbfs(sqrtf(mSq / n))
        snap.sideRMSDBFS = Self.dbfs(sqrtf(sSq / n))
        snap.stereoCorrelation = corr
        snap.stereoDecodeActive = decoder.stereoDecodeActive
        // Windowed BER from the LIVE decoder state (must keep measuring even
        // while the gate blanks the published readout).
        let rdsLive = rds.state
        let deltaReceived = rdsLive.blocksReceived - prevBlocksReceived
        let deltaValid = rdsLive.blocksValid - prevBlocksValid
        if deltaReceived > 0 {
            let instant = Float(deltaReceived - deltaValid) / Float(deltaReceived)
            berEMA = (0.95 * berEMA) + (0.05 * instant)
            prevBlocksReceived = rdsLive.blocksReceived
            prevBlocksValid = rdsLive.blocksValid
        }
        snap.recentBlockErrorRate = berEMA

        // RDS reception-quality gate (see the threshold rationale at the
        // declarations). Level criterion applies only when a kHz scale
        // exists; hysteresis (open <=15%, close >25%) prevents flapping;
        // blocksValid floor prevents a fresh-reset berEMA==0 false-open.
        let forceRDS = forceRDSOn.load(ordering: .relaxed)
        let levelOK = devScaleKHz == nil || snap.rdsDevKHz >= Self.rdsGateMinLevelKHz
        if rdsGateOpen {
            if berEMA > Self.rdsGateBERClose || !levelOK { rdsGateOpen = false }
        } else if berEMA <= Self.rdsGateBEROpen, levelOK,
                  rdsLive.blocksValid >= Self.rdsGateMinBlocksValid {
            rdsGateOpen = true
        }
        if rdsGateOpen || forceRDS {
            snap.rdsLocked = rds.locked
            snap.rds = rdsLive
            snap.rdsGated = false
            rdsGateClosedSamples = 0
        } else {
            snap.rdsLocked = false
            snap.rds = RDSReceiverState()
            snap.rdsGated = true
            // After 10 s continuously gated, clear the decoder so
            // hallucinated PS/RT/group counts don't flash when the gate
            // later opens. berEMA is kept (it is the gate input); the
            // delta counters re-sync to the fresh decoder state.
            rdsGateClosedSamples += count
            if rdsGateClosedSamples >= 10 * secLen {
                rds.reset()
                prevBlocksReceived = 0
                prevBlocksValid = 0
                rdsGateClosedSamples = 0
            }
        }

        // GUI display buffers. Decimate this block to a fixed point count for
        // the scopes, and recompute the spectra, every block (~23/s at 8192-frame
        // blocks @ 192 kHz) so the spectrum refreshes as smoothly as the scopes.
        // This runs on the analysis thread (off the audio path), and a few vDSP
        // FFTs are cheap next to the per-sample decode chains already run here,
        // so there is no need to throttle (the old every-4th-block gate dropped
        // the spectrum to ~6/s and looked sluggish).
        Self.decimate(into: &scopeComposite, from: samples, count: count)
        decodedL.withUnsafeBufferPointer {
            Self.decimate(into: &scopeL, from: $0, count: lastBlockCount)
        }
        decodedR.withUnsafeBufferPointer {
            Self.decimate(into: &scopeR, from: $0, count: lastBlockCount)
        }
        snap.compositeScope = scopeComposite
        snap.decodedLScope = scopeL
        snap.decodedRScope = scopeR

        if spectrumInput.count != count {
            spectrumInput = [Float](repeating: 0.0, count: count)
        }
        for j in 0..<count { spectrumInput[j] = samples[j] }
        let result = spectrum.compute(
            samples: spectrumInput, validCount: count,
            sampleRate: Double(sampleRate), displayBins: Self.spectrumBins,
            maxDisplayHz: 100_000)
        snap.spectrumDB = result.dbBins
        snap.spectrumMaxHz = result.maxHz
        snap.spectrumNyquistHz = result.nyquistHz

        // Decoded L / R audio spectra (0..20 kHz) for the click-to-spectrum
        // scope view. Computed from the full decoded blocks, audio range.
        let lres = spectrumL.compute(
            samples: decodedL, validCount: lastBlockCount,
            sampleRate: Double(sampleRate), displayBins: Self.spectrumBins,
            maxDisplayHz: 20_000)
        let rres = spectrumR.compute(
            samples: decodedR, validCount: lastBlockCount,
            sampleRate: Double(sampleRate), displayBins: Self.spectrumBins,
            maxDisplayHz: 20_000)
        snap.decodedLSpectrumDB = lres.dbBins
        snap.decodedRSpectrumDB = rres.dbBins
        snap.audioSpectrumMaxHz = lres.maxHz
        snap.audioSpectrumNyquistHz = lres.nyquistHz
    }

    /// Point-decimate a source buffer into a fixed-size destination (stride
    /// pick, point-to-point to match ScopeView's line render).
    private static func decimate(
        into dst: inout [Float], from src: UnsafeBufferPointer<Float>, count: Int
    ) {
        let n = dst.count
        guard count > 0 else {
            for i in 0..<n { dst[i] = 0.0 }
            return
        }
        for i in 0..<n {
            dst[i] = src[min(count - 1, (i * count) / n)]
        }
    }

    /// Same-thread snapshot (no cross-thread handoff).
    public func snapshot() -> MeterSnapshot { snap }

    /// A snapshot whose heap-backed members (RDS arrays + strings) are copied
    /// into independent storage, safe to hand to another thread. The live RDS
    /// decoder keeps mutating its own copy-on-write buffers every block, and
    /// `snap.rds` shares those buffers; reading them on the display thread
    /// while the analysis thread mutates them is undefined behavior (heap
    /// corruption / "pointer being freed was not allocated"). Build the
    /// isolated copy here, on the analysis thread, before publishing.
    public func isolatedSnapshot() -> MeterSnapshot {
        var c = snap
        c.rds.groupCounts = snap.rds.groupCounts.map { $0 }
        c.rds.groupOrder = snap.rds.groupOrder.map { $0 }
        c.rds.alternativeFrequenciesMHz = snap.rds.alternativeFrequenciesMHz.map { $0 }
        c.rds.rtPlusTags = snap.rds.rtPlusTags.map {
            RDSRTPlusTag(contentType: $0.contentType, text: String(Array($0.text)))
        }
        c.rds.programService = String(Array(snap.rds.programService))
        c.rds.radioText = String(Array(snap.rds.radioText))
        c.rds.programTypeName = String(Array(snap.rds.programTypeName))
        c.rds.longPS = String(Array(snap.rds.longPS))
        // Scope/spectrum buffers share the reused analysis-thread storage --
        // force independent copies for the display thread (same cross-thread
        // CoW hazard as the RDS arrays above).
        c.compositeScope = snap.compositeScope.map { $0 }
        c.decodedLScope = snap.decodedLScope.map { $0 }
        c.decodedRScope = snap.decodedRScope.map { $0 }
        c.spectrumDB = snap.spectrumDB.map { $0 }
        c.decodedLSpectrumDB = snap.decodedLSpectrumDB.map { $0 }
        c.decodedRSpectrumDB = snap.decodedRSpectrumDB.map { $0 }
        c.devHistoryKHz = snap.devHistoryKHz.map { $0 }
        c.mpxPowerHistoryDBr = snap.mpxPowerHistoryDBr.map { $0 }
        c.devHistogram = snap.devHistogram.map { $0 }
        return c
    }

    private static func dbfs(_ x: Float) -> Float { 20.0 * log10f(max(1e-6, x)) }
}
