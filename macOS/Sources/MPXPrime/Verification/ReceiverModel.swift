#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

func renderReceiverMPX(
    config: AppConfig,
    durationSeconds: Double,
    source: (_ frameIndex: Int, _ sampleRate: Double) -> (Float, Float)
) -> [Float] {
    let sampleRate = max(8_000.0, config.sampleRate)
    let frames = max(1, Int((durationSeconds * sampleRate).rounded()))
    let generator = MPXGenerator(config: config, sampleRate: sampleRate)
    var samples = [Float](repeating: 0.0, count: frames)
    for frame in 0..<frames {
        let input = source(frame, sampleRate)
        samples[frame] = generator.renderSingleSample(leftIn: input.0, rightIn: input.1)
    }
    return samples
}

func toneVector(
    samples: [Float],
    sampleRate: Double,
    frequencyHz: Double,
    start: Int,
    count: Int
) -> ToneVector {
    guard count > 0, start >= 0, start + count <= samples.count else {
        return ToneVector()
    }
    let omega = 2.0 * Double.pi * frequencyHz / sampleRate
    var sinSum = 0.0
    var cosSum = 0.0
    for i in 0..<count {
        let phase = omega * Double(start + i)
        let sample = Double(samples[start + i])
        sinSum += sample * sin(phase)
        cosSum += sample * cos(phase)
    }
    let scale = 2.0 / Double(count)
    return ToneVector(sin: sinSum * scale, cos: cosSum * scale)
}

func receiverAnalysisWindow(sampleCount: Int, sampleRate: Double) -> (start: Int, count: Int) {
    let desiredCount = min(sampleCount / 2, max(4096, Int((0.25 * sampleRate).rounded())))
    let count = max(1024, desiredCount)
    let start = max(0, sampleCount - count)
    return (start, min(count, sampleCount - start))
}

func estimatePilotPhase(
    samples: [Float],
    sampleRate: Double,
    start: Int,
    count: Int
) -> (amplitude: Double, phase: Double) {
    let pilot = toneVector(
        samples: samples,
        sampleRate: sampleRate,
        frequencyHz: 19_000.0,
        start: start,
        count: count
    )
    return (pilot.amplitude, atan2(pilot.cos, pilot.sin))
}

func toneBandEnergyDBFS(
    samples: [Float],
    sampleRate: Double,
    lowerHz: Double,
    upperHz: Double,
    start: Int,
    count: Int,
    stepHz: Double = 250.0
) -> Float {
    guard lowerHz <= upperHz, stepHz > 0.0 else { return -200.0 }
    var power = 0.0
    var frequency = lowerHz
    while frequency <= upperHz {
        let vector = toneVector(
            samples: samples,
            sampleRate: sampleRate,
            frequencyHz: frequency,
            start: start,
            count: count
        )
        let amplitude = max(vector.amplitude, 1e-12)
        power += amplitude * amplitude
        frequency += stepHz
    }
    return dbfs(sqrt(max(power, 1e-24)))
}

func demodulatedSideVector(
    samples: [Float],
    sampleRate: Double,
    audioHz: Double,
    pilotPhase: Double,
    start: Int,
    count: Int
) -> ToneVector {
    guard count > 0, start >= 0, start + count <= samples.count else {
        return ToneVector()
    }
    let audioOmega = 2.0 * Double.pi * audioHz / sampleRate
    let pilotOmega = 2.0 * Double.pi * 19_000.0 / sampleRate
    var sinSum = 0.0
    var cosSum = 0.0
    for i in 0..<count {
        let absoluteIndex = Double(start + i)
        let sub = sin(2.0 * ((pilotOmega * absoluteIndex) + pilotPhase))
        let demod = Double(samples[start + i]) * 2.0 * sub
        let audioPhase = audioOmega * absoluteIndex
        sinSum += demod * sin(audioPhase)
        cosSum += demod * cos(audioPhase)
    }
    let scale = 2.0 / Double(count)
    return ToneVector(sin: sinSum * scale, cos: cosSum * scale)
}

func decodeMPXWithReference(
    samples: [Float],
    pilotPhase: Double,
    config: AppConfig,
    programActivity: Float,
    expectedSide: Float
) -> (left: [Float], right: [Float]) {
    var decoder = MPXDecoder()
    decoder.configure(sampleRate: Float(config.sampleRate), preemphasisUS: config.preemphasisUS)
    var left = [Float](repeating: 0.0, count: samples.count)
    var right = [Float](repeating: 0.0, count: samples.count)
    let omega = 2.0 * Double.pi * 19_000.0 / config.sampleRate
    for i in 0..<samples.count {
        let ref = Float(sin(2.0 * ((omega * Double(i)) + pilotPhase)))
        let decoded = decoder.process(
            samples[i],
            referenceSubcarrier: ref,
            programActivity: programActivity,
            expectedSide: expectedSide
        )
        left[i] = decoded.0
        right[i] = decoded.1
    }
    return (left, right)
}

func decodeMPXWithPLL(
    samples: [Float],
    config: AppConfig,
    programActivity: Float,
    expectedSide: Float
) -> (left: [Float], right: [Float]) {
    var decoder = MPXDecoder()
    decoder.configure(sampleRate: Float(config.sampleRate), preemphasisUS: config.preemphasisUS)
    var left = [Float](repeating: 0.0, count: samples.count)
    var right = [Float](repeating: 0.0, count: samples.count)
    for i in 0..<samples.count {
        let decoded = decoder.process(
            samples[i],
            referenceSubcarrier: nil,
            programActivity: programActivity,
            expectedSide: expectedSide
        )
        left[i] = decoded.0
        right[i] = decoded.1
    }
    return (left, right)
}

func receiverToneMetrics(
    config: AppConfig,
    toneHz: Double,
    durationSeconds: Double
) -> ReceiverToneMetrics {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, 0.0)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )
    let decoded = decodeMPXWithReference(
        samples: samples,
        pilotPhase: pilot.phase,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let left = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let right = toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    // The synthetic pilot reference may lock with either 38 kHz polarity,
    // which swaps decoded L/R. Separation is therefore scored as stronger
    // decoded channel vs weaker decoded channel.
    let wanted = max(max(left.amplitude, right.amplitude), 1e-12)
    let crosstalk = max(min(left.amplitude, right.amplitude), 1e-12)
    return ReceiverToneMetrics(
        toneHz: toneHz,
        wantedDBFS: dbfs(wanted),
        crosstalkDBFS: dbfs(crosstalk),
        separationDB: Float(20.0 * log10(wanted / crosstalk))
    )
}

func encoderSidebandMetrics(
    config: AppConfig,
    toneHz: Double,
    drivenChannel: String,
    durationSeconds: Double
) -> EncoderSidebandMetrics {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let amplitude = 0.45
    let driveLeft = drivenChannel == "L"
    // Single-channel sine: produces a baseband (L+R)/2 component at
    // toneHz plus symmetric DSB-SC sidebands at 38 +/- toneHz. Any
    // encoder-side asymmetry between those sidebands (e.g., audio
    // composite bandwidth FIR rolling off 52 kHz harder than 24 kHz
    // for a 14 kHz tone) becomes a direct fingerprint of encoder-side
    // separation loss.
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return driveLeft ? (tone, 0.0) : (0.0, tone)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)

    let mono = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let lower = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: 38_000.0 - toneHz,
        start: window.start,
        count: window.count
    )
    let upper = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: 38_000.0 + toneHz,
        start: window.start,
        count: window.count
    )

    let monoAmp = max(mono.amplitude, 1e-12)
    let lowerAmp = max(lower.amplitude, 1e-12)
    let upperAmp = max(upper.amplitude, 1e-12)
    let sideSumAmp = max(lowerAmp + upperAmp, 1e-12)

    let lowerDB = dbfs(lowerAmp)
    let upperDB = dbfs(upperAmp)
    let monoDB = dbfs(monoAmp)
    let sideSumDB = dbfs(sideSumAmp)
    return EncoderSidebandMetrics(
        drivenChannel: drivenChannel,
        toneHz: toneHz,
        monoDBFS: monoDB,
        lowerSidebandDBFS: lowerDB,
        upperSidebandDBFS: upperDB,
        asymmetryDB: abs(lowerDB - upperDB),
        sideSumDBFS: sideSumDB,
        sideMonoDeltaDB: sideSumDB - monoDB
    )
}

func encoderSidebandMetricsFromSamples(
    samples: [Float],
    config: AppConfig,
    toneHz: Double,
    drivenChannel: String
) -> EncoderSidebandMetrics {
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: config.sampleRate)

    let mono = toneVector(
        samples: samples,
        sampleRate: config.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let lower = toneVector(
        samples: samples,
        sampleRate: config.sampleRate,
        frequencyHz: 38_000.0 - toneHz,
        start: window.start,
        count: window.count
    )
    let upper = toneVector(
        samples: samples,
        sampleRate: config.sampleRate,
        frequencyHz: 38_000.0 + toneHz,
        start: window.start,
        count: window.count
    )

    let monoAmp = max(mono.amplitude, 1e-12)
    let lowerAmp = max(lower.amplitude, 1e-12)
    let upperAmp = max(upper.amplitude, 1e-12)
    let sideSumAmp = max(lowerAmp + upperAmp, 1e-12)

    let lowerDB = dbfs(lowerAmp)
    let upperDB = dbfs(upperAmp)
    let monoDB = dbfs(monoAmp)
    let sideSumDB = dbfs(sideSumAmp)
    return EncoderSidebandMetrics(
        drivenChannel: drivenChannel,
        toneHz: toneHz,
        monoDBFS: monoDB,
        lowerSidebandDBFS: lowerDB,
        upperSidebandDBFS: upperDB,
        asymmetryDB: abs(lowerDB - upperDB),
        sideSumDBFS: sideSumDB,
        sideMonoDeltaDB: sideSumDB - monoDB
    )
}

func receiverToneAnalysis(
    config: AppConfig,
    toneHz: Double,
    durationSeconds: Double
) -> ReceiverToneAnalysis {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, 0.0)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )

    let coherentDecoded = decodeMPXWithReference(
        samples: samples,
        pilotPhase: pilot.phase,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let coherentLeft = toneVector(
        samples: coherentDecoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let coherentRight = toneVector(
        samples: coherentDecoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let coherentWanted = max(max(coherentLeft.amplitude, coherentRight.amplitude), 1e-12)
    let coherentCrosstalk = max(min(coherentLeft.amplitude, coherentRight.amplitude), 1e-12)

    let pllDecoded = decodeMPXWithPLL(
        samples: samples,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let pllLeft = toneVector(
        samples: pllDecoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let pllRight = toneVector(
        samples: pllDecoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let pllWanted = max(max(pllLeft.amplitude, pllRight.amplitude), 1e-12)
    let pllCrosstalk = max(min(pllLeft.amplitude, pllRight.amplitude), 1e-12)
    let pllDecodedMetrics = computeStereoSignalMetrics(
        left: Array(pllDecoded.left[window.start..<(window.start + window.count)]),
        right: Array(pllDecoded.right[window.start..<(window.start + window.count)])
    )

    let mono = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let side = demodulatedSideVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        audioHz: toneHz,
        pilotPhase: pilot.phase,
        start: window.start,
        count: window.count
    )
    let monoAmp = max(mono.amplitude, 1e-12)
    let sideAmp = max(side.amplitude, 1e-12)
    let normalizedSide = side.scaled(by: monoAmp / sideAmp)
    let idealPlus = mono + normalizedSide
    let idealMinus = mono - normalizedSide
    let idealWanted = max(max(idealPlus.amplitude, idealMinus.amplitude), 1e-12)
    let idealCrosstalk = max(min(idealPlus.amplitude, idealMinus.amplitude), 1e-12)

    return ReceiverToneAnalysis(
        coherent: ReceiverToneMetrics(
            toneHz: toneHz,
            wantedDBFS: dbfs(coherentWanted),
            crosstalkDBFS: dbfs(coherentCrosstalk),
            separationDB: Float(20.0 * log10(coherentWanted / coherentCrosstalk))
        ),
        pll: ReceiverPLLRoundTripMetrics(
            toneHz: toneHz,
            wantedDBFS: dbfs(pllWanted),
            crosstalkDBFS: dbfs(pllCrosstalk),
            separationDB: Float(20.0 * log10(pllWanted / pllCrosstalk)),
            decodedRMSDBFS: dbfs(Double(max(pllDecodedMetrics.rms, 1e-12))),
            decodedPeakDBFS: dbfs(Double(max(pllDecodedMetrics.peak, 1e-12))),
            correlation: pllDecodedMetrics.correlation,
            sideToMidRatio: pllDecodedMetrics.sideToMidRatio
        ),
        ideal: ReceiverIdealDecodeMetrics(
            toneHz: toneHz,
            wantedDBFS: dbfs(idealWanted),
            crosstalkDBFS: dbfs(idealCrosstalk),
            separationDB: Float(20.0 * log10(idealWanted / idealCrosstalk)),
            monoDBFS: dbfs(monoAmp),
            sideDBFS: dbfs(sideAmp),
            monoSideDeltaDB: dbfs(sideAmp) - dbfs(monoAmp)
        ),
        encoderSideband: encoderSidebandMetricsFromSamples(
            samples: samples,
            config: cfg,
            toneHz: toneHz,
            drivenChannel: "L"
        )
    )
}

/// Per-stage isolation sweep for the HF stereo-separation
/// investigation. Renders L-only sines at 1 / 10 / 14 kHz through the
/// chain with each stage individually disabled, and reports the
/// resulting asymmetry + side-vs-mono delta against the baseline (all
/// stages enabled). The stage whose row most-moves the metric is the
/// stage contributing that loss.
struct StageIsolationRow {
    let label: String
    let metricsByTone: [Double: EncoderSidebandMetrics]
}

func runEncoderStageIsolationSweep(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> [StageIsolationRow] {
    let tones: [Double] = [1_000.0, 10_000.0, 14_000.0]

    func measure(label: String, mutate: (inout AppConfig) -> Void) -> StageIsolationRow {
        var cfg = baseConfig
        mutate(&cfg)
        var byTone: [Double: EncoderSidebandMetrics] = [:]
        for tone in tones {
            byTone[tone] = encoderSidebandMetrics(
                config: cfg,
                toneHz: tone,
                drivenChannel: "L",
                durationSeconds: durationSeconds
            )
        }
        return StageIsolationRow(label: label, metricsByTone: byTone)
    }

    var rows: [StageIsolationRow] = []
    rows.append(measure(label: "baseline (full chain)") { _ in })
    rows.append(measure(label: "bass clipper OFF") { $0.bassClipperEnabled = false })
    rows.append(measure(label: "HF clipper OFF") { $0.hfClipperEnabled = false })
    rows.append(measure(label: "distortion-cancel clip OFF") { $0.dcClipperEnabled = false })
    rows.append(measure(label: "composite clipper OFF") { $0.compositeClipperEnabled = false })
    rows.append(measure(label: "audio composite softclip OFF") { $0.audioCompositeSoftClipEnabled = false })
    rows.append(measure(label: "audio composite smoother OFF") { $0.audioCompositeSmootherEnabled = false })
    rows.append(measure(label: "final MPX safety OFF") { $0.finalMPXSoftClipEnabled = false })
    rows.append(measure(label: "encoder FIR OFF") { $0.encoderFIREnabled = false })
    rows.append(measure(label: "pre-encode limiter OFF") { $0.preEncodeAudioLimiterEnabled = false })
    // Pre-emphasis disable also disables the 19 kHz pilot notch in
    // the audio path (they share the `preemphasisUS > 0` gate in
    // `configureAudioPath`). The pilot notch is only meaningful when
    // pre-emphasis is on, so the joint toggle is the right unit.
    rows.append(measure(label: "pre-emphasis + pilot notch OFF") { $0.preemphasisUS = 0 })
    return rows
}

/// Pilot/RDS phase-lock stability. The RDS 57 kHz subcarrier must stay
/// locked to 3x the 19 kHz pilot (EN 50067 Sec 2.1.4). If the encoder
/// derives the two from different phase representations they slowly slip;
/// this measures that slip by comparing the pilot-vs-RDS phase
/// relationship in an early window against a late window of one long
/// render. A locked encoder holds the relationship flat (~0 deg drift);
/// a slipping one accumulates degrees over the render.
struct PilotRDSLockMetrics {
    let earlyPilotPhaseDeg: Float
    let latePilotPhaseDeg: Float
    let earlyRDSPhaseDeg: Float
    let lateRDSPhaseDeg: Float
    /// Change in (RDS carrier phase - 3x pilot phase) from early to late
    /// window, wrapped to +/-90 deg (squaring recovery is mod 180).
    let lockDriftDeg: Float
    let renderSeconds: Double
}

/// Squaring carrier-phase recovery for the BPSK RDS subcarrier. A 57 kHz
/// bandpass isolates the RDS band; complex demod against an absolute-
/// sample-index 57 kHz reference brings it to baseband; squaring strips
/// the +/-1 biphase modulation. Returns 0.5*arg of the coherent sum --
/// the RDS carrier phase relative to the ideal 57 kHz reference, in
/// radians, ambiguous mod pi.
func rdsCarrierResidualPhase(
    samples: [Float],
    sampleRate: Double,
    start: Int,
    count: Int
) -> Double {
    guard count > 0, start >= 0, start + count <= samples.count else { return 0.0 }
    var bp = Biquad()
    bp.configureBandpass(freqHz: 57_000.0, sampleRate: Float(sampleRate), q: 14.0)
    // Prime the filter on a short run-up so its state is settled at the
    // window start.
    let primeStart = max(0, start - 2048)
    for i in primeStart..<start {
        _ = bp.process(samples[i])
    }
    let omega = 2.0 * Double.pi * 57_000.0 / sampleRate
    var reAcc = 0.0
    var imAcc = 0.0
    for i in 0..<count {
        let n = Double(start + i)
        let s = Double(bp.process(samples[start + i]))
        let zr = s * cos(omega * n)
        let zi = -s * sin(omega * n)
        reAcc += (zr * zr) - (zi * zi)
        imAcc += 2.0 * zr * zi
    }
    return 0.5 * atan2(imAcc, reAcc)
}

func pilotRDSLockMetrics(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> PilotRDSLockMetrics {
    var cfg = baseConfig
    cfg.monoMode = false
    cfg.enRDS = true
    // Stereo content so the pilot reads cleanly; modest level so nothing
    // saturates and shifts phase.
    let amplitude = 0.30
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let t = Double(frame) / sampleRate
        let l = Float(amplitude * sin(2.0 * Double.pi * 1_000.0 * t))
        let r = Float(amplitude * sin(2.0 * Double.pi * 1_000.0 * t + 0.6))
        return (l, r)
    }
    let sr = cfg.sampleRate
    let n = samples.count
    // Early / late analysis windows, each ~0.2 s, taken near the ends.
    let win = max(4096, min(n / 4, Int((0.2 * sr).rounded())))
    let earlyStart = min(max(0, n / 8), max(0, n - win))
    let lateStart = max(earlyStart + win, n - win)

    func pilotPhase(_ start: Int) -> Double {
        estimatePilotPhase(samples: samples, sampleRate: sr, start: start, count: win).phase
    }
    let earlyPilot = pilotPhase(earlyStart)
    let latePilot = pilotPhase(lateStart)
    let earlyRDS = rdsCarrierResidualPhase(samples: samples, sampleRate: sr, start: earlyStart, count: win)
    let lateRDS = rdsCarrierResidualPhase(samples: samples, sampleRate: sr, start: lateStart, count: win)

    // Lock error = RDS phase - 3*pilot phase. Compare early vs late; the
    // absolute value is meaningless (mod-pi ambiguity from squaring),
    // only the drift between windows matters. Wrap to +/- pi/2.
    func wrapHalfPi(_ x: Double) -> Double {
        var v = x
        let pi = Double.pi
        while v > pi / 2 { v -= pi }
        while v < -pi / 2 { v += pi }
        return v
    }
    let earlyErr = earlyRDS - 3.0 * earlyPilot
    let lateErr = lateRDS - 3.0 * latePilot
    let drift = wrapHalfPi(lateErr - earlyErr)
    let toDeg = 180.0 / Double.pi
    return PilotRDSLockMetrics(
        earlyPilotPhaseDeg: Float(earlyPilot * toDeg),
        latePilotPhaseDeg: Float(latePilot * toDeg),
        earlyRDSPhaseDeg: Float(earlyRDS * toDeg),
        lateRDSPhaseDeg: Float(lateRDS * toDeg),
        lockDriftDeg: Float(drift * toDeg),
        renderSeconds: Double(n) / sr
    )
}

/// Guard-band cancellation depth for the composite clipper. The clipper
/// removes its own intermod from the pilot guard (17-21 kHz) and RDS
/// guard (55-59 kHz) bands before the constant-amplitude subcarriers are
/// injected. This measures how deep that removal actually is.
///
/// Methodology: drive the clipper hard with a dense stereo program but
/// suppress the cleanly-injected subcarriers that would otherwise mask
/// the residual — pilot level forced to 0 (the 17-21 kHz band then holds
/// only clipper IM) and RDS off (the 55-59 kHz band holds only clipper
/// IM). The 38 kHz stereo DSB-SC stays on so the clipper sees a full
/// 0-53 kHz composite and generates realistic out-of-band IM. Render
/// once with the guard's cancellation flag on, once off; depth is the
/// band-energy delta. Larger = the guard is doing more work.
struct GuardBandCancellationMetrics {
    let pilotGuardResidualOnDBFS: Float
    let pilotGuardResidualOffDBFS: Float
    let pilotGuardDepthDB: Float
    let rdsGuardResidualOnDBFS: Float
    let rdsGuardResidualOffDBFS: Float
    let rdsGuardDepthDB: Float
}

func guardBandCancellationMetrics(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> GuardBandCancellationMetrics {
    func render(cancelPilot: Bool, cancelRDS: Bool) -> [Float] {
        var cfg = baseConfig
        cfg.monoMode = false
        cfg.enRDS = false
        cfg.pilotLevel = 0.0
        cfg.compositeClipperEnabled = true
        cfg.compositeClipperCancelPilot = cancelPilot
        cfg.compositeClipperCancelRDS = cancelRDS
        // Isolate the composite clipper: disable every other nonlinearity
        // so the only source of guard-band IM is the composite clipper
        // itself. Otherwise upstream clipper/limiter IM dominates the
        // guard bands and masks the cancellation depth we want to gate.
        cfg.bassClipperEnabled = false
        cfg.hfClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.audioCompositeSoftClipEnabled = false
        cfg.finalMPXSoftClipEnabled = false
        cfg.preEncodeAudioLimiterEnabled = false
        // Push the clipper hard so the guard bands carry measurable IM.
        cfg.finalDriveDB = min(20.0, baseConfig.finalDriveDB + 8.0)
        return renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            // Dense, hard-panned multitone with HF energy so clipping
            // throws IM up into the stereo / RDS region.
            let env = 0.85 + (0.10 * sin(2.0 * Double.pi * 0.5 * t))
            let a = sin(2.0 * Double.pi * 440.0 * t)
            let b = sin(2.0 * Double.pi * 3100.0 * t)
            let c = sin(2.0 * Double.pi * 7700.0 * t)
            let d = sin(2.0 * Double.pi * 13_500.0 * t)
            let left = Float(env) * Float((0.30 * a) + (0.26 * b) + (0.24 * c) + (0.20 * d))
            let right = Float(env) * Float((0.28 * a) - (0.24 * b) + (0.22 * c) - (0.20 * d))
            return (left, right)
        }
    }

    func bandEnergy(_ samples: [Float], lowerHz: Double, upperHz: Double) -> Float {
        let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: baseConfig.sampleRate)
        return toneBandEnergyDBFS(
            samples: samples,
            sampleRate: baseConfig.sampleRate,
            lowerHz: lowerHz,
            upperHz: upperHz,
            start: window.start,
            count: window.count,
            stepHz: 250.0
        )
    }

    let bothOn = render(cancelPilot: true, cancelRDS: true)
    let pilotOff = render(cancelPilot: false, cancelRDS: true)
    let rdsOff = render(cancelPilot: true, cancelRDS: false)

    let pilotOnDB = bandEnergy(bothOn, lowerHz: 17_000.0, upperHz: 21_000.0)
    let pilotOffDB = bandEnergy(pilotOff, lowerHz: 17_000.0, upperHz: 21_000.0)
    let rdsOnDB = bandEnergy(bothOn, lowerHz: 55_000.0, upperHz: 59_000.0)
    let rdsOffDB = bandEnergy(rdsOff, lowerHz: 55_000.0, upperHz: 59_000.0)

    return GuardBandCancellationMetrics(
        pilotGuardResidualOnDBFS: pilotOnDB,
        pilotGuardResidualOffDBFS: pilotOffDB,
        pilotGuardDepthDB: pilotOffDB - pilotOnDB,
        rdsGuardResidualOnDBFS: rdsOnDB,
        rdsGuardResidualOffDBFS: rdsOffDB,
        rdsGuardDepthDB: rdsOffDB - rdsOnDB
    )
}

func receiverPLLRoundTripMetrics(
    config: AppConfig,
    toneHz: Double,
    durationSeconds: Double
) -> ReceiverPLLRoundTripMetrics {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, 0.0)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let decoded = decodeMPXWithPLL(
        samples: samples,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let left = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let right = toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let wanted = max(max(left.amplitude, right.amplitude), 1e-12)
    let crosstalk = max(min(left.amplitude, right.amplitude), 1e-12)
    let decodedMetrics = computeStereoSignalMetrics(
        left: Array(decoded.left[window.start..<(window.start + window.count)]),
        right: Array(decoded.right[window.start..<(window.start + window.count)])
    )
    return ReceiverPLLRoundTripMetrics(
        toneHz: toneHz,
        wantedDBFS: dbfs(wanted),
        crosstalkDBFS: dbfs(crosstalk),
        separationDB: Float(20.0 * log10(wanted / crosstalk)),
        decodedRMSDBFS: dbfs(Double(max(decodedMetrics.rms, 1e-12))),
        decodedPeakDBFS: dbfs(Double(max(decodedMetrics.peak, 1e-12))),
        correlation: decodedMetrics.correlation,
        sideToMidRatio: decodedMetrics.sideToMidRatio
    )
}

func receiverMonoMetrics(
    config: AppConfig,
    durationSeconds: Double
) -> ReceiverMonoMetrics {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let toneHz = 1_000.0
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, tone)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )
    let decoded = decodeMPXWithReference(
        samples: samples,
        pilotPhase: pilot.phase,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let mid = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    ) + toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let side = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    ) - toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let midAmp = max(mid.amplitude * 0.5, 1e-12)
    let sideAmp = max(side.amplitude * 0.5, 1e-12)
    return ReceiverMonoMetrics(
        midDBFS: dbfs(midAmp),
        sideDBFS: dbfs(sideAmp),
        sideRejectionDB: Float(20.0 * log10(midAmp / sideAmp))
    )
}

func receiverNoPilotMetrics(
    config: AppConfig,
    durationSeconds: Double
) -> ReceiverNoPilotMetrics {
    var cfg = config
    cfg.monoMode = true
    cfg.enRDS = false
    let toneHz = 1_000.0
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, tone)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )
    let decoded = decodeMPXWithPLL(
        samples: samples,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let leftVector = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let rightVector = toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let mid = leftVector + rightVector
    let side = leftVector - rightVector
    let midAmp = max(mid.amplitude * 0.5, 1e-12)
    let sideAmp = max(side.amplitude * 0.5, 1e-12)
    let decodedMetrics = computeStereoSignalMetrics(
        left: Array(decoded.left[window.start..<(window.start + window.count)]),
        right: Array(decoded.right[window.start..<(window.start + window.count)])
    )
    return ReceiverNoPilotMetrics(
        pilotPercent: Float(pilot.amplitude * 100.0),
        midDBFS: dbfs(midAmp),
        sideDBFS: dbfs(sideAmp),
        sideRejectionDB: Float(20.0 * log10(midAmp / sideAmp)),
        correlation: decodedMetrics.correlation
    )
}

func receiverSubcarrierMetrics(
    config: AppConfig,
    durationSeconds: Double
) -> ReceiverSubcarrierMetrics {
    var cfg = config
    cfg.monoMode = false
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { _, _ in
        (0.0, 0.0)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )
    let rdsBand = toneBandEnergyDBFS(
        samples: samples,
        sampleRate: cfg.sampleRate,
        lowerHz: 55_000.0,
        upperHz: 59_000.0,
        start: window.start,
        count: window.count
    )
    let rdsCenter = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: 57_000.0,
        start: window.start,
        count: window.count
    )
    let wrappedDegrees = fmod((pilot.phase * 180.0 / Double.pi) + 360.0, 360.0)
    return ReceiverSubcarrierMetrics(
        pilotPercent: Float(pilot.amplitude * 100.0),
        pilotPhaseDegrees: Float(wrappedDegrees),
        rdsBandDBFS: rdsBand,
        rdsCenterDBFS: dbfs(rdsCenter.amplitude)
    )
}

func runReceiverModelVerification(
    baseConfig: AppConfig,
    configPath: String,
    durationSeconds: Double,
    captureBaseline: Bool = false,
    strictBaseline: Bool = false
) -> Int32 {
    let duration = max(1.0, durationSeconds)
    let pllDuration = max(3.0, durationSeconds)
    let diagnosticDuration = max(0.5, min(duration, 0.75))
    let toneFrequencies = [1_000.0, 10_000.0, 14_000.0]
    let receiverToneAnalyses = toneFrequencies.map {
        receiverToneAnalysis(config: baseConfig, toneHz: $0, durationSeconds: pllDuration)
    }
    let toneMetrics = receiverToneAnalyses.map(\.coherent)
    let pllRoundTripMetrics = receiverToneAnalyses.map(\.pll)
    let idealDecodeMetrics = receiverToneAnalyses.map(\.ideal)
    var encoderSidebandMetricsList: [EncoderSidebandMetrics] = []
    for analysis in receiverToneAnalyses {
        encoderSidebandMetricsList.append(analysis.encoderSideband)
        encoderSidebandMetricsList.append(
            encoderSidebandMetrics(
                config: baseConfig,
                toneHz: analysis.encoderSideband.toneHz,
                drivenChannel: "R",
                durationSeconds: diagnosticDuration
            )
        )
    }
    let stageIsolationRows = runEncoderStageIsolationSweep(
        baseConfig: baseConfig,
        durationSeconds: diagnosticDuration
    )
    let mono = receiverMonoMetrics(config: baseConfig, durationSeconds: duration)
    let noPilot = receiverNoPilotMetrics(config: baseConfig, durationSeconds: duration)
    let subcarriers = receiverSubcarrierMetrics(config: baseConfig, durationSeconds: duration)
    let guardBands = guardBandCancellationMetrics(
        baseConfig: baseConfig,
        durationSeconds: pllDuration
    )
    let pilotRDSLock = baseConfig.enRDS
        ? pilotRDSLockMetrics(baseConfig: baseConfig, durationSeconds: max(5.0, durationSeconds))
        : nil

    print("Receiver Model")
    print("Scope: coherent stereo decode, PLL external-style decode, mono/no-pilot behavior, pilot/RDS spectral checks")
    print("")
    print("Stereo Decode")
    print("Tone Hz  Wanted   Xtalk    Sep")
    print("-------  -------  -------  -----")

    var warnings: [String] = []
    var notes: [String] = []
    for metric in toneMetrics {
        let minimumSeparation: Float = metric.toneHz >= 14_000.0 ? 16.0 : 18.0
        if metric.separationDB < minimumSeparation {
            warnings.append(
                "\(Int(metric.toneHz)) Hz separation \(String(format: "%.1f", metric.separationDB)) dB < \(String(format: "%.1f", minimumSeparation)) dB"
            )
        }
        print(
            "\(leftPadded(String(format: "%.0f", metric.toneHz), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.wantedDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.crosstalkDBFS), width: 7))"
                + "  \(String(format: "%5.1f", metric.separationDB))"
        )
    }

    for metric in pllRoundTripMetrics {
        let minimumSeparation: Float = metric.toneHz >= 14_000.0 ? 16.0 : 18.0
        if metric.separationDB < minimumSeparation {
            warnings.append(
                "PLL external-style \(Int(metric.toneHz)) Hz separation \(String(format: "%.1f", metric.separationDB)) dB < \(String(format: "%.1f", minimumSeparation)) dB"
            )
        }
        if metric.decodedRMSDBFS < -42.0 {
            warnings.append(
                "PLL external-style \(Int(metric.toneHz)) Hz decoded RMS \(String(format: "%.1f", metric.decodedRMSDBFS)) dBFS is unexpectedly low"
            )
        }
    }
    for ideal in idealDecodeMetrics {
        guard let production = toneMetrics.first(where: { $0.toneHz == ideal.toneHz }) else { continue }
        let gap = ideal.separationDB - production.separationDB
        if gap > 6.0 {
            notes.append(
                "ideal receiver \(Int(ideal.toneHz)) Hz separation is \(String(format: "%.1f", gap)) dB above production decoder; audit MPXDecoder filters before encoder tuning"
            )
        }
    }
    if mono.sideRejectionDB < 26.0 {
        warnings.append(
            "mono side rejection \(String(format: "%.1f", mono.sideRejectionDB)) dB < 26.0 dB"
        )
    }
    if noPilot.pilotPercent > 0.50 {
        warnings.append(
            "mono MPX no-pilot residual \(String(format: "%.2f", noPilot.pilotPercent))% > 0.50%"
        )
    }
    if noPilot.sideRejectionDB < 26.0 {
        warnings.append(
            "mono MPX no-pilot side rejection \(String(format: "%.1f", noPilot.sideRejectionDB)) dB < 26.0 dB"
        )
    }
    if subcarriers.pilotPercent < 6.5 || subcarriers.pilotPercent > 9.5 {
        warnings.append(
            "pilot level \(String(format: "%.2f", subcarriers.pilotPercent))% outside 6.5-9.5%"
        )
    }
    if baseConfig.enRDS && subcarriers.rdsBandDBFS < -60.0 {
        warnings.append(
            "RDS band energy \(String(format: "%.1f", subcarriers.rdsBandDBFS)) dBFS below -60 dBFS"
        )
    }
    if baseConfig.enRDS && subcarriers.rdsCenterDBFS > subcarriers.rdsBandDBFS - 8.0 {
        warnings.append(
            "RDS center null \(String(format: "%.1f", subcarriers.rdsCenterDBFS)) dBFS is not at least 8 dB below band energy \(String(format: "%.1f", subcarriers.rdsBandDBFS)) dBFS"
        )
    }

    print("")
    print("PLL External-Style Decode")
    print("Tone Hz  Wanted   Xtalk    Sep    RMS     Peak   Corr   S/M")
    print("-------  -------  -------  -----  ------  ------  -----  ----")
    for metric in pllRoundTripMetrics {
        print(
            "\(leftPadded(String(format: "%.0f", metric.toneHz), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.wantedDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.crosstalkDBFS), width: 7))"
                + "  \(String(format: "%5.1f", metric.separationDB))"
                + "  \(leftPadded(String(format: "%.1f", metric.decodedRMSDBFS), width: 6))"
                + "  \(leftPadded(String(format: "%.1f", metric.decodedPeakDBFS), width: 6))"
                + "  \(String(format: "%5.2f", metric.correlation))"
                + "  \(String(format: "%4.2f", metric.sideToMidRatio))"
        )
    }

    print("")
    print("Ideal Receiver Decode (raw coherent M/S, no receiver filters)")
    print("Separation is scored after ideal side-gain normalization; S-M Delta reports raw side-vs-mono balance.")
    print("Tone Hz  Wanted   Xtalk    Sep    Mono    Side   S-M Delta  Gap vs Prod")
    print("-------  -------  -------  -----  ------  ------  ---------  -----------")
    for metric in idealDecodeMetrics {
        let productionSep = toneMetrics.first(where: { $0.toneHz == metric.toneHz })?.separationDB
            ?? metric.separationDB
        let gap = metric.separationDB - productionSep
        print(
            "\(leftPadded(String(format: "%.0f", metric.toneHz), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.wantedDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.crosstalkDBFS), width: 7))"
                + "  \(String(format: "%5.1f", metric.separationDB))"
                + "  \(leftPadded(String(format: "%.1f", metric.monoDBFS), width: 6))"
                + "  \(leftPadded(String(format: "%.1f", metric.sideDBFS), width: 6))"
                + "  \(String(format: "%+9.2f", metric.monoSideDeltaDB))"
                + "  \(String(format: "%+11.1f", gap))"
        )
    }

    print("")
    print("Encoder-Side Sidebands (raw MPX, pre-MPXDecoder)")
    print("Tap point: composite output before deemphasis / 15.5 kHz LP / pilot/RDS notches.")
    print("Drive: single-channel sine. Lower/Upper at 38 +/- toneHz. Asymm = |lower-upper|.")
    print("SideSum = |lower|+|upper|. SideDelta = SideSum - Mono (0 dB = perfect DSB-SC balance).")
    print("")
    print("Ch  Tone Hz  Mono     Lower    Upper    Asymm  SideSum  SideDelta")
    print("--  -------  -------  -------  -------  -----  -------  ---------")
    for metric in encoderSidebandMetricsList {
        print(
            "\(padded(metric.drivenChannel, width: 2))"
                + "  \(leftPadded(String(format: "%.0f", metric.toneHz), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.monoDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.lowerSidebandDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.upperSidebandDBFS), width: 7))"
                + "  \(String(format: "%5.2f", metric.asymmetryDB))"
                + "  \(leftPadded(String(format: "%.1f", metric.sideSumDBFS), width: 7))"
                + "  \(String(format: "%+8.2f", metric.sideMonoDeltaDB))"
        )
    }

    print("")
    print("Stage-Isolation Sweep (encoder-side, L-only sine, deltas vs baseline)")
    print("SideDelta col: SideSum - Mono (0 dB = balanced DSB-SC).")
    print("Asym col: |lower - upper| sideband dB. Bigger delta-vs-baseline = bigger contribution from that stage.")
    print("")
    print("Stage                          1k Asym  1k SideDel  10k Asym  10k SideDel  14k Asym  14k SideDel")
    print("-----------------------------  -------  ----------  --------  -----------  --------  -----------")
    if let baseline = stageIsolationRows.first {
        for row in stageIsolationRows {
            let a1 = row.metricsByTone[1_000.0]
            let a10 = row.metricsByTone[10_000.0]
            let a14 = row.metricsByTone[14_000.0]
            let label = padded(row.label, width: 29)
            let isBaseline = row.label == baseline.label
            func diffOrAbs(
                _ row: EncoderSidebandMetrics?,
                _ base: EncoderSidebandMetrics?,
                _ keyPath: KeyPath<EncoderSidebandMetrics, Float>
            ) -> String {
                guard let row = row else { return "  -    " }
                let value = row[keyPath: keyPath]
                if isBaseline { return String(format: "%+6.2f ", value) }
                guard let base = base else { return String(format: "%+6.2f ", value) }
                let delta = value - base[keyPath: keyPath]
                return String(format: "%+6.2f ", delta)
            }
            let b1 = baseline.metricsByTone[1_000.0]
            let b10 = baseline.metricsByTone[10_000.0]
            let b14 = baseline.metricsByTone[14_000.0]
            print(
                "\(label)"
                    + "  \(diffOrAbs(a1, b1, \.asymmetryDB))"
                    + "  \(diffOrAbs(a1, b1, \.sideMonoDeltaDB))"
                    + "    \(diffOrAbs(a10, b10, \.asymmetryDB))"
                    + "   \(diffOrAbs(a10, b10, \.sideMonoDeltaDB))"
                    + "    \(diffOrAbs(a14, b14, \.asymmetryDB))"
                    + "   \(diffOrAbs(a14, b14, \.sideMonoDeltaDB))"
            )
        }
    }

    print("")
    print("Mono Compatibility")
    print(
        "Mid \(String(format: "%.1f", mono.midDBFS)) dBFS"
            + "  Side \(String(format: "%.1f", mono.sideDBFS)) dBFS"
            + "  Rejection \(String(format: "%.1f", mono.sideRejectionDB)) dB"
    )
    print(
        "No-pilot MPX: Pilot \(String(format: "%.2f", noPilot.pilotPercent))%"
            + "  Mid \(String(format: "%.1f", noPilot.midDBFS)) dBFS"
            + "  Side \(String(format: "%.1f", noPilot.sideDBFS)) dBFS"
            + "  Rejection \(String(format: "%.1f", noPilot.sideRejectionDB)) dB"
            + "  Corr \(String(format: "%.2f", noPilot.correlation))"
    )

    print("")
    print("Subcarriers")
    print(
        "Pilot \(String(format: "%.2f", subcarriers.pilotPercent))%"
            + "  Phase \(String(format: "%.1f", subcarriers.pilotPhaseDegrees)) deg"
            + "  RDS band \(String(format: "%.1f", subcarriers.rdsBandDBFS)) dBFS"
            + "  center \(String(format: "%.1f", subcarriers.rdsCenterDBFS)) dBFS"
    )

    print("")
    print("Guard-Band Cancellation (clipper driven hard, subcarriers suppressed)")
    print("Depth = residual with guard OFF minus guard ON. Larger = guard removes more clipper IM.")
    print("Guard        Band        Resid ON   Resid OFF  Depth")
    print("-----------  ----------  ---------  ---------  -----")
    print(
        "pilot 17-21  17-21 kHz "
            + "  \(leftPadded(String(format: "%.1f", guardBands.pilotGuardResidualOnDBFS), width: 9))"
            + "  \(leftPadded(String(format: "%.1f", guardBands.pilotGuardResidualOffDBFS), width: 9))"
            + "  \(String(format: "%5.1f", guardBands.pilotGuardDepthDB))"
    )
    print(
        "rds 55-59    55-59 kHz "
            + "  \(leftPadded(String(format: "%.1f", guardBands.rdsGuardResidualOnDBFS), width: 9))"
            + "  \(leftPadded(String(format: "%.1f", guardBands.rdsGuardResidualOffDBFS), width: 9))"
            + "  \(String(format: "%5.1f", guardBands.rdsGuardDepthDB))"
    )
    // Soft floor: an enabled guard that removes essentially nothing is a
    // regression (cancellation FIR misconfigured / mis-aligned). The
    // threshold is deliberately low so this gates true breakage, not the
    // exact depth (the exact number is the human-read / baseline metric).
    if baseConfig.compositeClipperEnabled && baseConfig.compositeClipperCancelPilot
        && guardBands.pilotGuardDepthDB < 3.0 {
        warnings.append(
            "pilot guard cancellation depth \(String(format: "%.1f", guardBands.pilotGuardDepthDB)) dB < 3.0 dB (guard enabled but not removing IM)"
        )
    }
    if baseConfig.compositeClipperEnabled && baseConfig.compositeClipperCancelRDS
        && guardBands.rdsGuardDepthDB < 3.0 {
        warnings.append(
            "RDS guard cancellation depth \(String(format: "%.1f", guardBands.rdsGuardDepthDB)) dB < 3.0 dB (guard enabled but not removing IM)"
        )
    }

    if let lock = pilotRDSLock {
        print("")
        print("Pilot/RDS Phase Lock (RDS 57 kHz must track 3x pilot; drift over the render)")
        print("Render \(String(format: "%.1f", lock.renderSeconds)) s   Pilot early/late deg   RDS early/late deg   Lock drift")
        print(
            "             "
                + "  \(String(format: "%+7.1f", lock.earlyPilotPhaseDeg)) / \(String(format: "%+7.1f", lock.latePilotPhaseDeg))"
                + "   \(String(format: "%+7.1f", lock.earlyRDSPhaseDeg)) / \(String(format: "%+7.1f", lock.lateRDSPhaseDeg))"
                + "   \(String(format: "%+6.2f", lock.lockDriftDeg)) deg"
        )
        // A locked encoder holds RDS at exactly 3x pilot, so the relative
        // phase is flat over the render. Visible drift means the two
        // subcarriers are derived from diverging phase representations.
        if abs(lock.lockDriftDeg) > 3.0 {
            warnings.append(
                "pilot/RDS lock drift \(String(format: "%.2f", lock.lockDriftDeg)) deg over \(String(format: "%.1f", lock.renderSeconds)) s exceeds 3.0 deg (RDS not strictly locked to 3x pilot)"
            )
        }
    }

    // Stored receiver baseline (separate receiver.json): pin the decode
    // separation + subcarrier health so regressions are caught instead of
    // sailing past the loose inline thresholds. tone/pll metrics are indexed
    // by toneFrequencies [1k, 10k, 14k].
    let receiverRecord = ReceiverBaselineRecord(
        coherentSep1k: toneMetrics[0].separationDB,
        coherentSep10k: toneMetrics[1].separationDB,
        coherentSep14k: toneMetrics[2].separationDB,
        pllSep1k: pllRoundTripMetrics[0].separationDB,
        pllSep10k: pllRoundTripMetrics[1].separationDB,
        pllSep14k: pllRoundTripMetrics[2].separationDB,
        noPilotPilotPercent: noPilot.pilotPercent,
        subcarrierPilotPercent: subcarriers.pilotPercent,
        pilotGuardDepthDB: guardBands.pilotGuardDepthDB,
        rdsGuardDepthDB: guardBands.rdsGuardDepthDB
    )
    let receiverBaselineURL = defaultReceiverBaselinePath()
    var receiverDrift: [BaselineDriftFinding] = []
    var captureNote: String?
    if captureBaseline {
        let file = ReceiverBaselineFile(
            schemaVersion: ReceiverBaselineFile.currentSchemaVersion,
            capturedAt: verifierBaselineTimestampNow(),
            configPath: configPath,
            renderSampleRateHz: Int(baseConfig.sampleRate),
            metrics: receiverRecord
        )
        do {
            try saveReceiverBaseline(file, to: receiverBaselineURL)
            captureNote = "Receiver baseline captured: \(receiverBaselineURL.path)"
        } catch {
            captureNote = "Receiver baseline capture FAILED: \(error)"
        }
    } else if FileManager.default.fileExists(atPath: receiverBaselineURL.path) {
        do {
            let stored = try loadReceiverBaseline(from: receiverBaselineURL)
            receiverDrift = compareReceiverMetrics(measured: receiverRecord, baseline: stored.metrics)
        } catch {
            print("Receiver baseline: failed to load (\(error))")
        }
    }

    print("")
    print("Assessment")
    if !notes.isEmpty {
        print("Receiver notes:")
        for note in notes { print("- \(note)") }
    }
    if let captureNote { print(captureNote) }
    if !receiverDrift.isEmpty {
        print("Receiver baseline drift (\(receiverDrift.count) finding\(receiverDrift.count == 1 ? "" : "s")):")
        for finding in receiverDrift { print("- \(finding.formattedLine)") }
    }
    if !warnings.isEmpty {
        print("Receiver warnings:")
        for warning in warnings { print("- \(warning)") }
    }

    // Exit code, mirroring the composite path: stored-baseline drift is a hard
    // WARN (2) under --baseline-strict, else TIGHT (1); inline warnings are
    // TIGHT (1); otherwise PASS (0).
    if !receiverDrift.isEmpty {
        if strictBaseline {
            print("Result: WARN - stored receiver-baseline drift in --baseline-strict mode.")
            return 2
        }
        print("Result: TIGHT - receiver-baseline drift detected (use --baseline-strict to fail the run).")
        return 1
    }
    if !warnings.isEmpty {
        print("Result: TIGHT - receiver-model checks need review.")
        return 1
    }
    print("Result: OK - receiver-model decode checks passed.")
    return 0
}
