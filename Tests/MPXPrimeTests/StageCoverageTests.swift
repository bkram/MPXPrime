import Testing
import Foundation
@testable import MPXPrime

// Stages that had no DSP assertion at all (test-suite review 2026-10,
// coverage map): parametric EQ with a non-zero gain, input HPF, HF trim,
// stereo-image protection, the per-band downward expander, the encoder HF
// guard and mono bass. Each is measured THROUGH THE GENERATOR, so a wiring
// mistake counts as much as a coefficient mistake.
//
// Tap: the FM processed-audio output (`operating_mode = fm`, the audio-only
// render). It runs the same `processAudioDomain` as MPX Output, at the
// engine rate (the dual-rate boundary is off in the audio-only modes), with
// stereo L/R out instead of a composite. Every level-dependent stage is off
// unless the test is about it, tones are small, and each response is the
// RATIO of two renders that differ only in the stage under test, so the
// fixed path (program lowpass, output make-up) cancels.
//
// Oracles are independent of the code under test: the RBJ Audio-EQ-Cookbook
// formulas evaluated in Double in this file (the chain's biquads are RBJ,
// shelves at slope 1, HPF at Q 1/sqrt 2), the expander's textbook 1:r law,
// and the levelling review's pass conditions for mono bass.
@Suite("Stage coverage through the generator")
struct StageCoverageTests {

    private static let rate = 48_000.0

    /// Everything that levels, clips or limits is OFF; pre-emphasis 0 so the
    /// encoder HF guard and the HF limiter disable themselves; HPF at its
    /// 10 Hz floor; no final loudness clipper.
    static func quietChain() -> AppConfig {
        var c = AppConfig()
        c.sampleRate = rate
        c.operatingMode = .fm
        c.sourceMode = "input"
        c.enRDS = false
        c.processingBypass = false
        c.monoMode = false
        c.preemphasisUS = 0
        c.widebandAGCEnabled = false
        c.advancedDynamicsEnabled = false
        c.multibandEnabled = false
        c.multibandLimiterEnabled = false
        c.downwardExpanderEnabled = false
        c.primeBassEnabled = false
        c.monoBassEnabled = false
        c.phaseRotationEnabled = false
        c.parametricEQEnabled = false
        c.bassClipperEnabled = false
        c.dcClipperEnabled = false
        c.hfLimiterEnabled = false
        c.preEncodeAudioLimiterEnabled = false
        c.processedAudioCoderHasClipper = true
        c.hpfHz = 10.0
        c.hfTrimDB = 0.0
        return c
    }

    /// One tone per channel (amplitude, frequency, phase sign on R).
    struct Drive {
        var left: [(amp: Double, hz: Double)]
        var right: [(amp: Double, hz: Double)]
    }

    /// Render `seconds` through the processed-audio path and return (L, R).
    static func render(_ cfg: AppConfig, _ drive: Drive, seconds: Double = 0.6) -> ([Float], [Float]) {
        let r = renderWithGR(cfg, drive, seconds: seconds)
        return (r.left, r.right)
    }

    /// Same, plus the largest pre-encode (output) limiter gain reduction seen
    /// in the second half of the render: in the audio-only modes that
    /// limiter is the stereo-linked output peak control, so a measurement
    /// of another stage is only valid while it is idle.
    static func renderWithGR(_ cfg: AppConfig, _ drive: Drive, seconds: Double = 0.6)
        -> (left: [Float], right: [Float], maxGRDB: Float, meanGRDB: Float) {
        let gen = MPXGenerator(config: cfg, sampleRate: rate)
        gen.setAudioOutputOnly(true)
        let frames = Int(rate * seconds)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / rate
            var l = 0.0, r = 0.0
            for tone in drive.left { l += tone.amp * sin(2.0 * .pi * tone.hz * t) }
            for tone in drive.right { r += tone.amp * sin(2.0 * .pi * tone.hz * t) }
            left[i] = Float(l)
            right[i] = Float(r)
        }
        var maxGR: Float = 0.0
        var sumGR: Float = 0.0
        var countGR = 0
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                var offset = 0
                while offset < frames {
                    let n = min(512, frames - offset)
                    gen.renderAudioOnlyFromInputInPlace(
                        frameCount: n,
                        // swiftlint:disable force_unwrapping
                        left: lb.baseAddress!.advanced(by: offset),
                        right: rb.baseAddress!.advanced(by: offset))
                        // swiftlint:enable force_unwrapping
                    offset += n
                    if offset > frames / 2 {
                        let gr = gen.finalLimiterStatus.preEncodeGainReductionDB
                        maxGR = max(maxGR, gr)
                        sumGR += gr
                        countGR += 1
                    }
                }
            }
        }
        return (left, right, maxGR, sumGR / Float(max(1, countGR)))
    }

    /// Amplitude of `hz` over the last whole number of cycles that fit in
    /// the final `window` seconds (settled, no leakage from a partial cycle).
    static func amplitude(_ x: [Float], _ hz: Double, window: Double = 0.3) -> Double {
        let cycles = max(1.0, (window * hz).rounded(.down))
        let n = Int((cycles * rate / hz).rounded())
        let start = x.count - n
        let w = 2.0 * Double.pi * hz / rate
        var s = 0.0, c = 0.0
        for i in start..<x.count {
            s += Double(x[i]) * sin(w * Double(i))
            c += Double(x[i]) * cos(w * Double(i))
        }
        return 2.0 * hypot(s, c) / Double(n)
    }

    static func dB(_ ratio: Double) -> Double { 20.0 * log10(max(ratio, 1e-15)) }

    /// Gain in dB of the stage switched on by `edit`, at `hz`, on a mono tone.
    static func monoStageGainDB(_ edit: (inout AppConfig) -> Void, hz: Double, amp: Double = 0.05) -> Double {
        let off = quietChain()
        var on = off
        edit(&on)
        let drive = Drive(left: [(amp, hz)], right: [(amp, hz)])
        let a = amplitude(render(off, drive).0, hz)
        let b = amplitude(render(on, drive).0, hz)
        return dB(b / a)
    }

    // MARK: - RBJ cookbook (Double), the oracle

    /// |H(e^jw)| in dB of an RBJ biquad with numerator b and denominator a.
    static func biquadDB(b: [Double], a: [Double], hz: Double) -> Double {
        let w = 2.0 * Double.pi * hz / rate
        func eval(_ k: [Double]) -> (Double, Double) {
            (k[0] + k[1] * cos(w) + k[2] * cos(2 * w), -(k[1] * sin(w) + k[2] * sin(2 * w)))
        }
        let (nr, ni) = eval(b)
        let (dr, di) = eval(a)
        return 10.0 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }

    static func peakingDB(f0: Double, gainDB: Double, q: Double, at hz: Double) -> Double {
        let A = pow(10.0, gainDB / 40.0), w0 = 2.0 * Double.pi * f0 / rate
        let alpha = sin(w0) / (2.0 * q)
        return biquadDB(b: [1 + alpha * A, -2 * cos(w0), 1 - alpha * A],
                        a: [1 + alpha / A, -2 * cos(w0), 1 - alpha / A], hz: hz)
    }

    static func shelfDB(high: Bool, f0: Double, gainDB: Double, at hz: Double) -> Double {
        let A = pow(10.0, gainDB / 40.0), w0 = 2.0 * Double.pi * f0 / rate
        let alpha = sin(w0) / 2.0 * sqrt(2.0)   // slope S = 1: sqrt((A + 1/A)(1/S - 1) + 2)
        let c = cos(w0), sA = 2.0 * sqrt(A) * alpha
        if high {
            return biquadDB(b: [A * ((A + 1) + (A - 1) * c + sA), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sA)],
                            a: [(A + 1) - (A - 1) * c + sA, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sA], hz: hz)
        }
        return biquadDB(b: [A * ((A + 1) - (A - 1) * c + sA), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sA)],
                        a: [(A + 1) + (A - 1) * c + sA, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sA], hz: hz)
    }

    static func highpassDB(fc: Double, at hz: Double) -> Double {
        let w0 = 2.0 * Double.pi * fc / rate, alpha = sin(w0) / (2.0 * 0.7071067811865476), c = cos(w0)
        return biquadDB(b: [(1 + c) / 2, -(1 + c), (1 + c) / 2], a: [1 + alpha, -2 * c, 1 - alpha], hz: hz)
    }

    // MARK: - Parametric EQ (stage 7)

    @Test func parametricEQFollowsTheCookbookWithNonZeroGains() {
        // All four bands at once, each with a gain, so a band wired to the
        // wrong slot, a sign flip or a gain that never reaches the stage all
        // show. Expected = product of the four sections (sum in dB).
        func edit(_ c: inout AppConfig) {
            c.parametricEQEnabled = true
            c.peqB1FreqHz = 100.0; c.peqB1GainDB = 6.0
            c.peqB2FreqHz = 1_000.0; c.peqB2GainDB = 6.0; c.peqB2Q = 1.0
            c.peqB3FreqHz = 4_000.0; c.peqB3GainDB = -6.0; c.peqB3Q = 2.0
            c.peqB4FreqHz = 10_000.0; c.peqB4GainDB = -6.0
        }
        for hz in [40.0, 100.0, 300.0, 1_000.0, 2_500.0, 4_000.0, 7_000.0, 10_000.0, 14_000.0] {
            let expected = Self.shelfDB(high: false, f0: 100.0, gainDB: 6.0, at: hz)
                + Self.peakingDB(f0: 1_000.0, gainDB: 6.0, q: 1.0, at: hz)
                + Self.peakingDB(f0: 4_000.0, gainDB: -6.0, q: 2.0, at: hz)
                + Self.shelfDB(high: true, f0: 10_000.0, gainDB: -6.0, at: hz)
            let measured = Self.monoStageGainDB(edit, hz: hz)
            #expect(abs(measured - expected) < 0.15,
                    "PEQ at \(Int(hz)) Hz: measured \(String(format: "%+.2f", measured)) dB, cookbook \(String(format: "%+.2f", expected)) dB")
        }
    }

    // MARK: - Input HPF (stage 4)

    @Test func inputHighpassIsASecondOrderButterworthAtItsCorner() {
        // hpf_hz 100 against the 10 Hz floor: -3.01 dB at the corner and
        // 12 dB/octave below it. The 10 Hz section of the reference render
        // is divided out with the same formula.
        for hz in [50.0, 100.0, 200.0, 1_000.0] {
            let expected = Self.highpassDB(fc: 100.0, at: hz) - Self.highpassDB(fc: 10.0, at: hz)
            let measured = Self.monoStageGainDB({ $0.hpfHz = 100.0 }, hz: hz)
            #expect(abs(measured - expected) < 0.15,
                    "HPF at \(Int(hz)) Hz: measured \(String(format: "%+.2f", measured)) dB, expected \(String(format: "%+.2f", expected)) dB")
        }
    }

    // MARK: - HF trim (stage 6)

    @Test func hfTrimIsAHighShelfCut() {
        for hz in [200.0, 1_000.0, 4_000.0, 8_000.0, 14_000.0] {
            let expected = Self.shelfDB(high: true, f0: 4_000.0, gainDB: -6.0, at: hz)
            let measured = Self.monoStageGainDB({ $0.hfTrimDB = -6.0; $0.hfTrimHz = 4_000.0 }, hz: hz)
            #expect(abs(measured - expected) < 0.15,
                    "HF trim at \(Int(hz)) Hz: measured \(String(format: "%+.2f", measured)) dB, expected \(String(format: "%+.2f", expected)) dB")
        }
    }

    // MARK: - Stereo-image protection (stage 16)

    /// Side gain at 8 kHz through a +12 dB PEQ peak at 8 kHz, for a side
    /// tone of `sideAmp` under a 200 Hz mid tone at 0.2.
    private func sideBoostThroughPEQ(sideAmp: Double) -> Double {
        let off = Self.quietChain()
        var on = off
        on.parametricEQEnabled = true
        on.peqB3FreqHz = 8_000.0; on.peqB3GainDB = 12.0; on.peqB3Q = 1.0
        let drive = Drive(left: [(0.2, 200.0), (sideAmp, 8_000.0)],
                          right: [(0.2, 200.0), (-sideAmp, 8_000.0)])
        func side(_ cfg: AppConfig) -> Double {
            let (l, r) = Self.render(cfg, drive)
            let s = zip(l, r).map { ($0 - $1) * 0.5 }
            return Self.amplitude(s, 8_000.0)
        }
        return Self.dB(side(on) / side(off))
    }

    @Test func stereoImageProtectionLimitsASideBoostThatWidensTheImage() {
        // The protection holds the output side/mid ratio near the input's.
        // A PEQ peak that lifts a WIDE side component (0.08 under a 0.2 mid,
        // ratio 0.4 in, 1.6 after +12 dB) past the allowed ratio must be
        // pulled back; a NARROW one (0.01, ratio 0.2 after the boost) must
        // get the full +12 dB -- the control that shows the PEQ boost is
        // really there and the protection is not a blanket side cut.
        let narrow = sideBoostThroughPEQ(sideAmp: 0.01)
        let wide = sideBoostThroughPEQ(sideAmp: 0.08)
        print(String(format: "[image protection] side boost through +12 dB PEQ: narrow %+.2f dB, wide %+.2f dB", narrow, wide))
        #expect(abs(narrow - Self.peakingDB(f0: 8_000.0, gainDB: 12.0, q: 1.0, at: 8_000.0)) < 0.3,
                "a narrow image must pass the PEQ boost untouched; got \(narrow) dB")
        #expect(wide < narrow - 2.0,
                "a side boost that widens the image past the allowed ratio must be limited; wide \(wide) dB vs narrow \(narrow) dB")
    }

    // MARK: - Encoder HF guard (stage 14)

    @Test func encoderHFGuardRidesAtMostTwoDecibelsAndIsStereoLinked() {
        // Pre-emphasis on (the guard disables itself at 0 us), HF limiter and
        // pre-encode limiter off so nothing else reacts to the drive. A loud
        // 8 kHz tone on L drives the guard; a quiet 10 kHz probe on BOTH
        // channels reads its ride. The probe's gain change on R, which
        // carries no drive, IS the guard's stereo-linked ride; on L it must
        // be the same. (L's own 8 kHz tone is not a clean probe: part of it
        // sits in the guard's LR4 low band, and hot drives hit the output
        // clamp after the +8.6 dB pre-emphasis.)
        var cfg = Self.quietChain()
        cfg.preemphasisUS = 50
        // The output limiter stays in the audio-only path; at its highest
        // threshold it is idle for every drive below (checked per render).
        cfg.preEncodeThreshold = 0.995
        let probe = (amp: 0.01, hz: 10_000.0)
        func probeLevels(leftDrive: Double) -> (left: Double, right: Double, maxGR: Float, meanGR: Float) {
            let left: [(amp: Double, hz: Double)] = leftDrive > 0 ? [(leftDrive, 8_000.0), probe] : [probe]
            let r = Self.renderWithGR(cfg, Drive(left: left, right: [probe]))
            return (Self.amplitude(r.left, probe.hz), Self.amplitude(r.right, probe.hz), r.maxGRDB, r.meanGRDB)
        }
        let quiet = probeLevels(leftDrive: 0.0)
        // Moderate drive, output limiter idle: the probe's ride is the
        // guard's alone, and it must be the same on both channels.
        let moderate = probeLevels(leftDrive: 0.2)
        let rideL = Self.dB(moderate.left / quiet.left)
        let rideR = Self.dB(moderate.right / quiet.right)
        // Past the threshold: at drives 0.3 and 0.4 (L output 0.85 / 0.95,
        // still under full scale and with the output limiter idle) the ride
        // must have SATURATED at the cap. On the 10 kHz probe the cap reads
        // about -1.8 dB, not -2.0: part of 10 kHz sits in the guard's LR4
        // low band, which the guard does not ride.
        let hot = probeLevels(leftDrive: 0.3)
        let hotter = probeLevels(leftDrive: 0.4)
        let rideHot = Self.dB(hot.right / quiet.right)
        let rideHotter = Self.dB(hotter.right / quiet.right)
        print(String(format: "[HF guard] drive 0.2: probe L %+.2f / R %+.2f dB; drive 0.3: R %+.2f dB; 0.4: R %+.2f dB; limiter %.2f / %.2f / %.2f dB",
                     rideL, rideR, rideHot, rideHotter, moderate.maxGR, hot.maxGR, hotter.maxGR))
        #expect(max(moderate.maxGR, hot.maxGR, hotter.maxGR) == 0.0,
                "fixture problem: the output limiter acted, so the probe would read it too")
        #expect(rideR < -0.3,
                "the R probe did not move (\(rideR) dB) with L driven: the guard is not running or not stereo-linked")
        #expect(abs(rideL - rideR) < 0.1,
                "the probe rode \(rideL) dB on L but \(rideR) dB on R: the guard is not stereo-linked")
        #expect(rideHot >= -2.05 && rideHotter >= -2.05,
                "the guard rode \(rideHot) / \(rideHotter) dB: more than its 2 dB cap")
        #expect(abs(rideHotter - rideHot) < 0.15 && rideHotter < -1.5,
                "33 % more drive moved the ride from \(rideHot) to \(rideHotter) dB: the ride is not capped")
    }

    // MARK: - Mono bass (stage 8)

    /// Side and mid gain of mono bass at `hz` (on vs off). Amplitude 0.01
    /// L-only: the side envelope stays under the image protection's 0.008
    /// floor, so the protection cannot mask what mono bass does.
    private func monoBassGains(hz: Double) -> (side: Double, mid: Double) {
        let off = Self.quietChain()
        var on = off
        on.monoBassEnabled = true
        on.monoBassFreqHz = 140.0
        let drive = Drive(left: [(0.01, hz)], right: [])
        func parts(_ cfg: AppConfig) -> (Double, Double) {
            let (l, r) = Self.render(cfg, drive, seconds: 0.8)
            let side = zip(l, r).map { ($0 - $1) * 0.5 }
            let mid = zip(l, r).map { ($0 + $1) * 0.5 }
            return (Self.amplitude(side, hz), Self.amplitude(mid, hz))
        }
        let a = parts(off), b = parts(on)
        return (Self.dB(b.0 / a.0), Self.dB(b.1 / a.1))
    }

    // Pass conditions from levelling review 2026-10 ("Tests
    // that should exist", finding 1). Measured failing on 2026-10-15: the
    // stage forms side - LP2(side), which barely removes side bass and
    // boosts the side about 2 dB above the corner.
    @Test
    func monoBassRemovesSideBelowCornerAndKeepsItAbove() {
        let low = monoBassGains(hz: 60.0)
        #expect(low.side <= -20.0, "side at 60 Hz with a 140 Hz corner: \(low.side) dB, must be <= -20 dB")
        for hz in [500.0, 2_000.0] {
            let g = monoBassGains(hz: hz)
            #expect(abs(g.side) <= 0.1, "side at \(Int(hz)) Hz: \(g.side) dB, must be within 0.1 dB")
        }
        for hz in [60.0, 500.0] {
            let g = monoBassGains(hz: hz)
            #expect(abs(g.mid) <= 0.01, "mid at \(Int(hz)) Hz moved \(g.mid) dB")
        }
    }

    @Test
    func monoBassNeverBoostsSide() {
        for hz in [100.0, 140.0, 200.0, 300.0] {
            let g = monoBassGains(hz: hz)
            #expect(g.side <= 0.1, "mono bass boosts the side by \(g.side) dB at \(Int(hz)) Hz")
        }
    }

    // MARK: - Per-band downward expander (stage 9a)

    /// Gain the expander applies to a 1 kHz tone at `toneDBFS` peak, with
    /// threshold -45 dB, against the same chain with the expander off. The
    /// classic chain (multiband on, Advanced Dynamics off) is where it lives;
    /// the tone sits far below the compressor thresholds.
    private func expanderGainDB(ratio: Double, toneDBFS: Double) -> Double {
        var off = Self.quietChain()
        off.multibandEnabled = true
        var on = off
        on.downwardExpanderEnabled = true
        on.expanderThresholdDB = -45.0
        on.expanderRatio = ratio
        let amp = pow(10.0, toneDBFS / 20.0)
        let drive = Drive(left: [(amp, 1_000.0)], right: [(amp, 1_000.0)])
        let a = Self.amplitude(Self.render(off, drive, seconds: 1.0).0, 1_000.0)
        let b = Self.amplitude(Self.render(on, drive, seconds: 1.0).0, 1_000.0)
        return Self.dB(b / a)
    }

    @Test func expanderLeavesProgrammeAboveThresholdAlone() {
        let g = expanderGainDB(ratio: 2.0, toneDBFS: -30.0)
        #expect(abs(g) < 0.2, "a tone 15 dB above the expander threshold moved \(g) dB")
    }

    // A 1:r downward expander outputs T + r (in - T) below threshold, i.e. a
    // gain of (r - 1)(in - T). Tone 10 dB under the -45 dB threshold (its
    // peak detector reads ~0.77 dB below the sine peak, per the levelling
    // review): ratio 2 must give about -10.8 dB, ratio 1 nothing. Measured
    // 2026-10-15: -21.5 dB at ratio 2 and -10.8 dB at ratio 1 -- the gain is
    // `belowDB * ratio`, an off-by-one in the ratio.
    @Test
    func expanderFollowsTheOneToRLawBelowThreshold() {
        let r2 = expanderGainDB(ratio: 2.0, toneDBFS: -55.0)
        let r1 = expanderGainDB(ratio: 1.0, toneDBFS: -55.0)
        #expect(abs(r2 - (-10.77)) < 1.0, "ratio 2, 10 dB under threshold: \(r2) dB, expected about -10.8 dB")
        #expect(abs(r1) < 0.2, "ratio 1 must not expand: \(r1) dB")
    }
}
