import Testing
import Foundation
@testable import MPXPrime

// Verifies the TX-path linear-phase FIR program lowpass delivers the
// stop-band attenuation it claims. Compared against the default Butterworth
// cascade to document the quality gap and guard against regressions in
// either filter.

@Suite("Encoder bandwidth")
struct EncoderBandwidthTests {

    private let sampleRate: Float = 192_000.0
    private let fftSize: Int = 16_384
    // Feed long enough that the FIR group delay doesn't bias results.
    private let warmupFrames: Int = 4_096

    /// Process a single sine tone through the TX-path encoder filter stack
    /// alone and return the spectrum of the output. Uses the standalone
    /// filter struct (no MPXGenerator chain) so we measure the filter's
    /// intrinsic response without AGC, dynamics, or encoding artefacts.
    private func filterTone(
        freq: Float,
        amplitude: Float,
        useFIR: Bool
    ) -> SpectralReport {
        let totalFrames = warmupFrames + fftSize
        var samples = [Float](repeating: 0.0, count: totalFrames)
        let omega = 2.0 * Double.pi * Double(freq) / Double(sampleRate)
        for i in 0..<totalFrames {
            samples[i] = Float(Double(amplitude) * sin(omega * Double(i)))
        }

        if useFIR {
            var fir = LinearPhaseFIRLowpass()
            fir.configure(cutoffHz: 15_000.0, sampleRate: sampleRate)
            var filtered = [Float](repeating: 0.0, count: totalFrames)
            for i in 0..<totalFrames {
                let out = fir.process(left: samples[i], right: samples[i])
                filtered[i] = out.0
            }
            let tail = Array(filtered[warmupFrames..<totalFrames])
            return FFTAnalyzer(fftSize: fftSize).analyze(tail, sampleRate: sampleRate)
        } else {
            var bw = ProgramLowpass()
            bw.configure(cutoffHz: 15_000.0, sampleRate: sampleRate)
            var filtered = [Float](repeating: 0.0, count: totalFrames)
            for i in 0..<totalFrames {
                let out = bw.process(left: samples[i], right: samples[i])
                filtered[i] = out.0
            }
            let tail = Array(filtered[warmupFrames..<totalFrames])
            return FFTAnalyzer(fftSize: fftSize).analyze(tail, sampleRate: sampleRate)
        }
    }

    // MARK: - FIR characterization

    @Test func firPassesContentBelowCutoff() {
        let report = filterTone(freq: 10_000.0, amplitude: 0.5, useFIR: true)
        let db = report.peakDBFS(in: 9_500...10_500)
        // 0.5 amplitude -> -6 dBFS nominal; filter should not attenuate.
        #expect(db > -8.0, "FIR at 10 kHz measured \(db) dBFS, expected >-8 dB (roughly -6 dB for 0.5 amp minus small measurement error)")
    }

    @Test func firReachesDeepStopBandAt17kHz() {
        let report = filterTone(freq: 17_000.0, amplitude: 0.5, useFIR: true)
        let db = report.peakDBFS(in: 16_500...17_500)
        // Target: >=70 dB below pass-band (the design aims for 82 dB, but
        // Kaiser ripple + FFT leakage can shave a few dB in this measurement).
        #expect(db < -70.0, "FIR at 17 kHz measured \(db) dBFS, expected <-70 dB")
    }

    @Test func firReachesDeepStopBandAt19kHz() {
        // 19 kHz is where the pilot sits. The TX filter must not let audio
        // program bleed into the pilot band.
        let report = filterTone(freq: 19_000.0, amplitude: 0.5, useFIR: true)
        let db = report.peakDBFS(in: 18_500...19_500)
        #expect(db < -78.0, "FIR at 19 kHz (pilot band) measured \(db) dBFS, expected <-78 dB")
    }

    // MARK: - Butterworth characterization (baseline)

    @Test func butterworthIsShallowAboveCutoff() {
        // Document the baseline: the Butterworth cascade at 15 kHz cutoff has
        // roughly 13 dB of rolloff at 17 kHz (12th-order / 72 dB/octave over
        // ~0.18 octaves). The FIR's stop-band is another ~60 dB deeper. If
        // this number jumps past -40 dB it'd mean the Butterworth was
        // replaced with something much steeper (and we'd lose the
        // intentional low-latency property).
        let report = filterTone(freq: 17_000.0, amplitude: 0.5, useFIR: false)
        let db = report.peakDBFS(in: 16_500...17_500)
        #expect(db > -40.0 && db < -8.0,
            "Butterworth at 17 kHz measured \(db) dBFS, expected in (-40..-8) dB — below -40 means the baseline filter changed")
    }

    @Test func firIsDeeperThanButterworthBy20dBOrMore() {
        // The headline regression guard: if the FIR is ever silently swapped
        // out for the Butterworth, or its design parameters are loosened,
        // this delta collapses and the test fails.
        let firDB = filterTone(freq: 17_500.0, amplitude: 0.5, useFIR: true)
            .peakDBFS(in: 17_000...18_000)
        let bwDB = filterTone(freq: 17_500.0, amplitude: 0.5, useFIR: false)
            .peakDBFS(in: 17_000...18_000)
        let delta = bwDB - firDB
        #expect(delta > 20.0,
            "FIR attenuation \(firDB) dBFS vs Butterworth \(bwDB) dBFS — FIR should be >=20 dB deeper in the stop-band")
    }

    // MARK: - Design metadata

    @Test func firGroupDelayReflectsConfiguration() {
        var fir = LinearPhaseFIRLowpass()
        fir.configure(cutoffHz: 15_000.0, sampleRate: 192_000.0)
        let delaySamples = fir.groupDelaySamples
        let delaySeconds = Double(delaySamples) / 192_000.0
        // Sanity range: Kaiser-windowed FIR for ~80 dB and ~1.5 kHz
        // transition should land in the 0.8-3.0 ms range. A result outside
        // this range usually means the design parameters drifted.
        #expect(delaySeconds > 0.0008 && delaySeconds < 0.003,
            "FIR group delay \(delaySeconds * 1000) ms outside expected 0.8-3.0 ms range")
    }

    @Test func firTapCountIsOdd() {
        var fir = LinearPhaseFIRLowpass()
        fir.configure(cutoffHz: 15_000.0, sampleRate: 192_000.0)
        #expect(fir.tapCount % 2 == 1, "Symmetric linear-phase FIR requires odd tap count; got \(fir.tapCount)")
    }

    @Test func firAdaptsTapCountToSampleRate() {
        // Lower sample rates have wider normalized transition bands and need
        // fewer taps for the same stop-band attenuation. This isn't a strict
        // numeric test; it documents that the design is rate-aware and
        // catches a "hardcoded length" regression.
        var low = LinearPhaseFIRLowpass()
        low.configure(cutoffHz: 15_000.0, sampleRate: 48_000.0)
        var high = LinearPhaseFIRLowpass()
        high.configure(cutoffHz: 15_000.0, sampleRate: 192_000.0)
        #expect(high.tapCount > low.tapCount,
            "192 kHz filter has \(high.tapCount) taps; 48 kHz has \(low.tapCount). Higher sample rate should need more taps.")
    }
}
