import Foundation
import Testing

@testable import MPXPrime

// 2026-10 audio-chain overhaul: the final MPX limiter's detector reads the
// 4x true peak. On air the programme's negative peaks sat 0.35 dB above a
// full-scale tone's at the same sample budget (air-log 2026-10-20):
// inter-sample peaks of the 55 kHz-limited composite that the 1x sample
// detector could not see. The sliding window is now fed the largest of the
// sample and its four interpolated estimates, the ramp is shortened by the
// interpolator's delay so it stays a bound, and the audio path is untouched.
@Suite("Final-MPX limiter true-peak detector")
struct TruePeakFinalLimiterTests {

    private let sampleRate: Float = 192_000.0
    private let threshold: Float = 0.9

    private func run(_ input: [Float], lookaheadMS: Float) -> (out: [Float], limiter: LookaheadLimiter, maxGainStep: Float) {
        var limiter = LookaheadLimiter()
        limiter.configure(sampleRate: sampleRate, lookaheadMS: lookaheadMS, threshold: threshold, enabled: true)
        var out = [Float](repeating: 0.0, count: input.count)
        var previousGain: Float = 1.0
        var maxStep: Float = 0.0
        for i in 0..<input.count {
            out[i] = limiter.process(input[i])
            maxStep = max(maxStep, fabsf(limiter.gain - previousGain))
            previousGain = limiter.gain
        }
        return (out, limiter, maxStep)
    }

    /// Dense overdrive whose crest sits BETWEEN samples: a 1 kHz bed plus a
    /// 47.3 kHz component (close to fs/4, where the sample peak under-reads a
    /// sinusoid by up to 0.3 dB) -- the upper stereo sideband region of the
    /// composite.
    private func interSampleOverdrive(frames: Int, level: Float = 2.0) -> [Float] {
        (0..<frames).map { n in
            let t = Float(n) / sampleRate
            return level * (0.55 * sinf(2.0 * .pi * 1_000.0 * t) + 0.45 * sinf(2.0 * .pi * 47_300.0 * t + 0.4))
        }
    }

    private func worstTruePeak(_ out: [Float], from start: Int) -> (true: Float, sample: Float) {
        let tail = Array(out[start...])
        let tp = truePeak4x(tail)
        return (tp.truePeak, tp.samplePeak)
    }

    @Test func detectorGeometry() {
        var limiter = LookaheadLimiter()
        limiter.configure(sampleRate: sampleRate, lookaheadMS: 5.0, threshold: threshold, enabled: true)
        #expect(limiter.truePeakDetectorActive)
        #expect(limiter.detectorDelaySamples > 0 && limiter.detectorDelaySamples < 20,
                "detector delay \(limiter.detectorDelaySamples) samples should be a few samples at 192 kHz")
        // The audio path's delay is the look-ahead only; the detector adds none.
        #expect(limiter.latencySamples == 960)
        // Too short a look-ahead for the estimate to arrive in time: the
        // stage falls back to the sample detector rather than leaking.
        var short = LookaheadLimiter()
        short.configure(sampleRate: sampleRate, lookaheadMS: 0.01, threshold: threshold, enabled: true)
        #expect(!short.truePeakDetectorActive)
    }

    @Test func nothingAboveTheThresholdLeavesOnThe4xTruePeak() {
        let frames = Int(sampleRate * 0.5)
        let (out, _, maxStep) = run(interSampleOverdrive(frames: frames), lookaheadMS: 5.0)
        let peaks = worstTruePeak(out, from: Int(sampleRate * 0.05))
        let overDB = 20.0 * log10f(peaks.true / threshold)
        print(String(format: "[true peak] worst 4x true peak %.4f (%+.3f dB vs threshold), sample peak %.4f, max gain step %.5f",
                     peaks.true, overDB, peaks.sample, maxStep))
        #expect(overDB <= 0.03, "inter-sample peaks leak past the threshold by \(overDB) dB")
        #expect(peaks.sample <= threshold * 1.0005)
        // Step-free ramp: a 6 dB ride over 960 samples moves the gain by well
        // under 0.005 per sample.
        #expect(maxStep < 0.005, "gain stepped by \(maxStep) in one sample")
    }

    /// Band-limited (55 kHz, the composite FIR's passband) clicks whose
    /// true peak sits exactly BETWEEN two samples: a windowed sinc centred
    /// at n + 0.5. Its two largest samples read 0.87 x the true peak
    /// (+1.2 dB between them), the hard-panned HF transient of AGENTS.md
    /// reduced to its essence. Spaced 60 ms apart so each click arrives
    /// with the gain back near unity and is caught only by what the
    /// detector sees. A dense stimulus cannot serve as this control: over a
    /// 4 ms hold its samples visit every phase of the HF component, so the
    /// sample maximum approaches the true peak and the sample detector
    /// passes by accident -- a sine alone passes without a true-peak
    /// detector.
    private func interSampleClicks(frames: Int, level: Float) -> [Float] {
        var x = [Float](repeating: 0.0, count: frames)
        let bandwidth: Float = 2.0 * 55_000.0 / sampleRate  // sinc(bandwidth x t) has a 55 kHz band
        let halfSpan = 48
        let spacing = Int(sampleRate * 0.060)
        var centre = Int(sampleRate * 0.02)
        while centre + halfSpan < frames {
            for k in -halfSpan...halfSpan {
                let t = Float(k) - 0.5
                let arg = Float.pi * bandwidth * t
                let sinc = abs(arg) < 1e-6 ? 1.0 : sinf(arg) / arg
                let window = 0.5 * (1.0 + cosf(Float.pi * t / Float(halfSpan)))
                x[centre + k] += level * sinc * window
            }
            centre += spacing
        }
        return x
    }

    @Test func clicksAreCaughtOnTheirTruePeak() {
        // Clicks whose sample peak is 1.2 x the threshold (true peak
        // 1.38 x): with the detector active nothing above the threshold
        // leaves on the 4x estimate.
        let frames = Int(sampleRate * 0.5)
        let input = interSampleClicks(frames: frames, level: threshold * 1.2 / 0.870)
        let (out, limiter, _) = run(input, lookaheadMS: 5.0)
        #expect(limiter.truePeakDetectorActive)
        let peaks = worstTruePeak(out, from: 0)
        let overDB = 20.0 * log10f(peaks.true / threshold)
        print(String(format: "[clicks, true-peak detector] worst 4x true peak %.4f (%+.3f dB vs threshold), sample peak %.4f",
                     peaks.true, overDB, peaks.sample))
        #expect(overDB <= 0.03, "inter-sample click peaks leak past the threshold by \(overDB) dB")
    }

    @Test func theSampleDetectorAloneLetsInterSampleClicksThrough() {
        // Negative control: the same clicks with the true-peak detector
        // inactive (look-ahead shorter than its delay). The sample detector
        // places the two largest SAMPLES on the threshold and the true peak
        // between them leaves about 1.2 dB over -- what the air measurement
        // saw on programme (0.35 dB of negative-peak excess the 1x detector
        // could not see).
        let frames = Int(sampleRate * 0.5)
        let input = interSampleClicks(frames: frames, level: threshold * 1.2 / 0.870)
        let (out, limiter, _) = run(input, lookaheadMS: 0.01)
        #expect(!limiter.truePeakDetectorActive)
        let peaks = worstTruePeak(out, from: 0)
        let overDB = 20.0 * log10f(peaks.true / threshold)
        print(String(format: "[clicks, sample detector] worst 4x true peak %.4f (%+.3f dB vs threshold), sample peak %.4f",
                     peaks.true, overDB, peaks.sample))
        #expect(peaks.sample <= threshold * 1.002, "the sample detector must still hold the samples; \(peaks.sample)")
        #expect(overDB > 0.5, "the control must show the inter-sample leak the detector fixes; got \(overDB) dB")
    }

    @Test func aBurstIsCaughtOnItsTruePeakBeforeItArrives() {
        let frames = Int(sampleRate * 0.2)
        let start = frames / 2
        let hot = interSampleOverdrive(frames: frames - start, level: 1.6)
        let input = (0..<frames).map { n -> Float in n < start ? 0.0 : hot[n - start] }
        let (out, _, _) = run(input, lookaheadMS: 5.0)
        let peaks = worstTruePeak(out, from: 0)
        let overDB = 20.0 * log10f(peaks.true / threshold)
        #expect(overDB <= 0.03, "burst leading edge leaked on the true peak by \(overDB) dB")
    }

    @Test func belowThresholdIsStillAPureDelay() {
        let frames = 8_192
        let input = interSampleOverdrive(frames: frames, level: 0.6)
        let (out, limiter, _) = run(input, lookaheadMS: 5.0)
        let d = limiter.lookaheadSamples
        var maxErr: Float = 0.0
        for i in d..<frames { maxErr = max(maxErr, fabsf(out[i] - input[i - d])) }
        #expect(maxErr < 1e-6, "sub-threshold programme must pass as a pure \(d)-sample delay; error \(maxErr)")
        #expect(limiter.gainReductionDB == 0.0)
    }

    @Test func theMultiplexStaysUnderFullScaleOnTheTruePeak() {
        // Hot chain (12 dB drive, RDS off so the render is deterministic):
        // the audio composite's 4x true peak must stay on the budget, so the
        // complete multiplex with the pilot stays under 0 dBFS on the 4x
        // estimate and nothing is clamped after injection.
        var cfg = AppConfig()
        cfg.sampleRate = Double(sampleRate)
        cfg.enRDS = false
        cfg.finalDriveDB = 12.0
        cfg.advancedDynamicsEnabled = false
        cfg.widebandAGCEnabled = false
        cfg.multibandEnabled = false
        cfg.preEncodeAudioLimiterEnabled = false
        cfg.hfLimiterEnabled = false
        let generator = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        let frames = Int(cfg.sampleRate * 3.0)
        let settle = frames / 3
        var out = [Float](repeating: 0.0, count: frames - settle)
        var finalGR: Float = 0.0
        var safetyClip: Float = 0.0
        var overshoot: Float = 0.0
        for n in 0..<frames {
            let t = Double(n) / cfg.sampleRate
            // Bright, hard-panned top so the stereo sidebands carry the crest.
            let l = Float(0.5 * sin(2.0 * Double.pi * 80.0 * t) + 0.4 * sin(2.0 * Double.pi * 1_000.0 * t)
                + 0.45 * sin(2.0 * Double.pi * 11_000.0 * t))
            let r = Float(0.5 * sin(2.0 * Double.pi * 80.0 * t) + 0.3 * sin(2.0 * Double.pi * 1_300.0 * t)
                - 0.45 * sin(2.0 * Double.pi * 11_000.0 * t))
            let y = generator.renderSingleSample(leftIn: l, rightIn: r)
            if n >= settle {
                out[n - settle] = y
                let status = generator.finalLimiterStatus
                finalGR = max(finalGR, status.safetyGainReductionDB)
                safetyClip = max(safetyClip, status.safetyClipDB)
                overshoot = max(overshoot, generator.compositeCalibrationStatus.postInjectionOvershoot)
            }
        }
        let tp = truePeak4x(out)
        // Budget with pilot 8 %, RDS off: 1 - 0.08 - 0.005 = 0.915; plus the
        // pilot the multiplex can reach 0.995 at most.
        print(String(format: "[chain true peak] mpx sample peak %.4f, 4x true peak %.4f (%+.3f dBFS), final GR %.2f dB, safety clip %.2f dB, post-injection overshoot %.5f",
                     tp.samplePeak, tp.truePeak, dbfsValue(tp.truePeak), finalGR, safetyClip, overshoot))
        #expect(finalGR > 0.05, "the final limiter must be riding on this hot chain; GR \(finalGR) dB")
        #expect(tp.truePeak <= 1.0, "4x true peak \(tp.truePeak) above full scale")
        #expect(tp.truePeak <= 0.995 * 1.003, "4x true peak \(tp.truePeak) above the budget plus pilot (0.995)")
        #expect(safetyClip < 0.01, "shaper engaged: \(safetyClip) dB")
        #expect(overshoot == 0.0)
    }
}
