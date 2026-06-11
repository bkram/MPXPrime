import Accelerate
import Foundation

// Hann-windowed real-input FFT spectrum analyzer (Accelerate-only).
//
// Extracted from SwiftUIControlApp.swift in 0.37 so both the MPX Prime
// transmit GUI and the MPX Prime Meter analyzer share one calibrated
// spectrum path. Pure DSP: no UI, no transmit coupling. The single
// public entry point is `compute(...)`, which maps a real signal to a
// log-magnitude display-bin array with 0 dBFS-sine calibration.
public final class MPXSpectrumAnalyzer: @unchecked Sendable {
    private var fftSetup: FFTSetup?
    private var fftLog2: vDSP_Length = 0
    private var window: [Float] = []
    private var signal: [Float] = []
    private var windowed: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var magnitudesSq: [Float] = []
    private var spectrumDB: [Float] = []
    private var mapped: [Float] = []

    public init() {}

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    public func compute(
        samples: [Float],
        validCount: Int,
        sampleRate: Double,
        displayBins: Int,
        maxDisplayHz: Double
    ) -> (dbBins: [Float], maxHz: Double, nyquistHz: Double) {
        let safeBins = max(64, displayBins)
        let nyquist = max(1_000.0, sampleRate * 0.5)
        let maxHz = max(1_000.0, maxDisplayHz)
        let sampleCount = min(samples.count, max(0, validCount))
        guard sampleCount >= 256 else {
            return (Array(repeating: -100.0, count: safeBins), maxHz, nyquist)
        }

        let maxFFTSize = min(sampleCount, 8192)
        let log2n = Int(floor(log2(Double(maxFFTSize))))
        let n = max(256, 1 << log2n)
        prepareBuffers(fftSize: n, displayBins: safeBins)

        signal.withUnsafeMutableBufferPointer { buffer in
            samples.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress, let destinationBase = buffer.baseAddress else { return }
                let start = sampleCount - n
                destinationBase.update(from: sourceBase.advanced(by: start), count: n)
            }
        }

        var mean: Float = 0.0
        vDSP_meanv(signal, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        vDSP_vsadd(signal, 1, &negMean, &signal, 1, vDSP_Length(n))
        vDSP_vmul(signal, 1, window, 1, &windowed, 1, vDSP_Length(n))

        guard let fftSetup else {
            return (Array(repeating: -100.0, count: safeBins), maxHz, nyquist)
        }

        real.withUnsafeMutableBufferPointer { realBP in
            imag.withUnsafeMutableBufferPointer { imagBP in
                // baseAddress is non-nil for non-empty pre-allocated arrays.
                // swiftlint:disable force_unwrapping
                var split = DSPSplitComplex(realp: realBP.baseAddress!, imagp: imagBP.baseAddress!)
                windowed.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexSrc in
                        vDSP_ctoz(complexSrc, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                // swiftlint:enable force_unwrapping
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2, FFTDirection(FFT_FORWARD))
                // Apple's real-input FFT packs DC into split.realp[0]
                // and Nyquist into split.imagp[0] to save one slot.
                // Without untangling them, vDSP_zvmags would compute
                // magnitudesSq[0] = DC² + Nyquist² and the leftmost
                // display bin would render Nyquist energy (because we
                // already remove DC pre-FFT via vDSP_meanv + vDSP_vsadd).
                // Zero the Nyquist slot before the magnitude pass so
                // bin 0 holds clean DC². Nyquist is ignored for display
                // — the highest visible bin is at index n/2-1, just
                // below Nyquist.
                imagBP[0] = 0
                vDSP_zvmags(&split, 1, &magnitudesSq, 1, vDSP_Length(n / 2))
            }
        }

        // Calibrated amplitude: divide by N (FFT length) to undo the
        // un-normalised forward transform, then divide by the window's
        // coherent gain so a 0 dBFS sine through a Hann window reads as
        // 0 dB on the display. vDSP_HANN_NORM produces a normalised
        // Hann window with sum = N/2, i.e. coherent gain = 0.5. The
        // factor of 2 on non-DC bins accounts for the one-sided
        // spectrum (energy from the conjugate bin).
        let invN = 1.0 / Float(n)
        let hannCG: Float = 0.5
        let cgScale = invN / hannCG
        if !magnitudesSq.isEmpty {
            let dcAmp = sqrtf(max(0.0, magnitudesSq[0])) * cgScale
            spectrumDB[0] = max(-100.0, min(0.0, 20.0 * log10f(max(1e-9, dcAmp))))
        }
        if magnitudesSq.count > 1 {
            for k in 1..<magnitudesSq.count {
                let amp = (2.0 * sqrtf(max(0.0, magnitudesSq[k]))) * cgScale
                spectrumDB[k] = max(-100.0, min(0.0, 20.0 * log10f(max(1e-9, amp))))
            }
        }

        let sourceCount = max(1, spectrumDB.count)
        for i in 0..<safeBins {
            let ratio = safeBins > 1 ? (Double(i) / Double(safeBins - 1)) : 0.0
            let freq = ratio * maxHz
            if freq > nyquist {
                mapped[i] = -100.0
                continue
            }
            let srcPos = (freq / nyquist) * Double(sourceCount - 1)
            let i0 = max(0, min(sourceCount - 1, Int(srcPos.rounded(.down))))
            let i1 = max(0, min(sourceCount - 1, i0 + 1))
            let frac = Float(srcPos - Double(i0))
            let a = spectrumDB[i0]
            let b = spectrumDB[i1]
            mapped[i] = a + ((b - a) * frac)
        }
        return (mapped, maxHz, nyquist)
    }

    private func prepareBuffers(fftSize: Int, displayBins: Int) {
        let requiredLog2 = vDSP_Length(log2(Double(fftSize)))
        if fftLog2 != requiredLog2 || fftSetup == nil {
            if let fftSetup {
                vDSP_destroy_fftsetup(fftSetup)
            }
            fftSetup = vDSP_create_fftsetup(requiredLog2, FFTRadix(kFFTRadix2))
            fftLog2 = requiredLog2
        }

        if window.count != fftSize {
            window = Array(repeating: 0.0, count: fftSize)
            signal = Array(repeating: 0.0, count: fftSize)
            windowed = Array(repeating: 0.0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        }

        let halfSize = fftSize / 2
        if real.count != halfSize {
            real = Array(repeating: 0.0, count: halfSize)
            imag = Array(repeating: 0.0, count: halfSize)
            magnitudesSq = Array(repeating: 0.0, count: halfSize)
            spectrumDB = Array(repeating: -100.0, count: halfSize)
        }

        if mapped.count != displayBins {
            mapped = Array(repeating: -100.0, count: displayBins)
        }
    }
}
