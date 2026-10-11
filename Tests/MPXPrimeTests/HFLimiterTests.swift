import Foundation
import MPXPrimeCore
import Testing

@testable import MPXPrime

// Pre-emphasis-aware HF limiter (program-controlled pre-emphasis, Orban
// US 4,103,243 topology): rides only the boost component `pre - flat`.
// The invariants pinned here are the ones docs/hf-limiter-review.md found
// broken or unguarded in 2026-10: the bass-immunity gate, the cap on the
// removal, the opposite-sign case, the de-emphasised floor, the absence of
// gain ripple, the stereo image and the split top-octave ceiling.
@Suite struct HFLimiterTests {

    private let sampleRate: Float = 48_000.0

    private func makeLimiter(enabled: Bool = true, thresholdDB: Float = -2.0,
                             topThresholdDB: Float? = nil,
                             maxReductionDB: Float = 12.0) -> HFLimiter {
        var limiter = HFLimiter()
        limiter.configure(
            enabled: enabled, sampleRate: sampleRate, thresholdDB: thresholdDB,
            topThresholdDB: topThresholdDB ?? (thresholdDB - 1.0),
            attackMS: 1.5, releaseMS: 20.0, maxReductionDB: maxReductionDB)
        return limiter
    }

    private func makePreemphasis() -> PreemphasisFilter {
        var pre = PreemphasisFilter()
        pre.configure(tauUS: 50, sampleRate: sampleRate)
        return pre
    }

    private func makeDeemphasis() -> DeemphasisFilter {
        var de = DeemphasisFilter()
        de.configure(tauUS: 50, sampleRate: sampleRate)
        return de
    }

    private func rms(_ xs: ArraySlice<Float>) -> Float {
        guard !xs.isEmpty else { return 0.0 }
        var s: Float = 0.0
        for x in xs { s += x * x }
        return sqrtf(s / Float(xs.count))
    }

    private func db(_ x: Float) -> Float { 20.0 * log10f(max(1e-12, x)) }

    @Test func disabledIsExactPassthrough() {
        var limiter = makeLimiter(enabled: false)
        for n in 0..<2_000 {
            let flat = 0.5 * sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let pre = flat * 1.9
            let out = limiter.process(flatL: flat, flatR: flat, emphasizedL: pre, emphasizedR: pre)
            #expect(out.0 == pre)
            #expect(out.1 == pre)
        }
        #expect(limiter.gainReductionDB == 0.0)
    }

    @Test func hfOvershootIsPulledToTheThreshold() {
        // 10 kHz "hat": flat 0.30, boost 0.60 -> pre-emphasised peak 0.90,
        // threshold -2 dB (0.794). Steady state must sit at the threshold
        // (+ a small smoothing margin), never below the flat level.
        var limiter = makeLimiter()
        var peak: Float = 0.0
        for n in 0..<9_600 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let flat = 0.30 * s
            let pre = 0.90 * s
            let out = limiter.process(flatL: flat, flatR: flat, emphasizedL: pre, emphasizedR: pre)
            if n >= 4_800 { peak = max(peak, fabsf(out.0)) }
        }
        #expect(peak <= 0.794 * 1.03, "steady-state peak \(peak) should sit at the threshold")
        #expect(peak >= 0.30, "the stage must never cut HF below the flat level")
        #expect(limiter.gainReductionDB > 0.5)
    }

    @Test func bassDrivenPeakWithModerateHatIsIgnored() {
        // Finding 1 of the review: a 60 Hz kick at 0.95 with a 10 kHz hat
        // 20 dB down, through the real 50 us pre-emphasis. The emphasised
        // hat is ~0.31 and its boost ~0.28; the peak (~1.26) is the kick's.
        // Removing every bit of boost could not bring it to the threshold,
        // so the stage must not touch it -- the old gate (boost > 20 % of
        // the PEAK) floored at -12 dB on every kick crest instead.
        // The first kick has no history: on its rising flank the hat alone
        // crosses the threshold and a feed-forward detector cannot know the
        // crest is coming (a brief -1 dB). From the second crest on the
        // gate's 15 ms hold spans the cycle; the check starts at 200 ms,
        // once that first dip has released (20 ms, ten time constants).
        var limiter = makeLimiter()
        var pre = makePreemphasis()
        var minGain: Float = 1.0
        var firstCycleMinGain: Float = 1.0
        for n in 0..<19_200 {
            let t = Float(n) / sampleRate
            let kick = 0.95 * sinf(2.0 * Float.pi * 60.0 * t)
            let hat = 0.095 * sinf(2.0 * Float.pi * 10_000.0 * t)
            let flat = kick + hat
            let emph = pre.process(flat)
            _ = limiter.process(flatL: flat, flatR: flat, emphasizedL: emph, emphasizedR: emph)
            if n >= 9_600 { minGain = min(minGain, limiter.gain) } else { firstCycleMinGain = min(firstCycleMinGain, limiter.gain) }
        }
        #expect(firstCycleMinGain > 0.8, "even the history-less first kick should only dip briefly (gain \(firstCycleMinGain))")
        #expect(minGain == 1.0, "a bass-driven peak must leave the HF boost alone (gain fell to \(minGain))")
        #expect(!limiter.gateOpen)
    }

    @Test func reductionNeverExceedsTheExcess() {
        // Steady 10 kHz tones at several overshoots: the output peak lands ON
        // the threshold when the boost can cover the excess, and never below
        // it -- the stage removes exactly the excess, not the whole boost.
        // (0.78, 0.99): the boost covers the excess but not within Max
        // Reduction, so the ride floors and the peak stays above the
        // threshold for the broadband limiter. (0.85, 0.99): the boost cannot
        // cover the excess at all -- the program gate stays shut and the
        // stage does nothing rather than spend its range for nothing.
        let threshold: Float = 0.794
        let cases: [(flat: Float, pre: Float)] = [
            (0.30, 0.82), (0.30, 0.90), (0.20, 0.99), (0.10, 0.99), (0.78, 0.99), (0.85, 0.99)
        ]
        for c in cases {
            var limiter = makeLimiter()
            var peak: Float = 0.0
            for n in 0..<9_600 {
                let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
                let out = limiter.process(flatL: c.flat * s, flatR: c.flat * s,
                                          emphasizedL: c.pre * s, emphasizedR: c.pre * s)
                if n >= 4_800 { peak = max(peak, fabsf(out.0)) }
            }
            let boost = c.pre - c.flat
            let excess = c.pre - threshold
            #expect(peak >= threshold * 0.995,
                    "flat \(c.flat) pre \(c.pre): peak \(peak) fell below the threshold -- more than the excess was removed")
            if boost < excess {
                #expect(limiter.gain == 1.0, "flat \(c.flat) pre \(c.pre): a ride that cannot finish must not start")
                #expect(abs(peak - c.pre) < 1e-4)
            } else if boost * (1.0 - powf(10.0, -12.0 / 20.0)) >= excess {
                #expect(peak <= threshold * 1.03,
                        "flat \(c.flat) pre \(c.pre): peak \(peak) did not land on the threshold")
            } else {
                #expect(peak > threshold * 1.03, "flat \(c.flat) pre \(c.pre): the floor should leave an excess")
                #expect(abs(limiter.gain - powf(10.0, -12.0 / 20.0)) < 0.01)
            }
        }
    }

    @Test func oppositeSignBoostNeverRaisesThePeak() {
        // Pre-emphasis can leave the boost opposite-signed to the peak (a
        // phase-shifted component). Reducing such a boost would RAISE the
        // peak; the stage must leave it to the broadband limiter instead.
        // The boost magnitude (0.4) covers the excess (0.106), so the
        // program gate is open and it is the sign alone that holds it off.
        var limiter = makeLimiter()
        var inputPeak: Float = 0.0
        var outputPeak: Float = 0.0
        var deviation: Float = 0.0
        for n in 0..<9_600 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let flat = 1.3 * s
            let pre = 0.9 * s  // boost = -0.4 s: opposite sign at every peak
            let out = limiter.process(flatL: flat, flatR: flat, emphasizedL: pre, emphasizedR: pre)
            inputPeak = max(inputPeak, fabsf(pre))
            outputPeak = max(outputPeak, fabsf(out.0))
            deviation = max(deviation, fabsf(out.0 - pre))
        }
        #expect(limiter.gateOpen, "the gate should be open: it is the sign that protects the peak")
        #expect(limiter.gain == 1.0)
        #expect(deviation == 0.0)
        #expect(outputPeak <= inputPeak)
    }

    @Test func neverBelowFlatAfterDeemphasis() {
        // Through the real 50 us pre-emphasis and the receiver's exact
        // inverse: with the ride floored (threshold well below the hat, 24 dB
        // of reduction allowed) the decoded 10 kHz level sits between the
        // flat program de-emphasised (g = 0, the floor the topology promises)
        // and the program itself (g = 1). It can never go below the floor.
        var limiter = makeLimiter(thresholdDB: -6.0, maxReductionDB: 24.0)
        var pre = makePreemphasis()
        var deOut = makeDeemphasis()
        var deFlat = makeDeemphasis()
        var decoded: [Float] = []
        var floorRef: [Float] = []
        var program: [Float] = []
        var emphPeak: Float = 0.0
        var boostPeak: Float = 0.0
        for n in 0..<19_200 {
            let flat = 0.5 * sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let emph = pre.process(flat)
            emphPeak = max(emphPeak, fabsf(emph))
            boostPeak = max(boostPeak, fabsf(emph - flat))
            let out = limiter.process(flatL: flat, flatR: flat, emphasizedL: emph, emphasizedR: emph)
            decoded.append(deOut.process(out.0))
            floorRef.append(deFlat.process(flat))
            program.append(flat)
        }
        let tail = 9_600..<19_200
        let decodedDB = db(rms(decoded[tail]))
        let floorDB = db(rms(floorRef[tail]))
        let programDB = db(rms(program[tail]))
        #expect(limiter.gateOpen, "gate shut: emphasised peak \(emphPeak), boost peak \(boostPeak)")
        #expect(limiter.gainReductionDB > 6.0, "the ride should be deep for this test to mean anything (peak \(emphPeak), boost \(boostPeak))")
        #expect(decodedDB >= floorDB - 0.05, "decoded \(decodedDB) dB fell below the flat-response floor \(floorDB) dB")
        #expect(decodedDB <= programDB + 0.05, "decoded \(decodedDB) dB above the program \(programDB) dB")
        #expect(floorDB < programDB - 6.0, "the floor should be the de-emphasis curve, ~-10 dB at 10 kHz")
    }

    @Test func steadyToneHasNoGainRipple() {
        // A sustained tone must not modulate the gain: the 5 ms hold refreshes
        // on every crest, so the gain sits still. Checked below the top-octave
        // corner (10 kHz) and above it (14 kHz, where the split detector's
        // envelope is in play).
        for toneHz: Float in [10_000.0, 14_000.0] {
            var limiter = makeLimiter()
            var lo: Float = 1.0
            var hi: Float = 0.0
            for n in 0..<19_200 {
                let s = sinf(2.0 * Float.pi * toneHz * Float(n) / sampleRate)
                _ = limiter.process(flatL: 0.30 * s, flatR: 0.30 * s, emphasizedL: 0.95 * s, emphasizedR: 0.95 * s)
                if n >= 14_400 {
                    lo = min(lo, limiter.gain)
                    hi = max(hi, limiter.gain)
                }
            }
            #expect(hi < 0.98, "\(toneHz) Hz: the tone should keep the stage engaged")
            let rippleDB = db(hi) - db(lo)
            #expect(rippleDB < 0.01, "\(toneHz) Hz: steady-state gain ripple \(rippleDB) dB")
        }
    }

    @Test func cymbalWashRippleDepth() {
        // Band-limited (6-14 kHz) noise at a steady level, through the real
        // pre-emphasis: the hold/release cycle must not carve a 20-300 Hz
        // ripple into the gain trajectory (the review's finding 3 -- the
        // transient gate's +/-250 Hz mask hid it). Depth = p-p of an
        // equivalent sinusoid, 2 sqrt 2 x the RMS of the band-passed
        // trajectory in dB.
        var limiter = makeLimiter(thresholdDB: -0.4, topThresholdDB: -1.4)
        var pre = makePreemphasis()
        var noise = DeterministicNoise(seed: 0x4846_0000_0000_0011)
        var band = HFNoiseBand()
        var hp = LR4Section()
        var lp = LR4Section()
        hp.configureHighpass(cutoffHz: 20.0, sampleRate: sampleRate)
        lp.configureLowpass(cutoffHz: 300.0, sampleRate: sampleRate)
        let total = 48_000
        var sumSq: Double = 0.0
        var counted = 0
        var meanGR: Double = 0.0
        for n in 0..<total {
            let flat = 0.45 * band.process(noise.next(), sampleRate: sampleRate)
            let emph = pre.process(flat)
            _ = limiter.process(flatL: flat, flatR: 0.9 * flat, emphasizedL: emph, emphasizedR: 0.9 * emph)
            let gainDB = db(limiter.gain)
            let banded = lp.process(hp.process(gainDB))
            if n >= 9_600 {
                sumSq += Double(banded * banded)
                meanGR += Double(gainDB)
                counted += 1
            }
        }
        let depth = Float(2.0 * 2.0.squareRoot() * (sumSq / Double(counted)).squareRoot())
        let averageGR = -Float(meanGR / Double(counted))
        #expect(averageGR > 0.5, "the wash should keep the stage working (average GR \(averageGR) dB)")
        #expect(depth < 0.3, "20-300 Hz gain ripple depth \(depth) dB on a cymbal wash (GR \(averageGR) dB)")
    }

    @Test func stereoBalanceAfterDeemphasis() {
        // One shared gain and the receiver's de-emphasis: a hat panned
        // left-of-centre keeps its L/R balance on air, within 0.05 dB.
        var limiter = makeLimiter()
        var preL = makePreemphasis()
        var preR = makePreemphasis()
        var deL = makeDeemphasis()
        var deR = makeDeemphasis()
        var outL: [Float] = []
        var outR: [Float] = []
        for n in 0..<19_200 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let flatL = 0.40 * s
            let flatR = 0.20 * s
            let out = limiter.process(flatL: flatL, flatR: flatR,
                                      emphasizedL: preL.process(flatL), emphasizedR: preR.process(flatR))
            outL.append(deL.process(out.0))
            outR.append(deR.process(out.1))
        }
        #expect(limiter.gainReductionDB > 1.0, "the hat should engage the stage")
        let tail = 9_600..<19_200
        let balanceDB = db(rms(outL[tail])) - db(rms(outR[tail]))
        #expect(abs(balanceDB - 6.0206) < 0.05, "decoded L/R balance \(balanceDB) dB, input 6.02 dB")
    }

    @Test func topBandUsesItsOwnThreshold() {
        // Split ceiling: a 14 kHz tone (above the 13 kHz corner) is held at
        // the top threshold, a 6 kHz tone at the main one. Both through the
        // real 50 us pre-emphasis so the boost is the genuine article.
        let mainThreshold: Float = 0.794  // -2 dB
        let topThreshold: Float = 0.708   // -3 dB
        let cases: [(hz: Float, amp: Float, expected: Float, label: String)] = [
            (14_000.0, 0.25, topThreshold, "top"),
            (6_000.0, 0.50, mainThreshold, "main")
        ]
        for c in cases {
            var limiter = makeLimiter(thresholdDB: -2.0, topThresholdDB: -3.0)
            var pre = makePreemphasis()
            var inputPeak: Float = 0.0
            var peak: Float = 0.0
            for n in 0..<19_200 {
                let flat = c.amp * sinf(2.0 * Float.pi * c.hz * Float(n) / sampleRate)
                let emph = pre.process(flat)
                let out = limiter.process(flatL: flat, flatR: flat, emphasizedL: emph, emphasizedR: emph)
                if n >= 9_600 {
                    inputPeak = max(inputPeak, fabsf(emph))
                    peak = max(peak, fabsf(out.0))
                }
            }
            #expect(inputPeak > mainThreshold * 1.1, "\(c.label): the tone should overshoot both thresholds")
            #expect(abs(peak - c.expected) <= c.expected * 0.03,
                    "\(c.label) band (\(c.hz) Hz): peak \(peak), expected \(c.expected) (top share \(limiter.topShare))")
            #expect(abs(limiter.effectiveThresholdLin - c.expected) < 1e-3,
                    "\(c.label) band: effective threshold \(limiter.effectiveThresholdLin)")
        }
    }

    @Test func releaseRestoresFullPreemphasis() {
        var limiter = makeLimiter()
        for n in 0..<4_800 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            _ = limiter.process(flatL: 0.30 * s, flatR: 0.30 * s, emphasizedL: 0.90 * s, emphasizedR: 0.90 * s)
        }
        #expect(limiter.gain < 0.95)
        // Quiet program: 200 ms is 10 release time constants.
        for n in 0..<9_600 {
            let s = 0.05 * sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            _ = limiter.process(flatL: s, flatR: s, emphasizedL: 1.9 * s, emphasizedR: 1.9 * s)
        }
        #expect(limiter.gain > 0.999)
    }

    @Test func maxReductionCapsTheGainRide() {
        // Boost far above a -6 dB threshold with a 3 dB cap: removing the
        // excess would need ~-6.5 dB of boost gain, so the ride floors at
        // 10^(-3/20) and the rest is left for the broadband limiter.
        var limiter = makeLimiter(thresholdDB: -6.0, maxReductionDB: 3.0)
        for n in 0..<9_600 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            _ = limiter.process(flatL: 0.05 * s, flatR: 0.05 * s, emphasizedL: 0.99 * s, emphasizedR: 0.99 * s)
        }
        let floor = powf(10.0, -3.0 / 20.0)
        #expect(abs(limiter.gain - floor) < 0.01)
    }

    @Test func stereoLinkKeepsChannelRatio() {
        // One shared gain: a hard-left hat reduces both channels' boost by
        // the same factor, so the L/R ratio of the boost is preserved.
        var limiter = makeLimiter()
        var ratioError: Float = 0.0
        for n in 0..<9_600 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let out = limiter.process(
                flatL: 0.30 * s, flatR: 0.06 * s, emphasizedL: 0.90 * s, emphasizedR: 0.18 * s)
            if n >= 4_800, fabsf(s) > 0.5 {
                // out = flat + g*boost; boostR/boostL = 0.2 exactly.
                let gL = (out.0 - (0.30 * s)) / (0.60 * s)
                let gR = (out.1 - (0.06 * s)) / (0.12 * s)
                ratioError = max(ratioError, fabsf(gL - gR))
            }
        }
        #expect(ratioError < 1e-4)
    }

    @Test func runtimeConfigCarriesEveryField() {
        var config = AppConfig()
        config.hfLimiterEnabled = true
        config.hfLimiterThresholdDB = -4.5
        config.hfLimiterTopThresholdDB = -5.5
        config.hfLimiterAttackMS = 2.5
        config.hfLimiterReleaseMS = 35.0
        config.hfLimiterMaxReductionDB = 9.0
        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        #expect(runtime.hfLimiterEnabled)
        #expect(abs(runtime.hfLimiterThresholdDB - (-4.5)) < 1e-6)
        #expect(abs(runtime.hfLimiterTopThresholdDB - (-5.5)) < 1e-6)
        #expect(abs(runtime.hfLimiterAttackMS - 2.5) < 1e-6)
        #expect(abs(runtime.hfLimiterReleaseMS - 35.0) < 1e-6)
        #expect(abs(runtime.hfLimiterMaxReductionDB - 9.0) < 1e-6)
    }

    @Test func iniRoundTripKeepsHFLimiterKeys() throws {
        var config = AppConfig()
        config.hfLimiterEnabled = true
        config.hfLimiterThresholdDB = -3.0
        config.hfLimiterTopThresholdDB = -4.5
        config.hfLimiterAttackMS = 1.0
        config.hfLimiterReleaseMS = 40.0
        config.hfLimiterMaxReductionDB = 8.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-limiter-\(UUID().uuidString).ini")
        try config.save(toINI: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try AppConfig.load(fromINI: url.path)
        #expect(loaded.hfLimiterEnabled)
        #expect(abs(loaded.hfLimiterThresholdDB - (-3.0)) < 1e-6)
        #expect(abs(loaded.hfLimiterTopThresholdDB - (-4.5)) < 1e-6)
        #expect(abs(loaded.hfLimiterAttackMS - 1.0) < 1e-6)
        #expect(abs(loaded.hfLimiterReleaseMS - 40.0) < 1e-6)
        #expect(abs(loaded.hfLimiterMaxReductionDB - 8.0) < 1e-6)
    }

    @Test func defaultsAndProfilesSitHalfADecibelAboveThePreEncodeThreshold() {
        // Finding 2 of the review: the HF comparators belong 0.5 dB ABOVE the
        // broadband limiter's threshold (US 4,103,243), the top octave 1 dB
        // under that. Every profile fans the pair out from its own
        // `preEncodeThreshold`; the defaults match the default profile.
        let defaults = AppConfig()
        #expect(defaults.formatProfileID == "music_clean")
        #expect(abs(defaults.hfLimiterThresholdDB - (-0.4)) < 1e-9)
        #expect(abs(defaults.hfLimiterTopThresholdDB - (-1.4)) < 1e-9)
        for profile in PresetCatalog.formatProfiles {
            let expected = ((20.0 * log10(profile.preEncodeThreshold) + 0.5) * 10.0).rounded() / 10.0
            #expect(abs(profile.hfLimiterThresholdDB - expected) < 1e-9,
                    "\(profile.id): HF threshold \(profile.hfLimiterThresholdDB), pre-encode \(profile.preEncodeThreshold)")
            #expect(abs(profile.hfLimiterTopThresholdDB - (profile.hfLimiterThresholdDB - 1.0)) < 1e-9,
                    "\(profile.id): top threshold should be 1 dB under the main one")
        }
    }

    @Test func legacyFormatProfileIDsMigrateToThe045Profiles() {
        #expect(AppConfig.migratedFormatProfileID("chr_top40") == "music_loud")
        #expect(AppConfig.migratedFormatProfileID("edm_dance") == "music_dense")
        #expect(AppConfig.migratedFormatProfileID("community_radio") == "music_clean")
        #expect(AppConfig.migratedFormatProfileID("news_talk") == "speech")
        #expect(AppConfig.migratedFormatProfileID("jazz_classical") == "classical_wide")
        #expect(AppConfig.migratedFormatProfileID("music_clean") == "music_clean")
        #expect(AppConfig.migratedFormatProfileID("custom") == "custom")
    }

    @Test func safetyClipWarningFiresOnlyWithoutAPeakController() {
        var config = AppConfig()
        #expect(!config.safetyClipsAreThePeakController)
        config.preEncodeAudioLimiterEnabled = false
        #expect(!config.safetyClipsAreThePeakController)
        config.compositeClipperEnabled = false
        #expect(config.safetyClipsAreThePeakController)
        config.processingBypass = true
        #expect(!config.safetyClipsAreThePeakController)
    }
}
