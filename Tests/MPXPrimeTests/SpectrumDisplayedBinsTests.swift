import Foundation
import Testing

@testable import MPXPrimeCore

// MPXSpectrumAnalyzer converts to dB only the FFT bins the display mapping
// can read (the Audio Spectrum shows 16 kHz of a 96 kHz Nyquist, so ~83 % of
// the log10 work per 16384-point FFT went nowhere). The displayed result
// must be bit-identical to converting every bin.
@Suite struct SpectrumDisplayedBinsTests {
    private func signal(count: Int, sampleRate: Double) -> [Float] {
        // A few tones across the band plus a deterministic noise floor, so
        // every display bin has a different value.
        var state: UInt32 = 0x1234_5678
        return (0..<count).map { i in
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = (Float(state >> 8) / Float(1 << 24) - 0.5) * 1e-3
            let t = Double(i) / sampleRate
            let tones = 0.5 * sin(2 * .pi * 1_000 * t) + 0.2 * sin(2 * .pi * 9_700 * t)
                + 0.1 * sin(2 * .pi * 15_900 * t) + 0.05 * sin(2 * .pi * 38_000 * t)
            return Float(tones) + noise
        }
    }

    private func bothWays(
        sampleRate: Double, count: Int, displayBins: Int, maxDisplayHz: Double, fftCap: Int
    ) -> (limited: [Float], full: [Float]) {
        let samples = signal(count: count, sampleRate: sampleRate)
        let limited = MPXSpectrumAnalyzer()
        let full = MPXSpectrumAnalyzer()
        full.convertsOnlyDisplayedBins = false
        let a = limited.compute(
            samples: samples, validCount: count, sampleRate: sampleRate,
            displayBins: displayBins, maxDisplayHz: maxDisplayHz, maxFFTSize: fftCap)
        let b = full.compute(
            samples: samples, validCount: count, sampleRate: sampleRate,
            displayBins: displayBins, maxDisplayHz: maxDisplayHz, maxFFTSize: fftCap)
        #expect(a.maxHz == b.maxHz)
        #expect(a.nyquistHz == b.nyquistHz)
        return (a.dbBins, b.dbBins)
    }

    @Test func audioSpectrumIsUnchanged() {
        // The Audio Spectrum window: 16384-point FFT, 16 kHz of 96 kHz.
        let r = bothWays(sampleRate: 192_000, count: 16_384, displayBins: 128,
                         maxDisplayHz: 16_000, fftCap: 16_384)
        #expect(r.limited == r.full)
        let r48 = bothWays(sampleRate: 48_000, count: 8_192, displayBins: 128,
                           maxDisplayHz: 16_000, fftCap: 8_192)
        #expect(r48.limited == r48.full)
    }

    @Test func mpxSpectrumIsUnchanged() {
        // MPX Spectrum window and /api/telemetry: 4096 points, up to 96 kHz
        // (the whole band, and past Nyquist at 96 kHz).
        for (rate, maxHz) in [(192_000.0, 96_000.0), (192_000.0, 60_000.0), (96_000.0, 96_000.0)] {
            let r = bothWays(sampleRate: rate, count: 4_096, displayBins: 512,
                             maxDisplayHz: maxHz, fftCap: 8_192)
            #expect(r.limited == r.full, "rate \(rate) max \(maxHz)")
        }
    }

    @Test func aWiderDisplayAfterANarrowOneIsUnchanged() {
        // Reusing one analyzer from a narrow display to a wide one must not
        // read bins the narrow call left unconverted.
        let samples = signal(count: 4_096, sampleRate: 192_000)
        let reused = MPXSpectrumAnalyzer()
        _ = reused.compute(samples: samples, validCount: 4_096, sampleRate: 192_000,
                           displayBins: 128, maxDisplayHz: 16_000)
        let wide = reused.compute(samples: samples, validCount: 4_096, sampleRate: 192_000,
                                  displayBins: 512, maxDisplayHz: 96_000)
        let fresh = MPXSpectrumAnalyzer()
        fresh.convertsOnlyDisplayedBins = false
        let reference = fresh.compute(samples: samples, validCount: 4_096, sampleRate: 192_000,
                                      displayBins: 512, maxDisplayHz: 96_000)
        #expect(wide.dbBins == reference.dbBins)
    }
}
