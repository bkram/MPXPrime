import Accelerate
import Foundation

// MARK: - Sine generation

enum SineGenerator {
    /// Generates a pure mono sine at `freqHz` with the given amplitude.
    /// Phase starts at 0, so `samples[0]` is always 0.
    static func generate(freqHz: Float, amplitude: Float, sampleRate: Float, frameCount: Int) -> [Float] {
        let omega = 2.0 * Double.pi * Double(freqHz) / Double(sampleRate)
        return (0..<frameCount).map { Float(Double(amplitude) * sin(omega * Double($0))) }
    }
}

// MARK: - Spectral analysis

/// Result of an FFT analysis. All magnitudes are reported in dBFS, where
/// 0 dBFS is the FFT bin magnitude produced by a full-scale (amplitude 1.0) sine.
struct SpectralReport {
    let sampleRate: Float
    let binCount: Int
    let binWidthHz: Float
    let magnitudesDBFS: [Float]

    /// dBFS at the bin closest to `freqHz`.
    func dBFSAt(freqHz: Float) -> Float {
        let bin = Int((freqHz / binWidthHz).rounded())
        let safe = max(0, min(binCount - 1, bin))
        return magnitudesDBFS[safe]
    }

    /// Sum of energies (power-domain sum, then converted back to dBFS) at the
    /// bins closest to each `freqHz`, with a small `toleranceHz` window so a
    /// frequency that doesn't fall exactly on a bin still contributes its
    /// neighbouring-bin energy.
    func sumEnergyDBFS(atBins freqsHz: [Float], toleranceHz: Float = 50.0) -> Float {
        var totalPower: Double = 0.0
        for f in freqsHz {
            let centerBin = Int((f / binWidthHz).rounded())
            let radius = max(1, Int((toleranceHz / binWidthHz).rounded()))
            let lo = max(0, centerBin - radius)
            let hi = min(binCount - 1, centerBin + radius)
            for bin in lo...hi {
                let amp = pow(10.0, Double(magnitudesDBFS[bin]) / 20.0)
                totalPower += amp * amp
            }
        }
        let amp = sqrt(totalPower)
        return amp > 1e-30 ? Float(20.0 * log10(amp)) : -200.0
    }

    /// Largest dBFS value within the closed frequency range.
    func peakDBFS(in band: ClosedRange<Float>) -> Float {
        let loBin = max(0, Int((band.lowerBound / binWidthHz).rounded()))
        let hiBin = min(binCount - 1, Int((band.upperBound / binWidthHz).rounded()))
        guard loBin <= hiBin else { return -200.0 }
        return magnitudesDBFS[loBin...hiBin].max() ?? -200.0
    }
}

/// Forward real FFT analyzer with Hann windowing and self-calibrated dBFS
/// reporting (a full-scale unity-amplitude sine reads back as 0 dBFS at its bin).
final class FFTAnalyzer {
    let fftSize: Int
    private let log2N: vDSP_Length
    private let setup: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let dbfsOffset: Float  // adjustment so unit-amplitude sine reads 0 dBFS

    init(fftSize: Int) {
        precondition(fftSize >= 16 && (fftSize & (fftSize - 1)) == 0, "fftSize must be power of 2 and >= 16")
        self.fftSize = fftSize
        self.log2N = vDSP_Length(log2(Double(fftSize)))
        self.setup = vDSP.FFT<DSPSplitComplex>(log2n: log2N, radix: .radix2, ofType: DSPSplitComplex.self)!

        var win = [Float](repeating: 0.0, count: fftSize)
        vDSP_hann_window(&win, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = win

        // Calibrate dBFS: feed in a unit-amplitude sine, measure peak bin, derive
        // an offset so it reads exactly 0 dBFS. This bakes in the FFT scale, the
        // Hann coherent-gain loss, and any other constant factors so we don't
        // have to reason about them in the test code.
        let calSampleRate: Float = 48_000.0
        let calFreq: Float = 1_000.0
        let calSamples = SineGenerator.generate(
            freqHz: calFreq, amplitude: 1.0,
            sampleRate: calSampleRate, frameCount: fftSize
        )
        let rawSpectrum = Self.computeMagnitudesDBFS(
            samples: calSamples,
            window: win,
            log2N: log2N,
            setup: setup,
            offsetDBFS: 0.0  // uncalibrated
        )
        let calBin = Int((calFreq / (calSampleRate / Float(fftSize))).rounded())
        let measuredPeakDBFS = rawSpectrum[max(0, min(rawSpectrum.count - 1, calBin))]
        // measuredPeak should be 0 if calibration is right; offset closes the gap.
        self.dbfsOffset = -measuredPeakDBFS
    }

    func analyze(_ samples: [Float], sampleRate: Float) -> SpectralReport {
        precondition(samples.count >= fftSize, "samples.count (\(samples.count)) must be >= fftSize (\(fftSize))")
        let signal = Array(samples.prefix(fftSize))
        let magsDBFS = Self.computeMagnitudesDBFS(
            samples: signal,
            window: window,
            log2N: log2N,
            setup: setup,
            offsetDBFS: dbfsOffset
        )
        return SpectralReport(
            sampleRate: sampleRate,
            binCount: magsDBFS.count,
            binWidthHz: sampleRate / Float(fftSize),
            magnitudesDBFS: magsDBFS
        )
    }

    private static func computeMagnitudesDBFS(
        samples: [Float],
        window: [Float],
        log2N: vDSP_Length,
        setup: vDSP.FFT<DSPSplitComplex>,
        offsetDBFS: Float
    ) -> [Float] {
        let fftSize = samples.count
        let halfSize = fftSize / 2

        var windowed = [Float](repeating: 0.0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0.0, count: halfSize)
        var imag = [Float](repeating: 0.0, count: halfSize)
        var mags = [Float](repeating: 0.0, count: halfSize)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowedPtr in
                    windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                setup.forward(input: split, output: &split)
                mags.withUnsafeMutableBufferPointer { magsPtr in
                    vDSP_zvmags(&split, 1, magsPtr.baseAddress!, 1, vDSP_Length(halfSize))
                }
            }
        }

        // Convert squared magnitudes to dBFS (with calibration offset applied).
        return mags.map { sq in
            let amp = sqrt(Double(sq))
            return amp > 1e-30 ? Float(20.0 * log10(amp)) + offsetDBFS : -200.0
        }
    }
}
