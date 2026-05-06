import Testing
import Foundation
@testable import MPXPrime

@Suite("StereoInputRingBuffer")
struct StereoInputRingBufferTests {
    @Test func stereoWriteReadRoundTrip() {
        let ring = StereoInputRingBuffer(capacityFrames: 8)
        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [11, 12, 13, 14]
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: 4)
            }
        }

        var outLeft = [Float](repeating: 0, count: 4)
        var outRight = [Float](repeating: 0, count: 4)
        let missing = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.read(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 4
                )
            }
        }

        #expect(missing == 0)
        #expect(outLeft == left)
        #expect(outRight == right)
    }

    @Test func monoWriteDuplicatesChannels() {
        let ring = StereoInputRingBuffer(capacityFrames: 8)
        let mono: [Float] = [0.25, 0.5, 0.75]
        mono.withUnsafeBufferPointer { buffer in
            ring.writeMono(mono: buffer.baseAddress!, frameCount: mono.count)
        }

        var outLeft = [Float](repeating: 0, count: mono.count)
        var outRight = [Float](repeating: 0, count: mono.count)
        let missing = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.read(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: mono.count
                )
            }
        }

        #expect(missing == 0)
        #expect(outLeft == mono)
        #expect(outRight == mono)
    }

    @Test func wraparoundReadWrite() {
        let ring = StereoInputRingBuffer(capacityFrames: 512)
        let firstLeft: [Float] = Array(0..<500).map(Float.init)
        let firstRight: [Float] = Array(1000..<1500).map(Float.init)
        firstLeft.withUnsafeBufferPointer { leftBuffer in
            firstRight.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: firstLeft.count)
            }
        }

        var discardLeft = [Float](repeating: 0, count: 496)
        var discardRight = [Float](repeating: 0, count: 496)
        _ = discardLeft.withUnsafeMutableBufferPointer { leftBuffer in
            discardRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.read(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 496
                )
            }
        }

        let secondLeft: [Float] = Array(500..<532).map(Float.init)
        let secondRight: [Float] = Array(1500..<1532).map(Float.init)
        secondLeft.withUnsafeBufferPointer { leftBuffer in
            secondRight.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: secondLeft.count)
            }
        }

        var outLeft = [Float](repeating: 0, count: 36)
        var outRight = [Float](repeating: 0, count: 36)
        let missing = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.read(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 36
                )
            }
        }

        #expect(missing == 0)
        #expect(outLeft == Array(496..<532).map(Float.init))
        #expect(outRight == Array(1496..<1532).map(Float.init))
    }

    @Test func overflowKeepsNewestFrames() {
        let ring = StereoInputRingBuffer(capacityFrames: 512)
        let left: [Float] = Array(0..<520).map(Float.init)
        let right: [Float] = Array(1000..<1520).map(Float.init)
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: left.count)
            }
        }

        var outLeft = [Float](repeating: 0, count: 512)
        var outRight = [Float](repeating: 0, count: 512)
        let missing = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.read(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 512
                )
            }
        }

        #expect(missing == 0)
        #expect(outLeft == Array(8..<520).map(Float.init))
        #expect(outRight == Array(1008..<1520).map(Float.init))
        #expect(ring.stats().overflows == 8)
    }

    @Test func underflowCountsAndZeroFills() {
        let ring = StereoInputRingBuffer(capacityFrames: 8)
        let left: [Float] = [1, 2]
        let right: [Float] = [11, 12]
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: 2)
            }
        }

        var outLeft = [Float](repeating: -1, count: 4)
        var outRight = [Float](repeating: -1, count: 4)
        let missing = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.read(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 4
                )
            }
        }

        #expect(missing == 2)
        #expect(outLeft == [1, 2, 0, 0])
        #expect(outRight == [11, 12, 0, 0])
        #expect(ring.stats().underflows == 2)
    }

    @Test func bufferedFramesAndStats() {
        let ring = StereoInputRingBuffer(capacityFrames: 8)
        let left: [Float] = [1, 2, 3]
        let right: [Float] = [11, 12, 13]
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: 3)
            }
        }

        #expect(ring.bufferedFrames() == 3)
        let stats = ring.stats()
        #expect(stats.bufferedFrames == 3)
        #expect(stats.overflows == 0)
        #expect(stats.underflows == 0)
    }

    @Test func readAdaptiveMatchedRateDirectPath() {
        let ring = StereoInputRingBuffer(capacityFrames: 8)
        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [11, 12, 13, 14]
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: 4)
            }
        }

        var outLeft = [Float](repeating: 0, count: 4)
        var outRight = [Float](repeating: 0, count: 4)
        let missing = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.readAdaptive(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 4,
                    nominalConsume: 4,
                    targetBuffered: 4,
                    deadband: 0
                )
            }
        }

        #expect(missing == 0)
        #expect(outLeft == left)
        #expect(outRight == right)
    }

    @Test func readAdaptiveFractionalPathMaintainsContinuity() {
        let ring = StereoInputRingBuffer(capacityFrames: 16)
        let left: [Float] = Array(0..<12).map(Float.init)
        let right: [Float] = Array(100..<112).map(Float.init)
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: 12)
            }
        }

        var outLeft = [Float](repeating: 0, count: 4)
        var outRight = [Float](repeating: 0, count: 4)
        let missing = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.readAdaptive(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 4,
                    nominalConsume: 6,
                    targetBuffered: 8,
                    deadband: 0
                )
            }
        }

        #expect(missing == 0)
        #expect(abs(outLeft[0] - 0) <= 0.0001)
        #expect(outLeft[1] > outLeft[0])
        #expect(outLeft[2] > outLeft[1])
        #expect(outLeft[3] > outLeft[2])
        #expect(abs(outRight[0] - 100) <= 0.0001)
        #expect(outRight[1] > outRight[0])
    }

    @Test func readAdaptiveMatchedRateReportsDirectMode() {
        let ring = StereoInputRingBuffer(capacityFrames: 32)
        let left: [Float] = Array(0..<16).map(Float.init)
        let right: [Float] = Array(100..<116).map(Float.init)
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: left.count)
            }
        }

        var outLeft = [Float](repeating: 0, count: 16)
        var outRight = [Float](repeating: 0, count: 16)
        _ = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.readAdaptive(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 16,
                    nominalConsume: 16,
                    targetBuffered: 16,
                    deadband: 0
                )
            }
        }

        let snapshot = ring.transportSnapshot()
        #expect(snapshot.resampleMode == "direct")
        #expect(abs(snapshot.sampleStep - 1.0) <= 0.000001)
        #expect(abs(snapshot.ratioTrim - 0.0) <= 0.000001)
        #expect(outLeft == left)
        #expect(outRight == right)
    }

    @Test func adaptiveCubicInterpolationBeatsLinearForHighFrequencySine() {
        let ring = StereoInputRingBuffer(capacityFrames: 128)
        let omega = 2.0 * Double.pi * 0.22
        let sourceCount = 96
        let source = (0..<sourceCount).map { Float(sin(Double($0) * omega)) }
        source.withUnsafeBufferPointer { mono in
            ring.writeMono(mono: mono.baseAddress!, frameCount: source.count)
        }

        var outLeft = [Float](repeating: 0, count: 32)
        var outRight = [Float](repeating: 0, count: 32)
        let missing = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.readAdaptive(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 32,
                    nominalConsume: 48,
                    targetBuffered: sourceCount,
                    deadband: 0
                )
            }
        }

        #expect(missing == 0)
        let expected = (0..<32).map { Float(sin(Double($0) * 1.5 * omega)) }
        let cubicError = Self.rmsError(actual: outLeft, expected: expected)
        let linearReference = (0..<32).map { index -> Float in
            let position = Double(index) * 1.5
            let base = Int(position.rounded(.down))
            let frac = Float(position - Double(base))
            let next = min(base + 1, source.count - 1)
            let a = source[base]
            let b = source[next]
            return a + ((b - a) * frac)
        }
        let linearError = Self.rmsError(actual: linearReference, expected: expected)

        #expect(cubicError < linearError)
        #expect(ring.transportSnapshot().resampleMode == "adaptive-cubic")
    }

    @Test func largeWriteLargerThanCapacityKeepsNewestTail() {
        let ring = StereoInputRingBuffer(capacityFrames: 512)
        let left: [Float] = Array(0..<600).map(Float.init)
        let right: [Float] = Array(200..<800).map(Float.init)
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                ring.write(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: left.count)
            }
        }

        var outLeft = [Float](repeating: 0, count: 512)
        var outRight = [Float](repeating: 0, count: 512)
        let missing = outLeft.withUnsafeMutableBufferPointer { leftBuffer in
            outRight.withUnsafeMutableBufferPointer { rightBuffer in
                ring.read(
                    intoLeft: leftBuffer.baseAddress!,
                    outRight: rightBuffer.baseAddress!,
                    frameCount: 512
                )
            }
        }

        #expect(missing == 0)
        #expect(outLeft == Array(88..<600).map(Float.init))
        #expect(outRight == Array(288..<800).map(Float.init))
        #expect(ring.stats().overflows == 88)
    }

    private static func rmsError(actual: [Float], expected: [Float]) -> Float {
        let count = min(actual.count, expected.count)
        guard count > 0 else { return 0.0 }
        let sum = (0..<count).reduce(Float.zero) { partial, index in
            let delta = actual[index] - expected[index]
            return partial + (delta * delta)
        }
        return sqrt(sum / Float(count))
    }
}
