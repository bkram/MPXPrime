// Platform split: on macOS these resolve to the real Accelerate / Darwin /
// os modules (numerics and locking untouched); on Linux the
// MPXPrimeAcceleration shim provides same-name vDSP/vvtanhf functions and an
// OSAllocatedUnfairLock polyfill, and Glibc provides libm.
#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Atomics
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import MPXPrimeCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest on Linux corelibs
#endif
#if canImport(os)
import os
#endif

// MARK: - Per-Band Fast Peak Limiter
// Fast-attack, high-ratio brick-wall limiter for per-band transient control.
// Operates after multiband compressor, before band summation.
struct BandLimiter {
    private var thresholdLin: Float = 1.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    // Stereo-linked envelope: both channels are limited together based on the
    // max(|L|, |R|) peak, so a single envelope is sufficient.
    private var env: Float = 0.0

    mutating func configure(sampleRate: Float, thresholdDB: Float, attackMS: Float, releaseMS: Float) {
        thresholdLin = powf(10.0, min(0.0, thresholdDB) / 20.0)
        let sr = max(8_000.0, sampleRate)
        attackCoeff = expf(-1.0 / (max(0.01, attackMS) * 0.001 * sr))
        releaseCoeff = expf(-1.0 / (max(1.0, releaseMS) * 0.001 * sr))
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        let peak = max(fabsf(left), fabsf(right))
        let coeff = peak > env ? attackCoeff : releaseCoeff
        env = (coeff * env) + ((1.0 - coeff) * peak)
        if env > thresholdLin {
            let gain = thresholdLin / env
            return (left * gain, right * gain)
        }
        return (left, right)
    }
}

// MARK: - Downward Expander (per-band)
// Reduces gain on quiet bands to prevent AGC from lifting noise floor.
struct DownwardExpander {
    private var thresholdLin: Float = 0.001
    private var ratio: Float = 2.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    // Stereo-linked detector: both channels share one envelope driven by
    // max(|L|, |R|), so a single gain value is applied to the band.
    private var env: Float = 0.0

    mutating func configure(sampleRate: Float, thresholdDB: Float, ratio r: Float,
                            attackMS: Float, releaseMS: Float) {
        thresholdLin = powf(10.0, thresholdDB / 20.0)
        ratio = max(1.0, r)
        let sr = max(8_000.0, sampleRate)
        attackCoeff = expf(-1.0 / (max(0.1, attackMS) * 0.001 * sr))
        releaseCoeff = expf(-1.0 / (max(1.0, releaseMS) * 0.001 * sr))
    }

    @inline(__always)
    mutating func expanderGain(left: Float, right: Float) -> Float {
        let peak = max(fabsf(left), fabsf(right))
        let coeff = peak > env ? attackCoeff : releaseCoeff
        env = (coeff * env) + ((1.0 - coeff) * peak)
        if env < thresholdLin && env > 1e-10 {
            // Below threshold: reduce gain by expansion ratio. Floor the
            // result at -60 dB so very quiet signals don't underflow to a
            // subnormal gain (which produced a hard silent-vs-expanding
            // discontinuity / tremolo just above the 1e-10 detector floor).
            let belowDB = 20.0 * log10f(env / thresholdLin)
            let expandedDB = belowDB * ratio
            return max(1e-3, powf(10.0, expandedDB / 20.0))
        }
        return 1.0
    }
}

struct WidebandAGCRider {
    private var detectorAttackCoeff: Float = 0.0
    private var detectorReleaseCoeff: Float = 0.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    private var fastMakeupCoeff: Float = 0.0
    private var gateReleaseCoeff: Float = 0.0
    private var densityCoeff: Float = 0.0
    private var fastEnvCoeff: Float = 0.0
    private var slowEnvCoeff: Float = 0.0
    private var sampleRate: Float = 48_000.0
    private var configuredReleaseS: Double = 0.250

    private var targetDB: Float = -20.0
    private var minGainDB: Float = -12.0
    private var maxGainDB: Float = 12.0
    private var windowDB: Float = 1.5
    private var gateThresholdDB: Float = -42.0
    private var makeupThresholdDB: Float = -30.0

    private var kWeightingEnabled: Bool = true
    private var programDependentRelease: Bool = true
    private var kWeightL = KWeightingFilter()
    private var kWeightR = KWeightingFilter()

    private var power: Float = 0.0
    private var gainDB: Float = 0.0
    private var gateActive: Bool = false
    /// Two envelope followers at different time constants. Their log-
    /// ratio is the "program density" signal: if fast and slow
    /// envelopes agree, program is flat; if they diverge (transients,
    /// syllables, rhythmic modulation) program is busy. More reliable
    /// than |ΔlevelDB| on a heavily-smoothed detector, which barely
    /// wobbles between adjacent samples.
    private var fastEnv: Float = 0.0
    private var slowEnv: Float = 0.0
    /// Smoothed density value in dB. ~0 dB on flat program, several
    /// dB on busy program.
    private var density: Float = 0.0

    // Bass-desensitised AGC (opt-in, default off). Two complementary effects on
    // the AGC sidechain so a kick / heavy bass line doesn't pump the whole chain:
    //   P4 (US 4,249,042): attenuate the LF band in the *sidechain* (not the audio)
    //     so bass / kick energy can't dominate the loudness detector and drag the
    //     whole chain down. The detector tracks the mid/HF program instead.
    //   P5 (US 3,790,896): duration-aware recovery -- a *brief* reduction (a
    //     transient duck) recovers fast; a sustained reduction recovers at the
    //     normal (density-scaled) rate. Stops a momentary duck from pumping.
    private var bassDesensEnabled: Bool = false
    private var bassShelfL = Biquad()
    private var bassShelfR = Biquad()
    private var bassFastRecoveryCoeff: Float = 0.0
    private var dtPerSample: Float = 0.0
    private var reductionDurationS: Float = 0.0
    // Low-shelf cut applied to the *sidechain* LF (a decisive -14 dB below the
    // crossover) so bass / kicks don't drive the loudness detector. Audio is
    // untouched. A shelf gives the correct magnitude rolloff -- a subtract-lowpass
    // would phase-cancel poorly on tones.
    private static let bassShelfGainDB: Float = -14.0

    mutating func configure(
        sampleRate: Float,
        targetDB: Float,
        attackMS: Float,
        releaseMS: Float,
        minGainDB: Float,
        maxGainDB: Float,
        kWeightingEnabled: Bool = true,
        programDependentRelease: Bool = true,
        bassDesensitizeEnabled: Bool = false,
        bassDesensitizeFreqHz: Float = 150.0
    ) {
        let sr = max(8_000.0, sampleRate)
        self.sampleRate = sr
        let detectorAttackS = max(0.005, min(Double(attackMS) * 0.001 * 0.35, 0.050))
        let detectorReleaseS = max(0.120, Double(releaseMS) * 0.001 * 0.60)
        detectorAttackCoeff = expf(-1.0 / Float(detectorAttackS * Double(sr)))
        detectorReleaseCoeff = expf(-1.0 / Float(detectorReleaseS * Double(sr)))

        let attackS = max(0.010, Double(attackMS) * 0.001)
        let releaseS = max(0.250, Double(releaseMS) * 0.001)
        let fastMakeupS = max(0.120, min(releaseS * 0.35, 0.450))
        configuredReleaseS = releaseS
        attackCoeff = expf(-1.0 / Float(attackS * Double(sr)))
        releaseCoeff = expf(-1.0 / Float(releaseS * Double(sr)))
        fastMakeupCoeff = expf(-1.0 / Float(fastMakeupS * Double(sr)))
        gateReleaseCoeff = expf(-1.0 / Float(1.6 * Double(sr)))
        // Density tracker: fast envelope (~50 ms) tracks syllable /
        // transient wobble; slow envelope (~1 s) tracks program
        // platform. Their log-ratio gauges program busy-ness.
        // Smoothed over ~0.5 s so the density value itself is stable.
        fastEnvCoeff = expf(-1.0 / Float(0.050 * Double(sr)))
        slowEnvCoeff = expf(-1.0 / Float(1.000 * Double(sr)))
        densityCoeff = expf(-1.0 / Float(0.500 * Double(sr)))

        self.targetDB = targetDB
        self.minGainDB = minGainDB
        self.maxGainDB = maxGainDB
        self.windowDB = 3.0
        self.gateThresholdDB = targetDB - maxGainDB - 10.0
        self.makeupThresholdDB = targetDB - maxGainDB + 2.0

        self.kWeightingEnabled = kWeightingEnabled
        self.programDependentRelease = programDependentRelease
        kWeightL.configure(sampleRate: sr)
        kWeightR.configure(sampleRate: sr)

        // Bass-desensitise sidechain setup.
        self.bassDesensEnabled = bassDesensitizeEnabled
        let bassFreq = clampf(bassDesensitizeFreqHz, 60.0, 300.0)
        bassShelfL.configureLowShelf(gainDB: Self.bassShelfGainDB, cutoffHz: bassFreq, sampleRate: sr)
        bassShelfR.configureLowShelf(gainDB: Self.bassShelfGainDB, cutoffHz: bassFreq, sampleRate: sr)
        // Brief reductions recover at ~100 ms (P5).
        bassFastRecoveryCoeff = expf(-1.0 / Float(0.100 * Double(sr)))
        dtPerSample = 1.0 / sr
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        // Sidechain feed — audio path stays pristine, only the
        // detector sees the K-weighted signal.
        var sideL: Float
        var sideR: Float
        if kWeightingEnabled {
            sideL = kWeightL.process(left)
            sideR = kWeightR.process(right)
        } else {
            sideL = left
            sideR = right
        }

        if bassDesensEnabled {
            // P4: low-shelf-cut the LF band in the sidechain so bass / kick energy
            // can't dominate the loudness detector. Audio path is untouched -- only
            // the detector is desensitised.
            sideL = bassShelfL.process(sideL)
            sideR = bassShelfR.process(sideR)
        }

        let monoPower = max(1e-12, 0.5 * ((sideL * sideL) + (sideR * sideR)))
        let detectorCoeff = monoPower > power ? detectorAttackCoeff : detectorReleaseCoeff
        power = (detectorCoeff * power) + ((1.0 - detectorCoeff) * monoPower)
        power = zapDenorm(power)

        let levelDB = 10.0 * log10f(max(power, 1e-12))

        // Program-density estimate via fast-vs-slow envelope
        // divergence. Run raw power through two first-order smoothers
        // at ~50 ms and ~1 s; their log-ratio is how far the short-
        // term envelope is from the platform. Busy program (syllables,
        // transients, rhythmic modulation) makes |ratio_dB| large;
        // flat program keeps fast ≈ slow → ratio ≈ 0 dB.
        fastEnv = (fastEnvCoeff * fastEnv) + ((1.0 - fastEnvCoeff) * monoPower)
        slowEnv = (slowEnvCoeff * slowEnv) + ((1.0 - slowEnvCoeff) * monoPower)
        fastEnv = zapDenorm(fastEnv)
        slowEnv = zapDenorm(slowEnv)
        let envRatio = max(fastEnv, slowEnv) / max(1e-12, min(fastEnv, slowEnv))
        let instantDensity = 10.0 * log10f(max(1.0, envRatio))
        density = (densityCoeff * density) + ((1.0 - densityCoeff) * instantDensity)

        let desiredGainDB = clampf(targetDB - levelDB, minGainDB, maxGainDB)

        let targetGainDB: Float
        var coeff: Float
        if levelDB < gateThresholdDB {
            // Do not lift room noise or codec hash; drift back toward unity instead.
            targetGainDB = 0.0
            coeff = gateReleaseCoeff
            gateActive = true
        } else if fabsf(desiredGainDB - gainDB) <= windowDB {
            targetGainDB = gainDB
            coeff = 1.0
            gateActive = false
        } else if desiredGainDB < gainDB {
            targetGainDB = desiredGainDB
            coeff = attackCoeff
            gateActive = false
        } else {
            targetGainDB = desiredGainDB
            // Release/makeup is the only branch that uses the density-scaled
            // coefficient, so compute it lazily here -- the two expf() are
            // skipped on attack, hold, gate, and in-window samples (most of
            // steady state). Bit-identical to computing it every sample: the
            // formula is unchanged and the other branches never observed it.
            // Density 0 -> configured release; density >=4 dB -> 3x slower
            // release (linear between, saturating at 3x so very busy program
            // can't stall the AGC completely).
            let useFastMakeup = levelDB < makeupThresholdDB
            if programDependentRelease {
                let densityClamped = max(0.0, min(4.0, Double(density)))
                let densityScale = 1.0 + densityClamped * 0.5   // 1x…3x
                let scaledReleaseS = configuredReleaseS * densityScale
                if useFastMakeup {
                    let scaledFastS = max(0.120, min(scaledReleaseS * 0.35, 0.450))
                    coeff = expf(-1.0 / Float(scaledFastS * Double(sampleRate)))
                } else {
                    coeff = expf(-1.0 / Float(scaledReleaseS * Double(sampleRate)))
                }
            } else {
                coeff = useFastMakeup ? fastMakeupCoeff : releaseCoeff
            }
            if bassDesensEnabled && reductionDurationS < 0.35 {
                // P5: the reduction has only been active briefly (a transient
                // duck), so recover fast -- smaller coeff = faster approach.
                coeff = min(coeff, bassFastRecoveryCoeff)
            }
            gateActive = false
        }

        gainDB = (coeff * gainDB) + ((1.0 - coeff) * targetGainDB)
        gainDB = clampf(gainDB, minGainDB, maxGainDB)

        if bassDesensEnabled {
            // Track how long the AGC has been actively reduced, for P5 recovery.
            if gainDB < -0.5 {
                reductionDurationS = min(reductionDurationS + dtPerSample, 5.0)
            } else {
                reductionDurationS = max(0.0, reductionDurationS - dtPerSample)
            }
        }

        let gain = powf(10.0, gainDB / 20.0)
        return (left * gain, right * gain)
    }

    mutating func reset() {
        power = 0.0
        gainDB = 0.0
        gateActive = false
        density = 0.0
        fastEnv = 0.0
        slowEnv = 0.0
        reductionDurationS = 0.0
        bassShelfL.reset()
        bassShelfR.reset()
        kWeightL.reset()
        kWeightR.reset()
    }

    var telemetry: (detectorDB: Float, gainDB: Float, gateActive: Bool) {
        let detectorDB = 10.0 * log10f(max(power, 1e-12))
        return (detectorDB, gainDB, gateActive)
    }

    /// Current program-density estimate in dB. Exposed for diagnostics
    /// / tests; not surfaced to the UI (yet).
    var currentDensityDB: Float { density }
}

struct MonoCompressor {
    var thresholdDB: Float = -18.0
    var ratio: Float = 2.0
    var makeupDB: Float = 0.0
    var kneeDB: Float = 0.0
    var detector = EnvelopeFollower()
    /// Diagnostic ONLY: the largest hold value seen since `configure`.
    /// Processing must never read this. Seeding the hold window from this
    /// lifetime maximum is the 0.65 audit's P0-3 -- it never decreased, so
    /// every later transient inherited the drive of the loudest one the
    /// band had ever seen, minutes earlier.
    var transientDriveObserved: Float = 0.0
    /// The CURRENT hold value, which decays while the window is open.
    /// `AdvancedDynamicsLeveler` has always used this shape.
    private var heldDrive: Float = 0.0

    /// The live hold value, for tests and diagnosis. Expires to 0 once the
    /// hold window closes and the programme stops producing transients.
    var transientHoldValue: Float { heldDrive }
    private(set) var lastGainReductionDB: Float = 0.0
    private var transientAwareAttackEnabled: Bool = false
    private var rmsPower: Float = 0.0
    private var rmsAttackCoeff: Float = 0.0
    private var rmsReleaseCoeff: Float = 0.0
    private var transientAttackCoeff: Float = 0.0
    private var transientHoldSamples: Int = 0
    private var transientHoldCounter: Int = 0
    private var transientHoldDecayCoeff: Float = 0.0
    /// 0.94 per sample at 48 kHz, expressed as a time constant.
    private static let transientHoldDecaySeconds: Float = 0.000_336_7

    // Program-dependent (dual-slope) release, 0.45 chain review B2. Every
    // broadcast multiband has one (Orban WP: "multiple time constant release
    // ... speeds up after an abrupt transient to prevent a hole, slows as
    // 0 dB GR is approached"; Omnia.11: per-band release + fast release;
    // Thimeo: release hold / flatness). Before 0.45 the
    // `multiband_release_program_dependent` flag scaled the release time by a
    // CONSTANT 1.1 -- no program dependence at all. Now: the applied gain
    // reduction follows the detector's target through a GR-domain smoother
    // whose release is fast (the configured release) while the reduction sits
    // deeper than the slow platform level (~1.5 s average of the reduction the
    // detector demands -- Orban's "platform": a drum hit is a transient excursion below it and is
    // recovered quickly, no hole), and 3x slower once the reduction is back
    // at or above the platform (the average level itself dropped: release
    // gently, no breathing). Off = single slope, bit-identical to the
    // pre-0.45 path.
    private var programDependentRelease: Bool = false
    private var appliedGRDB: Float = 0.0
    private var platformGRDB: Float = 0.0
    private var fastReleaseCoeff: Float = 0.0
    private var slowReleaseCoeff: Float = 0.0
    private var platformCoeff: Float = 0.0
    /// Hysteresis around the platform: below it by more than this = excursion.
    static let platformExcursionDB: Float = 0.25
    static let slowReleaseFactor: Float = 3.0
    /// Current platform (slow-average) gain reduction in dB (<= 0); diagnostics.
    var platformGainReductionDB: Float { platformGRDB }

    mutating func configure(
        sampleRate: Float,
        thresholdDB: Float,
        ratio: Float,
        attackMS: Float,
        releaseMS: Float,
        makeupDB: Float,
        kneeDB: Float = 0.0,
        transientAwareAttackEnabled: Bool = false,
        programDependentRelease: Bool = false
    ) {
        let sr = max(8_000.0, sampleRate)
        let attack = max(0.1, attackMS)
        let release = max(1.0, releaseMS)
        self.thresholdDB = thresholdDB
        self.ratio = max(1.0, ratio)
        self.makeupDB = makeupDB
        self.kneeDB = max(0.0, min(12.0, kneeDB))
        self.transientAwareAttackEnabled = transientAwareAttackEnabled
        self.programDependentRelease = programDependentRelease
        // With the dual-slope smoother owning the release shape, the detector
        // must not add a second release pole of its own (two cascaded 250 ms
        // poles recover a kick twice as slowly): it tracks the level quickly
        // and the GR smoother decides how fast the gain comes back.
        detector.configure(sampleRate: sr, attackMS: attack,
                           releaseMS: programDependentRelease ? min(release, 30.0) : release)
        rmsAttackCoeff = expf(-1.0 / (0.010 * sr))
        rmsReleaseCoeff = expf(-1.0 / (0.090 * sr))
        transientAttackCoeff = expf(-1.0 / ((attack * 3.2 * 0.001) * sr))
        transientHoldSamples = max(1, Int((sr * 0.010).rounded()))
        // The hold decays on a time constant, not on a fixed per-sample
        // factor: the old 0.94 meant 0.34 ms at the 48 kHz audio domain
        // but 0.08 ms with the dual-rate boundary off. 0.337 ms IS 0.94
        // per sample at 48 kHz, so the production domain is unchanged.
        transientHoldDecayCoeff = expf(-1.0 / (Self.transientHoldDecaySeconds * sr))
        transientHoldCounter = 0
        heldDrive = 0.0
        transientDriveObserved = 0.0
        lastGainReductionDB = 0.0
        rmsPower = 0.0
        fastReleaseCoeff = expf(-1.0 / ((release * 0.001) * sr))
        slowReleaseCoeff = expf(-1.0 / ((release * Self.slowReleaseFactor * 0.001) * sr))
        platformCoeff = expf(-1.0 / (1.5 * sr))
        appliedGRDB = 0.0
        platformGRDB = 0.0
    }

    mutating func process(_ x: Float, sidechainAbs: Float? = nil, thresholdBiasDB: Float = 0.0) -> Float {
        let detectorSample = sidechainAbs ?? x
        let env = max(
            1e-8,
            transientAwareAttackEnabled
                ? processTransientAwareEnvelope(detectorSample)
            : detector.processAbs(detectorSample)
        )
        let levelDB = 20.0 * log10f(env)
        let targetGRDB = gainReductionDB(for: levelDB, thresholdBiasDB: thresholdBiasDB)
        let gainDB: Float
        if programDependentRelease {
            if targetGRDB < appliedGRDB {
                // Attack timing is the detector's; the target is followed at once.
                appliedGRDB = targetGRDB
            } else {
                // Release: fast while the reduction is a transient excursion
                // below the platform, slow once it is back near the platform.
                let excursionDB = platformGRDB - appliedGRDB
                let coeff = excursionDB > Self.platformExcursionDB ? fastReleaseCoeff : slowReleaseCoeff
                appliedGRDB = zapDenorm((coeff * appliedGRDB) + ((1.0 - coeff) * targetGRDB))
            }
            // The platform averages the DEMANDED reduction (what the program
            // asks for), not the applied one -- averaging the applied gain
            // feeds back on itself and freezes the band near kick depth.
            platformGRDB = zapDenorm((platformCoeff * platformGRDB) + ((1.0 - platformCoeff) * targetGRDB))
            gainDB = appliedGRDB
        } else {
            gainDB = targetGRDB
        }
        lastGainReductionDB = gainDB
        let gain = powf(10.0, (gainDB + makeupDB) / 20.0)
        return x * gain
    }

    private mutating func processTransientAwareEnvelope(_ x: Float) -> Float {
        let ax = fabsf(x)
        let power = ax * ax
        let rmsCoeff = power > rmsPower ? rmsAttackCoeff : rmsReleaseCoeff
        rmsPower = (rmsCoeff * rmsPower) + ((1.0 - rmsCoeff) * power)
        rmsPower = zapDenorm(rmsPower)
        let rms = sqrtf(max(1e-12, rmsPower))

        let peakToRMS = ax / max(1e-4, rms)
        let rising = ax > detector.value
        let transientDrive =
            rising && ax > 1e-5
            ? clampf((peakToRMS - 1.65) / 2.35, 0.0, 1.0)
            : 0.0
        if transientDrive > 0.15 {
            transientHoldCounter = transientHoldSamples
        } else if transientHoldCounter > 0 {
            transientHoldCounter -= 1
        }
        heldDrive = transientHoldCounter > 0
            ? max(heldDrive * transientHoldDecayCoeff, transientDrive)
            : transientDrive
        transientDriveObserved = max(transientDriveObserved, heldDrive)

        let peakWeight = lerpf(0.58, 0.18, heldDrive)
        let hybrid = (rms * (1.0 - peakWeight)) + (ax * peakWeight)
        let attackCoeff = heldDrive > 0.0 ? transientAttackCoeff : detector.attackCoeff
        if hybrid > detector.value {
            detector.value = (attackCoeff * detector.value) + ((1.0 - attackCoeff) * hybrid)
        } else {
            detector.value = (detector.releaseCoeff * detector.value) + ((1.0 - detector.releaseCoeff) * hybrid)
        }
        detector.value = zapDenorm(detector.value)
        return detector.value
    }

    private func gainReductionDB(for levelDB: Float, thresholdBiasDB: Float = 0.0) -> Float {
        if ratio <= 1.0 {
            return 0.0
        }
        let effectiveThresholdDB = thresholdDB + thresholdBiasDB
        let kneeHalf = kneeDB * 0.5
        if kneeDB <= 0.01 {
            if levelDB <= effectiveThresholdDB {
                return 0.0
            }
            let over = levelDB - effectiveThresholdDB
            return -(over - (over / ratio))
        }

        let lower = effectiveThresholdDB - kneeHalf
        let upper = effectiveThresholdDB + kneeHalf
        if levelDB <= lower {
            return 0.0
        }
        if levelDB >= upper {
            let over = levelDB - effectiveThresholdDB
            return -(over - (over / ratio))
        }
        let delta = levelDB - lower
        let curve = ((1.0 / ratio) - 1.0) * ((delta * delta) / (2.0 * max(1e-4, kneeDB)))
        return curve
    }
}

/// Experimental single-stage "Advanced Dynamics" leveler (default off).
///
/// Replaces the wideband AGC + multiband compressor pair with ONE fused
/// 5-band leveling stage, so slow leveling and per-band density shaping can
/// never fight each other (the classic AGC-pulls-down-while-multiband-
/// pushes-up pumping). Each band rides its level toward a per-band target
/// with *program-adaptive* time constants instead of fixed attack/release:
///
///  - transient acceleration: a rising peak-vs-RMS transient blends the
///    gain smoother's TIME CONSTANT from the base attack toward a per-band
///    floor of two band periods (33 ms on the bass band, 0.3 ms on the top
///    band at the default crossovers), so fast peaks are caught without
///    sub-cycle gain slew (modulation splatter) on low bands;
///  - come-to-a-stop hold: inside the target window the gain freezes
///    entirely, and dense (already-compressed) program slows release
///    further, so material that already sits at the desired density passes
///    untouched;
///  - distance acceleration: the further the band sits from target, the
///    faster it approaches (both directions), giving a wide usable range
///    (>20 dB jumps inside one song) that stays inaudible near target;
///  - band sync: no band may sit more than `bandSyncMaxDisparityDB` from
///    its neighbours (transitively further apart for bands further apart,
///    the Thimeo / Orban "preserve frequency balance" coupling), so a tone
///    on a crossover skirt is not lifted by the neighbour's full range and
///    the top band never ducks alone on every burst;
///  - per-band peak limiter before the sum: the limiters the classic
///    multiband path keeps on each band are kept here too, so leveled band
///    peaks are tamed before the HF limiter and the clippers see them.
///
/// The band split reuses `LinearPhaseMultibandSplitter5` (own instance so
/// live-toggling never shares filter state with the multiband compressor);
/// the detector reuses the RMS/peak hybrid idea from `MonoCompressor` and
/// the dual-envelope density estimator from `WidebandAGCRider`. Inter-band
/// coupling reuses the graduated low-band-GR bias curve.
struct AdvancedDynamicsLeveler {
    private var splitter = LinearPhaseMultibandSplitter5()

    private struct BandState {
        var rmsPower: Float = 0.0
        var env: Float = 0.0
        var gainDB: Float = 0.0
        var heldDrive: Float = 0.0
        var transientHoldCounter: Int = 0
        /// Slow-release peak of `env` for the decay guard: while `env` sits
        /// well below this (program actively fading), lifting holds.
        var fallEnv: Float = 0.0
        /// Smoothed band-sync bounds (dB) on this band's gain, derived from
        /// its neighbours' gains. Start wide open so a fresh stage is unbound
        /// until the first neighbour reading has settled in.
        var syncLoDB: Float = -24.0
        var syncHiDB: Float = 24.0
        /// Above its gate on the last sample: carries program, so it is a
        /// spectral-balance reference for its neighbours.
        var active: Bool = false
    }
    private var bands = [BandState](repeating: BandState(), count: 5)
    /// Per-band peak limiters, run on each band's leveled output before the
    /// sum (review finding 1a). Fixed, conservative settings -- the
    /// multiband-limiter defaults (-3 dB, 0.5 / 50 ms); the generator's
    /// `multiband_limiter_*` keys belong to the classic path and must have
    /// no effect here (the stage-bypass contract is bit-exact).
    private var limiters = [BandLimiter](repeating: BandLimiter(), count: 5)
    static let bandLimiterThresholdDB: Float = -3.0
    static let bandLimiterAttackMS: Float = 0.5
    static let bandLimiterReleaseMS: Float = 50.0
    /// Per-band level targets in dB (amplitude, 20*log10), band 1..5.
    private var bandTargetsDB = [Float](repeating: -16.0, count: 5)

    // Detector coefficients (fixed; the adaptivity lives in the gain
    // smoother). The RMS window is band-scaled: at least two band periods
    // (review finding 5), so the bass band's level has no 2f ripple to
    // modulate its gain with; the envelope follower keeps 5 / 60 ms.
    private var rmsAttackCoeffs = [Float](repeating: 0.0, count: 5)
    private var rmsReleaseCoeffs = [Float](repeating: 0.0, count: 5)
    private var envAttackCoeff: Float = 0.0
    private var envReleaseCoeff: Float = 0.0
    private var transientHoldSamples: Int = 1
    /// Per-sample decay of the transient hold. The design value is 0.94 per
    /// sample AT THE 48 kHz AUDIO DOMAIN (a 0.337 ms time constant, the same
    /// as `MonoCompressor`); it is re-derived per rate as `0.94^(48000/sr)`
    /// so the hold decays by TIME, not by sample count -- a flat 0.94 was
    /// 0.08 ms with the dual-rate boundary off (audit P0-3 follow-up). The
    /// power form is exactly 0.94 at 48 kHz, so the production domain and
    /// the armed corpus gates are bit-identical to before.
    private var transientHoldDecayCoeff: Float = 0.94

    // Attack law anchors, in SECONDS (review finding 2). The per-sample
    // coefficient is derived from a time constant blended between the base
    // attack and the band's fast attack; blending the COEFFICIENT instead
    // (the pre-fix law) reached 30 us at full acceleration on every band,
    // the 60 Hz band included -- a whole cycle of gain slew per sample.
    private var attackBaseS: Float = 0.030
    /// Two band periods per band (2 / lower band edge; band 1 uses 60 Hz).
    private var attackFloorS = [Float](repeating: 0.0005, count: 5)
    /// The fastest attack each band may reach: `attackBaseS / 1000`, floored
    /// at `attackFloorS` and never slower than the base attack itself.
    private var attackFastS = [Float](repeating: 0.0005, count: 5)
    private var invSampleRate: Float = 1.0 / 192_000.0
    private var releaseBaseCoeff: Float = 0.0
    private var releaseFastCoeff: Float = 0.0
    private var gateDriftCoeff: Float = 0.0
    /// Smoother on the band-sync bounds (50 ms) so a bound that appears or
    /// moves (a neighbour crossing the gate, a fast neighbour attack) pulls
    /// this band along at a musical rate instead of stepping its gain.
    private var syncBoundCoeff: Float = 0.0

    // Program-density estimator (dual-envelope, WidebandAGCRider pattern).
    private var fastEnv: Float = 0.0
    private var slowEnv: Float = 0.0
    private var density: Float = 0.0
    private var fastEnvCoeff: Float = 0.0
    private var slowEnvCoeff: Float = 0.0
    private var densityCoeff: Float = 0.0

    // Inter-band coupling smoother (20 ms / 300 ms, multiband pattern).
    private var couplingGRDB: Float = 0.0
    private var couplingAttackCoeff: Float = 0.0
    private var couplingReleaseCoeff: Float = 0.0
    /// Decay-guard tracker release (~8.7 dB/s at 1 s tau): slower than any
    /// musical decay, so a fading note keeps `env` pinned below `fallEnv`
    /// and the guard holds; steady program keeps env ~= fallEnv (no hold).
    private var fallEnvCoeff: Float = 0.0

    private var maxLiftDB: Float = 18.0
    private var maxCutDB: Float = 24.0
    private var holdWindowDB: Float = 2.0
    private var gateThresholdDB: Float = -42.0

    /// Band sync (review finding 3): how far a band's gain may sit ABOVE
    /// (`bandSyncMaxLiftAboveNeighbourDB`) and BELOW
    /// (`bandSyncMaxCutBelowNeighbourDB`) each adjacent band's gain, in dB.
    /// Bands further apart are bounded transitively (twice the bound two
    /// bands apart, and so on), which is the octave-distance weighting in
    /// its simplest form. The bound is applied to the DESIRED gain, so a
    /// band comes to rest inside its hold window short of the bound through
    /// the ordinary time constants (no step), and as a safety clamp on the
    /// applied gain against the smoothed bound. Internal (not an INI key):
    /// the roadmap's Step 7 decides whether it becomes one.
    ///
    /// `bandSyncGatedBandsAreReferences`: whether a band below its gate
    /// (no program) still constrains its neighbours. With it on, a lone
    /// tone over an empty spectrum is lifted at most D past the empty
    /// bands (the crossover-skirt scenario reads +4 dB) but a sparse
    /// spectrum -- quiet ballad, speech with empty bass and top bands --
    /// loses most of its leveling range (quiet_ballad read -4 dB vs the
    /// classic chain). With it off an empty band carries no spectral-
    /// balance information and caps nothing; it is still bounded by its
    /// active neighbours and still drifts to unity itself.
    static let bandSyncMaxLiftAboveNeighbourDB: Float = 6.0
    static let bandSyncMaxCutBelowNeighbourDB: Float = 6.0
    static let bandSyncGatedBandsAreReferences: Bool = false
    /// The larger of the two bounds: the disparity any adjacent pair of
    /// active bands can reach (tests).
    static var bandSyncMaxDisparityDB: Float {
        max(bandSyncMaxLiftAboveNeighbourDB, bandSyncMaxCutBelowNeighbourDB)
    }

    var groupDelaySamples: Int { splitter.groupDelaySamples }

    /// Diagnostic for the rate-independence test: the largest transient hold
    /// any band is currently carrying. Not telemetry.
    var maxHeldTransientDrive: Float { bands.reduce(0.0) { max($0, $1.heldDrive) } }

    /// The per-band attack floors in seconds (diagnostics / tests).
    var attackFloorSeconds: [Float] { attackFloorS }

    /// Structure: sample rate + crossovers. Allocates FIR state when the
    /// rate or a crossover actually changed -- call on engine start and on
    /// a crossover live-change. Continuity (review finding 6): the band
    /// gains, detector envelopes, density and limiter envelopes are KEPT,
    /// and only the splitter is rebuilt (and only when its design changed),
    /// so a live crossover change or a re-enable never snaps every band to
    /// unity on air. `reset()` remains the explicit full flush.
    mutating func configureStructure(
        sampleRate: Float, x1Hz: Float, x2Hz: Float, x3Hz: Float, x4Hz: Float
    ) {
        let sr = max(8_000.0, sampleRate)
        let structureChanged = !structureConfigured
            || sr != storedSampleRate
            || x1Hz != storedX1Hz || x2Hz != storedX2Hz
            || x3Hz != storedX3Hz || x4Hz != storedX4Hz
        if structureChanged {
            splitter.configure(x1Hz: x1Hz, x2Hz: x2Hz, x3Hz: x3Hz, x4Hz: x4Hz, sampleRate: sr)
            splitter.reset()
        }
        // Per-band time floors: two periods of the band's lower edge (band 1
        // has no lower edge; 60 Hz is the lowest program fundamental it is
        // expected to ride). Guarded so a degenerate crossover cannot make a
        // floor of seconds or of zero.
        let edges: [Float] = [60.0, x1Hz, x2Hz, x3Hz, x4Hz]
        for i in 0..<5 {
            attackFloorS[i] = 2.0 / clampf(edges[i], 20.0, 24_000.0)
        }
        // Detector: 10 ms / 90 ms RMS window, each floored at the band's two
        // periods; 5 ms / 60 ms envelope (MonoCompressor's hybrid-detector
        // time constants).
        for i in 0..<5 {
            rmsAttackCoeffs[i] = expf(-1.0 / (max(0.010, attackFloorS[i]) * sr))
            rmsReleaseCoeffs[i] = expf(-1.0 / (max(0.090, attackFloorS[i]) * sr))
        }
        envAttackCoeff = expf(-1.0 / (0.005 * sr))
        envReleaseCoeff = expf(-1.0 / (0.060 * sr))
        transientHoldSamples = max(1, Int((sr * 0.010).rounded()))
        transientHoldDecayCoeff = powf(0.94, 48_000.0 / sr)
        fastEnvCoeff = expf(-1.0 / (0.050 * sr))
        slowEnvCoeff = expf(-1.0 / (1.000 * sr))
        densityCoeff = expf(-1.0 / (0.500 * sr))
        couplingAttackCoeff = expf(-1.0 / (0.020 * sr))
        couplingReleaseCoeff = expf(-1.0 / (0.300 * sr))
        fallEnvCoeff = expf(-1.0 / (1.0 * sr))
        gateDriftCoeff = expf(-1.0 / (1.6 * sr))
        syncBoundCoeff = expf(-1.0 / (0.050 * sr))
        invSampleRate = 1.0 / sr
        if sr != storedSampleRate || !structureConfigured {
            configureLimiters(sampleRate: sr)
        }
        storedSampleRate = sr
        storedX1Hz = x1Hz
        storedX2Hz = x2Hz
        storedX3Hz = x3Hz
        storedX4Hz = x4Hz
        structureConfigured = true
        setParameters(
            targetDB: storedTargetDB, lowOffsetDB: storedLowOffsetDB,
            midOffsetDB: storedMidOffsetDB, highOffsetDB: storedHighOffsetDB,
            maxGainDB: storedMaxGainDB, density: storedDensity, speed: storedSpeed
        )
    }

    private mutating func configureLimiters(sampleRate sr: Float) {
        for i in 0..<limiters.count {
            limiters[i].configure(
                sampleRate: sr,
                thresholdDB: Self.bandLimiterThresholdDB,
                attackMS: Self.bandLimiterAttackMS,
                releaseMS: Self.bandLimiterReleaseMS
            )
        }
    }

    // Parameter mirrors so structure changes can re-derive coefficients.
    private var structureConfigured = false
    private var storedSampleRate: Float = 192_000.0
    private var storedX1Hz: Float = 0.0
    private var storedX2Hz: Float = 0.0
    private var storedX3Hz: Float = 0.0
    private var storedX4Hz: Float = 0.0
    private var storedTargetDB: Float = -16.0
    private var storedLowOffsetDB: Float = 0.0
    private var storedMidOffsetDB: Float = -3.0
    private var storedHighOffsetDB: Float = -9.0
    private var storedMaxGainDB: Float = 12.0
    private var storedDensity: Float = 0.5
    private var storedSpeed: Float = 1.0

    /// Parameters: cheap (no allocation) — safe on any live change.
    mutating func setParameters(
        targetDB: Float, lowOffsetDB: Float, midOffsetDB: Float,
        highOffsetDB: Float, maxGainDB: Float, density: Float, speed: Float
    ) {
        storedTargetDB = targetDB
        storedLowOffsetDB = lowOffsetDB
        storedMidOffsetDB = midOffsetDB
        storedHighOffsetDB = highOffsetDB
        storedMaxGainDB = maxGainDB
        storedDensity = clampf(density, 0.0, 1.0)
        storedSpeed = clampf(speed, 0.25, 4.0)
        let sr = storedSampleRate

        // Low/mid/high anchors expand to 5 bands the same way the
        // multiband compressor interpolates bands 2 and 4.
        let o1 = lowOffsetDB
        let o3 = midOffsetDB
        let o5 = highOffsetDB
        bandTargetsDB[0] = targetDB + o1
        bandTargetsDB[1] = targetDB + lerpf(o1, o3, 0.5)
        bandTargetsDB[2] = targetDB + o3
        bandTargetsDB[3] = targetDB + lerpf(o3, o5, 0.5)
        bandTargetsDB[4] = targetDB + o5

        maxLiftDB = clampf(maxGainDB, 0.0, 24.0)
        maxCutDB = 24.0
        // Denser setting = tighter hold window (more leveling action) and
        // faster base movement.
        holdWindowDB = lerpf(3.0, 0.75, storedDensity)
        gateThresholdDB = targetDB - maxLiftDB - 10.0

        let speedScale = Double(1.0 / storedSpeed)
        // Attack anchors in the time domain; `speed` scales the base attack,
        // the per-band floor is physical (two band periods) and is not
        // scaled. A floor above the base attack (the bass band at speed 4)
        // simply pins that band at its base attack.
        attackBaseS = Float(0.030 * speedScale)
        for i in 0..<5 {
            attackFastS[i] = min(attackBaseS, max(attackBaseS / 1_000.0, attackFloorS[i]))
        }
        let releaseBaseS = lerpf(1.2, 0.4, storedDensity)
        let releaseFastS = releaseBaseS * 0.25
        releaseBaseCoeff = expf(-1.0 / (Float(Double(releaseBaseS) * speedScale) * sr))
        releaseFastCoeff = expf(-1.0 / (Float(Double(releaseFastS) * speedScale) * sr))
    }

    /// Full flush: every band to unity, every detector and the splitter
    /// cleared. Not called by the generator's live-change path (see
    /// `configureStructure`); for tests, verify modes and explicit resets.
    mutating func reset() {
        splitter.reset()
        for i in 0..<bands.count { bands[i] = BandState() }
        for i in 0..<limiters.count { limiters[i] = BandLimiter() }
        configureLimiters(sampleRate: storedSampleRate)
        fastEnv = 0.0
        slowEnv = 0.0
        density = 0.0
        couplingGRDB = 0.0
    }

    /// Current per-band gains in dB (diagnostics / tests / verify modes).
    /// Heap-allocates; never call from the render thread.
    var bandGainsDB: [Float] { bands.map { $0.gainDB } }
    /// Allocation-free per-band gains for the render-thread telemetry path.
    var bandGainsDBFixed: (Float, Float, Float, Float, Float) {
        (bands[0].gainDB, bands[1].gainDB, bands[2].gainDB, bands[3].gainDB, bands[4].gainDB)
    }
    /// Fast/slow envelope divergence in dB (~0 on dense program, several dB
    /// on sparse, dynamic program). Diagnostics / telemetry.
    var currentDensityDB: Float { density }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        guard splitter.enabled else { return (left, right) }
        // NaN / Inf guard: one non-finite input sample would otherwise sit
        // in every one-pole state (envelopes, gains, limiter) for good. It
        // is replaced by silence for this sample; everything downstream
        // stays finite and the stage recovers within the FIR length.
        let inL = left.isFinite ? left : 0.0
        let inR = right.isFinite ? right : 0.0
        let split = splitter.process(left: inL, right: inR)

        // Program-density estimate on the full-band linked input (the
        // WidebandAGCRider dual-envelope pattern): the fast/slow envelope
        // DIVERGENCE in dB. Dense, already-compressed program keeps the two
        // envelopes together (~0 dB); sparse, dynamic program (syllables,
        // hits, pauses) drives them apart. The release law below slows as
        // the divergence falls ("stop when already dense").
        let monoPower = max(1e-12, 0.5 * ((inL * inL) + (inR * inR)))
        fastEnv = zapDenorm((fastEnvCoeff * fastEnv) + ((1.0 - fastEnvCoeff) * monoPower))
        slowEnv = zapDenorm((slowEnvCoeff * slowEnv) + ((1.0 - slowEnvCoeff) * monoPower))
        let envRatio = max(fastEnv, slowEnv) / max(1e-12, min(fastEnv, slowEnv))
        let instantDensity = 10.0 * log10f(max(1.0, envRatio))
        density = (densityCoeff * density) + ((1.0 - densityCoeff) * instantDensity)

        // Per-band leveling; tuples throughout, no per-sample allocation
        // (audio-thread rule). Band 1 runs first so its smoothed reduction
        // can bias the upper bands' targets this same sample.
        let o1 = levelBand(index: 0, bl: split.0.0, br: split.0.1)
        let o2 = levelBand(index: 1, bl: split.1.0, br: split.1.1)
        let o3 = levelBand(index: 2, bl: split.2.0, br: split.2.1)
        let o4 = levelBand(index: 3, bl: split.3.0, br: split.3.1)
        let o5 = levelBand(index: 4, bl: split.4.0, br: split.4.1)
        return (
            o1.0 + o2.0 + o3.0 + o4.0 + o5.0,
            o1.1 + o2.1 + o3.1 + o4.1 + o5.1
        )
    }

    /// Graduated coupling bias per band (the multiband 5-band curve).
    /// NOTE (docs/project-roadmap.md Step 2 #5, measured 2026-09-04): the ~4 dB hat-SINAD
    /// cost vs music_loud is NOT the top-band target offset (0/-3/-6/-9
    /// all read ~14.1 dB), not `speed`, not the band-5 transient
    /// acceleration (zeroing its weight moved the gate < 0.1 dB), and not
    /// the composite clipper (clipper OFF reads WORSE, 12.8 dB). Matching
    /// drive recovers ~2 dB (loudness parity); the rest is intrinsic to
    /// leveling burst HF. Do not re-try those knobs for this fault.
    private static let couplingWeights: (Float, Float, Float, Float, Float)
        = (0.0, 0.10, 0.15, 0.22, 0.25)

    @inline(__always)
    private mutating func levelBand(index i: Int, bl: Float, br: Float) -> (Float, Float) {
        // Linked-RMS sidechain: one shared gain per band keeps the stereo
        // image exact by construction.
        let linked = sqrtf(((bl * bl) + (br * br)) * 0.5)

        var st = bands[i]
        // Band-scaled RMS window + transient drive (MonoCompressor hybrid
        // pattern).
        let power = linked * linked
        let rmsCoeff = power > st.rmsPower ? rmsAttackCoeffs[i] : rmsReleaseCoeffs[i]
        st.rmsPower = zapDenorm((rmsCoeff * st.rmsPower) + ((1.0 - rmsCoeff) * power))
        let rms = sqrtf(max(1e-12, st.rmsPower))
        let peakToRMS = linked / max(1e-4, rms)
        let rising = linked > st.env
        let transientDrive = rising && linked > 1e-5
            ? clampf((peakToRMS - 1.65) / 2.35, 0.0, 1.0)
            : 0.0
        if transientDrive > 0.15 {
            st.transientHoldCounter = transientHoldSamples
        } else if st.transientHoldCounter > 0 {
            st.transientHoldCounter -= 1
        }
        st.heldDrive = st.transientHoldCounter > 0
            ? max(st.heldDrive * transientHoldDecayCoeff, transientDrive)
            : transientDrive
        // At rest the level is the RMS alone (no instantaneous term, so no
        // 2f ripple on the bass band's level); while a front is being
        // caught the hold blends up to 58 % of |x| in.
        let peakWeight = 0.58 * st.heldDrive
        let hybrid = (rms * (1.0 - peakWeight)) + (linked * peakWeight)
        let envCoeff = hybrid > st.env ? envAttackCoeff : envReleaseCoeff
        st.env = zapDenorm((envCoeff * st.env) + ((1.0 - envCoeff) * hybrid))
        st.fallEnv = zapDenorm(max(st.env, st.fallEnv * fallEnvCoeff))
        // Decay guard: env more than 3 dB below its slow-release recent
        // peak means the program is actively fading (a note decaying, a
        // song ending) -- NOT "quiet program that needs lifting". Chasing
        // a natural decay with gain flattens/extends it, which the ear
        // reads as added ringing/sustain (found on a solo bell synth).
        let decaying = st.env < st.fallEnv * 0.71

        let levelDB = 20.0 * log10f(max(1e-6, st.env))
        // Coupling: heavy low-band reduction biases upper-band targets
        // down so bass-heavy passages keep tonal glue (graduated curve).
        let weight: Float
        switch i {
        case 1: weight = Self.couplingWeights.1
        case 2: weight = Self.couplingWeights.2
        case 3: weight = Self.couplingWeights.3
        case 4: weight = Self.couplingWeights.4
        default: weight = Self.couplingWeights.0
        }
        let couplingBias = -weight * couplingGRDB
        var desiredDB = clampf(
            (bandTargetsDB[i] + couplingBias) - levelDB, -maxCutDB, maxLiftDB)

        // Band sync: this band's gain must stay within the lift / cut
        // bounds of each (reference) neighbour's gain. Band i-1 already
        // carries this sample's gain and gate state, band i+1 the previous
        // sample's. The bound targets are smoothed (50 ms) before use so
        // neither the appearance of a bound nor a fast neighbour attack can
        // step this band's gain.
        st.active = levelDB >= gateThresholdDB
        let liftD = Self.bandSyncMaxLiftAboveNeighbourDB
        let cutD = Self.bandSyncMaxCutBelowNeighbourDB
        var boundLo = -maxCutDB
        var boundHi = maxLiftDB
        if i > 0 {
            let nb = bands[i - 1]
            if nb.active || Self.bandSyncGatedBandsAreReferences {
                boundLo = max(boundLo, nb.gainDB - cutD)
                boundHi = min(boundHi, nb.gainDB + liftD)
            }
        }
        if i < 4 {
            let nb = bands[i + 1]
            if nb.active || Self.bandSyncGatedBandsAreReferences {
                boundLo = max(boundLo, nb.gainDB - cutD)
                boundHi = min(boundHi, nb.gainDB + liftD)
            }
        }
        if boundLo > boundHi {
            // Neighbours more than 2D apart: sit between them.
            let mid = 0.5 * (boundLo + boundHi)
            boundLo = mid
            boundHi = mid
        }
        st.syncLoDB = (syncBoundCoeff * st.syncLoDB) + ((1.0 - syncBoundCoeff) * boundLo)
        st.syncHiDB = (syncBoundCoeff * st.syncHiDB) + ((1.0 - syncBoundCoeff) * boundHi)
        desiredDB = clampf(desiredDB, st.syncLoDB, st.syncHiDB)

        let errorDB = desiredDB - st.gainDB
        if levelDB < gateThresholdDB {
            // Do not lift silence / room noise: drift back to unity.
            st.gainDB *= gateDriftCoeff
        } else if fabsf(errorDB) <= holdWindowDB {
            // At target: come to a complete stop (gain untouched).
        } else if errorDB < 0.0 {
            // Reduce: transient drive + distance accelerate the base attack
            // toward the band's fast attack. The blend is in the TIME domain
            // (accel 0.5 = a quarter of the way from base to fast, in
            // seconds), and the fast attack is floored at two band periods,
            // so no band ever slews its gain inside one cycle. One expf per
            // reducing band per sample; the hold / lift / gate branches
            // (most of steady state) never pay it.
            let distanceAccel = clampf((-errorDB - holdWindowDB) / 12.0, 0.0, 1.0)
            let accel = max(st.heldDrive, distanceAccel)
            let tauS = lerpf(attackBaseS, attackFastS[i], accel * accel)
            let coeff = expf(-invSampleRate / tauS)
            st.gainDB = (coeff * st.gainDB) + ((1.0 - coeff) * desiredDB)
        } else if decaying {
            // Hold: let the fade decay naturally at whatever gain the
            // material was riding; lifting resumes when the envelope
            // stabilizes or new material arrives.
        } else {
            // Lift: base release, accelerated when the band sits far below
            // target, slowed by program density.
            let distanceAccel = clampf((errorDB - holdWindowDB) / 15.0, 0.0, 1.0)
            var rel = lerpf(releaseBaseCoeff, releaseFastCoeff, distanceAccel)
            // Density law (review finding 4). `density` is the fast/slow
            // envelope divergence: ~0 dB on dense, already-compressed
            // program, 4 dB and more on sparse, dynamic program. Dense
            // program already sits at its density and must be left alone,
            // so the release slows as the divergence falls (2.5x slower at
            // 0 dB); sparse program gets the full configured release so the
            // lift can follow it. The pre-fix law slowed WITH divergence --
            // the opposite of what the settings reference promises.
            let denseness = 1.0 - clampf(density / 4.0, 0.0, 1.0)
            rel = lerpf(rel, 1.0, denseness * 0.6)
            st.gainDB = (rel * st.gainDB) + ((1.0 - rel) * desiredDB)
        }
        st.gainDB = clampf(st.gainDB, -maxCutDB, maxLiftDB)
        // Safety clamp against the smoothed sync bound (continuous, since
        // the bound is).
        st.gainDB = clampf(st.gainDB, st.syncLoDB, st.syncHiDB)
        if i == 0 {
            // Smooth low-band reduction feeding the coupling bias.
            let reduction = max(0.0, -st.gainDB)
            let cCoeff = reduction > couplingGRDB
                ? couplingAttackCoeff : couplingReleaseCoeff
            couplingGRDB = zapDenorm(
                (cCoeff * couplingGRDB) + ((1.0 - cCoeff) * reduction))
        }
        bands[i] = st

        let gain = powf(10.0, st.gainDB / 20.0)
        // Per-band peak limiter before the sum: leveled band peaks are
        // tamed here, not left to the HF limiter / clippers.
        return limiters[i].process(left: bl * gain, right: br * gain)
    }
}
