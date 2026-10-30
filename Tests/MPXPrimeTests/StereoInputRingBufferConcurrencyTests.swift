import Testing
import Foundation
import MPXPrimeCore
@testable import MPXPrime

// The lock-free input ring on TWO threads (test-suite review 2026-10
// finding 12). Every other ring test is single-threaded, where a torn read or
// a memory-ordering bug cannot happen, so `tornReads == 0` could not fail.
//
// The producer writes a counter (left = n, right = n + 0.5, exact in Float
// up to 2^23); the consumer reads on its own thread. With back-pressure (no
// overflow) the concatenated reads must be EXACTLY 0, 1, 2, ...: a cursor
// published before its samples (a release/acquire bug) hands the consumer
// stale slots from one lap earlier, and a broken L/R copy shows as a pair
// mismatch. With overflow, gaps are allowed but every read must still be
// increasing and pair-consistent -- unless the ring itself counted that read
// as torn, which is what the torn-read telemetry is for.
//
// The overflow test found a real race on 2026-10-16 (about 1 run in 4 at
// load average 15): the producer's overflow trim stored a `readCursor`
// computed from a stale load and moved it BACK past frames the consumer had
// just read, so the next read repeated up to 32 of them. The ring now trims
// with a forward-only compare-exchange; `RobustnessRingInterleavingTests`
// forces that interleaving deterministically, and the torn-read paths.
@Suite("StereoInputRingBuffer, two threads")
struct StereoInputRingBufferConcurrencyTests {

    /// Hands the ring to the producer thread on purpose (single producer,
    /// single consumer: exactly the ring's contract).
    private final class RingHandOff: @unchecked Sendable {
        let ring: StereoInputRingBuffer
        init(_ ring: StereoInputRingBuffer) { self.ring = ring }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Producer thread: writes `total` frames in `block`-frame chunks,
    /// waiting while more than `maxBuffered` frames are queued when
    /// `backPressure` is on.
    private func startProducer(ring: StereoInputRingBuffer, total: Int, block: Int,
                               backPressure: Bool, maxBuffered: Int, done: Flag, stop: Flag = Flag()) {
        // The hand-off to the producer thread is the point of the test (Linux
        // Foundation's Thread closure is @Sendable and rejects capturing the
        // non-Sendable ring directly).
        let ringBox = RingHandOff(ring)
        let thread = Thread {
            let ring = ringBox.ring
            var left = [Float](repeating: 0, count: block)
            var right = [Float](repeating: 0, count: block)
            var next = 0
            while next < total, !stop.isSet {
                if backPressure {
                    // Give up when the consumer has stopped (a failed check),
                    // or the back-pressure wait would hang the test.
                    while ring.bufferedFrames() > maxBuffered, !stop.isSet { sched_yield() }
                }
                let n = min(block, total - next)
                for i in 0..<n {
                    left[i] = Float(next + i)
                    right[i] = Float(next + i) + 0.5
                }
                left.withUnsafeBufferPointer { l in
                    right.withUnsafeBufferPointer { r in
                        // swiftlint:disable:next force_unwrapping
                        ring.write(left: l.baseAddress!, right: r.baseAddress!, frameCount: n)
                    }
                }
                next += n
            }
            done.set()
        }
        thread.start()
    }

    @Test func backPressuredStreamArrivesExactlyInOrder() {
        let total = 1 << 21          // 2M frames, exact in Float
        let ring = StereoInputRingBuffer(capacityFrames: 4096)
        let producerDone = Flag()
        let stopProducer = Flag()
        startProducer(ring: ring, total: total, block: 256, backPressure: true,
                      maxBuffered: 2048, done: producerDone, stop: stopProducer)

        var outL = [Float](repeating: 0, count: 200)
        var outR = [Float](repeating: 0, count: 200)
        var expected = 0
        var firstError: String?
        let deadline = Date().addingTimeInterval(60)
        while expected < total, firstError == nil, Date() < deadline {
            let missing = outL.withUnsafeMutableBufferPointer { l in
                outR.withUnsafeMutableBufferPointer { r in
                    // swiftlint:disable:next force_unwrapping
                    ring.read(intoLeft: l.baseAddress!, outRight: r.baseAddress!, frameCount: 200)
                }
            }
            let valid = 200 - missing
            for i in 0..<valid {
                if outL[i] != Float(expected) || outR[i] != Float(expected) + 0.5 {
                    firstError = "frame \(expected): read L \(outL[i]) R \(outR[i])"
                    break
                }
                expected += 1
            }
            if valid == 0 { sched_yield() }
        }
        stopProducer.set()
        while !producerDone.isSet { sched_yield() }
        #expect(firstError == nil, "two-thread stream out of order: \(firstError ?? "")")
        #expect(expected == total, "consumer received \(expected) of \(total) frames")
        #expect(ring.stats().overflows == 0, "back-pressure fixture overflowed: \(ring.stats().overflows)")
        #expect(ring.transportSnapshot().tornReads == 0)
    }

    @Test func overflowingStreamIsOrderedUnlessCountedAsTorn() {
        let total = 1 << 21
        let ring = StereoInputRingBuffer(capacityFrames: 512)
        let producerDone = Flag()
        startProducer(ring: ring, total: total, block: 480, backPressure: false,
                      maxBuffered: 0, done: producerDone)

        var outL = [Float](repeating: 0, count: 256)
        var outR = [Float](repeating: 0, count: 256)
        var uncountedFaults = 0
        var faultExample = ""
        var reads = 0
        var lastValue: Float = -1
        while !producerDone.isSet || ring.bufferedFrames() > 0 {
            let tornBefore = ring.transportSnapshot().tornReads
            let missing = outL.withUnsafeMutableBufferPointer { l in
                outR.withUnsafeMutableBufferPointer { r in
                    // swiftlint:disable:next force_unwrapping
                    ring.read(intoLeft: l.baseAddress!, outRight: r.baseAddress!, frameCount: 256)
                }
            }
            let tornAfter = ring.transportSnapshot().tornReads
            reads += 1
            let valid = 256 - missing
            // A read the ring counted as torn carries no promise at all --
            // its frames can come from the next lap -- so it is neither
            // checked nor used as the reference for the next read. The
            // contract for every other read: increasing (gaps allowed:
            // overflow drops frames), above the last frame of the previous
            // untorn read (a frame is never delivered twice), and the pair
            // written together. Using a torn read's last frame as the
            // reference asserted more than that: a fully lapped torn read
            // ends ABOVE frames the next correct read still delivers.
            guard tornAfter == tornBefore else { continue }
            var consistent = true
            var previous = lastValue
            for i in 0..<valid {
                if outL[i] <= previous || outR[i] != outL[i] + 0.5 { consistent = false; break }
                previous = outL[i]
            }
            if !consistent {
                uncountedFaults += 1
                if faultExample.isEmpty {
                    faultExample = "read \(reads) after frame \(lastValue): \(Array(outL[0..<min(valid, 8)]))"
                }
            }
            // Resynchronise on whatever arrived last, so one fault is
            // counted once.
            if valid > 0 { lastValue = outL[valid - 1] }
        }
        #expect(ring.stats().overflows > 0, "fixture problem: the producer never overflowed the ring")
        #expect(uncountedFaults == 0,
                "\(uncountedFaults) reads returned out-of-order or mismatched frames that the torn-read counter did not count, e.g. \(faultExample)")
    }
}
