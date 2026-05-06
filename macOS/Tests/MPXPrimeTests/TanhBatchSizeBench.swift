import Testing
import Foundation
import Accelerate
@testable import MPXPrime

// Diagnostic micro-benchmark: at what batch size does vvtanhf beat
// scalar tanhf? We use 8-element batches in CompositeClipper (8×
// oversampling), so the answer determines whether the vvtanhf change
// is actually a speedup at that batch size, marginal, or a regression.
//
// Apple's vvtanhf has fixed call overhead (~50-100 ns) plus a per-element
// SIMD cost (~3-5 ns). Scalar tanhf is ~25-40 ns per call. The break-even
// point is somewhere between batch size 4 and 16.

@Suite("vvtanhf batch-size break-even")
struct TanhBatchSizeBench {

    @Test func benchmarkScalarVsVDSPAtVariousBatchSizes() {
        let totalCalls = 5_000_000

        for batchSize in [1, 4, 8, 16, 32, 64, 128] {
            var input = [Float](repeating: 0.5, count: batchSize)
            var output = [Float](repeating: 0, count: batchSize)

            // Warm up both paths
            for _ in 0..<100 {
                for i in 0..<batchSize { output[i] = tanhf(input[i]) }
                var n = Int32(batchSize)
                input.withUnsafeMutableBufferPointer { iPtr in
                    output.withUnsafeMutableBufferPointer { oPtr in
                        vvtanhf(oPtr.baseAddress!, iPtr.baseAddress!, &n)
                    }
                }
            }

            let iters = totalCalls / batchSize
            let clock = ContinuousClock()

            // Scalar
            let scalarStart = clock.now
            var scalarSum: Float = 0
            for _ in 0..<iters {
                for i in 0..<batchSize {
                    output[i] = tanhf(input[i])
                }
                scalarSum += output[0]  // prevent dead-store elimination
            }
            let scalarElapsed = clock.now - scalarStart
            let scalarSec = Double(scalarElapsed.components.seconds)
                + Double(scalarElapsed.components.attoseconds) / 1e18

            // vDSP
            var vdspSum: Float = 0
            let vdspStart = clock.now
            for _ in 0..<iters {
                var n = Int32(batchSize)
                input.withUnsafeMutableBufferPointer { iPtr in
                    output.withUnsafeMutableBufferPointer { oPtr in
                        vvtanhf(oPtr.baseAddress!, iPtr.baseAddress!, &n)
                    }
                }
                vdspSum += output[0]
            }
            let vdspElapsed = clock.now - vdspStart
            let vdspSec = Double(vdspElapsed.components.seconds)
                + Double(vdspElapsed.components.attoseconds) / 1e18

            let speedup = scalarSec / max(1e-9, vdspSec)
            print(String(format: "batch=%-3d  scalar=%6.3f s  vvtanhf=%6.3f s  speedup=%5.2fx (scalarSum=%.3f, vdspSum=%.3f)",
                         batchSize, scalarSec, vdspSec, speedup, scalarSum, vdspSum))
        }
    }
}
