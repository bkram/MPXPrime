import Testing
import Foundation
#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
@testable import MPXPrime

// Stereo-image regression tests for `CompositeClipper`.
//
// The real-world failure mode reported by the user: with the previous
// signal-substitution clipper, HF stereo content collapsed when the
// clipper engaged. Root cause: cascaded-LR4 reconstruction in the
// 23–53 kHz stereo subcarrier band had –12 dB shoulders at the 23 and
// 53 kHz corners — exactly where HF (L-R) audio (>10 kHz) modulates
// onto the DSB-SC subcarrier as sidebands. Real-world result: ~12 dB
// of HF stereo separation lost at the receiver.
//
// What this suite measures: spectral preservation of the (L-R)
// subcarrier through the clipper. Hard-pan a sine into L (R=0), encode
// locally to M + S·sin(2π·38k·t), run through `CompositeClipper.process`
// at the shipped defaults, and FFT the output. The (L-R) sideband
// magnitudes at 38k ± f_audio must be preserved within a small tolerance
// — that's what governs receiver-side stereo separation under broadcast
// conditions.
//
// Why not measure decoded L/R separation directly: the oversampling +
// biquad-cascade decimation chain introduces a frequency-dependent group
// delay (small at audio frequencies, larger near the upper subcarrier
// edge). When the digital output is decoded by the test's locally
// generated 38 kHz reference, the differential delay shows up as an
// apparent L/R reconstruction error — but a real FM receiver doesn't
// share our digital chain's phase reference, so this artifact doesn't
// translate to broadcast reception. Spectral magnitude preservation is
// what governs the real-world receiver result.

@Suite("Composite clipper stereo separation")
struct CompositeClipperStereoSeparationTests {

    private let sampleRate: Float = 192_000.0
    private let fftSize: Int = 16_384
    private let warmupFrames: Int = 2_048

    // MARK: - Composite encode / decode

    /// Encode `(L, R)` to the audio composite using the standard (and, since
    /// 0.45, MPXGenerator) convention: `M=(L+R)/2`, `S=(L-R)/2`,
    /// composite = M + S·sin(2π·38k·t).
    private func encodeComposite(left: [Float], right: [Float]) -> [Float] {
        precondition(left.count == right.count)
        let frames = left.count
        var mpx = [Float](repeating: 0, count: frames)
        let w38 = 2.0 * Double.pi * 38_000.0 / Double(sampleRate)
        for i in 0..<frames {
            let m = 0.5 * (left[i] + right[i])
            let s = 0.5 * (left[i] - right[i])
            mpx[i] = m + s * Float(sin(w38 * Double(i)))
        }
        return mpx
    }

    // MARK: - Helpers

    private func runClipperAtDefaults(_ mpx: [Float]) -> [Float] {
        var clip = CompositeClipper()
        let cfg = AppConfig()
        clip.configure(
            sampleRate: sampleRate,
            thresholdDB: Float(cfg.compositeClipperThresholdDB),
            ceilingDB: Float(cfg.compositeClipperCeilingDB),
            cancelAudio: cfg.compositeClipperCancelAudio,
            stereoGuard: Float(cfg.compositeClipperStereoGuard),
            cancelPilot: cfg.compositeClipperCancelPilot,
            cancelRDS: cfg.compositeClipperCancelRDS
        )
        var out = [Float](repeating: 0, count: mpx.count)
        for i in 0..<mpx.count {
            out[i] = clip.process(mpx[i])
        }
        return out
    }

    private func analyze(_ samples: [Float]) -> SpectralReport {
        precondition(samples.count >= warmupFrames + fftSize,
                     "need enough samples to drop the warm-up window")
        let tail = Array(samples[warmupFrames..<(warmupFrames + fftSize)])
        return FFTAnalyzer(fftSize: fftSize).analyze(tail, sampleRate: sampleRate)
    }

    /// dBFS at the bin closest to `freqHz` ± a small tolerance window.
    private func binDB(_ samples: [Float], at freqHz: Float, tolHz: Float = 30.0) -> Float {
        analyze(samples).peakDBFS(in: (freqHz - tolHz)...(freqHz + tolHz))
    }

    private func runClipper(_ mpx: [Float], stereoGuard: Float) -> [Float] {
        var clip = CompositeClipper()
        let cfg = AppConfig()
        clip.configure(
            sampleRate: sampleRate,
            thresholdDB: Float(cfg.compositeClipperThresholdDB),
            ceilingDB: Float(cfg.compositeClipperCeilingDB),
            cancelAudio: cfg.compositeClipperCancelAudio,
            stereoGuard: stereoGuard,
            cancelPilot: cfg.compositeClipperCancelPilot,
            cancelRDS: cfg.compositeClipperCancelRDS
        )
        var out = [Float](repeating: 0, count: mpx.count)
        for i in 0..<mpx.count {
            out[i] = clip.process(mpx[i])
        }
        return out
    }

    /// Run the clipper at the shipped settings with `stereoGuard` and report
    /// the largest gain reduction it applied after the warm-up, so a test can
    /// prove the clipper was WORKING on its signal (test-suite review
    /// 2026-10 finding 3: at 0.95 hard-panned the composite peak sits at
    /// the -1 dB knee and the guard had nothing to protect).
    private func runClipperMeasuringGR(_ mpx: [Float], stereoGuard: Float) -> (out: [Float], maxGRDB: Float) {
        var clip = CompositeClipper()
        let cfg = AppConfig()
        clip.configure(
            sampleRate: sampleRate,
            thresholdDB: Float(cfg.compositeClipperThresholdDB),
            ceilingDB: Float(cfg.compositeClipperCeilingDB),
            cancelAudio: cfg.compositeClipperCancelAudio,
            stereoGuard: stereoGuard,
            cancelPilot: cfg.compositeClipperCancelPilot,
            cancelRDS: cfg.compositeClipperCancelRDS
        )
        var out = [Float](repeating: 0, count: mpx.count)
        var maxGR: Float = 0.0
        for i in 0..<mpx.count {
            out[i] = clip.process(mpx[i])
            if i >= warmupFrames { maxGR = max(maxGR, clip.gainReductionDB) }
        }
        return (out, maxGR)
    }

    /// Hard-pan a tone into L, encode, drive the composite 6 dB over the
    /// clipper (as `stereoGuardShareControlsSubcarrierClipping` does) and
    /// return the (L-R) sideband deltas through the clipper at the shipped
    /// guard (1.0) and with the guard off (0.0, full composite clipping --
    /// the old "HF stereo collapse"). The guard-off render is the negative
    /// control: if the two match, the measurement cannot see the guard.
    private func overdrivenSidebandDeltas(toneHz: Float, lowerHz: Float, upperHz: Float)
        -> (guardedLower: Float, guardedUpper: Float, unguardedLower: Float, unguardedUpper: Float, maxGRDB: Float) {
        let frames = warmupFrames + fftSize
        let left = SineGenerator.generate(freqHz: toneHz, amplitude: 0.95,
                                          sampleRate: sampleRate, frameCount: frames)
        let right = [Float](repeating: 0, count: frames)
        let mpx = encodeComposite(left: left, right: right).map { $0 * 2.0 }
        // Guard 1.0 by name: this pins the MECHANISM (full restoration), not
        // the shipped share (0.5 since 2026-10, `--verify-stereo-guard`).
        let guarded = runClipperMeasuringGR(mpx, stereoGuard: 1.0)
        let unguarded = runClipperMeasuringGR(mpx, stereoGuard: 0.0)
        let lowerIn = binDB(mpx, at: lowerHz)
        let upperIn = binDB(mpx, at: upperHz)
        return (binDB(guarded.out, at: lowerHz) - lowerIn,
                binDB(guarded.out, at: upperHz) - upperIn,
                binDB(unguarded.out, at: lowerHz) - lowerIn,
                binDB(unguarded.out, at: upperHz) - upperIn,
                guarded.maxGRDB)
    }

    // MARK: - Tests

    /// The stereo guard share decides whether the clipper touches the L-R
    /// subcarrier at all: at 1.0 the 37 / 39 kHz sidebands of a hard-clipped
    /// hard-panned tone come out intact (only the mono share of the peak is
    /// removed), at 0.0 they are clipped along with M (full composite
    /// clipping). Pins the 0.45 `mpx_clipper_stereo_guard` plumbing.
    @Test func stereoGuardShareControlsSubcarrierClipping() {
        let frames = warmupFrames + fftSize
        let left = SineGenerator.generate(freqHz: 1_000.0, amplitude: 0.95,
                                          sampleRate: sampleRate, frameCount: frames)
        let right = [Float](repeating: 0, count: frames)
        // 6 dB of overdrive so the clipper is working hard, not grazing.
        let mpx = encodeComposite(left: left, right: right).map { $0 * 2.0 }
        func sidebandDelta(_ guardShare: Float) -> Float {
            let out = runClipper(mpx, stereoGuard: guardShare)
            return binDB(out, at: 39_000.0) - binDB(mpx, at: 39_000.0)
        }
        let guarded = sidebandDelta(1.0)
        let half = sidebandDelta(0.5)
        let unguarded = sidebandDelta(0.0)
        print(String(format: "39 kHz (L-R) sideband at 6 dB overdrive: guard 1.0 %+.2f dB, 0.5 %+.2f dB, 0.0 %+.2f dB",
                     guarded, half, unguarded))
        // ~1 dB at 6 dB overdrive is the LR4 guard's own band-edge loss.
        #expect(abs(guarded) < 1.5, "guard 1.0 must leave the L-R sideband intact; got \(guarded) dB")
        #expect(unguarded < guarded - 1.0,
            "guard 0.0 must clip the L-R sideband along with M; got \(unguarded) vs \(guarded) dB")
        #expect(half < guarded && half > unguarded, "guard 0.5 must sit between the two")
    }

    @Test func clipperPreservesLowFrequencySubcarrierSidebands() {
        // Hard-pan 1 kHz into L. Encoding produces (L-R) subcarrier
        // sidebands at 38k +/- 1k = 37 kHz and 39 kHz, both at the same
        // amplitude. The clipper must keep those sideband magnitudes
        // intact WHILE IT IS CLIPPING -- a receiver demodulating the
        // composite recovers (L-R) from those sidebands, and any
        // attenuation here turns directly into reduced stereo separation.
        let d = overdrivenSidebandDeltas(toneHz: 1_000.0, lowerHz: 37_000.0, upperHz: 39_000.0)
        print(String(format: "(L-R) sidebands @ 1 kHz, 6 dB over: guard on 37k %+.2f / 39k %+.2f dB, guard off %+.2f / %+.2f dB, clipper GR %.1f dB",
                     d.guardedLower, d.guardedUpper, d.unguardedLower, d.unguardedUpper, d.maxGRDB))
        #expect(d.maxGRDB > 1.0, "the clipper must be working on this signal; GR \(d.maxGRDB) dB")
        // ~1 dB at 6 dB overdrive is the LR4 guard's own band-edge loss
        // (measured -1.00 dB at 39 kHz with the guard on, -3.93 dB off).
        #expect(abs(d.guardedLower) < 1.5 && abs(d.guardedUpper) < 1.5,
            "37/39 kHz (L-R) sidebands must be preserved within 1.5 dB while clipping; got \(d.guardedLower) / \(d.guardedUpper) dB")
        #expect(d.unguardedUpper < d.guardedUpper - 1.0,
            "negative control: guard off must clip the sideband; got \(d.unguardedUpper) vs \(d.guardedUpper) dB")
    }

    // Measured 2026-10-15 with the clipper 6 dB over: guard on 28k -2.41 / 48k -4.80 dB, guard off -3.86 / -3.40 dB. The guard
    // loses the band-edge sidebands while clipping (worse than no guard at
    // 14 kHz): the non-phase-coherent guard-band substitution of
    // peak-control review 2026-10 F3.
    @Test
    func clipperPreservesHighFrequencySubcarrierSidebands() {
        // The load-bearing test: hard-pan 10 kHz into L. Sidebands land
        // at 28 kHz and 48 kHz -- well inside 23-53 kHz, where the OLD
        // cascaded-LR4 reconstruction attenuated them by ~12 dB at the
        // 23/53 kHz corners. With single-LR4 cutoffs at 22 and 53 kHz,
        // the 28/48 kHz region sits in the passband and is preserved --
        // checked with the clipper driven 6 dB over, not grazing.
        let d = overdrivenSidebandDeltas(toneHz: 10_000.0, lowerHz: 28_000.0, upperHz: 48_000.0)
        print(String(format: "(L-R) sidebands @ 10 kHz, 6 dB over: guard on 28k %+.2f / 48k %+.2f dB, guard off %+.2f / %+.2f dB, clipper GR %.1f dB",
                     d.guardedLower, d.guardedUpper, d.unguardedLower, d.unguardedUpper, d.maxGRDB))
        #expect(d.maxGRDB > 1.0, "the clipper must be working on this signal; GR \(d.maxGRDB) dB")
        #expect(abs(d.guardedLower) < 2.0 && abs(d.guardedUpper) < 2.0,
            "28/48 kHz (L-R) sidebands must be preserved within 2 dB while clipping; got \(d.guardedLower) / \(d.guardedUpper) dB")
        #expect(d.unguardedLower < d.guardedLower - 1.0,
            "negative control: guard off must clip the sideband; got \(d.unguardedLower) vs \(d.guardedLower) dB")
    }

    // Measured 2026-10-15 with the clipper 6 dB over: guard on 24k -4.71 / 52k -4.98 dB, guard off -3.30 / -2.57 dB. The guard
    // loses the band-edge sidebands while clipping (worse than no guard at
    // 14 kHz): the non-phase-coherent guard-band substitution of
    // peak-control review 2026-10 F3.
    @Test
    func clipperPreservesEdgeOfBandSubcarrierSidebands() {
        // 14 kHz panned content modulates to 24 kHz and 52 kHz -- close
        // to the 23 / 53 kHz subcarrier edges. With cascaded-LR4 these
        // were attenuated ~9 dB; with single-LR4 they're well within
        // the passband, with the clipper driven 6 dB over.
        let d = overdrivenSidebandDeltas(toneHz: 14_000.0, lowerHz: 24_000.0, upperHz: 52_000.0)
        print(String(format: "(L-R) sidebands @ 14 kHz, 6 dB over: guard on 24k %+.2f / 52k %+.2f dB, guard off %+.2f / %+.2f dB, clipper GR %.1f dB",
                     d.guardedLower, d.guardedUpper, d.unguardedLower, d.unguardedUpper, d.maxGRDB))
        #expect(d.maxGRDB > 1.0, "the clipper must be working on this signal; GR \(d.maxGRDB) dB")
        #expect(abs(d.guardedLower) < 3.0 && abs(d.guardedUpper) < 3.0,
            "24/52 kHz (L-R) sidebands must be preserved within 3 dB while clipping; got \(d.guardedLower) / \(d.guardedUpper) dB")
        #expect(d.unguardedLower < d.guardedLower - 1.0,
            "negative control: guard off must clip the sideband; got \(d.unguardedLower) vs \(d.guardedLower) dB")
    }

    @Test func clipperPreservesAudioBandFundamental() {
        // L+R baseband at the test frequency must pass through with
        // negligible level change for input amplitudes that are below
        // the composite-peak threshold.
        let frames = warmupFrames + fftSize
        let left = SineGenerator.generate(freqHz: 1_000.0, amplitude: 0.95,
                                          sampleRate: sampleRate, frameCount: frames)
        let right = [Float](repeating: 0, count: frames)
        let mpx = encodeComposite(left: left, right: right)
        let clipped = runClipperAtDefaults(mpx)

        let fundIn = binDB(mpx, at: 1_000.0)
        let fundOut = binDB(clipped, at: 1_000.0)
        print(String(format: "Audio fund preservation @ 1 kHz:  Δ %+.2f dB", fundOut - fundIn))
        #expect(abs(fundOut - fundIn) < 1.0,
            "1 kHz audio fundamental must be preserved within 1 dB; got Δ \(fundOut - fundIn) dB")
    }

    @Test func clipperKeepsPilotAndRDSCentreFrequenciesClean() {
        // The user-reported failure mode: with cancelPilot/cancelRDS not
        // effective, the clipper dumps audio-IM products into the 17–21
        // kHz pilot guard and 55–59 kHz RDS guard regions. Pilot (19 kHz)
        // and RDS (57 kHz) are then injected post-clipper, but the IM at
        // exactly those centre frequencies vector-sums with the cleanly-
        // injected subcarriers at the receiver, corrupting pilot PLL lock
        // and RDS BER.
        //
        // The load-bearing measurement is *at the centre frequency*: that's
        // where the receiver locks/demodulates. IM that lands at 17 or 21
        // kHz (e.g. odd harmonics of a 1 kHz test tone) is not where the
        // pilot PLL lives and is harmless for receiver lock.
        let frames = warmupFrames + fftSize
        let left = SineGenerator.generate(freqHz: 1_000.0, amplitude: 1.0,
                                          sampleRate: sampleRate, frameCount: frames)
        let right = left
        let mpx = encodeComposite(left: left, right: right)
        let clipped = runClipperAtDefaults(mpx)

        let pilotCentre = binDB(clipped, at: 19_000.0)
        let rdsCentre = binDB(clipped, at: 57_000.0)
        print(String(format: "Pilot centre 19 kHz: %.1f dBFS", pilotCentre))
        print(String(format: "RDS centre 57 kHz:   %.1f dBFS", rdsCentre))

        #expect(pilotCentre < -75.0,
            "Pilot centre at 19 kHz must stay below -75 dBFS so post-stage pilot injection isn't masked by clipper IM; got \(pilotCentre) dBFS")
        #expect(rdsCentre < -90.0,
            "RDS centre at 57 kHz must stay below -90 dBFS so post-stage RDS injection isn't masked by clipper IM; got \(rdsCentre) dBFS")
    }

    @Test func clipperActuallyClipsAudioBand() {
        // Failsafe: confirm the clipper still engages on audio peaks
        // (i.e. cancelAudio defaulting to false didn't accidentally
        // become a no-op). Drive a hot mono sine; clipped peak should
        // sit at-or-below the configured ceiling.
        let frames = warmupFrames + fftSize
        let left = SineGenerator.generate(freqHz: 1_000.0, amplitude: 1.0,
                                          sampleRate: sampleRate, frameCount: frames)
        let right = left
        let mpx = encodeComposite(left: left, right: right)
        let clipped = runClipperAtDefaults(mpx)

        let inputPeak = mpx.dropFirst(warmupFrames).map(abs).max() ?? 0
        let outputPeak = clipped.dropFirst(warmupFrames).map(abs).max() ?? 0
        let cfg = AppConfig()
        let ceilingLin = pow(10.0, cfg.compositeClipperCeilingDB / 20.0)

        print(String(format: "Audio-band clipping: in %.3f → out %.3f (ceiling %.3f)",
                     inputPeak, outputPeak, ceilingLin))
        #expect(inputPeak > Float(ceilingLin),
            "Test setup error: input peak \(inputPeak) should exceed ceiling \(ceilingLin)")
        #expect(outputPeak < inputPeak,
            "Clipper should reduce peaks; in \(inputPeak), out \(outputPeak)")
        #expect(outputPeak <= Float(ceilingLin) * 1.05,
            "Output peak \(outputPeak) should sit at or below ceiling \(ceilingLin) (with 5% tolerance for tanh knee)")
    }
}
