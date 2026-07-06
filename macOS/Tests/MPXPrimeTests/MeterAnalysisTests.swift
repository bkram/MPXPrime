import Foundation
import MPXPrimeCore
import Testing

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
        #expect(abs(s.rdsDevKHz - 2.0) < 0.12)
        // Nothing exceeds 77 kHz: the SM.1268 statistic must be exactly 0.
        #expect(s.exceedanceValid)
        #expect(s.exceedancePct == 0.0)
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
        #expect(abs(s.rdsDevKHz - 2.0) < 0.15)
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
        #expect(s.exceedanceValid)
        #expect(abs(s.exceedancePct - expected) < 1.0)
        // And the windowed peak reads the true 80 kHz.
        #expect(abs(s.posPeakDevKHz - 80.0) < 1.0)
    }
}

@Suite("Meter RDS deviation (EN 50067 equivalent unmodulated subcarrier)")
struct MeterRDSDeviationTests {
    @Test func strongStereoDifferenceContentDoesNotLeakIntoRDS() {
        // 53 kHz is the top of the stereo L-R band, only 4 kHz below the RDS
        // subcarrier. 30 kHz of deviation there must not move the 2.0 kHz
        // RDS reading (the old single Q=10 biquad bandpass leaked badly).
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let pilot = amp(6.75)
        let rds = amp(2.0)
        let edge = amp(30.0)
        feed(a, seconds: 3.0) { t in
            pilot * cosf(twoPi(19_000, t)) + rds * cosf(twoPi(57_000, t))
                + edge * cosf(twoPi(53_000, t))
        }
        let s = a.snapshot()
        #expect(abs(s.rdsDevKHz - 2.0) < 0.15)
    }

    @Test func bpskModulationDoesNotChangeTheReading() {
        // EN 50067 quotes RDS deviation as the level of the UNMODULATED
        // subcarrier; instruments show a "solid reading" regardless of data.
        // A constant-modulus BPSK (sign flips) has the same power as the
        // unmodulated carrier, so the reading must be identical.
        let unmod = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let bpsk = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let rds = amp(2.0)
        feed(unmod, seconds: 3.0) { t in rds * cosf(twoPi(57_000, t)) }
        feed(bpsk, seconds: 3.0) { t in
            // ~300 Hz deterministic sign pattern (slow enough that the
            // sidebands stay inside the measurement passband).
            let sym = Int(t * 300.0)
            let sign: Float = (sym % 2 == 0) ? 1.0 : -1.0
            return sign * rds * cosf(twoPi(57_000, t))
        }
        let u = unmod.snapshot().rdsDevKHz
        let b = bpsk.snapshot().rdsDevKHz
        #expect(abs(u - 2.0) < 0.1)
        #expect(abs(b - u) < 0.12)
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
