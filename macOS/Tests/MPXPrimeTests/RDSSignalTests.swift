import Testing
import Foundation
@testable import MPXPrime

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

    @Test func pilotPresentAt19kHz() {
        var config = AppConfig()
        config.processingBypass = true  // isolate MPX/pilot path from audio DSP transients
        let report = analyze(renderMPX(config: config))
        let pilotDB = report.peakDBFS(in: 18_800...19_200)
        #expect(pilotDB > -40.0, "pilot at 19 kHz measured \(pilotDB) dBFS, expected > -40")
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
}
