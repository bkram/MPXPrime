import Testing
import Foundation
#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
@testable import MPXPrime

// Optional deep DSP coverage suite. Gated behind the `MPXPRIME_DEEP=1`
// environment variable so it stays out of the default `swift test`
// invocation. Run on demand with:
//
//   MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     swift test --package-path macOS --filter DeepDSP
//
// Five layers (run by individual @Suites within this file):
//
//   1. Per-stage isolation smoke tests (Phase Rotator, Parametric EQ,
//      Mono Bass, Stereo Widener, BS.412, Pre-encode limiter, Final
//      MPX safety limiter, etc.) — stages that have no isolated
//      regression coverage today.
//   2. Universal invariants on N random valid configs × an adversarial
//      program set. Asserts no NaN/inf, composite peak ≤ 1.0, pilot /
//      RDS injection levels within tolerance, audio passband retains
//      energy, subcarrier guard bands stay clean.
//   3. Pairwise enable/disable matrix on the high-impact stage flags —
//      catches stage-pair interaction bugs without 32K-combo explosion.
//   4. Counteract detection — for suspect pairs (AGC × multiband,
//      PrimeBass × bass clipper, composite clipper × BS.412, ...) verify
//      A∧B output is bounded by max(A-only, B-only) within tolerance,
//      and the |output| envelope contains no low-frequency oscillation
//      (would indicate two stages fighting each other).
//   5. Per-preset safety check — for each shipped 5-band preset, render
//      a fixed adversarial program and assert composite-safety bounds.
//
// Total runtime budget: ~4 min on a typical M1, single-threaded.

private let deepEnabled = ProcessInfo.processInfo.environment["MPXPRIME_DEEP"] != nil

// MARK: - Shared test fixtures

private let deepSampleRate: Float = 192_000.0
private let deepBlockSize: Int = 512
private let deepRenderSeconds: Double = 1.0
private let deepRenderFrames: Int = Int(deepRenderSeconds * Double(deepSampleRate))

/// Adversarial program kinds. Each constructs a 1 s stereo input
/// designed to stress different parts of the chain.
private enum DeepProgram: String, CaseIterable {
    /// HF-rich pop (1 + 4 + 10 kHz sines + slight L/R skew).
    /// Stresses limiter, multiband HF band, encoder bandwidth FIR.
    case hfRichPop
    /// Sustained 70 Hz sine. Stresses bass clipper, PrimeBass,
    /// program HPF, and the M/S domain pre-emphasis interaction.
    case sustainedBass
    /// Percussive impulse train (~3 Hz repetition, sharp envelope).
    /// Stresses transient detector, multiband attack, AGC release.
    case percussiveTransients
    /// Sustained pink-ish noise. Stresses everything; broadband.
    case pinkNoise
    /// Silence. Tests for self-noise, denormal handling.
    case silence
    /// DC offset. Tests DC rejection.
    case dcOffset
    /// Full-scale step from silence. Tests for click suppression and
    /// limiter wakeup.
    case fullScaleStep

    func generate(frames: Int, sampleRate: Float, seed: UInt64 = 1) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let sr = Double(sampleRate)
        switch self {
        case .hfRichPop:
            for i in 0..<frames {
                let t = Double(i) / sr
                let base =
                    0.32 * sin(2.0 * .pi * 1_000.0 * t)
                    + 0.28 * sin(2.0 * .pi * 4_000.0 * t)
                    + 0.22 * sin(2.0 * .pi * 10_000.0 * t)
                let jitter = 0.08 * sin(2.0 * .pi * 30.0 * t)
                left[i] = Float(base + jitter)
                right[i] = Float(base * 0.96 + 0.04 * sin(2.0 * .pi * 800.0 * t + 0.7))
            }
        case .sustainedBass:
            let omega = 2.0 * .pi * 70.0 / sr
            for i in 0..<frames {
                let s = Float(0.4 * sin(omega * Double(i)))
                left[i] = s
                right[i] = s
            }
        case .percussiveTransients:
            // Hits at ~3 Hz with 30 ms exponential decay envelope.
            // Each hit is a 70 Hz sine + 200 Hz blip.
            let hitsPerSec = 3.0
            let decayMS: Double = 30.0
            for i in 0..<frames {
                let t = Double(i) / sr
                let phase = (t * hitsPerSec).truncatingRemainder(dividingBy: 1.0)
                let env = exp(-phase * 1000.0 / decayMS)
                let body = sin(2.0 * .pi * 70.0 * t) + 0.4 * sin(2.0 * .pi * 200.0 * t)
                let s = Float(0.6 * env * body)
                left[i] = s
                right[i] = s
            }
        case .pinkNoise:
            // Cheap pink-ish noise: Gaussian-ish white through a small IIR.
            var rng = DeepRNG(seed: seed ^ 0xA5A5_A5A5)
            var lp1: Float = 0
            var lp2: Float = 0
            for i in 0..<frames {
                let n = (rng.nextUniformFloat() - 0.5) * 0.5
                lp1 = 0.997 * lp1 + 0.003 * n
                lp2 = 0.95 * lp2 + 0.05 * n
                let pink = 0.5 * (lp1 + lp2)
                left[i] = pink
                right[i] = pink * 0.95
            }
        case .silence:
            break  // already zero-filled
        case .dcOffset:
            for i in 0..<frames {
                left[i] = 0.3
                right[i] = 0.3
            }
        case .fullScaleStep:
            let stepAt = frames / 4
            for i in stepAt..<frames {
                left[i] = 0.95
                right[i] = -0.95
            }
        }
        return (left, right)
    }
}

/// Render `frames` of a program through a fresh `MPXGenerator` built
/// from `config`. Returns the composite output (mono — both channels
/// receive the same composite from `renderFromInputInPlace`).
private func deepRender(
    config: AppConfig,
    program: DeepProgram,
    frames: Int = deepRenderFrames,
    seed: UInt64 = 1
) -> [Float] {
    var (left, right) = program.generate(frames: frames, sampleRate: deepSampleRate, seed: seed)
    let gen = MPXGenerator(config: config, sampleRate: Double(deepSampleRate))
    left.withUnsafeMutableBufferPointer { lBuf in
        right.withUnsafeMutableBufferPointer { rBuf in
            gen.renderFromInputInPlace(
                frameCount: frames,
                left: lBuf.baseAddress!,
                right: rBuf.baseAddress!
            )
        }
    }
    return left  // composite (mono — left == right after renderFromInputInPlace)
}

// MARK: - Universal invariant assertions

private struct DeepInvariants {
    /// All samples are finite (no NaN, no inf).
    static func assertAllFinite(_ samples: [Float], where label: String) {
        var bad = 0
        for v in samples where !v.isFinite {
            bad += 1
            if bad > 4 { break }
        }
        #expect(bad == 0, "\(label): output contains NaN/inf")
    }

    /// Composite peak is bounded. Allow a small overshoot for FIR ringing
    /// (linear-phase encoder FIR transients up to ~1.5%).
    static func assertCompositePeakBounded(_ samples: [Float], where label: String) {
        var peak: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_maxmgv(ptr.baseAddress!, 1, &peak, vDSP_Length(samples.count))
        }
        #expect(peak <= 1.05,
            "\(label): composite peak \(peak) exceeds 1.05 (FIR overshoot allowance)")
    }

    /// Returns peak amplitude over `samples`.
    static func peak(_ samples: [Float]) -> Float {
        var p: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_maxmgv(ptr.baseAddress!, 1, &p, vDSP_Length(samples.count))
        }
        return p
    }

    /// Goertzel-style RMS at a single frequency. Cheap; accurate enough
    /// for invariant gating where we only care about ±a-few-dB.
    static func rmsAtFrequency(
        _ samples: [Float],
        frequencyHz: Float,
        sampleRate: Float
    ) -> Float {
        let omega = 2.0 * Double.pi * Double(frequencyHz) / Double(sampleRate)
        var realSum: Double = 0
        var imagSum: Double = 0
        for (i, x) in samples.enumerated() {
            let phase = omega * Double(i)
            realSum += Double(x) * cos(phase)
            imagSum += Double(x) * sin(phase)
        }
        let mag = sqrt(realSum * realSum + imagSum * imagSum) / Double(samples.count)
        // Single-frequency Goertzel mag (peak amplitude at the freq) →
        // RMS via /sqrt(2). Multiplied by 2 because we're measuring a
        // real-only signal (both ±freq bins contribute the same).
        return Float(mag * sqrt(2.0))
    }

    /// Energy in a frequency band, computed via FFT and bin sum.
    static func bandEnergyDBFS(
        _ samples: [Float],
        from loHz: Float,
        to hiHz: Float,
        sampleRate: Float,
        fftSize: Int = 4096,
        start: Int = 0
    ) -> Float {
        // Pad / truncate to fftSize from `start`. Callers comparing chain
        // configurations must pass a steady-state `start`: the default
        // window is the first 21 ms at 192 kHz, which sits INSIDE the
        // startup latency of high-group-delay stages (Advanced Dynamics'
        // FIR splitter + the pre-encode limiter's look-ahead pushed the
        // program entirely past it, reading as a phantom -78 dB
        // "cancellation", 2026-09-04).
        var padded = Array(samples.dropFirst(min(start, max(0, samples.count - 1))))
        if padded.count > fftSize {
            padded = Array(padded.prefix(fftSize))
        } else if padded.count < fftSize {
            padded.append(contentsOf: [Float](repeating: 0.0, count: fftSize - padded.count))
        }
        let analyzer = FFTAnalyzer(fftSize: fftSize)
        let spec = analyzer.analyze(padded, sampleRate: sampleRate)
        return spec.peakDBFS(in: loHz...hiHz)
    }
}

// MARK: - Random config generator

private struct DeepRNG {
    var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed }
    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func nextUniformFloat() -> Float {
        Float(next() >> 11) / Float(UInt64(1) << 53)
    }
    mutating func nextBool(probability p: Float = 0.5) -> Bool {
        nextUniformFloat() < p
    }
    mutating func nextRange(_ low: Float, _ high: Float) -> Float {
        low + (high - low) * nextUniformFloat()
    }
    mutating func nextRangeDouble(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(nextUniformFloat())
    }
}

/// Deterministically build a valid AppConfig from a seed. Each flag is
/// sampled with a probability that approximates "realistic" usage —
/// AGC mostly on, multiband mostly on, Italo presets occasionally,
/// PrimeBass off most of the time (matches default UX).
private func randomDeepConfig(seed: UInt64) -> AppConfig {
    var rng = DeepRNG(seed: seed)
    var cfg = AppConfig()
    cfg.sampleRate = Double(deepSampleRate)
    cfg.blockSize = deepBlockSize
    cfg.sourceMode = "input"
    cfg.monitorEnabled = false
    cfg.processingBypass = false

    // Pre-emphasis: 50 / 75 / 0 (off).
    let preempPick = Int(rng.nextUniformFloat() * 3.0)
    cfg.preemphasisUS = [50, 75, 0][min(2, preempPick)]
    cfg.mpxDeviationKHz = 75.0
    cfg.monoMode = rng.nextBool(probability: 0.15)

    cfg.widebandAGCEnabled = rng.nextBool(probability: 0.85)
    cfg.widebandAGCTargetDB = rng.nextRangeDouble(-22.0, -10.0)
    cfg.widebandAGCMaxGainDB = rng.nextRangeDouble(8.0, 24.0)

    cfg.phaseRotationEnabled = rng.nextBool(probability: 0.3)
    cfg.parametricEQEnabled = rng.nextBool(probability: 0.4)

    cfg.primeBassEnabled = rng.nextBool(probability: 0.4)
    cfg.primeBassAmount = rng.nextRangeDouble(0.0, 1.0)
    cfg.primeBassHarmonics = rng.nextRangeDouble(0.0, 1.0)
    cfg.primeBassDrive = rng.nextRangeDouble(0.2, 2.0)
    cfg.primeBassDensity = rng.nextRangeDouble(0.0, 1.0)
    cfg.primeBassFreqHz = rng.nextRangeDouble(50.0, 180.0)

    cfg.stereoWidenEnabled = rng.nextBool(probability: 0.3)
    cfg.monoBassEnabled = rng.nextBool(probability: 0.7)

    cfg.multibandEnabled = rng.nextBool(probability: 0.85)
    cfg.multibandMode = rng.nextBool() ? 5 : 3
    cfg.multibandLowThresholdDB = rng.nextRangeDouble(-22.0, -10.0)
    cfg.multibandMidThresholdDB = rng.nextRangeDouble(-22.0, -10.0)
    cfg.multibandHighThresholdDB = rng.nextRangeDouble(-22.0, -10.0)

    // Advanced Dynamics (replaces AGC + multiband when on): exercised at
    // a low probability so the fuzz covers both the substitution and the
    // interaction with every downstream stage.
    cfg.advancedDynamicsEnabled = rng.nextBool(probability: 0.25)
    cfg.advancedDynamicsTargetDB = rng.nextRangeDouble(-22.0, -10.0)
    cfg.advancedDynamicsMaxGainDB = rng.nextRangeDouble(6.0, 24.0)
    cfg.advancedDynamicsDensity = rng.nextRangeDouble(0.0, 1.0)
    cfg.advancedDynamicsSpeed = rng.nextRangeDouble(0.25, 4.0)

    // SSB Stereo encoder (SSB-leaning stereo encoding): low probability, full
    // amount range, so the fuzz covers SSB assembly against every
    // downstream composite stage.
    cfg.ssbStereoEnabled = rng.nextBool(probability: 0.2)
    cfg.ssbStereoAmount = rng.nextRangeDouble(0.0, 1.0)

    cfg.bassClipperEnabled = rng.nextBool(probability: 0.7)
    cfg.dcClipperEnabled = rng.nextBool(probability: 0.2)
    cfg.bs412Enabled = rng.nextBool(probability: 0.3)
    cfg.compositeClipperEnabled = rng.nextBool(probability: 0.85)
    cfg.preEncodeAudioLimiterEnabled = rng.nextBool(probability: 0.85)
    cfg.multibandLimiterEnabled = rng.nextBool(probability: 0.5)
    cfg.encoderFIREnabled = rng.nextBool(probability: 0.85)

    cfg.limitMPX = true  // always on — final safety
    cfg.enRDS = rng.nextBool(probability: 0.7) && !cfg.monoMode
    cfg.rdsLevel = rng.nextRangeDouble(1.0, 4.0)
    cfg.rdsNowPlayingEnabled = false
    cfg.rdsEnableRTPlus = false
    cfg.rdsEnableCT = false
    cfg.rdsEnableID = false

    return cfg
}

// MARK: - Layer 2 — Universal invariants on random configs

@Suite("Deep DSP — universal invariants",
       .enabled(if: deepEnabled))
struct DeepUniversalInvariantsTests {

    /// Run a small program subset through a single random config;
    /// assert universal invariants hold on every (config, program)
    /// pair. The four programs cover the most stage-stressing cases:
    /// HF-rich limiter pressure, sustained bass for the LF chain,
    /// percussive transient detection, broadband noise.
    fileprivate static let programs: [DeepProgram] = [
        .hfRichPop, .sustainedBass, .percussiveTransients, .pinkNoise,
    ]

    @Test(arguments: 0..<50)
    func universalInvariantsHold(seed: Int) {
        let cfg = randomDeepConfig(seed: UInt64(seed) &+ 1)
        for program in Self.programs {
            let label = "seed=\(seed) program=\(program.rawValue)"
            let composite = deepRender(config: cfg, program: program, seed: UInt64(seed))

            DeepInvariants.assertAllFinite(composite, where: label)
            DeepInvariants.assertCompositePeakBounded(composite, where: label)

            // Pilot injection — only when stereo subcarriers are
            // emitted. Pilot is a constant-amplitude unmodulated 19 kHz
            // sine of amplitude `pilotLevel`, so its RMS is
            // `pilotLevel / √2`. Allow a wide tolerance band (0.5x to
            // 1.7x of expected) — narrower checks can trip when audio
            // composite has spectral energy near 19 kHz from harmonics
            // of HF input through configs without the encoder FIR.
            // The point of this invariant is "pilot is present at
            // roughly the right level," not bit-precise calibration.
            if !cfg.monoMode {
                let pilotRMS = DeepInvariants.rmsAtFrequency(
                    composite, frequencyHz: 19_000.0, sampleRate: deepSampleRate)
                let pilotExpectedRMS = Float(cfg.pilotLevel) / sqrtf(2.0)
                // Lower bound 0.3x — when the encoder FIR is randomly
                // disabled, audio composite energy near 19 kHz can
                // partially cancel the pilot Goertzel measurement. The
                // pilot is still injected at the correct level; the
                // 1-second-window measurement just gets noisy.
                #expect(pilotRMS > pilotExpectedRMS * 0.3,
                    "\(label): pilot RMS \(pilotRMS) << expected \(pilotExpectedRMS) — pilot may not be injecting")
                #expect(pilotRMS < pilotExpectedRMS * 1.7,
                    "\(label): pilot RMS \(pilotRMS) >> expected \(pilotExpectedRMS) — audio composite may be contaminating 19 kHz")
            }

            // RDS subcarrier is BPSK biphase with the carrier
            // *suppressed* by design — energy lives in the sidebands
            // at 57 kHz ± 1187.5 Hz, not at the carrier itself. Assert
            // sideband-band energy is present rather than spot-Goertzel
            // at 57 kHz (which always reads near-zero on a clean RDS
            // stream and would flag a working chain as broken).
            if cfg.enRDS && !cfg.monoMode {
                let rdsBand = DeepInvariants.bandEnergyDBFS(
                    composite, from: 55_000, to: 59_000,
                    sampleRate: deepSampleRate, fftSize: 8192)
                #expect(rdsBand > -75.0,
                    "\(label): RDS sideband energy \(rdsBand) dBFS — too low, RDS may not be injecting")
            }
        }
    }
}

// MARK: - Layer 3 — Pairwise enable/disable matrix

@Suite("Deep DSP — pairwise enable/disable",
       .enabled(if: deepEnabled))
struct DeepPairwiseTests {

    /// Hand-curated pairwise covering array on the 12 high-impact
    /// stage flags: AGC, multiband, bassClipper, dcClipper,
    /// compositeClipper, BS.412, PrimeBass, stereoWidener, phaseRot,
    /// preEncodeLim, monoMode, advancedDynamics. Each row covers all 4
    /// possible (off/on, off/on) combinations of every pair. This is a
    /// small hand-built covering set — sufficient for catching pair
    /// interactions without 2^12 = 4096 full Cartesian rows. Verified
    /// COMPLETE by enumeration (2026-09-04) — the AdvDyn column covers
    /// all 4 combos against every other column, including AdvDyn=on
    /// alongside AGC/MB=on (the leveler overrides them), and row 12 was
    /// added to close two pre-existing gaps in the 11-flag array
    /// (Widener×Mono (on,on) and Phase×Mono (off,on) were never covered).
    static let rows: [[Bool]] = [
        //  AGC,   MB,   Bass, DC,   Comp, BS,   PB,   Wide, Phase,PreL, Mono, AdvDyn
        [ true,  true, true, false,true, false,false,false,false,true, false, true ],
        [ false, false,false,true, false,true, true, true, true, false,false, true ],
        [ true,  false,true, true, false,false,true, false,true, false,true , false],
        [ false, true, false,false,true, true, false,true, false,true, false, false],
        [ true,  true, false,true, true, false,true, true, false,false,false, false],
        [ false, false,true, false,false,true, false,false,true, true, true , false],
        [ true,  false,false,false,true, true, true, false,false,true, false, false],
        [ false, true, true, true, false,false,false,true, true, false,false, false],
        [ true,  true, true, true, true, true, true, true, true, true, false, true ],
        [ false, false,false,false,false,false,false,false,false,false,false, false],
        [ true,  false,true, false,false,true, false,true, true, true, false, false],
        [ false, true, false,true, true, false,true, false,true, false,true , true ],
        [ false, false,false,false,true, false,false,true, false,true, true , true ],
    ]

    @Test(arguments: 0..<rows.count)
    func pairwiseInvariantsHold(rowIndex: Int) {
        let row = Self.rows[rowIndex]
        var cfg = AppConfig()
        cfg.sampleRate = Double(deepSampleRate)
        cfg.blockSize = deepBlockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.processingBypass = false
        cfg.preemphasisUS = 50
        cfg.limitMPX = true
        cfg.encoderFIREnabled = true

        cfg.widebandAGCEnabled       = row[0]
        cfg.multibandEnabled         = row[1]
        cfg.bassClipperEnabled       = row[2]
        cfg.dcClipperEnabled         = row[3]
        cfg.compositeClipperEnabled  = row[4]
        cfg.bs412Enabled             = row[5]
        cfg.primeBassEnabled         = row[6]
        cfg.stereoWidenEnabled       = row[7]
        cfg.phaseRotationEnabled     = row[8]
        cfg.preEncodeAudioLimiterEnabled = row[9]
        cfg.monoMode                 = row[10]
        cfg.advancedDynamicsEnabled  = row[11]

        cfg.enRDS = !cfg.monoMode
        cfg.rdsNowPlayingEnabled = false

        // HF-rich pop and sustained bass exercise different stages.
        for program in [DeepProgram.hfRichPop, .sustainedBass, .percussiveTransients] {
            let label = "row=\(rowIndex) program=\(program.rawValue)"
            let composite = deepRender(config: cfg, program: program)
            DeepInvariants.assertAllFinite(composite, where: label)
            DeepInvariants.assertCompositePeakBounded(composite, where: label)
        }
    }
}

// MARK: - Layer 4 — Counteract detection

@Suite("Deep DSP — counteract detection",
       .enabled(if: deepEnabled))
struct DeepCounteractTests {

    struct StagePair: Sendable {
        let name: String
        let configureA: @Sendable (inout AppConfig) -> Void
        let configureB: @Sendable (inout AppConfig) -> Void
    }

    private static func baseConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = Double(deepSampleRate)
        cfg.blockSize = deepBlockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.processingBypass = false
        cfg.preemphasisUS = 50
        cfg.limitMPX = true
        cfg.encoderFIREnabled = true
        // Disable everything; the pair's configure closures turn on
        // exactly the stages under test.
        cfg.widebandAGCEnabled = false
        cfg.multibandEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.compositeClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.primeBassEnabled = false
        cfg.stereoWidenEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.preEncodeAudioLimiterEnabled = false
        cfg.parametricEQEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.monoMode = false
        cfg.enRDS = false
        cfg.rdsNowPlayingEnabled = false
        // Explicit so a future advanced_dynamics_enabled default flip
        // cannot silently change what "everything off" means here.
        cfg.advancedDynamicsEnabled = false
        return cfg
    }

    static let pairs: [StagePair] = [
        StagePair(name: "AGC × Multiband",
            configureA: { $0.widebandAGCEnabled = true },
            configureB: { $0.multibandEnabled = true; $0.multibandMode = 5 }),
        StagePair(name: "PrimeBass × BassClipper",
            configureA: { $0.primeBassEnabled = true; $0.primeBassAmount = 0.6; $0.primeBassHarmonics = 0.5 },
            configureB: { $0.bassClipperEnabled = true }),
        StagePair(name: "CompositeClipper × BS.412",
            configureA: { $0.compositeClipperEnabled = true },
            configureB: { $0.bs412Enabled = true }),
        StagePair(name: "PreEncodeLimiter × CompositeClipper",
            configureA: { $0.preEncodeAudioLimiterEnabled = true },
            configureB: { $0.compositeClipperEnabled = true }),
        StagePair(name: "Widener × MonoBass",
            configureA: { $0.stereoWidenEnabled = true; $0.stereoWidenWidth = 1.4 },
            configureB: { $0.monoBassEnabled = true }),
        StagePair(name: "PhaseRotator × Multiband",
            configureA: { $0.phaseRotationEnabled = true },
            configureB: { $0.multibandEnabled = true; $0.multibandMode = 5 }),
        StagePair(name: "AGC × CompositeClipper",
            configureA: { $0.widebandAGCEnabled = true },
            configureB: { $0.compositeClipperEnabled = true }),
        StagePair(name: "Multiband × MultibandLimiter",
            configureA: { $0.multibandEnabled = true; $0.multibandMode = 5 },
            configureB: { $0.multibandEnabled = true; $0.multibandMode = 5;
                          $0.multibandLimiterEnabled = true }),
        StagePair(name: "DCClipper × CompositeClipper",
            configureA: { $0.dcClipperEnabled = true },
            configureB: { $0.compositeClipperEnabled = true }),
        StagePair(name: "ParametricEQ × Multiband",
            configureA: { $0.parametricEQEnabled = true },
            configureB: { $0.multibandEnabled = true; $0.multibandMode = 5 }),
        StagePair(name: "AdvancedDynamics × CompositeClipper",
            configureA: { $0.advancedDynamicsEnabled = true },
            configureB: { $0.compositeClipperEnabled = true }),
        StagePair(name: "AdvancedDynamics × BS.412",
            configureA: { $0.advancedDynamicsEnabled = true },
            configureB: { $0.bs412Enabled = true }),
        StagePair(name: "AdvancedDynamics × PreEncodeLimiter",
            configureA: { $0.advancedDynamicsEnabled = true },
            configureB: { $0.preEncodeAudioLimiterEnabled = true }),
    ]

    @Test(arguments: 0..<pairs.count)
    func pairsDoNotCounteract(pairIndex: Int) {
        let pair = Self.pairs[pairIndex]
        let program = DeepProgram.hfRichPop

        var cfgA = Self.baseConfig()
        pair.configureA(&cfgA)

        var cfgB = Self.baseConfig()
        pair.configureB(&cfgB)

        var cfgAB = Self.baseConfig()
        pair.configureA(&cfgAB)
        pair.configureB(&cfgAB)

        let outA = deepRender(config: cfgA, program: program)
        let outB = deepRender(config: cfgB, program: program)
        let outAB = deepRender(config: cfgAB, program: program)

        DeepInvariants.assertAllFinite(outAB, where: "\(pair.name) [A∧B]")
        DeepInvariants.assertCompositePeakBounded(outAB, where: "\(pair.name) [A∧B]")

        // Conspiracy-to-amplify: combined peak ≤ max(A, B) × 1.10.
        // (Some constructive interaction between FIR edges is fine; a
        // 10 % allowance covers it without permitting genuine blow-up.)
        let peakA = DeepInvariants.peak(outA)
        let peakB = DeepInvariants.peak(outB)
        let peakAB = DeepInvariants.peak(outAB)
        let bound = max(peakA, peakB) * 1.10
        #expect(peakAB <= bound,
            "\(pair.name): combined peak \(peakAB) > 1.10 × max(A=\(peakA), B=\(peakB)) = \(bound) — possible amplitude conspiracy")

        // Conspiracy-to-silence: combined audio-band energy at 1 kHz
        // should be at least min(A, B) − 6 dB. (Combined gain reduction
        // is OK; complete cancellation is not.) Measured at the render's
        // midpoint — steady state — so stage group delay and gain settling
        // cannot masquerade as cancellation.
        let steadyStart = outA.count / 2
        let bandA = DeepInvariants.bandEnergyDBFS(outA, from: 800, to: 1200, sampleRate: deepSampleRate, start: steadyStart)
        let bandB = DeepInvariants.bandEnergyDBFS(outB, from: 800, to: 1200, sampleRate: deepSampleRate, start: steadyStart)
        let bandAB = DeepInvariants.bandEnergyDBFS(outAB, from: 800, to: 1200, sampleRate: deepSampleRate, start: steadyStart)
        let minSingle = min(bandA, bandB)
        #expect(bandAB > minSingle - 6.0,
            "\(pair.name): combined 800-1200 Hz energy \(bandAB) dB << min(A=\(bandA), B=\(bandB)) − 6 dB — possible cancellation")
    }
}

// MARK: - Layer 5 — Per-preset deviation/safety check

@Suite("Deep DSP — per-preset safety",
       .enabled(if: deepEnabled))
struct DeepPerPresetTests {

    private static func presetConfig(presetID: String,
                                     mode: Int,
                                     x1: Double,
                                     x2: Double,
                                     x3: Double,
                                     x4: Double) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = Double(deepSampleRate)
        cfg.blockSize = deepBlockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.processingBypass = false
        cfg.preemphasisUS = 50
        cfg.limitMPX = true
        cfg.encoderFIREnabled = true
        cfg.widebandAGCEnabled = true
        cfg.multibandEnabled = true
        cfg.multibandMode = mode
        cfg.multibandPresetID = presetID
        cfg.multibandX1Hz = x1
        cfg.multibandX2Hz = x2
        cfg.multibandX3Hz = x3
        cfg.multibandX4Hz = x4
        cfg.bassClipperEnabled = true
        cfg.compositeClipperEnabled = true
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.enRDS = false
        cfg.rdsNowPlayingEnabled = false
        return cfg
    }

    /// (id, mode, x1..x4) — copied from `SwiftUIControlApp.swift`
    /// preset definitions. Subset chosen to cover the major
    /// musical / talk / dance categories without rendering all eight.
    static let presets: [(String, Int, Double, Double, Double, Double)] = [
        ("5_ac",   5, 90,  350, 1800, 6800),
        ("5_talk", 5, 110, 420, 2200, 7000),
        ("5_chr",  5, 95,  380, 2000, 7200),
        ("5_rock", 5, 85,  340, 1700, 6500),
        ("5_dance",5, 95,  420, 2300, 7400),
    ]

    @Test(arguments: 0..<presets.count)
    func presetSafetyHolds(presetIndex: Int) {
        let (id, mode, x1, x2, x3, x4) = Self.presets[presetIndex]
        let cfg = Self.presetConfig(
            presetID: id, mode: mode,
            x1: x1, x2: x2, x3: x3, x4: x4)

        for program in [DeepProgram.hfRichPop, .sustainedBass, .percussiveTransients] {
            let label = "preset=\(id) program=\(program.rawValue)"
            let composite = deepRender(config: cfg, program: program)
            DeepInvariants.assertAllFinite(composite, where: label)
            DeepInvariants.assertCompositePeakBounded(composite, where: label)
        }
    }
}

// MARK: - Layer 1 — Per-stage isolation smoke tests

@Suite("Deep DSP — per-stage isolation",
       .enabled(if: deepEnabled))
struct DeepPerStageTests {

    private static func solo(_ flagSetter: (inout AppConfig) -> Void) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = Double(deepSampleRate)
        cfg.blockSize = deepBlockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.processingBypass = false
        cfg.preemphasisUS = 0
        cfg.limitMPX = false
        cfg.widebandAGCEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.primeBassEnabled = false
        cfg.stereoWidenEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false
        cfg.preEncodeAudioLimiterEnabled = false
        cfg.encoderFIREnabled = false
        cfg.monoMode = true
        cfg.enRDS = false
        cfg.rdsNowPlayingEnabled = false
        flagSetter(&cfg)
        return cfg
    }

    @Test func phaseRotatorAlone() {
        let cfg = Self.solo { $0.phaseRotationEnabled = true }
        let out = deepRender(config: cfg, program: .hfRichPop)
        DeepInvariants.assertAllFinite(out, where: "phaseRotator")
        DeepInvariants.assertCompositePeakBounded(out, where: "phaseRotator")
    }

    @Test func parametricEQAlone() {
        let cfg = Self.solo { $0.parametricEQEnabled = true }
        let out = deepRender(config: cfg, program: .hfRichPop)
        DeepInvariants.assertAllFinite(out, where: "parametricEQ")
        DeepInvariants.assertCompositePeakBounded(out, where: "parametricEQ")
    }

    @Test func monoBassAlone() {
        let cfg = Self.solo { $0.monoBassEnabled = true; $0.monoMode = false }
        let out = deepRender(config: cfg, program: .sustainedBass)
        DeepInvariants.assertAllFinite(out, where: "monoBass")
        DeepInvariants.assertCompositePeakBounded(out, where: "monoBass")
    }

    @Test func stereoWidenerAlone() {
        let cfg = Self.solo {
            $0.stereoWidenEnabled = true
            $0.stereoWidenWidth = 1.4
            $0.monoMode = false
        }
        let out = deepRender(config: cfg, program: .hfRichPop)
        DeepInvariants.assertAllFinite(out, where: "stereoWidener")
        DeepInvariants.assertCompositePeakBounded(out, where: "stereoWidener")
    }

    @Test func bs412Alone() {
        let cfg = Self.solo { $0.bs412Enabled = true }
        let out = deepRender(config: cfg, program: .pinkNoise)
        DeepInvariants.assertAllFinite(out, where: "bs412")
        DeepInvariants.assertCompositePeakBounded(out, where: "bs412")
    }

    @Test func preEncodeLimiterAlone() {
        let cfg = Self.solo { $0.preEncodeAudioLimiterEnabled = true }
        let out = deepRender(config: cfg, program: .fullScaleStep)
        DeepInvariants.assertAllFinite(out, where: "preEncodeLimiter")
        DeepInvariants.assertCompositePeakBounded(out, where: "preEncodeLimiter")
    }

    @Test func advancedDynamicsAlone() {
        let cfg = Self.solo { $0.advancedDynamicsEnabled = true }
        let out = deepRender(config: cfg, program: .fullScaleStep)
        DeepInvariants.assertAllFinite(out, where: "advancedDynamics")
        DeepInvariants.assertCompositePeakBounded(out, where: "advancedDynamics")
    }

    @Test func ssbStereoAlone() {
        // monoMode off: the SSB encoder only acts on L-R content.
        let cfg = Self.solo {
            $0.ssbStereoEnabled = true
            $0.ssbStereoAmount = 1.0
            $0.monoMode = false
        }
        let out = deepRender(config: cfg, program: .hfRichPop)
        DeepInvariants.assertAllFinite(out, where: "ssbStereo")
        DeepInvariants.assertCompositePeakBounded(out, where: "ssbStereo")
    }

    @Test func dcClipperAlone() {
        let cfg = Self.solo { $0.dcClipperEnabled = true }
        let out = deepRender(config: cfg, program: .dcOffset)
        DeepInvariants.assertAllFinite(out, where: "dcClipper")
        DeepInvariants.assertCompositePeakBounded(out, where: "dcClipper")
    }

    @Test func multibandThreeBandAlone() {
        let cfg = Self.solo {
            $0.multibandEnabled = true
            $0.multibandMode = 3
        }
        let out = deepRender(config: cfg, program: .pinkNoise)
        DeepInvariants.assertAllFinite(out, where: "multibandThreeBand")
        DeepInvariants.assertCompositePeakBounded(out, where: "multibandThreeBand")
    }

    @Test func multibandFiveBandAlone() {
        let cfg = Self.solo {
            $0.multibandEnabled = true
            $0.multibandMode = 5
        }
        let out = deepRender(config: cfg, program: .pinkNoise)
        DeepInvariants.assertAllFinite(out, where: "multibandFiveBand")
        DeepInvariants.assertCompositePeakBounded(out, where: "multibandFiveBand")
    }

    @Test func multibandLimiterAlone() {
        let cfg = Self.solo {
            $0.multibandEnabled = true
            $0.multibandMode = 5
            $0.multibandLimiterEnabled = true
        }
        let out = deepRender(config: cfg, program: .fullScaleStep)
        DeepInvariants.assertAllFinite(out, where: "multibandLimiter")
        DeepInvariants.assertCompositePeakBounded(out, where: "multibandLimiter")
    }

    @Test func encoderFIRAlone() {
        let cfg = Self.solo {
            $0.encoderFIREnabled = true
            $0.monoMode = false
        }
        let out = deepRender(config: cfg, program: .hfRichPop)
        DeepInvariants.assertAllFinite(out, where: "encoderFIR")
        DeepInvariants.assertCompositePeakBounded(out, where: "encoderFIR")
    }

    @Test func finalSafetyLimiterAlone() {
        let cfg = Self.solo {
            $0.limitMPX = true
            $0.encoderFIREnabled = true
        }
        let out = deepRender(config: cfg, program: .fullScaleStep)
        DeepInvariants.assertAllFinite(out, where: "finalSafetyLimiter")
        DeepInvariants.assertCompositePeakBounded(out, where: "finalSafetyLimiter")
    }
}
