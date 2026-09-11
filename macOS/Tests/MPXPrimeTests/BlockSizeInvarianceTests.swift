import Foundation
import Testing

@testable import MPXPrime

// The DSP must not care how the host slices time: the composite rendered in
// 512-frame blocks, 4096-frame blocks and odd 480-frame blocks (CoreAudio
// delivers non-power-of-two counts on some devices) must be bit-identical.
// Anything else would make the on-air sound depend on the buffer size.
@Suite struct BlockSizeInvarianceTests {
    private func render(block: Int, frames: Int) -> [Float] {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        // RDS off: its text scheduler paces PS/RT frames by wall-clock uptime
        // (right on air, non-deterministic for two offline renders).
        cfg.enRDS = false
        let gen = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        for n in 0..<frames {
            let t = Double(n) / cfg.sampleRate
            left[n] = Float(0.4 * sin(2.0 * Double.pi * 1_000.0 * t) + 0.2 * sin(2.0 * Double.pi * 9_000.0 * t))
            right[n] = Float(0.35 * sin(2.0 * Double.pi * 1_300.0 * t) - 0.2 * sin(2.0 * Double.pi * 11_000.0 * t))
        }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var offset = 0
                while offset < frames {
                    let count = min(block, frames - offset)
                    // swiftlint:disable:next force_unwrapping
                    gen.renderFromInputInPlace(frameCount: count, left: l.baseAddress!.advanced(by: offset), right: r.baseAddress!.advanced(by: offset))
                    offset += count
                }
            }
        }
        return left
    }

    @Test func compositeIsBitIdenticalAcrossBlockSizes() {
        let frames = 96_000
        let reference = render(block: 512, frames: frames)
        for block in [64, 480, 1024, 4096, 8192] {
            let other = render(block: block, frames: frames)
            #expect(other == reference, "block size \(block) changed the composite")
        }
    }
}
