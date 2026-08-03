import Testing
import Foundation
@testable import MPXPrime

// Rule Breaker: experimental SSB-leaning stereo encoder (default off).
// These tests pin (1) config plumbing, (2) the SSB action itself (one
// 38 kHz sideband suppressed at full amount, symmetric at amount 0),
// (3) mono transparency, and (4) chain inertness when off (zero-drift at
// unit level). Receiver-decode separation is gated by --verify-rulebreaker.
@Suite("Rule Breaker SSB stereo encoder")
struct RuleBreakerTests {
    private let sampleRate: Float = 192_000.0

    /// Clean-encode config: processing bypassed so the composite carries
    /// textbook stereo encoding (bypass keeps encode stages active), RDS
    /// off so the 38 kHz region is easy to read.
    private func makeCleanConfig(ruleBreaker: Bool, amount: Double = 1.0) -> AppConfig {
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
        config.audioCompositeSmootherEnabled = false
        config.finalMPXSoftClipEnabled = false
        config.ruleBreakerEnabled = ruleBreaker
        config.ruleBreakerSSBAmount = amount
        return config
    }

    private func renderMPX(
        config: AppConfig, leftHz: Float, rightHz: Float?, frames: Int
    ) -> [Float] {
        let generator = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        var samples = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let l = 0.4 * sinf(2.0 * Float.pi * leftHz * t)
            let r = rightHz.map { 0.4 * sinf(2.0 * Float.pi * $0 * t) } ?? 0.0
            samples[i] = generator.renderSingleSample(leftIn: l, rightIn: r)
        }
        return samples
    }

    private func sidebandAsymmetryDB(config: AppConfig, toneHz: Float) -> Float {
        let fftSize = 65_536
        let samples = renderMPX(
            config: config, leftHz: toneHz, rightHz: nil, frames: fftSize * 2)
        let analyzer = FFTAnalyzer(fftSize: fftSize)
        let report = analyzer.analyze(Array(samples.suffix(fftSize)), sampleRate: sampleRate)
        let lower = report.dBFSAt(freqHz: 38_000.0 - toneHz)
        let upper = report.dBFSAt(freqHz: 38_000.0 + toneHz)
        return abs(lower - upper)
    }

    @Test func runtimeConfigCarriesRuleBreakerFields() {
        var config = AppConfig()
        #expect(config.ruleBreakerEnabled == false)
        config.ruleBreakerEnabled = true
        config.ruleBreakerSSBAmount = 0.42

        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        #expect(runtime.ruleBreakerEnabled == true)
        #expect(abs(runtime.ruleBreakerSSBAmount - 0.42) < 1e-4)
    }

    @Test func iniRoundTripsRuleBreakerKeys() throws {
        var config = AppConfig()
        config.ruleBreakerEnabled = true
        config.ruleBreakerSSBAmount = 0.55

        let ini = try config.captureAsINIString()
        let reloaded = try AppConfig.loadFromINIString(ini)
        #expect(reloaded.ruleBreakerEnabled == true)
        #expect(abs(reloaded.ruleBreakerSSBAmount - 0.55) < 1e-4)
    }

    @Test func fullSSBSuppressesOneSideband() {
        // Classic DSB: symmetric sidebands around 38 kHz. Full SSB: one
        // sideband suppressed. The suppressed side should sit well below
        // the kept side (Hilbert ripple bounds perfection; require the
        // asymmetry to open up by a decisive margin).
        let dsbAsym = sidebandAsymmetryDB(
            config: makeCleanConfig(ruleBreaker: false), toneHz: 10_000.0)
        let ssbAsym = sidebandAsymmetryDB(
            config: makeCleanConfig(ruleBreaker: true, amount: 1.0), toneHz: 10_000.0)
        #expect(dsbAsym < 1.5, "DSB sidebands should be symmetric, got \(dsbAsym) dB")
        #expect(ssbAsym > 15.0,
            "full SSB should suppress one sideband; asymmetry only \(ssbAsym) dB")
    }

    @Test func amountZeroKeepsDSBSymmetry() {
        // amount = 0 is exactly DSB (just delayed): sidebands stay symmetric.
        let asym = sidebandAsymmetryDB(
            config: makeCleanConfig(ruleBreaker: true, amount: 0.0), toneHz: 10_000.0)
        #expect(asym < 1.5, "amount=0 should be plain DSB, got \(asym) dB asymmetry")
    }

    @Test func monoContentPassesUnchanged() {
        // L == R -> diff == 0 -> the encoder contributes nothing: the
        // 38 kHz region stays empty and the mono tone level is unchanged
        // vs the classic path.
        let fftSize = 65_536
        func spectrum(_ ruleBreaker: Bool) -> SpectralReport {
            var config = makeCleanConfig(ruleBreaker: ruleBreaker, amount: 1.0)
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

        var tweaked = base
        tweaked.ruleBreakerEnabled = false
        tweaked.ruleBreakerSSBAmount = 1.0

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
        var config = makeCleanConfig(ruleBreaker: true, amount: 1.0)
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
