import Testing
import Foundation
@testable import MPXPrime

// Linear-phase 1:L FIR interpolator regression tests.
//
// `LinearPhaseFIRInterpolator` is the companion to `LinearPhaseFIRDecimator`
// for the dual-rate audio chain boundary (plan.md "Next up" #1). The
// load-bearing assertions:
//
// (1) Round-trip identity. A signal downsampled then upsampled (or upsampled
//     then downsampled) at the same factor must recover the original to
//     within the kernel's stopband floor, after stripping the combined
//     group delay. This is what makes a no-op resampler boundary defensible
//     — if round-trip introduces audible error, the dual-rate refactor is
//     not viable on the current primitive design.
//
// (2) Group delay accounting. Kernel midpoint must match the reported
//     groupDelayOSSamples / groupDelayInputSamples, otherwise downstream
//     subcarrierDelayLine sizing will be wrong.
//
// (3) DC gain unity. The scale-by-L compensation inside configure() must
//     keep average gain at 1.0 — otherwise level changes through the
//     boundary and operators see a sudden VU shift on enable.
//
// (4) Stopband attenuation. Image energy above the cutoff must sit below
//     the design stopband. Otherwise aliasing seeps in from zero-stuffing.

@Suite("LinearPhaseFIRInterpolator")
struct LinearPhaseFIRInterpolatorTests {

    private let inputRate: Float = 48_000.0
    private let osRate: Float = 192_000.0
    private let factor: Int = 4  // 48 -> 192 = 4x

    // MARK: - DC gain

    @Test func dcGainIsUnity() {
        var interp = LinearPhaseFIRInterpolator()
        interp.configure(
            cutoffHz: inputRate * 0.5 * 0.9,  // 21.6 kHz, well below 24 kHz Nyquist
            sampleRateOS: osRate,
            interpolateFactor: factor,
            stopBandDB: 90.0,
            transitionHz: 4_000.0
        )

        var outBuf = [Float](repeating: 0, count: factor)
        var sum: Double = 0
        let count = 2_000
        // Feed DC for long enough to flush the FIR delay, then average the
        // OS-rate outputs.
        for i in 0..<count {
            interp.push(1.0, into: &outBuf)
            // Skip the first half-kernel of warm-up.
            if i > interp.groupDelayInputSamples + 8 {
                for s in outBuf { sum += Double(s) }
            }
        }
        let countedInputs = count - (interp.groupDelayInputSamples + 8) - 1
        let totalOutputs = countedInputs * factor
        let avg = sum / Double(max(1, totalOutputs))
        #expect(abs(avg - 1.0) < 0.001,
                "DC gain should be ~1.0, got \(avg). Likely the L-scaling in configure() is missing.")
    }

    // MARK: - Group delay accounting

    @Test func groupDelayMatchesKernelMidpoint() {
        var interp = LinearPhaseFIRInterpolator()
        interp.configure(
            cutoffHz: 21_600.0,
            sampleRateOS: osRate,
            interpolateFactor: factor,
            stopBandDB: 90.0,
            transitionHz: 4_000.0
        )
        // Reported group delays must agree to within the rounding tolerance.
        let osDelay = interp.groupDelayOSSamples
        let inputDelay = interp.groupDelayInputSamples
        #expect(osDelay > 0, "group delay must be positive on a configured FIR")
        // The input-rate delay should be close to osDelay / factor.
        let expectedInputDelay = osDelay / factor
        #expect(abs(inputDelay - expectedInputDelay) <= 1,
                "input-rate group delay (\(inputDelay)) should be ~\(expectedInputDelay)")
    }

    @Test func impulseResponsePeaksAtReportedGroupDelay() {
        var interp = LinearPhaseFIRInterpolator()
        interp.configure(
            cutoffHz: 21_600.0,
            sampleRateOS: osRate,
            interpolateFactor: factor,
            stopBandDB: 90.0,
            transitionHz: 4_000.0
        )
        // Send a unit impulse, then zeros. Collect OS-rate outputs.
        var outBuf = [Float](repeating: 0, count: factor)
        let inputSamples = 600
        var osStream = [Float]()
        osStream.reserveCapacity(inputSamples * factor)
        for n in 0..<inputSamples {
            let x: Float = (n == 0) ? 1.0 : 0.0
            interp.push(x, into: &outBuf)
            for p in 0..<factor { osStream.append(outBuf[p]) }
        }
        // Peak should sit at OS-rate index ~ groupDelayOSSamples.
        var peakIdx = 0
        var peakVal: Float = 0
        for i in 0..<osStream.count {
            let a = abs(osStream[i])
            if a > peakVal { peakVal = a; peakIdx = i }
        }
        let expected = interp.groupDelayOSSamples
        #expect(abs(peakIdx - expected) <= factor,
                "impulse-response peak at OS-rate index \(peakIdx) should be within ±\(factor) of reported group delay \(expected)")
    }

    // MARK: - Round-trip identity (down then up)

    @Test func roundtripDownThenUpRecoversBandLimitedSignal() {
        // Generate a band-limited program signal AT THE OS RATE, then:
        //   1. Decimate to input rate via LinearPhaseFIRDecimator (factor)
        //   2. Interpolate back to OS rate via LinearPhaseFIRInterpolator (factor)
        //   3. Compare to the original (delayed by combined group delay)
        // RMS error should be deep below the stopband floor for content
        // safely inside the cutoff.

        var decim = LinearPhaseFIRDecimator()
        decim.configure(
            cutoffHz: 21_600.0,
            sampleRateOS: osRate,
            decimateFactor: factor,
            stopBandDB: 90.0,
            transitionHz: 4_000.0
        )
        var interp = LinearPhaseFIRInterpolator()
        interp.configure(
            cutoffHz: 21_600.0,
            sampleRateOS: osRate,
            interpolateFactor: factor,
            stopBandDB: 90.0,
            transitionHz: 4_000.0
        )

        // Build OS-rate program: 1 kHz + 4 kHz + 10 kHz, all well inside
        // 21.6 kHz cutoff.
        let osFrames = 8_192
        var original = [Float](repeating: 0, count: osFrames)
        let sr = Double(osRate)
        for i in 0..<osFrames {
            let t = Double(i) / sr
            original[i] = Float(
                0.30 * sin(2.0 * .pi * 1_000.0 * t)
                + 0.25 * sin(2.0 * .pi * 4_000.0 * t)
                + 0.20 * sin(2.0 * .pi * 10_000.0 * t)
            )
        }

        // Pass through decim (every Nth sample is the meaningful decimated output).
        var inputRateStream = [Float]()
        inputRateStream.reserveCapacity(osFrames / factor + 16)
        for i in 0..<osFrames {
            let y = decim.push(original[i])
            // Decimator emits on every Nth push. We just sample at the
            // input-rate boundary by reading every factor-th iteration.
            if i % factor == factor - 1 {
                inputRateStream.append(y)
            }
        }

        // Now interpolate back.
        var outBuf = [Float](repeating: 0, count: factor)
        var recovered = [Float](repeating: 0, count: inputRateStream.count * factor)
        for (n, x) in inputRateStream.enumerated() {
            interp.push(x, into: &outBuf)
            for p in 0..<factor {
                recovered[n * factor + p] = outBuf[p]
            }
        }

        // Total group delay of the cascade in OS-rate samples. The
        // (factor - 1) correction accounts for the decim's emission
        // timing: it emits after factor pushes, so its first emission
        // sits at OS-time factor-1 (not 0). When we treat that as
        // input-rate sample 0 and feed it to the interp (which assumes
        // input-rate sample n maps to OS-time n*L), the alignment
        // shifts by factor-1 OS samples.
        let totalDelay =
            decim.groupDelayOSSamples
            + interp.groupDelayOSSamples
            - (factor - 1)
        // Compare original[i] vs recovered[i + totalDelay] over a stable
        // window, away from both the warm-up edge and the tail.
        let startCompare = totalDelay + 256
        let endCompare = min(osFrames - 256, recovered.count - 256)
        guard endCompare > startCompare + 1_000 else {
            Issue.record("Test span too short — recovered length \(recovered.count), totalDelay \(totalDelay)")
            return
        }
        var sse: Double = 0
        var sig: Double = 0
        for i in startCompare..<endCompare {
            let want = Double(original[i - totalDelay])
            let got = Double(recovered[i])
            let e = got - want
            sse += e * e
            sig += want * want
        }
        let rmsError = sqrt(sse / Double(endCompare - startCompare))
        let rmsSignal = sqrt(sig / Double(endCompare - startCompare))
        let errDB = 20.0 * log10(rmsError / max(1e-12, rmsSignal))
        #expect(errDB < -75.0,
                "round-trip RMS error \(errDB) dB should be below -75 dB; signal RMS \(rmsSignal), error RMS \(rmsError)")
    }

    // MARK: - Stopband image rejection

    @Test func zeroStuffingImagesAreSuppressedBelowCutoff() {
        // Drive the interpolator with a sine WELL INSIDE the cutoff
        // (10 kHz at 48k input). Without interpolation lowpass, zero-
        // stuffing would produce images at osRate - 10 kHz = 182 kHz,
        // 2*osRate - 10 kHz, etc. The Kaiser-sinc lowpass at the OS rate
        // should attenuate the first image by at least the design
        // stopband (90 dB).
        var interp = LinearPhaseFIRInterpolator()
        interp.configure(
            cutoffHz: 21_600.0,  // 90% of input Nyquist
            sampleRateOS: osRate,
            interpolateFactor: factor,
            stopBandDB: 90.0,
            transitionHz: 4_000.0
        )

        let signalFreq: Double = 10_000.0
        let inputSamples = 4_096
        var inStream = [Float](repeating: 0, count: inputSamples)
        let sr = Double(inputRate)
        for i in 0..<inputSamples {
            inStream[i] = Float(sin(2.0 * .pi * signalFreq * Double(i) / sr))
        }

        var outBuf = [Float](repeating: 0, count: factor)
        var osStream = [Float](repeating: 0, count: inputSamples * factor)
        for n in 0..<inputSamples {
            interp.push(inStream[n], into: &outBuf)
            for p in 0..<factor {
                osStream[n * factor + p] = outBuf[p]
            }
        }

        // Steady-state region away from FIR warm-up edge.
        let startIdx = interp.groupDelayOSSamples + 512
        let endIdx = osStream.count - 256
        guard endIdx > startIdx + 1_000 else {
            Issue.record("Test span too short")
            return
        }
        let span = endIdx - startIdx
        let passMag = goertzelMagnitude(
            buf: osStream, start: startIdx, length: span,
            freqHz: signalFreq, sampleRate: osRate
        )
        // First spectral image from zero-stuffing sits at `inputRate -
        // signalFreq` = 48 kHz - 10 kHz = 38 kHz. (Goertzel'ing at
        // osRate - signalFreq would alias back to signalFreq for a
        // real-valued signal — same bin, doesn't test anything.)
        let imageFreq: Double = Double(inputRate) - signalFreq
        let imageMag = goertzelMagnitude(
            buf: osStream, start: startIdx, length: span,
            freqHz: imageFreq, sampleRate: osRate
        )
        let suppressionDB = 20.0 * log10(imageMag / max(1e-12, passMag))
        // 10 kHz is well inside the 21.6 kHz cutoff; its image at 38 kHz
        // is well inside the FIR stopband. Demand >=75 dB suppression —
        // a few dB below the 90 dB design target to allow for windowing
        // leakage and finite-precision Goertzel.
        #expect(suppressionDB < -75.0,
                "image at \(imageFreq) Hz should be suppressed by >=75 dB vs 10 kHz pass content; got \(suppressionDB) dB. pass mag \(passMag), image mag \(imageMag)")
    }

    // MARK: - reset/configure idempotence

    @Test func resetReturnsStateToInitial() {
        var interp = LinearPhaseFIRInterpolator()
        interp.configure(
            cutoffHz: 21_600.0,
            sampleRateOS: osRate,
            interpolateFactor: factor,
            stopBandDB: 90.0,
            transitionHz: 4_000.0
        )
        var outBuf = [Float](repeating: 0, count: factor)
        // Pre-soil with a hot signal.
        for _ in 0..<256 { interp.push(0.8, into: &outBuf) }
        interp.reset()
        // After reset, feeding zeros must return zeros immediately.
        for _ in 0..<8 {
            interp.push(0.0, into: &outBuf)
            for p in 0..<factor {
                #expect(abs(outBuf[p]) < 1e-7,
                        "post-reset output for zero input should be ~0, got \(outBuf[p])")
            }
        }
    }

    @Test func disabledStateActsAsPassthrough() {
        // Default-init (no configure) state should pass input through L
        // times, so a no-op resampler boundary can stay "disabled" without
        // crashing or distorting.
        var interp = LinearPhaseFIRInterpolator()
        var outBuf = [Float](repeating: 0, count: 4)
        interp.push(0.42, into: &outBuf)
        for p in 0..<outBuf.count {
            // Default factor is 1; only out[0] is meaningfully written.
            // But callers may have allocated more — confirm out[0] is the input.
            if p < interp.factor {
                #expect(abs(outBuf[p] - 0.42) < 1e-7,
                        "disabled interpolator should passthrough input")
            }
        }
    }

    // MARK: - Helpers

    /// Goertzel single-bin magnitude estimator. Returns linear amplitude.
    private func goertzelMagnitude(
        buf: [Float], start: Int, length: Int,
        freqHz: Double, sampleRate: Float
    ) -> Double {
        let n = length
        let k = (Double(n) * freqHz / Double(sampleRate)).rounded()
        let omega = 2.0 * .pi * k / Double(n)
        let cosw = cos(omega)
        let coeff = 2.0 * cosw
        var s0: Double = 0
        var s1: Double = 0
        var s2: Double = 0
        for i in 0..<n {
            let x = Double(buf[start + i])
            s0 = coeff * s1 - s2 + x
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cosw
        let imag = s2 * sin(omega)
        return sqrt(real * real + imag * imag) / Double(n) * 2.0
    }
}
