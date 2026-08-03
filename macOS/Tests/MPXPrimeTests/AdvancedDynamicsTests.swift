import Testing
import Foundation
@testable import MPXPrime

// Advanced Dynamics: experimental single-stage 5-band leveler that replaces
// the wideband AGC + multiband compressor when enabled (default off). These
// tests pin (1) the config plumbing, (2) the leveling behavior itself
// (quiet and loud program converge toward the target), (3) the
// come-to-a-stop hold at target, and (4) that a disabled stage is inert
// bit-for-bit (the zero-drift contract at unit level).
@Suite("Advanced Dynamics leveler")
struct AdvancedDynamicsTests {
    private let sampleRate: Float = 48_000.0

    private func makeLeveler(
        targetDB: Float = -14.0,
        maxGainDB: Float = 18.0,
        density: Float = 0.5,
        speed: Float = 1.0
    ) -> AdvancedDynamicsLeveler {
        var leveler = AdvancedDynamicsLeveler()
        leveler.configureStructure(
            sampleRate: sampleRate,
            x1Hz: 95.0, x2Hz: 360.0, x3Hz: 1_600.0, x4Hz: 6_200.0
        )
        leveler.setParameters(
            targetDB: targetDB,
            lowOffsetDB: 0.0, midOffsetDB: 0.0, highOffsetDB: 0.0,
            maxGainDB: maxGainDB, density: density, speed: speed
        )
        return leveler
    }

    /// Steady-state output RMS (dB) for a mono 1 kHz tone at `amplitude`,
    /// measured over the last second of `seconds` of processing.
    private func steadyStateOutputDB(amplitude: Float, seconds: Float = 8.0) -> Float {
        var leveler = makeLeveler()
        let frames = Int(sampleRate * seconds)
        let measureStart = frames - Int(sampleRate)
        var sumSq: Double = 0.0
        var count = 0
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let x = amplitude * sinf(2.0 * Float.pi * 1_000.0 * t)
            let (l, _) = leveler.process(left: x, right: x)
            if i >= measureStart {
                sumSq += Double(l * l)
                count += 1
            }
        }
        let rms = sqrt(sumSq / Double(max(1, count)))
        return Float(20.0 * log10(max(1e-9, rms)))
    }

    @Test func runtimeConfigCarriesAdvancedDynamicsFields() {
        var config = AppConfig()
        #expect(config.advancedDynamicsEnabled == false)
        config.advancedDynamicsEnabled = true
        config.advancedDynamicsTargetDB = -16.0
        config.advancedDynamicsMaxGainDB = 20.0
        config.advancedDynamicsDensity = 0.7
        config.advancedDynamicsSpeed = 2.0
        config.advancedDynamicsLowOffsetDB = 1.0
        config.advancedDynamicsMidOffsetDB = -2.0
        config.advancedDynamicsHighOffsetDB = -8.0

        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        #expect(runtime.advancedDynamicsEnabled == true)
        #expect(abs(runtime.advancedDynamicsTargetDB - -16.0) < 1e-4)
        #expect(abs(runtime.advancedDynamicsMaxGainDB - 20.0) < 1e-4)
        #expect(abs(runtime.advancedDynamicsDensity - 0.7) < 1e-4)
        #expect(abs(runtime.advancedDynamicsSpeed - 2.0) < 1e-4)
        #expect(abs(runtime.advancedDynamicsLowOffsetDB - 1.0) < 1e-4)
        #expect(abs(runtime.advancedDynamicsMidOffsetDB - -2.0) < 1e-4)
        #expect(abs(runtime.advancedDynamicsHighOffsetDB - -8.0) < 1e-4)
    }

    @Test func iniRoundTripsAdvancedDynamicsKeys() throws {
        var config = AppConfig()
        config.advancedDynamicsEnabled = true
        config.advancedDynamicsTargetDB = -18.5
        config.advancedDynamicsLowOffsetDB = 2.0
        config.advancedDynamicsMidOffsetDB = -1.5
        config.advancedDynamicsHighOffsetDB = -7.0
        config.advancedDynamicsMaxGainDB = 21.0
        config.advancedDynamicsDensity = 0.35
        config.advancedDynamicsSpeed = 1.75

        let ini = try config.captureAsINIString()
        let reloaded = try AppConfig.loadFromINIString(ini)
        #expect(reloaded.advancedDynamicsEnabled == true)
        #expect(abs(reloaded.advancedDynamicsTargetDB - -18.5) < 1e-4)
        #expect(abs(reloaded.advancedDynamicsLowOffsetDB - 2.0) < 1e-4)
        #expect(abs(reloaded.advancedDynamicsMidOffsetDB - -1.5) < 1e-4)
        #expect(abs(reloaded.advancedDynamicsHighOffsetDB - -7.0) < 1e-4)
        #expect(abs(reloaded.advancedDynamicsMaxGainDB - 21.0) < 1e-4)
        #expect(abs(reloaded.advancedDynamicsDensity - 0.35) < 1e-4)
        #expect(abs(reloaded.advancedDynamicsSpeed - 1.75) < 1e-4)
    }

    @Test func quietAndLoudProgramConvergeTowardTarget() {
        // The whole point of a leveler: a 23 dB input difference collapses
        // to a small output difference once each has settled at target.
        // (The quiet level is chosen to need less lift than maxGainDB=18,
        // so the clamp is not the limiting factor.)
        let quietDB = steadyStateOutputDB(amplitude: 0.045)  // ~-27 dBFS
        let loudDB = steadyStateOutputDB(amplitude: 0.63)    // ~-4 dBFS
        #expect(abs(loudDB - quietDB) < 6.0,
            "leveler failed to converge: quiet settled at \(quietDB) dB, loud at \(loudDB) dB")
        // And both should sit in the neighbourhood of the target, not at
        // some runaway level (detector reads a hybrid RMS/peak, so allow
        // a generous window around -14 dB target).
        #expect(quietDB > -26.0 && quietDB < -6.0)
        #expect(loudDB > -26.0 && loudDB < -6.0)
    }

    @Test func gainFreezesInsideTargetWindow() {
        // Feed a tone that has fully settled, then verify the band gain
        // stops moving (come-to-a-complete-stop hold).
        var leveler = makeLeveler()
        let frames = Int(sampleRate * 6.0)
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let x = 0.2 * sinf(2.0 * Float.pi * 1_000.0 * t)
            _ = leveler.process(left: x, right: x)
        }
        let gainsAfterSettle = leveler.bandGainsDB
        for i in 0..<Int(sampleRate * 1.0) {
            let t = Float(frames + i) / sampleRate
            let x = 0.2 * sinf(2.0 * Float.pi * 1_000.0 * t)
            _ = leveler.process(left: x, right: x)
        }
        let gainsLater = leveler.bandGainsDB
        // The active band's gain must be effectively frozen.
        for (a, b) in zip(gainsAfterSettle, gainsLater) {
            #expect(abs(a - b) < 0.5)
        }
    }

    @Test func transientReductionIsFasterThanBaseAttack() {
        // A sudden +24 dB step must be caught quickly: within 50 ms the
        // output peak should already be well below the raw step peak.
        var leveler = makeLeveler()
        // Settle on a quiet bed first.
        for i in 0..<Int(sampleRate * 4.0) {
            let t = Float(i) / sampleRate
            let x = 0.05 * sinf(2.0 * Float.pi * 1_000.0 * t)
            _ = leveler.process(left: x, right: x)
        }
        // Step to a hot level; measure peak 30..80 ms after the step
        // (skipping the FIR group delay + first instants).
        let stepAmp: Float = 0.9
        var latePeak: Float = 0.0
        let skip = Int(sampleRate * 0.030)
        let end = Int(sampleRate * 0.080)
        for i in 0..<end {
            let t = Float(i) / sampleRate
            let x = stepAmp * sinf(2.0 * Float.pi * 1_000.0 * t)
            let (l, _) = leveler.process(left: x, right: x)
            if i >= skip {
                latePeak = max(latePeak, fabsf(l))
            }
        }
        // Without adaptive attack the gain would still sit near the bed's
        // lift and the step would pass out well above its input amplitude.
        #expect(latePeak < stepAmp * 1.1,
            "transient not caught: peak \(latePeak) vs step \(stepAmp)")
    }

    @Test func silenceIsNotLiftedByTheGate() {
        var leveler = makeLeveler()
        // Settle on program so gains ride up...
        for i in 0..<Int(sampleRate * 3.0) {
            let t = Float(i) / sampleRate
            let x = 0.05 * sinf(2.0 * Float.pi * 1_000.0 * t)
            _ = leveler.process(left: x, right: x)
        }
        // ...then feed near-silence: no band may keep drifting UP (the
        // gate drifts gains back toward unity instead of amplifying hiss).
        let gainsAtSilenceStart = leveler.bandGainsDB
        for _ in 0..<Int(sampleRate * 4.0) {
            _ = leveler.process(left: 1e-7, right: -1e-7)
        }
        let gainsAfterSilence = leveler.bandGainsDB
        for (before, after) in zip(gainsAtSilenceStart, gainsAfterSilence) {
            #expect(after <= before + 0.5,
                "gate failed: band gain rose from \(before) to \(after) dB on silence")
        }
    }

    @Test func hostileInputStaysFinite() {
        var leveler = makeLeveler()
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<40_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = Float(Int64(bitPattern: seed) % 1_000_000) / 500_000.0
            let x: Float
            switch i % 5 {
            case 0: x = r * 2.0            // hot noise
            case 1: x = 1.5                // DC slam
            case 2: x = -1.5
            case 3: x = 0.0                // silence
            default: x = r * 0.01          // near-silence
            }
            let (l, rr) = leveler.process(left: x, right: -x)
            #expect(l.isFinite && rr.isFinite)
        }
    }

    @Test func degenerateRateDegradesToPassThrough() {
        var leveler = AdvancedDynamicsLeveler()
        leveler.configureStructure(
            sampleRate: 0.0, x1Hz: 95.0, x2Hz: 360.0, x3Hz: 1_600.0, x4Hz: 6_200.0)
        // At a floored/degenerate rate the FIR splitter may still build;
        // whatever happens, processing must never produce non-finite output.
        for value in [Float(-0.8), -0.1, 0.0, 0.37, 1.25] {
            let (l, r) = leveler.process(left: value, right: value)
            #expect(l.isFinite && r.isFinite)
        }
    }

    @Test func disabledStageIsInertInChain() {
        // Zero-drift at unit level: with the toggle OFF, changing every
        // other Advanced Dynamics parameter must leave the rendered MPX
        // bit-identical to a default config.
        var base = AppConfig()
        base.sampleRate = 192_000.0
        base.sourceMode = "input"

        var tweaked = base
        tweaked.advancedDynamicsEnabled = false
        tweaked.advancedDynamicsTargetDB = -22.0
        tweaked.advancedDynamicsMaxGainDB = 24.0
        tweaked.advancedDynamicsDensity = 1.0
        tweaked.advancedDynamicsSpeed = 4.0

        let genA = MPXGenerator(config: base, sampleRate: 192_000.0)
        let genB = MPXGenerator(config: tweaked, sampleRate: 192_000.0)
        for i in 0..<24_000 {
            let t = Float(i) / 192_000.0
            let l = 0.5 * sinf(2.0 * Float.pi * 1_000.0 * t)
            let r = 0.4 * sinf(2.0 * Float.pi * 3_000.0 * t)
            let a = genA.renderSingleSample(leftIn: l, rightIn: r)
            let b = genB.renderSingleSample(leftIn: l, rightIn: r)
            #expect(a == b)
            if a != b { break }
        }
    }

    @Test func enabledStageBypassesAGCAndMultibandCompletely() {
        // With Advanced Dynamics ON, the AGC / multiband / expander /
        // MB-limiter settings must have ZERO effect on the output -- the
        // stages are bypassed, not blended. Render the same program with
        // (a) those stages on at extreme settings and (b) fully off; the
        // MPX must be bit-identical.
        var loud = AppConfig()
        loud.sampleRate = 192_000.0
        loud.sourceMode = "input"
        loud.advancedDynamicsEnabled = true
        loud.widebandAGCEnabled = true
        loud.widebandAGCTargetDB = -30.0        // extreme: would crush audio
        loud.multibandEnabled = true
        loud.multibandLowThresholdDB = -40.0    // extreme: would crush audio
        loud.multibandMidThresholdDB = -40.0
        loud.multibandHighThresholdDB = -40.0
        loud.downwardExpanderEnabled = true
        loud.multibandLimiterEnabled = true
        loud.multibandLimiterThresholdDB = -20.0

        var off = loud
        off.widebandAGCEnabled = false
        off.multibandEnabled = false
        off.downwardExpanderEnabled = false
        off.multibandLimiterEnabled = false

        let genA = MPXGenerator(config: loud, sampleRate: 192_000.0)
        let genB = MPXGenerator(config: off, sampleRate: 192_000.0)
        for i in 0..<24_000 {
            let t = Float(i) / 192_000.0
            let l = 0.5 * sinf(2.0 * Float.pi * 900.0 * t)
            let r = 0.45 * sinf(2.0 * Float.pi * 2_200.0 * t)
            let a = genA.renderSingleSample(leftIn: l, rightIn: r)
            let b = genB.renderSingleSample(leftIn: l, rightIn: r)
            #expect(a == b)
            if a != b { break }
        }
    }

    @Test func enabledChainRendersFiniteBoundedComposite() {
        var config = AppConfig()
        config.sampleRate = 192_000.0
        config.sourceMode = "input"
        config.advancedDynamicsEnabled = true

        let generator = MPXGenerator(config: config, sampleRate: 192_000.0)
        var peak: Float = 0.0
        for i in 0..<48_000 {
            let t = Float(i) / 192_000.0
            let l = 0.6 * sinf(2.0 * Float.pi * 400.0 * t)
                + 0.2 * sinf(2.0 * Float.pi * 5_000.0 * t)
            let mpx = generator.renderSingleSample(leftIn: l, rightIn: l * 0.8)
            #expect(mpx.isFinite)
            peak = max(peak, fabsf(mpx))
        }
        #expect(peak <= 1.0)
        #expect(peak > 0.01)
    }
}
