import Foundation
import Testing

@testable import MPXPrime

// 2026-10 audio-chain overhaul, gain-structure audit C1: clip depth.
//
// Until then the composite clipper's look-ahead target was its own ceiling,
// so the 2 ms ride removed 100 % of every overshoot and the oversampled,
// guard-band-protected tanh kernel only ever bent peaks that were already
// sitting on the ceiling: 0.16 dB of kernel GR on every scenario and every
// profile, -4 dB RMS on bright programme. "Enable Composite Clipper" was a
// look-ahead LIMITER with an 80 ms release. `mpx_clipper_lookahead_depth_db`
// moves the ride target to `ceiling x depth`: the ride removes only what
// exceeds the depth and the kernel clips the rest. 0 dB is the old behaviour.
//
// Re-derivation of `CompositeClipperLookaheadTests.peakLA <= ceiling x 1.05`:
// that bound assumed the look-ahead alone places the peak on the ceiling. With
// a depth the kernel places it: its output is `thr + knee x tanh(excess)`,
// which never reaches the ceiling, and the only thing that can leave above
// the ceiling is the guard-band share of the clipping residual that the guard
// FIR restores (17-21 / 22-54 / 55-59 kHz). On a band-limited mono sine those
// shares are its 17th+ harmonics, so the bound holds with margin at every
// depth; on M+S programme the restored S share is what the final limiter
// rides, as before. The old test keeps depth 0 (the `configure` default),
// where its derivation is unchanged; this file pins the depth > 0 case.
@Suite("Composite clipper clip depth")
struct CompositeClipDepthTests {

    private let sampleRate: Float = 192_000.0
    private static let threshold: Float = -1.0
    private static let ceiling: Float = -0.3

    private func makeClipper(depthDB: Float, lookaheadMS: Float = 2.0) -> CompositeClipper {
        var clip = CompositeClipper()
        clip.configure(sampleRate: sampleRate, thresholdDB: Self.threshold, ceilingDB: Self.ceiling,
                       cancelAudio: false, stereoGuard: 1.0, cancelPilot: true, cancelRDS: true,
                       lookaheadMS: lookaheadMS, lookaheadDepthDB: depthDB)
        return clip
    }

    private static func lin(_ db: Float) -> Float { powf(10.0, db / 20.0) }

    /// Hot 1 kHz sine, `overDB` above the ceiling, through the clipper; returns
    /// the steady-state output peak and the two GR telemetry maxima.
    private func runSine(_ clip: inout CompositeClipper, overDB: Float, frames: Int = 32_768)
        -> (peak: Float, kernelGR: Float, lookaheadGR: Float, out: [Float]) {
        let amplitude = Self.lin(Self.ceiling + overDB)
        let w = 2.0 * Float.pi * 1_000.0 / sampleRate
        var out = [Float](repeating: 0.0, count: frames)
        var peak: Float = 0.0
        var kernelGR: Float = 0.0
        var lookaheadGR: Float = 0.0
        let settle = frames / 4
        for i in 0..<frames {
            out[i] = clip.process(amplitude * sinf(Float(i) * w))
            if i >= settle {
                peak = max(peak, fabsf(out[i]))
                kernelGR = max(kernelGR, clip.gainReductionDB)
                lookaheadGR = max(lookaheadGR, clip.lookaheadGainReductionDB)
            }
        }
        return (peak, kernelGR, lookaheadGR, out)
    }

    // MARK: - The mechanism

    @Test func theRideTargetIsCeilingTimesDepth() {
        for depth: Float in [0.0, 1.5, 3.0, 6.0] {
            let clip = makeClipper(depthDB: depth)
            let expected = Self.lin(Self.ceiling) * Self.lin(depth)
            #expect(abs(clip.lookaheadTargetLinear - expected) < 1e-5,
                    "depth \(depth): target \(clip.lookaheadTargetLinear), expected \(expected)")
        }
        // Clamped to the 0...6 dB range AppConfig uses.
        let over = makeClipper(depthDB: 9.0)
        #expect(abs(over.lookaheadTargetLinear - Self.lin(Self.ceiling) * Self.lin(6.0)) < 1e-5)
        let under = makeClipper(depthDB: -2.0)
        #expect(abs(under.lookaheadTargetLinear - Self.lin(Self.ceiling)) < 1e-5)
    }

    @Test func depthZeroIsTheOldLookaheadLimiter() {
        var clip = makeClipper(depthDB: 0.0)
        let r = runSine(&clip, overDB: 3.5)
        print(String(format: "[depth 0] peak %.4f (%+.3f dB vs ceiling), kernel GR %.2f dB, look-ahead GR %.2f dB",
                     r.peak, 20.0 * log10f(r.peak / Self.lin(Self.ceiling)), r.kernelGR, r.lookaheadGR))
        // The ride takes the whole 3.5 dB; the kernel only bends the
        // ceiling-pinned peak (the 0.16 dB of every pre-overhaul baseline).
        #expect(r.lookaheadGR > 3.0, "look-ahead must ride the whole overshoot at depth 0; GR \(r.lookaheadGR) dB")
        #expect(r.kernelGR < 0.3, "kernel GR at depth 0 is the knee bend only; got \(r.kernelGR) dB")
    }

    @Test func theDepthIsLeftToTheKernel() {
        var clip = makeClipper(depthDB: 3.0)
        let r = runSine(&clip, overDB: 3.5)
        print(String(format: "[depth 3] peak %.4f (%+.3f dB vs ceiling), kernel GR %.2f dB, look-ahead GR %.2f dB",
                     r.peak, 20.0 * log10f(r.peak / Self.lin(Self.ceiling)), r.kernelGR, r.lookaheadGR))
        // The ride removes only the 0.5 dB that exceeds the depth ...
        #expect(r.lookaheadGR > 0.3 && r.lookaheadGR < 0.9,
                "look-ahead must remove only the excess over the depth (0.5 dB); GR \(r.lookaheadGR) dB")
        // ... and the kernel clips the 3 dB that are left to it.
        #expect(r.kernelGR > 2.0, "kernel must clip the depth; GR \(r.kernelGR) dB")
        // The kernel's output never reaches the ceiling; what leaves above it
        // is the restored guard-band share of the residual (see the header).
        #expect(r.peak <= Self.lin(Self.ceiling) * 1.02,
                "output peak \(r.peak) exceeds the ceiling \(Self.lin(Self.ceiling)) by more than the guard share")
    }

    @Test func overshootUnderTheDepthIsNotRiddenAtAll() {
        // 2 dB over the ceiling with a 3 dB depth: the look-ahead stays at
        // unity (a pure delay) and the kernel does everything.
        var clip = makeClipper(depthDB: 3.0)
        let r = runSine(&clip, overDB: 2.0)
        #expect(r.lookaheadGR < 0.01, "look-ahead must be idle under the depth; GR \(r.lookaheadGR) dB")
        #expect(r.kernelGR > 1.2, "kernel GR \(r.kernelGR) dB on a 2 dB overshoot")
    }

    @Test func depthAppliesLiveWithoutAReset() {
        // Configure at depth 0, run hot, switch to depth 3 mid-stream: the
        // output stays finite and continuous and settles to the depth-3
        // steady state the configure path produces.
        var live = makeClipper(depthDB: 0.0)
        var reference = makeClipper(depthDB: 3.0)
        let amplitude = Self.lin(Self.ceiling + 3.5)
        let w = 2.0 * Float.pi * 1_000.0 / sampleRate
        let frames = 65_536
        var maxStep: Float = 0.0
        var previous: Float = 0.0
        var tail: Float = 0.0
        for i in 0..<frames {
            if i == frames / 4 { live.setLookaheadDepthDB(3.0) }
            let x = amplitude * sinf(Float(i) * w)
            let y = live.process(x)
            let ref = reference.process(x)
            #expect(y.isFinite)
            if i > 0 { maxStep = max(maxStep, fabsf(y - previous)) }
            previous = y
            if i >= frames - 8_192 { tail = max(tail, fabsf(y - ref)) }
        }
        // A 1 kHz sine at this level moves at most ~0.03 per sample; a gain
        // step would add far more.
        #expect(maxStep < 0.06, "live depth change stepped the output by \(maxStep)")
        #expect(tail < 1e-3, "live depth change did not settle to the configured state (max delta \(tail))")
    }

    // MARK: - Guard bands stay clean with the kernel at work

    @Test func pilotAndRDSGuardsStayCleanAtFullDepth() {
        // The kernel now clips 6 dB of a hot M + S composite; the guards must
        // still keep its IM out of the 19 and 57 kHz centres (the same floors
        // `CompositeClipperStereoSeparationTests` pins at the shipped depth).
        let fftSize = 16_384
        let warmup = 4_096
        let frames = warmup + fftSize
        var mpx = [Float](repeating: 0.0, count: frames)
        let wAudio = 2.0 * Float.pi * 1_000.0 / sampleRate
        let w38 = 2.0 * Float.pi * 38_000.0 / sampleRate
        for i in 0..<frames {
            let l = 0.95 * sinf(Float(i) * wAudio)
            let r = 0.4 * sinf(Float(i) * wAudio * 2.3)
            let m = 0.5 * (l + r)
            let s = 0.5 * (l - r)
            mpx[i] = 2.0 * (m + s * sinf(Float(i) * w38))
        }
        var clip = makeClipper(depthDB: 6.0)
        var out = [Float](repeating: 0.0, count: frames)
        var kernelGR: Float = 0.0
        for i in 0..<frames {
            out[i] = clip.process(mpx[i])
            if i >= warmup { kernelGR = max(kernelGR, clip.gainReductionDB) }
        }
        let report = FFTAnalyzer(fftSize: fftSize).analyze(Array(out[warmup..<frames]), sampleRate: sampleRate)
        let pilot = report.peakDBFS(in: 18_970...19_030)
        let rds = report.peakDBFS(in: 56_970...57_030)
        print(String(format: "[guards at depth 6] kernel GR %.2f dB, 19 kHz %.1f dBFS, 57 kHz %.1f dBFS", kernelGR, pilot, rds))
        #expect(kernelGR > 3.0, "the kernel must be working hard here; GR \(kernelGR) dB")
        #expect(pilot < -75.0, "pilot centre \(pilot) dBFS with the kernel clipping")
        #expect(rds < -90.0, "RDS centre \(rds) dBFS with the kernel clipping")
    }

    // MARK: - Configuration plumbing

    @Test func theKeyRoundTripsAndClamps() throws {
        var cfg = AppConfig()
        cfg.compositeClipperLookaheadDepthDB = 3.7
        let ini = try cfg.captureAsINIString()
        #expect(ini.contains("mpx_clipper_lookahead_depth_db = 3.7"))
        let parsed = INIParser.parse(ini)
        #expect(parsed["MPX"]?["mpx_clipper_lookahead_depth_db"] == "3.7")
        var hot = AppConfig()
        hot.compositeClipperLookaheadDepthDB = 9.5
        hot.validate()
        #expect(hot.compositeClipperLookaheadDepthDB == 6.0)
        var low = AppConfig()
        low.compositeClipperLookaheadDepthDB = -1.0
        low.validate()
        #expect(low.compositeClipperLookaheadDepthDB == 0.0)
        // Live-apply: the field rides RuntimeConfig.
        let runtime = MPXGenerator.makeRuntimeConfig(from: cfg)
        #expect(abs(runtime.compositeClipperLookaheadDepthDB - 3.7) < 1e-6)
    }

    @Test func shippedProfilesCarryTheMeasuredDepths() {
        // The largest depth per profile that keeps the --verify-hf-transients
        // SINAD floors (ride >= 30 dB, hat >= 20 dB / 15 dB loud) with 2 dB
        // in hand at stereo guard 0.5 (ride SINAD 33.9-34.3 dB at 1.0 on the
        // music profiles, 29.4-29.7 at 1.5); see the clip depth table in the
        // 2026-10 report. Classical was 2.0 until the levelling task raised
        // its drive to 5 dB, where depth 2 costs the ride SINAD (27.3 dB at
        // 4 dB of drive) and depth 1 keeps it (33.8 dB at 5 dB).
        let expected: [String: Double] = [
            "music_clean": 1.0, "music_loud": 1.0, "music_dense": 1.0,
            "speech": 1.0, "classical_wide": 1.0
        ]
        for (id, depth) in expected {
            var cfg = AppConfig()
            #expect(PresetCatalog.applyFormatProfile(id: id, to: &cfg) != nil)
            #expect(abs(cfg.compositeClipperLookaheadDepthDB - depth) < 1e-9,
                    "\(id): depth \(cfg.compositeClipperLookaheadDepthDB), expected \(depth)")
        }
        // A fresh install IS Music - Clean.
        var clean = AppConfig()
        _ = PresetCatalog.applyFormatProfile(id: "music_clean", to: &clean)
        #expect(AppConfig().compositeClipperLookaheadDepthDB == clean.compositeClipperLookaheadDepthDB)
    }

    @Test func liveDepthEditMatchesARestart() {
        // Build at depth 0, live-apply depth 3, render; a generator built at
        // depth 3 must agree once the ride has released (the scalar is the
        // only state that differs, and the ramp is contractive).
        var a = AppConfig()
        a.sampleRate = Double(sampleRate)
        a.enRDS = false
        a.advancedDynamicsEnabled = false
        a.widebandAGCEnabled = false
        a.multibandEnabled = false
        a.preEncodeAudioLimiterEnabled = false
        a.finalDriveDB = 10.0
        a.compositeClipperLookaheadDepthDB = 0.0
        var b = a
        b.compositeClipperLookaheadDepthDB = 3.0
        let live = MPXGenerator(config: a, sampleRate: a.sampleRate)
        live.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: b))
        let restarted = MPXGenerator(config: b, sampleRate: b.sampleRate)
        let frames = Int(a.sampleRate * 2.0)
        var worst: Float = 0.0
        var kernelGR: Float = 0.0
        for n in 0..<frames {
            let t = Double(n) / a.sampleRate
            let l = Float(0.7 * sin(2.0 * Double.pi * 1_000.0 * t) + 0.3 * sin(2.0 * Double.pi * 9_000.0 * t))
            let r = Float(0.6 * sin(2.0 * Double.pi * 1_300.0 * t) - 0.3 * sin(2.0 * Double.pi * 11_000.0 * t))
            let y = live.renderSingleSample(leftIn: l, rightIn: r)
            let z = restarted.renderSingleSample(leftIn: l, rightIn: r)
            if n >= frames / 2 {
                worst = max(worst, fabsf(y - z))
                kernelGR = max(kernelGR, live.finalLimiterStatus.gainReductionDB)
            }
        }
        print(String(format: "[live depth] live vs restart max delta %.3g, kernel GR %.2f dB", worst, kernelGR))
        #expect(kernelGR > 1.0, "the clipper must be clipping on this hot chain; GR \(kernelGR) dB")
        #expect(worst < 1e-4, "live depth edit differs from a restart by \(worst)")
    }

    // MARK: - The chain: dense programme is clipped, not ridden

    @Test func denseProgrammeIsClippedNotRidden() {
        // bright_dense through the shipped chain (RDS off for determinism):
        // the kernel does the depth's worth of clipping, the look-ahead no
        // longer rides it, the true-peak final limiter bounds the restored
        // guard-band share and the filter overshoot, the shaper stays idle
        // and the multiplex stays under 0 dBFS on the 4x true peak. At depth
        // 0 the same chain is the old look-ahead limiter.
        //
        // Measured 2026-10 (sweep in audits-2026-10-20/report-clipper.md):
        // the depth buys NO loudness on this programme -- dRMS -3.7 dB at
        // depth 0 and at depth 1 and 2 through Music - Clean, +0.2 dB through
        // Loud / Dense -- because 70-85 % of what the kernel removes returns
        // as the restored guard-band residual plus decimator / 55 kHz FIR
        // overshoot (final-limiter duty 0.78 dB at depth 1, 1.44 at depth 2)
        // and the final limiter rides it. This test pins THAT: the two
        // chains' RMS agree, and the ride has moved from the clipper's
        // look-ahead to the final limiter. A claim that depth buys loudness
        // belongs here only with a second clip after the filters.
        guard let dense = verificationScenarios().first(where: { $0.name == "bright_dense" }) else {
            Issue.record("bright_dense scenario missing")
            return
        }
        var cfg = AppConfig()
        cfg.sampleRate = Double(sampleRate)
        cfg.enRDS = false
        var flat = cfg
        flat.compositeClipperLookaheadDepthDB = 0.0
        let shipped = verifyScenario(config: cfg, durationSeconds: 4.0, scenario: dense)
        guard let denseAgain = verificationScenarios().first(where: { $0.name == "bright_dense" }) else { return }
        let ridden = verifyScenario(config: flat, durationSeconds: 4.0, scenario: denseAgain)
        print(String(format: "[dense] depth %.1f: kernel GR %.2f dB, final GR %.2f dB, safety clip %.2f dB, true peak %.3f dBFS, dRMS %.2f dB; depth 0: kernel GR %.2f dB, final GR %.2f dB, dRMS %.2f dB",
                     cfg.compositeClipperLookaheadDepthDB, shipped.maxLimiterGRDB, shipped.maxSafetyGRDB, shipped.maxSafetyClipDB,
                     dbfsValue(shipped.truePeakAbs), shipped.rmsDeltaDB, ridden.maxLimiterGRDB, ridden.maxSafetyGRDB, ridden.rmsDeltaDB))
        let depth = Float(cfg.compositeClipperLookaheadDepthDB)
        #expect(depth >= 1.0, "the shipped default must leave at least 1 dB to the kernel; got \(depth)")
        #expect(shipped.maxLimiterGRDB > depth - 0.2 && shipped.maxLimiterGRDB < depth + 0.2,
                "kernel GR \(shipped.maxLimiterGRDB) dB must read the depth (\(depth) dB) on dense programme")
        #expect(ridden.maxLimiterGRDB < 0.4, "depth 0 must reproduce the ride-only chain; kernel GR \(ridden.maxLimiterGRDB) dB")
        #expect(ridden.maxSafetyGRDB < 0.1, "at depth 0 the final limiter is idle; GR \(ridden.maxSafetyGRDB) dB")
        // The restored guard share of the clipped depth is ridden by the
        // final limiter: 0.78 dB measured at depth 1 (stereo guard 0.5).
        #expect(shipped.maxSafetyGRDB > 0.4 && shipped.maxSafetyGRDB < depth,
                "final limiter must ride the restored overshoot, less than the depth; GR \(shipped.maxSafetyGRDB) dB")
        // The measured loudness figure: no gain, no loss (-3.7 vs -3.7 dB).
        #expect(abs(shipped.rmsDeltaDB - ridden.rmsDeltaDB) < 0.5,
                "dRMS \(shipped.rmsDeltaDB) vs \(ridden.rmsDeltaDB) dB at depth 0: the depth moves the ride, it does not buy loudness here")
        #expect(shipped.maxSafetyClipDB < 0.01, "shaper engaged: \(shipped.maxSafetyClipDB) dB")
        #expect(shipped.maxPostInjectionOvershoot == 0.0)
        #expect(!shipped.overBudget)
        #expect(shipped.truePeakAbs <= 1.0, "4x true peak \(shipped.truePeakAbs) above full scale")
    }
}
