import Testing
import Foundation
@testable import MPXPrime

// The Final-MPX look-ahead limiter is the last gain-riding stage before the
// 1x safety shaper; if it lets peaks through, the shaper clips them at 1x
// with full aliasing (the 0.45 distortion class). Chain review A1b found the
// pre-0.45 detector leaking 0.9-2.7 dB on dense program; these tests pin the
// contract: nothing above the threshold leaves the limiter once the
// look-ahead window is primed, at any drive, on program-like signals.

@Suite("Final-MPX look-ahead limiter")
struct LookaheadLimiterTests {

    private let sampleRate: Float = 192_000.0

    private func run(_ input: [Float], lookaheadMS: Float, threshold: Float = 0.9) -> (out: [Float], limiter: LookaheadLimiter) {
        var limiter = LookaheadLimiter()
        limiter.configure(sampleRate: sampleRate, lookaheadMS: lookaheadMS, threshold: threshold, enabled: true)
        var out = [Float](repeating: 0.0, count: input.count)
        for i in 0..<input.count { out[i] = limiter.process(input[i]) }
        return (out, limiter)
    }

    /// Dense two-tone at 12 dB over the threshold -- the bright_dense class.
    private func denseOverdrive(frames: Int) -> [Float] {
        (0..<frames).map { n in
            let t = Float(n) / sampleRate
            return 3.6 * (0.7 * sinf(2.0 * .pi * 1_000.0 * t) + 0.3 * sinf(2.0 * .pi * 9_000.0 * t))
        }
    }

    @Test func nothingAboveTheThresholdLeavesWithLookAhead() {
        let frames = Int(sampleRate * 0.5)
        let (out, _) = run(denseOverdrive(frames: frames), lookaheadMS: 5.0)
        var worst: Float = 0.0
        for i in Int(sampleRate * 0.02)..<frames { worst = max(worst, fabsf(out[i])) }
        let overDB = 20.0 * log10f(worst / 0.9)
        print(String(format: "look-ahead limiter: worst output %.4f vs threshold 0.9 (%+.3f dB)", worst, overDB))
        #expect(overDB <= 0.02, "peaks leak past the threshold by \(overDB) dB")
    }

    @Test func aSuddenBurstIsCaughtBeforeItArrives() {
        // Silence, then an instant 6 dB-over sine: the gain must already be at
        // depth when the first hot sample leaves the delay line.
        let frames = Int(sampleRate * 0.2)
        let start = frames / 2
        let input = (0..<frames).map { n -> Float in
            n < start ? 0.0 : 1.8 * sinf(2.0 * .pi * 3_000.0 * Float(n - start) / sampleRate)
        }
        let (out, _) = run(input, lookaheadMS: 5.0)
        var worst: Float = 0.0
        for v in out { worst = max(worst, fabsf(v)) }
        #expect(worst <= 0.9 * 1.002, "burst leading edge leaked: \(worst) vs 0.9")
    }

    @Test func belowThresholdIsAPureDelay() {
        let frames = 4_096
        let input = (0..<frames).map { n in 0.5 * sinf(2.0 * .pi * 997.0 * Float(n) / sampleRate) }
        let (out, limiter) = run(input, lookaheadMS: 5.0)
        let d = limiter.lookaheadSamples
        var maxErr: Float = 0.0
        for i in d..<frames { maxErr = max(maxErr, fabsf(out[i] - input[i - d])) }
        #expect(maxErr < 1e-6, "sub-threshold program must pass as a pure \(d)-sample delay; error \(maxErr)")
    }

    @Test func reportsTheGainItApplies() {
        let (_, limiter) = run(denseOverdrive(frames: Int(sampleRate * 0.3)), lookaheadMS: 5.0)
        // 12 dB over -> ~12 dB of gain reduction reported while the program is hot.
        #expect(limiter.gainReductionDB > 10.0 && limiter.gainReductionDB < 13.0,
                "reported GR \(limiter.gainReductionDB) dB does not match a 12 dB overdrive")
    }

    @Test func withoutLookAheadItStillLimits() {
        let (out, _) = run(denseOverdrive(frames: Int(sampleRate * 0.3)), lookaheadMS: 0.0)
        var worst: Float = 0.0
        for i in Int(sampleRate * 0.05)..<out.count { worst = max(worst, fabsf(out[i])) }
        // Feedback-only: a floor still caps the current sample.
        #expect(worst <= 0.9 * 1.002, "no-look-ahead path exceeded the threshold: \(worst)")
    }
}
