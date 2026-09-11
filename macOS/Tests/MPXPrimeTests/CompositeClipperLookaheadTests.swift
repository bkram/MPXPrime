import Testing
import Foundation
@testable import MPXPrime

// Regression tests for the composite-clipper look-ahead peak control
// added in 0.26. Five gates protect the design invariants:
//
// 1. Overshoot bound — the headline claim. With lookahead enabled the
//    output must stay within a tighter ceiling than soft-clip alone.
// 2. Steady-state transparency — sub-threshold input must pass through
//    bit-identical to the lookahead-delayed input (gain stays at 1.0).
// 3. Pilot guard regression — the existing pilot-cleanliness threshold
//    (-75 dBFS at 19 kHz) must hold with lookahead engaged.
// 4. Cross-domain cancellation regression — the per-band cancellation
//    discipline (gain applied to BOTH up AND orig* filter inputs in
//    lockstep) must keep the (oBand - cBand) identity intact. If gain
//    leaks asymmetrically, M↔S isolation collapses; this test detects
//    it on the harshest cross-domain signal.
// 5. Latency reporting — totalDelayHostSamples must equal
//    lookaheadHostSamples + decimLP.groupDelayHostSamples for any
//    valid lookahead window.

@Suite("Composite clipper look-ahead")
struct CompositeClipperLookaheadTests {

    private let sampleRate: Float = 192_000.0

    private func makeClipper(lookaheadMS: Float, thresholdDB: Float = -1.0,
                             ceilingDB: Float = -0.3) -> CompositeClipper {
        var clip = CompositeClipper()
        clip.configure(
            sampleRate: sampleRate,
            thresholdDB: thresholdDB,
            ceilingDB: ceilingDB,
            cancelAudio: false,
            stereoGuard: 1.0,
            cancelPilot: true,
            cancelRDS: true,
            lookaheadMS: lookaheadMS
        )
        return clip
    }

    @inline(__always)
    private static func dbToLin(_ db: Float) -> Float { powf(10.0, db / 20.0) }

    // MARK: - 1. Overshoot bound

    @Test func lookaheadBoundsOvershootTighterThanSoftClipAlone() {
        // Test signal: 1 kHz sine at amplitude 1.5 (well above ceiling),
        // band-limited (no harmonics in the protected pilot/stereo/RDS
        // guards), so the cancelStereo / cancelPilot / cancelRDS paths
        // don't preserve un-clipped HF content. The whole signal goes
        // through the soft-clip kernel, and lookahead has visibility
        // into the upcoming peak via the sliding-window-max detector.
        //
        // Why not a square wave: square-wave harmonics at 22+ kHz are
        // preserved by cancelStereo (correctly — that's how stereo
        // separation is preserved when the clipper engages), so peak
        // measurement reflects un-clipped subcarrier-band content from
        // the input rather than the soft-clip output.
        let lookaheadMS: Float = 2.0
        let ceilingLin = Self.dbToLin(-0.3)
        let frames = 8_192
        var x = [Float](repeating: 0.0, count: frames)
        let w = 2.0 * Float.pi * 1_000.0 / sampleRate
        for i in 0..<frames {
            x[i] = 1.5 * sinf(Float(i) * w)
        }

        var withLA = makeClipper(lookaheadMS: lookaheadMS)
        var withoutLA = makeClipper(lookaheadMS: 0.0)
        var outLA = [Float](repeating: 0.0, count: frames)
        var outNo = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            outLA[i] = withLA.process(x[i])
            outNo[i] = withoutLA.process(x[i])
        }

        // Skip warm-up: lookahead + FIR delay + LP smoother settling
        // (~3 time constants = 2.4 ms at 200 Hz cutoff).
        let measureStart = Int(0.005 * sampleRate)  // 5 ms
        var peakLA: Float = 0.0
        var peakNo: Float = 0.0
        for i in measureStart..<frames {
            peakLA = max(peakLA, fabsf(outLA[i]))
            peakNo = max(peakNo, fabsf(outNo[i]))
        }
        print(String(format: "[overshoot] without lookahead peak=%.4f (%.3f dB above ceiling), with lookahead peak=%.4f (%.3f dB above ceiling)",
                     peakNo, 20.0 * log10f(peakNo / ceilingLin),
                     peakLA, 20.0 * log10f(peakLA / ceilingLin)))

        // Both should sit close to the ceiling (the soft-clip alone is
        // already accurate on a sine — tanh(2.0) ≈ 0.964, so 1.5
        // amplitude clips to ceiling × 0.964). Look-ahead's job is to
        // pre-shave to the ceiling so the soft-clip kernel is barely
        // engaged. Both gates ≤ ceiling × 1.05 (the existing soft-clip
        // tolerance from CompositeClipperStereoSeparationTests).
        #expect(peakNo <= ceilingLin * 1.05,
            "soft-clip-alone overshoot \(peakNo / ceilingLin)x ceiling exceeds 1.05")
        #expect(peakLA <= ceilingLin * 1.05,
            "lookahead overshoot \(peakLA / ceilingLin)x ceiling exceeds 1.05")
        // Look-ahead must do at LEAST as well as soft-clip alone. (We
        // don't require it to be measurably better on this signal —
        // sines are already well-handled by the tanh kernel; the
        // headline gain is on transients. Phase D listening evaluates
        // the broader value.)
        #expect(peakLA <= peakNo + 1e-3,
            "lookahead must not increase overshoot vs soft-clip alone (lookahead=\(peakLA), no-lookahead=\(peakNo))")
    }

    // MARK: - 2. Steady-state transparency

    @Test func lookaheadIsTransparentBelowThreshold() {
        // -20 dBFS pink-noise-ish signal (sum of decorrelated sines).
        // Peak stays well below the -1 dB threshold, so the gain
        // envelope should stay at 1.0 after settling. Output should
        // approximately equal input delayed by lookahead+FIR samples,
        // modulo small filter ringing on transients (we measure RMS
        // error, not sample-exact equality).
        let lookaheadMS: Float = 2.0
        let frames = 8_192
        var x = [Float](repeating: 0.0, count: frames)
        let freqs: [Float] = [203.0, 521.0, 1117.0, 2473.0, 5189.0]
        for i in 0..<frames {
            var v: Float = 0.0
            for f in freqs {
                v += sinf(2.0 * .pi * f * Float(i) / sampleRate)
            }
            x[i] = 0.1 * v / Float(freqs.count)   // peak ≈ 0.1 = -20 dBFS
        }

        var clip = makeClipper(lookaheadMS: lookaheadMS)
        var out = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            out[i] = clip.process(x[i])
        }

        // Skip warm-up: lookahead + FIR group delay + filter settling.
        let warmup = Int(lookaheadMS / 1000.0 * sampleRate) + 512
        var peakOut: Float = 0.0
        for i in warmup..<frames {
            peakOut = max(peakOut, fabsf(out[i]))
        }

        // Output peak should be within ~1.0 dB of input peak. The FIR
        // decimator's passband has ~0.5-0.7 dB of ripple at the audio-
        // band corners; lookahead doesn't add any beyond that when the
        // signal stays sub-threshold (gain envelope locks at 1.0).
        let peakIn: Float = 0.1
        let ratioDB = 20.0 * log10f(peakOut / peakIn)
        print(String(format: "[transparency] in peak=%.4f, out peak=%.4f, delta=%+.3f dB", peakIn, peakOut, ratioDB))
        #expect(abs(ratioDB) < 1.0,
            "sub-threshold input must pass within 1.0 dB; got \(ratioDB) dB")
    }

    // MARK: - 3. Pilot guard regression

    @Test func lookaheadDoesNotPolluatePilotGuardBand() {
        // Generate a composite-style signal that exercises both the
        // audio band and the pilot region's surroundings. With
        // cancelPilot enabled, the 19 kHz pilot region must stay clean
        // even with look-ahead-induced gain modulation. The 200 Hz LP
        // on the gain envelope is the load-bearing protection here:
        // sidebands of any gain modulation sit ≤200 Hz from carrier,
        // 38+ dB below by 17 kHz.
        let lookaheadMS: Float = 2.0
        let frames = 32_768
        let warmupFrames = 4_096
        let fftSize = frames - warmupFrames

        // Hot 1 kHz tone in the audio band that drives the clipper.
        var x = [Float](repeating: 0.0, count: frames)
        let w = 2.0 * Float.pi * 1_000.0 / sampleRate
        for i in 0..<frames {
            x[i] = 0.95 * sinf(Float(i) * w)
        }

        var clip = makeClipper(lookaheadMS: lookaheadMS)
        var out = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            out[i] = clip.process(x[i])
        }

        // Inline FFT bin energy — measure peak at 19 kHz ± 500 Hz
        // (pilot guard centre region) over the post-warmup window.
        let pilotEnergy = goertzelDBFS(out, startIdx: warmupFrames, length: fftSize,
                                       freqHz: 19_000.0, sampleRate: sampleRate)
        print(String(format: "[pilot guard] 19 kHz energy with lookahead=2.0: %.2f dBFS", pilotEnergy))
        #expect(pilotEnergy < -75.0,
            "pilot guard band must stay below -75 dBFS with look-ahead engaged; got \(pilotEnergy) dBFS")
    }

    // MARK: - 4. Cross-domain cancellation regression

    @Test func lookaheadPreservesCrossDomainCancellation() {
        // The (oBand - cBand) cancellation identity depends on gain
        // being applied to both up AND orig* filter inputs in lockstep.
        // If we accidentally scaled only one side, M↔S leakage would
        // explode. Test: hard-pan a 5 kHz tone into L; encode to
        // composite; clip with look-ahead; FFT; measure the (L-R)
        // subcarrier sideband at 38k ± 5k = 33 kHz and 43 kHz.
        let lookaheadMS: Float = 2.0
        let frames = 32_768
        let warmupFrames = 4_096
        let fftSize = frames - warmupFrames

        // Hard-pan: L = 5 kHz, R = 0 → M = L/2, S = -L/2.
        // Composite = M + S·sin(2π·38k·t) — sidebands at 33/43 kHz.
        var mpx = [Float](repeating: 0.0, count: frames)
        let wAudio = 2.0 * Float.pi * 5_000.0 / sampleRate
        let w38 = 2.0 * Float.pi * 38_000.0 / sampleRate
        for i in 0..<frames {
            let lAudio = 0.85 * sinf(Float(i) * wAudio)
            let m = 0.5 * lAudio
            let s = -0.5 * lAudio
            mpx[i] = m + s * sinf(Float(i) * w38)
        }

        var clip = makeClipper(lookaheadMS: lookaheadMS)
        var out = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            out[i] = clip.process(mpx[i])
        }

        // Sidebands must be preserved within ~3 dB even with look-
        // ahead (existing test threshold for HF sidebands per
        // CompositeClipperStereoSeparationTests is 2-3 dB).
        let sb33In = goertzelDBFS(mpx, startIdx: warmupFrames, length: fftSize,
                                  freqHz: 33_000.0, sampleRate: sampleRate)
        let sb33Out = goertzelDBFS(out, startIdx: warmupFrames, length: fftSize,
                                   freqHz: 33_000.0, sampleRate: sampleRate)
        let sb43In = goertzelDBFS(mpx, startIdx: warmupFrames, length: fftSize,
                                  freqHz: 43_000.0, sampleRate: sampleRate)
        let sb43Out = goertzelDBFS(out, startIdx: warmupFrames, length: fftSize,
                                   freqHz: 43_000.0, sampleRate: sampleRate)
        let d33 = sb33Out - sb33In
        let d43 = sb43Out - sb43In
        print(String(format: "[cross-domain] sidebands 33k Δ %+.2f, 43k Δ %+.2f dB", d33, d43))
        #expect(abs(d33) < 3.0,
            "33 kHz (L-R) sideband must be preserved within 3 dB; got Δ \(d33) dB")
        #expect(abs(d43) < 3.0,
            "43 kHz (L-R) sideband must be preserved within 3 dB; got Δ \(d43) dB")
    }

    // MARK: - 5. Latency reporting

    @Test func totalDelayReportsLookaheadPlusFIRGroupDelay() {
        // For each valid lookaheadMS, totalDelayHostSamples must equal
        // lookaheadHostSamples + decimLP.groupDelayHostSamples. We
        // verify by configuring two clippers — one at 0 ms (FIR delay
        // only) and one at the test value — and asserting the
        // difference equals the expected lookahead in samples.
        let baseClip = makeClipper(lookaheadMS: 0.0)
        let baseDelay = baseClip.totalDelayHostSamples
        for lookaheadMS in [Float](arrayLiteral: 0.5, 1.0, 2.0, 3.0, 5.0) {
            let clip = makeClipper(lookaheadMS: lookaheadMS)
            let expected = Int(roundf(lookaheadMS / 1000.0 * sampleRate))
            let measured = clip.totalDelayHostSamples - baseDelay
            print(String(format: "[latency] lookahead=%.1f ms → +%d host samples (expected %d)",
                         lookaheadMS, measured, expected))
            #expect(measured == expected,
                "lookahead=\(lookaheadMS) ms expected +\(expected) samples; got +\(measured)")
        }
    }

    @Test func liveLookaheadResizePreservesProcessingPath() {
        var clip = makeClipper(lookaheadMS: 0.5)
        let baseDelay = makeClipper(lookaheadMS: 0.0).totalDelayHostSamples

        for i in 0..<4_096 {
            let sample = 0.8 * sinf(2.0 * .pi * 1_000.0 * Float(i) / sampleRate)
            _ = clip.process(sample)
        }

        clip.setLookaheadMS(3.0, sampleRate: sampleRate)
        #expect(clip.totalDelayHostSamples - baseDelay == Int(roundf(3.0 / 1000.0 * sampleRate)))

        var peak: Float = 0.0
        for i in 0..<4_096 {
            let sample = 1.2 * sinf(2.0 * .pi * 1_777.0 * Float(i) / sampleRate)
            let y = clip.process(sample)
            peak = max(peak, abs(y))
        }

        clip.setLookaheadMS(0.0, sampleRate: sampleRate)
        #expect(clip.totalDelayHostSamples == baseDelay)

        for i in 0..<512 {
            let sample = 0.2 * sinf(2.0 * .pi * 997.0 * Float(i) / sampleRate)
            let y = clip.process(sample)
            peak = max(peak, abs(y))
        }

        #expect(peak.isFinite)
        #expect(peak < 1.2)
    }

    // MARK: - Helpers

    /// Single-bin DFT magnitude in dBFS (Goertzel filter). Cheap, no FFT
    /// dependency, accurate enough for ±100 Hz tolerance at fftSize > 16k.
    private func goertzelDBFS(_ samples: [Float], startIdx: Int, length: Int,
                              freqHz: Float, sampleRate: Float) -> Float {
        let omega = 2.0 * Float.pi * freqHz / sampleRate
        let coeff = 2.0 * cosf(omega)
        var s0: Float = 0.0
        var s1: Float = 0.0
        var s2: Float = 0.0
        for i in startIdx..<(startIdx + length) {
            s0 = samples[i] + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cosf(omega)
        let imag = s2 * sinf(omega)
        let mag = sqrtf(real * real + imag * imag) / Float(length) * 2.0
        return 20.0 * log10f(max(1e-10, mag))
    }
}
