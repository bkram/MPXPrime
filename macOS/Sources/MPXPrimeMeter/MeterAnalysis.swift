import Atomics
import Darwin
import Foundation
import MPXPrimeCore

/// One coherent snapshot of the meter's measurements, copied out for display.
struct MeterSnapshot {
    var hasSignal = false
    var inputPeakDBFS: Float = -120.0
    var inputRMSDBFS: Float = -120.0

    var pilotPresent = false
    /// Pilot amplitude as a percentage of the composite peak. With the input
    /// driven near full scale this approximates pilot injection; it is a
    /// RELATIVE figure, not calibrated kHz of deviation.
    var pilotPercent: Float = 0.0

    // Pilot-referenced deviation estimates (kHz). The operator's known pilot
    // injection anchors the scale (constant-amplitude pilot is the stable
    // reference); MAX DEV and RDS are then real measurements. PILOT echoes the
    // reference, confirming the calibration.
    var pilotDevKHz: Float = 0.0
    var rdsDevKHz: Float = 0.0
    var maxDevKHz: Float = 0.0

    // Total deviation peak-hold since the last reset (composite amplitude
    // scaled to kHz). Positive and negative excursions tracked separately so
    // asymmetry is visible. negPeakDevKHz is signed (<= 0).
    var posPeakDevKHz: Float = 0.0
    var negPeakDevKHz: Float = 0.0

    // MPX power per ITU-R BS.412: multiplex power integrated over ~60 s,
    // expressed in dBr where 0 dBr is the power of a sine at +/-19 kHz
    // deviation. Only meaningful with a known kHz scale (abs cal, or pilot
    // lock for pilot-ref); `mpxPowerValid` is false otherwise.
    var mpxPowerDBr: Float = -30.0
    var mpxPowerValid = false

    // Best stereo separation (dB) observed since reset: 20*log10(stronger /
    // weaker decoded channel) sampled during strongly lateralized content
    // (a single-channel / test tone gives the truest reading). Peak-held
    // because panned program reads pessimistically low.
    var bestSeparationDB: Float = 0.0
    var separationValid = false

    var leftRMSDBFS: Float = -120.0
    var rightRMSDBFS: Float = -120.0
    var midRMSDBFS: Float = -120.0
    var sideRMSDBFS: Float = -120.0
    /// Decoded L/R correlation: ~+1 mono, lower for wide stereo.
    var stereoCorrelation: Float = 0.0

    var rdsLocked = false
    var rds = RDSReceiverState()
    /// Windowed block-error rate (~1 s smoothing). `rds.blockErrorRate` is
    /// cumulative since start and never recovers after a retune; this one
    /// reflects current link quality.
    var recentBlockErrorRate: Float = 0.0

    // Display waveforms / spectrum for the GUI (empty for the headless CLI).
    // Downsampled to a fixed point count; cross-thread-copied in
    // `isolatedSnapshot()`.
    var compositeScope: [Float] = []
    var decodedLScope: [Float] = []
    var decodedRScope: [Float] = []
    /// Composite spectrum (dB bins), 0..spectrumMaxHz.
    var spectrumDB: [Float] = []
    var spectrumMaxHz: Double = 100_000
    var spectrumNyquistHz: Double = 0

    // Scrolling trend history (oldest -> newest), ~2 points/s. Deviation in kHz
    // and MPX power in dBr. Cross-thread-copied in `isolatedSnapshot()`.
    var devHistoryKHz: [Float] = []
    var mpxPowerHistoryDBr: [Float] = []
}

/// Drives the receive chain over blocks of composite samples and accumulates a
/// `MeterSnapshot`. Thread-confined: create and call `process` on one thread.
final class MeterAnalysis {
    private let sampleRate: Float
    private let pilotRefKHz: Float
    // When non-nil, the source is absolutely calibrated: amplitude 1.0 == this
    // many kHz of FM deviation (e.g. FM-SDR-Tuner demod, 1.0 = 75 kHz). All
    // deviations are then measured directly and PILOT is a real reading. When
    // nil, fall back to pilot-referenced calibration (uncalibrated audio in).
    private let fullScaleKHz: Float?
    private var pilot = PilotPLL()
    private var decoder = MPXDecoder()
    private let rds: RDSSubcarrierDecoder
    private var snap = MeterSnapshot()

    // 57 kHz bandpass to isolate the RDS subcarrier for deviation measurement.
    private var rdsBandpass = Biquad()
    // Measurement low-pass (60 kHz Butterworth, 6th order) applied to the
    // deviation/MPX-power path only. An FM demod's noise density rises with
    // f^2 (the noise triangle), so on a weak station the 60..96 kHz band is
    // pure demod noise that vector-sums into the raw composite peaks and
    // inflates MAX/peak/power readings far above the true deviation.
    // Bandlimiting to 60 kHz keeps everything that is really modulated
    // (mono, pilot, stereo, RDS) -- matching how modulation monitors measure.
    // Scopes, spectrum, and the IN level stay raw so the noise stays visible.
    private var measurementLP = BiquadCascade6()
    // Warm-up gate: skip the held-peak / power / separation accumulators for
    // the first second after start so a tuner's pre-lock transient does not
    // poison hold-until-reset values (PEAK +/- read ~full scale forever).
    private var warmupRemaining: Int
    // Composite peak-hold (~2 s exponential decay) -> MAX DEV.
    private var peakHoldComposite: Float = 0.0
    private var peakDecay: Float = 0.999986
    // RDS subcarrier RMS, smoothed (~0.5 s). RMS-referenced to the pilot
    // matches how measuring receivers report RDS injection -- a peak-hold of
    // the DSB-SC biphase envelope over-reads (~1.7x) on data overshoot.
    private var rdsRMS: Float = 0.0

    // Total-deviation peak-hold (hold until reset): raw +/- composite extremes.
    private var posPeakRaw: Float = 0.0
    private var negPeakRaw: Float = 0.0
    // MPX power (BS.412): ~60 s EMA of the composite mean-square.
    private var mpxPowerMS: Float = 0.0
    private var mpxPowerPrimed = false
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
    // `resetRequested`: peak-hold + separation (the "Reset Peaks" button).
    // `fullResetRequested`: everything transient (peaks, separation, MPX-power
    // integrator, BER, trends, RDS decoder) + re-arm warm-up -- used on retune
    // so the previous station's accumulators don't linger.
    private let resetRequested = ManagedAtomic<Bool>(false)
    private let fullResetRequested = ManagedAtomic<Bool>(false)

    // Windowed BER: diff the stream decoder's cumulative block counters per
    // process() call and smooth (~1 s) so the readout tracks current quality.
    private var prevBlocksReceived = 0
    private var prevBlocksValid = 0
    private var berEMA: Float = 0.0

    // Decoded L/R audio for the current block, for the monitor path. Filled by
    // `process`; valid for `[0..<lastBlockCount]`.
    private(set) var decodedL: [Float]
    private(set) var decodedR: [Float]
    private(set) var lastBlockCount = 0

    // GUI display buffers (reused; copied into the snapshot each block).
    private static let scopePoints = 512
    private static let spectrumBins = 512
    private var scopeComposite = [Float](repeating: 0.0, count: scopePoints)
    private var scopeL = [Float](repeating: 0.0, count: scopePoints)
    private var scopeR = [Float](repeating: 0.0, count: scopePoints)
    private var spectrum = MPXSpectrumAnalyzer()
    private var spectrumInput: [Float] = []
    private var spectrumTick = 0

    init(
        sampleRate: Float, preemphasisUS: Int = 50, pilotRefKHz: Float = 6.75,
        fullScaleKHz: Float? = nil, maxBlock: Int = 16384
    ) {
        self.sampleRate = sampleRate
        self.pilotRefKHz = pilotRefKHz
        self.fullScaleKHz = fullScaleKHz
        pilot.configure(sampleRate: sampleRate)
        decoder.configure(sampleRate: sampleRate, preemphasisUS: preemphasisUS)
        rds = RDSSubcarrierDecoder(sampleRate: sampleRate)
        rdsBandpass.configureBandpass(freqHz: 57_000.0, sampleRate: sampleRate, q: 10.0)
        // Clamp below Nyquist for low-rate captures (no RDS there anyway).
        measurementLP.configureLowpass(
            cutoffHz: min(60_000.0, 0.45 * sampleRate), sampleRate: sampleRate)
        warmupRemaining = Int(sampleRate)  // ~1 s
        // ~2 s hold: decay^(2*sr) ~ 1/e.
        peakDecay = expf(-1.0 / (2.0 * sampleRate))
        decodedL = [Float](repeating: 0.0, count: maxBlock)
        decodedR = [Float](repeating: 0.0, count: maxBlock)
    }

    /// Clear the peak-hold and best-separation accumulators (UI "Reset"). Safe
    /// to call from any thread; applied at the top of the next `process`.
    func requestPeakReset() { resetRequested.store(true, ordering: .relaxed) }

    /// Clear ALL transient accumulators + re-arm the warm-up gate + reset the
    /// RDS decoder. Use on retune so the prior station's peaks / MPX power /
    /// BER / RDS text don't carry over. Safe to call from any thread.
    func requestFullReset() { fullResetRequested.store(true, ordering: .relaxed) }

    func process(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let doFullReset = fullResetRequested.exchange(false, ordering: .relaxed)
        if doFullReset {
            // Everything transient -- the new station starts clean.
            mpxPowerMS = 0.0
            mpxPowerPrimed = false
            berEMA = 0.0
            prevBlocksReceived = 0
            prevBlocksValid = 0
            rdsRMS = 0.0
            for i in devHistory.indices { devHistory[i] = 0.0 }
            for i in powerHistory.indices { powerHistory[i] = -30.0 }
            warmupRemaining = Int(sampleRate)  // ~1 s -- skip the relock transient
            rds.reset()
        }
        if doFullReset || resetRequested.exchange(false, ordering: .relaxed) {
            peakHoldComposite = 0.0
            posPeakRaw = 0.0
            negPeakRaw = 0.0
            bestSepDB = 0.0
            sepValid = false
        }
        let n = Float(samples.count)
        let cap = decodedL.count

        var peak: Float = 0.0
        var sumSq: Float = 0.0
        var measSumSq: Float = 0.0
        var rdsSumSq: Float = 0.0
        let inWarmup = warmupRemaining > 0
        var pilotMagMax: Float = 0.0
        var lSq: Float = 0.0
        var rSq: Float = 0.0
        var lr: Float = 0.0
        var mSq: Float = 0.0
        var sSq: Float = 0.0

        var i = 0
        for s in samples {
            let a = fabsf(s)
            if a > peak { peak = a }
            sumSq += s * s

            // Deviation/power measurement path: 60 kHz bandlimited composite
            // (rejects the demod noise triangle above the modulated bands).
            let m = measurementLP.process(s)
            measSumSq += m * m
            let ma = fabsf(m)
            // Composite peak-hold (decay then capture) for MAX DEV.
            peakHoldComposite *= peakDecay
            if !inWarmup {
                if ma > peakHoldComposite { peakHoldComposite = ma }
                // Signed peak-hold (until reset) for +/- deviation asymmetry.
                if m > posPeakRaw { posPeakRaw = m }
                if m < negPeakRaw { negPeakRaw = m }
            }
            // RDS subcarrier power for an RMS-based deviation estimate.
            let rdsBand = rdsBandpass.process(s)
            rdsSumSq += rdsBand * rdsBand

            let p = pilot.process(s)
            if p.mag2 > pilotMagMax { pilotMagMax = p.mag2 }

            // expectedSide = 0 disables the decoder's stereo-collapse self-heal
            // (a meter must not silently reconfigure); programActivity = |s|
            // keeps the noise gate open while signal is present.
            let (l, r) = decoder.process(s, programActivity: a, expectedSide: 0.0)
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
        lastBlockCount = min(samples.count, cap)

        let rms = sqrtf(sumSq / n)
        // PilotPLL lock-in I/Q each converge to (A/2)*{cos,sin}(phi); |I,Q| = A/2.
        let pilotAmp = 2.0 * sqrtf(pilotMagMax)
        // Smooth the RDS subcarrier RMS (~0.5 s) across blocks.
        let blockRDSRMS = sqrtf(rdsSumSq / n)
        rdsRMS = (0.95 * rdsRMS) + (0.05 * blockRDSRMS)
        let corr: Float = (lSq > 1e-12 && rSq > 1e-12) ? (lr / sqrtf(lSq * rSq)) : 0.0

        snap.hasSignal = peak > 1e-4
        snap.inputPeakDBFS = Self.dbfs(peak)
        snap.inputRMSDBFS = Self.dbfs(rms)
        snap.pilotPresent = pilotMagMax > 1e-6
        snap.pilotPercent = peak > 1e-6 ? (pilotAmp / peak * 100.0) : 0.0

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
            snap.rdsDevKHz = rdsRMS * 1.41421356 * fullScale
            snap.maxDevKHz = peakHoldComposite * fullScale
            devScaleKHz = fullScale
        } else if pilotAmp > 1e-5 {
            let scale = pilotRefKHz / pilotAmp
            snap.pilotDevKHz = pilotRefKHz
            // RDS RMS referenced to the pilot RMS (pilotAmp/sqrt2), expressed as
            // the equivalent sine-peak deviation -- the basis measuring
            // receivers use, so it matches an SFP-style RDS readout.
            snap.rdsDevKHz = (rdsRMS * 1.41421356 / pilotAmp) * pilotRefKHz
            snap.maxDevKHz = peakHoldComposite * scale
            devScaleKHz = scale
        } else {
            snap.pilotDevKHz = 0.0
            snap.rdsDevKHz = 0.0
            snap.maxDevKHz = 0.0
            devScaleKHz = nil
        }

        // Total-deviation +/- peak-hold (kHz).
        if let devScaleKHz {
            snap.posPeakDevKHz = posPeakRaw * devScaleKHz
            snap.negPeakDevKHz = negPeakRaw * devScaleKHz
        }

        // MPX power (ITU-R BS.412): EMA the bandlimited composite mean-square
        // (~60 s), then express in dBr vs the power of a +/-19 kHz sine
        // (mean-square 19^2/2 in the kHz domain). beta is the per-block decay.
        let blockMeanSq = measSumSq / n
        let beta = expf(-(n / sampleRate) / 60.0)
        if inWarmup {
            // Don't seed the 60 s integrator from pre-lock transients.
        } else if mpxPowerPrimed {
            mpxPowerMS = mpxPowerMS * beta + blockMeanSq * (1.0 - beta)
        } else {
            mpxPowerMS = blockMeanSq
            mpxPowerPrimed = true
        }
        if let devScaleKHz, mpxPowerPrimed {
            let mpxMSkHz2 = mpxPowerMS * devScaleKHz * devScaleKHz
            let refMSkHz2: Float = 19.0 * 19.0 / 2.0
            snap.mpxPowerDBr = 10.0 * log10f(max(1e-9, mpxMSkHz2 / refMSkHz2))
            snap.mpxPowerValid = true
        } else {
            snap.mpxPowerValid = false
        }

        // Best stereo separation (dB): sample 20*log10(stronger/weaker) only on
        // real, lateralized content (a single-channel / test tone is truest),
        // and peak-hold it -- panned program reads pessimistically low.
        let lRMS = sqrtf(lSq / n)
        let rRMS = sqrtf(rSq / n)
        let hi = max(lRMS, rRMS)
        let lo = min(lRMS, rRMS)
        if !inWarmup, hi > 0.05, lo > 1e-4 {
            let sep = min(60.0, 20.0 * log10f(hi / lo))
            if sep > bestSepDB { bestSepDB = sep; sepValid = true }
        }
        snap.bestSeparationDB = bestSepDB
        snap.separationValid = sepValid
        warmupRemaining = max(0, warmupRemaining - samples.count)

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
        snap.rdsLocked = rds.locked
        snap.rds = rds.state

        let deltaReceived = snap.rds.blocksReceived - prevBlocksReceived
        let deltaValid = snap.rds.blocksValid - prevBlocksValid
        if deltaReceived > 0 {
            let instant = Float(deltaReceived - deltaValid) / Float(deltaReceived)
            berEMA = (0.95 * berEMA) + (0.05 * instant)
            prevBlocksReceived = snap.rds.blocksReceived
            prevBlocksValid = snap.rds.blocksValid
        }
        snap.recentBlockErrorRate = berEMA

        // GUI display buffers. Decimate this block to a fixed point count for
        // the scopes; recompute the composite spectrum every 4th block (~6/s at
        // 8192-frame blocks @ 192 kHz -- ample for a display, cheap on CPU).
        Self.decimate(into: &scopeComposite, from: samples, count: samples.count)
        decodedL.withUnsafeBufferPointer {
            Self.decimate(into: &scopeL, from: $0, count: lastBlockCount)
        }
        decodedR.withUnsafeBufferPointer {
            Self.decimate(into: &scopeR, from: $0, count: lastBlockCount)
        }
        snap.compositeScope = scopeComposite
        snap.decodedLScope = scopeL
        snap.decodedRScope = scopeR

        spectrumTick += 1
        if spectrumTick >= 4 {
            spectrumTick = 0
            if spectrumInput.count != samples.count {
                spectrumInput = [Float](repeating: 0.0, count: samples.count)
            }
            for j in 0..<samples.count { spectrumInput[j] = samples[j] }
            let result = spectrum.compute(
                samples: spectrumInput, validCount: samples.count,
                sampleRate: Double(sampleRate), displayBins: Self.spectrumBins,
                maxDisplayHz: 100_000)
            snap.spectrumDB = result.dbBins
            snap.spectrumMaxHz = result.maxHz
            snap.spectrumNyquistHz = result.nyquistHz
        }
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
    func snapshot() -> MeterSnapshot { snap }

    /// A snapshot whose heap-backed members (RDS arrays + strings) are copied
    /// into independent storage, safe to hand to another thread. The live RDS
    /// decoder keeps mutating its own copy-on-write buffers every block, and
    /// `snap.rds` shares those buffers; reading them on the display thread
    /// while the analysis thread mutates them is undefined behavior (heap
    /// corruption / "pointer being freed was not allocated"). Build the
    /// isolated copy here, on the analysis thread, before publishing.
    func isolatedSnapshot() -> MeterSnapshot {
        var c = snap
        c.rds.groupCounts = snap.rds.groupCounts.map { $0 }
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
        c.devHistoryKHz = snap.devHistoryKHz.map { $0 }
        c.mpxPowerHistoryDBr = snap.mpxPowerHistoryDBr.map { $0 }
        return c
    }

    private static func dbfs(_ x: Float) -> Float { 20.0 * log10f(max(1e-6, x)) }
}
