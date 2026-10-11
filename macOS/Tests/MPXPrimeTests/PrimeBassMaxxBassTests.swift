import Testing
import Foundation
@testable import MPXPrime

// Pins for the PrimeBass missing-fundamental enhancer (rewritten 2026-10-10
// after docs/primebass-review.md; `processPrimeBass` and
// `configurePrimeBassFilters` in MPXGenerator.swift).
//
// Intended behaviour: for bass below the cutoff F0 the stage adds a clean,
// level-tracking harmonic series in F0 .. 5 F0 (2nd, 3rd, 5th ...) on the
// mid channel and touches nothing else -- no gate steps, no DC, no
// intermodulation with the midrange, at most +1.5 dB of peak growth, and the
// direct path dry. The developer-facing pins here mirror the operator-facing
// `--verify-primebass` gate (Verification/PrimeBassGate.swift), measured on a
// transparent chain instead of the shipped one.
//
// Strategy: configure MPXGenerator with the rest of the chain reduced to
// (near) transparent -- mono mode (no pilot / stereo subcarrier / RDS), no
// AGC / multiband / clippers / limiter / pre-emphasis / BS.412 / encoder FIR.
// The composite output is then the baseband mono audio with PrimeBass's
// effect on it, and the ENHANCEMENT is the difference between an enabled
// and a disabled render of the same input.

@Suite("PrimeBass missing-fundamental enhancer")
struct PrimeBassMaxxBassTests {

    private let sampleRate: Float = 192_000.0
    private let fftSize: Int = 131_072  // 0.68 s at 192 kHz: 1.46 Hz bins
    private let warmupFrames: Int = 96_000  // 0.5 s: every envelope settled

    private func makeMinimalChainConfig(
        primeBassEnabled: Bool,
        amount: Double = 0.22,
        harmonics: Double = 0.18,
        drive: Double = 0.78,
        density: Double = 0.45,
        freqHz: Double = 95.0,
        subharmonics: Double = 0.0
    ) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = Double(sampleRate)
        cfg.blockSize = 512
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.monoMode = true
        cfg.processingBypass = false
        cfg.preemphasisUS = 0
        cfg.limitMPX = false
        cfg.preEncodeAudioLimiterEnabled = false
        cfg.audioCompositeSoftClipEnabled = false
        cfg.encoderFIREnabled = false
        cfg.widebandAGCEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false
        cfg.enRDS = false
        cfg.rdsNowPlayingEnabled = false
        cfg.hfTrimDB = 0.0
        cfg.hpfHz = 20.0
        cfg.programLowpassHz = 19_000.0
        cfg.primeBassEnabled = primeBassEnabled
        cfg.primeBassAmount = amount
        cfg.primeBassFreqHz = freqHz
        cfg.primeBassHarmonics = harmonics
        cfg.primeBassDrive = drive
        cfg.primeBassDensity = density
        cfg.primeBassSubharmonicsEnabled = subharmonics > 0.0
        cfg.primeBassSubharmonicsAmount = subharmonics
        return cfg
    }

    private var totalFrames: Int { warmupFrames + fftSize }

    /// Identical left / right (the stage works on mid), the sum of the
    /// given tones; `samples[0]` is 0 for every tone.
    private func tones(_ parts: [(hz: Float, amplitude: Float)]) -> [Float] {
        var out = [Float](repeating: 0.0, count: totalFrames)
        for part in parts {
            let omega = 2.0 * Double.pi * Double(part.hz) / Double(sampleRate)
            for i in 0..<totalFrames {
                out[i] += Float(Double(part.amplitude) * sin(omega * Double(i)))
            }
        }
        return out
    }

    /// Renders through the chain and returns the analysis window (after
    /// warm-up) of the composite = baseband mono audio.
    private func render(config: AppConfig, input: [Float]) -> [Float] {
        let gen = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        var left = input
        var right = input
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                gen.renderFromInputInPlace(
                    frameCount: totalFrames,
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!
                )
            }
        }
        return Array(left[warmupFrames..<totalFrames])
    }

    /// Enabled minus disabled render of the same input: what PrimeBass added.
    private func enhancement(on: AppConfig, off: AppConfig, input: [Float]) -> (on: [Float], off: [Float], diff: [Float]) {
        let outOn = render(config: on, input: input)
        let outOff = render(config: off, input: input)
        var diff = [Float](repeating: 0.0, count: outOn.count)
        for i in 0..<diff.count { diff[i] = outOn[i] - outOff[i] }
        return (outOn, outOff, diff)
    }

    private func rms(_ x: [Float]) -> Float {
        var sum: Double = 0.0
        for v in x { sum += Double(v * v) }
        return Float(sqrt(sum / Double(max(1, x.count))))
    }

    private func peak(_ x: [Float]) -> Float {
        x.reduce(0.0) { max($0, abs($1)) }
    }

    private func db(_ ratio: Float) -> Float {
        20.0 * log10(max(1e-30, ratio))
    }

    /// Band energy ratio (dB) of two frequency ranges of one spectrum.
    private func bandRatioDB(_ spec: SpectralReport, numerator: ClosedRange<Float>, denominator: ClosedRange<Float>) -> Float {
        func power(_ band: ClosedRange<Float>) -> Double {
            let lo = max(1, Int((band.lowerBound / spec.binWidthHz).rounded(.up)))
            let hi = min(spec.binCount - 1, Int((band.upperBound / spec.binWidthHz).rounded(.down)))
            var sum: Double = 0.0
            if lo <= hi {
                for bin in lo...hi {
                    let amp = pow(10.0, Double(spec.magnitudesDBFS[bin]) / 20.0)
                    sum += amp * amp
                }
            }
            return sum
        }
        return Float(10.0 * log10(max(1e-30, power(numerator)) / max(1e-30, power(denominator))))
    }

    @Test func defaultSettingsAddSecondAndThirdHarmonicsCleanly() {
        // A 50 Hz sine at -20 dBFS at the shipped knobs (F0 95 Hz) must
        // come out with a 2nd (100 Hz) and 3rd (150 Hz) harmonic well above
        // the floor, the 2nd not weaker than the 3rd by more than 6 dB,
        // nothing of note above 5 F0 and the fundamental itself untouched.
        let f0: Float = 50.0
        let on = makeMinimalChainConfig(primeBassEnabled: true)
        let off = makeMinimalChainConfig(primeBassEnabled: false)
        let r = enhancement(on: on, off: off, input: tones([(f0, 0.1)]))
        let analyzer = FFTAnalyzer(fftSize: fftSize)
        let specOn = analyzer.analyze(r.on, sampleRate: sampleRate)
        let specOff = analyzer.analyze(r.off, sampleRate: sampleRate)
        let specDiff = analyzer.analyze(r.diff, sampleRate: sampleRate)

        let floor = specOff.peakDBFS(in: 90.0...160.0)
        let second = specDiff.dBFSAt(freqHz: 2 * f0)
        let third = specDiff.dBFSAt(freqHz: 3 * f0)
        #expect(second > floor + 25.0,
            "2nd harmonic must sit >= 25 dB above the floor; got \(second) dBFS vs floor \(floor)")
        #expect(third > floor + 25.0,
            "3rd harmonic must sit >= 25 dB above the floor; got \(third) dBFS vs floor \(floor)")
        #expect(second >= third - 6.0,
            "2nd harmonic must not be weaker than the 3rd by more than 6 dB; got 2nd \(second), 3rd \(third)")

        let fundamentalOn = specOn.dBFSAt(freqHz: f0)
        let fundamentalOff = specOff.dBFSAt(freqHz: f0)
        #expect(abs(fundamentalOn - fundamentalOff) <= 1.0,
            "fundamental must pass within 1 dB (no cancellation); on \(fundamentalOn), off \(fundamentalOff)")

        // Energy above 5 F0 (475 Hz) relative to the harmonic band F0 .. 5 F0.
        let above = bandRatioDB(specDiff, numerator: 480.0...15_000.0, denominator: 55.0...480.0)
        #expect(above <= -40.0,
            "enhancement above 5 F0 must stay >= 40 dB below the harmonic band; got \(above) dB")
    }

    @Test func harmonicRatioIsLevelInvariant() {
        // The band is normalised to unit amplitude before the device and
        // rescaled after it, so the 2nd-to-fundamental ratio must not move
        // with level (the old x^2 law gave loud bass 10 dB more).
        let f0: Float = 50.0
        let on = makeMinimalChainConfig(primeBassEnabled: true)
        let off = makeMinimalChainConfig(primeBassEnabled: false)
        let analyzer = FFTAnalyzer(fftSize: fftSize)
        func ratio(_ amplitude: Float) -> Float {
            let r = enhancement(on: on, off: off, input: tones([(f0, amplitude)]))
            let specDiff = analyzer.analyze(r.diff, sampleRate: sampleRate)
            let specOff = analyzer.analyze(r.off, sampleRate: sampleRate)
            return specDiff.dBFSAt(freqHz: 2 * f0) - specOff.dBFSAt(freqHz: f0)
        }
        let quiet = ratio(0.0316)  // -30 dBFS
        let loud = ratio(0.316)  // -10 dBFS
        #expect(abs(loud - quiet) < 2.0,
            "2F0 / F0 ratio must move < 2 dB over 20 dB of level; -30 dBFS \(quiet), -10 dBFS \(loud)")
    }

    @Test func harmonicsKnobShiftsBalanceFromSecondToThird() {
        // `harmonics` is the even / odd balance: 0 is 2nd-dominant, 1 is
        // 3rd-dominant. Measured away from the output highpass corner (F0
        // 60 Hz, tone 40 Hz) so the filter slope does not decide it.
        let f0: Float = 40.0
        let analyzer = FFTAnalyzer(fftSize: fftSize)
        let off = makeMinimalChainConfig(primeBassEnabled: false, freqHz: 60.0)
        func balance(_ harmonics: Double) -> Float {
            let on = makeMinimalChainConfig(primeBassEnabled: true, harmonics: harmonics, freqHz: 60.0)
            let r = enhancement(on: on, off: off, input: tones([(f0, 0.1)]))
            let spec = analyzer.analyze(r.diff, sampleRate: sampleRate)
            return spec.dBFSAt(freqHz: 2 * f0) - spec.dBFSAt(freqHz: 3 * f0)
        }
        let even = balance(0.0)
        let odd = balance(1.0)
        #expect(even > 6.0, "harmonics 0: 2nd must lead the 3rd by > 6 dB; got \(even) dB")
        #expect(odd < 0.0, "harmonics 1: 3rd must lead the 2nd; got 2nd - 3rd = \(odd) dB")
    }

    @Test func midrangeIsIsolatedFromTheGenerator() {
        // Nothing above F0 may reach the nonlinearity: a 1 kHz tone mixed
        // with the bass produces no 950 / 1050 Hz products, and a 1 kHz
        // tone alone passes with nothing added.
        let on = makeMinimalChainConfig(primeBassEnabled: true)
        let off = makeMinimalChainConfig(primeBassEnabled: false)
        let analyzer = FFTAnalyzer(fftSize: fftSize)

        let mixed = enhancement(on: on, off: off, input: tones([(50.0, 0.1), (1_000.0, 0.1)]))
        let specDiff = analyzer.analyze(mixed.diff, sampleRate: sampleRate)
        let specOff = analyzer.analyze(mixed.off, sampleRate: sampleRate)
        let tone = specOff.dBFSAt(freqHz: 1_000.0)
        let imd = specDiff.sumEnergyDBFS(atBins: [950.0, 1_050.0], toleranceHz: 3.0) - tone
        #expect(imd <= -70.0, "IMD at 950 / 1050 Hz must stay <= -70 dB re the 1 kHz tone; got \(imd) dB")

        let alone = enhancement(on: on, off: off, input: tones([(1_000.0, 0.1)]))
        let residual = db(rms(alone.diff) / max(1e-30, rms(alone.off)))
        #expect(residual <= -90.0,
            "1 kHz alone: the enabled stage must add <= -90 dB re the dry path (max |diff| \(peak(alone.diff))); got \(residual) dB")
    }

    @Test func enhancementIsSmoothAndFreeOfDC() {
        // No gate, no per-sample limiter: the enhancement is a band-limited
        // waveform whose largest sample-to-sample step is a small fraction
        // of its RMS, and the output highpass leaves no DC.
        let f0: Float = 50.0
        let on = makeMinimalChainConfig(primeBassEnabled: true)
        let off = makeMinimalChainConfig(primeBassEnabled: false)
        let r = enhancement(on: on, off: off, input: tones([(f0, 0.1)]))
        var maxJump: Float = 0.0
        for i in 1..<r.diff.count { maxJump = max(maxJump, abs(r.diff[i] - r.diff[i - 1])) }
        let level = rms(r.diff)
        #expect(maxJump / max(1e-30, level) < 0.2,
            "max sample-to-sample jump of the enhancement must stay < 0.2 x its RMS; got \(maxJump / level)")

        // Mean over a whole number of 50 Hz periods = the DC component.
        let period = Int((sampleRate / f0).rounded())
        let count = (r.diff.count / period) * period
        var sum: Double = 0.0
        for i in 0..<count { sum += Double(r.diff[i]) }
        let dc = Float(abs(sum / Double(count)))
        #expect(dc < 1e-4, "enhancement DC must stay below -80 dBFS; got \(db(dc)) dBFS")
    }

    @Test func peakGrowthStaysWithinGuard() {
        // The envelope-based guard limits the added peak to +1.5 dB on a
        // sine and on a beating two-tone bass.
        let on = makeMinimalChainConfig(primeBassEnabled: true)
        let off = makeMinimalChainConfig(primeBassEnabled: false)
        let sine = enhancement(on: on, off: off, input: tones([(50.0, 0.1)]))
        let sineGrowth = db(peak(sine.on) / peak(sine.off))
        #expect(sineGrowth <= 1.5, "50 Hz sine: peak growth must be <= 1.5 dB; got \(sineGrowth) dB")
        let pair = enhancement(on: on, off: off, input: tones([(50.0, 0.1), (70.0, 0.1)]))
        let pairGrowth = db(peak(pair.on) / peak(pair.off))
        #expect(pairGrowth <= 1.5, "50 + 70 Hz: peak growth must be <= 1.5 dB; got \(pairGrowth) dB")
    }

    @Test func fundamentalIsNotCombFilteredAroundTheCutoff() {
        // Time alignment check: the harmonic path's filters delay it by a
        // few ms, but the path carries no fundamental, so the dry path needs
        // no matching delay. Tones at F0 and 0.5 F0 must pass within 1 dB.
        let on = makeMinimalChainConfig(primeBassEnabled: true)
        let off = makeMinimalChainConfig(primeBassEnabled: false)
        let analyzer = FFTAnalyzer(fftSize: fftSize)
        for hz: Float in [47.5, 95.0] {
            let r = enhancement(on: on, off: off, input: tones([(hz, 0.1)]))
            let delta = analyzer.analyze(r.on, sampleRate: sampleRate).dBFSAt(freqHz: hz)
                - analyzer.analyze(r.off, sampleRate: sampleRate).dBFSAt(freqHz: hz)
            #expect(abs(delta) <= 1.0, "\(hz) Hz fundamental must pass within 1 dB; got \(delta) dB")
        }
    }

    @Test func subharmonicOctaveDividerAddsHalfFrequencyOnly() {
        // Subharmonics (off by default) add F/2 for a tone below F0 and keep
        // the divider's square wave band-limited: its 3rd (1.5 F) stays
        // >= 20 dB under the subharmonic. Measured with `amount` 0 so the
        // enhancement is the subharmonic alone.
        let hz: Float = 80.0
        let on = makeMinimalChainConfig(primeBassEnabled: true, amount: 0.0, subharmonics: 0.5)
        let off = makeMinimalChainConfig(primeBassEnabled: false)
        let r = enhancement(on: on, off: off, input: tones([(hz, 0.1)]))
        let spec = FFTAnalyzer(fftSize: fftSize).analyze(r.diff, sampleRate: sampleRate)
        let sub = spec.dBFSAt(freqHz: hz * 0.5)
        let leak = spec.dBFSAt(freqHz: hz * 1.5)
        #expect(sub > -50.0, "subharmonic at 40 Hz must be present; got \(sub) dBFS")
        #expect(leak < sub - 20.0, "divider's 3rd (120 Hz) must stay >= 20 dB under the subharmonic; sub \(sub), leak \(leak)")
    }

    @Test func transientGainBurstsOnAttackAndDecaysOnSustain() {
        // Werrbach transient-discriminate behaviour (US 5,424,488).
        // Direct inspection of the modulator's internal gain factor:
        // the dual-envelope (fast / slow) detector's output should
        // saturate to ~peak (1.4x) shortly after a step onset, then
        // decay back toward floor (~0.7x) as the slow envelope catches
        // up to the fast one. Tested via internal `transientGainObserved`
        // accessor rather than spectral analysis.
        let cfg = makeMinimalChainConfig(primeBassEnabled: true, freqHz: 80.0)
        let gen = MPXGenerator(config: cfg, sampleRate: Double(sampleRate))

        // 50 ms of silence, then a sustained 70 Hz sine for 400 ms so the
        // slow envelope has time to catch up.
        let preStepFrames = Int(0.050 * Double(sampleRate))
        let toneFrames = Int(0.400 * Double(sampleRate))
        let totalFrames = preStepFrames + toneFrames
        var left = [Float](repeating: 0.0, count: totalFrames)
        var right = [Float](repeating: 0.0, count: totalFrames)
        let omega = 2.0 * Double.pi * 70.0 / Double(sampleRate)
        for i in preStepFrames..<totalFrames {
            let s = Float(0.3 * sin(omega * Double(i - preStepFrames)))
            left[i] = s
            right[i] = s
        }

        var gainPreOnset: Float = 0.0
        var gainPostOnsetPeak: Float = 0.0
        var gainSustained: Float = 0.0
        let postOnsetSampleAbsolute = preStepFrames + Int(0.025 * Double(sampleRate))  // 25 ms in
        let sustainedSampleAbsolute = preStepFrames + Int(0.350 * Double(sampleRate))  // 350 ms in

        var leftBlock = [Float](repeating: 0.0, count: 1)
        var rightBlock = [Float](repeating: 0.0, count: 1)
        for i in 0..<totalFrames {
            leftBlock[0] = left[i]
            rightBlock[0] = right[i]
            leftBlock.withUnsafeMutableBufferPointer { lBuf in
                rightBlock.withUnsafeMutableBufferPointer { rBuf in
                    gen.renderFromInputInPlace(
                        frameCount: 1,
                        left: lBuf.baseAddress!,
                        right: rBuf.baseAddress!
                    )
                }
            }
            if i == preStepFrames - 1 { gainPreOnset = gen.primeBassTransientGainObserved }
            if i == postOnsetSampleAbsolute { gainPostOnsetPeak = gen.primeBassTransientGainObserved }
            if i == sustainedSampleAbsolute { gainSustained = gen.primeBassTransientGainObserved }
        }

        #expect(abs(gainPreOnset - 0.7) < 0.05,
            "Before onset, transient gain should be at floor 0.7; got \(gainPreOnset)")
        #expect(gainPostOnsetPeak > 1.25,
            "25 ms after onset, transient gain should be near peak 1.4; got \(gainPostOnsetPeak)")
        #expect(gainSustained < 0.85,
            "After 350 ms of sustained tone, transient gain should be back near floor 0.7; got \(gainSustained)")
        let burstRange = gainPostOnsetPeak - gainSustained
        #expect(burstRange > 0.35,
            "Transient burst should clearly exceed sustained gain; got peak \(gainPostOnsetPeak), sustained \(gainSustained), range \(burstRange)")
    }

    @Test func levelEnvelopeAttacksFastAndReleasesSlow() {
        // The level normaliser's envelope (peak of the fundamental band)
        // attacks within a cycle and releases over ~150 ms, so the
        // harmonic layer holds over a note's decay instead of collapsing.
        let cfg = makeMinimalChainConfig(primeBassEnabled: true, freqHz: 80.0)
        let gen = MPXGenerator(config: cfg, sampleRate: Double(sampleRate))

        // 50 ms silence -> 200 ms sustained 70 Hz sine -> 200 ms silence.
        let preFrames = Int(0.050 * Double(sampleRate))
        let toneFrames = Int(0.200 * Double(sampleRate))
        let postSilenceFrames = Int(0.200 * Double(sampleRate))
        let totalFrames = preFrames + toneFrames + postSilenceFrames
        var left = [Float](repeating: 0.0, count: totalFrames)
        var right = [Float](repeating: 0.0, count: totalFrames)
        let omega = 2.0 * Double.pi * 70.0 / Double(sampleRate)
        for i in preFrames..<(preFrames + toneFrames) {
            let s = Float(0.3 * sin(omega * Double(i - preFrames)))
            left[i] = s
            right[i] = s
        }

        var envPreOnset: Float = 0.0
        var envEarly: Float = 0.0
        var envSustained: Float = 0.0
        var envPostRelease: Float = 0.0
        let earlySample = preFrames + Int(0.020 * Double(sampleRate))  // 20 ms into the tone
        let sustainedSample = preFrames + Int(0.150 * Double(sampleRate))  // 150 ms into the tone
        let postReleaseSample = preFrames + toneFrames + Int(0.050 * Double(sampleRate))  // 50 ms after

        var leftBlock = [Float](repeating: 0.0, count: 1)
        var rightBlock = [Float](repeating: 0.0, count: 1)
        for i in 0..<totalFrames {
            leftBlock[0] = left[i]
            rightBlock[0] = right[i]
            leftBlock.withUnsafeMutableBufferPointer { lBuf in
                rightBlock.withUnsafeMutableBufferPointer { rBuf in
                    gen.renderFromInputInPlace(
                        frameCount: 1,
                        left: lBuf.baseAddress!,
                        right: rBuf.baseAddress!
                    )
                }
            }
            if i == preFrames - 1 { envPreOnset = gen.primeBassLevelEnv }
            if i == earlySample { envEarly = gen.primeBassLevelEnv }
            if i == sustainedSample { envSustained = gen.primeBassLevelEnv }
            if i == postReleaseSample { envPostRelease = gen.primeBassLevelEnv }
        }

        // The band is the LR4-filtered 70 Hz tone (F0 80 Hz: 0.63 x 0.3 =
        // 0.19 peak), and the band filters themselves settle over ~15 ms.
        #expect(envPreOnset < 1e-3, "Before onset the level envelope is silent; got \(envPreOnset)")
        #expect(envEarly > 0.1, "20 ms into a 0.3 amplitude tone the envelope has attacked; got \(envEarly)")
        #expect(envSustained > 0.15, "150 ms in, the envelope sits near the band's peak; got \(envSustained)")
        // 50 ms after the tone ends a 150 ms release has decayed by
        // e^(-50/150) = 0.72 -- the layer holds over the note's decay.
        #expect(envPostRelease > 0.1, "50 ms after the tone, the envelope is still > 0.1 (slow release); got \(envPostRelease)")
        #expect(envSustained > envPostRelease && envPostRelease > envPreOnset,
            "Envelope must be monotonic across sustain (\(envSustained)) > release (\(envPostRelease)) > silence (\(envPreOnset))")
    }

    @Test func disabledStageIsBitIdenticalToItsIdentityPath() {
        // With `primebass_enabled = false` the chain must not touch the
        // signal: byte-identical to the enabled stage's own identity path
        // (amount 0, subharmonics off), which returns its input untouched.
        let input = tones([(50.0, 0.1), (1_000.0, 0.1)])
        let off = render(config: makeMinimalChainConfig(primeBassEnabled: false), input: input)
        let identity = render(config: makeMinimalChainConfig(primeBassEnabled: true, amount: 0.0), input: input)
        #expect(off == identity, "disabled render must be bit-identical to the stage's identity path")
    }

    @Test func disabledPrimeBassPassesThroughTone() {
        // Sanity check: with PrimeBass disabled and the rest of the chain
        // configured transparent, the composite output should contain
        // the input fundamental near its input amplitude with minimal
        // harmonic content.
        let f0: Float = 80.0
        let out = render(config: makeMinimalChainConfig(primeBassEnabled: false), input: tones([(f0, 0.3)]))
        let spec = FFTAnalyzer(fftSize: fftSize).analyze(out, sampleRate: sampleRate)
        let f0Level = spec.dBFSAt(freqHz: f0)
        #expect(f0Level > -16.0,
            "Pass-through tone at F0 must be near input level; got \(f0Level) dBFS")
        let harmEnergy = spec.sumEnergyDBFS(atBins: [2 * f0, 3 * f0, 4 * f0], toleranceHz: 5.0)
        #expect(harmEnergy < -55.0,
            "Pass-through chain should not generate harmonics; got \(harmEnergy) dBFS")
    }
}
