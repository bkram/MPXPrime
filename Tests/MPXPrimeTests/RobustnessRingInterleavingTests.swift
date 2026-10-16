#if DEBUG
import Testing
import Foundation
@testable import MPXPrimeCore

// Forced interleavings of the lock-free input ring (test-suite review
// finding 12). The two-thread stress test in
// `StereoInputRingBufferConcurrencyTests` only hits these windows by luck
// (about 1 run in 4 under heavy load); here the ring's internal `testHook`
// (debug builds only, compiled out of release) stops one side at the exact
// point where the other side's step matters, so each case runs every time.
//
// Frame n carries left = n, right = n + 0.5 throughout.
@Suite("Ring interleavings, forced")
struct RobustnessRingInterleavingTests {

    private let capacity = 512

    private func write(_ ring: StereoInputRingBuffer, from first: Int, count: Int) {
        let left = (0..<count).map { Float(first + $0) }
        let right = left.map { $0 + 0.5 }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                ring.write(left: l.baseAddress!, right: r.baseAddress!, frameCount: count)
            }
        }
    }

    private func read(_ ring: StereoInputRingBuffer, count: Int) -> (left: [Float], right: [Float], missing: Int) {
        var left = [Float](repeating: -1, count: count)
        var right = [Float](repeating: -1, count: count)
        let missing = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // swiftlint:disable:next force_unwrapping
                ring.read(intoLeft: l.baseAddress!, outRight: r.baseAddress!, frameCount: count)
            }
        }
        return (left, right, missing)
    }

    /// The race the stress test found: the producer loads `readCursor`, the
    /// consumer reads, then the producer's overflow trim stores a cursor
    /// computed from the stale load. A plain store moved the cursor BACK
    /// and the next read repeated 240 frames here; the forward-only trim
    /// leaves the consumer's position alone and drops nothing, because the
    /// consumer's read made the room.
    @Test func anOverflowTrimNeverMovesTheReadCursorBack() {
        let ring = StereoInputRingBuffer(capacityFrames: capacity)
        write(ring, from: 0, count: capacity)                  // full: 0...511

        var consumed: [Float] = []
        var fired = false
        ring.testHook = { point in
            guard point == .producerAfterCursorLoad, !fired else { return }
            fired = true
            // The consumer runs between the producer's load and its trim.
            consumed = read(ring, count: 256).left             // 0...255
        }
        write(ring, from: capacity, count: 16)                 // 512...527
        ring.testHook = nil

        #expect(fired)
        #expect(consumed.first == 0 && consumed.last == 255)
        let next = read(ring, count: 256)
        #expect(next.missing == 0)
        #expect(next.left.first == 256,
                "the read after the trim starts at frame \(next.left.first ?? -1); 256 is next, lower is a repeat")
        #expect(next.left == (256..<512).map { Float($0) })
        #expect(ring.stats().overflows == 0,
                "nothing was dropped -- the consumer made room -- but \(ring.stats().overflows) frames were counted")
    }

    /// Item 2 of the fix round: a read the producer laps between the
    /// consumer's snapshot and its copy must be COUNTED. The producer is
    /// made to miss `consumerReadInProgress` (the accepted race), so it
    /// trims the read cursor and overwrites the very slots being read.
    @Test func aReadLappedBetweenSnapshotAndCopyIsCounted() {
        let ring = StereoInputRingBuffer(capacityFrames: capacity)
        write(ring, from: 0, count: capacity)                  // full: 0...511
        #expect(ring.transportSnapshot().tornReads == 0)

        var fired = false
        ring.testHook = { point in
            guard point == .consumerAfterSnapshot, !fired else { return }
            fired = true
            ring.testProducerIgnoresReadInProgress = true
            write(ring, from: capacity, count: 256)            // overwrites slots of 0...255
            ring.testProducerIgnoresReadInProgress = false
        }
        let torn = read(ring, count: 256)
        ring.testHook = nil

        #expect(fired)
        // The fixture really tore the read: it got the NEXT lap's frames.
        #expect(torn.left.first == Float(capacity), "fixture did not lap the read: \(torn.left.first ?? -1)")
        #expect(ring.transportSnapshot().tornReads == 1)
    }

    /// The same read when the producer honours the in-progress flag: it
    /// drops its input instead, nothing is overwritten, nothing counted.
    @Test func aRespectedReadInProgressIsNotTorn() {
        let ring = StereoInputRingBuffer(capacityFrames: capacity)
        write(ring, from: 0, count: capacity)

        var fired = false
        ring.testHook = { point in
            guard point == .consumerAfterSnapshot, !fired else { return }
            fired = true
            write(ring, from: capacity, count: 256)
        }
        let result = read(ring, count: 256)
        ring.testHook = nil

        #expect(fired)
        #expect(result.left == (0..<256).map { Float($0) })
        #expect(ring.transportSnapshot().tornReads == 0)
        #expect(ring.stats().overflows == 256)
    }

    /// A write still IN PROGRESS when the consumer checks: its samples are
    /// in the slots, its cursor is not published yet. Checking the
    /// published `writeCursor` missed exactly this; the claim catches it.
    /// Needs two threads: the producer is parked inside its write while the
    /// consumer copies and checks.
    @Test func aReadTornByAnUnpublishedWriteIsCounted() {
        let ring = StereoInputRingBuffer(capacityFrames: capacity)
        write(ring, from: 0, count: capacity)                  // full: 0...511

        let startProducer = DispatchSemaphore(value: 0)
        let producerParked = DispatchSemaphore(value: 0)
        let releaseProducer = DispatchSemaphore(value: 0)
        let producerDone = DispatchSemaphore(value: 0)
        ring.testProducerIgnoresReadInProgress = true          // set before the thread starts
        ring.testHook = { point in
            switch point {
            case .consumerAfterSnapshot:
                // Consumer (this thread): snapshot taken; let the producer
                // overwrite the slots and park before it publishes.
                startProducer.signal()
                producerParked.wait()
            case .producerBeforePublish:
                producerParked.signal()
                releaseProducer.wait()
            case .producerAfterCursorLoad:
                break
            }
        }
        // The hand-off to the producer thread is the point of the test; the
        // box states that explicitly (Linux Foundation's Thread closure is
        // @Sendable and rejects capturing the non-Sendable ring directly).
        let ringBox = UncheckedRingBox(ring)
        let producer = Thread {
            startProducer.wait()
            write(ringBox.ring, from: capacity, count: 256)
            producerDone.signal()
        }
        producer.start()

        let torn = read(ring, count: 256)
        releaseProducer.signal()
        producerDone.wait()
        ring.testHook = nil

        #expect(torn.left.first == Float(capacity), "fixture did not lap the read: \(torn.left.first ?? -1)")
        #expect(ring.transportSnapshot().tornReads == 1,
                "a read overwritten by a write not yet published was not counted")
    }

    /// The sinc read path (readAdaptive, resampling) has the same check:
    /// a lapped interpolated read is counted too.
    @Test func aLappedInterpolatedReadIsCounted() {
        let ring = StereoInputRingBuffer(capacityFrames: capacity)
        write(ring, from: 0, count: capacity)

        var fired = false
        ring.testHook = { point in
            guard point == .consumerAfterSnapshot, !fired else { return }
            fired = true
            ring.testProducerIgnoresReadInProgress = true
            write(ring, from: capacity, count: 256)
            ring.testProducerIgnoresReadInProgress = false
        }
        var left = [Float](repeating: 0, count: 128)
        var right = [Float](repeating: 0, count: 128)
        _ = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // nominal 130 of 128: the resampling (sinc) path, not the direct one.
                // swiftlint:disable:next force_unwrapping
                ring.readAdaptive(intoLeft: l.baseAddress!, outRight: r.baseAddress!, frameCount: 128,
                                  nominalConsume: 130, targetBuffered: 256, deadband: 0)
            }
        }
        ring.testHook = nil
        #expect(fired)
        #expect(ring.transportSnapshot().resampleMode == "adaptive-sinc")
        #expect(ring.transportSnapshot().tornReads == 1)
    }
}

/// Hands a ring to a test thread on purpose (single producer, single
/// consumer: exactly the ring's contract).
private final class UncheckedRingBox: @unchecked Sendable {
    let ring: StereoInputRingBuffer
    init(_ ring: StereoInputRingBuffer) { self.ring = ring }
}
#endif
