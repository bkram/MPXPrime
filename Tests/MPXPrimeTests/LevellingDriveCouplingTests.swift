import Foundation
import Testing

@testable import MPXPrime

// 2026-10 audio-chain overhaul, gain-structure audit B3 / B4 / C3 / C6: the
// levelling target, Final Drive and the pre-encode limiter were decoupled.
// Advanced Dynamics held the weighted level at -18 dBFS, the pre-encode
// limiter (threshold 0.90) idled on real programme, and nothing after it
// added gain in MPX mode, so low-crest programme never reached the audio
// budget (wide_bass 55 kHz against a 64 kHz budget) and dense programme left
// the chain 3.7 dB quieter than it came in. The fix is measured, not
// guessed (audits-2026-10-20/report-levelling.md): the leveller target per
// profile, the AD / AGC coupling rule, and the pre-encode stereo-link blend
// (`pre_encode_stereo_link`, roadmap item 1). This file pins the four goals
// of that task and the link's identities.
@Suite("Levelling / drive coupling (2026-10 overhaul)")
struct LevellingDriveCouplingTests {

    // MARK: - Pre-encode stereo-link blend (unit level)

    private let audioRate: Float = 48_000.0

    private func makeLimiter(link: Float?) -> StereoLinkedOversampledPeakLimiter {
        var lim = StereoLinkedOversampledPeakLimiter()
        if let link {
            lim.configure(sampleRate: audioRate, threshold: 0.90, releaseMS: 50.0,
                          lookaheadMS: 1.0, lookaheadHFOnly: true, stereoLink: link)
        } else {
            lim.configure(sampleRate: audioRate, threshold: 0.90, releaseMS: 50.0,
                          lookaheadMS: 1.0, lookaheadHFOnly: true)
        }
        return lim
    }

    /// Loud left (over the threshold), quiet right (well under it).
    private func stimulus(_ i: Int, loudLeft: Bool = true) -> (Float, Float) {
        let t = Float(i) / audioRate
        let left: Float = loudLeft ? 0.98 * sinf(2.0 * .pi * 1_000.0 * t) : 0.0
        let right: Float = 0.30 * sinf(2.0 * .pi * 1_300.0 * t)
        return (left, right)
    }

    private func render(_ lim: inout StereoLinkedOversampledPeakLimiter, frames: Int,
                        loudLeft: Bool = true) -> (left: [Float], right: [Float], gr: Float) {
        var outL = [Float](repeating: 0, count: frames)
        var outR = [Float](repeating: 0, count: frames)
        var gr: Float = 0
        for i in 0..<frames {
            let s = stimulus(i, loudLeft: loudLeft)
            let o = lim.process(left: s.0, right: s.1)
            outL[i] = o.0
            outR[i] = o.1
            gr = max(gr, lim.gainReductionDB)
        }
        return (outL, outR, gr)
    }

    private func rmsDB(_ x: ArraySlice<Float>) -> Float {
        var sum = 0.0
        for v in x { sum += Double(v * v) }
        return 20.0 * log10f(Float(sqrt(sum / Double(max(1, x.count)))))
    }

    @Test func linkOneIsTheClassicSharedEnvelope() {
        // configure() without the parameter and with stereoLink 1 are the same
        // limiter, bit for bit, and both channels take the same gain: the
        // quiet right channel loses exactly what the loud left one loses.
        let frames = Int(audioRate)
        var classic = makeLimiter(link: nil)
        var linked = makeLimiter(link: 1.0)
        let a = render(&classic, frames: frames)
        let b = render(&linked, frames: frames)
        #expect(a.left == b.left && a.right == b.right, "stereoLink 1 must be the pre-key limiter bit for bit")
        let tail = (frames / 2)..<frames
        var inL = [Float](repeating: 0, count: frames)
        var inR = [Float](repeating: 0, count: frames)
        for i in 0..<frames { let s = stimulus(i); inL[i] = s.0; inR[i] = s.1 }
        let lossL = rmsDB(a.left[tail]) - rmsDB(inL[tail])
        let lossR = rmsDB(a.right[tail]) - rmsDB(inR[tail])
        #expect(lossL < -0.5, "the loud channel must be limited; loss \(lossL) dB")
        #expect(abs(lossL - lossR) < 0.1, "linked: both channels lose the same (\(lossL) vs \(lossR) dB)")
        #expect(a.gr > 0.5)
    }

    @Test func linkZeroLeavesTheQuietChannelUntouched() {
        // At link 0 the right channel's gain is its own envelope, which never
        // leaves unity because the right channel never crosses the threshold:
        // its output is identical to the right channel rendered alone (left
        // silent), sample for sample. The left channel is still held.
        let frames = Int(audioRate)
        var unlinked = makeLimiter(link: 0.0)
        var alone = makeLimiter(link: 0.0)
        let a = render(&unlinked, frames: frames)
        let b = render(&alone, frames: frames, loudLeft: false)
        #expect(a.right == b.right, "link 0: the quiet channel must not see the loud channel's gain")
        let ceiling = oversampledLimiterCeiling(threshold: 0.90)
        let peakL = a.left.map { abs($0) }.max() ?? 0
        #expect(peakL <= ceiling + 1e-4, "left peak \(peakL) above the ceiling \(ceiling)")
        #expect(a.gr > 0.5, "the readout must still show the loud channel's reduction")
    }

    @Test func blendedGainLiesBetweenSharedAndOwn() {
        // At link 0.5 the quiet channel's level sits between the linked
        // (fully attenuated) and unlinked (untouched) renders, and every
        // output stays under the ceiling at every link setting.
        let frames = Int(audioRate)
        var l0 = makeLimiter(link: 0.0)
        var l5 = makeLimiter(link: 0.5)
        var l1 = makeLimiter(link: 1.0)
        let a = render(&l0, frames: frames)
        let b = render(&l5, frames: frames)
        let c = render(&l1, frames: frames)
        let tail = (frames / 2)..<frames
        let r0 = rmsDB(a.right[tail]), r5 = rmsDB(b.right[tail]), r1 = rmsDB(c.right[tail])
        #expect(r1 < r5 - 0.1 && r5 < r0 - 0.1, "right RMS link 0 / 0.5 / 1 = \(r0) / \(r5) / \(r1) dB must be ordered")
        let ceiling = oversampledLimiterCeiling(threshold: 0.90)
        for out in [a, b, c] {
            let peak = max(out.left.map { abs($0) }.max() ?? 0, out.right.map { abs($0) }.max() ?? 0)
            #expect(peak <= ceiling + 1e-4, "peak \(peak) above the ceiling \(ceiling)")
        }
    }

    // MARK: - Coupling rule and per-profile operating points (chain level)

    @Test func levellerTargetFollowsTheAGCTarget() {
        // Was the AGC target less 2 dB everywhere, which measured 4.0 dB
        // quieter than the classic chain on bass_dense (parity bound 3.0).
        // Now the AGC target itself, except where PrimeBass runs: there the
        // 2 dB keep its IMD under the --verify-primebass -70 dB gate (-56.2 dB
        // at the AGC target on Music - Loud). The default config is Music -
        // Clean, so it carries the AGC target.
        #expect(PresetCatalog.primeBassLevellerOffsetDB == 2.0)
        for profile in PresetCatalog.formatProfiles where profile.id != "custom" {
            var cfg = AppConfig()
            #expect(PresetCatalog.applyFormatProfile(id: profile.id, to: &cfg) != nil)
            let offset = profile.primeBassEnabled ? 2.0 : 0.0
            #expect(cfg.advancedDynamicsTargetDB == cfg.widebandAGCTargetDB - offset,
                    "\(profile.id): leveller target \(cfg.advancedDynamicsTargetDB) vs AGC target \(cfg.widebandAGCTargetDB)")
        }
        #expect(AppConfig().advancedDynamicsTargetDB == AppConfig().widebandAGCTargetDB)
        #expect(AppConfig().preEncodeStereoLink == 1.0, "the link ships fully linked (it buys nothing at the shipped levels)")
    }

    private struct ChainReading {
        let budgetFraction: Float
        let rmsDeltaDB: Float
    }

    /// One scenario through the profile's shipped chain (RDS on, as on air:
    /// the RDS reservation is part of the budget, and with RDS off the budget
    /// is 3 % larger): the audio-composite peak as a share of the audio
    /// budget the generator holds it to, and output-vs-input RMS.
    private func reading(profile: String, scenario name: String, seconds: Double = 4.0) -> ChainReading? {
        guard let scenario = verificationScenarios().first(where: { $0.name == name }),
              let again = verificationScenarios().first(where: { $0.name == name }) else { return nil }
        var cfg = AppConfig()
        _ = PresetCatalog.applyFormatProfile(id: profile, to: &cfg)
        let sampleRate = cfg.sampleRate
        let generator = MPXGenerator(config: cfg, sampleRate: sampleRate)
        var audioPeak: Float = 0.0
        var reserved: Float = 0.0
        let frames = Int(seconds * sampleRate)
        for frame in 0..<frames {
            let input = scenario.sample(frame, sampleRate)
            _ = generator.renderSingleSample(leftIn: input.0, rightIn: input.1)
            let cal = generator.compositeCalibrationStatus
            audioPeak = max(audioPeak, cal.audioPeak)
            reserved = max(reserved, powf(10.0, -cal.budgetMarginDB / 20.0) - cal.audioPeak)
        }
        let budget = Float(cfg.limitThreshold) - MPXGenerator.finalCompositeBudgetSafetyMargin - reserved
        let rms = name == "bright_dense"
            ? verifyScenario(config: cfg, durationSeconds: seconds, scenario: again).rmsDeltaDB
            : 0.0
        return ChainReading(budgetFraction: audioPeak / max(1e-6, budget), rmsDeltaDB: rms)
    }

    @Test func programmeReachesTheBudgetWhereTheHatGateAllowsIt() {
        // Goal (1) of the levelling task: program_mix reaches >= 0.97 of the
        // audio budget on its peaks. Measured 2026-10 (4 s, Linux release):
        // Loud / Dense 0.999, Speech 0.993, Classical 0.989 -- met. Music -
        // Clean reads 0.925: its drive is held at 3.5 dB by the 20 dB hi-hat
        // gate (20.9 dB; 4.0 dB of drive reads 0.978 and 20.1 dB, inside the
        // gate by 0.1 dB), so the floor here is its measured figure less a
        // render-length allowance, not the goal. 4 s renders, as the sweep:
        // the leveller is still rising at 3 s (Clean 0.898, Speech 0.967). Before the task: Clean 0.909,
        // Speech 0.991, Classical 0.787.
        let floors: [String: Float] = [
            "music_clean": 0.90, "music_loud": 0.97, "music_dense": 0.97,
            "speech": 0.97, "classical_wide": 0.96
        ]
        for (profile, floor) in floors {
            guard let r = reading(profile: profile, scenario: "program_mix") else {
                Issue.record("program_mix missing"); return
            }
            print("[levelling] \(profile) program_mix: \(r.budgetFraction) of the budget")
            #expect(r.budgetFraction >= floor, "\(profile): program_mix peaks at \(r.budgetFraction) of the budget, floor \(floor)")
            #expect(r.budgetFraction <= 1.0 + 1e-3, "\(profile): over the budget (\(r.budgetFraction))")
        }
    }

    @Test func brightProgrammeIsLessQuietThanBefore() {
        // Goal (3) measured, not met: bright_dense leaves the chain -3.0 dB
        // under its input RMS through Music - Clean (was -3.78); Loud / Dense
        // keep their leveller target (PrimeBass) and read -2.1 / -2.2 dB as
        // before. The budget, not the levelling, is the
        // bound: the composite peak of this programme is its pre-emphasised
        // 6-10 kHz content, so even +8 dB on the leveller only reaches -1.5 dB
        // (sweep, at hat SINAD far under the gate). The test pins the gain the
        // task did make, so a regression back to the decoupled chain fails.
        let ceilings: [String: Float] = ["music_clean": -3.4]
        for (profile, limit) in ceilings {
            guard let r = reading(profile: profile, scenario: "bright_dense") else {
                Issue.record("bright_dense missing"); return
            }
            print("[levelling] \(profile) bright_dense dRMS \(r.rmsDeltaDB) dB")
            #expect(r.rmsDeltaDB > limit, "\(profile): bright_dense dRMS \(r.rmsDeltaDB) dB, must stay above \(limit)")
        }
    }

    @Test func levellerMatchesTheClassicChainLoudness() {
        // Goal (4), the --verify-advanced-dynamics parity rule on its own
        // scenario (bass_dense, classic AGC + multiband vs the leveller, the
        // default chain): within 3.0 dB. Measured -2.1 dB at the new rule,
        // -4.0 dB at the old one (AGC target less 2 dB).
        guard let classicScenario = advancedDynamicsComparisonScenarios().first(where: { $0.name == "bass_dense" }),
              let levelledScenario = advancedDynamicsComparisonScenarios().first(where: { $0.name == "bass_dense" }) else {
            Issue.record("bass_dense missing"); return
        }
        var classic = AppConfig()
        classic.enRDS = false
        classic.advancedDynamicsEnabled = false
        classic.widebandAGCEnabled = true
        classic.multibandEnabled = true
        classic.multibandMode = 5
        var levelled = classic
        levelled.advancedDynamicsEnabled = true
        let off = verifyScenario(config: classic, durationSeconds: 4.0, scenario: classicScenario)
        let on = verifyScenario(config: levelled, durationSeconds: 4.0, scenario: levelledScenario)
        let delta = on.rmsDeltaDB - off.rmsDeltaDB
        print(String(format: "[levelling] bass_dense parity: leveller %.2f dB, classic %.2f dB, delta %+.2f dB", on.rmsDeltaDB, off.rmsDeltaDB, delta))
        #expect(abs(delta) <= 3.0, "leveller vs classic chain \(delta) dB, parity bound 3.0")
    }
}
