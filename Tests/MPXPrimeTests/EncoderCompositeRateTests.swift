import Foundation
import Testing
@testable import MPXPrime

/// Composite services against the render rate, and the RDS injection scale
/// (encoder review 2026-10, findings 4 and 5).
@Suite("Encoder composite rate and RDS level")
struct EncoderCompositeRateTests {
    private static func goertzelAmplitude(_ x: [Float], hz: Double, sampleRate: Double) -> Double {
        var s = 0.0
        var c = 0.0
        for (n, v) in x.enumerated() {
            let w = 2.0 * Double.pi * hz * Double(n) / sampleRate
            s += Double(v) * sin(w)
            c += Double(v) * cos(w)
        }
        return 2.0 * (s * s + c * c).squareRoot() / Double(x.count)
    }

    /// Composite of a left-only 1 kHz tone, after settling.
    private static func leftOnlyComposite(sampleRate: Double) -> [Float] {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.sourceMode = "input"
        cfg.enRDS = true
        let generator = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        let total = Int(sampleRate * 0.6)
        let keep = Int(sampleRate * 0.2)  // 200 cycles of 1 kHz: leak-free
        var out: [Float] = []
        out.reserveCapacity(keep)
        for i in 0..<total {
            let x = Float(0.2 * sin(2.0 * Double.pi * 1_000.0 * Double(i) / sampleRate))
            let mpx = generator.renderSingleSample(leftIn: x, rightIn: 0.0)
            if i >= total - keep { out.append(mpx) }
        }
        return out
    }

    @Test func thresholdsFollowTheBandPlan() {
        // Upper L-R sideband: 38 kHz + 17.5 kHz audio band edge = 55.5 kHz.
        #expect(MPXGenerator.minimumStereoSampleRate == 111_000.0)
        // RDS: 57 kHz + 2.4 kHz.
        #expect(abs(MPXGenerator.minimumRDSSampleRate - 118_800.0) < 0.001)
        #expect(MPXGenerator.compositeRateSupport(sampleRate: 96_000) == .init(stereo: false, rds: false))
        #expect(MPXGenerator.compositeRateSupport(sampleRate: 115_000) == .init(stereo: true, rds: false))
        #expect(MPXGenerator.compositeRateSupport(sampleRate: 176_400) == .init(stereo: true, rds: true))
        #expect(MPXGenerator.compositeRateSupport(sampleRate: 192_000) == .init(stereo: true, rds: true))
        #expect(MPXGenerator.compositeRateNote(sampleRate: 96_000)?.contains("too low for stereo") == true)
        #expect(MPXGenerator.compositeRateNote(sampleRate: 115_000)?.contains("too low for RDS") == true)
        #expect(MPXGenerator.compositeRateNote(sampleRate: 192_000) == nil)
    }

    /// At 96 kHz the upper sideband of a 12 kHz tone (50 kHz) would fold to
    /// 46 kHz and decode as an 8 kHz L-R alias. Below the stereo threshold
    /// the composite is mono: no pilot, no subcarrier, no RDS.
    @Test func stereoIsOffBelowTheThreshold() {
        let rate = 96_000.0
        let composite = Self.leftOnlyComposite(sampleRate: rate)
        let mono = Self.goertzelAmplitude(composite, hz: 1_000, sampleRate: rate)
        let pilot = Self.goertzelAmplitude(composite, hz: 19_000, sampleRate: rate)
        let lowerSideband = Self.goertzelAmplitude(composite, hz: 37_000, sampleRate: rate)
        let upperSideband = Self.goertzelAmplitude(composite, hz: 39_000, sampleRate: rate)
        #expect(mono > 0.01, "mono \(mono)")
        #expect(pilot < mono * 1e-4, "pilot \(pilot) at 96 kHz")
        #expect(lowerSideband < mono * 1e-4, "38 - 1 kHz sideband \(lowerSideband) at 96 kHz")
        #expect(upperSideband < mono * 1e-4, "38 + 1 kHz sideband \(upperSideband) at 96 kHz")
    }

    @Test func stereoIsOnAt192k() {
        let rate = 192_000.0
        let composite = Self.leftOnlyComposite(sampleRate: rate)
        let mono = Self.goertzelAmplitude(composite, hz: 1_000, sampleRate: rate)
        let pilot = Self.goertzelAmplitude(composite, hz: 19_000, sampleRate: rate)
        let lowerSideband = Self.goertzelAmplitude(composite, hz: 37_000, sampleRate: rate)
        #expect(pilot > 0.05, "pilot \(pilot)")
        #expect(lowerSideband > mono * 0.3, "sideband \(lowerSideband) vs mono \(mono)")
    }

    /// Peak of an RDS-only composite (pilot level 0, silent programme), in
    /// kHz on the fixed 75 kHz scale (`DeviationReadout`).
    private static func rdsPeakKHz(deviationKHz: Double) -> Float {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        cfg.sourceMode = "input"
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.pilotLevel = 0.0
        cfg.outputGainDB = 0.0
        cfg.mpxDeviationKHz = deviationKHz
        let generator = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        var peak: Float = 0.0
        let frames = Int(cfg.sampleRate * 0.6)
        for i in 0..<frames {
            let mpx = generator.renderSingleSample(leftIn: 0.0, rightIn: 0.0)
            if i > frames / 3 { peak = max(peak, fabsf(mpx)) }
        }
        return DeviationReadout.kilohertz(compositePeak: peak, modulationReferenceScale: 1.0)
    }

    /// `rds_level` is kHz of deviation at every `mpx_deviation_khz`. Before
    /// 2026-10 it followed the deviation: 2.0 put 1.33 kHz on air at 50 kHz.
    @Test func rdsInjectionIsTrueKilohertzAtAnyDeviation() {
        let at75 = Self.rdsPeakKHz(deviationKHz: 75.0)
        let at50 = Self.rdsPeakKHz(deviationKHz: 50.0)
        let at25 = Self.rdsPeakKHz(deviationKHz: 25.0)
        #expect(abs(at75 - 2.0) < 0.15, "RDS peak \(at75) kHz at 75 kHz deviation")
        #expect(abs(at50 / at75 - 1.0) < 0.02, "RDS peak \(at50) kHz at 50 vs \(at75) kHz at 75")
        #expect(abs(at25 / at75 - 1.0) < 0.02, "RDS peak \(at25) kHz at 25 vs \(at75) kHz at 75")
    }

    /// Finding 6: the audio-composite bandwidth FIR (`MPXGenerator`,
    /// 55 kHz passband edge, 5 kHz transition, 92 dB) passes most of the RDS
    /// band (54.6-59.4 kHz); RDS protection rests on the composite clipper's
    /// RDS guard. Pinned so a design change -- or a doc claiming the FIR
    /// strips everything above the upper stereo sideband -- is deliberate.
    @Test func compositeBandwidthFIRResponseInTheRDSBand() {
        let kernel = kaiserSincLowpassCoefficients(
            cutoffHz: 55_000, sampleRate: 192_000, stopBandDB: 92, transitionHz: 5_000)
        func gainDB(_ hz: Double) -> Double {
            var re = 0.0
            var im = 0.0
            for (n, h) in kernel.enumerated() {
                let w = 2.0 * Double.pi * hz * Double(n) / 192_000.0
                re += Double(h) * cos(w)
                im -= Double(h) * sin(w)
            }
            return 10.0 * log10(re * re + im * im)
        }
        #expect(abs(gainDB(53_000)) < 0.01)
        #expect(abs(gainDB(54_600)) < 0.01)
        #expect(abs(gainDB(57_000) - -2.8) < 0.5, "57 kHz: \(gainDB(57_000)) dB")
        #expect(abs(gainDB(59_400) - -43.9) < 2.0, "59.4 kHz: \(gainDB(59_400)) dB")
        #expect(gainDB(60_500) < -85, "60.5 kHz: \(gainDB(60_500)) dB")
    }
}
