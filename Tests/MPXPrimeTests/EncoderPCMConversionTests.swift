import Foundation
import Testing
@testable import MPXPrime

/// The ALSA integer conversions (encoder review 2026-10,
/// finding 11): S16 used to truncate toward zero, a 1 LSB dead zone with no
/// dither.
@Suite("Encoder PCM conversion")
struct EncoderPCMConversionTests {
    static let lsb = Float(1.0 / 32_767.0)

    @Test func s16RoundsToNearest() {
        #expect(PCMSampleConverter.s16(0.4 * Self.lsb, dither: 0) == 0)
        #expect(PCMSampleConverter.s16(-0.4 * Self.lsb, dither: 0) == 0)
        #expect(PCMSampleConverter.s16(0.6 * Self.lsb, dither: 0) == 1)
        #expect(PCMSampleConverter.s16(-0.6 * Self.lsb, dither: 0) == -1)
        #expect(PCMSampleConverter.s16(1.0, dither: 0) == 32_767)
        #expect(PCMSampleConverter.s16(-1.0, dither: 0) == -32_767)
        // Dither never wraps at the rails.
        #expect(PCMSampleConverter.s16(1.0, dither: 0.99) == 32_767)
        #expect(PCMSampleConverter.s16(-1.0, dither: -1.99) == -32_768)
    }

    /// With TPDF dither a signal far below one LSB survives on average:
    /// the mean output tracks the input (truncation gave exactly 0), and the
    /// dither noise is the TPDF figure (variance 1/6 LSB^2 plus the rounding
    /// error's 1/12).
    @Test func s16DitherHasNoDeadZone() {
        var converter = PCMSampleConverter()
        for level in [0.3, -0.3, 0.7] {
            let n = 200_000
            var sum = 0.0
            var sumSquares = 0.0
            for _ in 0..<n {
                let y = Double(converter.s16(Float(level) * Self.lsb))
                sum += y
                sumSquares += (y - level) * (y - level)
            }
            let mean = sum / Double(n)
            let variance = sumSquares / Double(n)
            #expect(abs(mean - level) < 0.01, "mean \(mean) LSB for \(level) LSB in")
            #expect(abs(variance - 0.25) < 0.03, "error variance \(variance) LSB^2")
        }
    }

    @Test func s32Rounds() {
        #expect(PCMSampleConverter.s32(1.0) == 2_147_483_520)
        #expect(PCMSampleConverter.s32(-1.0) == -2_147_483_520)
        #expect(PCMSampleConverter.s32(0.0) == 0)
    }
}
