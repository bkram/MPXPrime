import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// Spectral tests on the MPX composite output with RDS configured.
//
// Approach: build an MPXGenerator from a sensible AppConfig, feed it silent
// L/R input for enough frames to settle filter transients, capture one FFT
// window of composite output, then inspect energy at:
//   * 19 kHz (pilot)
//   * 54-60 kHz (RDS subcarrier band; biphase spreads energy ~1187.5 Hz wide)
//   * 38 kHz (stereo subcarrier — must be silent with silent input)
//
// Mono Mode and `en_rds = false` paths are verified to suppress what they
// should. "Pilot-locked" 57 kHz is verified by asserting the RDS spectral
// peak falls on the bin that is exactly 3x the pilot bin.

@Suite("RDS DSP signal")
struct RDSSignalTests {

    private let sampleRate: Float = 192_000.0
    private let fftSize: Int = 16_384
    private let warmupFrames: Int = 2_048

    private func renderMPX(config: AppConfig) -> [Float] {
        let gen = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        let totalFrames = warmupFrames + fftSize
        var left = [Float](repeating: 0.0, count: totalFrames)
        var right = [Float](repeating: 0.0, count: totalFrames)
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                gen.renderFromInputInPlace(
                    frameCount: totalFrames,
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!
                )
            }
        }
        return Array(left[warmupFrames..<totalFrames])
    }

    private func analyze(_ samples: [Float]) -> SpectralReport {
        let analyzer = FFTAnalyzer(fftSize: fftSize)
        return analyzer.analyze(samples, sampleRate: sampleRate)
    }

    // MARK: - Pilot and RDS presence

    /// Pilot and RDS levels against their DEFINITIONS, not "present": the old
    /// bounds (pilot above -40 dBFS, RDS band above -60 dBFS) passed a pilot
    /// 19 dB low (test-suite review 2026-10 finding 13). Composite
    /// 1.0 is 75 kHz at every deviation setting and the whole composite is
    /// scaled by `mpx_deviation_khz / 75`, so the pilot amplitude is
    /// `pilot_level * deviation / 75` (9 % of 75 kHz = 0.09) and the RDS
    /// subcarrier's peak is `rds_level` kHz of that deviation. 0.5 s of
    /// silent input, processing bypassed: the composite is pilot + RDS only.
    private func pilotAndRDS(rdsLevel: Double, deviationKHz: Double)
        -> (config: AppConfig, pilotAmplitude: Double, rdsPeak: Double) {
        var config = AppConfig()
        config.processingBypass = true
        config.rdsLevel = rdsLevel
        config.mpxDeviationKHz = deviationKHz
        let gen = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        let frames = warmupFrames + 192 * 500     // 192 frames hold exactly 19 pilot cycles
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                // swiftlint:disable:next force_unwrapping
                gen.renderFromInputInPlace(frameCount: frames, left: lBuf.baseAddress!, right: rBuf.baseAddress!)
            }
        }
        let x = Array(left[warmupFrames...])
        // Least-squares 19 kHz sinusoid over a whole number of cycles
        // (192 samples = 19 cycles at 192 kHz), then RDS = what is left.
        let w = 2.0 * Double.pi * 19_000.0 / Double(sampleRate)
        var s = 0.0, c = 0.0
        for i in 0..<x.count {
            s += Double(x[i]) * sin(w * Double(i))
            c += Double(x[i]) * cos(w * Double(i))
        }
        s *= 2.0 / Double(x.count)
        c *= 2.0 / Double(x.count)
        var peak = 0.0
        for i in 0..<x.count {
            let residual = Double(x[i]) - s * sin(w * Double(i)) - c * cos(w * Double(i))
            peak = max(peak, abs(residual))
        }
        return (config, hypot(s, c), peak)
    }

    @Test(arguments: [75.0, 60.0])
    func pilotIsAtItsConfiguredInjection(deviationKHz: Double) {
        let m = pilotAndRDS(rdsLevel: 2.0, deviationKHz: deviationKHz)
        let expected = m.config.pilotLevel * deviationKHz / 75.0
        let errorDB = 20.0 * log10(m.pilotAmplitude / expected)
        #expect(abs(errorDB) < 0.2,
                "pilot amplitude \(m.pilotAmplitude) at \(deviationKHz) kHz deviation, expected \(expected) (\(errorDB) dB off)")
    }

    @Test(arguments: [(2.0, 75.0), (4.0, 75.0), (2.0, 60.0)])
    func rdsSubcarrierPeakIsItsConfiguredInjection(rdsLevel: Double, deviationKHz: Double) {
        // The coder's biphase shaping peaks a few percent over the nominal
        // (+0.37 dB before 2026-10; the all-zeros reference made it ~0 dB); 1 dB keeps a doubled or halved
        // level (6 dB), the scaling by deviation and a missing subcarrier
        // all far outside the bound.
        let m = pilotAndRDS(rdsLevel: rdsLevel, deviationKHz: deviationKHz)
        let expected = rdsLevel / 75.0  // true kHz at every deviation (review 2026-10 finding 5)
        let errorDB = 20.0 * log10(max(m.rdsPeak, 1e-12) / expected)
        #expect(abs(errorDB) < 1.0,
                "RDS peak \(m.rdsPeak) for rds_level \(rdsLevel) kHz at \(deviationKHz) kHz deviation, expected \(expected) (\(errorDB) dB off)")
    }

    @Test func rdsSubcarrierPresentAround57kHz() {
        var config = AppConfig()
        config.processingBypass = true
        let report = analyze(renderMPX(config: config))
        let rdsDB = report.peakDBFS(in: 54_000...60_000)
        #expect(rdsDB > -60.0, "RDS band energy measured \(rdsDB) dBFS, expected > -60")
    }

    @Test func stereoSubcarrierSilentWithSilentInput() {
        // With silent L=R=0, the stereo (S=L-R) channel is zero, so the 38 kHz
        // DSB-SC carrier should have no energy beyond noise floor.
        var config = AppConfig()
        config.processingBypass = true
        let report = analyze(renderMPX(config: config))
        let subDB = report.peakDBFS(in: 37_500...38_500)
        #expect(subDB < -60.0, "38 kHz subcarrier energy \(subDB) dBFS leaked with silent input")
    }

    // MARK: - Mono Mode

    @Test func monoModeSuppressesPilot() {
        var config = AppConfig()
        config.processingBypass = true
        config.monoMode = true
        let report = analyze(renderMPX(config: config))
        let pilotDB = report.peakDBFS(in: 18_800...19_200)
        #expect(pilotDB < -60.0, "Mono Mode pilot measured \(pilotDB) dBFS, should be < -60")
    }

    @Test func monoModeSuppressesRDS() {
        var config = AppConfig()
        config.processingBypass = true
        config.monoMode = true
        let report = analyze(renderMPX(config: config))
        let rdsDB = report.peakDBFS(in: 54_000...60_000)
        #expect(rdsDB < -60.0, "Mono Mode RDS measured \(rdsDB) dBFS, should be < -60")
    }

    // MARK: - Disabling RDS

    @Test func rdsOffRemovesSubcarrierEnergy() {
        var on = AppConfig()
        on.processingBypass = true
        var off = AppConfig()
        off.processingBypass = true
        off.enRDS = false

        let onDB = analyze(renderMPX(config: on)).peakDBFS(in: 54_000...60_000)
        let offDB = analyze(renderMPX(config: off)).peakDBFS(in: 54_000...60_000)
        #expect(onDB - offDB > 20.0,
                "RDS on \(onDB) dBFS should be at least 20 dB above RDS off \(offDB) dBFS")
    }

    @Test func rdsLevelZeroRemovesSubcarrierEnergy() {
        var on = AppConfig()
        on.processingBypass = true
        var zero = AppConfig()
        zero.processingBypass = true
        zero.rdsLevel = 0.0

        let onDB = analyze(renderMPX(config: on)).peakDBFS(in: 54_000...60_000)
        let zeroDB = analyze(renderMPX(config: zero)).peakDBFS(in: 54_000...60_000)
        #expect(onDB - zeroDB > 20.0,
                "RDS level 2.0 \(onDB) dBFS should be at least 20 dB above level 0 \(zeroDB) dBFS")
    }

    // MARK: - Pilot lock (57 kHz = 3 × 19 kHz) — verified via sideband symmetry

    @Test func rdsSubcarrierSidebandsSymmetricAround57kHz() {
        // Biphase shaping produces a spectral NULL at the 57 kHz carrier;
        // main-lobe energy sits symmetrically in the sidebands. A valid DSB-SC
        // RDS signal will have roughly equal energy in the lower and upper
        // sidebands. Gross asymmetry would indicate a broken carrier or
        // single-sideband leakage.
        var config = AppConfig()
        config.processingBypass = true
        let report = analyze(renderMPX(config: config))

        let lower = report.peakDBFS(in: 55_600...56_800)
        let upper = report.peakDBFS(in: 57_200...58_400)
        #expect(lower > -60.0, "lower sideband energy \(lower) dBFS too low")
        #expect(upper > -60.0, "upper sideband energy \(upper) dBFS too low")
        let imbalance = abs(lower - upper)
        #expect(imbalance < 6.0,
                "RDS sidebands asymmetric: lower \(lower) dBFS, upper \(upper) dBFS, diff \(imbalance) dB")
    }

    @Test func rdsNullAt57kHzCenter() {
        // A biphase-shaped DSB-SC signal has a spectral null at the carrier.
        // The 57 kHz bin should sit meaningfully below the sideband peaks.
        var config = AppConfig()
        config.processingBypass = true
        let report = analyze(renderMPX(config: config))
        let centerDB = report.peakDBFS(in: 56_990...57_010)
        let sidebandDB = max(
            report.peakDBFS(in: 55_600...56_800),
            report.peakDBFS(in: 57_200...58_400)
        )
        #expect(sidebandDB - centerDB > 10.0,
                "57 kHz center \(centerDB) dBFS not below sideband peak \(sidebandDB) dBFS by 10 dB")
    }

    // MARK: - Pilot level scales with config

    @Test func doublingPilotLevelLiftsPilotEnergy() {
        var low = AppConfig()
        low.processingBypass = true
        low.pilotLevel = 0.04
        var high = AppConfig()
        high.processingBypass = true
        high.pilotLevel = 0.08

        let lowDB = analyze(renderMPX(config: low)).peakDBFS(in: 18_800...19_200)
        let highDB = analyze(renderMPX(config: high)).peakDBFS(in: 18_800...19_200)
        // 0.08 / 0.04 = 2x = +6 dB nominal
        let delta = highDB - lowDB
        #expect(delta > 4.0 && delta < 8.0,
                "pilot level doubling gave \(delta) dB step, expected ~6 dB")
    }

    // MARK: - Pilot/RDS phase lock (B1 regression)

    /// The RDS 57 kHz carrier must stay exactly locked to 3x the emitted
    /// 19 kHz pilot (EN 50067 Sec 2.1.4). Before the fix the carrier was
    /// driven by a separate additive phase accumulator that drifted off
    /// the pilot's recurrence oscillator (~9 deg / 5 s). Now the carrier
    /// is sin(3*theta) derived from the pilot recurrence, so the relative
    /// phase is flat over an arbitrarily long render. This renders ~2 s,
    /// recovers the pilot phase (Goertzel) and the BPSK RDS carrier phase
    /// (57 kHz bandpass + complex demod + squaring to strip the +/-1
    /// modulation) in an early and a late window, and asserts the
    /// pilot-vs-RDS relationship barely moves.
    @Test func rdsCarrierStaysPhaseLockedToTriplePilot() {
        var config = AppConfig()
        config.processingBypass = true  // pilot + RDS only, no audio DSP
        let sr = Double(sampleRate)
        let totalFrames = warmupFrames + Int(2.0 * sr)
        let gen = MPXGenerator(config: config, sampleRate: sr)
        var left = [Float](repeating: 0.0, count: totalFrames)
        var right = [Float](repeating: 0.0, count: totalFrames)
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                gen.renderFromInputInPlace(
                    frameCount: totalFrames,
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!
                )
            }
        }
        let samples = Array(left[warmupFrames..<totalFrames])

        let win = Int(0.2 * sr)
        let earlyStart = 0
        let lateStart = samples.count - win

        func pilotPhase(_ start: Int) -> Double {
            let omega = 2.0 * Double.pi * 19_000.0 / sr
            var sinSum = 0.0
            var cosSum = 0.0
            for i in 0..<win {
                let phase = omega * Double(start + i)
                let s = Double(samples[start + i])
                sinSum += s * sin(phase)
                cosSum += s * cos(phase)
            }
            return atan2(cosSum, sinSum)
        }

        func rdsCarrierPhase(_ start: Int) -> Double {
            var bp = Biquad()
            bp.configureBandpass(freqHz: 57_000.0, sampleRate: sampleRate, q: 14.0)
            let prime = max(0, start - 2048)
            for i in prime..<start { _ = bp.process(samples[i]) }
            let omega = 2.0 * Double.pi * 57_000.0 / sr
            var re = 0.0
            var im = 0.0
            for i in 0..<win {
                let n = Double(start + i)
                let s = Double(bp.process(samples[start + i]))
                let zr = s * cos(omega * n)
                let zi = -s * sin(omega * n)
                re += (zr * zr) - (zi * zi)
                im += 2.0 * zr * zi
            }
            return 0.5 * atan2(im, re)
        }

        let earlyErr = rdsCarrierPhase(earlyStart) - 3.0 * pilotPhase(earlyStart)
        let lateErr = rdsCarrierPhase(lateStart) - 3.0 * pilotPhase(lateStart)
        var drift = lateErr - earlyErr
        let pi = Double.pi
        while drift > pi / 2 { drift -= pi }
        while drift < -pi / 2 { drift += pi }
        let driftDeg = abs(drift) * 180.0 / pi
        #expect(driftDeg < 1.0,
                "RDS carrier drifted \(driftDeg) deg vs 3x pilot over ~2 s — not locked to pilot recurrence")
    }
}
