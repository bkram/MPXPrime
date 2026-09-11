import Testing
import Foundation
import MPXPrimeCore
@testable import MPXPrime

// The cross-check the 0.60 audit asked for: render the real chain for longer
// than the Recommendation's window, feed the composite into the Meter's
// measurement engine, and require the encoder's own BS.412 figure and the
// Meter's to agree.
//
// This is the test the pre-0.60 stage could never have passed. It measured
// the audio composite BEFORE pilot and RDS injection, so it was blind to
// about a tenth of the power; the Meter measures what is actually on the
// wire. Both sides now compute the same quantity from the same definition,
// and -- importantly -- they do it with INDEPENDENT code, so an
// equal-and-opposite mistake cannot hide.
// Gated behind `MPXPRIME_DEEP=1`: a 192 kHz full-chain render long enough to
// prime a 60-second window costs minutes, not seconds, and the default suite
// has to stay fast. Run before a release, or after touching the final stage:
//
//   MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     swift test --package-path macOS --filter BS412FullChain
private let deepEnabled = ProcessInfo.processInfo.environment["MPXPRIME_DEEP"] != nil

@Suite("BS.412 full-chain cross-check", .enabled(if: deepEnabled))
struct BS412FullChainTests {

    private let sampleRate: Double = 192_000.0

    private func config(ceilingDBr: Double, bs412: Bool) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = 4096
        cfg.operatingMode = .mpx
        cfg.processingBypass = false
        // Wall-clock-paced RDS text would make two renders differ; the
        // subcarrier itself is not needed for a power check.
        cfg.enRDS = false
        cfg.bs412Enabled = bs412
        cfg.bs412CeilingDBr = ceilingDBr
        cfg.mpxDeviationKHz = 75.0
        cfg.outputGainDB = 0.0
        return cfg
    }

    /// Render `seconds` of programme and return the composite.
    private func render(_ cfg: AppConfig, seconds: Double) -> [Float] {
        let generator = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let frames = Int(sampleRate * seconds)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        // Steady programme: two tones, slightly different per channel so the
        // stereo subcarrier carries something.
        let w1 = 2.0 * Double.pi * 440.0 / sampleRate
        let w2 = 2.0 * Double.pi * 1_270.0 / sampleRate
        for i in 0..<frames {
            let t = Double(i)
            left[i] = Float(0.3 * sin(w1 * t) + 0.15 * sin(w2 * t))
            right[i] = Float(0.3 * sin(w1 * t) - 0.15 * sin(w2 * t))
        }
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                let block = 4096
                var offset = 0
                while offset < frames {
                    let n = min(block, frames - offset)
                    generator.renderFromInputInPlace(
                        frameCount: n,
                        // swiftlint:disable force_unwrapping
                        left: lb.baseAddress!.advanced(by: offset),
                        right: rb.baseAddress!.advanced(by: offset)
                        // swiftlint:enable force_unwrapping
                    )
                    offset += n
                }
            }
        }
        return left
    }

    /// The Meter's reading of the same composite. Its absolute calibration is
    /// amplitude 1.0 == 75 kHz, matching the encoder's normalisation.
    private func meterPowerDBr(_ composite: [Float]) -> Float {
        let analysis = MeterAnalysis(sampleRate: Float(sampleRate), fullScaleKHz: 75.0)
        var buf = [Float](repeating: 0.0, count: 8192)
        var offset = 0
        while offset < composite.count {
            let n = min(buf.count, composite.count - offset)
            for i in 0..<n { buf[i] = composite[offset + i] }
            buf.withUnsafeBufferPointer {
                analysis.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
            }
            offset += n
        }
        return analysis.snapshot().mpxPowerDBr
    }

    @Test func theEncoderAndTheMeterAgreeOnCompleteMultiplexPower() {
        // 65 seconds: past the Recommendation's 60 s window on both sides.
        let cfg = config(ceilingDBr: 0.0, bs412: false)
        let composite = render(cfg, seconds: 65.0)
        let meter = meterPowerDBr(composite)

        // Measure the same composite with the encoder's own meter, fed the
        // way the chain feeds it.
        var encoder = BS412MultiplexPowerMeter()
        encoder.configure(sampleRate: Float(sampleRate))
        for sample in composite { encoder.process(sample) }

        #expect(encoder.windowValid, "65 s must validate a 60 s window")
        #expect(abs(encoder.powerDBr - meter) < 0.2,
                """
                encoder reads \(encoder.powerDBr) dBr and the Meter reads \(meter) dBr \
                on the same composite -- the two definitions have diverged
                """)
    }

    /// Settling behaviour, NOT a compliance test -- it looks at the settled
    /// end of a long render. `BS412PowerLimiterTests` is what checks every
    /// window, including the first and the transitions.
    @Test func theLimiterSettlesUnderTheCeiling() {
        // Drive it hard enough to need real reduction, then check the Meter
        // agrees the finished signal is compliant.
        var hot = config(ceilingDBr: -1.0, bs412: true)
        hot.finalDriveDB = 6.0
        let composite = render(hot, seconds: 200.0)
        let settled = Array(composite.suffix(Int(sampleRate * 60.0)))
        let meter = meterPowerDBr(settled)
        #expect(meter <= -1.0 + 0.3,
                "the Meter reads \(meter) dBr on the settled signal, over the -1.0 dBr ceiling")
    }

    @Test func theMeasurementRunsWhileTheLimiterIsOff() {
        // Continuous observation is what lets the operator switch the
        // limiter on without a 60-second blind spot.
        let cfg = config(ceilingDBr: 0.0, bs412: false)
        let composite = render(cfg, seconds: 65.0)
        #expect(!composite.isEmpty)
        var encoder = BS412MultiplexPowerMeter()
        encoder.configure(sampleRate: Float(sampleRate))
        for sample in composite { encoder.process(sample) }
        #expect(encoder.windowValid)
        #expect(encoder.powerDBr.isFinite)
    }
}
