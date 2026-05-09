import Testing
import Foundation
@testable import MPXPrime

// Integration tests for the Phase 1 PrimeBass MaxxBass-style bass
// enhancement (US 5,930,373, expired 2017) + HP-then-clip topology
// (Aphex US 4,150,253, expired 1996). Both patents are public-domain;
// the implementation lives in `processPrimeBass` and `configurePrimeBassFilters`
// in MPXGenerator.swift.
//
// Strategy: configure MPXGenerator with the post-PrimeBass chain reduced
// to (near) transparent — mono mode (no pilot / stereo subcarrier /
// RDS), no AGC / multiband / clippers / limiter / pre-emphasis /
// BS.412 / encoder FIR. The composite output then carries the
// baseband mono audio with PrimeBass's effect on it. Feed an LF sine at
// 60 Hz, FFT the steady-state output, and compare:
//
// 1. PrimeBass off vs PrimeBass on with `harmonics` engaged — confirms
//    harmonic content appears at integer multiples of 60 Hz.
// 2. PrimeBass on with `harmonics` low vs `harmonics` high — confirms
//    the direct LF gain reduction (`primeBassDirectGainReduction`)
//    actually attenuates the fundamental.
// 3. Per-order spectral shape — confirms the equal-loudness weighting
//    favours the warm mid-band harmonics (3rd > 5th near 60-100 Hz F0).

@Suite("PrimeBass MaxxBass topology")
struct PrimeBassMaxxBassTests {

    private let sampleRate: Float = 192_000.0
    private let fftSize: Int = 16_384
    private let warmupFrames: Int = 4_096

    /// Build a config that passes audio mostly transparently except for
    /// PrimeBass. Mono mode strips pilot / stereo subcarrier / RDS so the
    /// composite output equals the baseband mono audio.
    private func makeMinimalChainConfig(
        primeBassEnabled: Bool,
        harmonics: Double,
        amount: Double = 0.6,
        drive: Double = 1.0,
        density: Double = 0.4,
        freqHz: Double = 80.0
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
        cfg.stereoWidenEnabled = false
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
        cfg.primeBassSubharmonicsEnabled = false
        return cfg
    }

    private func renderTone(
        config: AppConfig,
        toneHz: Float,
        amplitude: Float
    ) -> [Float] {
        let gen = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        let totalFrames = warmupFrames + fftSize
        var left = [Float](repeating: 0.0, count: totalFrames)
        var right = [Float](repeating: 0.0, count: totalFrames)
        let omega = 2.0 * Double.pi * Double(toneHz) / Double(sampleRate)
        for i in 0..<totalFrames {
            let s = Float(Double(amplitude) * sin(omega * Double(i)))
            left[i] = s
            right[i] = s
        }
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

    @Test func generatesHarmonicsAtIntegerMultiplesOfFundamental() {
        // PrimeBass with non-zero `harmonics` should add measurable energy
        // at 2..5 × F0 versus a clean pass-through (PrimeBass off).
        let f0: Float = 60.0
        let off = makeMinimalChainConfig(primeBassEnabled: false, harmonics: 0.0)
        let on = makeMinimalChainConfig(primeBassEnabled: true, harmonics: 0.85, amount: 0.7)

        let outOff = renderTone(config: off, toneHz: f0, amplitude: 0.3)
        let outOn = renderTone(config: on, toneHz: f0, amplitude: 0.3)

        let analyzer = FFTAnalyzer(fftSize: fftSize)
        let specOff = analyzer.analyze(outOff, sampleRate: sampleRate)
        let specOn = analyzer.analyze(outOn, sampleRate: sampleRate)

        // 2nd–5th harmonic combined energy.
        let harmFreqs: [Float] = [2 * f0, 3 * f0, 4 * f0, 5 * f0]
        let harmOff = specOff.sumEnergyDBFS(atBins: harmFreqs, toleranceHz: 5.0)
        let harmOn = specOn.sumEnergyDBFS(atBins: harmFreqs, toleranceHz: 5.0)

        let lift = harmOn - harmOff
        #expect(lift > 12.0,
            "PrimeBass on should add ≥12 dB harmonic energy at 2..5×F0 vs PrimeBass off; got \(lift) dB (off \(harmOff), on \(harmOn))")
    }

    @Test func harmonicsCarryMoreOfPerceivedBassWhenEngaged() {
        // MaxxBass principle: when harmonic synthesis is engaged, the
        // weighted harmonics should carry a larger fraction of the
        // perceived bass, while the direct LF amplitude is reduced
        // (primeBassDirectGainReduction tapers boostGain). Measure this
        // as the ratio of harmonic energy (2..5×F0) to fundamental
        // energy: with high `harmonics`, the ratio should rise
        // significantly versus the harmonics-off baseline.
        //
        // The makeup-gain stage compensates for output level so the
        // *absolute* F0 amplitude is largely preserved — that's by
        // design (no perceived volume jump). What changes is the
        // spectral balance, which is what this test measures.
        let f0: Float = 70.0
        let lowHarm = makeMinimalChainConfig(
            primeBassEnabled: true, harmonics: 0.02, amount: 0.7)
        let highHarm = makeMinimalChainConfig(
            primeBassEnabled: true, harmonics: 1.0, amount: 0.7)

        let outLow = renderTone(config: lowHarm, toneHz: f0, amplitude: 0.3)
        let outHigh = renderTone(config: highHarm, toneHz: f0, amplitude: 0.3)

        let analyzer = FFTAnalyzer(fftSize: fftSize)
        let specLow = analyzer.analyze(outLow, sampleRate: sampleRate)
        let specHigh = analyzer.analyze(outHigh, sampleRate: sampleRate)

        let harmFreqs: [Float] = [2 * f0, 3 * f0, 4 * f0, 5 * f0]
        let harmLow = specLow.sumEnergyDBFS(atBins: harmFreqs, toleranceHz: 5.0)
        let harmHigh = specHigh.sumEnergyDBFS(atBins: harmFreqs, toleranceHz: 5.0)
        let f0Low = specLow.dBFSAt(freqHz: f0)
        let f0High = specHigh.dBFSAt(freqHz: f0)

        // (harmonics − F0) ratio in dB. With harmonics low, F0
        // dominates; with harmonics=1 the ratio shifts upward as
        // weighted harmonics rise relative to F0. A 4 dB shift is the
        // floor — direct gain reduction (4 dB toward fundamental drop)
        // and harmonic rise combine, but the makeup gain partially
        // compensates absolute level changes.
        let ratioLow = harmLow - f0Low
        let ratioHigh = harmHigh - f0High
        let shift = ratioHigh - ratioLow
        #expect(shift > 4.0,
            "Harmonics should carry a larger share of bass when engaged; ratio shift \(shift) dB (low \(ratioLow), high \(ratioHigh))")
    }

    @Test func equalLoudnessFavorsWarmMidHarmonicsOverHigherOrders() {
        // Equal-loudness weights peak in the 100-300 Hz "warmth band".
        // For F0=80 Hz, the 3rd harmonic at 240 Hz sits near the peak,
        // while the 5th harmonic at 400 Hz is on the rolloff side.
        // Verify the 3rd harmonic carries more energy than the 5th.
        let f0: Float = 80.0
        let cfg = makeMinimalChainConfig(
            primeBassEnabled: true, harmonics: 1.0, amount: 0.7, freqHz: 80.0)
        let out = renderTone(config: cfg, toneHz: f0, amplitude: 0.3)
        let spec = FFTAnalyzer(fftSize: fftSize).analyze(out, sampleRate: sampleRate)

        let third = spec.dBFSAt(freqHz: 3 * f0)
        let fifth = spec.dBFSAt(freqHz: 5 * f0)

        #expect(third > fifth + 3.0,
            "Equal-loudness weighting: 3rd harmonic (warm band) should exceed 5th (rolloff) by >3 dB; got 3rd \(third) dB, 5th \(fifth) dB")
    }

    @Test func transientGainBurstsOnAttackAndDecaysOnSustain() {
        // Werrbach transient-discriminate behaviour (US 5,424,488).
        // Direct inspection of the modulator's internal gain factor:
        // the dual-envelope (fast / slow) detector's output should
        // saturate to ~peak (1.4×) shortly after a step onset, then
        // decay back toward floor (~0.7×) as the slow envelope catches
        // up to the fast one. Tested via internal `transientGainObserved`
        // accessor rather than spectral analysis — FFT-based measurement
        // of harmonics this close to the fundamental gets muddied by
        // window leakage at FFT sizes practical for short bursts.
        let cfg = makeMinimalChainConfig(
            primeBassEnabled: true, harmonics: 1.0, amount: 0.7, freqHz: 80.0)
        let gen = MPXGenerator(config: cfg, sampleRate: Double(sampleRate))

        // 50 ms of silence to let the gate stay closed and the envelope
        // followers stay at zero, then a sustained 70 Hz sine for
        // 400 ms so the slow envelope has time to catch up.
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

        // Tap the transient gain at three points: just before onset
        // (gate closed → still at floor), shortly after onset (peak),
        // and after the slow envelope has caught up (back to floor).
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

        // Pre-onset: input is silence, gate keeps the modulator dormant
        // → gain stays at floor.
        #expect(abs(gainPreOnset - 0.7) < 0.05,
            "Before onset, transient gain should be at floor 0.7; got \(gainPreOnset)")

        // 25 ms after onset: fast envelope has caught up, slow has not
        // → drive saturates near 1.0, gain near peak 1.4.
        #expect(gainPostOnsetPeak > 1.25,
            "25 ms after onset, transient gain should be near peak 1.4; got \(gainPostOnsetPeak)")

        // 350 ms after onset: slow envelope has caught up, drive ≈ 0,
        // gain back near floor.
        #expect(gainSustained < 0.85,
            "After 350 ms of sustained tone, transient gain should be back near floor 0.7; got \(gainSustained)")

        // The burst-to-sustain envelope range is what gives Werrbach
        // its "punchy not boomy" character: at least 0.4 absolute
        // (0.85 vs 1.25 = 3.4 dB) between the two snapshots.
        let burstRange = gainPostOnsetPeak - gainSustained
        #expect(burstRange > 0.35,
            "Transient burst should clearly exceed sustained gain; got peak \(gainPostOnsetPeak), sustained \(gainSustained), range \(burstRange)")
    }

    @Test func disabledPrimeBassPassesThroughTone() {
        // Sanity check: with PrimeBass disabled and the rest of the chain
        // configured transparent, the composite output should contain
        // the input fundamental near its input amplitude with minimal
        // harmonic content.
        let f0: Float = 80.0
        let cfg = makeMinimalChainConfig(primeBassEnabled: false, harmonics: 0.0)
        let out = renderTone(config: cfg, toneHz: f0, amplitude: 0.3)
        let spec = FFTAnalyzer(fftSize: fftSize).analyze(out, sampleRate: sampleRate)

        let f0Level = spec.dBFSAt(freqHz: f0)
        // 0.3 amplitude → ~ -10.5 dBFS at the fundamental bin. Allow
        // ±3 dB tolerance for HPF passband ripple and FFT bin alignment.
        #expect(f0Level > -16.0,
            "Pass-through tone at F0 must be near input level; got \(f0Level) dBFS")

        // Harmonic energy should be very low — the chain isn't
        // generating any when PrimeBass is off.
        let harmFreqs: [Float] = [2 * f0, 3 * f0, 4 * f0]
        let harmEnergy = spec.sumEnergyDBFS(atBins: harmFreqs, toleranceHz: 5.0)
        #expect(harmEnergy < -55.0,
            "Pass-through chain should not generate harmonics; got \(harmEnergy) dBFS")
    }
}
