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
// Fast-attack, high-ratio peak limiter for per-band transient control.
// Operates after multiband compressor, before band summation.
//
// The detector follows a PEAK HOLD, not |x| itself (review 2026-10-15,
// finding 5). A one-pole follower of |x| droops between the half-cycle peaks
// of a low band (exp(-8.3 ms / 50 ms) = -1.4 dB on 60 Hz), so the gain
// rippled at 2f and wrote a third harmonic into the bass (-35 dB at 3 dB of
// reduction), and the follower never quite reached the peak, so the output
// sat 0.27 dB over the threshold. The hold is the maximum of |x| over the
// last one to two periods of the band's lowest frequency (two alternating
// blocks of one period each: O(1), no allocation), and the release is at
// least two such periods. On a steady tone the held peak is constant, the
// gain is constant and the output peak lands on the threshold; the 0.5 ms
// attack still smooths the onset of a new peak (it is not a look-ahead, so
// the first cycle of a step can pass up to the attack's lag over).
struct BandLimiter {
    private var thresholdLin: Float = 1.0
    private var attackCoeff: Float = 0.0
    private var releaseCoeff: Float = 0.0
    // Stereo-linked envelope: both channels are limited together based on the
    // max(|L|, |R|) peak, so a single envelope is sufficient.
    private var env: Float = 0.0
    /// Peak hold: maximum of the current block and the previous one.
    private var holdBlockSamples: Int = 1
    private var holdCount: Int = 0
    private var holdCurrent: Float = 0.0
    private var holdPrevious: Float = 0.0

    /// The lowest frequency a band limiter is assumed to carry when the
    /// caller does not say (one period = 20 ms of hold): low enough for any
    /// bass band, harmless on an upper band (the hold only delays release).
    static let defaultLowestFrequencyHz: Float = 50.0

    /// Peak-hold block length in samples (one period of the lowest frequency).
    var holdSamples: Int { holdBlockSamples }

    /// `lowestFrequencyHz` is the band's lower edge (60 Hz or so for the
    /// bass band): the hold spans one period of it and the release is at
    /// least two periods.
    mutating func configure(
        sampleRate: Float, thresholdDB: Float, attackMS: Float, releaseMS: Float,
        lowestFrequencyHz: Float = BandLimiter.defaultLowestFrequencyHz
    ) {
        thresholdLin = powf(10.0, min(0.0, thresholdDB) / 20.0)
        let sr = max(8_000.0, sampleRate)
        let periodS = 1.0 / clampf(lowestFrequencyHz, 20.0, 20_000.0)
        attackCoeff = expf(-1.0 / (max(0.01, attackMS) * 0.001 * sr))
        let releaseS = max(max(1.0, releaseMS) * 0.001, 2.0 * periodS)
        releaseCoeff = expf(-1.0 / (releaseS * sr))
        holdBlockSamples = max(1, Int((periodS * sr).rounded(.up)))
        holdCount = min(holdCount, holdBlockSamples)
    }

    @inline(__always)
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        let peak = max(fabsf(left), fabsf(right))
        holdCurrent = max(holdCurrent, peak)
        holdCount += 1
        let held = max(holdCurrent, holdPrevious)
        if holdCount >= holdBlockSamples {
            holdPrevious = holdCurrent
            holdCurrent = 0.0
            holdCount = 0
        }
        let coeff = held > env ? attackCoeff : releaseCoeff
        env = zapDenorm((coeff * env) + ((1.0 - coeff) * held))
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
        env = zapDenorm((coeff * env) + ((1.0 - coeff) * peak))
        if ratio > 1.0 && env < thresholdLin && env > 1e-10 {
            // Below threshold: a 1:r downward expander puts the output at
            // T + r (in - T), so its GAIN is (r - 1) times the distance below
            // the threshold. Until 2026-10-15 this was `belowDB * ratio`, an
            // effective 1:(r + 1): the documented 2:1 expanded 1:3 and ratio 1
            // still expanded 1:2 (review finding 3). Ratio 1 is now a no-op.
            // Floor the result at -60 dB so very quiet signals don't
            // underflow to a subnormal gain (which produced a hard
            // silent-vs-expanding discontinuity / tremolo just above the
            // 1e-10 detector floor).
            let belowDB = 20.0 * log10f(env / thresholdLin)
            let expandedDB = belowDB * (ratio - 1.0)
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

    /// Symmetric average of the instantaneous power (one time constant,
    /// `meanPowerSeconds`): the waveform-ripple-free power reading the
    /// asymmetric programme detector below works on.
    private var meanPower: Float = 0.0
    private var meanPowerCoeff: Float = 0.0
    /// Two periods of 60 Hz: the 2f ripple of a bass tone's instantaneous
    /// power is down to +/-0.2 dB after it.
    static let meanPowerSeconds: Float = 0.030
    private var power: Float = 0.0
    private var gainDB: Float = 0.0
    private var gateActive: Bool = false
    /// Inside the window the gain CREEPS to the target instead of
    /// freezing (review 2026-10-15, finding 4): `windowCreepFactor` x the
    /// configured release. See `process`.
    private var windowCreepCoeff: Float = 0.0
    static let windowCreepFactor: Double = 10.0
    /// Two envelope followers at different time constants. Their log-
    /// ratio is the "program density" signal: if fast and slow
    /// envelopes agree, program is flat; if they diverge (transients,
    /// syllables, rhythmic modulation) program is busy. More reliable
    /// than |delta levelDB| on a heavily-smoothed detector, which barely
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
        meanPowerCoeff = expf(-1.0 / (Self.meanPowerSeconds * sr))

        let attackS = max(0.010, Double(attackMS) * 0.001)
        let releaseS = max(0.250, Double(releaseMS) * 0.001)
        let fastMakeupS = max(0.120, min(releaseS * 0.35, 0.450))
        configuredReleaseS = releaseS
        windowCreepCoeff = expf(-1.0 / Float(releaseS * Self.windowCreepFactor * Double(sr)))
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
        // Sidechain feed -- audio path stays pristine, only the
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
        // Two stages (review 2026-10-15, finding 4). The instantaneous power
        // of a waveform swings 0..2x its mean twice per cycle, and an average
        // that rises faster than it falls settles ABOVE the mean by an amount
        // set by the waveform's power distribution: the old single
        // asymmetric stage read a sine +2.3 dB and Gaussian noise +4.7 dB
        // over their true power, so tonal programme came out 2.1 dB louder
        // than dense programme of the same power. The symmetric average first
        // removes the waveform; the asymmetric attack / release then acts on
        // the PROGRAMME envelope only, as intended.
        meanPower = zapDenorm((meanPowerCoeff * meanPower) + ((1.0 - meanPowerCoeff) * monoPower))
        let detectorCoeff = meanPower > power ? detectorAttackCoeff : detectorReleaseCoeff
        power = (detectorCoeff * power) + ((1.0 - detectorCoeff) * meanPower)
        power = zapDenorm(power)

        let levelDB = 10.0 * log10f(max(power, 1e-12))

        // Program-density estimate via fast-vs-slow envelope
        // divergence. Run raw power through two first-order smoothers
        // at ~50 ms and ~1 s; their log-ratio is how far the short-
        // term envelope is from the platform. Busy program (syllables,
        // transients, rhythmic modulation) makes |ratio_dB| large;
        // flat program keeps fast ~= slow -> ratio ~= 0 dB.
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
            // Inside the window the gain no longer FREEZES: it creeps to the
            // target at 10x the release time (12 s at the 1.2 s default),
            // the Optimod "window" behaviour (release slowed inside the
            // window, not stopped). A frozen window had no memory-free rest
            // point: a lift stopped 3 dB short and a cut 3 dB over, so the
            // same steady input could end anywhere in a 6 dB range depending
            // on what played before (measured -18.27 vs -12.27 dBFS). Short
            // excursions inside the window still move the gain by almost
            // nothing (0.25 dB per second at 3 dB of error).
            targetGainDB = desiredGainDB
            coeff = windowCreepCoeff
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
                let densityScale = 1.0 + densityClamped * 0.5   // 1x...3x
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
        meanPower = 0.0
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

/// The multiband compressor's stereo link as an AMOUNT (review 2026-10-15,
/// finding 6). Each channel's detector is blended from its own |x| toward
/// the linked level `sqrt((L^2 + R^2) / 2)`: 0 = each channel compressed on
/// its own, 1 = one shared detector (equal gain reduction on L and R, the
/// image held exactly). The control it replaces fed BOTH channels the same
/// sidechain at any value above 1e-4 (so L/R gain was always identical) and
/// used the value only to blend that sidechain between `(|L| + |R|) / 2`
/// and the RMS -- the two are equal on a centred source, so the slider did
/// nothing from 0.0001 to 1, and nothing was ever shared ACROSS bands, which
/// its tooltip promised. At 1 this is the old path's detector at 1 (the
/// linked RMS, to within float rounding).
enum MultibandStereoLink {
    @inline(__always)
    static func sidechains(absLeft: Float, absRight: Float, amount: Float) -> (left: Float, right: Float) {
        let linked = sqrtf(((absLeft * absLeft) + (absRight * absRight)) * 0.5)
        let a = clampf(amount, 0.0, 1.0)
        return (lerpf(absLeft, linked, a), lerpf(absRight, linked, a))
    }
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
