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
    @Test func guardCancellationLeavesInBandOvershootForTheLimiter() {
        let sampleRate: Float = 192_000.0
        var clipper = CompositeClipper()
        clipper.configure(sampleRate: sampleRate, thresholdDB: -1.0, ceilingDB: -0.3,
                          cancelAudio: false, cancelStereo: true, cancelPilot: true, cancelRDS: true,
                          lookaheadMS: 0.0, oversamplingFactor: 16)
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
        #expect(rawPeak > ceiling * 1.05, "clipper raw peak \(rawPeak) vs ceiling \(ceiling)")
        #expect(firPeak > ceiling * 1.05, "the overshoot is in-band: FIR peak \(firPeak) vs ceiling \(ceiling)")
        #expect(rawPeak < 1.6, "overshoot should stay a fraction of the ceiling, not run away")
    }
}
