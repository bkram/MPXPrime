import Testing
@testable import MPXPrime

struct BandLimitedStepTests {
    @Test func crossingFractionDetectsRisingAndFallingEdges() {
        #expect(approx(BandLimitedStep.crossingFraction(previous: -1.0, current: 1.0, threshold: 0.0), 0.5))
        #expect(approx(BandLimitedStep.crossingFraction(previous: 0.0, current: 4.0, threshold: 1.0), 0.25))
        #expect(approx(BandLimitedStep.crossingFraction(previous: 1.0, current: -1.0, threshold: 0.0), 0.5))
        #expect(approx(BandLimitedStep.crossingFraction(previous: 0.0, current: 1.0, threshold: 1.0), 1.0))
    }

    @Test func crossingFractionRejectsNoCrossingAndThresholdGrazing() {
        #expect(BandLimitedStep.crossingFraction(previous: -1.0, current: -0.2, threshold: 0.0) == nil)
        #expect(BandLimitedStep.crossingFraction(previous: 0.5, current: 0.5, threshold: 0.5) == nil)
        #expect(BandLimitedStep.crossingFraction(previous: 0.0, current: 0.5, threshold: 0.0) == nil)
        #expect(BandLimitedStep.crossingFraction(previous: 0.5, current: 0.0, threshold: 0.5) == nil)
    }

    @Test func kernelNormalizesToUnityAndStaysBounded() {
        let taps = BandLimitedStep.kernelTaps(windowSamples: 16, fractionalOffset: 0.37, cutoffFraction: 0.45)
        let sum = taps.reduce(Float(0.0), +)
        let maxAbs = taps.map { abs($0) }.max() ?? 0.0

        #expect(taps.count == 16)
        #expect(abs(sum - 1.0) < 1e-5)
        #expect(maxAbs < 1.25)
        #expect(taps.allSatisfy { $0.isFinite })
    }

    @Test func stepCorrectionStartsAndEndsNearZero() {
        let taps = BandLimitedStep.stepCorrectionTaps(
            windowSamples: 32,
            fractionalOffset: 0.41,
            cutoffFraction: 0.45
        )
        let maxAbs = taps.map { abs($0) }.max() ?? 0.0

        #expect(abs(taps.first ?? 1.0) < 1e-4)
        #expect(abs(taps.last ?? 1.0) < 1e-4)
        #expect(maxAbs < 1.1)
        #expect(taps.allSatisfy { $0.isFinite })
    }

    @Test func rampCorrectionIsFiniteAndDCBalanced() {
        let taps = BandLimitedStep.rampCorrectionTaps(
            windowSamples: 32,
            fractionalOffset: 0.41,
            cutoffFraction: 0.45
        )
        let sum = taps.reduce(Float(0.0), +)
        let maxAbs = taps.map { abs($0) }.max() ?? 0.0

        #expect(abs(sum) < 1e-5)
        #expect(maxAbs < 4.0)
        #expect(taps.allSatisfy { $0.isFinite })
    }

    @Test func positiveAndNegativeStepsAreSymmetric() {
        var positive = BandLimitedStep(windowSamples: 16, cutoffFraction: 0.45)
        var negative = BandLimitedStep(windowSamples: 16, cutoffFraction: 0.45)
        positive.schedule(stepAmplitude: 0.8, fractionalOffset: 0.42)
        negative.schedule(stepAmplitude: -0.8, fractionalOffset: 0.42)

        for _ in 0..<16 {
            let summed = positive.process(0.0) + negative.process(0.0)
            #expect(abs(summed) < 1e-6)
        }
    }

    @Test func balancedStepsDoNotCreateDCDrift() {
        var step = BandLimitedStep(windowSamples: 16, cutoffFraction: 0.45)
        var total: Float = 0.0

        step.schedule(stepAmplitude: 0.7, fractionalOffset: 0.33)
        for _ in 0..<16 {
            total += step.process(0.0)
        }

        step.schedule(stepAmplitude: -0.7, fractionalOffset: 0.66)
        for _ in 0..<16 {
            total += step.process(0.0)
        }

        #expect(abs(total) < 1e-5)
    }

    @Test func overlappingEventsPreserveScheduledAmplitude() {
        var step = BandLimitedStep(windowSamples: 16, cutoffFraction: 0.45)
        var total: Float = 0.0

        step.schedule(stepAmplitude: 0.4, fractionalOffset: 0.25)
        step.schedule(stepAmplitude: 0.6, fractionalOffset: 0.75)
        for _ in 0..<16 {
            total += step.process(0.0)
        }

        #expect(abs(total - 1.0) < 1e-5)
    }

    @Test func resetClearsPendingCorrection() {
        var step = BandLimitedStep(windowSamples: 16, cutoffFraction: 0.45)
        step.schedule(stepAmplitude: 1.0, fractionalOffset: 0.5)
        step.reset()

        for _ in 0..<16 {
            #expect(step.process(0.0) == 0.0)
        }
    }

    @Test func scheduledStepCorrectionIsFinite() {
        var step = BandLimitedStep(windowSamples: 32, cutoffFraction: 0.45)
        var peak: Float = 0.0

        step.scheduleStepCorrection(stepAmplitude: 0.5, fractionalOffset: 0.41)
        for _ in 0..<32 {
            peak = max(peak, abs(step.process(0.0)))
        }

        #expect(peak > 0.0)
        #expect(peak < 0.6)
    }

    @Test func scheduledRampCorrectionIsFinite() {
        var step = BandLimitedStep(windowSamples: 32, cutoffFraction: 0.45)
        var total: Float = 0.0
        var peak: Float = 0.0

        step.scheduleRampCorrection(slopeDelta: 0.5, fractionalOffset: 0.41)
        for _ in 0..<32 {
            let y = step.process(0.0)
            total += y
            peak = max(peak, abs(y))
        }

        #expect(abs(total) < 1e-5)
        #expect(peak > 0.0)
        #expect(peak < 2.0)
    }

    private func approx(_ value: Float?, _ expected: Float, tolerance: Float = 1e-6) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }
}
