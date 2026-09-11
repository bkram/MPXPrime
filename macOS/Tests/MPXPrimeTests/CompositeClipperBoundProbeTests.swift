import Foundation
import Testing

@testable import MPXPrime

// Pins a structural fact of the differential composite clipper: its guard-
// band cancellation restores the protected bands (22-53 kHz stereo region,
// pilot, RDS) to the CLEAN input, so on a deep overdrive the raw output
// exceeds the configured ceiling IN-BAND -- the 55 kHz bandwidth FIR removes
// none of it. The final look-ahead MPX limiter (budget-referenced, 0.45)
// exists to take that excess with a gain ride. Anyone tempted to drop the
// limiter or run the shaper ahead of it should see this number first.
@Suite struct CompositeClipperBoundProbeTests {

    /// One clipper configuration of the attribution table.
    struct ProbeCase: CustomStringConvertible, Sendable {
        let label: String
        let stereoGuard: Float
        let cancelPilot: Bool
        let cancelRDS: Bool
        let oversampling: Int
        let thresholdDB: Float
        var description: String { label }
    }

    /// Overshoot above the configured ceiling (dB) of the clipper output after
    /// the 55 kHz bandwidth FIR, on a 12 dB two-tone overdrive.
    private static func firOvershootDB(_ c: ProbeCase) -> (raw: Float, fir: Float) {
        let sampleRate: Float = 192_000.0
        var clipper = CompositeClipper()
        clipper.configure(sampleRate: sampleRate, thresholdDB: c.thresholdDB, ceilingDB: -0.3,
                          cancelAudio: false, stereoGuard: c.stereoGuard,
                          cancelPilot: c.cancelPilot, cancelRDS: c.cancelRDS,
                          lookaheadMS: 0.0, oversamplingFactor: c.oversampling)
        var fir = LinearPhaseFIRLowpass()
        fir.configure(cutoffHz: 55_000.0, sampleRate: sampleRate, stopBandDB: 92.0, transitionHz: 5_000.0)
        let frames = 96_000
        var rawPeak: Float = 0.0
        var firPeak: Float = 0.0
        for n in 0..<frames {
            let t = Float(n) / sampleRate
            let x = 4.0 * (0.7 * sinf(2.0 * Float.pi * 1_000.0 * t) + 0.3 * sinf(2.0 * Float.pi * 9_000.0 * t))
            let y = clipper.process(x)
            let z = fir.process(left: y, right: y).0
            if n > frames / 2 {
                rawPeak = max(rawPeak, fabsf(y))
                firPeak = max(firPeak, fabsf(z))
            }
        }
        let ceiling = powf(10.0, -0.3 / 20.0)
        return (20.0 * log10f(rawPeak / ceiling), 20.0 * log10f(firPeak / ceiling))
    }

    @Test func guardCancellationLeavesInBandOvershootForTheLimiter() {
        let base = ProbeCase(label: "defaults", stereoGuard: 1.0, cancelPilot: true, cancelRDS: true,
                             oversampling: 16, thresholdDB: -1.0)
        let over = Self.firOvershootDB(base)
        #expect(over.raw > 0.4, "clipper raw overshoot \(over.raw) dB above the ceiling expected")
        #expect(over.fir > 0.4, "the overshoot is in-band: FIR overshoot \(over.fir) dB")
        #expect(over.raw < 4.1, "overshoot should stay a fraction of the ceiling, not run away")
    }

    /// Attribution table (chain review A1): where does the in-band overshoot the
    /// final limiter has to ride come from? Each row switches one thing off
    /// relative to the defaults; the "no guards, guard 0" row is the pure
    /// band-limiting (Gibbs) overshoot of LP(clipped). Printed for the record,
    /// asserted only to be finite and bounded -- the decision it feeds is A2.
    static let attributionCases: [ProbeCase] = [
        ProbeCase(label: "defaults (guard 1, pilot+RDS, 16x, knee 0.7 dB)", stereoGuard: 1.0, cancelPilot: true, cancelRDS: true, oversampling: 16, thresholdDB: -1.0),
        ProbeCase(label: "pilot guard OFF", stereoGuard: 1.0, cancelPilot: false, cancelRDS: true, oversampling: 16, thresholdDB: -1.0),
        ProbeCase(label: "RDS guard OFF", stereoGuard: 1.0, cancelPilot: true, cancelRDS: false, oversampling: 16, thresholdDB: -1.0),
        ProbeCase(label: "stereo guard 0", stereoGuard: 0.0, cancelPilot: true, cancelRDS: true, oversampling: 16, thresholdDB: -1.0),
        ProbeCase(label: "no guards at all (pure band-limit overshoot)", stereoGuard: 0.0, cancelPilot: false, cancelRDS: false, oversampling: 16, thresholdDB: -1.0),
        ProbeCase(label: "8x oversampling", stereoGuard: 1.0, cancelPilot: true, cancelRDS: true, oversampling: 8, thresholdDB: -1.0),
        ProbeCase(label: "32x oversampling", stereoGuard: 1.0, cancelPilot: true, cancelRDS: true, oversampling: 32, thresholdDB: -1.0),
        ProbeCase(label: "narrow knee (threshold -0.5 dB)", stereoGuard: 1.0, cancelPilot: true, cancelRDS: true, oversampling: 16, thresholdDB: -0.5),
    ]

    @Test(arguments: attributionCases)
    func overshootAttribution(_ c: ProbeCase) {
        let over = Self.firOvershootDB(c)
        print(String(format: "bound probe | %-48@ raw %+5.2f dB  after 55 kHz FIR %+5.2f dB", c.label as NSString, over.raw, over.fir))
        #expect(over.raw.isFinite && over.fir.isFinite)
        #expect(over.raw < 4.1 && over.fir < 4.1, "\(c.label): overshoot ran away (\(over.raw) / \(over.fir) dB)")
    }
}
