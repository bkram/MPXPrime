import Atomics
import Foundation

// Lock-free single-producer / single-consumer stereo ring.
//
// Atomic protocol:
//   * `writeCursor` and `readCursor` are monotonic UInt64 frame counts;
//     physical slots are `cursor & mask`. Only the producer advances
//     `writeCursor`. Each store uses `.releasing`, each cross-thread load
//     `.acquiring`, so a reader that observes a new `writeCursor` also
//     observes the frames written before it.
//   * `readCursor` has TWO writers: the consumer after every read, and the
//     producer on overflow, when it trims the oldest unread frames to make
//     room. The producer's trim is a compare-exchange that only ever moves
//     the cursor FORWARD. It used to be a plain store of a value computed
//     from a `readCursor` loaded earlier in the same write; when the
//     consumer read in between, that store moved the cursor BACK and the
//     next read handed out up to `capacity - block` frames a second time
//     (reproduced 2026-10-16 under load: a read starting 32 frames before
//     the previous read's last frame, 512-frame ring, 480-frame writes,
//     not counted as torn -- the frames were intact, just repeated). The
//     consumer's own store may still move the cursor back over a producer
//     trim made during its copy; that is harmless, because its next read
//     clamps the start to `writeCursor - capacity` and every frame from
//     there on is either intact or caught by the torn-read check below.
//   * `consumerReadInProgress` is a hint, not a lock: the consumer raises
//     it around its copy so the producer prefers trimming new input over
//     advancing `readCursor` (overwriting unread frames) on overflow.
//   * `writeClaim` is the torn-read sequence: the producer stores the END
//     cursor of a write, then a release fence, BEFORE it touches a slot;
//     the consumer, after its copy, takes an acquire fence and loads it.
//     If the claim is more than `capacity` past the first frame the
//     consumer copied, a slot it copied may have been overwritten during
//     the copy (seqlock style). Checking the published `writeCursor`
//     instead missed a write still in progress: its slots are overwritten
//     before its cursor is published.
//
// Accepted race: the producer's `consumerReadInProgress` load can be stale
// relative to the consumer's store (they are separate atomics with no
// combined ordering point). In that narrow window the producer may lap the
// span the consumer is mid-copy, tearing a few frames. This is only
// reachable in the overflow fault state (the ring is already full and
// dropping input -- `overflowCount` is climbing and audio is already
// compromised), so we detect and count it (`tornReadCount`) for telemetry
// rather than pay for a lock on the real-time path. The count may include
// a read that was not actually torn (the claim is taken before the copy
// reaches the slot), never miss one that was.
//
// The sample storage is raw memory allocated once in `init`, not `[Float]`:
// a Swift array written through `withUnsafeMutableBufferPointer` from one
// thread while another holds it is a copy-on-write uniqueness check, a
// possible reallocation on the real-time thread, and a race on the array
// reference itself.
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
    private let ringLeft: UnsafeMutablePointer<Float>
    private let ringRight: UnsafeMutablePointer<Float>
    private var lastLeft: Float = 0.0
    private var lastRight: Float = 0.0
    // Band-limited resampling state (consumer thread only). The adaptive
    // read interpolates with a 32-tap Kaiser-windowed sinc, which needs
    // `interpolatorHistory` frames BEFORE the current read position. Those
    // frames are already consumed from the ring, so the consumer keeps its
    // own copy of the last ones it took -- on every path, so a direct read
    // followed by a resampling read is still continuous. `window*` is the
    // preallocated linear scratch one block is interpolated from:
    // [history | ring frames | held last frame].
    // Until the first frame arrives (and again after the ring ran dry) the
    // history is unknown, and it is filled with that first frame rather than
    // silence: a stream that starts on a DC offset must not ring.
    private var historyLeft: [Float]
    private var historyRight: [Float]
    private var historyPrimed = false
    private var windowLeft: [Float]
    private var windowRight: [Float]
    private let kernel: [Float]
    private let kernelSlope: [Float]
    private var resamplePhase: Double = 0.0
    private var resampleRatioTrim: Double = 0.0
    private let readCursor = ManagedAtomic<UInt64>(0)
    private let writeCursor = ManagedAtomic<UInt64>(0)
    /// End cursor of the write in progress (or the last one); see the
    /// protocol notes at the top of the file.
    private let writeClaim = ManagedAtomic<UInt64>(0)
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
        self.ringLeft = UnsafeMutablePointer<Float>.allocate(capacity: roundedCapacity)
        self.ringLeft.initialize(repeating: 0.0, count: roundedCapacity)
        self.ringRight = UnsafeMutablePointer<Float>.allocate(capacity: roundedCapacity)
        self.ringRight.initialize(repeating: 0.0, count: roundedCapacity)
        self.historyLeft = Array(repeating: 0.0, count: Self.interpolatorHistory)
        self.historyRight = Array(repeating: 0.0, count: Self.interpolatorHistory)
        let windowCount = roundedCapacity + Self.interpolatorTaps + 1
        self.windowLeft = Array(repeating: 0.0, count: windowCount)
        self.windowRight = Array(repeating: 0.0, count: windowCount)
        // Touch the shared tables here, off the real-time thread: a Swift
        // `static let` initialises lazily on first use.
        self.kernel = Self.interpolatorKernel.taps
        self.kernelSlope = Self.interpolatorKernel.slopes
    }

    deinit {
        ringLeft.deallocate()
        ringRight.deallocate()
    }

    // MARK: - Test seam (test-suite review finding 12)

    /// Where `testHook` runs. Each point sits between two steps of the
    /// protocol whose interleaving with the other thread matters, so a test
    /// can force that interleaving instead of hoping a stress run hits it.
    enum TestHookPoint {
        /// Consumer: cursors snapshotted, nothing copied yet.
        case consumerAfterSnapshot
        /// Producer: cursors loaded in `planWrite`, nothing decided yet.
        case producerAfterCursorLoad
        /// Producer: claim stored and samples written, cursor not published.
        case producerBeforePublish
    }

    #if DEBUG
    /// Internal, debug builds only: called at each `TestHookPoint`, on the
    /// thread that reaches it. Release builds compile the calls out
    /// entirely, so the real-time path pays nothing.
    var testHook: ((TestHookPoint) -> Void)?
    /// Debug builds only: the producer behaves as if its
    /// `consumerReadInProgress` load were stale (the accepted race), so a
    /// test can drive the overflow path into a read in progress.
    var testProducerIgnoresReadInProgress = false
    #endif

    @inline(__always)
    private func testPoint(_ point: TestHookPoint) {
        #if DEBUG
        testHook?(point)
        #endif
    }

    @inline(__always)
    private var producerSeesReadInProgress: Bool {
        #if DEBUG
        if testProducerIgnoresReadInProgress { return false }
        #endif
        return consumerReadInProgress.load(ordering: .acquiring)
    }

    // MARK: - Band-limited interpolator

    /// Taps of the fractional-delay interpolator: 15 before the base frame,
    /// the base frame, 16 after it.
    static let interpolatorTaps = 32
    static let interpolatorHistory = 15
    /// Frames needed from the base frame onward (the base frame + 16).
    static let interpolatorLookahead = interpolatorTaps - interpolatorHistory
    /// Fractions tabulated; the kernel is linearly blended between rows.
    static let interpolatorPhases = 256
    static let interpolatorKaiserBeta = 7.0

    /// Kaiser-windowed sinc (beta 7, 32 taps), tabulated at 257 fractions
    /// with the row-to-row slope for linear blending. Measured (model and
    /// `EncoderInputRingTests`): the interpolation error is about -86 dBc
    /// at 0.31 fs (15 kHz at 48 kHz, 57 kHz at 192 kHz) and -80 dBc at
    /// 0.42 fs, at every fraction; the blend between rows adds about
    /// -110 dBc. At fraction 0 the kernel is an exact unit impulse, so an
    /// integer position reads the stored sample bit for bit.
    ///
    /// It replaced a 4-point Catmull-Rom cubic (2026-10), which drooped
    /// -1.23 dB at 15 kHz on the 48 -> 192 kHz input read, filtered the
    /// composite's 38 kHz subcarrier differently from the pilot as the
    /// fraction swept, and clamped its outer neighbours at every block edge
    /// (-45 dBc products at the block rate).
    private static let interpolatorKernel: (taps: [Float], slopes: [Float]) = {
        let taps = interpolatorTaps
        let phases = interpolatorPhases
        let half = Double(interpolatorTaps / 2)
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0
            var term = 1.0
            var k = 1.0
            while term > 1e-17 * sum {
                term *= (x / (2.0 * k)) * (x / (2.0 * k))
                sum += term
                k += 1.0
            }
            return sum
        }
        let beta = interpolatorKaiserBeta
        let normaliser = besselI0(beta)
        var rows = [Double](repeating: 0.0, count: (phases + 1) * taps)
        for row in 0...phases {
            let fraction = Double(row) / Double(phases)
            for k in 0..<taps {
                // Tap k sits at frame offset (k - history) from the base frame.
                let x = Double(k - interpolatorHistory) - fraction
                let sinc: Double
                if x == 0.0 {
                    sinc = 1.0
                } else if fraction == 0.0 || fraction == 1.0 {
                    sinc = 0.0  // exact zeros at the other integer positions
                } else {
                    sinc = sin(Double.pi * x) / (Double.pi * x)
                }
                let t = x / half
                let window = besselI0(beta * (max(0.0, 1.0 - t * t)).squareRoot()) / normaliser
                rows[row * taps + k] = sinc * window
            }
        }
        var tapsOut = [Float](repeating: 0.0, count: (phases + 1) * taps)
        var slopes = [Float](repeating: 0.0, count: phases * taps)
        for i in 0..<tapsOut.count { tapsOut[i] = Float(rows[i]) }
        for row in 0..<phases {
            for k in 0..<taps {
                slopes[row * taps + k] = Float(rows[(row + 1) * taps + k] - rows[row * taps + k])
            }
        }
        return (tapsOut, slopes)
    }()

    /// Keep the last `interpolatorHistory` frames the consumer took, after a
    /// read that delivered `count` input frames unchanged in `outLeft` /
    /// `outRight` (the direct paths).
    private func rememberHistory(
        left newLeft: UnsafePointer<Float>, right newRight: UnsafePointer<Float>, count: Int
    ) {
        guard count > 0 else { return }
        let history = Self.interpolatorHistory
        primeHistoryIfNeeded(left: newLeft[0], right: newRight[0])
        historyLeft.withUnsafeMutableBufferPointer { hl in
            historyRight.withUnsafeMutableBufferPointer { hr in
                if count >= history {
                    for i in 0..<history {
                        hl[i] = newLeft[count - history + i]
                        hr[i] = newRight[count - history + i]
                    }
                } else {
                    for i in 0..<(history - count) {
                        hl[i] = hl[i + count]
                        hr[i] = hr[i + count]
                    }
                    for i in 0..<count {
                        hl[history - count + i] = newLeft[i]
                        hr[history - count + i] = newRight[i]
                    }
                }
            }
        }
    }

    /// The ring ran dry: whatever comes next starts a new stream.
    private func clearHistory() {
        historyPrimed = false
    }

    private func primeHistoryIfNeeded(left firstLeft: Float, right firstRight: Float) {
        guard !historyPrimed else { return }
        for i in 0..<Self.interpolatorHistory {
            historyLeft[i] = firstLeft
            historyRight[i] = firstRight
        }
        historyPrimed = true
    }

    public func write(
        left inLeft: UnsafePointer<Float>, right inRight: UnsafePointer<Float>, frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let plan = planWrite(frameCount: frameCount)
        guard plan.framesToWrite > 0 else { return }
        claimWrite(endCursor: plan.startCursor &+ UInt64(plan.framesToWrite))
        copyStereoIntoRing(
            left: inLeft.advanced(by: plan.sourceOffset),
            right: inRight.advanced(by: plan.sourceOffset),
            frameCount: plan.framesToWrite,
            startCursor: plan.startCursor
        )
        testPoint(.producerBeforePublish)
        writeCursor.store(
            plan.startCursor &+ UInt64(plan.framesToWrite),
            ordering: .releasing
        )
    }

    public func writeMono(mono inMono: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let plan = planWrite(frameCount: frameCount)
        guard plan.framesToWrite > 0 else { return }
        claimWrite(endCursor: plan.startCursor &+ UInt64(plan.framesToWrite))
        copyMonoIntoRing(
            mono: inMono.advanced(by: plan.sourceOffset),
            frameCount: plan.framesToWrite,
            startCursor: plan.startCursor
        )
        testPoint(.producerBeforePublish)
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
        testPoint(.consumerAfterSnapshot)
        if snapshot.available > 0 {
            copyRingFrames(
                startCursor: snapshot.startCursor,
                frameCount: snapshot.available,
                intoLeft: outLeft,
                outRight: outRight
            )
            lastLeft = outLeft[snapshot.available - 1]
            lastRight = outRight[snapshot.available - 1]
            rememberHistory(left: outLeft, right: outRight, count: snapshot.available)
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
                clearHistory()
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
        testPoint(.consumerAfterSnapshot)

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
            clearHistory()
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
        // load-bearing -- without it, hardware-clock drift between two
        // nominally-same-rate devices (input 192 kHz vs render 192
        // kHz, say 50 ppm apart) accumulates as monotonic ring fill
        // creep over hours. With the guard, drift > deadband falls
        // through to the slow path's trim logic, which interpolates
        // step in [0.994, 1.006] to drive depth back toward target.
        // resampleRatioTrim is intentionally NOT reset here so trim
        // state survives transient slow->fast->slow path transitions.
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
                rememberHistory(left: outLeft, right: outRight, count: availableFrames)
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
                    clearHistory()
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
        // The last output's base frame is at most Int(phaseEnd); its kernel
        // reaches `interpolatorLookahead - 1` frames past it. Fetch them all
        // so no tap is clamped at the block edge (only a nearly empty ring
        // falls short, and then the last frame is held).
        let neededFrames = min(available, max(1, Int(phaseEnd) + Self.interpolatorLookahead))

        let consumed = min(available, Int(phaseEnd))
        let missing = renderInterpolatedFrames(
            intoLeft: outLeft,
            outRight: outRight,
            frameCount: frameCount,
            startCursor: startCursor,
            neededFrames: neededFrames,
            consumed: consumed,
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

    /// Frames the ring can hold (rounded up to a power of two at init). Lets a
    /// non-realtime producer apply back-pressure against the fill instead of
    /// silently overwriting unread samples.
    public var capacityFrames: Int { capacity }

    public func bufferedFrames() -> Int {
        let read = readCursor.load(ordering: .acquiring)
        let write = writeCursor.load(ordering: .acquiring)
        return min(capacity, max(0, Int(write &- read)))
    }

    /// Snap the read cursor so the ring holds exactly `targetFrames`
    /// of buffered content (clamped to what's actually available).
    /// Used when switching the engine source from tone -> input live --
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
        testPoint(.producerAfterCursorLoad)

        var sourceOffset = 0
        var framesToWrite = frameCount
        var dropped: Int = 0

        if framesToWrite > capacity {
            let trim = framesToWrite - capacity
            sourceOffset += trim
            framesToWrite = capacity
            dropped += trim
        }

        if producerSeesReadInProgress {
            let free = max(0, capacity - buffered)
            if framesToWrite > free {
                let trim = framesToWrite - free
                sourceOffset += trim
                framesToWrite = free
                dropped += trim
            }
        } else if buffered + framesToWrite > capacity {
            let overflow = (buffered + framesToWrite) - capacity
            dropped += advanceReadCursor(loaded: read, to: read &+ UInt64(overflow))
        }

        if dropped > 0 {
            overflowCount.wrappingIncrement(by: UInt64(dropped), ordering: .relaxed)
        }
        return (write, sourceOffset, framesToWrite)
    }

    /// Producer overflow trim: move `readCursor` forward to `wanted`, never
    /// back. `loaded` is the value `planWrite` read; the consumer may have
    /// advanced the cursor since, past `wanted` even, and then nothing is
    /// dropped. Returns the frames actually dropped. See the protocol notes
    /// at the top of the file for the plain store this replaced.
    private func advanceReadCursor(loaded: UInt64, to wanted: UInt64) -> Int {
        var expected = loaded
        while true {
            let ahead = Int64(bitPattern: wanted &- expected)
            if ahead <= 0 { return 0 }
            let (exchanged, original) = readCursor.compareExchange(
                expected: expected, desired: wanted, ordering: .acquiringAndReleasing)
            if exchanged { return Int(ahead) }
            expected = original
        }
    }

    /// Producer: announce the end of the write about to start, BEFORE any
    /// slot is touched (the fence keeps the sample stores after it).
    @inline(__always)
    private func claimWrite(endCursor: UInt64) {
        writeClaim.store(endCursor, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
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
            ringLeft.advanced(by: writeIndex).update(
                from: sourceLeft.advanced(by: sourceOffset), count: chunk)
            ringRight.advanced(by: writeIndex).update(
                from: sourceRight.advanced(by: sourceOffset), count: chunk)
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
            let outLeft = ringLeft.advanced(by: writeIndex)
            let outRight = ringRight.advanced(by: writeIndex)
            for i in 0..<chunk {
                let sample = sourceMono[sourceOffset + i]
                outLeft[i] = sample
                outRight[i] = sample
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
            outLeft.advanced(by: destinationOffset).update(
                from: ringLeft.advanced(by: sourceIndex), count: chunk)
            outRight.advanced(by: destinationOffset).update(
                from: ringRight.advanced(by: sourceIndex), count: chunk)
            sourceIndex = (sourceIndex + chunk) & mask
            destinationOffset += chunk
            remaining -= chunk
        }
    }

    /// Band-limited read of one block. Builds the linear window
    /// [history | `neededFrames` ring frames | last frame held], interpolates
    /// every output from it with the windowed-sinc kernel, then keeps the
    /// `interpolatorHistory` frames ending just before the new read position
    /// (`consumed` frames on) as the next block's history.
    private func renderInterpolatedFrames(
        intoLeft outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>,
        frameCount: Int,
        startCursor: UInt64,
        neededFrames: Int,
        consumed: Int,
        startPhase: Double,
        step: Double
    ) -> Int {
        let history = Self.interpolatorHistory
        let taps = Self.interpolatorTaps
        let phases = Float(Self.interpolatorPhases)
        let ringStart = physicalIndex(for: startCursor)
        var missing = 0
        var finalLeft = lastLeft
        var finalRight = lastRight
        primeHistoryIfNeeded(left: ringLeft[ringStart], right: ringRight[ringStart])
        let ringL = ringLeft
        let ringR = ringRight
        windowLeft.withUnsafeMutableBufferPointer { wl in
        windowRight.withUnsafeMutableBufferPointer { wr in
        historyLeft.withUnsafeMutableBufferPointer { hl in
        historyRight.withUnsafeMutableBufferPointer { hr in
        kernel.withUnsafeBufferPointer { kernelRows in
        kernelSlope.withUnsafeBufferPointer { slopeRows in
            // swiftlint:disable force_unwrapping
            let winL = wl.baseAddress!
            let winR = wr.baseAddress!
            let rows = kernelRows.baseAddress!
            let slopes = slopeRows.baseAddress!
            // swiftlint:enable force_unwrapping
            for i in 0..<history {
                winL[i] = hl[i]
                winR[i] = hr[i]
            }
            for i in 0..<neededFrames {
                let index = (ringStart + i) & mask
                winL[history + i] = ringL[index]
                winR[history + i] = ringR[index]
            }
            let heldL = winL[history + neededFrames - 1]
            let heldR = winR[history + neededFrames - 1]
            for i in 0..<Self.interpolatorLookahead {
                winL[history + neededFrames + i] = heldL
                winR[history + neededFrames + i] = heldR
            }

            var localPhase = startPhase
            for i in 0..<frameCount {
                let base = Int(localPhase)
                if base >= neededFrames {
                    outLeft[i] = 0.0
                    outRight[i] = 0.0
                    missing += 1
                } else {
                    let rowPosition = Float(localPhase - Double(base)) * phases
                    let row = min(Self.interpolatorPhases - 1, Int(rowPosition))
                    let blend = rowPosition - Float(row)
                    let a = rows + row * taps
                    let d = slopes + row * taps
                    // Window index `base` holds the frame `history` before
                    // the base frame: the kernel's first tap.
                    let xl = winL + base
                    let xr = winR + base
                    var accL0: Float = 0.0
                    var accL1: Float = 0.0
                    var accR0: Float = 0.0
                    var accR1: Float = 0.0
                    for k in 0..<taps {
                        accL0 += a[k] * xl[k]
                        accL1 += d[k] * xl[k]
                        accR0 += a[k] * xr[k]
                        accR1 += d[k] * xr[k]
                    }
                    let valueL = accL0 + blend * accL1
                    let valueR = accR0 + blend * accR1
                    outLeft[i] = valueL
                    outRight[i] = valueR
                    finalLeft = valueL
                    finalRight = valueR
                }
                localPhase += step
            }

            // Frames before the new read position become the history.
            for i in 0..<history {
                hl[i] = winL[consumed + i]
                hr[i] = winR[consumed + i]
            }
        }
        }
        }
        }
        }
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
    /// has since CLAIMED more than `capacity` frames past it -- published or
    /// still being written -- the oldest copied frames may have been
    /// overwritten mid-read (torn). Overwrites run in cursor order, so the
    /// first copied frame is the one to check. We can't prevent this
    /// without a lock, so we count it -- it only happens deep in the
    /// overflow fault state and makes the fault visible in telemetry.
    @inline(__always)
    private func noteTornReadIfLapped(startCursor: UInt64) {
        // Pairs with the release fence in `claimWrite`: if the copy saw any
        // sample of a write, this load sees that write's claim.
        atomicMemoryFence(ordering: .acquiring)
        let claimed = writeClaim.load(ordering: .relaxed)
        if (claimed &- startCursor) > UInt64(capacity) {
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
            return "adaptive-sinc"
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
