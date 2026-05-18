import Accelerate
import Foundation

/// Patent-style clipping candidate for 0.27 research.
///
/// The clipper applies a hard ceiling, then reconstructs the output as:
///
///     delayed clean input + band-limited clipping residual
///
/// This keeps the wanted signal phase-aligned with the FIR group delay while
/// restricting the broadband clipping error. It is intentionally not wired
/// into the production chain yet; tests use it as the Accelerate-backed
/// candidate for the US 6,937,912 work.
struct AcceleratedBandlimitedResidualClipper {
    private var threshold: Float = 0.62
    private var coeffs: [Float] = []
    private var residualDelay: [Float] = []
    private var cleanDelay: [Float] = []
    private var residualWriteIndex: Int = 0
    private var cleanWriteIndex: Int = 0
    private var tapCountValue: Int = 0
    private var groupDelayValue: Int = 0

    var tapCount: Int { tapCountValue }
    var groupDelaySamples: Int { groupDelayValue }
    var enabled: Bool { tapCountValue > 0 }

    init(threshold: Float = 0.62, tapCount: Int = 65, cutoffFraction: Float = 0.20) {
        configure(threshold: threshold, tapCount: tapCount, cutoffFraction: cutoffFraction)
    }

    mutating func configure(threshold: Float, tapCount requestedTapCount: Int = 65, cutoffFraction: Float = 0.20) {
        self.threshold = min(0.999, max(0.05, threshold))
        let count = max(5, requestedTapCount | 1)
        let cutoff = min(0.49, max(0.05, cutoffFraction))
        coeffs = Self.windowedSincLowpassTaps(tapCount: count, cutoffFraction: cutoff)
        tapCountValue = coeffs.count
        groupDelayValue = (tapCountValue - 1) / 2
        residualDelay = [Float](repeating: 0.0, count: tapCountValue * 2)
        cleanDelay = [Float](repeating: 0.0, count: max(1, groupDelayValue))
        residualWriteIndex = 0
        cleanWriteIndex = 0
    }

    mutating func reset() {
        for i in 0..<residualDelay.count {
            residualDelay[i] = 0.0
        }
        for i in 0..<cleanDelay.count {
            cleanDelay[i] = 0.0
        }
        residualWriteIndex = 0
        cleanWriteIndex = 0
    }

    mutating func process(_ x: Float) -> Float {
        guard enabled else { return hardClip(x) }
        let clipped = hardClip(x)
        let residual = clipped - x
        let delayedClean = processCleanDelay(x)
        let filteredResidual = processResidual(residual)
        return delayedClean + filteredResidual
    }

    func hardClip(_ x: Float) -> Float {
        min(threshold, max(-threshold, x))
    }

    private mutating func processCleanDelay(_ x: Float) -> Float {
        let delayed = cleanDelay[cleanWriteIndex]
        cleanDelay[cleanWriteIndex] = x
        cleanWriteIndex += 1
        if cleanWriteIndex >= cleanDelay.count { cleanWriteIndex = 0 }
        return delayed
    }

    private mutating func processResidual(_ residual: Float) -> Float {
        residualDelay[residualWriteIndex] = residual
        residualDelay[residualWriteIndex + tapCountValue] = residual

        let startIndex = residualWriteIndex + 1
        var output: Float = 0.0
        let n = vDSP_Length(tapCountValue)
        coeffs.withUnsafeBufferPointer { coeffPtr in
            residualDelay.withUnsafeBufferPointer { delayPtr in
                // baseAddress is non-nil for non-empty pre-allocated arrays (vDSP idiom).
                // swiftlint:disable force_unwrapping
                vDSP_dotpr(
                    coeffPtr.baseAddress!, 1,
                    delayPtr.baseAddress!.advanced(by: startIndex), 1,
                    &output,
                    n
                )
                // swiftlint:enable force_unwrapping
            }
        }

        residualWriteIndex += 1
        if residualWriteIndex >= tapCountValue { residualWriteIndex = 0 }
        return output
    }

    private static func windowedSincLowpassTaps(tapCount: Int, cutoffFraction: Float) -> [Float] {
        let count = max(5, tapCount | 1)
        let center = Float(count - 1) * 0.5
        var taps = [Float](repeating: 0.0, count: count)
        var sum: Float = 0.0

        for n in 0..<count {
            let x = Float(n) - center
            let sincArg = 2.0 * cutoffFraction * x
            let sincValue: Float
            if abs(sincArg) < 1e-6 {
                sincValue = 1.0
            } else {
                sincValue = sinf(.pi * sincArg) / (.pi * sincArg)
            }
            let phase = 2.0 * Float.pi * Float(n) / Float(count - 1)
            let window = 0.5 - (0.5 * cosf(phase))
            let tap = 2.0 * cutoffFraction * sincValue * window
            taps[n] = tap
            sum += tap
        }

        if abs(sum) > 1e-12 {
            for n in 0..<count {
                taps[n] /= sum
            }
        }
        return taps
    }
}
