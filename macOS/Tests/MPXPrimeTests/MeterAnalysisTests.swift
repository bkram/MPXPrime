import Foundation
import MPXPrimeCore
import Testing

@testable import MPXPrime

// Deterministic verification of the MPX Prime Meter's measurement math.
// Every test synthesizes a composite whose deviation is known EXACTLY from
// first principles (absolute calibration: amplitude 1.0 == 150 kHz, the SDR
// demod convention) and asserts the meter reads it. This is the measurement
// contract with ITU-R SM.1268-5 (deviation statistics), ITU-R BS.412-9
// (MPX power), BS.450 (pilot), and EN 50067 sec 1.3 (RDS equivalent
// unmodulated subcarrier).

private let sr: Float = 192_000.0
private let fullScale: Float = 150.0  // amplitude 1.0 == 150 kHz deviation
private let blockLen = 8192

/// Amplitude for a component of the given deviation (kHz) under absolute cal.
private func amp(_ kHz: Float) -> Float { kHz / fullScale }

/// Feed `seconds` of a generator through the analysis in engine-sized blocks.
private func feed(
    _ analysis: MeterAnalysis, seconds: Float,
    _ gen: (Float) -> Float
) {
    let total = Int(seconds * sr)
    var block = [Float](repeating: 0.0, count: blockLen)
    var t0 = 0
    while t0 < total {
        let n = min(blockLen, total - t0)
        for i in 0..<n { block[i] = gen(Float(t0 + i) / sr) }
        block.withUnsafeBufferPointer {
            analysis.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
        }
        t0 += n
    }
}

private func twoPi(_ f: Float, _ t: Float) -> Float {
    // Wrap the phase before the trig call: at 192 kHz * several seconds,
    // f*t reaches 1e6+ where Float has ~0.1 phase-turn resolution.
    let cycles = Double(f) * Double(t)
    let frac = cycles - cycles.rounded(.down)
    return Float(2.0 * Double.pi * frac)
}

@Suite("Meter deviation measurement (absolute calibration)")
struct MeterDeviationTests {
    @Test func pilotOnlyReadsExactPilotDeviation() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let pilotAmp = amp(6.75)
        feed(a, seconds: 3.0) { t in pilotAmp * cosf(twoPi(19_000, t)) }
        let s = a.snapshot()
        // Pilot: BS.450 9% injection == 6.75 kHz, measured coherently.
        #expect(abs(s.pilotDevKHz - 6.75) < 0.07)
        // A bare pilot IS the whole composite: MAX DEV == pilot deviation.
        #expect(abs(s.maxDevKHz - 6.75) < 0.2)
        // No RDS present: the coherent 57 kHz meter must read ~zero.
        #expect(s.rdsDevKHz < 0.05)
        // MPX power of a sine at 6.75 kHz deviation:
        // 10*log10((6.75^2/2) / (19^2/2)) = -8.99 dBr.
        #expect(s.mpxPowerValid)
        #expect(abs(s.mpxPowerDBr - (-8.99)) < 0.3)
    }

    @Test func fullCompositeReadsExactTotalDeviation() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        // 1 kHz mono at 66.25 kHz + pilot 6.75 + unmodulated RDS 2.0:
        // all cosine, all harmonics of 1 kHz, so every 1 ms the three crests
        // align and the composite peak is EXACTLY 75.0 kHz.
        let mono = amp(66.25)
        let pilot = amp(6.75)
        let rds = amp(2.0)
        feed(a, seconds: 3.0) { t in
            mono * cosf(twoPi(1_000, t)) + pilot * cosf(twoPi(19_000, t))
                + rds * cosf(twoPi(57_000, t))
        }
        let s = a.snapshot()
        #expect(abs(s.maxDevKHz - 75.0) < 0.7)
        #expect(abs(s.posPeakDevKHz - 75.0) < 0.7)
        #expect(s.negPeakDevKHz < -57.0 && s.negPeakDevKHz > -75.7)
        #expect(abs(s.pilotDevKHz - 6.75) < 0.1)
        // An UNMODULATED 57 kHz carrier reads its amplitude times the shaped-
        // biphase form factor (the reading is calibrated so spec-shaped DATA
        // reads the set injection; see encoderRoundTripReadsTheSetInjection).
        let unmodFactor = RDSSubcarrierLevelMeter.shapedBiphasePeakOverRMSSqrt2
        #expect(abs(s.rdsDevKHz - 2.0 * unmodFactor) < 0.15)
        // Nothing exceeds 77 kHz: the SM.1268 statistic must be exactly 0.
        // (It is not yet VALID -- one sample in a million needs a full minute
        // of samples to resolve; see exceedanceValidityRequiresAFullMinute.)
        #expect(s.exceedancePct == 0.0)
        #expect(!s.exceedanceValid)
        #expect(s.exceedanceBoundPct > 0.0)
    }

    @Test func pilotReferencedModeMatchesAbsolute() {
        // Same composite, uncalibrated input: the pilot anchors the scale.
        let a = MeterAnalysis(sampleRate: sr, pilotRefKHz: 6.75, fullScaleKHz: nil)
        let mono = amp(66.25)
        let pilot = amp(6.75)
        let rds = amp(2.0)
        feed(a, seconds: 3.0) { t in
            mono * cosf(twoPi(1_000, t)) + pilot * cosf(twoPi(19_000, t))
                + rds * cosf(twoPi(57_000, t))
        }
        let s = a.snapshot()
        #expect(s.pilotDevKHz == 6.75)  // echoes the reference
        #expect(abs(s.maxDevKHz - 75.0) < 1.0)
        // Unmodulated test carrier: reads amplitude x form factor (see
        // fullCompositeReadsExactTotalDeviation).
        let unmodFactor = RDSSubcarrierLevelMeter.shapedBiphasePeakOverRMSSqrt2
        #expect(abs(s.rdsDevKHz - 2.0 * unmodFactor) < 0.2)
    }

    @Test func dcOffsetDoesNotSkewPeakSymmetry() {
        // SDR demod carrier offset == DC. 60 kHz symmetric tone + 7.5 kHz of
        // DC: the DC tracker must remove it so +/- peaks stay symmetric
        // (without it: +67.5 / -52.5).
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let tone = amp(60.0)
        let dc = amp(7.5)
        feed(a, seconds: 3.0) { t in dc + tone * cosf(twoPi(1_000, t)) }
        let s = a.snapshot()
        #expect(abs(s.posPeakDevKHz - 60.0) < 1.0)
        #expect(abs(s.negPeakDevKHz + 60.0) < 1.0)
    }

    @Test func measurementFilterDoesNotOvershootClippedComposite() {
        // A clipped-then-bandlimited composite (what a broadcast processor
        // actually emits). The linear-phase FIR measurement filter must pass
        // it without manufacturing overshoot; the old 6th-order Butterworth
        // IIR rang ~1-3% high on exactly this signal class.
        let total = Int(3.0 * sr)
        var raw = [Float](repeating: 0.0, count: total)
        for i in 0..<total {
            let t = Float(i) / sr
            // Hard-clipped dense program stand-in.
            let x = 3.0 * sinf(twoPi(1_000, t)) + 1.5 * sinf(twoPi(3_700, t))
            raw[i] = max(-1.0, min(1.0, x)) * amp(70.0)
        }
        // Transmitter-side bandlimit (53 kHz linear-phase FIR), so the test
        // signal is a legitimate band-limited composite with known true peak.
        let txTaps = FIRDesign.kaiserLowpass(
            cutoffHz: 53_000, sampleRate: sr, transitionHz: 4_000, stopbandDB: 80)
        let tx = BlockFIRFilter(taps: txTaps, maxBlock: total)
        var limited = [Float](repeating: 0.0, count: total)
        raw.withUnsafeBufferPointer { tx.process(input: $0, output: &limited, count: total) }
        // True peak of the actual test signal (skip the FIR warmup edge).
        var truePeak: Float = 0.0
        for i in (txTaps.count)..<total { truePeak = max(truePeak, abs(limited[i])) }

        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        var idx = 0
        var block = [Float](repeating: 0.0, count: blockLen)
        while idx < total {
            let n = min(blockLen, total - idx)
            for i in 0..<n { block[i] = limited[idx + i] }
            block.withUnsafeBufferPointer {
                a.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
            }
            idx += n
        }
        let s = a.snapshot()
        let trueKHz = truePeak * fullScale
        // No overshoot: the reading must not exceed the true peak by > 0.7%.
        #expect(s.posPeakDevKHz <= trueKHz * 1.007)
        #expect(-s.negPeakDevKHz <= trueKHz * 1.007)
        // And it must not under-read either (within 2%).
        #expect(s.maxDevKHz > trueKHz * 0.98)
    }

    @Test func exceedanceStatisticMatchesAnalyticFraction() {
        // A constant tone at 80 kHz deviation: the fraction of samples with
        // |80*cos| > 77 kHz is exactly acos(77/80)/(pi/2) = 17.45%.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let tone = amp(80.0)
        feed(a, seconds: 4.0) { t in tone * cosf(twoPi(1_000, t)) }
        let s = a.snapshot()
        let expected = Float(acos(77.0 / 80.0) / (Double.pi / 2.0) * 100.0)
        #expect(abs(s.exceedancePct - expected) < 1.0)
        // And the windowed peak reads the true 80 kHz.
        #expect(abs(s.posPeakDevKHz - 80.0) < 1.0)
    }

    /// SM.1268-5 sec 4 judges a transmitter at 1e-4 % of samples -- one in a
    /// million. A short window cannot resolve that (1 s at 192 kHz resolves
    /// 5.2e-4 %, 520x too coarse, so a single transient read as a violation),
    /// so the statistic only becomes VALID after a full minute; before that the
    /// snapshot publishes the upper bound the counted samples support (0.45,
    /// audit M6).
    @Test func exceedanceStaysInvalidUntilTheWindowIsLongEnough() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let tone = amp(80.0)
        feed(a, seconds: 4.0) { t in tone * cosf(twoPi(1_000, t)) }
        let early = a.snapshot()
        #expect(!early.exceedanceValid)
        // The published bound is exactly one sample's worth of the counted
        // total (100 / count %), which also pins the sample accounting: 4 s at
        // 192 kHz minus the ~1 s warm-up.
        #expect(early.exceedanceBoundPct > 0.0)
        let counted = Double(100.0 / early.exceedanceBoundPct)
        #expect(counted > 0.55e6 && counted < 0.79e6)
        // The percentage itself is already measured (see the analytic test);
        // only its VALIDITY waits for the minute. The crossing is pinned by
        // the deep-suite test below, which needs a real minute of samples.
    }

    /// Losing the deviation scale must invalidate the peaks rather than leave
    /// the last station's kHz on the snapshot (the struct is reused across
    /// blocks, and the view tinted those numbers red as live over-deviation --
    /// 0.45, audit M7 / C2 / C14).
    @Test func lostDeviationScaleInvalidatesPeaks() {
        // Pilot-referenced (no absolute scale): a composite WITH a pilot
        // establishes the scale, then pilot-free noise must drop it.
        let a = MeterAnalysis(sampleRate: sr)
        feed(a, seconds: 2.0) { t in
            (0.5 * cosf(twoPi(1_000, t))) + (0.09 * sinf(twoPi(19_000, t)))
        }
        let withPilot = a.snapshot()
        #expect(withPilot.devScaleValid)
        #expect(withPilot.peakValid)
        #expect(withPilot.posPeakDevKHz > 0.0)
        // Pilot gone (the station dropped stereo / reception lost): after the
        // hold window the kHz readouts must stop being measurements.
        feed(a, seconds: 2.0) { t in 0.5 * cosf(twoPi(1_000, t)) }
        let noPilot = a.snapshot()
        #expect(!noPilot.devScaleValid)
        #expect(!noPilot.peakValid)
        #expect(noPilot.posPeakDevKHz == 0.0)
        #expect(noPilot.negPeakDevKHz == 0.0)
    }

    /// A block longer than the configured `maxBlock` is split, not indexed past
    /// the scratch buffers (0.45, audit M15 -- it used to trap).
    @Test func oversizedBlockIsSplitInsteadOfTrapping() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale, maxBlock: 512)
        // Past the ~1 s warm-up, in one 1.5 s call -- 3x the scratch capacity.
        let big = (0..<Int(1.5 * sr)).map { i in
            amp(50.0) * cosf(twoPi(1_000, Float(i) / sr))
        }
        big.withUnsafeBufferPointer { a.process($0) }
        let s = a.snapshot()
        #expect(s.hasSignal)
        #expect(abs(s.maxDevKHz - 50.0) < 1.0)
    }
}

@Suite("Meter RDS deviation (peak subcarrier level, encoder-consistent)")
struct MeterRDSDeviationTests {
    @Test func strongStereoDifferenceContentDoesNotLeakIntoRDS() {
        // 53 kHz is the top of the stereo L-R band, only 4 kHz below the RDS
        // subcarrier. 30 kHz of deviation there must not move the RDS
        // reading (the old single Q=10 biquad bandpass leaked badly).
        let clean = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let leaky = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let pilot = amp(6.75)
        let rds = amp(2.0)
        let edge = amp(30.0)
        feed(clean, seconds: 3.0) { t in
            pilot * cosf(twoPi(19_000, t)) + rds * cosf(twoPi(57_000, t))
        }
        feed(leaky, seconds: 3.0) { t in
            pilot * cosf(twoPi(19_000, t)) + rds * cosf(twoPi(57_000, t))
                + edge * cosf(twoPi(53_000, t))
        }
        let c = clean.snapshot().rdsDevKHz
        let l = leaky.snapshot().rdsDevKHz
        #expect(abs(l - c) < 0.1)  // the 53 kHz tone must not move the reading
        let unmodFactor = RDSSubcarrierLevelMeter.shapedBiphasePeakOverRMSSqrt2
        #expect(abs(c - 2.0 * unmodFactor) < 0.2)
    }

    @Test func encoderRoundTripReadsTheSetInjection() {
        // THE RDS-level contract: an EN 50067-exact shaped biphase stream
        // from our own encoder at rds_level = 2.0 kHz must read 2.0 kHz.
        // Encoders normalize the shaped waveform by its peak, so the set
        // level IS the envelope peak; the meter reads the coherent envelope
        // peak (50 ms slot maxima, 1 s mean). An RMS-equivalent reading sits
        // ~24% low on real shaped data (the 0.39 under-read regression).
        let sr192: Float = 192_000.0
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "83E1"
        cfg.rdsPSA = "TESTCASE"
        cfg.rdsRTText = "RDS level round-trip regression"
        let coder = BasicRDSCoder(config: cfg, sampleRate: sr192)

        let a = MeterAnalysis(sampleRate: sr192, fullScaleKHz: 75.0)
        let total = Int(5.0 * sr192)
        var block = [Float](repeating: 0.0, count: blockLen)
        let pilotAmp: Float = 6.75 / 75.0
        var idx = 0
        while idx < total {
            let n = min(blockLen, total - idx)
            for i in 0..<n {
                let t = Float(idx + i) / sr192
                block[i] = coder.nextSample() + pilotAmp * cosf(twoPi(19_000, t))
            }
            block.withUnsafeBufferPointer {
                a.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
            }
            idx += n
        }
        let s = a.snapshot()
        #expect(abs(s.rdsDevKHz - 2.0) < 0.12)
        // Guard against regressing to the RMS convention (~1.51 kHz).
        #expect(s.rdsDevKHz > 1.85)
        #expect(abs(s.pilotDevKHz - 6.75) < 0.1)
    }

    @Test func readingIsSteadyUnderDataModulation() {
        // Instruments show a "solid reading": two snapshots ~1 s apart over
        // live shaped data must agree closely.
        let sr192: Float = 192_000.0
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "83E1"
        cfg.rdsRTText = "Steadiness check with changing group content"
        let coder = BasicRDSCoder(config: cfg, sampleRate: sr192)
        let a = MeterAnalysis(sampleRate: sr192, fullScaleKHz: 75.0)
        var block = [Float](repeating: 0.0, count: blockLen)
        func run(seconds: Float) {
            let total = Int(seconds * sr192)
            var idx = 0
            while idx < total {
                let n = min(blockLen, total - idx)
                for i in 0..<n { block[i] = coder.nextSample() }
                block.withUnsafeBufferPointer {
                    a.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
                }
                idx += n
            }
        }
        run(seconds: 3.0)
        let first = a.snapshot().rdsDevKHz
        run(seconds: 1.0)
        let second = a.snapshot().rdsDevKHz
        #expect(abs(first - second) < 0.08)
    }
}

@Suite("Meter deviation statistics (MAX / AVE / MIN, histogram)")
struct MeterDeviationStatisticsTests {
    @Test func steadyToneReadsTheSameMaxAveAndMin() {
        // A constant-amplitude tone fills every 50 ms slot identically, so
        // the three statistics must collapse onto the same value.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let tone = amp(50.0)
        feed(a, seconds: 3.0) { t in tone * cosf(twoPi(1_000, t)) }
        let s = a.snapshot()
        #expect(abs(s.maxDevKHz - 50.0) < 0.5)
        #expect(abs(s.aveDevKHz - 50.0) < 0.5)
        #expect(abs(s.minDevKHz - 50.0) < 0.5)
    }

    @Test func aveSitsBetweenMinAndMaxOnADynamicSignal() {
        // 2 Hz amplitude sweep between 20 and 70 kHz: successive 50 ms slots
        // see different peaks, so MIN < AVE < MAX -- the spread a single MAX
        // number hides.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        feed(a, seconds: 4.0) { t in
            let env = 0.5 + 0.5 * cosf(twoPi(2, t))       // 0..1
            return amp(20.0 + 50.0 * env) * cosf(twoPi(1_000, t))
        }
        let s = a.snapshot()
        #expect(s.maxDevKHz > s.aveDevKHz)
        #expect(s.aveDevKHz > s.minDevKHz)
        #expect(s.maxDevKHz <= 71.0)
        #expect(s.minDevKHz >= 19.0)
    }

    @Test func histogramBinsTheDeviationAndAccumulates() {
        // Steady 60 kHz: every slot lands in the 60 kHz bin, so the
        // accumulated distribution is 100% at or above 60 and 0% above 61.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let tone = amp(60.0)
        feed(a, seconds: 4.0) { t in tone * cosf(twoPi(1_000, t)) }
        let s = a.snapshot()
        #expect(s.devHistogramSamples > 40)  // ~20 slots/s for ~3 s past warm-up
        #expect(s.devHistogram.count == MeterAnalysis.histogramBins)
        // All samples in one bin (59 or 60 -- the 1 kHz bin edge).
        let inBand = UInt64(s.devHistogram[59]) + UInt64(s.devHistogram[60])
        #expect(inBand == s.devHistogramSamples)
        #expect(s.devDistributionAtOrAbove(59.0) > 0.99)
        #expect(s.devDistributionAtOrAbove(62.0) == 0.0)
        #expect(abs(s.devHistogramMaxKHz - 59.5) <= 0.5)
    }

    @Test func histogramSplitsAMixedSignalByProportion() {
        // 3 s at 40 kHz then 1 s at 70 kHz: the distribution must report
        // ~25% of the programme at or above 70 kHz.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        a.requestPeakReset()
        feed(a, seconds: 1.2) { t in amp(40.0) * cosf(twoPi(1_000, t)) }  // warm-up
        a.requestPeakReset()
        feed(a, seconds: 3.0) { t in amp(40.0) * cosf(twoPi(1_000, t)) }
        feed(a, seconds: 1.0) { t in amp(70.0) * cosf(twoPi(1_000, t)) }
        let s = a.snapshot()
        let hot = s.devDistributionAtOrAbove(69.0)
        #expect(hot > 0.18 && hot < 0.32)
        #expect(s.devDistributionAtOrAbove(39.0) > 0.99)
        // The 40 -> 70 kHz amplitude step is a discontinuity, so a slot or
        // two straddling it legitimately reads a few kHz high; the histogram
        // must reach the 70 kHz content but need not stop exactly there.
        #expect(s.devHistogramMaxKHz >= 69.0)
        #expect(s.devHistogramMaxKHz <= 76.0)
    }

    @Test func histogramClearsOnPeakReset() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        feed(a, seconds: 3.0) { t in amp(50.0) * cosf(twoPi(1_000, t)) }
        #expect(a.snapshot().devHistogramSamples > 0)
        a.requestPeakReset()
        feed(a, seconds: 0.5) { _ in 0.0 }
        let s = a.snapshot()
        #expect(s.devHistogramSamples < 15)
        // Only the first slot after the tone stops can still hold the
        // measurement filter's decay; the rest are silence.
        #expect(s.devDistributionAtOrAbove(5.0) < 0.25)
    }
}

@Suite("Meter carrier offset, baseband noise, stereo balance")
struct MeterQualityMetricsTests {
    @Test func carrierOffsetReadsTheDCAsDeviation() {
        // An FM demod turns a transmitter carrier offset into composite DC.
        // 5 kHz of DC must read as +5 kHz of carrier offset -- and must NOT
        // leak into the deviation peaks (the DC tracker removes it).
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let dc = amp(5.0)
        let tone = amp(40.0)
        feed(a, seconds: 4.0) { t in dc + tone * cosf(twoPi(1_000, t)) }
        let s = a.snapshot()
        #expect(s.carrierOffsetValid)
        #expect(abs(s.carrierOffsetKHz - 5.0) < 0.3)
        #expect(abs(s.posPeakDevKHz - 40.0) < 1.0)
    }

    @Test func carrierOffsetIsSignedAndZeroOnACenteredSignal() {
        let neg = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        feed(neg, seconds: 4.0) { t in -amp(3.0) + amp(30.0) * cosf(twoPi(1_000, t)) }
        #expect(abs(neg.snapshot().carrierOffsetKHz + 3.0) < 0.3)

        let centered = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        feed(centered, seconds: 4.0) { t in amp(30.0) * cosf(twoPi(1_000, t)) }
        #expect(abs(centered.snapshot().carrierOffsetKHz) < 0.2)
    }

    @Test func basebandNoiseSeesOnlyWhatIsAboveTheModulatedBands() {
        // A clean composite has nothing above 60 kHz: the noise readout must
        // be near zero and the quality scale at its top.
        let clean = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        feed(clean, seconds: 3.0) { t in
            amp(60.0) * cosf(twoPi(1_000, t)) + amp(6.75) * cosf(twoPi(19_000, t))
        }
        let c = clean.snapshot()
        #expect(c.basebandNoiseValid)
        #expect(c.basebandNoiseKHz < 0.1)
        #expect(c.signalQuality == 4)

        // Add 4 kHz of out-of-band energy at 80 kHz (demod noise lives here;
        // nothing is legitimately modulated above 60 kHz).
        let noisy = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        feed(noisy, seconds: 3.0) { t in
            amp(60.0) * cosf(twoPi(1_000, t)) + amp(6.75) * cosf(twoPi(19_000, t))
                + amp(4.0) * cosf(twoPi(80_000, t))
        }
        let n = noisy.snapshot()
        // A sine of 4 kHz peak deviation is 4/sqrt(2) = 2.83 kHz RMS.
        #expect(abs(n.basebandNoiseKHz - 2.83) < 0.4)
        #expect(n.signalQuality == 0)  // past the 3.0 kHz bottom threshold
        // ... and it must not have disturbed the in-band measurements. The
        // in-band peak is 60 + 6.75 kHz: the tone and the pilot are both
        // cosines on harmonics of 1 kHz, so their crests coincide.
        #expect(abs(n.maxDevKHz - 66.75) < 1.0)
    }

    @Test func qualityScaleStepsWithTheNoiseFloor() {
        // Each threshold crossing costs exactly one step of the 4..0 scale.
        for (noiseKHz, expected) in [(Float(0.05), 4), (0.2, 3), (0.6, 2), (2.0, 1), (6.0, 0)] {
            let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
            // Amplitude for the requested RMS: a sine's RMS is peak/sqrt(2).
            let peakKHz = noiseKHz * Float(2.0).squareRoot()
            feed(a, seconds: 3.0) { t in
                amp(40.0) * cosf(twoPi(1_000, t)) + amp(peakKHz) * cosf(twoPi(80_000, t))
            }
            #expect(a.snapshot().signalQuality == expected)
        }
    }

    @Test func stereoBalanceReadsTheChannelOffset() {
        // Left 6 dB hotter than right, encoded as a real composite.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let l: Float = 0.20
        let r: Float = 0.20 * powf(10.0, -6.0 / 20.0)
        // Standard composite (47 CFR 73.322 / BS.450-3): M = (L+R)/2,
        // S = (L-R)/2, composite = M + S*sin(2pi*38k*t), with the pilot as
        // sin(2pi*19k*t) so the subcarrier is its true second harmonic -- a
        // cosine pilot against a cosine subcarrier is 90 deg out and decodes
        // as no side at all. A real station with left hotter must read +dB.
        feed(a, seconds: 8.0) { t in
            let audioL = l * cosf(twoPi(1_000, t))
            let audioR = r * cosf(twoPi(1_000, t))
            let mid = (audioL + audioR) * 0.5
            let side = (audioL - audioR) * 0.5
            return mid + side * sinf(twoPi(38_000, t))
                + amp(6.75) * sinf(twoPi(19_000, t))
        }
        let s = a.snapshot()
        #expect(s.stereoBalanceValid)
        #expect(abs(s.stereoBalanceDB - 6.0) < 1.5)
    }

    @Test func stereoBalanceIsZeroOnAMonoSignal() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        feed(a, seconds: 8.0) { t in
            amp(40.0) * cosf(twoPi(1_000, t)) + amp(6.75) * cosf(twoPi(19_000, t))
        }
        let s = a.snapshot()
        #expect(s.stereoBalanceValid)
        #expect(abs(s.stereoBalanceDB) < 1.0)
    }
}

@Suite("Meter RDS subcarrier phase (EN 50067 sec 1.2)")
struct MeterRDSPhaseTests {
    /// Composite of a pilot and a 57 kHz subcarrier whose phase relative to
    /// the pilot's third harmonic is EXACTLY `phaseDeg`. Both components are
    /// written as sines of the same phase argument, so the third harmonic of
    /// the pilot is `sin(3*theta)` by construction and the subcarrier's offset
    /// from it is the only phase in the signal.
    private func phaseComposite(
        _ analysis: MeterAnalysis, seconds: Float, phaseDeg: Float,
        pilotHz: Float = 19_000.0, rdsKHz: Float = 2.0
    ) {
        let pilotAmp = amp(6.75)
        let rdsAmp = amp(rdsKHz)
        let phi = phaseDeg * Float.pi / 180.0
        feed(analysis, seconds: seconds) { t in
            let theta = twoPi(pilotHz, t)
            // sin(3*theta) computed from the phase argument directly (not the
            // triple-angle identity) so the test is independent of the
            // meter's own derivation.
            let third = twoPi(3.0 * pilotHz, t)
            return pilotAmp * sinf(theta) + rdsAmp * sinf(third + phi)
        }
    }

    @Test func inPhaseSubcarrierReadsZeroDegrees() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        phaseComposite(a, seconds: 4.0, phaseDeg: 0.0)
        let s = a.snapshot()
        #expect(s.pilotRDSPhaseValid)
        #expect(s.pilotRDSPhaseDeg < 1.0)
        #expect(s.pilotRDSPhase == .inPhase)
        // A clean synthetic subcarrier is fully coherent.
        #expect(s.pilotRDSPhaseCoherence > 0.95)
    }

    @Test func quadratureSubcarrierReadsNinetyDegrees() {
        // The other EN 50067-legal convention (BBC practice).
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        phaseComposite(a, seconds: 4.0, phaseDeg: 90.0)
        let s = a.snapshot()
        #expect(s.pilotRDSPhaseValid)
        #expect(s.pilotRDSPhaseDeg > 89.0)
        #expect(s.pilotRDSPhase == .quadrature)
    }

    @Test func antiPhaseIsIndistinguishableFromInPhase() {
        // The subcarrier is suppressed-carrier DSB, so 180 deg is the
        // in-phase case with inverted data -- the squaring estimator folds
        // them together, as a receiver's differential decoding does.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        phaseComposite(a, seconds: 4.0, phaseDeg: 180.0)
        let s = a.snapshot()
        #expect(s.pilotRDSPhaseValid)
        #expect(s.pilotRDSPhaseDeg < 1.0)
    }

    @Test func misalignedSubcarrierReadsItsAngleAndFailsSpec() {
        // 45 deg: the worst case -- equidistant from both legal conventions.
        // This is the reading that says an encoder is not truly pilot-locked.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        phaseComposite(a, seconds: 4.0, phaseDeg: 45.0)
        let s = a.snapshot()
        #expect(s.pilotRDSPhaseValid)
        #expect(abs(s.pilotRDSPhaseDeg - 45.0) < 1.5)
        #expect(s.pilotRDSPhase == .outOfSpec)
    }

    @Test func readingIsImmuneToPilotFrequencyOffset() {
        // THE design contract for the matched lock-in chains. The measurement
        // NCO never sits exactly on the pilot (transmitter tolerance +/- 2 Hz
        // plus capture-clock ppm), so both baseband phasors rotate -- the
        // 57 kHz one three times faster. Unmatched filter group delays turn
        // that into a phase error of 3*w*(tau_p - tau_r): at the 5 Hz offset
        // used here, a 2.5 ms mismatch would read ~13 deg on a subcarrier
        // that is exactly in phase. Identical chains cancel it.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        phaseComposite(a, seconds: 4.0, phaseDeg: 0.0, pilotHz: 19_005.0)
        let s = a.snapshot()
        #expect(s.pilotRDSPhaseValid)
        #expect(s.pilotRDSPhaseDeg < 2.0)

        // ... and the same offset must not drag a quadrature station off 90.
        let q = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        phaseComposite(q, seconds: 4.0, phaseDeg: 90.0, pilotHz: 19_005.0)
        #expect(q.snapshot().pilotRDSPhaseDeg > 88.0)
    }

    @Test func strongStereoDifferenceContentDoesNotBiasThePhase() {
        // 53 kHz is 4 kHz from the subcarrier: 30 kHz of L-R edge energy must
        // not move the angle (the same selectivity contract the RDS LEVEL
        // meter carries).
        let clean = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let leaky = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        phaseComposite(clean, seconds: 4.0, phaseDeg: 30.0)
        let pilotAmp = amp(6.75)
        let rdsAmp = amp(2.0)
        let edge = amp(30.0)
        let phi = 30.0 * Float.pi / 180.0
        feed(leaky, seconds: 4.0) { t in
            pilotAmp * sinf(twoPi(19_000, t))
                + rdsAmp * sinf(twoPi(57_000, t) + phi)
                + edge * cosf(twoPi(53_000, t))
        }
        let c = clean.snapshot()
        let l = leaky.snapshot()
        #expect(abs(c.pilotRDSPhaseDeg - 30.0) < 1.5)
        #expect(abs(l.pilotRDSPhaseDeg - c.pilotRDSPhaseDeg) < 2.0)
    }

    @Test func absentSubcarrierIsNotReportedAsAPhase() {
        // Pilot only, no RDS: the meter must say "no reading". Note this is
        // NOT caught by coherence -- the tiny pilot leakage that survives the
        // 57 kHz chain is perfectly coherent (it is the pilot), so it reads a
        // confident ~0 deg on ~0.01 kHz. The RDS level gate is what rejects
        // it; keep both gates.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let pilotAmp = amp(6.75)
        feed(a, seconds: 3.0) { t in pilotAmp * sinf(twoPi(19_000, t)) }
        let s = a.snapshot()
        #expect(!s.pilotRDSPhaseValid)
        #expect(s.rdsDevKHz < 0.05)
    }

    @Test func subcarrierBelowTheInjectionFloorIsNotReported() {
        // A 0.3 kHz "subcarrier" is below EN 50067's 1.0 kHz minimum
        // injection and below the meter's 0.8 kHz gate: no phase reading,
        // even though the angle itself would be perfectly measurable.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        phaseComposite(a, seconds: 3.0, phaseDeg: 0.0, rdsKHz: 0.3)
        #expect(!a.snapshot().pilotRDSPhaseValid)
    }

    @Test func encoderRoundTripReadsInPhase() {
        // THE phase contract: our own encoder derives the 57 kHz carrier from
        // the emitted pilot's recurrence via the triple-angle identity, so a
        // measuring receiver must read it as in phase (EN 50067 sec 1.2, the
        // 0 deg convention). Real shaped biphase, not a bare carrier: this
        // also proves the squaring estimator handles the BPSK sign flips.
        let sr192: Float = 192_000.0
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "83E1"
        cfg.rdsPSA = "PHASETST"
        cfg.rdsRTText = "Pilot-to-RDS subcarrier phase round-trip"
        let coder = BasicRDSCoder(config: cfg, sampleRate: sr192)

        let a = MeterAnalysis(sampleRate: sr192, fullScaleKHz: 75.0)
        let total = Int(6.0 * sr192)
        var block = [Float](repeating: 0.0, count: blockLen)
        let pilotAmp: Float = 6.75 / 75.0
        var idx = 0
        while idx < total {
            let n = min(blockLen, total - idx)
            for i in 0..<n {
                let pilotSin = sinf(twoPi(19_000, Float(idx + i) / sr192))
                coder.updateRDSPilotSin(pilotSin)
                block[i] = coder.nextSampleWithPilotLock() + pilotAmp * pilotSin
            }
            block.withUnsafeBufferPointer {
                a.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
            }
            idx += n
        }
        let s = a.snapshot()
        #expect(s.pilotRDSPhaseValid)
        #expect(s.pilotRDSPhaseDeg < 5.0)
        #expect(s.pilotRDSPhase == .inPhase)
    }

    @Test func accuracyAcrossTheRangeBeatsTheReferenceInstrument() {
        // Accuracy contract, stated against the instrument this readout is
        // modelled on: the Pira P175/P275 FM Broadcast Analyzer specifies
        // "Pilot-to-RDS phase difference error +/- 4 deg". Sweep the whole
        // 0..90 range and require an order of magnitude better on a clean
        // synthetic composite (measured worst case is ~0.12 deg; the 1 deg
        // bound leaves room for float noise across platforms). Real off-air
        // accuracy is set by noise and in-band IM, not by this, but a DSP
        // error budget above ~1 deg would eat into the +/- 10 deg window the
        // verdict is drawn on.
        var worst: Float = 0.0
        for trueDeg in stride(from: Float(0.0), through: 90.0, by: 15.0) {
            let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
            phaseComposite(a, seconds: 3.0, phaseDeg: trueDeg)
            let s = a.snapshot()
            #expect(s.pilotRDSPhaseValid)
            worst = max(worst, abs(s.pilotRDSPhaseDeg - trueDeg))
        }
        #expect(worst < 1.0)
    }

    @Test func accuracyHoldsAcrossTheLegalInjectionRange() {
        // EN 50067 sec 1.3 allows 1.0..7.5 kHz of RDS. The angle must not
        // depend on level -- the residual coherent pilot leakage in the
        // 57 kHz chain pulls the reading toward 0 deg, and that pull grows as
        // the subcarrier shrinks (measured -0.14 deg at the 0.8 kHz gate
        // floor, -0.01 deg at 7.5 kHz).
        for level in [Float(0.8), 1.0, 3.0, 7.5] {
            let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
            phaseComposite(a, seconds: 3.0, phaseDeg: 30.0, rdsKHz: level)
            let s = a.snapshot()
            #expect(s.pilotRDSPhaseValid)
            #expect(abs(s.pilotRDSPhaseDeg - 30.0) < 1.0)
        }
    }

    /// The coherence ratio primes at EXACTLY 1.0 (|zr^2| == |zr|^2 for a
    /// single sample) and only decays on the ~2 s EMA, so before 0.45 the
    /// phase readout was "valid" for the whole settling time on ANYTHING after
    /// a retune -- and the folded angle of noise has expectation 45 deg, which
    /// is where the phantom "45.4 deg" readings came from (audit M4).
    @Test func noiseDoesNotReadAsAValidPhaseWhileTheAverageIsPriming() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        // Pilot present (so the pilot gate passes) plus broadband noise where
        // the subcarrier would be -- no coherent 57 kHz component at all.
        var seed: UInt64 = 0x5DEECE66D
        let pilotAmp = amp(6.75)
        feed(a, seconds: 0.4) { t in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = Float(Int32(truncatingIfNeeded: seed >> 32)) / 2.147483648e9
            return (pilotAmp * sinf(twoPi(19_000, t))) + (0.15 * r)
        }
        #expect(!a.snapshot().pilotRDSPhaseValid)
    }

    /// Coherence is scale-free and says nothing about whether the angle is
    /// STANDING STILL. A free-running RDS carrier (not locked to the pilot)
    /// walks the angle through the whole range at sub-Hz rate with coherence
    /// high the entire time, and the readout used to label the sweep
    /// in-spec / out-of-spec as it passed (audit M5).
    @Test func aDriftingSubcarrierPhaseIsNotPublishedAsAMeasurement() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        // 57 kHz + 0.02 Hz: only 7.2 deg/s of phase walk, deliberately SLOW
        // enough that the 2 s coherence average stays high -- so this pins the
        // stability gate specifically, not the coherence floor.
        let pilotAmp = amp(6.75)
        let rdsAmp = amp(2.0)
        feed(a, seconds: 4.0) { t in
            (pilotAmp * sinf(twoPi(19_000, t)))
                + (rdsAmp * sinf(twoPi(57_000.02, t)))
        }
        let s = a.snapshot()
        #expect(s.pilotRDSPhaseCoherence > 0.8)  // coherence would have passed
        #expect(!s.pilotRDSPhaseValid)           // stability gate rejects it
        // A locked subcarrier at the same level and duration IS published --
        // i.e. the gate rejects drift, not RDS.
        let b = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        phaseComposite(b, seconds: 4.0, phaseDeg: 30.0)
        #expect(b.snapshot().pilotRDSPhaseValid)
    }

    @Test func complianceWindowsMatchTheStandard() {
        // EN 50067 sec 1.2: either convention, +/- 10 deg.
        #expect(RDSPhaseCompliance(degrees: 0.0) == .inPhase)
        #expect(RDSPhaseCompliance(degrees: 10.0) == .inPhase)
        #expect(RDSPhaseCompliance(degrees: 10.5) == .outOfSpec)
        #expect(RDSPhaseCompliance(degrees: 45.0) == .outOfSpec)
        #expect(RDSPhaseCompliance(degrees: 79.5) == .outOfSpec)
        #expect(RDSPhaseCompliance(degrees: 80.0) == .quadrature)
        #expect(RDSPhaseCompliance(degrees: 90.0) == .quadrature)
        #expect(RDSPhaseCompliance(degrees: 45.0).isCompliant == false)
    }
}

@Suite("Meter MPX power (ITU-R BS.412 uniform sliding window)")
struct MeterMPXPowerTests {
    @Test func sineAt19kHzDeviationReadsZeroDBr() {
        let a = MeterAnalysis(
            sampleRate: sr, fullScaleKHz: fullScale, mpxPowerWindowSeconds: 4)
        let tone = amp(19.0)
        feed(a, seconds: 6.0) { t in tone * cosf(twoPi(1_000, t)) }
        let s = a.snapshot()
        #expect(s.mpxPowerValid)
        #expect(abs(s.mpxPowerDBr) < 0.1)
        #expect(s.mpxPowerMaxValid)
        #expect(abs(s.mpxPowerMaxDBr) < 0.1)
    }

    @Test func windowIsUniformNotExponential() {
        // Fill a 4 s window with a 0 dBr tone, then feed 2 s of silence.
        // A UNIFORM window holds 2 s loud + 2 s quiet: exactly -3.01 dBr.
        // The old 60 s EMA over-weighted the recent audio (that is why the
        // meter and the transmit-side BS.412 limiter disagreed).
        let a = MeterAnalysis(
            sampleRate: sr, fullScaleKHz: fullScale, mpxPowerWindowSeconds: 4)
        let tone = amp(19.0)
        feed(a, seconds: 5.0) { t in tone * cosf(twoPi(1_000, t)) }  // 1 s warmup + 4 s
        feed(a, seconds: 2.0) { _ in 0.0 }
        let s = a.snapshot()
        #expect(s.mpxPowerValid)
        #expect(abs(s.mpxPowerDBr - (-3.01)) < 0.15)
        // The compliance max keeps the worst full window (~0 dBr).
        #expect(s.mpxPowerMaxValid)
        #expect(abs(s.mpxPowerMaxDBr) < 0.15)
    }

    @Test func windowFullyForgetsOldProgram() {
        // After a full window of silence the sliding mean must drop to the
        // floor -- an EMA never fully forgets.
        let a = MeterAnalysis(
            sampleRate: sr, fullScaleKHz: fullScale, mpxPowerWindowSeconds: 3)
        let tone = amp(19.0)
        feed(a, seconds: 4.5) { t in tone * cosf(twoPi(1_000, t)) }
        feed(a, seconds: 4.0) { _ in 0.0 }
        let s = a.snapshot()
        #expect(s.mpxPowerValid)
        #expect(s.mpxPowerDBr < -30.0)
    }
}

@Suite("Meter windowed peaks (SM.1268 display statistics)")
struct MeterWindowedPeakTests {
    @Test func impulseAgesOutOfThePeakWindow() {
        // One 2 ms burst at 85 kHz inside otherwise 40 kHz program. With a
        // short 2 s peak window the burst must dominate PEAK+ while inside
        // the window and be GONE once it ages out -- the old latched max
        // pinned 85 kHz until manual reset.
        let a = MeterAnalysis(
            sampleRate: sr, fullScaleKHz: fullScale, peakWindowSeconds: 2)
        let baseAmp = amp(40.0)
        let burstAmp = amp(85.0)
        // 1 s warmup + 1 s base, then the burst, then base again.
        feed(a, seconds: 2.0) { t in baseAmp * cosf(twoPi(1_000, t)) }
        feed(a, seconds: 0.002) { t in burstAmp * cosf(twoPi(1_000, t) + 0.2) }
        feed(a, seconds: 0.5) { t in baseAmp * cosf(twoPi(1_000, t)) }
        let during = a.snapshot().posPeakDevKHz
        #expect(during > 75.0)  // burst visible while in the window
        feed(a, seconds: 3.0) { t in baseAmp * cosf(twoPi(1_000, t)) }
        let after = a.snapshot().posPeakDevKHz
        #expect(abs(after - 40.0) < 1.0)  // burst aged out, base restored
    }

    @Test func maxDevTracksTrailingSecond() {
        // MAX DEV is the trailing-1 s max: after level drops from 70 to 30
        // kHz, the reading must follow within ~1 s (the old 2 s exponential
        // decay lingered).
        let a = MeterAnalysis(
            sampleRate: sr, fullScaleKHz: fullScale, peakWindowSeconds: 2)
        feed(a, seconds: 2.5) { t in amp(70.0) * cosf(twoPi(1_000, t)) }
        #expect(abs(a.snapshot().maxDevKHz - 70.0) < 1.0)
        feed(a, seconds: 1.3) { t in amp(30.0) * cosf(twoPi(1_000, t)) }
        #expect(abs(a.snapshot().maxDevKHz - 30.0) < 1.0)
    }
}

@Suite("Meter RDS reception-quality gate")
struct MeterRDSGateTests {
    /// Deterministic broadband noise (seeded LCG; no Math.random in tests).
    private struct LCG {
        var state: UInt64
        mutating func nextFloat() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: Int64(bitPattern: state >> 33))) / Float(Int32.max)
        }
    }

    @Test func gateSuppressesNoiseHallucinations() {
        // Pilot + broadband noise, NO RDS: the stream decoder happily syncs
        // on accidental syndrome matches and hallucinates PI/PTY at ~74%
        // BER -- the published readout must stay blank and be marked gated.
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        var rng = LCG(state: 0x4d585052494d45)
        let pilot = amp(6.75)
        let noise = amp(25.0)
        feed(a, seconds: 5.0) { t in
            pilot * cosf(twoPi(19_000, t)) + noise * rng.nextFloat()
        }
        let s = a.snapshot()
        #expect(s.rdsGated)
        #expect(s.rds.pi == nil)
        #expect(!s.rds.synced)
        #expect(!s.rdsLocked)
        // Note: broadband noise at this level legitimately reads a few kHz on
        // the coherent 57 kHz level meter (in-band noise energy) -- the BER
        // criterion is what holds the gate closed here, by design.
    }

    @Test func gateOpensOnRealRDS() {
        // Spec-exact shaped RDS from our own encoder: the gate must open and
        // the real PI must publish.
        let sr192: Float = 192_000.0
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = "83E1"
        cfg.rdsPSA = "GATETEST"
        let coder = BasicRDSCoder(config: cfg, sampleRate: sr192)
        let a = MeterAnalysis(sampleRate: sr192, fullScaleKHz: 75.0)
        var block = [Float](repeating: 0.0, count: blockLen)
        let pilotAmp: Float = 6.75 / 75.0
        let total = Int(6.0 * sr192)
        var idx = 0
        while idx < total {
            let n = min(blockLen, total - idx)
            for i in 0..<n {
                let t = Float(idx + i) / sr192
                block[i] = coder.nextSample() + pilotAmp * cosf(twoPi(19_000, t))
            }
            block.withUnsafeBufferPointer {
                a.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
            }
            idx += n
        }
        let s = a.snapshot()
        #expect(!s.rdsGated)
        #expect(s.rds.pi == 0x83E1)
        #expect(s.rds.synced)
    }

    @Test func forceBypassesTheGate() {
        // Same noise as the suppress test, but Force on: publishing must not
        // be gated (whatever junk the decoder produced is shown verbatim).
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        a.setForceRDS(true)
        var rng = LCG(state: 0x4d585052494d45)
        let pilot = amp(6.75)
        let noise = amp(25.0)
        feed(a, seconds: 5.0) { t in
            pilot * cosf(twoPi(19_000, t)) + noise * rng.nextFloat()
        }
        let s = a.snapshot()
        #expect(!s.rdsGated)
    }
}

/// A full minute of samples is expensive in a debug build (~25 s), so the
/// actual validity CROSSING lives in the opt-in deep suite; the default suite
/// pins the invalid-and-bounded state (0.45, audit M6).
@Suite("Meter exceedance validity (deep)",
       .enabled(if: ProcessInfo.processInfo.environment["MPXPRIME_DEEP"] != nil))
struct MeterExceedanceValidityDeepTests {
    @Test func exceedanceBecomesValidAfterAFullMinute() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let tone = amp(80.0)
        feed(a, seconds: 4.0) { t in tone * cosf(twoPi(1_000, t)) }
        #expect(!a.snapshot().exceedanceValid)
        feed(a, seconds: 58.0) { t in tone * cosf(twoPi(1_000, t)) }
        let late = a.snapshot()
        #expect(late.exceedanceValid)
        let expected = Float(acos(77.0 / 80.0) / (Double.pi / 2.0) * 100.0)
        #expect(abs(late.exceedancePct - expected) < 1.0)
    }
}
