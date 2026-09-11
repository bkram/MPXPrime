import Testing
import Foundation
import MPXPrimeCore
@testable import MPXPrime

// AM pre-emphasis is NRSC-1-C, which is NOT the FM 75 us curve. The standard
// specifies a MODIFIED 75 us characteristic: a zero at 1 / (2 pi 75 us) =
// 2122.07 Hz and a pole at 8700 Hz, so the boost levels off inside the AM
// channel instead of climbing at 6 dB/octave forever. Its published table
// reaches exactly +10.00 dB at 10 kHz.
//
// Until 0.60 `am_preemphasis_us = 75` was handed to the FM network, which is
// 3.66 dB hotter at 10 kHz and diverging; the monitor removed the FM curve
// too, and the calibration tone was compensated with it. The test that was
// supposed to cover this asserted the FM numbers and called them NRSC
// (0.60 audit, P0-7).
@Suite("NRSC-1 AM pre-emphasis")
struct NRSCPreemphasisTests {

    /// The standard's own anchor points, in dB relative to DC. Independent of
    /// our implementation: computed from the published zero/pole, and the
    /// 10 kHz entry is the figure NRSC-1-C tabulates.
    private static let table: [(hz: Double, dB: Double)] = [
        (50, 0.002), (100, 0.009), (200, 0.036), (500, 0.220),
        (1_000, 0.814), (2_000, 2.537), (3_000, 4.281), (4_000, 5.750),
        (5_000, 6.924), (6_000, 7.850), (7_000, 8.581), (8_000, 9.161),
        (9_000, 9.625), (10_000, 9.999),
    ]

    /// |H(e^jw)| of a designed biquad, in dB.
    private func responseDB(_ d: PreemphasisDesign, hz: Double, sampleRate: Double) -> Double {
        let w = 2.0 * Double.pi * hz / sampleRate
        let c1 = cos(w), s1 = sin(w)
        let c2 = cos(2.0 * w), s2 = sin(2.0 * w)
        let numRe = d.b0 + (d.b1 * c1) + (d.b2 * c2)
        let numIm = -((d.b1 * s1) + (d.b2 * s2))
        let denRe = 1.0 + (d.a1 * c1) + (d.a2 * c2)
        let denIm = -((d.a1 * s1) + (d.a2 * s2))
        let num = (numRe * numRe) + (numIm * numIm)
        let den = max(1e-300, (denRe * denRe) + (denIm * denIm))
        return 10.0 * log10(max(1e-300, num / den))
    }

    // MARK: - The curve itself

    @Test func theAnalogOracleMatchesTheStandardsTable() {
        // The oracle every other test compares against, checked against the
        // published figures rather than against our own filter.
        for point in Self.table {
            let got = PreemphasisDesign.nrscGainDB(frequencyHz: point.hz)
            #expect(abs(got - point.dB) < 0.01,
                    "NRSC-1 at \(Int(point.hz)) Hz is \(got) dB, the standard says \(point.dB) dB")
        }
        #expect(abs(PreemphasisDesign.nrscGainDB(frequencyHz: 10_000.0) - 10.0) < 0.01,
                "the standard's anchor point is +10.00 dB at 10 kHz")
    }

    @Test func theDesignedFilterFollowsTheStandardAtEveryRate() {
        for sampleRate in [48_000.0, 96_000.0, 192_000.0] {
            let design = PreemphasisDesign.nrsc(sampleRate: sampleRate)
            for point in Self.table where point.hz < 0.45 * sampleRate {
                let got = responseDB(design, hz: point.hz, sampleRate: sampleRate)
                #expect(abs(got - point.dB) < 0.1,
                        """
                        \(Int(sampleRate)) Hz design reads \(got) dB at \(Int(point.hz)) Hz, \
                        the standard says \(point.dB) dB
                        """)
            }
        }
    }

    @Test func theCurveIsNotTheFMSeventyFiveMicrosecondOne() {
        // The whole point of the pole. If these ever agree, the AM path has
        // silently gone back to the FM network.
        let nrsc = PreemphasisDesign.nrscGainDB(frequencyHz: 10_000.0)
        let fm = PreemphasisDesign.analogGainDB(frequencyHz: 10_000.0, tau: 75e-6)
        #expect(fm - nrsc > 3.0,
                "FM 75 us and NRSC-1 differ by only \(fm - nrsc) dB at 10 kHz")
        // ... and they must agree low down, where the pole does nothing.
        let nrscLow = PreemphasisDesign.nrscGainDB(frequencyHz: 300.0)
        let fmLow = PreemphasisDesign.analogGainDB(frequencyHz: 300.0, tau: 75e-6)
        #expect(abs(fmLow - nrscLow) < 0.05,
                "the two curves should be indistinguishable at 300 Hz")
    }

    // MARK: - The filters

    @Test func preEmphasisThenDeEmphasisIsFlat() {
        for sampleRate in [Float(48_000.0), Float(96_000.0), Float(192_000.0)] {
            var pre = PreemphasisFilter()
            var de = DeemphasisFilter()
            pre.configure(curve: .nrsc, sampleRate: sampleRate)
            de.configure(curve: .nrsc, sampleRate: sampleRate)
            // An impulse through both must come back out as an impulse.
            var worst: Float = 0.0
            for i in 0..<2_048 {
                let x: Float = i == 0 ? 1.0 : 0.0
                let y = de.process(pre.process(x))
                worst = max(worst, abs(y - x))
            }
            #expect(worst < 1e-3,
                    "the NRSC cascade is not flat at \(Int(sampleRate)) Hz: worst deviation \(worst)")
        }
    }

    @Test func theFilterReproducesTheDesignOnRealSignal() {
        // Drive the actual filter with tones and measure, in case the
        // coefficients are transcribed wrongly into Float.
        let sampleRate: Float = 48_000.0
        for point in Self.table where point.hz >= 500.0 && point.hz <= 9_000.0 {
            var pre = PreemphasisFilter()
            pre.configure(curve: .nrsc, sampleRate: sampleRate)
            let frames = 24_000
            let skip = 4_000
            let span = Double(frames - skip)
            let bin = max(1.0, (span * point.hz / Double(sampleRate)).rounded())
            let tone = bin * Double(sampleRate) / span
            var out = [Float](repeating: 0.0, count: frames)
            for i in 0..<frames {
                let s = Float(0.05 * sin(2.0 * Double.pi * tone * Double(i) / Double(sampleRate)))
                out[i] = pre.process(s)
            }
            // Goertzel on the settled part.
            let k = bin
            let omega = 2.0 * Double.pi * k / span
            let coeff = 2.0 * cos(omega)
            var s1 = 0.0, s2 = 0.0
            for i in 0..<Int(span) {
                let s0 = coeff * s1 - s2 + Double(out[skip + i])
                s2 = s1
                s1 = s0
            }
            let real = s1 - s2 * cos(omega)
            let imag = s2 * sin(omega)
            let level = sqrt(real * real + imag * imag) / span * 2.0
            let gotDB = 20.0 * log10(level / 0.05)
            let wantDB = PreemphasisDesign.nrscGainDB(frequencyHz: tone)
            #expect(abs(gotDB - wantDB) < 0.15,
                    "filter reads \(gotDB) dB at \(Int(tone)) Hz, design says \(wantDB) dB")
        }
    }

    @Test func noCurveIsAnExactPassThrough() {
        var pre = PreemphasisFilter()
        var de = DeemphasisFilter()
        pre.configure(curve: .none, sampleRate: 48_000.0)
        de.configure(curve: .none, sampleRate: 48_000.0)
        for i in 0..<64 {
            let x = Float(sin(Double(i) * 0.3))
            #expect(pre.process(x) == x)
            #expect(de.process(x) == x)
        }
    }

    @Test func theFMPathIsUnchangedByTheCurveVocabulary() {
        // `configure(tauUS:)` must still mean exactly what it did, or every
        // FM baseline moves.
        for tau in [50, 75] {
            for rate in [Float(48_000.0), Float(192_000.0)] {
                var byTau = PreemphasisFilter()
                var byCurve = PreemphasisFilter()
                byTau.configure(tauUS: tau, sampleRate: rate)
                byCurve.configure(curve: .fm(tauUS: tau), sampleRate: rate)
                for i in 0..<512 {
                    let x = Float(sin(Double(i) * 0.11))
                    #expect(byTau.process(x) == byCurve.process(x),
                            "tau \(tau) at \(Int(rate)) Hz diverged at sample \(i)")
                }
            }
        }
    }
}
