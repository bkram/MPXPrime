import Testing
import Foundation
@testable import MPXPrime

// The stereo-image protector (`protectStereoImage`) became an operator option
// on 2026-10-20 (stereo audit A3 / C1): `stereo_image_protect_enabled`,
// default OFF, and `stereo_image_max_side_ratio` (1.55 = the former fixed
// cap). Always on before that, it was the removed widener's safety net and,
// with every remaining dynamics stage stereo-linked, the only width left for
// it to limit was the source's own: anti-phase content lost 24 dB of RMS to
// an absolute 0.008 side floor, and very wide content was clamped to a 1.55
// side/mid ratio. These tests pin the four things the change promises:
//
// 1. OFF is the chain without the stage, bit for bit (not "the stage at
//    gain 1.0": `(L+R)/2 + (L-R)/2` is not L in Float arithmetic).
// 2. OFF: pure-side content keeps its level like mono content does, and a
//    wide image keeps its width.
// 3. ON still limits a widened image the way the always-on stage did, but
//    no longer crushes pure-side content (the absolute floor is gone).
// 4. ON reads its input reference through a delay equal to the audio-domain
//    latency between its two taps.
//
// Every render runs with RDS off: the RDS text scheduler paces by wall clock
// and would make two otherwise identical renders differ.
@Suite("Stereo-image protector option")
struct StereoImageProtectorOptionTests {

    private static let rate = 192_000.0

    /// The shipped defaults as a composite (what `--verify` measures through
    /// Verification.ini, less that file's own choices), RDS off.
    private static func compositeConfig() -> AppConfig {
        var c = AppConfig()
        c.sampleRate = rate
        c.operatingMode = .mpx
        c.enRDS = false
        c.processingBypass = false
        return c
    }

    private static func scenario(_ name: String) -> VerificationScenario {
        // A fresh table per call: the program-like scenarios carry their
        // noise generators as shared state inside the closure, so two
        // renders of the SAME scenario value would see different noise.
        guard let s = verificationScenarios().first(where: { $0.name == name }) else {
            Issue.record("scenario \(name) missing from verificationScenarios()")
            return VerificationScenario(name: name, description: "", quality: .none) { _, _ in (0.0, 0.0) }
        }
        return s
    }

    /// Composite render of a verification scenario through a generator the
    /// caller may pre-configure (the test hook lives on the generator).
    private static func renderComposite(
        _ cfg: AppConfig,
        scenarioName: String,
        seconds: Double = 0.5,
        configure: (MPXGenerator) -> Void = { _ in }
    ) -> [Float] {
        let gen = MPXGenerator(config: cfg, sampleRate: rate)
        configure(gen)
        let source = scenario(scenarioName)
        let frames = Int(rate * seconds)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let s = source.sample(i, rate)
            left[i] = s.0
            right[i] = s.1
        }
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                var offset = 0
                while offset < frames {
                    let n = min(1_024, frames - offset)
                    gen.renderFromInputInPlace(
                        frameCount: n,
                        // swiftlint:disable force_unwrapping
                        left: lb.baseAddress!.advanced(by: offset),
                        right: rb.baseAddress!.advanced(by: offset))
                        // swiftlint:enable force_unwrapping
                    offset += n
                }
            }
        }
        return left
    }

    private static func metrics(_ cfg: AppConfig, _ name: String, seconds: Double = 1.5) -> VerificationMetrics {
        verifyScenario(config: cfg, durationSeconds: seconds, scenario: scenario(name))
    }

    // MARK: - 1. OFF is the chain without the stage

    @Test func offIsBitIdenticalToAChainWithoutTheCall() {
        // `omitStereoImageProtectorForTest` removes the call whatever the
        // config says. A generator configured ON (coefficients computed,
        // ratio adopted) but with the call omitted is the chain "with the
        // stage compiled out"; the OFF config must render exactly that, and
        // the ratio key must be inert while OFF.
        for name in ["mono_1khz", "program_mix", "stereo_diff_400hz", "wide_bass"] {
            var off = Self.compositeConfig()
            off.stereoImageProtectEnabled = false
            let offRender = Self.renderComposite(off, scenarioName: name)

            var on = off
            on.stereoImageProtectEnabled = true
            on.stereoImageMaxSideRatio = 1.0
            let compiledOut = Self.renderComposite(on, scenarioName: name) { $0.omitStereoImageProtectorForTest = true }
            #expect(offRender == compiledOut,
                    "\(name): protector OFF is not bit-identical to the chain without the call")

            var offOtherRatio = off
            offOtherRatio.stereoImageMaxSideRatio = 3.0
            #expect(offRender == Self.renderComposite(offOtherRatio, scenarioName: name),
                    "\(name): the ratio key moved the output while the protector is OFF")

            // ...and ON must not be the same render on an image the stage
            // acts on, or the comparison above proves nothing. (Not on
            // stereo_diff_400hz: pure-side content has no mid reference, so
            // ON is idle there by design -- `onLeavesPureSideContentAlone`.)
            if name == "wide_bass" {
                let onRender = Self.renderComposite(on, scenarioName: name)
                #expect(onRender != offRender, "\(name): protector ON at ratio 1.0 rendered the OFF chain")
            }
        }
    }

    // MARK: - 2. OFF keeps level and width

    @Test func antiPhaseToneKeepsItsLevelWithinTwoDecibelsOfTheMonoTone() {
        // stereo_diff_400hz (L = -R, 0.5) against mono_1khz (0.55 both
        // channels): the stored baseline read -24.3 dB against -4.7 dB with
        // the always-on protector (its 0.008 floor crushed pure-side content
        // to -42 dBFS). Without the stage the two are the linked limiters'
        // doing alone and sit within 2 dB of each other.
        let cfg = Self.compositeConfig()
        let mono = Self.metrics(cfg, "mono_1khz").rmsDeltaDB
        let diff = Self.metrics(cfg, "stereo_diff_400hz").rmsDeltaDB
        print(String(format: "[protector OFF] rmsDeltaDB mono_1khz %+.2f dB, stereo_diff_400hz %+.2f dB", mono, diff))
        #expect(abs(diff - mono) <= 2.0,
                "anti-phase tone lost \(diff) dB against \(mono) dB for the mono tone (limit: within 2 dB)")
    }

    @Test func wideBassKeepsAtLeastNinetyFivePercentOfItsWidth() {
        // wide_bass: input S/M 1.79 -> 1.54 (the 1.55 cap) with the stage on,
        // retention 0.86. Mono bass off here as in Verification.ini: with it
        // on the 72 Hz anti-phase component is summed to mono by design.
        var cfg = Self.compositeConfig()
        cfg.monoBassEnabled = false
        let m = Self.metrics(cfg, "wide_bass")
        let retention = m.outputSignal.sideToMidRatio / max(0.001, m.inputSignal.sideToMidRatio)
        print(String(format: "[protector OFF] wide_bass S/M in %.3f out %.3f retention %.3f", m.inputSignal.sideToMidRatio, m.outputSignal.sideToMidRatio, retention))
        #expect(retention >= 0.95, "wide_bass side retention \(retention) < 0.95 with the protector OFF")
    }

    // MARK: - 3. ON limits a widened image, not pure-side content

    @Test func onReproducesTheFormerLimitingOnAWidenedImage() {
        var cfg = Self.compositeConfig()
        cfg.monoBassEnabled = false
        cfg.stereoImageProtectEnabled = true
        cfg.stereoImageMaxSideRatio = 1.55
        let m = Self.metrics(cfg, "wide_bass")
        let retention = m.outputSignal.sideToMidRatio / max(0.001, m.inputSignal.sideToMidRatio)
        print(String(format: "[protector ON] wide_bass S/M in %.3f out %.3f retention %.3f", m.inputSignal.sideToMidRatio, m.outputSignal.sideToMidRatio, retention))
        #expect(m.outputSignal.sideToMidRatio <= 1.62,
                "ON: output side/mid \(m.outputSignal.sideToMidRatio) is over the 1.55 cap")
        #expect(retention < 0.92,
                "ON: wide_bass retention \(retention) -- the stage did not limit the widened image (the always-on stage read 0.86)")

        // A tighter cap limits harder; the key is live and monotonic.
        cfg.stereoImageMaxSideRatio = 1.0
        let tight = Self.metrics(cfg, "wide_bass")
        #expect(tight.outputSignal.sideToMidRatio < m.outputSignal.sideToMidRatio,
                "ON: ratio 1.0 (\(tight.outputSignal.sideToMidRatio)) did not narrow further than 1.55 (\(m.outputSignal.sideToMidRatio))")
    }

    @Test func onLeavesPureSideContentAlone() {
        // The absolute 0.008 side floor is gone: without a mid reference the
        // stage has no ratio to hold and pure-side content passes. ON and
        // OFF must agree within 1 dB on stereo_diff_400hz.
        var off = Self.compositeConfig()
        off.stereoImageProtectEnabled = false
        var on = off
        on.stereoImageProtectEnabled = true
        let offDelta = Self.metrics(off, "stereo_diff_400hz").rmsDeltaDB
        let onDelta = Self.metrics(on, "stereo_diff_400hz").rmsDeltaDB
        print(String(format: "[stereo_diff_400hz] rmsDeltaDB OFF %+.2f dB, ON %+.2f dB", offDelta, onDelta))
        #expect(abs(onDelta - offDelta) <= 1.0,
                "ON crushed pure-side content: \(onDelta) dB against \(offDelta) dB OFF")
    }

    // MARK: - 4. The reference is delay-matched to the output tap

    @Test func referenceDelayFollowsTheStagesBetweenTheTaps() {
        // Between the reference tap (after the programme lowpass) and the
        // output tap (after the encoder FIR) only the linear-phase stages
        // delay the signal: mono bass, the leveller's FIR split, the
        // distortion-cancelled clipper and the encoder FIR. The delay must
        // be their sum for the stages that are ON, and nothing else.
        var cfg = Self.compositeConfig()
        cfg.stereoImageProtectEnabled = true
        cfg.advancedDynamicsEnabled = false
        cfg.multibandEnabled = false
        cfg.monoBassEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bassClipperEnabled = true
        cfg.primeBassEnabled = true
        cfg.parametricEQEnabled = true

        let encoderOnly = MPXGenerator(config: cfg, sampleRate: Self.rate)
        #expect(encoderOnly.stereoImageProtectorReferenceDelaySamples == encoderOnly.encoderFIRGroupDelaySamples,
                "with only the encoder FIR between the taps the delay must be its group delay")
        encoderOnly.setEncoderFIREnabled(false)
        #expect(encoderOnly.stereoImageProtectorReferenceDelaySamples == 0,
                "IIR-only stages between the taps must give a zero reference delay")

        var withMonoBass = cfg
        withMonoBass.monoBassEnabled = true
        withMonoBass.monoBassFreqHz = 140.0
        let gen = MPXGenerator(config: withMonoBass, sampleRate: Self.rate)
        // The audio domain runs at the dual-rate boundary's rate on this
        // composite config (192 kHz / 4 = 48 kHz), which is where the mono
        // bass filter is designed.
        var reference = MonoBassFilter()
        reference.configure(cutoffHz: 140.0, sampleRate: Float(withMonoBass.dualRateAudioDomainRateHz))
        #expect(gen.stereoImageProtectorReferenceDelaySamples
                    == gen.encoderFIRGroupDelaySamples + reference.groupDelaySamples,
                "mono bass ON must add its group delay (\(reference.groupDelaySamples)) to the reference delay")

        // Live: switching mono bass off takes its delay back out.
        var without = withMonoBass
        without.monoBassEnabled = false
        gen.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: without))
        #expect(gen.stereoImageProtectorReferenceDelaySamples == gen.encoderFIRGroupDelaySamples)
    }
}
