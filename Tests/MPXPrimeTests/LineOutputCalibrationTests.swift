#if os(macOS)
import Testing
import Foundation
@testable import MPXPrime

/// The composite line-output trim (`mpx_line_output_dbfs`).
///
/// This exists because the trim was INERT on air on macOS until 0.50: the
/// scale/clip block sat inside the render callback's test-tone branch, so a
/// live-input composite went to the converter untrimmed while the DAC Peak
/// readout divided by the trim as if it had been applied. Only a disposition
/// test covered the key, and a disposition test cannot see that.
@Suite("MPX line output calibration")
struct LineOutputCalibrationTests {

    private func render(scale: Float, sample: Float, frames: Int = 64) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: sample, count: frames)
        var right = [Float](repeating: -sample, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                AudioOutputEngine.applyLineOutput(scale: scale, left: l.baseAddress!, right: r.baseAddress!, frameCount: frames)
            }
        }
        return (left, right)
    }

    @Test func attenuationScalesBothChannels() {
        // -6 dB is the operator-visible case: half the amplitude at the DAC.
        let scale = powf(10.0, -6.0 / 20.0)
        let out = render(scale: scale, sample: 0.8)
        #expect(abs(out.left[0] - 0.8 * scale) < 1e-6, "left \(out.left[0])")
        #expect(abs(out.right[0] + 0.8 * scale) < 1e-6, "right \(out.right[0])")
    }

    @Test func zeroDBFSIsBitIdentical() {
        // The default must not touch a sample -- that is what keeps every
        // captured baseline valid.
        let out = render(scale: 1.0, sample: 0.73)
        #expect(out.left.allSatisfy { $0 == 0.73 })
        #expect(out.right.allSatisfy { $0 == -0.73 })
    }

    @Test func positiveTrimClampsInsteadOfLettingTheConverterDoIt() {
        // +3 dB on a composite already near 100% modulation would overshoot;
        // the clamp is deterministic here rather than converter-dependent.
        let scale = powf(10.0, 3.0 / 20.0)
        let out = render(scale: scale, sample: 0.95)
        #expect(out.left.allSatisfy { $0 == 1.0 }, "left peaked at \(out.left[0])")
        #expect(out.right.allSatisfy { $0 == -1.0 }, "right peaked at \(out.right[0])")
    }

    @Test func theTrimAppliedAndTheTrimMeteredAreTheSameNumber() {
        // The DAC Peak readout and the DAC write both use the scale both
        // engines take from OutputWiring (review finding 10: this test used
        // to compute the scale itself, so the engines' copy was never run).
        var cfg = AppConfig()
        cfg.mpxLineOutputDBFS = -6.0
        let scale = OutputWiring.lineOutputScale(
            lineOutputDBFS: Float(cfg.mpxLineOutputDBFS), mode: .mpxComposite)
        let out = render(scale: scale, sample: 1.0)
        #expect(abs(20.0 * log10(Double(out.left[0])) - cfg.mpxLineOutputDBFS) < 0.01,
                "the DAC got \(out.left[0]) for a full-scale composite at \(cfg.mpxLineOutputDBFS) dBFS")
        let metered = OutputWiring.dacPeak(compositePeak: 1.0, lineOutputScale: scale)
        #expect(metered == out.left[0], "DAC Peak reads \(metered), the DAC got \(out.left[0])")
    }
}
#endif
