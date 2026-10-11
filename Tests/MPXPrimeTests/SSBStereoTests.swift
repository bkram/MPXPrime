import Testing
import Foundation
@testable import MPXPrime

// SSB Stereo: fixed lower-sideband SSB / VSB stereo encoder (default off).
// These tests pin (1) config plumbing, (2) the SSB action itself (the
// UPPER 38 kHz sideband suppressed at full amount at every audio
// frequency, sideband gains summing to 1 at every amount, symmetric at
// amount 0, a selection that never moves), (3) mono transparency, (4) the
// composite-peak COST on 90-degree L/R against theory, and (5) chain
// inertness when off (zero-drift at unit level). Receiver-decode
// separation and the decoder phase-error sweep are gated by
// --verify-ssb-stereo.
@Suite("SSB Stereo encoder")
struct SSBStereoTests {
    private let sampleRate: Float = 192_000.0

    /// Clean-encode config: processing bypassed so the composite carries
    /// textbook stereo encoding (bypass keeps encode stages active), RDS
    /// off so the 38 kHz region is easy to read.
    private func makeCleanConfig(ssbStereo: Bool, amount: Double = 1.0) -> AppConfig {
        var config = AppConfig()
        config.sampleRate = Double(sampleRate)
        config.sourceMode = "input"
        config.processingBypass = true
        config.enRDS = false
        config.limitMPX = false
        config.compositeClipperEnabled = false
        // Keep the composite strictly linear so sideband readings measure
        // the ENCODER, not clipping intermod: no pre-emphasis HF boost, no
        // final drive, no composite soft-clip/smoother. (The first version
        // of this config left drive at +6 dB with 50 us pre-emphasis --
        // the tone hit the always-on soft clip and the "residual sideband"
        // was clipper splatter at a deterministic -14 dB.)
        config.preemphasisUS = 0
        config.finalDriveDB = 0.0
        config.audioCompositeSoftClipEnabled = false
        config.ssbStereoEnabled = ssbStereo
        config.ssbStereoAmount = amount
        return config
    }

    private func renderMPX(
        config: AppConfig, leftHz: Float?, rightHz: Float?, frames: Int
    ) -> [Float] {
        let generator = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        var samples = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let l = leftHz.map { 0.4 * sinf(2.0 * Float.pi * $0 * t) } ?? 0.0
            let r = rightHz.map { 0.4 * sinf(2.0 * Float.pi * $0 * t) } ?? 0.0
            samples[i] = generator.renderSingleSample(leftIn: l, rightIn: r)
        }
        return samples
    }

    /// Encoder-side sideband levels (dBFS) at 38 - f (lower) and 38 + f
    /// (upper) for a single-channel sine, by exact tone projection over the
    /// verifier's analysis window (the last 0.25 s of a 0.5 s render, so
    /// the encoder's delay lines are long settled). No FFT scalloping: the
    /// gain-sum test needs 0.1 dB.
    private func sidebandLevels(
        config: AppConfig, toneHz: Float, driveLeft: Bool = true
    ) -> (lower: Float, upper: Float) {
        let samples = renderMPX(
            config: config,
            leftHz: driveLeft ? toneHz : nil,
            rightHz: driveLeft ? nil : toneHz,
            frames: Int(sampleRate) / 2)
        let metrics = encoderSidebandMetricsFromSamples(
            samples: samples,
            config: config,
            toneHz: Double(toneHz),
            drivenChannel: driveLeft ? "L" : "R")
        return (metrics.lowerSidebandDBFS, metrics.upperSidebandDBFS)
    }

    private func sidebandAsymmetryDB(config: AppConfig, toneHz: Float) -> Float {
        let levels = sidebandLevels(config: config, toneHz: toneHz)
        return abs(levels.lower - levels.upper)
    }

    @Test func runtimeConfigCarriesSSBStereoFields() {
        var config = AppConfig()
        #expect(config.ssbStereoEnabled == false)
        config.ssbStereoEnabled = true
        config.ssbStereoAmount = 0.42

        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        #expect(runtime.ssbStereoEnabled == true)
        #expect(abs(runtime.ssbStereoAmount - 0.42) < 1e-4)
    }

    @Test func iniRoundTripsSSBStereoKeys() throws {
        var config = AppConfig()
        config.ssbStereoEnabled = true
        config.ssbStereoAmount = 0.55

        let ini = try config.captureAsINIString()
        let reloaded = try AppConfig.loadFromINIString(ini)
        #expect(reloaded.ssbStereoEnabled == true)
        #expect(abs(reloaded.ssbStereoAmount - 0.55) < 1e-4)
    }

    @Test func fullSSBSuppressesOneSideband() {
        // Classic DSB: symmetric sidebands around 38 kHz. Full SSB: the
        // UPPER sideband suppressed. The 511-tap Kaiser Hilbert delivers
        // a 60 dB class null at 10 kHz; require 40 dB (the old 15 dB
        // bound only covered the removed selector's chatter).
        let dsbAsym = sidebandAsymmetryDB(
            config: makeCleanConfig(ssbStereo: false), toneHz: 10_000.0)
        let ssb = sidebandLevels(
            config: makeCleanConfig(ssbStereo: true, amount: 1.0), toneHz: 10_000.0)
        let depth = ssb.lower - ssb.upper
        #expect(dsbAsym < 1.5, "DSB sidebands should be symmetric, got \(dsbAsym) dB")
        #expect(depth > 40.0,
            "full SSB should suppress the upper sideband; it is only \(depth) dB below the lower one")
    }

    @Test func ssbKeepsLowerSidebandAtEveryFrequency() {
        // The kept sideband is FIXED at 38 - f: lower sideband, every
        // audio frequency, either channel driven. A sign fault shows the
        // mirror image (upper kept) at every row; the old opportunistic
        // selector showed it at some rows. 40 dB is the gate's bound.
        let config = makeCleanConfig(ssbStereo: true, amount: 1.0)
        for toneHz: Float in [1_000.0, 5_000.0, 10_000.0, 14_000.0] {
            for driveLeft in [true, false] {
                let levels = sidebandLevels(config: config, toneHz: toneHz, driveLeft: driveLeft)
                let depth = levels.lower - levels.upper
                #expect(depth >= 40.0,
                    "\(Int(toneHz)) Hz \(driveLeft ? "L" : "R") drive: upper sideband only \(depth) dB below the lower one")
            }
        }
    }

    @Test func ssbSidebandGainsSumToUnity() {
        // Orban's compatibility condition: the sideband gains (1 + a) / 2
        // and (1 - a) / 2 sum to 1, so a product detector recovers L-R at
        // the DSB level whatever the amount. Linear sideband amplitudes
        // must therefore sum to the same value at amount 0, 0.5 and 1,
        // and equal the classic path's. 5 kHz keeps both sidebands
        // (33 / 43 kHz) well inside the composite FIR's flat passband.
        func sumDB(_ config: AppConfig) -> Float {
            let levels = sidebandLevels(config: config, toneHz: 5_000.0)
            let linear = powf(10.0, levels.lower / 20.0) + powf(10.0, levels.upper / 20.0)
            return 20.0 * log10f(linear)
        }
        let reference = sumDB(makeCleanConfig(ssbStereo: false))
        for amount in [0.0, 0.5, 1.0] {
            let sum = sumDB(makeCleanConfig(ssbStereo: true, amount: amount))
            #expect(abs(sum - reference) < 0.1,
                "amount \(amount): sideband sum \(sum) dBFS vs classic \(reference) dBFS")
        }
    }

    @Test func ssbSelectionIsConstant() {
        // The sideband selection is a constant (-1 = lower in the
        // `dsb - sel * quad` convention): no tracker, no hysteresis, no
        // crossfade, nothing program-dependent to wander.
        #expect(SSBStereoEncoder.lowerSidebandSelection == -1.0)
        var encoder = SSBStereoEncoder()
        encoder.configure(sampleRate: sampleRate)
        encoder.setAmount(1.0)
        #expect(encoder.currentSelection == -1.0)
        for i in 0..<48_000 {
            let t = Float(i) / sampleRate
            let theta = 2.0 * Float.pi * 19_000.0 * t
            let envelope = 1.0 + sinf(2.0 * Float.pi * 3.0 * t)
            let base = 0.4 * sinf(2.0 * Float.pi * 200.0 * t)
            let diff = 0.3 * envelope * sinf(2.0 * Float.pi * 7_000.0 * t)
            _ = encoder.process(base: base, diff: diff, sub: sinf(2.0 * theta), cos2: cosf(2.0 * theta))
            if i % 1_000 == 0 {
                #expect(encoder.currentSelection == -1.0)
            }
        }
        #expect(encoder.currentSelection == -1.0)
    }

    @Test func ssbCompositePeakOnQuadratureLRStaysWithinTheory() {
        // SSB cannot lower a composite peak; on L/R correlated at 90
        // degrees it RAISES it (Orban's overshoot case). For a single tone
        // pair the cost is exactly 20 log10(max(1 + a, sqrt 2) / sqrt 2):
        // +3.01 dB at amount 1, +0.51 dB at 0.5. Pin the measured cost to
        // that theory from both sides: more means a delay or sign fault,
        // less means the encoder is not doing its job. The pilot is off
        // so it cannot dilute the ratio (with it on the same measurement
        // reads 2.1 dB at amount 1); measured 2.97 dB on 2026-10-10.
        func peakDB(_ configIn: AppConfig) -> Float {
            var config = configIn
            config.pilotLevel = 0.0
            let generator = MPXGenerator(config: config, sampleRate: Double(sampleRate))
            let frames = Int(sampleRate) / 2
            var peak: Float = 0.0
            for i in 0..<frames {
                let phase = 2.0 * Float.pi * 1_000.0 * Float(i) / sampleRate
                let mpx = generator.renderSingleSample(leftIn: 0.5 * sinf(phase), rightIn: 0.5 * cosf(phase))
                if i >= frames / 2 { peak = max(peak, abs(mpx)) }
            }
            return 20.0 * log10f(max(peak, 1e-9))
        }
        let off = peakDB(makeCleanConfig(ssbStereo: false))
        for amount in [0.5, 1.0] {
            let delta = peakDB(makeCleanConfig(ssbStereo: true, amount: amount)) - off
            let theory = ssbQuadraturePeakCostDB(amount: Float(amount))
            #expect(abs(delta - theory) <= 0.3,
                "amount \(amount): SSB added \(delta) dB of composite peak, theory \(theory) dB")
        }
    }

    @Test func amountZeroKeepsDSBSymmetry() {
        // amount = 0 is exactly DSB (just delayed): sidebands stay symmetric.
        let asym = sidebandAsymmetryDB(
            config: makeCleanConfig(ssbStereo: true, amount: 0.0), toneHz: 10_000.0)
        #expect(asym < 1.5, "amount=0 should be plain DSB, got \(asym) dB asymmetry")
    }

    @Test func monoContentPassesUnchanged() {
        // L == R -> diff == 0 -> the encoder contributes nothing: the
        // 38 kHz region stays empty and the mono tone level is unchanged
        // vs the classic path.
        let fftSize = 65_536
        func spectrum(_ ssbStereo: Bool) -> SpectralReport {
            var config = makeCleanConfig(ssbStereo: ssbStereo, amount: 1.0)
            config.monoMode = false
            let generator = MPXGenerator(config: config, sampleRate: Double(sampleRate))
            var samples = [Float](repeating: 0.0, count: fftSize * 2)
            for i in 0..<samples.count {
                let t = Float(i) / sampleRate
                let x = 0.4 * sinf(2.0 * Float.pi * 3_000.0 * t)
                samples[i] = generator.renderSingleSample(leftIn: x, rightIn: x)
            }
            let analyzer = FFTAnalyzer(fftSize: fftSize)
            return analyzer.analyze(Array(samples.suffix(fftSize)), sampleRate: sampleRate)
        }
        let off = spectrum(false)
        let on = spectrum(true)
        let toneDelta = abs(on.dBFSAt(freqHz: Float(3_000.0)) - off.dBFSAt(freqHz: Float(3_000.0)))
        #expect(toneDelta < 0.2, "mono tone level moved \(toneDelta) dB")
        // 38 kHz region stays quiet (below -60 dBFS) with the encoder on.
        #expect(on.dBFSAt(freqHz: Float(35_000.0)) < -60.0)
        #expect(on.dBFSAt(freqHz: Float(41_000.0)) < -60.0)
    }

    @Test func disabledStageIsInertInChain() {
        // Zero-drift at unit level: toggle OFF but amount tweaked must be
        // bit-identical to a default config.
        var base = AppConfig()
        base.sampleRate = Double(sampleRate)
        base.sourceMode = "input"
        // RDS OFF: the text scheduler paces by WALL CLOCK, so two generators
        // rendered in the same loop can emit different bits on a busy machine
        // (the documented offline-comparison rule in AGENTS.md).
        base.enRDS = false

        var tweaked = base
        tweaked.ssbStereoEnabled = false
        tweaked.ssbStereoAmount = 1.0

        let genA = MPXGenerator(config: base, sampleRate: Double(sampleRate))
        let genB = MPXGenerator(config: tweaked, sampleRate: Double(sampleRate))
        for i in 0..<24_000 {
            let t = Float(i) / sampleRate
            let l = 0.5 * sinf(2.0 * Float.pi * 1_000.0 * t)
            let r = 0.4 * sinf(2.0 * Float.pi * 3_000.0 * t)
            let a = genA.renderSingleSample(leftIn: l, rightIn: r)
            let b = genB.renderSingleSample(leftIn: l, rightIn: r)
            #expect(a == b)
            if a != b { break }
        }
    }

    @Test func hostileInputStaysFinite() {
        var config = makeCleanConfig(ssbStereo: true, amount: 1.0)
        config.processingBypass = false
        let generator = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        for i in 0..<48_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = Float(Int64(bitPattern: seed) % 1_000_000) / 500_000.0
            let x: Float = i % 4 == 0 ? 1.4 : r
            let mpx = generator.renderSingleSample(leftIn: x, rightIn: -x)
            #expect(mpx.isFinite)
            if !mpx.isFinite { break }
        }
    }
}
