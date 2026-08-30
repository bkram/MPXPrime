#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

// MARK: - HF transient (hi-hat / cymbal) distortion gate (--verify-hf-transients)
//
// Field finding 2026-08-29: hi-hats and cymbals distort on air. After 50 us
// pre-emphasis the 5-15 kHz content IS the peak, so every nonlinearity
// downstream of pre-emphasis acts on it first. This gate measures, receiver-
// side (MPXDecoder, de-emphasised), what each chain variant does to HF
// transients, so the culprit stage is named with numbers before DSP is
// changed and any fix is judged by the same numbers afterwards.
//
// Metrics per (chain variant, scenario):
//   HF SINAD  -- decoded power at the known hat partials vs everything else
//                in 300 Hz-15 kHz (excluding the bed fundamentals). Clipping
//                IM and harmonics land in the "everything else" sum. Orban's
//                point: difference-frequency IM of clipped pre-emphasised HF
//                is what de-emphasis then exaggerates ("essses" -> "efffs").
//   HF crest  -- decoded >6 kHz crest factor minus the input's: how much of
//                the hat's attack survives (negative = crushed / spitty).
//   Gap spill -- composite energy in 15.5-18.5 + 19.5-22.5 kHz relative to
//                the 0-15 kHz audio composite. Nothing but the pilot belongs
//                there; L/R-domain clipping products that are not lowpassed
//                afterwards show up here (pilot guard + L-R sideband foot).

struct HFTransientScenario {
    let name: String
    /// Hat partials whose bins count as "wanted" in the decoded spectrum;
    /// empty for noise-based scenarios (SINAD not computed).
    let wantedHz: [Double]
    let wantedHalfWidthHz: Double
    /// Bed fundamentals: program, not distortion -- excluded from the unwanted sum.
    let bedHz: [Double]
    let sample: (_ frameIndex: Int, _ sampleRate: Double) -> (Float, Float)
}

/// Band-limits white noise to the 6-14 kHz "cymbal" region. Configured lazily
/// on the first call at the render rate.
struct HFNoiseBand {
    private var hp = Biquad()
    private var lp = Biquad()
    private var configuredRate: Float = 0.0

    mutating func process(_ x: Float, sampleRate: Float) -> Float {
        if configuredRate != sampleRate {
            hp.configureHighpass(cutoffHz: 6_000.0, sampleRate: sampleRate)
            lp.configureLowpass(cutoffHz: 14_000.0, sampleRate: sampleRate)
            configuredRate = sampleRate
        }
        return lp.process(hp.process(x))
    }
}

func hfTransientScenarios() -> [HFTransientScenario] {
    let partials: [Double] = [8_900.0, 11_300.0, 13_100.0]
    let bed: [Double] = [220.0, 520.0]
    func bedSample(_ t: Double) -> (Double, Double) {
        let b = (0.25 * sin(2.0 * Double.pi * 220.0 * t)) + (0.12 * sin(2.0 * Double.pi * 520.0 * t))
        return (b, 0.9 * b)
    }
    func partialSum(_ t: Double, amp: Double) -> Double {
        var s = 0.0
        for (i, f) in partials.enumerated() {
            s += amp * sin((2.0 * Double.pi * f * t) + (Double(i) * 1.3))
        }
        return s
    }
    var hatNoiseL = DeterministicNoise(seed: 0x4846_0000_0000_0001)
    var hatNoiseR = DeterministicNoise(seed: 0x4846_0000_0000_0002)
    var washNoiseL = DeterministicNoise(seed: 0x4846_0000_0000_0003)
    var washNoiseR = DeterministicNoise(seed: 0x4846_0000_0000_0004)
    var hatBandL = HFNoiseBand()
    var hatBandR = HFNoiseBand()
    var washBandL = HFNoiseBand()
    var washBandR = HFNoiseBand()

    return [
        HFTransientScenario(
            name: "ride_multitone",
            wantedHz: partials, wantedHalfWidthHz: 40.0, bedHz: bed
        ) { frame, sampleRate in
            // Sustained ride/crash wash as three fixed HF partials over a bed:
            // steady state, so IM products land in exactly-known bins.
            let t = Double(frame) / sampleRate
            let b = bedSample(t)
            let p = partialSum(t, amp: 0.16)
            return (Float(b.0 + p), Float(b.1 + (0.8 * p)))
        },
        HFTransientScenario(
            name: "hat_multitone",
            wantedHz: partials, wantedHalfWidthHz: 250.0, bedHz: bed
        ) { frame, sampleRate in
            // The same partials gated as 4 hats/s (pow-24 sine window ~ 30 ms
            // burst). Envelope sidebands stay within +/-250 Hz of each partial.
            let t = Double(frame) / sampleRate
            let b = bedSample(t)
            let env = pow(max(0.0, sin(2.0 * Double.pi * 4.0 * t)), 24.0)
            let p = env * partialSum(t, amp: 0.45)
            return (Float(b.0 + p), Float(b.1 + (0.8 * p)))
        },
        HFTransientScenario(
            name: "cymbal_wash",
            wantedHz: [], wantedHalfWidthHz: 0.0, bedHz: bed
        ) { frame, sampleRate in
            // Band-limited (6-14 kHz) noise: percussive hat bursts (instant
            // attack, ~30 ms decay, 4/s) over a sustained ride/crash wash and
            // the bed. No wanted bins -- scored by crest and composite spill.
            let t = Double(frame) / sampleRate
            let sr = Float(sampleRate)
            let b = bedSample(t)
            let beat = fmod(t, 0.25)
            let hatEnv = Float(exp(-beat * 35.0))
            let hatL = hatEnv * 0.6 * hatBandL.process(hatNoiseL.next(), sampleRate: sr)
            let hatR = hatEnv * 0.48 * hatBandR.process(hatNoiseR.next(), sampleRate: sr)
            let washL = 0.12 * washBandL.process(washNoiseL.next(), sampleRate: sr)
            let washR = 0.13 * washBandR.process(washNoiseR.next(), sampleRate: sr)
            return (Float(b.0) + hatL + washL, Float(b.1) + hatR + washR)
        }
    ]
}

struct HFTransientMeasurement {
    var compositePeakDBFS: Float = -200.0
    var gapSpillDB: Float = -200.0
    var hfSINADDB: Float?
    var inputHFSINADDB: Float?
    var hfCrestDeltaDB: Float = 0.0
}

/// Hann-windowed power spectrum (bins 0..<fftSize/2) of `samples[start..<start+fftSize]`.
/// Only ratios are used, so the vDSP packing scale is irrelevant.
func hannPowerSpectrum(_ samples: [Float], start: Int, fftSize: Int) -> [Float] {
    let halfSize = fftSize / 2
    guard fftSize >= 1024, start >= 0, start + fftSize <= samples.count else {
        return [Float](repeating: 0.0, count: max(1, halfSize))
    }
    var window = [Float](repeating: 0.0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    let signal = Array(samples[start..<(start + fftSize)])
    var windowed = [Float](repeating: 0.0, count: fftSize)
    vDSP_vmul(signal, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

    var real = [Float](repeating: 0.0, count: halfSize)
    var imag = [Float](repeating: 0.0, count: halfSize)
    var power = [Float](repeating: 0.0, count: halfSize)
    let log2n = vDSP_Length(log2(Double(fftSize)))
    real.withUnsafeMutableBufferPointer { realPtr in
        imag.withUnsafeMutableBufferPointer { imagPtr in
            guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
            var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
            windowed.withUnsafeBufferPointer { windowedPtr in
                guard let windowedBase = windowedPtr.baseAddress else { return }
                windowedBase.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                }
            }
            guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_destroy_fftsetup(fftSetup)
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfSize))
        }
    }
    // Bin 0 packs DC (real) and Nyquist (imag) -- neither is wanted.
    power[0] = 0.0
    return power
}

func bandPower(
    _ spectrum: [Float], sampleRate: Double, fftSize: Int, lowHz: Double, highHz: Double
) -> Double {
    guard highHz > lowHz else { return 0.0 }
    let binHz = sampleRate / Double(fftSize)
    let lo = max(1, Int((lowHz / binHz).rounded(.up)))
    let hi = min(spectrum.count - 1, Int((highHz / binHz).rounded(.down)))
    guard hi >= lo else { return 0.0 }
    var sum = 0.0
    for i in lo...hi { sum += Double(spectrum[i]) }
    return sum
}

/// HF (>6 kHz) crest factor as 99.9th-percentile-of-|x| over RMS. The
/// percentile (the ~130th largest of 131072 samples) is a stable statistic
/// on noise-like cymbal material where the single maximum jumps by dB
/// between otherwise near-identical renders.
func hfCrestDB(_ samples: [Float], start: Int, count: Int, sampleRate: Float) -> Float {
    var hp = Biquad()
    hp.configureHighpass(cutoffHz: 6_000.0, sampleRate: sampleRate)
    var magnitudes = [Float](repeating: 0.0, count: count)
    var sumSq: Double = 0.0
    // Prime the filter on the preceding samples so the window is steady state.
    let primeStart = max(0, start - 4_096)
    for i in primeStart..<start { _ = hp.process(samples[i]) }
    for i in 0..<count {
        let y = hp.process(samples[start + i])
        magnitudes[i] = fabsf(y)
        sumSq += Double(y * y)
    }
    magnitudes.sort()
    let index = min(count - 1, Int(Double(count) * 0.999))
    let p999 = magnitudes[max(0, index)]
    let rms = sqrt(max(1e-30, sumSq / Double(max(1, count))))
    return Float(20.0 * log10(Double(max(1e-15, p999)) / rms))
}

func measureHFTransient(
    config: AppConfig,
    scenario: HFTransientScenario,
    durationSeconds: Double
) -> HFTransientMeasurement {
    let sampleRate = max(8_000.0, config.sampleRate)
    let frames = max(1, Int((durationSeconds * sampleRate).rounded()))
    let generator = MPXGenerator(config: config, sampleRate: sampleRate)
    var inputLeft = [Float](repeating: 0.0, count: frames)
    var inputRight = [Float](repeating: 0.0, count: frames)
    var mpx = [Float](repeating: 0.0, count: frames)
    for frame in 0..<frames {
        let source = scenario.sample(frame, sampleRate)
        inputLeft[frame] = source.0
        inputRight[frame] = source.1
        mpx[frame] = generator.renderSingleSample(leftIn: source.0, rightIn: source.1)
    }

    // Analysis window: the last power-of-two block (<= 131072 samples, ~0.68 s
    // at 192 kHz -> 1.5 Hz bins), so AGC / leveler settling is excluded.
    let fftSize = 1 << Int(floor(log2(Double(min(frames, 131_072)))))
    let start = frames - fftSize
    var m = HFTransientMeasurement()
    guard fftSize >= 1024, start >= 0 else { return m }

    var peak: Float = 0.0
    for i in start..<frames { peak = max(peak, fabsf(mpx[i])) }
    m.compositePeakDBFS = dbfsValue(peak)

    let compositeSpec = hannPowerSpectrum(mpx, start: start, fftSize: fftSize)
    let audioPower = bandPower(compositeSpec, sampleRate: sampleRate, fftSize: fftSize, lowHz: 30.0, highHz: 15_000.0)
    let gapPower =
        bandPower(compositeSpec, sampleRate: sampleRate, fftSize: fftSize, lowHz: 15_500.0, highHz: 18_500.0)
        + bandPower(compositeSpec, sampleRate: sampleRate, fftSize: fftSize, lowHz: 19_500.0, highHz: 22_500.0)
    m.gapSpillDB = Float(10.0 * log10(max(1e-30, gapPower) / max(1e-30, audioPower)))

    // Receiver side: coherent decode with the pilot phase estimated from the
    // composite itself, de-emphasised by MPXDecoder.
    let pilot = estimatePilotPhase(samples: mpx, sampleRate: sampleRate, start: start, count: fftSize)
    // expectedSide 0 (as in --verify-receiver): a non-zero hint arms the
    // decoder's stereo-collapse self-heal, which re-configures the whole
    // decoder (2 s cooldown) whenever the decoded side sits below 12% of the
    // hint for 0.55 s -- a periodic reset that landed inside the analysis
    // window on odd render lengths and read as 20 dB of "distortion".
    let decoded = decodeMPXWithReference(
        samples: mpx, pilotPhase: pilot.phase, config: config,
        programActivity: 0.5, expectedSide: 0.0)
    let specL = hannPowerSpectrum(decoded.left, start: start, fftSize: fftSize)
    let specR = hannPowerSpectrum(decoded.right, start: start, fftSize: fftSize)
    // The scenarios mix the hats left-dominant (0.6 / 0.48, 1.0 / 0.8); score
    // the decoded channel carrying the stronger HF (= left with a polarity-
    // correct decode; polarity itself is gated in --verify-receiver).
    let hfL = bandPower(specL, sampleRate: sampleRate, fftSize: fftSize, lowHz: 6_000.0, highHz: 15_000.0)
    let hfR = bandPower(specR, sampleRate: sampleRate, fftSize: fftSize, lowHz: 6_000.0, highHz: 15_000.0)
    let chosenSpec = hfL >= hfR ? specL : specR
    let chosenSamples = hfL >= hfR ? decoded.left : decoded.right

    if !scenario.wantedHz.isEmpty {
        // Unwanted power is summed bin-by-bin over an explicit mask rather
        // than as (total - wanted): for near-perfect synthetic sines the
        // remainder sits below the double-precision resolution of the sums
        // and the subtraction collapses to rounding noise.
        func sinad(_ spec: [Float]) -> Float {
            let binHz = sampleRate / Double(fftSize)
            func range(_ f: Double, _ hw: Double) -> ClosedRange<Int> {
                let lo = max(1, Int(((f - hw) / binHz).rounded(.up)))
                let hi = min(spec.count - 1, Int(((f + hw) / binHz).rounded(.down)))
                return lo...max(lo, hi)
            }
            let wantedRanges = scenario.wantedHz.map { range($0, scenario.wantedHalfWidthHz) }
            let bedRanges = scenario.bedHz.map { range($0, 40.0) }
            var wanted = 0.0
            var unwanted = 0.0
            let lo = max(1, Int((300.0 / binHz).rounded(.up)))
            let hi = min(spec.count - 1, Int((15_000.0 / binHz).rounded(.down)))
            for i in lo...hi {
                let p = Double(spec[i])
                if wantedRanges.contains(where: { $0.contains(i) }) {
                    wanted += p
                } else if !bedRanges.contains(where: { $0.contains(i) }) {
                    unwanted += p
                }
            }
            return Float(10.0 * log10(max(1e-30, wanted) / max(1e-30, unwanted)))
        }
        m.hfSINADDB = sinad(chosenSpec)
        let inputSpec = hannPowerSpectrum(inputLeft, start: start, fftSize: fftSize)
        m.inputHFSINADDB = sinad(inputSpec)
    }

    let sr = Float(sampleRate)
    m.hfCrestDeltaDB =
        hfCrestDB(chosenSamples, start: start, count: fftSize, sampleRate: sr)
        - hfCrestDB(inputLeft, start: start, count: fftSize, sampleRate: sr)
    return m
}

struct HFTransientChainVariant {
    let label: String
    /// Shipped Format Profiles are gated; diagnostic variants only report.
    let gated: Bool
    let mutate: (inout AppConfig) -> Void
}

/// The operator's station config as found 2026-08-29 (pre-0.45 profile
/// `chr_top40`, never migrated): every peak controller off, +8 dB drive, so
/// the safety soft-clips do the peak control; Advanced Dynamics on with a
/// -9 dB high offset; composite clipper's audio-band cancel armed.
func applyFieldChain2026_08(_ c: inout AppConfig) {
    c.inputGainDB = -4.0
    c.preEncodeAudioLimiterEnabled = false
    c.compositeClipperEnabled = false
    c.compositeClipperCancelAudio = true
    c.compositeClipperLookaheadMS = 2.0
    c.compositeClipperThresholdDB = -0.8
    c.compositeClipperCeilingDB = -0.2
    c.hfClipperEnabled = false
    c.bassClipperEnabled = false
    c.dcClipperEnabled = false
    c.limitMPX = false
    c.finalDriveDB = 8.0
    c.audioCompositeSoftClipEnabled = true
    c.widebandAGCEnabled = true
    c.widebandAGCTargetDB = -15.0
    c.multibandEnabled = true
    c.multibandMode = 5
    c.advancedDynamicsEnabled = true
    c.advancedDynamicsTargetDB = -16.0
    c.advancedDynamicsLowOffsetDB = 0.0
    c.advancedDynamicsMidOffsetDB = -3.0
    c.advancedDynamicsHighOffsetDB = -9.0
    c.advancedDynamicsMaxGainDB = 12.0
}

func hfTransientChainVariants() -> [HFTransientChainVariant] {
    func profile(_ id: String) -> (inout AppConfig) -> Void {
        { c in _ = PresetCatalog.applyFormatProfile(id: id, to: &c) }
    }
    func loudPlus(_ extra: @escaping (inout AppConfig) -> Void) -> (inout AppConfig) -> Void {
        { c in
            _ = PresetCatalog.applyFormatProfile(id: "music_loud", to: &c)
            extra(&c)
        }
    }
    return [
        HFTransientChainVariant(label: "field INI 2026-08 (no limiter/clipper)", gated: false) { c in
            applyFieldChain2026_08(&c)
        },
        HFTransientChainVariant(label: "field INI + music_loud applied", gated: false) { c in
            applyFieldChain2026_08(&c)
            _ = PresetCatalog.applyFormatProfile(id: "music_loud", to: &c)
        },
        HFTransientChainVariant(label: "profile music_clean", gated: true, mutate: profile("music_clean")),
        HFTransientChainVariant(label: "profile music_loud", gated: true, mutate: profile("music_loud")),
        HFTransientChainVariant(label: "profile speech", gated: true, mutate: profile("speech")),
        HFTransientChainVariant(label: "profile classical_wide", gated: true, mutate: profile("classical_wide")),
        HFTransientChainVariant(label: "music_loud - HF limiter OFF", gated: false,
                                mutate: loudPlus { $0.hfLimiterEnabled = false }),
        HFTransientChainVariant(label: "music_loud + HF clipper (pre-0.45)", gated: false,
                                mutate: loudPlus {
                                    $0.hfLimiterEnabled = false
                                    $0.hfClipperEnabled = true
                                }),
        HFTransientChainVariant(label: "music_loud HF limiter thr -4 dB", gated: false,
                                mutate: loudPlus { $0.hfLimiterThresholdDB = -4.0 }),
        HFTransientChainVariant(label: "music_loud HF limiter attack 0.5 ms", gated: false,
                                mutate: loudPlus { $0.hfLimiterAttackMS = 0.5 }),
        HFTransientChainVariant(label: "music_loud drive 6 dB", gated: false,
                                mutate: loudPlus { $0.finalDriveDB = 6.0 }),
        HFTransientChainVariant(label: "music_loud - composite clipper OFF", gated: false,
                                mutate: loudPlus { $0.compositeClipperEnabled = false }),
        HFTransientChainVariant(label: "music_loud - pre-encode limiter OFF", gated: false,
                                mutate: loudPlus { $0.preEncodeAudioLimiterEnabled = false }),
        HFTransientChainVariant(label: "music_loud + cancel_audio", gated: false,
                                mutate: loudPlus { $0.compositeClipperCancelAudio = true }),
        HFTransientChainVariant(label: "music_loud + advanced dynamics", gated: false,
                                mutate: loudPlus { $0.advancedDynamicsEnabled = true }),
        HFTransientChainVariant(label: "music_loud - safety soft clip", gated: false,
                                mutate: loudPlus { $0.audioCompositeSoftClipEnabled = false })
    ]
}

// Gate thresholds for SHIPPED profiles (diagnostic variants only report).
// Measured 2026-08-29 after the final-stage fix + HF limiter: clean/speech/
// classical read 42-50 / 23-27 dB, music_loud 38 / 18 dB (its 8 dB drive
// into the composite clipper is the loudness it promises; the loud gate is
// therefore 5 dB lower). The 15-23 kHz spill floor of the chain is ~-36 dB
// (composite-clipper IM below 17 kHz plus the encoder FIR's transition tail;
// everything the L/R limiter generates above 16.5 kHz is 80 dB down since the
// 0.45 decimator, and the pilot region is protected by the clipper's guard).
// The floor was ~-39 dB before Step 2 of the chain review only because the
// old limiter decimator dropped 12-15 kHz by 2-4 dB before the clipper saw
// it; the gate sits 2 dB above the measured floor of the corrected chain.
let hfTransientMinRideSINADDB: Float = 30.0
let hfTransientMinHatSINADDB: Float = 20.0
let hfTransientMinHatSINADLoudDB: Float = 15.0
let hfTransientMinCrestDeltaDB: Float = -6.0
let hfTransientMaxGapSpillDB: Float = -34.0

func runHFTransientVerification(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    // 4 s floor: the analysis window is the LAST 0.68 s, and the AGC /
    // multiband release (~1 s) plus the hat pattern need >= 3 s of settling
    // before it -- at 3 s the gated-hat SINAD of the loud profile still
    // moves with the AGC.
    let duration = max(5.0, min(durationSeconds, 8.0))
    print("Hi-hat / cymbal distortion sweep (receiver-side, de-emphasised decode)")
    print("Columns: RideSINAD / HatSINAD = decoded HF partials vs IM+harmonics in 300 Hz-15 kHz (dB, higher is cleaner)")
    print("         HatCrest / WashCrest = decoded >6 kHz crest minus input crest (dB, 0 = attack intact)")
    print("         WashGap = composite 15.5-18.5 + 19.5-22.5 kHz vs 0-15 kHz audio (dB, lower is cleaner)")
    print("         Peak = worst composite peak over the three scenarios")
    print("")
    print("Chain variant                            RideSINAD  HatSINAD  HatCrest  WashCrest  WashGap  Peak dBFS")
    print("---------------------------------------  ---------  --------  --------  ---------  -------  ---------")

    var warnings: [String] = []
    var floorPrinted = false
    for variant in hfTransientChainVariants() {
        var cfg = baseConfig
        variant.mutate(&cfg)
        var byName: [String: HFTransientMeasurement] = [:]
        var worstPeak: Float = -200.0
        // Fresh scenario closures per variant: the noise scenario carries
        // generator + filter state, so sharing one instance across variants
        // would hand each variant a different noise realisation and make
        // the crest column incomparable between rows.
        for scenario in hfTransientScenarios() {
            let m = measureHFTransient(config: cfg, scenario: scenario, durationSeconds: duration)
            byName[scenario.name] = m
            worstPeak = max(worstPeak, m.compositePeakDBFS)
        }
        let ride = byName["ride_multitone"] ?? HFTransientMeasurement()
        let hat = byName["hat_multitone"] ?? HFTransientMeasurement()
        let wash = byName["cymbal_wash"] ?? HFTransientMeasurement()
        if !floorPrinted {
            print(
                "(input floor: RideSINAD \(String(format: "%.1f", ride.inputHFSINADDB ?? 0.0)) dB, "
                    + "HatSINAD \(String(format: "%.1f", hat.inputHFSINADDB ?? 0.0)) dB)")
            floorPrinted = true
        }
        print(
            "\(padded(variant.label, width: 39))  "
                + "\(String(format: "%9.1f", ride.hfSINADDB ?? 0.0))"
                + "  \(String(format: "%8.1f", hat.hfSINADDB ?? 0.0))"
                + "  \(String(format: "%+8.1f", hat.hfCrestDeltaDB))"
                + "  \(String(format: "%+9.1f", wash.hfCrestDeltaDB))"
                + "  \(String(format: "%7.1f", wash.gapSpillDB))"
                + "  \(String(format: "%9.2f", worstPeak))"
        )
        guard variant.gated else { continue }
        if let s = ride.hfSINADDB, s < hfTransientMinRideSINADDB {
            warnings.append("\(variant.label): ride HF SINAD \(String(format: "%.1f", s)) dB < \(String(format: "%.0f", hfTransientMinRideSINADDB)) dB")
        }
        let hatGate = variant.label.contains("music_loud") ? hfTransientMinHatSINADLoudDB : hfTransientMinHatSINADDB
        if let s = hat.hfSINADDB, s < hatGate {
            warnings.append("\(variant.label): hat HF SINAD \(String(format: "%.1f", s)) dB < \(String(format: "%.0f", hatGate)) dB")
        }
        if wash.hfCrestDeltaDB < hfTransientMinCrestDeltaDB {
            warnings.append("\(variant.label): cymbal wash crest crushed by \(String(format: "%.1f", -wash.hfCrestDeltaDB)) dB")
        }
        if wash.gapSpillDB > hfTransientMaxGapSpillDB {
            warnings.append("\(variant.label): 15-23 kHz composite spill \(String(format: "%.1f", wash.gapSpillDB)) dB > \(String(format: "%.0f", hfTransientMaxGapSpillDB)) dB")
        }
    }

    print("")
    print("Assessment")
    if warnings.isEmpty {
        print("Result: OK - every shipped Format Profile keeps HF transients within the gate.")
        return 0
    }
    print("Findings:")
    for warning in warnings {
        print("- \(warning)")
    }
    print("Result: TIGHT - a shipped Format Profile distorts HF transients beyond the gate.")
    return 1
}
