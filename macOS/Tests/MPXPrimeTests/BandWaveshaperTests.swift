import Testing
import Foundation
#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
@testable import MPXPrime

// The curve `BassClipper` and `HFClipper` share. Until 0.60 it was
// discontinuous at the threshold -- the output stepped DOWN to tanh(1) =
// 0.7616 of where it was, a 24 % drop, then climbed back toward the same
// ceiling, so it was not monotonic either (0.60 audit, P0-2).
//
// Oversampling reduces alias folding; it cannot repair a discontinuous
// transfer. These tests pin the properties the old one broke, and they are
// the reason to trust the replacement independently of any listening.
@Suite("Band waveshaper")
struct BandWaveshaperTests {

    private let thresholds: [Float] = [0.25, 0.5, 0.8, 1.0]
    private let knees: [Float] = [0.4, 0.6, 0.8, 0.9]

    /// The pre-0.60 curve, for comparison only.
    private func legacy(_ x: Float, threshold: Float) -> Float {
        fabsf(x) <= threshold ? x : copysignf(threshold * tanhf(fabsf(x) / threshold), x)
    }

    @Test func theOldCurveReallyWasDiscontinuous() {
        // Establishes the baseline this replaces: a step down at the join.
        for threshold in thresholds {
            let below = legacy(threshold * 0.999_9, threshold: threshold)
            let above = legacy(threshold * 1.000_1, threshold: threshold)
            let stepDB = 20.0 * log10f(above / below)
            #expect(stepDB < -2.0,
                    "threshold \(threshold): expected a step DOWN, got \(stepDB) dB")
        }
    }

    @Test func theCurveIsContinuousAtTheJoin() {
        for threshold in thresholds {
            for knee in knees {
                let x0 = knee * threshold
                // Straddle the join by a known amount. With unity slope on
                // both sides the output must move by about that same amount;
                // a JUMP is anything much larger. Comparing the raw
                // difference to a fixed epsilon would just measure the slope.
                let delta: Float = 1e-5
                let below = BandWaveshaper.apply(driven: x0 - delta, threshold: threshold, knee: knee)
                let above = BandWaveshaper.apply(driven: x0 + delta, threshold: threshold, knee: knee)
                let excess = abs(above - below) - (2.0 * delta)
                #expect(excess < delta,
                        "threshold \(threshold) knee \(knee): moved \(above - below) across a \(2.0 * delta) input step -- a jump, not a slope")
            }
        }
    }

    @Test func theSlopeIsContinuousAtTheJoin() {
        // The knee must not kink: unity slope below, unity slope just above.
        let h: Float = 1e-4
        for threshold in thresholds {
            for knee in knees {
                let x0 = knee * threshold
                func slope(at x: Float) -> Float {
                    (BandWaveshaper.apply(driven: x + h, threshold: threshold, knee: knee)
                        - BandWaveshaper.apply(driven: x - h, threshold: threshold, knee: knee)) / (2.0 * h)
                }
                let under = slope(at: x0 - (10.0 * h))
                let over = slope(at: x0 + (10.0 * h))
                #expect(abs(under - 1.0) < 0.02, "slope below the knee is \(under), expected 1")
                #expect(abs(over - 1.0) < 0.05, "slope above the knee is \(over), expected ~1")
            }
        }
    }

    @Test func theCurveIsMonotonic() {
        for threshold in thresholds {
            for knee in knees {
                var previous = -Float.infinity
                var x: Float = -4.0
                while x <= 4.0 {
                    let y = BandWaveshaper.apply(driven: x, threshold: threshold, knee: knee)
                    #expect(y >= previous - 1e-6,
                            "threshold \(threshold) knee \(knee): fell from \(previous) to \(y) at x = \(x)")
                    previous = y
                    x += 0.001
                }
            }
        }
    }

    @Test func theCurveIsOddSymmetric() {
        for threshold in thresholds {
            for knee in knees {
                var x: Float = 0.0
                while x <= 4.0 {
                    let positive = BandWaveshaper.apply(driven: x, threshold: threshold, knee: knee)
                    let negative = BandWaveshaper.apply(driven: -x, threshold: threshold, knee: knee)
                    #expect(abs(positive + negative) < 1e-6,
                            "asymmetric at x = \(x): \(positive) vs \(negative)")
                    x += 0.01
                }
            }
        }
    }

    @Test func belowTheKneeIsExactlyUntouched() {
        for threshold in thresholds {
            for knee in knees {
                var x: Float = 0.0
                while x < knee * threshold {
                    #expect(BandWaveshaper.apply(driven: x, threshold: threshold, knee: knee) == x,
                            "altered a sample below the knee at x = \(x)")
                    x += 0.001
                }
            }
        }
    }

    @Test func theAsymptoteIsStillTheThreshold() {
        // The operator's "Threshold" must keep meaning the ceiling, or every
        // shipped setting silently changes meaning.
        for threshold in thresholds {
            for knee in knees {
                let far = BandWaveshaper.apply(driven: 50.0 * threshold, threshold: threshold, knee: knee)
                #expect(far <= threshold + 1e-6, "exceeded the threshold: \(far) > \(threshold)")
                #expect(far > threshold * 0.98,
                        "did not reach the threshold: \(far) vs \(threshold)")
            }
        }
    }

    @Test func everyOutputIsFinite() {
        for threshold in thresholds {
            for knee in knees {
                for x in [Float(0.0), 1e-30, -1e-30, 1e6, -1e6] {
                    let y = BandWaveshaper.apply(driven: x, threshold: threshold, knee: knee)
                    #expect(y.isFinite, "non-finite output \(y) at x = \(x)")
                }
            }
        }
    }

    @Test func splittingTheCurveIntoArgumentAndShapeChangesNothing() {
        // `apply` is `shaped(tanhf(tanhArgument))`; this pins that the split
        // the batched path relies on is exact. It does NOT run the vector
        // path -- the next test does.
        for threshold in thresholds {
            for knee in knees {
                var x: Float = -3.0
                while x <= 3.0 {
                    let argument = BandWaveshaper.tanhArgument(
                        driven: x, threshold: threshold, knee: knee)
                    let combined = BandWaveshaper.shaped(
                        driven: x, tanhValue: tanhf(argument), threshold: threshold, knee: knee)
                    let reference = BandWaveshaper.apply(driven: x, threshold: threshold, knee: knee)
                    #expect(abs(combined - reference) < 1e-6,
                            "batched and scalar disagree at x = \(x)")
                    x += 0.01
                }
            }
        }
    }

    /// The production loops fill an 8-lane batch (4 oversample steps x L+R),
    /// run `vvtanhf` on it and recombine per lane. This runs exactly that
    /// -- the platform's vector tanh, not a scalar stand-in -- on lanes of
    /// mixed sign and amplitude that are all DIFFERENT, so a lane swap,
    /// a sign slip or a short count cannot pass, and compares against the
    /// curve written out from its definition in Double, independent of
    /// `BandWaveshaper`.
    @Test func theVectorisedTanhPathMatchesAnIndependentCurve() {
        for threshold in thresholds {
            for knee in knees {
                let x0 = knee * threshold
                let width = threshold - x0
                let lanes: [Float] = [
                    -0.30 * threshold,          // well below the knee, negative
                    0.95 * x0,                  // just under the knee
                    x0,                         // exactly at the knee
                    -threshold,                 // at the threshold, negative
                    1.5 * threshold,            // over
                    -0.5 * (x0 + threshold),    // inside the knee, negative
                    3.0 * threshold,            // far over
                    -1.01 * x0                  // just inside the knee, negative
                ]
                var arguments = lanes.map {
                    BandWaveshaper.tanhArgument(driven: $0, threshold: threshold, knee: knee)
                }
                var tanhs = [Float](repeating: 0.0, count: lanes.count)
                var n = Int32(lanes.count)
                arguments.withUnsafeMutableBufferPointer { a in
                    tanhs.withUnsafeMutableBufferPointer { t in
                        // swiftlint:disable force_unwrapping
                        vvtanhf(t.baseAddress!, a.baseAddress!, &n)
                        // swiftlint:enable force_unwrapping
                    }
                }
                for (i, x) in lanes.enumerated() {
                    let got = BandWaveshaper.shaped(
                        driven: x, tanhValue: tanhs[i], threshold: threshold, knee: knee)
                    let m = Double(abs(x))
                    let sign: Double = x < 0 ? -1.0 : 1.0
                    let reference: Double = m <= Double(x0)
                        ? Double(x)
                        : sign * (Double(x0) + Double(width) * tanh((m - Double(x0)) / Double(width)))
                    #expect(abs(Double(got) - reference) < 2e-6,
                            "lane \(i) (x = \(x)) got \(got), curve says \(reference) at threshold \(threshold) knee \(knee)")
                }
            }
        }
    }
}
