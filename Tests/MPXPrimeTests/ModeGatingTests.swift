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
        for feature in [ChainFeature.stereoCoder, .compositeClipper, .bs412, .finalStage, .rds] {
            #expect(feature.applies(in: .mpx), "\(feature) must exist in MPX Output")
            for mode in [AppConfig.OperatingMode.fm, .hd, .am] {
                #expect(!feature.applies(in: mode),
                        "\(feature) has no composite to act on in \(mode.title)")
            }
        }
    }

    @Test func aPreZeroFiftyMonitorConfigDoesNotStartAnythingUnannounced() throws {
        // Before 0.50, `monitor_enabled = True` meant the monitor REPLACED the
        // transmitter feed: the output device sat idle. It now means a second
        // device plays as well -- so inheriting the flag silently would start a
        // composite on an output that used to be quiet. An INI written before
        // the change has no `monitor_gain_db`, and that is the marker.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpxprime-monitor-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("legacy.ini").path
        try """
        [INTERFACES]
        operating_mode = mpx
        monitor_enabled = True
        monitor_device_uid = speakers
        """.write(toFile: path, atomically: true, encoding: .utf8)

        let legacy = try AppConfig.load(fromINI: path)
        #expect(!legacy.monitorEnabled, "a pre-0.50 monitor config switched itself on")
        #expect(legacy.monitorLegacyModeReset, "the operator is not told why it is off")
        #expect(legacy.monitorDeviceUID == "speakers", "the device choice must survive")

        // A config written by this version carries the level, so it is taken
        // at face value.
        try """
        [INTERFACES]
        operating_mode = mpx
        monitor_enabled = True
        monitor_gain_db = -6.0
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let current = try AppConfig.load(fromINI: path)
        #expect(current.monitorEnabled)
        #expect(!current.monitorLegacyModeReset)
    }

    @Test func theMonitorExistsInEveryMode() {
        // Listening is not a property of the output shape. The operator asked
        // for exactly this: hear the programme without tuning a receiver to
        // the transmitter, whatever the box is feeding.
        for mode in AppConfig.OperatingMode.allCases {
            #expect(ChainFeature.monitorPath.applies(in: mode),
                    "no monitor in \(mode.title)")
        }
    }

    @Test func modeSpecificFeaturesAreExclusive() {
        #expect(ChainFeature.digitalCeiling.modes == ["hd"])
        #expect(ChainFeature.amShaping.modes == ["am"])
        #expect(ChainFeature.coderFinalClipper.modes == ["fm"])
        #expect(ChainFeature.preemphasis.modes == ["mpx", "fm"])
        #expect(ChainFeature.stereoImage.modes == ["mpx", "fm"])
        #expect(ChainFeature.hfLimiter.modes == ["mpx", "fm", "am"])
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

    /// Render the COMPOSITE path of `gen` itself -- the one that calls the RDS
    /// coder and the stereo encoder -- on a programme with a different signal
    /// per channel. The audio-only path never reaches either, so comparing
    /// audio-only renders cannot see whether the gate holds (test-suite
    /// review 2026-10 finding 7: with the SSB gate removed at
    /// construction and on live apply, and the RDS live gate removed, all 11
    /// tests here stayed green). Driving the composite path of a generator
    /// built for an audio mode is a probe, not a production path: it exposes
    /// the gated state as output.
    private func renderCompositePath(_ gen: MPXGenerator, frames: Int = 19_200) -> [Float] {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / 192_000.0
            left[i] = Float(0.3 * sin(2.0 * .pi * 1_000.0 * t))
            right[i] = Float(0.2 * sin(2.0 * .pi * 3_000.0 * t))
        }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                gen.renderFromInputInPlace(frameCount: l.count, left: l.baseAddress!, right: r.baseAddress!)
            }
        }
        return left
    }

    private func gatingConfig(_ mode: AppConfig.OperatingMode) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        cfg.operatingMode = mode
        cfg.sourceMode = "input"
        cfg.enRDS = false
        cfg.ssbStereoEnabled = false
        return cfg
    }

    @Test func rdsIsInertOutsideMPXEvenWhenTheKeyIsOn() {
        // en_rds stays true in the config (the operator's stored intent), but
        // a live RDS apply on an engine built for a mode with no composite
        // must not switch the coder on. The configured generator is the one
        // rendered.
        for mode in AppConfig.OperatingMode.allCases {
            let plain = gatingConfig(mode)
            var keyOn = plain
            keyOn.enRDS = true
            let reference = renderCompositePath(MPXGenerator(config: plain, sampleRate: 192_000.0))
            let live = MPXGenerator(config: plain, sampleRate: 192_000.0)
            live.applyRDSRuntimeConfig(MPXGenerator.RDSRuntimeConfig.make(from: keyOn))
            let liveOn = renderCompositePath(live)
            if mode == .mpx {
                // Negative control: where RDS exists the same probe sees it,
                // so equality below is the gate and not a blind measurement.
                #expect(liveOn != reference, "probe cannot see a live RDS enable in MPX Output")
            } else {
                #expect(liveOn == reference,
                        "\(mode.title): a live RDS apply switched the coder on -- applyRDSRuntimeConfig is not gated")
            }
        }
    }

    // Measured 2026-10-15: fails in fm, hd and am. `MPXGenerator.init` hands
    // the UNGATED config to `BasicRDSCoder(config:)`, so an engine built with
    // en_rds on has an enabled coder in a mode without a composite (the live
    // path gates it in `applyRDSRuntimeConfig`). Harmless while only the
    // composite path calls the coder, but it breaks the "switched off in the
    // engine" rule. Fix: build the coder from a copy with
    // `enRDS = config.enRDS && ChainFeature.rds.applies(in: mode)`.
    @Test
    func rdsCoderIsBuiltDisabledOutsideMPX() {
        for mode in AppConfig.OperatingMode.allCases {
            let plain = gatingConfig(mode)
            var keyOn = plain
            keyOn.enRDS = true
            let reference = renderCompositePath(MPXGenerator(config: plain, sampleRate: 192_000.0))
            let builtOn = renderCompositePath(MPXGenerator(config: keyOn, sampleRate: 192_000.0))
            if mode == .mpx {
                #expect(builtOn != reference, "probe cannot see the RDS coder in MPX Output")
            } else {
                #expect(builtOn == reference,
                        "\(mode.title): an engine built with en_rds on runs the RDS coder -- the construction gate is missing")
            }
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
        // chain (nor allocate its Hilbert FIRs) -- at construction or on a
        // live apply. 0.1 s covers the 511-tap Hilbert FIR's latency.
        for mode in AppConfig.OperatingMode.allCases {
            let plain = gatingConfig(mode)
            var ssb = plain
            ssb.ssbStereoEnabled = true
            ssb.ssbStereoAmount = 1.0
            let reference = renderCompositePath(MPXGenerator(config: plain, sampleRate: 192_000.0))
            let builtOn = renderCompositePath(MPXGenerator(config: ssb, sampleRate: 192_000.0))
            let live = MPXGenerator(config: plain, sampleRate: 192_000.0)
            live.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: ssb))
            let liveOn = renderCompositePath(live)
            if mode == .mpx {
                #expect(builtOn != reference, "probe cannot see SSB stereo in MPX Output")
                #expect(liveOn != reference, "probe cannot see a live SSB enable in MPX Output")
            } else {
                #expect(builtOn == reference,
                        "\(mode.title): an engine built with SSB on runs it -- the construction gate is missing")
                #expect(liveOn == reference,
                        "\(mode.title): a live apply switched SSB on -- applyRuntimeConfig is not gated")
            }
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
        hfOn.hfLimiterTopThresholdDB = -12.0
        hfOn.hfLimiterMaxReductionDB = 24.0
        #expect(!ChainFeature.hfLimiter.applies(in: .hd))
        #expect(renderAudioOnly(cfg: hfBase, stereo: true) == renderAudioOnly(cfg: hfOn, stereo: true),
                "HD output moved when the HF limiter was enabled -- it is hidden but not inert")

        // The stereo-image protector (an option since 2026-10) exists in the
        // FM paths only: a digital carrier has neither deviation nor
        // multipath to protect, and AM is mono before it. The stereo probe
        // is anti-phase in the bass (side/mid well over 1.0), so in `fm` the
        // tightest cap WOULD act -- the test's control that the keys are
        // live where the feature exists, not inert everywhere.
        for mode in [AppConfig.OperatingMode.hd, .am] {
            var imageBase = AppConfig()
            imageBase.operatingMode = mode
            imageBase.sampleRate = 192_000.0
            imageBase.stereoImageProtectEnabled = false
            var imageOn = imageBase
            imageOn.stereoImageProtectEnabled = true
            imageOn.stereoImageMaxSideRatio = 1.0
            #expect(!ChainFeature.stereoImage.applies(in: mode))
            #expect(renderAudioOnly(cfg: imageBase, stereo: true) == renderAudioOnly(cfg: imageOn, stereo: true),
                    "\(mode.title) output moved when the stereo-image protector was enabled -- it is hidden but not inert")
        }
        var fmBase = AppConfig()
        fmBase.operatingMode = .fm
        fmBase.sampleRate = 192_000.0
        fmBase.stereoImageProtectEnabled = false
        var fmOn = fmBase
        fmOn.stereoImageProtectEnabled = true
        fmOn.stereoImageMaxSideRatio = 1.0
        #expect(ChainFeature.stereoImage.applies(in: .fm))
        #expect(renderAudioOnly(cfg: fmBase, stereo: true) != renderAudioOnly(cfg: fmOn, stereo: true),
                "FM output did not move when the stereo-image protector was enabled on an anti-phase probe")
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
