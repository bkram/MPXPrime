import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// FM pre-/de-emphasis. The encoder's PreemphasisFilter is a biquad fitted to
// the ANALOG network |1 + j omega tau| (a real receiver de-emphasises with the
// analog curve, so any digital approximation error goes on air as a response
// error); the decoder's DeemphasisFilter is its exact inverse, so the cascade
// is identity and both sit on the analog curve. Both are unity at DC and the
// 50/75 us time constant sets the HF boost (+10.3 dB at 10 kHz for 50 us).

@Suite("Pre/de-emphasis filters")
struct PreemphasisFilterTests {

    private let sampleRate: Float = 192_000.0

    /// Steady-state amplitude of a unit sine through `filter` at `freq`:
    /// sin/cos projection over the second half of the render (leakage-free
    /// enough at 2^15 samples for a 0.01 dB comparison).
    private func projectedAmplitude(process: (Float) -> Float, freq: Float, sampleRate: Float) -> Float {
        let total = 1 << 16
        let start = total / 2
        let omega = 2.0 * Double(Float.pi) * Double(freq) / Double(sampleRate)
        var s = 0.0, c = 0.0
        for i in 0..<total {
            let y = Double(process(sinf(Float(omega * Double(i)))))
            if i >= start {
                s += y * sin(omega * Double(i))
                c += y * cos(omega * Double(i))
            }
        }
        let scale = 2.0 / Double(total - start)
        return Float(hypot(s * scale, c * scale))
    }

    private func measurePre(tauUS: Int, freq: Float, sampleRate: Float? = nil) -> Float {
        let sr = sampleRate ?? self.sampleRate
        var f = PreemphasisFilter()
        f.configure(tauUS: tauUS, sampleRate: sr)
        return projectedAmplitude(process: { f.process($0) }, freq: freq, sampleRate: sr)
    }

    private func measureDe(tauUS: Int, freq: Float) -> Float {
        var f = DeemphasisFilter()
        f.configure(tauUS: tauUS, sampleRate: sampleRate)
        return projectedAmplitude(process: { f.process($0) }, freq: freq, sampleRate: sampleRate)
    }

    private func dB(_ ratio: Float) -> Float { 20.0 * log10f(max(1e-9, ratio)) }

    private func analogDB(tauUS: Int, freq: Float) -> Float {
        Float(PreemphasisDesign.analogGainDB(frequencyHz: Double(freq), tau: Double(tauUS) * 1e-6))
    }

    @Test func preEmphasisBoostsHighFrequencies() {
        let low = measurePre(tauUS: 50, freq: 1_000.0)
        let high = measurePre(tauUS: 50, freq: 10_000.0)
        let boost = dB(high) - dB(low)
        // Analytic: +0.4 dB at 1 kHz, +10.3 dB at 10 kHz -> +9.9 dB difference.
        #expect(boost > 6.0, "50 us pre-emphasis 10 kHz vs 1 kHz boost was \(boost) dB, expected > 6")
    }

    /// The on-air contract: at the 48 kHz audio-domain rate the filter must
    /// sit on the analog curve to 0.1 dB across the program band. The
    /// matched-z single zero it replaced was -0.62 dB at 10 kHz and -1.43 dB
    /// at 15 kHz here (fine at 192 kHz, a receiver-side HF droop at 48 kHz).
    @Test func matchesTheAnalogCurveAtTheAudioDomainRate() {
        for tau in [50, 75] {
            for (rate, freqs) in [(48_000.0 as Float, [1_000.0, 5_000.0, 10_000.0, 13_000.0, 15_000.0] as [Float]),
                                  (192_000.0 as Float, [1_000.0, 10_000.0, 15_000.0] as [Float])] {
                for f in freqs {
                    let measured = dB(measurePre(tauUS: tau, freq: f, sampleRate: rate))
                    let analog = analogDB(tauUS: tau, freq: f)
                    #expect(abs(measured - analog) < 0.1,
                        "\(tau) us @ \(Int(rate)) Hz: \(Int(f)) Hz measured \(measured) dB vs analog \(analog) dB")
                }
            }
        }
    }

    @Test func designFallsBackToMatchedZWhenTheFitCannotImprove() {
        // The fit must never return something unstable or worse than the
        // classic network. At 8 kHz Nyquist is inside the program band; the
        // design still has to be stable, minimum-phase and at least as close
        // to the analog curve as matched-z on its own grid.
        for rate in [8_000.0, 44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let fitted = PreemphasisDesign.fit(tau: 50e-6, sampleRate: rate)
            let classic = PreemphasisDesign.matchedZ(tau: 50e-6, sampleRate: rate)
            #expect(fitted.maxErrorDB <= classic.maxErrorDB + 1e-9,
                "fit at \(rate) Hz is worse than matched-z: \(fitted.maxErrorDB) vs \(classic.maxErrorDB) dB")
            #expect(abs(fitted.a2) < 1.0 && abs(fitted.a1) < 1.0 + fitted.a2, "unstable poles at \(rate) Hz")
            #expect(abs(fitted.b0 + fitted.b1 + fitted.b2 - (1.0 + fitted.a1 + fitted.a2)) < 1e-9, "DC gain != 1 at \(rate) Hz")
        }
        // At the two rates that matter the residual is far inside 0.1 dB.
        #expect(PreemphasisDesign.fit(tau: 50e-6, sampleRate: 48_000.0).maxErrorDB < 0.05)
        #expect(PreemphasisDesign.fit(tau: 75e-6, sampleRate: 48_000.0).maxErrorDB < 0.05)
    }

    @Test func deEmphasisCutsHighFrequencies() {
        let low = measureDe(tauUS: 50, freq: 1_000.0)
        let high = measureDe(tauUS: 50, freq: 10_000.0)
        let cut = dB(low) - dB(high)
        #expect(cut > 6.0, "50 us de-emphasis 10 kHz vs 1 kHz cut was \(cut) dB, expected > 6")
    }

    @Test func sevenFiveBoostsMoreThanFifty() {
        // 75 us has a lower corner (2123 Hz vs 3183 Hz) -> more boost at 10 kHz.
        let boost50 = dB(measurePre(tauUS: 50, freq: 10_000.0))
        let boost75 = dB(measurePre(tauUS: 75, freq: 10_000.0))
        #expect(boost75 > boost50, "75 us boost (\(boost75) dB) should exceed 50 us (\(boost50) dB) at 10 kHz")
    }

    @Test func preThenDeReconstructsInput() {
        // The decoder's de-emphasis is the algebraic inverse of the encoder's
        // pre-emphasis, so after the transient decays the cascade tracks the
        // input to float precision -- at the MPX rate and at the audio rate.
        for sr in [192_000.0, 48_000.0] as [Float] {
            var pre = PreemphasisFilter()
            var de = DeemphasisFilter()
            pre.configure(tauUS: 50, sampleRate: sr)
            de.configure(tauUS: 50, sampleRate: sr)
            let omega = 2.0 * Float.pi * 5_000.0 / sr
            var maxErr: Float = 0.0
            for i in 0..<8192 {
                let x = sinf(omega * Float(i))
                let y = de.process(pre.process(x))
                if i >= 4096 { maxErr = max(maxErr, abs(y - x)) }
            }
            #expect(maxErr < 1e-3, "pre->de cascade at \(Int(sr)) Hz should reconstruct input; max error \(maxErr)")
        }
    }

    @Test func deEmphasisMatchesTheAnalogCurve() {
        // The Meter and the verifier de-emphasise with this filter; it has to
        // sit on 1 / |1 + j omega tau| like a receiver's network does. The
        // matched-z pole it replaced was +0.09 dB high at 15 kHz even at
        // 192 kHz (and +1.4 dB at 48 kHz).
        for (rate, freqs) in [(192_000.0 as Float, [1_000.0, 10_000.0, 15_000.0] as [Float]),
                              (48_000.0 as Float, [1_000.0, 10_000.0, 15_000.0] as [Float])] {
            for f in freqs {
                var de = DeemphasisFilter()
                de.configure(tauUS: 50, sampleRate: rate)
                let measured = dB(projectedAmplitude(process: { de.process($0) }, freq: f, sampleRate: rate))
                let analog = -analogDB(tauUS: 50, freq: f)
                #expect(abs(measured - analog) < 0.1,
                    "de-emphasis @ \(Int(rate)) Hz: \(Int(f)) Hz measured \(measured) dB vs analog \(analog) dB")
            }
        }
    }

    @Test func disabledFiltersPassThrough() {
        var pre = PreemphasisFilter()
        var de = DeemphasisFilter()
        pre.configure(tauUS: 0, sampleRate: sampleRate)
        de.configure(tauUS: 0, sampleRate: sampleRate)
        #expect(!pre.enabled)
        #expect(!de.enabled)
        for x in [Float(-0.7), 0.0, 0.3, 0.95] {
            #expect(pre.process(x) == x)
            #expect(de.process(x) == x)
        }
    }
}
