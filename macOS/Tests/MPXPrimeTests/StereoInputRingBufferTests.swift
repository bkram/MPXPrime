import Testing
import Foundation
import MPXPrimeCore
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

    @Test func overflowSequenceDoesNotReportTornReads() {
        // Single-producer/consumer overflow handled by the normal atomic
        // protocol must never tear a read: the consumer brackets each copy
        // with `consumerReadInProgress`, so the producer trims new input
        // rather than lapping the span being read. A true torn read needs
        // concurrent interleaving (covered by the detection helper +
        // telemetry); here we assert the happy path stays clean and the
        // tornReads telemetry is wired and reads 0.
        let ring = StereoInputRingBuffer(capacityFrames: 512)
        // Interleave heavy overflowing writes with reads several times.
        let block: [Float] = Array(0..<700).map(Float.init)
        var outLeft = [Float](repeating: 0, count: 256)
        var outRight = [Float](repeating: 0, count: 256)
        for _ in 0..<8 {
            block.withUnsafeBufferPointer { buf in
                ring.write(left: buf.baseAddress!, right: buf.baseAddress!, frameCount: block.count)
            }
            _ = outLeft.withUnsafeMutableBufferPointer { lBuf in
                outRight.withUnsafeMutableBufferPointer { rBuf in
                    ring.read(intoLeft: lBuf.baseAddress!, outRight: rBuf.baseAddress!, frameCount: 256)
                }
            }
        }

        #expect(ring.stats().overflows > 0, "expected overflow to occur in this stress pattern")
        let snapshot = ring.transportSnapshot()
        #expect(snapshot.tornReads == 0, "normal protocol must not report torn reads, got \(snapshot.tornReads)")
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

    // MARK: - Clock-drift simulation
    //
    // These three tests model the operational case where the input
    // device's clock drifts relative to the render clock — both
    // nominally the same rate (so the call site computes
    // nominalConsume == frameCount and would pick the fast path) but
    // the writer produces a slightly different number of frames per
    // render callback than the reader consumes. Without drift
    // correction, bufferedFrames grows or shrinks without bound; over
    // hours, the user observes input-to-output latency increasing
    // toward ring capacity.

    /// Drive a sustained drift loop and return final buffered depth.
    /// `writeFramesPerCallback` controls drift direction: > frameCount
    /// means input rate > render rate (latency creep up); < frameCount
    /// is the inverse. `transitionAfter` (optional) switches to exact
    /// matched-rate writes after that many callbacks.
    private static func runDriftLoop(
        ring: StereoInputRingBuffer,
        callbacks: Int,
        frameCount: Int,
        nominalConsume: Int,
        targetBuffered: Int,
        deadband: Int,
        writeFramesPerCallback: Int,
        transitionAfter: Int? = nil,
        matchedRateAfterTransition: Int = 0
    ) -> Int {
        var leftOut = [Float](repeating: 0, count: frameCount)
        var rightOut = [Float](repeating: 0, count: frameCount)
        var phase: Float = 0
        for cb in 0..<callbacks {
            let writeCount: Int
            if let cutoff = transitionAfter, cb >= cutoff {
                writeCount = matchedRateAfterTransition
            } else {
                writeCount = writeFramesPerCallback
            }
            // Push a low-amplitude sine so cubic interpolation has real
            // signal to work with (zero-fill paths short-circuit some
            // logic and would mask drift behaviour).
            if writeCount > 0 {
                var writeBuf = [Float](repeating: 0, count: writeCount)
                for i in 0..<writeCount {
                    writeBuf[i] = sin(phase) * 0.1
                    phase += 0.01
                }
                writeBuf.withUnsafeBufferPointer { ptr in
                    ring.write(left: ptr.baseAddress!, right: ptr.baseAddress!, frameCount: writeCount)
                }
            }
            _ = leftOut.withUnsafeMutableBufferPointer { l in
                rightOut.withUnsafeMutableBufferPointer { r in
                    ring.readAdaptive(
                        intoLeft: l.baseAddress!,
                        outRight: r.baseAddress!,
                        frameCount: frameCount,
                        nominalConsume: nominalConsume,
                        targetBuffered: targetBuffered,
                        deadband: deadband
                    )
                }
            }
        }
        return ring.bufferedFrames()
    }

    @Test func sustainedPositiveDriftKeepsBufferNearTarget() {
        // Writer pushes 257 frames per 256-frame render callback (~0.4%
        // drift). Without correction the ring fills monotonically until
        // capacity. With the deadband-gated fast path, the slow path
        // engages once drift exceeds the deadband and trims back toward
        // target.
        let frameCount = 256
        let target = 4096
        let deadband = 1024
        let ring = StereoInputRingBuffer(capacityFrames: 32_768)
        // Pre-fill to target so we start in steady state.
        let prefill = [Float](repeating: 0, count: target)
        prefill.withUnsafeBufferPointer { ptr in
            ring.write(left: ptr.baseAddress!, right: ptr.baseAddress!, frameCount: target)
        }
        let final = Self.runDriftLoop(
            ring: ring,
            callbacks: 5_000,
            frameCount: frameCount,
            nominalConsume: frameCount,  // ratio == 1.0 — fast path candidate
            targetBuffered: target,
            deadband: deadband,
            writeFramesPerCallback: 257
        )
        // After 5000 callbacks at +1 frame/callback drift, an
        // uncorrected fast path would have grown the ring by ~5000
        // frames (clamped at capacity 32768). Correction must keep us
        // within a few deadbands of target.
        let driftFromTarget = abs(final - target)
        #expect(driftFromTarget < deadband * 4,
            "Sustained positive drift must stay within 4×deadband of target; ended at \(final), target \(target), deadband \(deadband)")
    }

    @Test func sustainedNegativeDriftKeepsBufferNearTarget() {
        // Inverse: writer pushes 255 frames per 256-frame callback.
        // Buffer would drain toward zero without correction.
        let frameCount = 256
        let target = 4096
        let deadband = 1024
        let ring = StereoInputRingBuffer(capacityFrames: 32_768)
        let prefill = [Float](repeating: 0, count: target)
        prefill.withUnsafeBufferPointer { ptr in
            ring.write(left: ptr.baseAddress!, right: ptr.baseAddress!, frameCount: target)
        }
        let final = Self.runDriftLoop(
            ring: ring,
            callbacks: 5_000,
            frameCount: frameCount,
            nominalConsume: frameCount,
            targetBuffered: target,
            deadband: deadband,
            writeFramesPerCallback: 255
        )
        let driftFromTarget = abs(final - target)
        #expect(driftFromTarget < deadband * 4,
            "Sustained negative drift must stay within 4×deadband of target; ended at \(final), target \(target), deadband \(deadband)")
    }

    @Test func transitionFromDriftToMatchedRatePreservesTrimState() {
        // Drift for 2000 callbacks then switch to exact matched rate
        // for 2000 more. The trim state accumulated during drift must
        // not be clobbered by intermediate fast-path entries; the
        // ring depth must remain bounded throughout and converge back
        // toward target after the drift stops.
        let frameCount = 256
        let target = 4096
        let deadband = 1024
        let ring = StereoInputRingBuffer(capacityFrames: 32_768)
        let prefill = [Float](repeating: 0, count: target)
        prefill.withUnsafeBufferPointer { ptr in
            ring.write(left: ptr.baseAddress!, right: ptr.baseAddress!, frameCount: target)
        }
        let final = Self.runDriftLoop(
            ring: ring,
            callbacks: 4_000,
            frameCount: frameCount,
            nominalConsume: frameCount,
            targetBuffered: target,
            deadband: deadband,
            writeFramesPerCallback: 257,
            transitionAfter: 2_000,
            matchedRateAfterTransition: frameCount
        )
        // After drift halts, depth should converge back toward target.
        // Without the fix, the matched-rate phase has no correction
        // and depth stays ~2000 frames above target (the accumulated
        // drift). With the fix, the slow path's trim drives depth
        // back to within the deadband.
        let driftFromTarget = abs(final - target)
        #expect(driftFromTarget < deadband,
            "After drift→matched-rate transition, depth must converge to within 1×deadband of target; ended at \(final), target \(target), deadband \(deadband)")
    }
}
