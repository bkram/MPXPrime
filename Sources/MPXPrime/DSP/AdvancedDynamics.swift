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

/// Single-stage "Advanced Dynamics" leveler (the default levelling since
/// 2026-10-15).
///
/// Replaces the wideband AGC + multiband compressor pair with ONE fused
/// 5-band leveling stage, so slow leveling and per-band density shaping can
/// never fight each other (the classic AGC-pulls-down-while-multiband-
/// pushes-up pumping). The gain law is `G_band = G_wideband + C_band`
/// (docs/ARCHITECTURE.md, "Advanced Dynamics single-stage leveler"):
///
///  - the loudness layer: ONE adaptive gain on the pre-emphasis-weighted
///    wideband level carries the levelling ballistics -- hold window with
///    hysteresis, distance acceleration toward a floor of two bass periods,
///    decay guard, density-slowed release, gate;
///  - the tone layer: each band adds a correction bounded to +3 / -3 dB
///    (-6 dB on the two top bands) for SHORT-TERM departures from its own
///    long-term share of the programme, cut fast (5 ms on the top bands, so
///    a sibilant or a cymbal is caught at once) and restored slowly, with
///    its long-term mean removed so a programme whose balance does not
///    change ends with zero mean correction; adjacent bands can never sit
///    more than `maxAdjacentBandDisparityDB` apart (this replaced the
///    2026-10-10 neighbour-to-neighbour band sync, removed with its dead
///    state on 2026-10-15);
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
        /// Above its gate on the last sample: carries programme, so its
        /// share is learnt and corrected.
        var active: Bool = false
        /// Spectral memory: this band's long-term level relative to the
        /// wideband level (dB). The band is corrected only for SHORT-TERM
        /// departures from it, so the programme keeps its own tonal balance.
        var shareDB: Float = 0.0
        var shareSeeded: Bool = false
        /// Seconds of active programme seen, capped at the fast-start span.
        var shareSeconds: Float = 0.0
        /// Wideband reading only: programme seconds since it left the gate.
        var acquireSeconds: Float = 0.0
        /// Applied correction (dB) on top of the wideband gain: `toneDB`
        /// plus the zero-mean spectral part (diagnostics).
        var correctionDB: Float = 0.0
        /// The user's tilt and the bass-excess coupling, smoothed.
        var toneDB: Float = 0.0
        /// The spectral correction, smoothed fast-cut / slow-restore.
        var spectralDB: Float = 0.0
        /// Long-term mean of `spectralDB` (the `shareDB` memory), removed
        /// from it so the applied spectral correction is zero-mean.
        var spectralMeanDB: Float = 0.0
        /// Hold-window hysteresis: true while the gain rests. Programme
        /// already inside the window is never touched; a gain that started
        /// moving keeps moving until it is inside HALF the window.
        var resting: Bool = true
    }
    private var bands = [BandState](repeating: BandState(), count: 5)
    /// Per-band peak limiters, run on each band's leveled output before the
    /// sum (review finding 1a). Fixed, conservative settings -- the
    /// multiband-limiter defaults (-3 dB, 0.5 / 50 ms); the generator's
    /// `multiband_limiter_*` keys belong to the classic path and must have
    /// no effect here (the stage-bypass contract is bit-exact).
    private var limiters = [BandLimiter](repeating: BandLimiter(), count: 5)
    /// Lower edge of each band (band 1: 60 Hz), for the limiters' hold.
    private var bandLowEdgesHz: [Float] = [60.0, 90.0, 350.0, 1_800.0, 6_800.0]
    static let bandLimiterThresholdDB: Float = -3.0
    static let bandLimiterAttackMS: Float = 0.5
    static let bandLimiterReleaseMS: Float = 50.0
    /// Per-band tonal tilt in dB, band 1..5, from the Bass / Mid / Treble
    /// balance controls: added to the band's gain relative to the wideband
    /// gain. 0 everywhere = the programme's own balance.
    private var bandOffsetsDB = [Float](repeating: 0.0, count: 5)
    /// The wideband level target (the loudness the stage rides to).
    private var widebandTargetDB: Float = -16.0

    /// Pre-emphasis weighting of the wideband LOUDNESS reading (detector
    /// only; the audio is not touched): first-order `1 + tau * fs * (1 - z^-1)`
    /// with a share (`detectorPreemphasisWeight`) of the chain's own
    /// pre-emphasis time constant, so the leveller sees treble partly the way
    /// the HF limiter and the composite clipper will after pre-emphasis.
    /// Unweighted, a treble-heavy programme was lifted fully to target and
    /// then clipped: 10 kHz stereo separation fell from 41 to 22 dB in
    /// `--verify-receiver`. 0 = flat (HD Output, pre-emphasis off).
    private var detectorPreemphasisK: Float = 0.0
    private var detectorTauS: Float = 0.0
    private var prevWideL: Float = 0.0
    private var prevWideR: Float = 0.0

    /// Sets the detector weighting from the chain's pre-emphasis in
    /// microseconds (0 = none). Cheap; safe on any live change.
    mutating func setDetectorPreemphasis(tauUS: Int) {
        detectorTauS = Float(max(0, tauUS)) * 1e-6 * Self.detectorPreemphasisWeight
        detectorPreemphasisK = detectorTauS * storedSampleRate
    }

    /// How much of the chain's pre-emphasis the loudness reading carries:
    /// the weighting is the pre-emphasis network with `weight x tau` (15 us
    /// on a 50 us chain): +0.1 dB at 1 kHz, +1.8 dB at 5 kHz, +4.5 dB at
    /// 10 kHz, about what the classic AGC's K-weighting shelf (+4 dB) gave
    /// treble. Full weighting (1.0) levelled bright programme far below the
    /// classic chain (bright_dense -7.8 dB, hf_edge_12k -7.8 dB against
    /// bounds of 5 and 2); none (0.0) cost 10 kHz separation (22 dB, classic
    /// chain 41 dB). Measured 2026-10-15 (`--verify`, `--verify-receiver`,
    /// 10 kHz separation PLL / coherent): 1.0 -> 62 / 96 dB, hf_edge 7.8;
    /// 0.5 -> 62 / 96, hf_edge 3.5; 0.4 -> 62 / 96, hf_edge 2.4; 0.3 -> 59 /
    /// 66, hf_edge 1.1; 0.2 -> 43 / 44; 0.0 -> 22 / 22.
    static let detectorPreemphasisWeight: Float = 0.3

    /// The wideband layer: detector + adaptive gain on the sum of the split
    /// bands (time-aligned with them, unlike the raw input, which leads by
    /// the splitter's delay).
    private var wideband = BandState()
    /// Spectral correction smoothing, per band: the cut is 50 ms on the two
    /// bass bands, 10 ms on the mid band and 5 ms on the two top bands (each
    /// at least two band periods); the restore is 500 ms everywhere (all
    /// scaled by `speed`). The top bands must catch a sibilant or a cymbal
    /// burst within its first few milliseconds, as the classic multiband's
    /// 13 ms top band did: at 50 ms they reached the composite clipper raw and
    /// the energy above 60 kHz rose 8 dB on sibilant programme.
    private var correctionAttackCoeffs = [Float](repeating: 0.0, count: 5)
    private var correctionReleaseCoeff: Float = 0.0
    private static let correctionAttackS: [Float] = [0.050, 0.050, 0.010, 0.005, 0.005]
    private var wbRMSAttackCoeff: Float = 0.0
    private var wbRMSReleaseCoeff: Float = 0.0

    /// Spectral memory time constants: 0.5 s for the first 2 s of a band's
    /// programme (so a fresh stage does not tilt while it learns), then 8 s.
    private var shareFastCoeff: Float = 0.0
    private var shareSlowCoeff: Float = 0.0
    static let shareFastStartSeconds: Float = 2.0
    /// The share follows the band's level exactly for this long after the
    /// band first carries programme (envelope rise time, 5 ms attack x 10).
    static let shareSeedSeconds: Float = 0.050
    /// How strongly a short-term departure from the band's long-term share
    /// is corrected (0 = never, 1 = fully), from `density`.
    private var spectralCorrection: Float = 0.55
    /// Bounds on the spectral correction: a band may be lifted at most
    /// `spectralLiftMaxDB` and cut at most `spectralCutMaxDB` relative to
    /// the wideband gain (before the user's tilt). This is what keeps the
    /// tone: the pre-2026-10-15 law levelled every band to an ABSOLUTE
    /// target and re-equalised all programme toward one spectrum (+10 dB on
    /// a single band, and on dense bass a 5.5 dB bass cut against 4 dB of
    /// top lift that dropped L/R correlation from 0.90 to 0.74).
    static let spectralLiftMaxDB: Float = 3.0
    static let spectralCutMaxDB: Float = 3.0
    /// The two top bands may cut deeper: a short HF burst (sibilance,
    /// cymbals) is de-essed here instead of being clipped downstream.
    static let spectralCutMaxTopDB: Float = 6.0

    // Detector coefficients (fixed; the adaptivity lives in the gain
    // smoother). The RMS window is band-scaled: at least two band periods
    // (review finding 5), so the bass band's level has no 2f ripple to
    // modulate its gain with; the envelope follower keeps 5 / 60 ms.
    private var rmsAttackCoeffs = [Float](repeating: 0.0, count: 5)
    private var rmsReleaseCoeffs = [Float](repeating: 0.0, count: 5)
    private var envAttackCoeff: Float = 0.0
    private var envReleaseCoeff: Float = 0.0
    /// The wideband loudness reading's second smoother: ONE time constant
    /// both ways (review 2026-10-15). The 5 / 60 ms attack / release pair it
    /// replaced settled near the PEAKS of a rhythmic programme envelope (the
    /// same asymmetric-averaging bias as finding 4, one level up): a kick
    /// train left the stage 2.3 dB under its target and the verifier's
    /// bass_kick 5.3 dB under (its level bound in `--verify`, and most of
    /// bass_dense's drift in `--verify-advanced-dynamics`). The asymmetry
    /// belongs in the gain smoother (30 ms attack,
    /// 0.4-1.2 s release), as in the wideband AGC. 100 ms measured best:
    /// at 200 ms transient programme was lifted into the limiters
    /// (transient_push +3.3 dB > 3.0, limiter +1.6 dB); at 50-70 ms the
    /// reading rippled with each kick and the gain rode it (bass_kick 2.2-
    /// 3.3 dB under target); at 100 ms kick train / bass_kick / bass_dense
    /// land -0.2 / -0.9 / +0.1 dB from target (hold window 1.9 dB).
    private var wbEnvCoeff: Float = 0.0
    static let widebandEnvelopeSeconds: Float = 0.100
    /// For this long after the reading leaves the gate (programme starting
    /// from silence, a fresh stage) a RISE still uses the 5 ms attack: there
    /// is no level history to bias, and a symmetric 100 ms acquisition let
    /// the first few hundred ms through at the wrong gain (the preset
    /// sweep's 1 s renders read transient_push 3.8 dB > 3.0 and
    /// vocal_sibilant 3.0 dB > 2.5; with acquisition 2.3 and 2.0 in
    /// `--verify`, presets inside their bounds).
    static let widebandAcquireSeconds: Float = 0.250
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
    /// Inside the hold window the wideband gain CREEPS to the target at
    /// `windowCreepFactor` x the base release instead of stopping (the
    /// `WidebandAGCRider` fix, review 2026-10-15 finding 4, applied here).
    private var windowCreepCoeff: Float = 0.0
    static let windowCreepFactor: Float = 10.0

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

    /// The largest gain difference two adjacent bands can reach (tilt
    /// aside): one lifted by the full lift bound, the other cut by the full
    /// top-band cut bound, plus the largest step in the coupling curve on the
    /// deepest bass excess. Replaces the 2026-10-10 band-sync bound.
    static var maxAdjacentBandDisparityDB: Float {
        spectralLiftMaxDB + spectralCutMaxTopDB + (0.10 * spectralCutMaxDB)
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
        wbEnvCoeff = expf(-1.0 / (Self.widebandEnvelopeSeconds * sr))
        // Wideband RMS: ONE 50 ms time constant both ways (at least two
        // periods of 60 Hz). Instantaneous power swings 0..peak twice per
        // cycle, and an average that rises faster than it falls settles
        // ABOVE the mean: the 33 / 90 ms pair read a steady multitone 1.8 dB
        // hot, so the stage under-levelled it and pulled its own output down
        // again on a second pass. The envelope after it is symmetric too
        // (`widebandEnvelopeSeconds`): an asymmetric one biases the reading
        // toward the peaks of a rhythmic programme envelope.
        let wbRMSCoeff = expf(-1.0 / (max(0.050, attackFloorS[0]) * sr))
        wbRMSAttackCoeff = wbRMSCoeff
        wbRMSReleaseCoeff = wbRMSCoeff
        shareFastCoeff = expf(-1.0 / (0.5 * sr))
        shareSlowCoeff = expf(-1.0 / (8.0 * sr))
        transientHoldSamples = max(1, Int((sr * 0.010).rounded()))
        transientHoldDecayCoeff = powf(0.94, 48_000.0 / sr)
        fastEnvCoeff = expf(-1.0 / (0.050 * sr))
        slowEnvCoeff = expf(-1.0 / (1.000 * sr))
        densityCoeff = expf(-1.0 / (0.500 * sr))
        couplingAttackCoeff = expf(-1.0 / (0.020 * sr))
        couplingReleaseCoeff = expf(-1.0 / (0.300 * sr))
        fallEnvCoeff = expf(-1.0 / (1.0 * sr))
        gateDriftCoeff = expf(-1.0 / (1.6 * sr))
        invSampleRate = 1.0 / sr
        detectorPreemphasisK = detectorTauS * sr
        bandLowEdgesHz = edges
        if structureChanged {
            // Coefficients and hold length only; limiter envelopes are kept.
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
                releaseMS: Self.bandLimiterReleaseMS,
                lowestFrequencyHz: bandLowEdgesHz[i]
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
    private var storedMidOffsetDB: Float = 0.0
    private var storedHighOffsetDB: Float = 0.0
    private var storedMaxGainDB: Float = 12.0
    private var storedDensity: Float = 0.5
    private var storedSpeed: Float = 1.0

    /// Parameters: cheap (no allocation) -- safe on any live change.
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
        widebandTargetDB = targetDB
        bandOffsetsDB[0] = o1
        bandOffsetsDB[1] = lerpf(o1, o3, 0.5)
        bandOffsetsDB[2] = o3
        bandOffsetsDB[3] = lerpf(o3, o5, 0.5)
        bandOffsetsDB[4] = o5
        // Denser setting = closer spectral control.
        spectralCorrection = lerpf(0.3, 0.8, storedDensity)

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
        windowCreepCoeff = expf(
            -1.0 / (Float(Double(releaseBaseS) * speedScale) * Self.windowCreepFactor * sr))
        for i in 0..<5 {
            let attackS = max(Self.correctionAttackS[i], attackFloorS[i]) * Float(speedScale)
            correctionAttackCoeffs[i] = expf(-1.0 / (attackS * sr))
        }
        correctionReleaseCoeff = expf(-1.0 / (Float(0.500 * speedScale) * sr))
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
        wideband = BandState()
        prevWideL = 0.0
        prevWideR = 0.0
    }

    /// The wideband layer's last level reading and gain (dB), and whether
    /// it is resting in its hold window (diagnostics / tests / verify).
    private(set) var lastWidebandLevelDB: Float = -120.0
    var widebandGainDB: Float { wideband.gainDB }
    var widebandResting: Bool { wideband.resting }

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
        // hits, pauses) drives them apart. The release law slows as the
        // divergence falls ("stop when already dense").
        let monoPower = max(1e-12, 0.5 * ((inL * inL) + (inR * inR)))
        fastEnv = zapDenorm((fastEnvCoeff * fastEnv) + ((1.0 - fastEnvCoeff) * monoPower))
        slowEnv = zapDenorm((slowEnvCoeff * slowEnv) + ((1.0 - slowEnvCoeff) * monoPower))
        let envRatio = max(fastEnv, slowEnv) / max(1e-12, min(fastEnv, slowEnv))
        let instantDensity = 10.0 * log10f(max(1.0, envRatio))
        density = (densityCoeff * density) + ((1.0 - densityCoeff) * instantDensity)

        // Layer 1, the loudness: ONE adaptive gain on the wideband level,
        // measured on the sum of the split bands so it is time-aligned with
        // them (the raw input leads by the splitter's delay). It carries the
        // loudness ballistics: hold window, decay guard, density, gate, and
        // a reduce time constant that transient drive and distance shorten
        // from the base attack toward the bass band's floor (two periods of
        // 60 Hz, 33 ms: one gain on every band must not slew inside a bass
        // cycle). At speed 0.9 and up the base attack (30 ms / speed) is
        // already at or under that floor, so the acceleration has nothing
        // left to shorten -- by design, not a fault (review 2026-10-15,
        // finding 8). It would buy little anyway: the catch is bounded by the
        // 50 ms waveform-independent RMS reading, not by the smoother -- a
        // +20 dB step reached half its gain change in 46.9 ms at speed 1 and
        // still 42.5 ms with the floor cut to a quarter (and bass-band slew
        // up from 0.31 to 0.36 dB/ms). Fast PEAKS are the tone layer's job
        // (5 ms cut on the top bands) and the band limiters'.
        let wbL = split.0.0 + split.1.0 + split.2.0 + split.3.0 + split.4.0
        let wbR = split.0.1 + split.1.1 + split.2.1 + split.3.1 + split.4.1
        let k = detectorPreemphasisK
        let weightedL = wbL + (k * (wbL - prevWideL))
        let weightedR = wbR + (k * (wbR - prevWideR))
        prevWideL = wbL
        prevWideR = wbR
        let wbLinked = sqrtf(((weightedL * weightedL) + (weightedR * weightedR)) * 0.5)
        var wbState = wideband
        let wbLevelDB = ride(
            &wbState, linked: wbLinked,
            rmsAttack: wbRMSAttackCoeff, rmsRelease: wbRMSReleaseCoeff,
            attackFastS: attackFastS[0], targetDB: widebandTargetDB)
        wideband = wbState
        lastWidebandLevelDB = wbLevelDB
        let wbActive = wbLevelDB >= gateThresholdDB

        // Layer 2, the tone: each band = wideband gain + a slow, bounded
        // correction (`levelBand`). Bands are L/R-linked, so with
        // corrections bounded the stereo image and the spectral balance
        // move only within those bounds.
        let o1 = levelBand(index: 0, bl: split.0.0, br: split.0.1, wbLevelDB: wbLevelDB, wbActive: wbActive)
        let o2 = levelBand(index: 1, bl: split.1.0, br: split.1.1, wbLevelDB: wbLevelDB, wbActive: wbActive)
        let o3 = levelBand(index: 2, bl: split.2.0, br: split.2.1, wbLevelDB: wbLevelDB, wbActive: wbActive)
        let o4 = levelBand(index: 3, bl: split.3.0, br: split.3.1, wbLevelDB: wbLevelDB, wbActive: wbActive)
        let o5 = levelBand(index: 4, bl: split.4.0, br: split.4.1, wbLevelDB: wbLevelDB, wbActive: wbActive)
        return (
            o1.0 + o2.0 + o3.0 + o4.0 + o5.0,
            o1.1 + o2.1 + o3.1 + o4.1 + o5.1
        )
    }

    /// Graduated coupling bias per band (the multiband 5-band curve): a
    /// bass EXCESS (band 1 corrected below the wideband gain) lowers the
    /// upper bands' corrections by this share of it, for tonal glue.
    private static let couplingWeights: (Float, Float, Float, Float, Float)
        = (0.0, 0.10, 0.15, 0.22, 0.25)

    /// Detector: band-scaled RMS window blended with |x| while a front is
    /// caught (MonoCompressor hybrid pattern), into a 5 / 60 ms envelope.
    /// Returns the level in dB and updates the transient hold.
    @inline(__always)
    private mutating func detect(
        _ st: inout BandState, linked: Float, rmsAttack: Float, rmsRelease: Float,
        blendPeaks: Bool = true
    ) -> Float {
        let power = linked * linked
        let rmsCoeff = power > st.rmsPower ? rmsAttack : rmsRelease
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
        // At rest the level is the RMS alone (no 2f ripple on bass); while
        // a front is being caught the hold blends up to 58 % of |x| in. The
        // wideband LOUDNESS reading never blends: a dense mix or a steady
        // multitone has a crest factor near 2.4, which the transient test
        // (peak / RMS > 1.65) reads as a permanent front, so the blend
        // overstated its level by about 2.5 dB and every pass through the
        // stage pulled it down again. There the transient drive only speeds
        // the attack.
        let peakWeight = blendPeaks ? 0.58 * st.heldDrive : 0.0
        let hybrid = (rms * (1.0 - peakWeight)) + (linked * peakWeight)
        // The wideband loudness reading (`blendPeaks == false`) is smoothed
        // SYMMETRICALLY once it has acquired the programme; the bands keep
        // the fast-attack 5 / 60 ms envelope.
        let envCoeff: Float
        if blendPeaks || (st.acquireSeconds < Self.widebandAcquireSeconds && hybrid > st.env) {
            envCoeff = hybrid > st.env ? envAttackCoeff : envReleaseCoeff
        } else {
            envCoeff = wbEnvCoeff
        }
        st.env = zapDenorm((envCoeff * st.env) + ((1.0 - envCoeff) * hybrid))
        st.fallEnv = zapDenorm(max(st.env, st.fallEnv * fallEnvCoeff))
        return 20.0 * log10f(max(1e-6, st.env))
    }

    /// The adaptive gain law on one detector (the wideband layer): returns
    /// the level in dB and moves `st.gainDB` toward `targetDB - level`.
    @inline(__always)
    private mutating func ride(
        _ st: inout BandState, linked: Float, rmsAttack: Float, rmsRelease: Float,
        attackFastS fastS: Float, targetDB: Float
    ) -> Float {
        let levelDB = detect(
            &st, linked: linked, rmsAttack: rmsAttack, rmsRelease: rmsRelease, blendPeaks: false)
        // Acquisition clock: programme time since the reading last sat
        // below the gate (silence, or a fresh stage).
        if levelDB < gateThresholdDB {
            st.acquireSeconds = 0.0
        } else if st.acquireSeconds < Self.widebandAcquireSeconds {
            st.acquireSeconds += invSampleRate
        }
        // Decay guard: env more than 3 dB below its slow-release recent
        // peak means the program is actively fading (a note decaying, a
        // song ending) -- NOT "quiet program that needs lifting".
        let decaying = st.env < st.fallEnv * 0.71
        let desiredDB = clampf(targetDB - levelDB, -maxCutDB, maxLiftDB)
        let errorDB = desiredDB - st.gainDB
        if levelDB < gateThresholdDB {
            // Do not lift silence / room noise: drift back to unity.
            st.gainDB *= gateDriftCoeff
        } else if fabsf(errorDB) <= (st.resting ? holdWindowDB : 0.5 * holdWindowDB) {
            // At target: the gain no longer stops dead, it CREEPS to the
            // target at 10x the base release (12 s at density 0 and speed
            // 1, 4 s at density 1). A gain that stopped wherever it entered
            // the window had no memory-free rest point: the same steady
            // programme settled up to half a window above or below target
            // depending on whether the stage had come down from louder or up
            // from quieter programme. Short excursions inside the window
            // still move the gain by little (1 dB of error moves it 0.08 to
            // 0.25 dB per second at speed 1). The hysteresis stays: a gain that started
            // moving keeps its normal ballistics until it is inside half the
            // window.
            st.resting = true
            st.gainDB = (windowCreepCoeff * st.gainDB) + ((1.0 - windowCreepCoeff) * desiredDB)
        } else if errorDB < 0.0 {
            st.resting = false
            // Reduce: transient drive + distance accelerate the base attack
            // toward the fast attack, blended in the TIME domain; the fast
            // attack is floored at two periods of the lowest band, so the
            // gain never slews inside one bass cycle.
            let distanceAccel = clampf((-errorDB - holdWindowDB) / 12.0, 0.0, 1.0)
            let accel = max(st.heldDrive, distanceAccel)
            let tauS = lerpf(attackBaseS, fastS, accel * accel)
            let coeff = expf(-invSampleRate / tauS)
            st.gainDB = (coeff * st.gainDB) + ((1.0 - coeff) * desiredDB)
        } else if decaying {
            // Hold: let the fade decay naturally.
        } else {
            st.resting = false
            // Lift: base release, accelerated far below target, slowed on
            // dense program (review finding 4: dense program releases up to
            // 2.5x slower, sparse at the configured speed).
            let rel = liftCoefficient(errorDB: errorDB, densityDB: density)
            st.gainDB = (rel * st.gainDB) + ((1.0 - rel) * desiredDB)
        }
        st.gainDB = clampf(st.gainDB, -maxCutDB, maxLiftDB)
        return levelDB
    }

    /// The lift (release) smoothing coefficient: base release, accelerated
    /// when the gain sits far below target, slowed on dense programme.
    /// `densityDB` is the fast / slow envelope divergence: ~0 dB on dense,
    /// already-compressed programme, which must be left alone (up to 2.5x
    /// slower), 4 dB and more on sparse programme (full configured speed).
    @inline(__always)
    func liftCoefficient(errorDB: Float, densityDB: Float) -> Float {
        let distanceAccel = clampf((errorDB - holdWindowDB) / 15.0, 0.0, 1.0)
        let rel = lerpf(releaseBaseCoeff, releaseFastCoeff, distanceAccel)
        let denseness = 1.0 - clampf(densityDB / 4.0, 0.0, 1.0)
        return lerpf(rel, 1.0, denseness * 0.6)
    }

    @inline(__always)
    private mutating func levelBand(
        index i: Int, bl: Float, br: Float, wbLevelDB: Float, wbActive: Bool
    ) -> (Float, Float) {
        // Linked sidechain: one gain per band keeps the image exact in it.
        let linked = sqrtf(((bl * bl) + (br * br)) * 0.5)
        var st = bands[i]
        let levelDB = detect(&st, linked: linked, rmsAttack: rmsAttackCoeffs[i], rmsRelease: rmsReleaseCoeffs[i])
        st.active = levelDB >= gateThresholdDB

        // Spectral memory: the band's long-term share of the programme.
        let shareNowDB = levelDB - wbLevelDB
        let learning = st.active && wbActive
        var shareCoeff = shareSlowCoeff
        if learning {
            let fastStart = st.shareSeconds < Self.shareFastStartSeconds
            if fastStart { st.shareSeconds += invSampleRate }
            shareCoeff = fastStart ? shareFastCoeff : shareSlowCoeff
            if !st.shareSeeded || st.shareSeconds < Self.shareSeedSeconds {
                // Seed over the band's first `shareSeedSeconds` of programme,
                // not on its first sample: a band entering from its gate
                // reads a share far below its real one while its envelope
                // rises (a bell entering an empty top band seeded ~20 dB low
                // and was cut 5 dB on its strike as a bogus departure).
                st.shareDB = shareNowDB
                st.shareSeeded = true
            } else {
                st.shareDB = (shareCoeff * st.shareDB) + ((1.0 - shareCoeff) * shareNowDB)
            }
        }

        // Spectral correction: pull a short-term departure from the band's
        // usual share back by `spectralCorrection`, within the bounds. A
        // band with no programme (or a gated programme) carries no spectral
        // information and returns to zero.
        let cutMax = i >= 3 ? Self.spectralCutMaxTopDB : Self.spectralCutMaxDB
        let spectralTargetDB = learning
            ? clampf(spectralCorrection * (st.shareDB - shareNowDB), -cutMax, Self.spectralLiftMaxDB)
            : 0.0
        // Decay guard on the tone layer too: a band whose envelope is
        // actively fading (a bell, a note ending) is not lifted back toward
        // its usual share -- that would extend the fade, which the ear hears
        // as added ringing. Cutting is always allowed.
        let bandDecaying = st.env < st.fallEnv * 0.71
        if !(bandDecaying && spectralTargetDB > st.spectralDB) {
            let cCoeff = spectralTargetDB < st.spectralDB
                ? correctionAttackCoeffs[i] : correctionReleaseCoeff
            st.spectralDB = zapDenorm((cCoeff * st.spectralDB) + ((1.0 - cCoeff) * spectralTargetDB))
        }
        // Zero mean by construction (review 2026-10-15, finding 2). The cut
        // is 10 to 100 times faster than the restore (so a sibilant or a
        // cymbal is caught within its first milliseconds), and smoothing a
        // target that fluctuates around zero that asymmetrically settles
        // BELOW zero: a kick train held every band about 1.5 dB down and hat
        // bursts gave band 5 a static -1.4 dB cut. The smoothed correction's
        // own long-term mean (the same memory as `shareDB`) is subtracted, so
        // a programme whose long-term share is unchanged ends with zero mean
        // correction, while a burst that departs from it is still cut at the
        // full fast rate: an 8 s mean barely moves in a burst's few ms.
        if learning {
            st.spectralMeanDB = zapDenorm((shareCoeff * st.spectralMeanDB) + ((1.0 - shareCoeff) * st.spectralDB))
        } else if !(bandDecaying && st.spectralDB < st.spectralMeanDB) {
            // Gated: the band carries no spectral information and both parts
            // return to zero together -- but not as a lift while the band is
            // fading (the decay guard again: a mean falling onto the cut
            // spectral part lifts the band through its own decay).
            st.spectralMeanDB = zapDenorm(
                (correctionReleaseCoeff * st.spectralMeanDB) + ((1.0 - correctionReleaseCoeff) * st.spectralDB))
        }
        let spectralAppliedDB = clampf(st.spectralDB - st.spectralMeanDB, -cutMax, Self.spectralLiftMaxDB)

        // Tone: the user's tilt and the bass-excess coupling (deliberate
        // offsets, not zero-mean), smoothed fast-cut / slow-restore.
        let weight: Float
        switch i {
        case 1: weight = Self.couplingWeights.1
        case 2: weight = Self.couplingWeights.2
        case 3: weight = Self.couplingWeights.3
        case 4: weight = Self.couplingWeights.4
        default: weight = Self.couplingWeights.0
        }
        let toneTargetDB = bandOffsetsDB[i] - (learning ? weight * couplingGRDB : 0.0)
        let tCoeff = toneTargetDB < st.toneDB ? correctionAttackCoeffs[i] : correctionReleaseCoeff
        st.toneDB = zapDenorm((tCoeff * st.toneDB) + ((1.0 - tCoeff) * toneTargetDB))

        st.correctionDB = st.toneDB + spectralAppliedDB
        st.gainDB = clampf(wideband.gainDB + st.correctionDB, -maxCutDB, maxLiftDB)
        if i == 0 {
            // The bass band's spectral cut (its excess) feeds the coupling;
            // the user's own bass tilt does not count.
            let excess = max(0.0, -spectralAppliedDB)
            let couplingCoeff = excess > couplingGRDB ? couplingAttackCoeff : couplingReleaseCoeff
            couplingGRDB = zapDenorm((couplingCoeff * couplingGRDB) + ((1.0 - couplingCoeff) * excess))
        }
        bands[i] = st

        let gain = powf(10.0, st.gainDB / 20.0)
        // Per-band peak limiter before the sum: leveled band peaks are
        // tamed here, not left to the HF limiter / clippers.
        return limiters[i].process(left: bl * gain, right: br * gain)
    }
}
