import Testing
import Foundation
@testable import MPXPrime

/// Listening must not change what is transmitted.
///
/// The concurrent monitor decodes each composite sample as it is produced, in
/// the same pass. That decode reads the encoder's delay-aligned subcarrier
/// reference and its own decoder state, so it CANNOT move the composite -- but
/// "cannot" is worth a test, because this runs on air and the alternative is
/// discovering it in a strict-baseline diff months later.
@Suite("Monitor render parity")
struct MonitorRenderParityTests {

    private let frames = 4_096

    private func config() -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        cfg.sourceMode = "input"
        // Wall-clock-paced RDS text would make two renders differ on their own.
        cfg.enRDS = false
        return cfg
    }

    private func program(_ i: Int) -> (Float, Float) {
        let t = Double(i) / 192_000.0
        let l = Float(0.4 * sin(2.0 * .pi * 700.0 * t) + 0.2 * sin(2.0 * .pi * 6_000.0 * t))
        let r = Float(0.35 * sin(2.0 * .pi * 1_100.0 * t) - 0.15 * sin(2.0 * .pi * 9_000.0 * t))
        return (l, r)
    }

    @Test func theCompositeIsIdenticalWithAndWithoutTheMonitorTap() {
        let plain = MPXGenerator(config: config(), sampleRate: 192_000.0)
        let tapped = MPXGenerator(config: config(), sampleRate: 192_000.0)

        var plainL = [Float](repeating: 0, count: frames)
        var plainR = [Float](repeating: 0, count: frames)
        var tappedL = [Float](repeating: 0, count: frames)
        var tappedR = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let (l, r) = program(i)
            plainL[i] = l; plainR[i] = r
            tappedL[i] = l; tappedR[i] = r
        }
        var monL = [Float](repeating: 0, count: frames)
        var monR = [Float](repeating: 0, count: frames)

        plainL.withUnsafeMutableBufferPointer { l in
            plainR.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                plain.renderFromInputInPlace(frameCount: frames, left: l.baseAddress!, right: r.baseAddress!)
            }
        }
        tappedL.withUnsafeMutableBufferPointer { l in
            tappedR.withUnsafeMutableBufferPointer { r in
                monL.withUnsafeMutableBufferPointer { ml in
                    monR.withUnsafeMutableBufferPointer { mr in
                        tapped.renderFromInputInPlace(
                            // swiftlint:disable:next force_unwrapping
                            frameCount: frames, left: l.baseAddress!, right: r.baseAddress!,
                            // swiftlint:disable:next force_unwrapping
                            analysis: .none, monitorLeft: ml.baseAddress!, monitorRight: mr.baseAddress!)
                    }
                }
            }
        }

        var firstDiff: Int?
        for i in 0..<frames where plainL[i] != tappedL[i] {
            firstDiff = i
            break
        }
        #expect(firstDiff == nil, "the composite moved when the monitor was listening")
        #expect(plainR == tappedR, "the second composite channel moved")
    }

    @Test func theMonitorTapActuallyProducesAudio() {
        // The parity test above would also pass if the tap wrote nothing, so
        // pin that it decodes something recognisable.
        let gen = MPXGenerator(config: config(), sampleRate: 192_000.0)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let (l, r) = program(i)
            left[i] = l; right[i] = r
        }
        var monL = [Float](repeating: 0, count: frames)
        var monR = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                monL.withUnsafeMutableBufferPointer { ml in
                    monR.withUnsafeMutableBufferPointer { mr in
                        gen.renderFromInputInPlace(
                            // swiftlint:disable:next force_unwrapping
                            frameCount: frames, left: l.baseAddress!, right: r.baseAddress!,
                            // swiftlint:disable:next force_unwrapping
                            analysis: .none, monitorLeft: ml.baseAddress!, monitorRight: mr.baseAddress!)
                    }
                }
            }
        }
        let tail = frames / 2
        var peak: Float = 0
        for i in tail..<frames { peak = max(peak, max(abs(monL[i]), abs(monR[i]))) }
        #expect(peak > 0.01, "the monitor tap produced silence (peak \(peak))")
        #expect(monL.allSatisfy { $0.isFinite } && monR.allSatisfy { $0.isFinite })
    }
}
