import Foundation
@testable import MPXPrime

// MARK: - Stereo nonlinearity protocol

/// A minimal protocol covering any stereo-input/stereo-output sample-rate
/// nonlinear block. The probe rig drives blocks through this protocol so a
/// single rig can measure any clipper, limiter, or saturator.
protocol StereoNonlinearity {
    mutating func process(left: Float, right: Float) -> (Float, Float)
}

extension DistortionCancelledClipper: StereoNonlinearity {}
extension BassClipper: StereoNonlinearity {}

// MARK: - Probe rig

enum NonlinearityProbe {
    /// Drive `block` with a mono sine on both L and R channels, capture the
    /// steady-state output, and return its spectrum.
    ///
    /// - `frameCount`: total samples generated. The first `skipTransient`
    ///   are dropped to let internal filters reach steady state.
    /// - `fftSize`: size of the analysis window. Must be a power of 2 and
    ///   `<= frameCount - skipTransient`.
    static func runMonoTone<Block: StereoNonlinearity>(
        block: inout Block,
        freqHz: Float,
        amplitude: Float,
        sampleRate: Float,
        frameCount: Int = 65_536,
        skipTransient: Int = 4_096,
        fftSize: Int = 16_384
    ) -> SpectralReport {
        precondition(skipTransient + fftSize <= frameCount,
                     "frameCount must be >= skipTransient + fftSize")
        let input = SineGenerator.generate(
            freqHz: freqHz, amplitude: amplitude,
            sampleRate: sampleRate, frameCount: frameCount
        )
        var output = [Float](repeating: 0.0, count: frameCount)
        for i in 0..<frameCount {
            let (l, _) = block.process(left: input[i], right: input[i])
            // L and R are driven identically, so only L is needed for analysis.
            output[i] = l
        }
        let analysis = FFTAnalyzer(fftSize: fftSize)
        let steadyState = Array(output[skipTransient..<(skipTransient + fftSize)])
        return analysis.analyze(steadyState, sampleRate: sampleRate)
    }

    /// Same as `runMonoTone` but returns the raw output samples too, so a test
    /// can check time-domain properties (peak, RMS, exact passthrough) without
    /// re-running the block.
    static func captureMonoTone<Block: StereoNonlinearity>(
        block: inout Block,
        freqHz: Float,
        amplitude: Float,
        sampleRate: Float,
        frameCount: Int = 65_536,
        skipTransient: Int = 4_096,
        fftSize: Int = 16_384
    ) -> (output: [Float], steadyState: [Float], report: SpectralReport) {
        precondition(skipTransient + fftSize <= frameCount,
                     "frameCount must be >= skipTransient + fftSize")
        let input = SineGenerator.generate(
            freqHz: freqHz, amplitude: amplitude,
            sampleRate: sampleRate, frameCount: frameCount
        )
        var output = [Float](repeating: 0.0, count: frameCount)
        for i in 0..<frameCount {
            let (l, _) = block.process(left: input[i], right: input[i])
            output[i] = l
        }
        let steadyState = Array(output[skipTransient..<(skipTransient + fftSize)])
        let analysis = FFTAnalyzer(fftSize: fftSize)
        let report = analysis.analyze(steadyState, sampleRate: sampleRate)
        return (output, steadyState, report)
    }
}
