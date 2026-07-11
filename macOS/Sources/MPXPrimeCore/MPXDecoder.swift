#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Reusable FM MPX decoder for monitor audio and offline verification.
///
/// The monitor path can pass the internally generated, delay-aligned 38 kHz
/// reference for low latency and exact phase. Standalone analysis can omit the
/// reference and let the lightweight pilot-locked oscillator recover it from
/// the 19 kHz pilot.
///
/// Moved into MPXPrimeCore in the v0.31 modularization step so both the
/// transmit app (MPXPrime, monitor path) and the future MPXPrimeMeter
/// companion app can share one decoder. Body is unchanged from the prior
/// MPXPrime-internal version; only the type / init / configure / process
/// surface is now public.
public struct MPXDecoder {
    private static let pilotHz: Float = 19_000.0
    private static let rdsHz: Float = 57_000.0
    // process() is @inlinable so it can inline across the MPXPrimeCore module
    // boundary into the transmit app's per-sample monitor loop. Every stored
    // member it (or its inlinable callee) touches must therefore be
    // @usableFromInline; pilotHz/rdsHz stay private because only the
    // non-inlinable configure() reads them.
    @usableFromInline static let diffDecodeGain: Float = 1.0

    @usableFromInline var sampleRate: Float = 192_000.0
    @usableFromInline var preemphasisUS: Int = 50

    @usableFromInline var lprLP = BiquadCascade6()
    @usableFromInline var diffBandHP = BiquadCascade6()
    @usableFromInline var diffBandLP = BiquadCascade6()
    @usableFromInline var diffLP = BiquadCascade6()
    @usableFromInline var pilotNotchL = Biquad()
    @usableFromInline var pilotNotchR = Biquad()
    @usableFromInline var deemphasisL = DeemphasisFilter()
    @usableFromInline var deemphasisR = DeemphasisFilter()

    @usableFromInline var pllPhase: Float = 0.0
    @usableFromInline var pllStep: Float = 0.0
    @usableFromInline var pilotLockI: Float = 0.0
    @usableFromInline var pilotLockQ: Float = 0.0
    @usableFromInline var pilotLockCoeff: Float = 0.0

    @usableFromInline var noiseGateGain: Float = 0.0
    @usableFromInline var noiseGateOpen: Bool = false
    @usableFromInline var programEnv: Float = 0.0
    @usableFromInline var programNoiseFloor: Float = 0.0
    @usableFromInline var collapseHoldSamples: Int = 0
    @usableFromInline var collapseCooldownSamples: Int = 0

    @usableFromInline var programEnvAttackCoeff: Float = 0.0
    @usableFromInline var programEnvReleaseCoeff: Float = 0.0
    @usableFromInline var noiseFloorRiseCoeff: Float = 0.0
    @usableFromInline var noiseFloorFallCoeff: Float = 0.0
    @usableFromInline var noiseGateAttackCoeff: Float = 0.0
    @usableFromInline var noiseGateReleaseCoeff: Float = 0.0
    @usableFromInline var collapseHoldThresholdSamples: Int = 0
    @usableFromInline var collapseCooldownResetSamples: Int = 0

    public init() {}

    public mutating func configure(sampleRate: Float, preemphasisUS: Int) {
        let sr = max(8_000.0, sampleRate)
        self.sampleRate = sr
        self.preemphasisUS = preemphasisUS
        let nyquist = max(6_000.0, (sr * 0.5) - 200.0)

        lprLP.configureLowpass(cutoffHz: 15_500.0, sampleRate: sr)
        diffBandHP.configureIdentity()
        diffBandLP.configureIdentity()
        diffLP.configureLowpass(cutoffHz: 15_500.0, sampleRate: sr)

        // No pre-demod RF notch (see process()): pilot/RDS are handled by the
        // audio-band lowpasses + the post-recombination pilot notch. The
        // pilot notch on the decoded L/R removes residual 19 kHz that the
        // M-path 15.5 kHz lowpass leaves behind.
        if nyquist > (Self.pilotHz + 100.0) {
            pilotNotchL.configureNotch(freqHz: Self.pilotHz, sampleRate: sr, q: 24.0)
            pilotNotchR.configureNotch(freqHz: Self.pilotHz, sampleRate: sr, q: 24.0)
        } else {
            pilotNotchL.configureIdentity()
            pilotNotchR.configureIdentity()
        }

        deemphasisL.configure(tauUS: preemphasisUS, sampleRate: sr)
        deemphasisR.configure(tauUS: preemphasisUS, sampleRate: sr)

        pllPhase = 0.0
        pllStep = (Float.pi * 2.0 * Self.pilotHz) / sr
        pilotLockI = 0.0
        pilotLockQ = 0.0
        pilotLockCoeff = expf(-1.0 / (0.020 * sr))

        programEnvAttackCoeff = expf(-1.0 / (0.010 * sr))
        programEnvReleaseCoeff = expf(-1.0 / (0.180 * sr))
        noiseFloorRiseCoeff = expf(-1.0 / (3.0 * sr))
        noiseFloorFallCoeff = expf(-1.0 / (0.50 * sr))
        noiseGateAttackCoeff = expf(-1.0 / (0.006 * sr))
        noiseGateReleaseCoeff = expf(-1.0 / (0.140 * sr))
        collapseHoldThresholdSamples = max(1, Int((sr * 0.55).rounded()))
        collapseCooldownResetSamples = max(1, Int((sr * 2.0).rounded()))

        noiseGateGain = 0.0
        noiseGateOpen = false
        programEnv = 0.0
        programNoiseFloor = 0.0
        collapseHoldSamples = 0
        collapseCooldownSamples = 0
    }

    @inlinable
    @inline(__always)
    public mutating func process(
        _ mpxIn: Float,
        referenceSubcarrier: Float? = nil,
        programActivity programActivityIn: Float,
        expectedSide expectedSideIn: Float
    ) -> (Float, Float) {
        // Sanitize all float inputs up front. A single non-finite sample
        // would otherwise poison the persistent pilot-lock I/Q, envelope,
        // and noise-floor state permanently: NaN flows through the
        // exponential smoothers (which never flush it) and every recovery
        // comparison against NaN is false, so the stereo-collapse self-heal
        // can never re-arm. Substituting 0 keeps the decoder recoverable.
        let mpx = mpxIn.isFinite ? mpxIn : 0.0
        let programActivity = programActivityIn.isFinite ? programActivityIn : 0.0
        let expectedSide = expectedSideIn.isFinite ? expectedSideIn : 0.0
        let refSubcarrier: Float? = referenceSubcarrier.flatMap { $0.isFinite ? $0 : 0.0 }
        let subcarrier = refSubcarrier ?? pilotLockedSubcarrier(from: mpx)

        // No pre-demod pilot/RDS notch: it used to attenuate the 19 kHz pilot
        // and 57 kHz RDS before the M/S split, but its skirts clipped the
        // S-channel DSB-SC sidebands (38 +/- f) asymmetrically — worse as f
        // rose toward the notches — which was the dominant HF stereo-
        // separation limiter (14 kHz ~44 dB -> ~97 dB once removed). The
        // pilot/RDS are already handled downstream: the 15.5 kHz M-path
        // lowpass + S-path `diffLP` reject everything above the audio band,
        // and `pilotNotchL/R` cleans residual 19 kHz from the decoded L/R.
        let monSrc = mpx

        let lpr = lprLP.process(monSrc)
        var diff = 2.0 * monSrc * subcarrier
        diff = diffLP.process(diff)
        diff *= Self.diffDecodeGain
        diff = -diff

        var left = lpr + diff
        var right = lpr - diff

        left = pilotNotchL.process(left)
        right = pilotNotchR.process(right)
        left = deemphasisL.process(left)
        right = deemphasisR.process(right)

        let activity = max(0.0, programActivity)
        let envCoeff = activity > programEnv ? programEnvAttackCoeff : programEnvReleaseCoeff
        programEnv = zapDenorm((envCoeff * programEnv) + ((1.0 - envCoeff) * activity))

        let floorTarget = programEnv
        if !noiseGateOpen || floorTarget <= (programNoiseFloor * 1.4) {
            let floorCoeff = floorTarget > programNoiseFloor ? noiseFloorRiseCoeff : noiseFloorFallCoeff
            programNoiseFloor = zapDenorm((floorCoeff * programNoiseFloor) + ((1.0 - floorCoeff) * floorTarget))
        }

        let openThreshold = max(0.00016, programNoiseFloor * 2.3)
        let closeThreshold = max(0.00008, programNoiseFloor * 1.6)
        if noiseGateOpen {
            if programEnv < closeThreshold {
                noiseGateOpen = false
            }
        } else if programEnv > openThreshold {
            noiseGateOpen = true
        }
        let targetGain: Float = noiseGateOpen ? 1.0 : 0.0
        let gateCoeff = targetGain > noiseGateGain ? noiseGateAttackCoeff : noiseGateReleaseCoeff
        noiseGateGain = zapDenorm((gateCoeff * noiseGateGain) + ((1.0 - gateCoeff) * targetGain))
        left *= noiseGateGain
        right *= noiseGateGain

        if collapseCooldownSamples > 0 {
            collapseCooldownSamples -= 1
        }
        let outSideAbs = fabsf((left - right) * 0.5)
        let sidePresent = expectedSide > max(0.0012, programEnv * 0.08)
        let collapsed = outSideAbs < (expectedSide * 0.12)
        if sidePresent && collapsed {
            collapseHoldSamples += 1
            if collapseCooldownSamples <= 0, collapseHoldSamples > collapseHoldThresholdSamples {
                configure(sampleRate: sampleRate, preemphasisUS: preemphasisUS)
                collapseCooldownSamples = collapseCooldownResetSamples
                collapseHoldSamples = 0
            }
        } else {
            collapseHoldSamples = max(0, collapseHoldSamples - 1)
        }

        return (max(-1.0, min(1.0, left)), max(-1.0, min(1.0, right)))
    }

    @inlinable
    @inline(__always)
    mutating func pilotLockedSubcarrier(from mpx: Float) -> Float {
        let oscSin = sinf(pllPhase)
        let oscCos = cosf(pllPhase)
        pilotLockI = zapDenorm((pilotLockCoeff * pilotLockI) + ((1.0 - pilotLockCoeff) * (mpx * oscSin)))
        pilotLockQ = zapDenorm((pilotLockCoeff * pilotLockQ) + ((1.0 - pilotLockCoeff) * (mpx * oscCos)))

        let mag2 = (pilotLockI * pilotLockI) + (pilotLockQ * pilotLockQ)
        let subcarrier: Float
        if mag2 > 1e-4 {
            let invMag2 = 1.0 / mag2
            let cos2Phi = ((pilotLockI * pilotLockI) - (pilotLockQ * pilotLockQ)) * invMag2
            let sin2Phi = (2.0 * pilotLockI * pilotLockQ) * invMag2
            let sin2Theta = 2.0 * oscSin * oscCos
            let cos2Theta = (oscCos * oscCos) - (oscSin * oscSin)
            subcarrier = (sin2Theta * cos2Phi) + (cos2Theta * sin2Phi)
        } else {
            subcarrier = 0.0
        }

        pllPhase += pllStep
        if pllPhase >= (Float.pi * 2.0) {
            pllPhase -= Float.pi * 2.0
        } else if pllPhase < 0.0 {
            pllPhase += Float.pi * 2.0
        }
        return subcarrier
    }
}
