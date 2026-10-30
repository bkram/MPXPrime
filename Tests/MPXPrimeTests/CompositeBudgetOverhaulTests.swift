import Foundation
import Testing

@testable import MPXPrime

// 2026-10 composite budget overhaul (gain-structure audit C2 / C5 / C7).
//
// Until then two static reserves stacked on the audio-composite budget:
// `limit_threshold` 0.98 (the final limiter's absolute threshold before 0.45,
// surviving only as a bite out of the budget once the limiter was normalised
// onto it) and a 0.02 safety margin -- 3 kHz of headroom that capped the
// multiplex at 72 kHz with the pilot and RDS at their defaults, 69-70.6 kHz
// as measured. The threshold default is now 1.0 (legal: the clamps stop at
// 1.0, not 0.999) and the margin 0.005, so the budget with pilot 8 % + RDS
// 2 kHz is 1.0 - 0.1067 - 0.005 = 0.8883 and the worst-case multiplex 0.995.
// The design is unchanged: the composite clipper, the final limiter, the
// shaper and the governor stay normalised onto the budget; nothing reads a
// threshold against full scale again.
@Suite struct CompositeBudgetOverhaulTests {

    private static let sampleRate: Double = 192_000.0
    /// `limit_threshold` default.
    private static let threshold: Float = 1.0
    /// Pilot 8 % + RDS 2 kHz of 75, the shipped defaults.
    private static let reserved: Float = 0.08 + 2.0 / 75.0
    private static var expectedBudget: Float {
        threshold - reserved - MPXGenerator.finalCompositeBudgetSafetyMargin
    }

    // MARK: - Budget formula

    @Test func shippedConstantsAreTheOverhauledOnes() {
        #expect(AppConfig().limitThreshold == 1.0)
        #expect(MPXGenerator.finalCompositeBudgetSafetyMargin == 0.005)
        #expect(MPXGenerator.softClipSafetyKneeStart == 0.995)
        // 1.0 is legal on the way in: `validate()` must not pull it back
        // to 0.999 (that would be a 0.009 dB bite nobody asked for).
        var cfg = AppConfig()
        cfg.limitThreshold = 1.0
        cfg.validate()
        #expect(cfg.limitThreshold == 1.0)
        #expect(abs(Self.expectedBudget - 0.8883) < 5e-4,
                "budget with pilot 8 % + RDS 2 kHz is \(Self.expectedBudget), expected 0.8883")
    }

    /// The UI-side derivation of the audio ceiling (from `limit_threshold`,
    /// the deviation share, the output gain and the metered margin) returns
    /// the engine's budget at the operating point.
    @Test func derivedAudioCeilingMatchesTheBudgetFormula() {
        let audioPeak = Self.expectedBudget
        let marginDB = -20.0 * log10f(audioPeak + Self.reserved)
        let ceiling = CompositeBudgetState.audioCeiling(
            limitThreshold: 1.0, deviationKHz: 75.0, outputGainDB: 0.0,
            budgetMarginDB: marginDB, audioPeak: audioPeak)
        #expect(abs(ceiling - Self.expectedBudget) < 1e-4,
                "derived ceiling \(ceiling) vs budget \(Self.expectedBudget)")
        // The deviation share scales the budget (a 50 kHz station's audio
        // ceiling is 2/3 of the 75 kHz one, the reservation included).
        let share: Float = 50.0 / 75.0
        let peak50 = Self.expectedBudget * share
        let margin50 = -20.0 * log10f(peak50 + Self.reserved * share)
        let ceiling50 = CompositeBudgetState.audioCeiling(
            limitThreshold: 1.0, deviationKHz: 50.0, outputGainDB: 0.0,
            budgetMarginDB: margin50, audioPeak: peak50)
        #expect(abs(ceiling50 - peak50) < 1e-4, "50 kHz ceiling \(ceiling50) vs \(peak50)")
        // -6 dB of output gain scales the metered domain the same way.
        let trim = powf(10.0, -6.0 / 20.0)
        let marginTrim = -20.0 * log10f((audioPeak + Self.reserved) * trim)
        let ceilingTrim = CompositeBudgetState.audioCeiling(
            limitThreshold: 1.0, deviationKHz: 75.0, outputGainDB: -6.0,
            budgetMarginDB: marginTrim, audioPeak: audioPeak * trim)
        #expect(abs(ceilingTrim - Self.expectedBudget * trim) < 1e-4,
                "-6 dB ceiling \(ceilingTrim) vs \(Self.expectedBudget * trim)")
    }

    // MARK: - Dense programme reaches full deviation

    private func denseConfig() -> AppConfig {
        var config = AppConfig()
        config.sampleRate = Self.sampleRate
        config.sourceMode = "input"
        config.monitorEnabled = false
        // Hot: the clipper must hold the audio composite on its ceiling for
        // long stretches so the pilot and RDS crests coincide with it.
        config.finalDriveDB = 12.0
        return config
    }

    private struct DenseRender {
        let samplePeak: Float
        let truePeak: Float
        /// Highest audio-composite peak the engine reported anywhere in the
        /// measured window (its peak hold is read every 64 frames; the hold
        /// decays with a 250 ms time constant, so one read loses < 0.01 dB).
        let audioPeakMax: Float
        let calibration: MPXGenerator.CompositeCalibrationStatus
    }

    private func renderDense(_ config: AppConfig, seconds: Double) -> DenseRender {
        let generator = MPXGenerator(config: config, sampleRate: config.sampleRate)
        let frames = Int(config.sampleRate * seconds)
        let settle = frames / 4
        var out = [Float](repeating: 0.0, count: frames - settle)
        var audioPeakMax: Float = 0.0
        var seed: UInt32 = 0x1234_5678
        for n in 0..<frames {
            let t = Double(n) / config.sampleRate
            // Dense pop mix: bass, mids, a bright top and a little noise.
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = (Float(seed >> 8) / Float(1 << 24)) * 2.0 - 1.0
            let l = Float(0.5 * sin(2.0 * Double.pi * 80.0 * t)
                + 0.4 * sin(2.0 * Double.pi * 1_000.0 * t)
                + 0.25 * sin(2.0 * Double.pi * 3_100.0 * t)
                + 0.2 * sin(2.0 * Double.pi * 9_000.0 * t)) + 0.1 * noise
            let r = Float(0.5 * sin(2.0 * Double.pi * 80.0 * t)
                + 0.35 * sin(2.0 * Double.pi * 1_300.0 * t + 0.7)
                + 0.25 * sin(2.0 * Double.pi * 2_500.0 * t)
                - 0.2 * sin(2.0 * Double.pi * 11_000.0 * t)) + 0.1 * noise
            let mpx = generator.renderSingleSample(leftIn: l, rightIn: r)
            if n >= settle {
                out[n - settle] = mpx
                if n % 64 == 0 {
                    audioPeakMax = max(audioPeakMax, generator.compositeCalibrationStatus.audioPeak)
                }
            }
        }
        let tp = truePeak4x(out)
        return DenseRender(samplePeak: tp.samplePeak, truePeak: tp.truePeak,
                           audioPeakMax: audioPeakMax,
                           calibration: generator.compositeCalibrationStatus)
    }

    /// Dense programme through the whole chain: the complete composite now
    /// exceeds the OLD worst-case bound of 0.96 (72 kHz; measured 72.1 kHz
    /// here against 69.3 on the stored baselines), the 4x true peak stays at
    /// or below 0 dBFS and the final clamp never engages after injection.
    /// It does not reach the 0.995 worst case: the composite clipper's tanh
    /// kernel bends ceiling-pinned peaks 0.16-0.27 dB under the budget
    /// (`0.891 + 0.075 tanh(1)` of its 0.966 ceiling) and the pilot / RDS
    /// crests rarely coincide with the audio crest. Closing that gap is the
    /// clip-depth task (audit C1), not the budget.
    ///
    /// Three seconds, and the audio peak is the MAXIMUM over the window: a
    /// 2 s render read the engine's decaying peak hold once at the end,
    /// which only sees the last 250 ms, and that figure moved by 0.5 dB
    /// with the mono bass corner (its FIR length shifts the window by 2 ms
    /// over a multi-tone whose crests do not repeat) -- measured 2026-10-30:
    /// -0.49 / -0.22 dB at 2 s, -0.13 / -0.38 dB at 6 s for 110 / 140 Hz.
    @Test func denseProgrammeExceedsTheOldBudgetWithinTruePeak() {
        let render = renderDense(denseConfig(), seconds: 3.0)
        let deviationKHz = render.samplePeak * MPXGenerator.referenceDeviationKHz
        print(String(
            format: "[budget overhaul] composite sample peak %.4f (%.1f kHz), 4x true peak %.4f (%+.3f dBFS), "
                + "audio peak %.4f, margin %.3f dB, post-injection overshoot %.5f",
            render.samplePeak, deviationKHz, render.truePeak, 20.0 * log10f(render.truePeak),
            render.audioPeakMax, render.calibration.budgetMarginDB,
            render.calibration.postInjectionOvershoot))
        #expect(render.samplePeak > 0.96,
                "complete composite peaks at \(render.samplePeak) (\(deviationKHz) kHz): not above the old 0.96 bound")
        #expect(render.truePeak <= 1.0,
                "4x true peak \(render.truePeak) is above 0 dBFS: inter-sample over-deviation")
        #expect(render.calibration.postInjectionOvershoot == 0.0,
                "final clamp engaged after pilot/RDS injection: \(render.calibration.postInjectionOvershoot)")
        #expect(!render.calibration.overBudget)
        // The audio composite sits just under the 0.8883 budget: never over
        // it, and within the clipper kernel's knee (measured -0.27 dB at
        // 12 dB of drive; -0.02 dB on the stored baselines at 4 dB).
        let budgetDB = 20.0 * log10f(render.audioPeakMax / Self.expectedBudget)
        #expect(budgetDB <= 0.01 && budgetDB > -0.4,
                "audio composite peak \(render.audioPeakMax) is \(budgetDB) dB from the 0.8883 budget")
    }

    /// The calibration tone at 0 dBFS puts the audio EXACTLY on the budget
    /// (the clipper and the limiter are transparent for it), so with the
    /// pilot and RDS at their defaults the whole composite shows what the
    /// budget formula allows: at least 0.99 of full scale (74 kHz at the
    /// 75 kHz setting; the worst-case sum is 0.995), with the 4x true peak
    /// at or below 0 dBFS and the final clamp idle. Until the overhaul the
    /// same render could not exceed 0.96 (72 kHz).
    @Test func calibrationToneWithSubcarriersReachesFullDeviation() {
        // 997 Hz: not a sub-harmonic of the pilot, so the tone and pilot
        // crests drift through every relative phase inside the render.
        var cfg = AppConfig()
        cfg.sampleRate = Self.sampleRate
        cfg.sourceMode = "tone"
        cfg.monitorEnabled = false
        cfg.testToneType = "sine"
        cfg.testToneFreq = 997.0
        cfg.testToneLevelDB = 0.0
        cfg.testToneMode = "mono"
        let generator = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        let frames = Int(cfg.sampleRate * 2.0)
        let settle = frames / 4
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        var mpxLeft = [Float](repeating: 0.0, count: frames)
        var mpxRight = [Float](repeating: 0.0, count: frames)
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                mpxLeft.withUnsafeMutableBufferPointer { mlBuf in
                    mpxRight.withUnsafeMutableBufferPointer { mrBuf in
                        generator.renderToneAndMonitorNonInterleaved(
                            frameCount: frames,
                            left: lBuf.baseAddress!, right: rBuf.baseAddress!,
                            mpxLeft: mlBuf.baseAddress!, mpxRight: mrBuf.baseAddress!)
                    }
                }
            }
        }
        let tp = truePeak4x(Array(mpxLeft[settle...]))
        let cal = generator.compositeCalibrationStatus
        let deviationKHz = tp.samplePeak * MPXGenerator.referenceDeviationKHz
        print(String(
            format: "[budget overhaul] tone + pilot + RDS: sample peak %.4f (%.1f kHz), 4x true peak %.4f (%+.3f dBFS), "
                + "audio peak %.4f, margin %.3f dB, post-injection overshoot %.5f",
            tp.samplePeak, deviationKHz, tp.truePeak, 20.0 * log10f(tp.truePeak),
            cal.audioPeak, cal.budgetMarginDB, cal.postInjectionOvershoot))
        #expect(tp.samplePeak >= 0.99,
                "complete composite peaks at \(tp.samplePeak) (\(deviationKHz) kHz): below 0.99 of full scale")
        #expect(tp.truePeak <= 1.0, "4x true peak \(tp.truePeak) is above 0 dBFS")
        #expect(cal.postInjectionOvershoot == 0.0,
                "final clamp engaged after pilot/RDS injection: \(cal.postInjectionOvershoot)")
        let budgetDB = 20.0 * log10f(cal.audioPeak / Self.expectedBudget)
        #expect(abs(budgetDB) < 0.05,
                "tone audio peak \(cal.audioPeak) is \(budgetDB) dB from the 0.8883 budget")
    }

    // MARK: - Composite Budget state

    @Test func stateReadsTheAudioBudget() {
        let ceiling = Self.expectedBudget
        #expect(CompositeBudgetState.text(
            running: false, audioPeak: 0.0, audioCeiling: ceiling,
            postInjectionOvershoot: 0.0, overBudget: false) == "Off")
        // Silence and a programme 1 dB under the ceiling: Safe.
        #expect(CompositeBudgetState.text(
            running: true, audioPeak: 0.0, audioCeiling: ceiling,
            postInjectionOvershoot: 0.0, overBudget: false) == "Safe")
        #expect(CompositeBudgetState.text(
            running: true, audioPeak: ceiling * powf(10.0, -1.0 / 20.0), audioCeiling: ceiling,
            postInjectionOvershoot: 0.0, overBudget: false) == "Safe")
        // Within 0.5 dB of the ceiling, and ON the ceiling (the designed
        // operating point on dense programme): Tight, never Risk.
        #expect(CompositeBudgetState.text(
            running: true, audioPeak: ceiling * powf(10.0, -0.3 / 20.0), audioCeiling: ceiling,
            postInjectionOvershoot: 0.0, overBudget: false) == "Tight")
        #expect(CompositeBudgetState.text(
            running: true, audioPeak: ceiling, audioCeiling: ceiling,
            postInjectionOvershoot: 0.0, overBudget: false) == "Tight")
        // Risk only when the final clamp engaged after injection or the
        // configuration leaves no audio budget.
        #expect(CompositeBudgetState.text(
            running: true, audioPeak: ceiling * 0.5, audioCeiling: ceiling,
            postInjectionOvershoot: 0.01, overBudget: false) == "Risk")
        #expect(CompositeBudgetState.text(
            running: true, audioPeak: 0.0, audioCeiling: 0.0,
            postInjectionOvershoot: 0.0, overBudget: true) == "Risk")
    }

    /// At the operating point the whole-composite margin the old state read
    /// is a few hundredths of a dB; the new state calls that Tight.
    @Test func operatingPointIsTightNotRisk() {
        let audioPeak = Self.expectedBudget
        let marginDB = -20.0 * log10f(audioPeak + Self.reserved)
        #expect(marginDB < 0.1 && marginDB > 0.0, "whole-composite margin at the operating point: \(marginDB) dB")
        let state = CompositeBudgetState.text(
            running: true,
            audioPeak: audioPeak,
            audioCeiling: CompositeBudgetState.audioCeiling(
                limitThreshold: 1.0, deviationKHz: 75.0, outputGainDB: 0.0,
                budgetMarginDB: marginDB, audioPeak: audioPeak),
            postInjectionOvershoot: 0.0,
            overBudget: false)
        #expect(state == "Tight")
    }
}
