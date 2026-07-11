import Testing
import Foundation
#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
@testable import MPXPrime
import MPXPrimeCore

// Diagnostic + regression tests for the cross-domain IM distortion of
// `CompositeClipper`.
//
// The composite clipper operates on `M + S·cos(2π·38kHz)`. A naive
// tanh soft-clip of that sum produces cubic-and-higher-order products
// that mix M and S content, so:
//   - Loud M bleeds energy into the S band around 38 kHz (fake
//     stereo-difference sidebands driven by the M envelope)
//   - Loud S bleeds back into the M band (hard-panned content
//     modulates the mono sum)
// Both are perceived as the stereo image "changing" when the clipper
// engages.
//
// These tests build a synthetic composite with a known M tone and a
// known S tone at different frequencies, push it through
// `CompositeClipper` alone (no MPXGenerator chain, no other DSP),
// demodulate the result, and measure how much energy leaks into the
// wrong band. The bypass-vs-clipper delta quantifies the distortion.

@Suite("Composite clipper cross-domain IM")
struct CompositeClipperCrossDomainTests {

    private let sampleRate: Float = 192_000.0
    private let fftSize: Int = 16_384
    private let warmupFrames: Int = 2_048
    private let mFreq: Float = 1_000.0   // M-band tone (mono centre)
    private let sFreq: Float = 400.0     // S-band tone (hard-pan difference)

    // MARK: - Composite construction

    /// Build `M(t) + S(t)·cos(2π·38kHz·t)` at the test sample rate.
    /// Amplitudes deliberately stack so the composite peaks above the
    /// clipper threshold on the largest sample.
    private func buildComposite(
        mAmplitude: Float,
        sAmplitude: Float,
        frames: Int
    ) -> (mpx: [Float], m: [Float], s: [Float]) {
        var m = [Float](repeating: 0, count: frames)
        var s = [Float](repeating: 0, count: frames)
        var mpx = [Float](repeating: 0, count: frames)
        let wM = 2.0 * Double.pi * Double(mFreq) / Double(sampleRate)
        let wS = 2.0 * Double.pi * Double(sFreq) / Double(sampleRate)
        let w38 = 2.0 * Double.pi * 38_000.0 / Double(sampleRate)
        for i in 0..<frames {
            let mSample = Float(Double(mAmplitude) * sin(wM * Double(i)))
            let sSample = Float(Double(sAmplitude) * sin(wS * Double(i)))
            m[i] = mSample
            s[i] = sSample
            mpx[i] = mSample + sSample * Float(cos(w38 * Double(i)))
        }
        return (mpx, m, s)
    }

    // MARK: - Demodulation

    /// Decode a composite back to M (mono) and S (side) using
    /// synchronous demodulation. This is the receiver-side stereo
    /// decoder in its simplest form: M = LPF(mpx), S = LPF(mpx · 2·cos(38k)).
    private func demodulate(mpx: [Float], audioCutoffHz: Float = 15_000.0)
        -> (decodedM: [Float], decodedS: [Float])
    {
        let frames = mpx.count
        var demodM = [Float](repeating: 0, count: frames)
        var demodS = [Float](repeating: 0, count: frames)
        let w38 = 2.0 * Double.pi * 38_000.0 / Double(sampleRate)
        for i in 0..<frames {
            demodM[i] = mpx[i]
            demodS[i] = mpx[i] * 2.0 * Float(cos(w38 * Double(i)))
        }
        var lpM = Biquad()
        lpM.configureLowpass(cutoffHz: audioCutoffHz, sampleRate: sampleRate, q: 0.7071068)
        var lpM2 = Biquad()
        lpM2.configureLowpass(cutoffHz: audioCutoffHz, sampleRate: sampleRate, q: 0.7071068)
        var lpS = Biquad()
        lpS.configureLowpass(cutoffHz: audioCutoffHz, sampleRate: sampleRate, q: 0.7071068)
        var lpS2 = Biquad()
        lpS2.configureLowpass(cutoffHz: audioCutoffHz, sampleRate: sampleRate, q: 0.7071068)
        for i in 0..<frames {
            demodM[i] = lpM2.process(lpM.process(demodM[i]))
            demodS[i] = lpS2.process(lpS.process(demodS[i]))
        }
        return (demodM, demodS)
    }

    // MARK: - Spectral energy helpers

    private func analyze(_ samples: [Float]) -> SpectralReport {
        precondition(samples.count >= warmupFrames + fftSize,
                     "need enough samples to drop the warm-up window")
        let tail = Array(samples[warmupFrames..<(warmupFrames + fftSize)])
        return FFTAnalyzer(fftSize: fftSize).analyze(tail, sampleRate: sampleRate)
    }

    /// dBFS at the FFT bin closest to `freq` ± small tolerance.
    private func binDB(_ report: SpectralReport, around freq: Float, tolHz: Float = 30.0) -> Float {
        let lo = max(0.0, freq - tolHz)
        let hi = min(sampleRate * 0.5 - 1, freq + tolHz)
        return report.peakDBFS(in: lo...hi)
    }

    // MARK: - Runners

    private func runClipper(_ mpx: [Float], thresholdDB: Float, ceilingDB: Float,
                            cancelAudio: Bool = true, cancelStereo: Bool = true,
                            cancelPilot: Bool = true, cancelRDS: Bool = true) -> [Float] {
        var clip = CompositeClipper()
        clip.configure(sampleRate: sampleRate, thresholdDB: thresholdDB, ceilingDB: ceilingDB,
                       cancelAudio: cancelAudio, cancelStereo: cancelStereo,
                       cancelPilot: cancelPilot, cancelRDS: cancelRDS)
        var out = [Float](repeating: 0, count: mpx.count)
        for i in 0..<mpx.count {
            out[i] = clip.process(mpx[i])
        }
        return out
    }

    // MARK: - Tests

    @Test func bypassProducesNoCrossDomainLeakage() {
        // Sanity: pure M + S·cos(38k) with no clipping should
        // demodulate back to a clean M at mFreq and a clean S at sFreq
        // with no meaningful energy in the other band's test frequency.
        let frames = warmupFrames + fftSize
        let (mpx, _, _) = buildComposite(mAmplitude: 0.5, sAmplitude: 0.3, frames: frames)
        let (decodedM, decodedS) = demodulate(mpx: mpx)
        let mReport = analyze(decodedM)
        let sReport = analyze(decodedS)

        // Real signal energies should be strong:
        let realM = binDB(mReport, around: mFreq)
        let realS = binDB(sReport, around: sFreq)
        // Cross-band probes should be deep in the floor:
        let leakMintoS = binDB(sReport, around: mFreq)
        let leakSintoM = binDB(mReport, around: sFreq)

        #expect(realM > -10.0, "M should decode back strong; got \(realM) dBFS")
        #expect(realS > -12.0, "S should decode back strong; got \(realS) dBFS")
        #expect(realM - leakMintoS > 60.0,
            "M-into-S leak \(leakMintoS) dBFS should be at least 60 dB below the real M \(realM) without clipping")
        #expect(realS - leakSintoM > 60.0,
            "S-into-M leak \(leakSintoM) dBFS should be at least 60 dB below the real S \(realS) without clipping")
    }

    @Test func compositeClipperIntroducesCrossDomainLeakage() {
        // With the clipper engaged, the composite saturates and its
        // IM products scatter into both bands. Quantify the drop in
        // isolation. Cancellation disabled to measure the bare clipper
        // IM mechanism that the cancellation path is designed to remove.
        let frames = warmupFrames + fftSize
        // Composite peak reaches ~mA + sA = 0.8 before clipping;
        // threshold at -3 dB (~0.708) → modest-heavy clipping.
        let (clean, _, _) = buildComposite(mAmplitude: 0.5, sAmplitude: 0.3, frames: frames)
        let clipped = runClipper(clean, thresholdDB: -3.0, ceilingDB: -0.5,
                                 cancelAudio: false, cancelStereo: false,
                                 cancelPilot: false, cancelRDS: false)

        let (cleanM, cleanS) = demodulate(mpx: clean)
        let (clipM, clipS) = demodulate(mpx: clipped)
        let cleanMReport = analyze(cleanM)
        let cleanSReport = analyze(cleanS)
        let clipMReport = analyze(clipM)
        let clipSReport = analyze(clipS)

        let realMClean = binDB(cleanMReport, around: mFreq)
        let realSClean = binDB(cleanSReport, around: sFreq)

        let leakMintoSClean = binDB(cleanSReport, around: mFreq)
        let leakSintoMClean = binDB(cleanMReport, around: sFreq)

        let leakMintoSClipped = binDB(clipSReport, around: mFreq)
        let leakSintoMClipped = binDB(clipMReport, around: sFreq)

        let deltaMintoS = leakMintoSClipped - leakMintoSClean
        let deltaSintoM = leakSintoMClipped - leakSintoMClean

        // Print the measurement so it shows up in test output even
        // when the test passes — this is primarily a diagnostic.
        print("=== Composite clipper cross-domain IM diagnostic ===")
        print(String(format: "Clean M bin: %.1f dBFS, Clean S bin: %.1f dBFS", realMClean, realSClean))
        print(String(format: "Bypass M→S leak: %.1f dBFS  (isolation %.1f dB)",
                     leakMintoSClean, realMClean - leakMintoSClean))
        print(String(format: "Clipper M→S leak: %.1f dBFS  (isolation %.1f dB, worsened by %+.1f dB)",
                     leakMintoSClipped, realMClean - leakMintoSClipped, deltaMintoS))
        print(String(format: "Bypass S→M leak: %.1f dBFS  (isolation %.1f dB)",
                     leakSintoMClean, realSClean - leakSintoMClean))
        print(String(format: "Clipper S→M leak: %.1f dBFS  (isolation %.1f dB, worsened by %+.1f dB)",
                     leakSintoMClipped, realSClean - leakSintoMClipped, deltaSintoM))

        // The behavioural assertion: clipper must make the leak WORSE
        // by a measurable amount (>6 dB). If it doesn't, either the
        // clipper isn't engaging or this diagnostic is not wired up
        // correctly.
        #expect(deltaMintoS > 6.0 || deltaSintoM > 6.0,
            "Clipper should increase cross-domain leakage by >6 dB; M→S delta \(deltaMintoS) dB, S→M delta \(deltaSintoM) dB")
    }

    @Test func harderClipperDrivesCrossDomainLeakageFurther() {
        // Push the clipper harder and expect even more IM distortion.
        // Measure at a frequency that ONLY contains IM products — the
        // cubic clipping term has its characteristic mixing products
        // at (ω_S ± 2·ω_M), i.e. 1600 Hz and 2400 Hz for our 1 kHz M
        // and 400 Hz S. No real signal there — any energy is pure
        // clipper-generated crosstalk. Cancellation disabled so we
        // measure raw drive sensitivity.
        let frames = warmupFrames + fftSize
        let (signal, _, _) = buildComposite(mAmplitude: 0.5, sAmplitude: 0.3, frames: frames)
        let softlyClipped = runClipper(signal, thresholdDB: -3.0, ceilingDB: -0.5,
                                       cancelAudio: false, cancelStereo: false,
                                       cancelPilot: false, cancelRDS: false)
        let heavilyClipped = runClipper(signal, thresholdDB: -12.0, ceilingDB: -0.5,
                                        cancelAudio: false, cancelStereo: false,
                                        cancelPilot: false, cancelRDS: false)

        let (_, softS) = demodulate(mpx: softlyClipped)
        let (_, heavyS) = demodulate(mpx: heavilyClipped)
        // ω_S ± 2·ω_M IM product: 400 + 2·1000 = 2400 Hz.
        let probeHz: Float = 2_400.0
        let softLeak = binDB(analyze(softS), around: probeHz)
        let heavyLeak = binDB(analyze(heavyS), around: probeHz)

        print(String(format: "IM probe (M²·S at 2400 Hz)  soft: %.1f dBFS   heavy: %.1f dBFS   Δ: %+.1f dB",
                     softLeak, heavyLeak, heavyLeak - softLeak))

        #expect(heavyLeak > softLeak + 6.0,
            "Harder clipping should produce >6 dB more IM-product energy at 2400 Hz (M²·S mixing product); got soft \(softLeak), heavy \(heavyLeak)")
    }

    @Test func intermodulationProductsLiveAtPredictedFrequencies() {
        // Validate that the IM distortion we measure really is where
        // the cubic theory says it should be: M³ term produces a
        // 3 kHz tone in the M band; M²·S term produces tones at
        // ω_S ± 2·ω_M (i.e. 1600 and 2400 Hz) in the S band.
        // Cancellation disabled — this test diagnoses the bare clipper's
        // IM mechanism, not the cancellation behaviour.
        let frames = warmupFrames + fftSize
        let (clean, _, _) = buildComposite(mAmplitude: 0.5, sAmplitude: 0.3, frames: frames)
        let clipped = runClipper(clean, thresholdDB: -3.0, ceilingDB: -0.5,
                                 cancelAudio: false, cancelStereo: false,
                                 cancelPilot: false, cancelRDS: false)

        let (cleanM, cleanS) = demodulate(mpx: clean)
        let (clipM, clipS) = demodulate(mpx: clipped)

        let cleanM3 = binDB(analyze(cleanM), around: 3 * mFreq)         // 3 kHz
        let clipM3 = binDB(analyze(clipM), around: 3 * mFreq)

        let cleanMixLow = binDB(analyze(cleanS), around: 2 * mFreq - sFreq)  // 1600 Hz
        let clipMixLow = binDB(analyze(clipS), around: 2 * mFreq - sFreq)

        let cleanMixHigh = binDB(analyze(cleanS), around: 2 * mFreq + sFreq) // 2400 Hz
        let clipMixHigh = binDB(analyze(clipS), around: 2 * mFreq + sFreq)

        print("=== IM products at predicted frequencies ===")
        print(String(format: "M³ at 3 kHz:         clean %.1f → clipped %.1f   (Δ %+.1f)",
                     cleanM3, clipM3, clipM3 - cleanM3))
        print(String(format: "M²·S at 1600 Hz:     clean %.1f → clipped %.1f   (Δ %+.1f)",
                     cleanMixLow, clipMixLow, clipMixLow - cleanMixLow))
        print(String(format: "M²·S at 2400 Hz:     clean %.1f → clipped %.1f   (Δ %+.1f)",
                     cleanMixHigh, clipMixHigh, clipMixHigh - cleanMixHigh))

        // Each predicted product should rise meaningfully with
        // clipping engaged (>20 dB delta) — these are the exact bins
        // a distortion-cancelled composite clipper needs to remove.
        #expect(clipM3 - cleanM3 > 20.0,
            "M³ product at 3 kHz should rise >20 dB with clipping")
        #expect(clipMixLow - cleanMixLow > 20.0,
            "M²·S product at 1600 Hz should rise >20 dB with clipping")
        #expect(clipMixHigh - cleanMixHigh > 20.0,
            "M²·S product at 2400 Hz should rise >20 dB with clipping")
    }

    @Test func audioBandCancellationDropsMonoIM() {
        // M³ at 3 kHz lives in MPX-domain audio band (0–17 kHz), so
        // cancelAudio targets it directly.
        //
        // Note: with the delta-based cancellation algorithm (single-LR4
        // bandpass on the clip residual, subtracted from clipped), the
        // achievable cancellation depth is bounded by the LR4 phase
        // shift in the passband — at 3 kHz with LR4 LP cutoff at 17 kHz,
        // the 4th-order phase rolloff limits cancellation to ~5 dB. The
        // earlier signal-substitution algorithm gave >20 dB but at the
        // cost of attenuating HF (L-R) subcarrier sidebands by ~12 dB
        // (the user-reported "stereo image disappears" issue). The new
        // algorithm trades cancellation depth for sideband preservation.
        let frames = warmupFrames + fftSize
        let (clean, _, _) = buildComposite(mAmplitude: 0.5, sAmplitude: 0.3, frames: frames)
        let off = runClipper(clean, thresholdDB: -12.0, ceilingDB: -0.5,
                             cancelAudio: false, cancelStereo: false,
                             cancelPilot: false, cancelRDS: false)
        let onAudio = runClipper(clean, thresholdDB: -12.0, ceilingDB: -0.5,
                                 cancelAudio: true, cancelStereo: false,
                                 cancelPilot: false, cancelRDS: false)

        let (mOff, _) = demodulate(mpx: off)
        let (mOnA, _) = demodulate(mpx: onAudio)
        let m3Off = binDB(analyze(mOff), around: 3 * mFreq)
        let m3OnA = binDB(analyze(mOnA), around: 3 * mFreq)

        print(String(format: "Audio cancel — M³ at 3 kHz:  off %.1f → on %.1f   (drop %+.1f dB)",
                     m3Off, m3OnA, m3Off - m3OnA))
        #expect(m3Off - m3OnA > 3.0,
            "Audio cancellation should drop M³ at 3 kHz by >3 dB")
    }

    @Test func stereoBandCancellationDropsCrossDomainMixingProducts() {
        // M²·S at 1600/2400 Hz in S band comes from MPX-domain energy near
        // 38k ± 2ωM ± ωS (35.6/36.4/39.6/40.4 kHz), which lives inside the
        // 23-53 kHz stereo subband. cancelStereo should drop these.
        let frames = warmupFrames + fftSize
        let (clean, _, _) = buildComposite(mAmplitude: 0.5, sAmplitude: 0.3, frames: frames)
        let off = runClipper(clean, thresholdDB: -12.0, ceilingDB: -0.5,
                             cancelAudio: false, cancelStereo: false,
                             cancelPilot: false, cancelRDS: false)
        let onStereo = runClipper(clean, thresholdDB: -12.0, ceilingDB: -0.5,
                                  cancelAudio: false, cancelStereo: true,
                                  cancelPilot: false, cancelRDS: false)

        let (_, sOff) = demodulate(mpx: off)
        let (_, sOnS) = demodulate(mpx: onStereo)
        let mixLowOff = binDB(analyze(sOff), around: 2 * mFreq - sFreq)
        let mixLowOnS = binDB(analyze(sOnS), around: 2 * mFreq - sFreq)
        let mixHighOff = binDB(analyze(sOff), around: 2 * mFreq + sFreq)
        let mixHighOnS = binDB(analyze(sOnS), around: 2 * mFreq + sFreq)

        print(String(format: "Stereo cancel — M²·S at 1600 Hz:  off %.1f → on %.1f   (drop %+.1f dB)",
                     mixLowOff, mixLowOnS, mixLowOff - mixLowOnS))
        print(String(format: "Stereo cancel — M²·S at 2400 Hz:  off %.1f → on %.1f   (drop %+.1f dB)",
                     mixHighOff, mixHighOnS, mixHighOff - mixHighOnS))

        // Single-LR4 delta-based cancellation through the differential
        // FIR-decimator path (Orban US 6,337,999 topology) gives ~5–7 dB
        // drop in the stereo subband. Cancellation depth dropped 1–2 dB
        // versus the previous Butterworth-decimator + classical-add
        // algorithm — that's the cost of moving the wanted (L−R)
        // sidebands off the decimator path entirely (the win on the
        // wanted-signal side is flat passband response across 0–53 kHz
        // versus Butterworth's ~1–2 dB rolloff at the upper subcarrier
        // edge). Net improvement on real receivers because the (L−R)
        // sidebands no longer phase-twist; minor regression on this
        // synthetic cross-domain test.
        #expect(mixLowOff - mixLowOnS > 5.0,
            "Stereo cancellation should drop M²·S at 1600 Hz by >5 dB")
        #expect(mixHighOff - mixHighOnS > 4.0,
            "Stereo cancellation should drop M²·S at 2400 Hz by >4 dB")
    }

}
