import Atomics
import Foundation

// Lock-free single-producer / single-consumer stereo ring.
//
// Atomic protocol:
//   * `writeCursor` and `readCursor` are monotonic UInt64 frame counts;
//     physical slots are `cursor & mask`. The producer only advances
//     `writeCursor`; the consumer only advances `readCursor`. Each store
//     uses `.releasing`, each cross-thread load `.acquiring`, so a reader
//     that observes a new `writeCursor` also observes the frames written
//     before it.
//   * `consumerReadInProgress` is a hint, not a lock: the consumer raises
//     it around its copy so the producer prefers trimming new input over
//     advancing `readCursor` (overwriting unread frames) on overflow.
//
// Accepted race: the producer's `consumerReadInProgress` load can be stale
// relative to the consumer's store (they are separate atomics with no
// combined ordering point). In that narrow window the producer may lap the
// span the consumer is mid-copy, tearing a few frames. This is only
// reachable in the overflow fault state (the ring is already full and
// dropping input — `overflowCount` is climbing and audio is already
// compromised), so we detect and count it (`tornReadCount`) for telemetry
// rather than pay for a lock on the real-time path.
public final class StereoInputRingBuffer {
    public struct TransportSnapshot {
        public let overflows: UInt64
        public let underflows: UInt64
        public let tornReads: UInt64
        public let bufferedFrames: Int
        public let resampleMode: String
        public let ratioTrim: Double
        public let sampleStep: Double

        public init(
            overflows: UInt64, underflows: UInt64, tornReads: UInt64,
            bufferedFrames: Int, resampleMode: String, ratioTrim: Double,
            sampleStep: Double
        ) {
            self.overflows = overflows
            self.underflows = underflows
            self.tornReads = tornReads
            self.bufferedFrames = bufferedFrames
            self.resampleMode = resampleMode
            self.ratioTrim = ratioTrim
            self.sampleStep = sampleStep
        }
    }

    private let capacity: Int
    private let mask: Int
    private var left: [Float]
    private var right: [Float]
    private var lastLeft: Float = 0.0
    private var lastRight: Float = 0.0
    private var resamplePhase: Double = 0.0
    private var resampleRatioTrim: Double = 0.0
    private let readCursor = ManagedAtomic<UInt64>(0)
    private let writeCursor = ManagedAtomic<UInt64>(0)
    private let overflowCount = ManagedAtomic<UInt64>(0)
    private let underflowCount = ManagedAtomic<UInt64>(0)
    private let tornReadCount = ManagedAtomic<UInt64>(0)
    private let consumerReadInProgress = ManagedAtomic<Bool>(false)
    private let transportMode = ManagedAtomic<Int>(0)
    private let transportRatioTrimMicrounits = ManagedAtomic<Int>(0)
    private let transportSampleStepMicrounits = ManagedAtomic<Int>(1_000_000)

    public init(capacityFrames: Int) {
        let requested = max(512, capacityFrames)
        let roundedCapacity = Self.nextPowerOfTwo(requested)
        self.capacity = roundedCapacity
        self.mask = roundedCapacity - 1
        self.left = Array(repeating: 0.0, count: roundedCapacity)
        self.right = Array(repeating: 0.0, count: roundedCapacity)
    }

    public func write(
        left inLeft: UnsafePointer<Float>, right inRight: UnsafePointer<Float>, frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let plan = planWrite(frameCount: frameCount)
        guard plan.framesToWrite > 0 else { return }
        copyStereoIntoRing(
            left: inLeft.advanced(by: plan.sourceOffset),
            right: inRight.advanced(by: plan.sourceOffset),
            frameCount: plan.framesToWrite,
            startCursor: plan.startCursor
        )
        writeCursor.store(
            plan.startCursor &+ UInt64(plan.framesToWrite),
            ordering: .releasing
        )
    }

    public func writeMono(mono inMono: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let plan = planWrite(frameCount: frameCount)
        guard plan.framesToWrite > 0 else { return }
        copyMonoIntoRing(
            mono: inMono.advanced(by: plan.sourceOffset),
            frameCount: plan.framesToWrite,
            startCursor: plan.startCursor
        )
        writeCursor.store(
            plan.startCursor &+ UInt64(plan.framesToWrite),
            ordering: .releasing
        )
    }

    public func read(
        intoLeft outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Int {
        guard frameCount > 0 else { return 0 }
        consumerReadInProgress.store(true, ordering: .releasing)
        defer { consumerReadInProgress.store(false, ordering: .releasing) }

        let snapshot = makeReadableSnapshot(frameCount: frameCount)
        if snapshot.available > 0 {
            copyRingFrames(
                startCursor: snapshot.startCursor,
                frameCount: snapshot.available,
                intoLeft: outLeft,
                outRight: outRight
            )
            lastLeft = outLeft[snapshot.available - 1]
            lastRight = outRight[snapshot.available - 1]
        }

        let missing = frameCount - snapshot.available
        if missing > 0 {
            fillMissingFrames(
                intoLeft: outLeft,
                outRight: outRight,
                start: snapshot.available,
                frameCount: frameCount,
                repeatLast: false
            )
            if snapshot.available == 0 {
                lastLeft = 0.0
                lastRight = 0.0
            }
            underflowCount.wrappingIncrement(by: UInt64(missing), ordering: .relaxed)
        }

        if snapshot.available > 0 {
            noteTornReadIfLapped(startCursor: snapshot.startCursor)
        }
        readCursor.store(
            snapshot.startCursor &+ UInt64(snapshot.available),
            ordering: .releasing
        )
        return missing
    }

    public func readAdaptive(
        intoLeft outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>,
        frameCount: Int,
        nominalConsume: Int,
        targetBuffered: Int,
        deadband: Int
    ) -> Int {
        guard frameCount > 0 else { return 0 }
        consumerReadInProgress.store(true, ordering: .releasing)
        defer { consumerReadInProgress.store(false, ordering: .releasing) }

        let read = readCursor.load(ordering: .acquiring)
        let write = writeCursor.load(ordering: .acquiring)
        let startCursor = readableStartCursor(read: read, write: write)
        let available = max(0, Int(write &- startCursor))

        if available <= 0 {
            fillMissingFrames(
                intoLeft: outLeft,
                outRight: outRight,
                start: 0,
                frameCount: frameCount,
                repeatLast: false
            )
            lastLeft = 0.0
            lastRight = 0.0
            resamplePhase = 0.0
            resampleRatioTrim = 0.0
            updateTransportState(mode: 0, ratioTrim: 0.0, sampleStep: 1.0)
            underflowCount.wrappingIncrement(by: UInt64(frameCount), ordering: .relaxed)
            readCursor.store(startCursor, ordering: .releasing)
            return frameCount
        }

        let nominal = max(1, nominalConsume)
        // Fast path: nominal sample rates match (1:1 read) AND the
        // ring is within deadband of target. The deadband guard is
        // load-bearing — without it, hardware-clock drift between two
        // nominally-same-rate devices (input 192 kHz vs render 192
        // kHz, say 50 ppm apart) accumulates as monotonic ring fill
        // creep over hours. With the guard, drift > deadband falls
        // through to the slow path's trim logic, which interpolates
        // step ∈ [0.994, 1.006] to drive depth back toward target.
        // resampleRatioTrim is intentionally NOT reset here so trim
        // state survives transient slow→fast→slow path transitions.
        let targetForGuard = max(1, targetBuffered)
        let deadbandForGuard = max(0, deadband)
        let driftFromTarget = abs(available - targetForGuard)
        if nominal == frameCount && driftFromTarget <= deadbandForGuard {
            let availableFrames = min(frameCount, available)
            if availableFrames > 0 {
                copyRingFrames(
                    startCursor: startCursor,
                    frameCount: availableFrames,
                    intoLeft: outLeft,
                    outRight: outRight
                )
                lastLeft = outLeft[availableFrames - 1]
                lastRight = outRight[availableFrames - 1]
            }

            let missing = frameCount - availableFrames
            if missing > 0 {
                fillMissingFrames(
                    intoLeft: outLeft,
                    outRight: outRight,
                    start: availableFrames,
                    frameCount: frameCount,
                    repeatLast: true
                )
                if availableFrames == 0 {
                    lastLeft = 0.0
                    lastRight = 0.0
                }
                underflowCount.wrappingIncrement(by: UInt64(missing), ordering: .relaxed)
            }

            resamplePhase = 0.0
            updateTransportState(mode: 1, ratioTrim: resampleRatioTrim, sampleStep: 1.0)
            if availableFrames > 0 {
                noteTornReadIfLapped(startCursor: startCursor)
            }
            readCursor.store(
                startCursor &+ UInt64(availableFrames),
                ordering: .releasing
            )
            return missing
        }

        let target = max(1, targetBuffered)
        let deadbandFrames = max(0, deadband)
        let errorFrames = Double(available - target)
        let trimTarget: Double
        if abs(errorFrames) <= Double(deadbandFrames) {
            trimTarget = 0.0
        } else {
            let normalized = errorFrames / Double(target)
            trimTarget = max(-0.006, min(0.006, normalized * 0.018))
        }
        resampleRatioTrim += (trimTarget - resampleRatioTrim) * 0.010

        let nominalRatio = Double(nominal) / Double(max(1, frameCount))
        let step = max(0.25, min(4.0, nominalRatio * (1.0 + resampleRatioTrim)))
        updateTransportState(mode: 2, ratioTrim: resampleRatioTrim, sampleStep: step)
        let startPhase = resamplePhase
        let phaseEnd = startPhase + (step * Double(frameCount))
        let neededFrames = min(available, max(1, Int(ceil(phaseEnd)) + 1))

        let consumed = min(available, Int(phaseEnd))
        let missing = renderInterpolatedFrames(
            intoLeft: outLeft,
            outRight: outRight,
            frameCount: frameCount,
            startIndex: physicalIndex(for: startCursor),
            neededFrames: neededFrames,
            startPhase: startPhase,
            step: step
        )

        if consumed >= available {
            resamplePhase = 0.0
        } else {
            resamplePhase = phaseEnd - Double(consumed)
            if resamplePhase > Double(capacity) / 2 {
                resamplePhase = Double(capacity) / 4
            }
        }
        if missing > 0 {
            underflowCount.wrappingIncrement(by: UInt64(missing), ordering: .relaxed)
        }

        if consumed > 0 {
            noteTornReadIfLapped(startCursor: startCursor)
        }
        readCursor.store(
            startCursor &+ UInt64(consumed),
            ordering: .releasing
        )
        return missing
    }

    public func bufferedFrames() -> Int {
        let read = readCursor.load(ordering: .acquiring)
        let write = writeCursor.load(ordering: .acquiring)
        return min(capacity, max(0, Int(write &- read)))
    }

    /// Snap the read cursor so the ring holds exactly `targetFrames`
    /// of buffered content (clamped to what's actually available).
    /// Used when switching the engine source from tone → input live —
    /// the input tap kept filling the ring while tone was active, so
    /// without this drain the ring would be at full capacity (red
    /// state) the moment the input render path starts pulling. After
    /// the drain the ring is at its prime depth and reads continue
    /// normally.
    public func dropToTargetBufferedFrames(_ targetFrames: Int) {
        let target = max(0, targetFrames)
        let read = readCursor.load(ordering: .acquiring)
        let write = writeCursor.load(ordering: .acquiring)
        let buffered = min(capacity, max(0, Int(write &- read)))
        guard buffered > target else { return }
        let toAdvance = UInt64(buffered - target)
        readCursor.store(read &+ toAdvance, ordering: .releasing)
    }

    public func stats() -> (overflows: UInt64, underflows: UInt64, bufferedFrames: Int) {
        let over = overflowCount.load(ordering: .relaxed)
        let under = underflowCount.load(ordering: .relaxed)
        let buffered = bufferedFrames()
        return (over, under, buffered)
    }

    public func transportSnapshot() -> TransportSnapshot {
        TransportSnapshot(
            overflows: overflowCount.load(ordering: .relaxed),
            underflows: underflowCount.load(ordering: .relaxed),
            tornReads: tornReadCount.load(ordering: .relaxed),
            bufferedFrames: bufferedFrames(),
            resampleMode: transportModeName(raw: transportMode.load(ordering: .relaxed)),
            ratioTrim: Double(transportRatioTrimMicrounits.load(ordering: .relaxed)) / 1_000_000.0,
            sampleStep: Double(transportSampleStepMicrounits.load(ordering: .relaxed)) / 1_000_000.0
        )
    }

    private func planWrite(frameCount: Int) -> (startCursor: UInt64, sourceOffset: Int, framesToWrite: Int) {
        let write = writeCursor.load(ordering: .acquiring)
        let read = readCursor.load(ordering: .acquiring)
        let unread = write &- read
        let buffered = min(capacity, max(0, Int(unread)))

        var sourceOffset = 0
        var framesToWrite = frameCount
        var dropped: Int = 0

        if framesToWrite > capacity {
            let trim = framesToWrite - capacity
            sourceOffset += trim
            framesToWrite = capacity
            dropped += trim
        }

        if consumerReadInProgress.load(ordering: .acquiring) {
            let free = max(0, capacity - buffered)
            if framesToWrite > free {
                let trim = framesToWrite - free
                sourceOffset += trim
                framesToWrite = free
                dropped += trim
            }
        } else if buffered + framesToWrite > capacity {
            let overflow = (buffered + framesToWrite) - capacity
            readCursor.store(read &+ UInt64(overflow), ordering: .releasing)
            dropped += overflow
        }

        if dropped > 0 {
            overflowCount.wrappingIncrement(by: UInt64(dropped), ordering: .relaxed)
        }
        return (write, sourceOffset, framesToWrite)
    }

    private func makeReadableSnapshot(frameCount: Int) -> (startCursor: UInt64, available: Int) {
        let read = readCursor.load(ordering: .acquiring)
        let write = writeCursor.load(ordering: .acquiring)
        let startCursor = readableStartCursor(read: read, write: write)
        let available = min(frameCount, max(0, Int(write &- startCursor)))
        return (startCursor, available)
    }

    private func copyStereoIntoRing(
        left sourceLeft: UnsafePointer<Float>,
        right sourceRight: UnsafePointer<Float>,
        frameCount: Int,
        startCursor: UInt64
    ) {
        guard frameCount > 0 else { return }
        var remaining = frameCount
        var sourceOffset = 0
        var writeIndex = physicalIndex(for: startCursor)
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            left.withUnsafeMutableBufferPointer { dstLeft in
                right.withUnsafeMutableBufferPointer { dstRight in
                    // baseAddress is non-nil for the pre-allocated ring storage.
                    // swiftlint:disable force_unwrapping
                    dstLeft.baseAddress!.advanced(by: writeIndex).update(
                        from: sourceLeft.advanced(by: sourceOffset),
                        count: chunk
                    )
                    dstRight.baseAddress!.advanced(by: writeIndex).update(
                        from: sourceRight.advanced(by: sourceOffset),
                        count: chunk
                    )
                    // swiftlint:enable force_unwrapping
                }
            }
            writeIndex = (writeIndex + chunk) & mask
            sourceOffset += chunk
            remaining -= chunk
        }
    }

    private func copyMonoIntoRing(
        mono sourceMono: UnsafePointer<Float>,
        frameCount: Int,
        startCursor: UInt64
    ) {
        guard frameCount > 0 else { return }
        var remaining = frameCount
        var sourceOffset = 0
        var writeIndex = physicalIndex(for: startCursor)
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            left.withUnsafeMutableBufferPointer { dstLeft in
                right.withUnsafeMutableBufferPointer { dstRight in
                    // baseAddress is non-nil for the pre-allocated ring storage.
                    // swiftlint:disable force_unwrapping
                    let outLeft = dstLeft.baseAddress!.advanced(by: writeIndex)
                    let outRight = dstRight.baseAddress!.advanced(by: writeIndex)
                    // swiftlint:enable force_unwrapping
                    for i in 0..<chunk {
                        let sample = sourceMono[sourceOffset + i]
                        outLeft[i] = sample
                        outRight[i] = sample
                    }
                }
            }
            writeIndex = (writeIndex + chunk) & mask
            sourceOffset += chunk
            remaining -= chunk
        }
    }

    private func copyRingFrames(
        startCursor: UInt64,
        frameCount: Int,
        intoLeft outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>
    ) {
        guard frameCount > 0 else { return }
        var remaining = frameCount
        var sourceIndex = physicalIndex(for: startCursor)
        var destinationOffset = 0
        while remaining > 0 {
            let chunk = min(remaining, capacity - sourceIndex)
            left.withUnsafeBufferPointer { srcLeft in
                right.withUnsafeBufferPointer { srcRight in
                    // baseAddress is non-nil for the pre-allocated ring storage.
                    // swiftlint:disable force_unwrapping
                    outLeft.advanced(by: destinationOffset).update(
                        from: srcLeft.baseAddress!.advanced(by: sourceIndex),
                        count: chunk
                    )
                    outRight.advanced(by: destinationOffset).update(
                        from: srcRight.baseAddress!.advanced(by: sourceIndex),
                        count: chunk
                    )
                    // swiftlint:enable force_unwrapping
                }
            }
            sourceIndex = (sourceIndex + chunk) & mask
            destinationOffset += chunk
            remaining -= chunk
        }
    }

    private func renderInterpolatedFrames(
        intoLeft outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>,
        frameCount: Int,
        startIndex: Int,
        neededFrames: Int,
        startPhase: Double,
        step: Double
    ) -> Int {
        var localPhase = startPhase
        var missing = 0
        var finalLeft = lastLeft
        var finalRight = lastRight
        for i in 0..<frameCount {
            let base = Int(localPhase)
            if base >= neededFrames {
                outLeft[i] = 0.0
                outRight[i] = 0.0
                missing += 1
            } else {
                let fraction = Float(localPhase - Double(base))
                let leftValue = interpolatedSample(
                    samples: left,
                    startIndex: startIndex,
                    baseIndex: base,
                    fraction: fraction,
                    validCount: neededFrames
                )
                let rightValue = interpolatedSample(
                    samples: right,
                    startIndex: startIndex,
                    baseIndex: base,
                    fraction: fraction,
                    validCount: neededFrames
                )
                outLeft[i] = leftValue
                outRight[i] = rightValue
                finalLeft = leftValue
                finalRight = rightValue
            }
            localPhase += step
        }
        lastLeft = finalLeft
        lastRight = finalRight
        return missing
    }

    private func fillMissingFrames(
        intoLeft outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>,
        start: Int,
        frameCount: Int,
        repeatLast: Bool
    ) {
        guard start < frameCount else { return }
        let fillLeft = repeatLast ? lastLeft : 0.0
        let fillRight = repeatLast ? lastRight : 0.0
        for index in start..<frameCount {
            outLeft[index] = fillLeft
            outRight[index] = fillRight
        }
    }

    @inline(__always)
    private func interpolatedSample(
        samples: [Float],
        startIndex: Int,
        baseIndex: Int,
        fraction: Float,
        validCount: Int
    ) -> Float {
        guard validCount > 0 else { return 0.0 }
        let p0 = ringSample(
            samples: samples,
            startIndex: startIndex,
            offset: max(0, baseIndex - 1)
        )
        let p1 = ringSample(
            samples: samples,
            startIndex: startIndex,
            offset: min(validCount - 1, baseIndex)
        )
        let p2 = ringSample(
            samples: samples,
            startIndex: startIndex,
            offset: min(validCount - 1, baseIndex + 1)
        )
        let p3 = ringSample(
            samples: samples,
            startIndex: startIndex,
            offset: min(validCount - 1, baseIndex + 2)
        )

        let a0 = (-0.5 * p0) + (1.5 * p1) - (1.5 * p2) + (0.5 * p3)
        let a1 = p0 - (2.5 * p1) + (2.0 * p2) - (0.5 * p3)
        let a2 = (-0.5 * p0) + (0.5 * p2)
        let a3 = p1
        let x = fraction
        let x2 = x * x
        let x3 = x2 * x
        return ((a0 * x3) + (a1 * x2) + (a2 * x) + a3)
    }

    @inline(__always)
    private func ringSample(samples: [Float], startIndex: Int, offset: Int) -> Float {
        samples[(startIndex + offset) & mask]
    }

    private func physicalIndex(for cursor: UInt64) -> Int {
        Int(cursor & UInt64(mask))
    }

    private func readableStartCursor(read: UInt64, write: UInt64) -> UInt64 {
        let unread = write &- read
        if unread > UInt64(capacity) {
            return write &- UInt64(capacity)
        }
        return read
    }

    /// After a copy, check whether the producer lapped the copied span.
    /// `startCursor` is where the consumer began copying; if the producer
    /// has since written more than `capacity` frames past it, the oldest
    /// copied frames were overwritten mid-read (torn). We can't prevent
    /// this without a lock, so we count it — it only happens deep in the
    /// overflow fault state and makes the fault visible in telemetry.
    @inline(__always)
    private func noteTornReadIfLapped(startCursor: UInt64) {
        let writeNow = writeCursor.load(ordering: .acquiring)
        if (writeNow &- startCursor) > UInt64(capacity) {
            tornReadCount.wrappingIncrement(by: 1, ordering: .relaxed)
        }
    }

    private func updateTransportState(mode: Int, ratioTrim: Double, sampleStep: Double) {
        transportMode.store(mode, ordering: .relaxed)
        transportRatioTrimMicrounits.store(Int((ratioTrim * 1_000_000.0).rounded()), ordering: .relaxed)
        transportSampleStepMicrounits.store(Int((sampleStep * 1_000_000.0).rounded()), ordering: .relaxed)
    }

    private func transportModeName(raw: Int) -> String {
        switch raw {
        case 1:
            return "direct"
        case 2:
            return "adaptive-cubic"
        default:
            return "idle"
        }
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value {
            result <<= 1
        }
        return result
    }
}
