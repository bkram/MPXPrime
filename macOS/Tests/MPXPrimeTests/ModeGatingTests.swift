import Testing
import Foundation
@testable import MPXPrime

// The operator's rule for 0.50: what has no function in the current operating
// mode is switched off in the engine AND invisible in both interfaces. These
// tests pin the pairing -- a feature that is merely HIDDEN while its stage
// still runs (or still polls an external script) is the defect this change
// removes, not a cosmetic difference.
@Suite("Operating mode gating")
struct ModeGatingTests {

    // MARK: - The table itself

    @Test func compositeOnlyFeaturesExistOnlyInMPX() {
        for feature in [ChainFeature.stereoCoder, .compositeClipper, .bs412, .finalStage,
                        .rds, .monitorPath] {
            #expect(feature.applies(in: .mpx), "\(feature) must exist in MPX Output")
            for mode in [AppConfig.OperatingMode.fm, .hd, .am] {
                #expect(!feature.applies(in: mode),
                        "\(feature) has no composite to act on in \(mode.title)")
            }
        }
    }

    @Test func modeSpecificFeaturesAreExclusive() {
        #expect(ChainFeature.digitalCeiling.modes == ["hd"])
        #expect(ChainFeature.amShaping.modes == ["am"])
        #expect(ChainFeature.coderFinalClipper.modes == ["fm"])
        #expect(ChainFeature.preemphasis.modes == ["mpx", "fm"])
        #expect(ChainFeature.stereoImage.modes == ["mpx", "fm"])
    }

    // MARK: - Config plumbing

    @Test func everyModeRoundTripsThroughTheINI() throws {
        for mode in AppConfig.OperatingMode.allCases {
            var cfg = AppConfig()
            cfg.operatingMode = mode
            let restored = try AppConfig.loadFromINIString(cfg.captureAsINIString())
            #expect(restored.operatingMode == mode, "\(mode.rawValue) did not survive a save/load")
            #expect(restored.processedAudioOutput == mode.isAudioOutput)
        }
    }

    @Test func preZeroFiftyINIMigratesToTheMode() throws {
        // The two keys `operating_mode` replaced, as a 0.45-era INI carries them.
        func migrated(_ output: String, _ target: String) throws -> AppConfig.OperatingMode {
            let ini = """
            [INTERFACES]
            processed_audio_output = \(output)
            processed_audio_target = \(target)
            """
            return try AppConfig.loadFromINIString(ini).operatingMode
        }
        #expect(try migrated("False", "fm_coder") == .mpx)
        #expect(try migrated("False", "digital") == .mpx, "the target is meaningless without the output flag")
        #expect(try migrated("True", "fm_coder") == .fm)
        #expect(try migrated("True", "digital") == .hd)
        // ...and the new key wins when both are present (a migrated INI that
        // an old client then patched keeps the mode the operator chose).
        let both = try AppConfig.loadFromINIString("""
        [INTERFACES]
        operating_mode = hd
        processed_audio_output = False
        processed_audio_target = fm_coder
        """)
        #expect(both.operatingMode == .hd)
    }

    @Test func modeIsRestartClassInEveryDirection() throws {
        for from in AppConfig.OperatingMode.allCases {
            for to in AppConfig.OperatingMode.allCases where to != from {
                var cfg = AppConfig()
                cfg.operatingMode = from
                let (patched, outcomes, planes) = try ConfigPatch.apply(
                    ["operating_mode": to.rawValue], to: cfg)
                #expect(patched.operatingMode == to)
                #expect(outcomes[0].disposition == .restartRequired,
                        "\(from.rawValue) -> \(to.rawValue) reported \(outcomes[0].disposition)")
                #expect(planes.restartRequired && !planes.rdsLive,
                        "\(from.rawValue) -> \(to.rawValue) must not look like a live RDS edit")
            }
        }
    }

    // MARK: - The engine side of the pairing

    /// A generator built for `mode`, rendered on a short program.
    private func renderComposite(mode: AppConfig.OperatingMode, enRDS: Bool) -> [Float] {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        cfg.operatingMode = mode
        cfg.enRDS = enRDS
        cfg.sourceMode = "input"
        let gen = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        var out = [Float](repeating: 0, count: 4_096)
        for i in 0..<out.count {
            let t = Double(i) / cfg.sampleRate
            out[i] = Float(0.3 * sin(2.0 * .pi * 1_000.0 * t))
        }
        var left = out
        var right = out
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable force_unwrapping
                if mode.isAudioOutput {
                    gen.renderAudioOnlyFromInputInPlace(
                        frameCount: l.count, left: l.baseAddress!, right: r.baseAddress!)
                } else {
                    gen.renderFromInputInPlace(
                        frameCount: l.count, left: l.baseAddress!, right: r.baseAddress!)
                }
                // swiftlint:enable force_unwrapping
            }
        }
        return left
    }

    @Test func rdsIsInertOutsideMPXEvenWhenTheKeyIsOn() {
        // en_rds stays true in the config (the operator's stored intent), but
        // an engine built for a mode with no composite must not run the coder.
        for mode in [AppConfig.OperatingMode.fm, .hd, .am] {
            var cfg = AppConfig()
            cfg.operatingMode = mode
            cfg.enRDS = true
            let gen = MPXGenerator(config: cfg, sampleRate: 192_000.0)
            gen.applyRDSRuntimeConfig(MPXGenerator.RDSRuntimeConfig.make(from: cfg))
            let withRDS = renderComposite(mode: mode, enRDS: true)
            let withoutRDS = renderComposite(mode: mode, enRDS: false)
            #expect(withRDS == withoutRDS,
                    "\(mode.title) output changed with RDS enabled -- the encoder is not gated")
        }
    }

    @Test func nowPlayingPollerFollowsTheMode() {
        // The concrete complaint: a processed-audio box kept polling an
        // external metadata script for a feed nobody transmits.
        var cfg = AppConfig()
        cfg.rdsNowPlayingEnabled = true
        cfg.rdsNowPlayingScript = "/usr/bin/true"
        for mode in AppConfig.OperatingMode.allCases {
            cfg.operatingMode = mode
            let settings = NowPlayingScriptRunner.Settings(config: cfg)
            #expect(settings.enabled == (mode == .mpx),
                    "Now Playing polling in \(mode.title) should be \(mode == .mpx)")
        }
    }

    @Test func ssbStereoIsInertOutsideMPX() {
        // "SSB stereo coder is not correctly gated": there is no stereo
        // encoder to lean outside MPX Output, so the flag must not reach the
        // chain (nor allocate its Hilbert FIRs).
        for mode in [AppConfig.OperatingMode.fm, .hd, .am] {
            var plain = AppConfig()
            plain.operatingMode = mode
            plain.sampleRate = 192_000.0
            var ssb = plain
            ssb.ssbStereoEnabled = true
            ssb.ssbStereoAmount = 1.0
            let a = renderAudioOnly(cfg: plain)
            let b = renderAudioOnly(cfg: ssb)
            #expect(a == b, "\(mode.title) output changed with SSB enabled -- the encoder is not gated")
        }
    }

    @Test func hiddenControlsAreTheInertOnes() {
        // The rule the operator set: a control is hidden because it does
        // nothing here, not to tidy the page. So prove the "nothing": with the
        // feature gated out of a mode, moving its keys must not change a
        // sample. A control that FAILS this belongs on screen instead.
        //
        // These two are inert by construction rather than by a gate --
        // `stereoProgram` because AM sums L+R ahead of the chain, `hfLimiter`
        // because the stage rides the pre-emphasis boost and the digital
        // target is flat -- which is exactly why they need a test: a chain
        // change could quietly give them an effect again while both
        // interfaces keep hiding them.
        var stereoBase = AppConfig()
        stereoBase.operatingMode = .am
        stereoBase.sampleRate = 192_000.0
        stereoBase.monoMode = false
        stereoBase.monoBassEnabled = false
        var stereoMoved = stereoBase
        stereoMoved.monoMode = true
        stereoMoved.monoBassEnabled = true
        stereoMoved.monoBassFreqHz = 220.0
        stereoMoved.multibandLinkStrength = 1.0 - stereoBase.multibandLinkStrength
        #expect(!ChainFeature.stereoProgram.applies(in: .am))
        #expect(renderAudioOnly(cfg: stereoBase, stereo: true) == renderAudioOnly(cfg: stereoMoved, stereo: true),
                "AM output moved when a stereo-only control moved -- it is hidden but not inert")

        var hfBase = AppConfig()
        hfBase.operatingMode = .hd
        hfBase.sampleRate = 192_000.0
        hfBase.hfLimiterEnabled = false
        var hfOn = hfBase
        hfOn.hfLimiterEnabled = true
        hfOn.hfLimiterThresholdDB = -12.0
        hfOn.hfLimiterMaxReductionDB = 24.0
        #expect(!ChainFeature.hfLimiter.applies(in: .hd))
        #expect(renderAudioOnly(cfg: hfBase, stereo: true) == renderAudioOnly(cfg: hfOn, stereo: true),
                "HD output moved when the HF limiter was enabled -- it is hidden but not inert")
    }

    private func renderAudioOnly(cfg: AppConfig, stereo: Bool = false) -> [Float] {
        let gen = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        gen.setAudioOutputOnly(true)
        var l = [Float](repeating: 0, count: 4_096)
        var r = [Float](repeating: 0, count: 4_096)
        for i in 0..<l.count {
            let t = Double(i) / cfg.sampleRate
            // Bass + HF, and a different signal per channel when asked, so a
            // stage that acts on the difference or on the pre-emphasis boost
            // has something to act on.
            let bass = 0.30 * sin(2.0 * .pi * 60.0 * t)
            let high = 0.25 * sin(2.0 * .pi * 11_000.0 * t)
            l[i] = Float(bass + high + 0.20 * sin(2.0 * .pi * 1_000.0 * t))
            r[i] = stereo ? Float(-bass + 0.9 * high + 0.20 * sin(2.0 * .pi * 1_500.0 * t)) : l[i]
        }
        var left = l
        var right = r
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                // swiftlint:disable:next force_unwrapping
                gen.renderAudioOnlyFromInputInPlace(frameCount: lb.count, left: lb.baseAddress!, right: rb.baseAddress!)
            }
        }
        return left
    }
}
