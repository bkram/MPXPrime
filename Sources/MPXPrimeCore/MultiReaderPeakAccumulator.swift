import Atomics
import Foundation

/// One consumer of the engine's meter peaks: the GUI meters, one web
/// dashboard meter stream, the headless status tick. Each reader has its own
/// "peak since my last read", so a read by one never clears another's.
/// `shared` is the anonymous reader stateless callers (a plain
/// `/api/meters` poll) use; they still steal from each other, as polls
/// without an identity must.
public struct MeterPeakReader: Hashable, Sendable {
    public let id: UInt64

    public static let shared = MeterPeakReader(id: 0)

    private static let nextID = ManagedAtomic<UInt64>(1)

    /// A fresh identity. Cheap; make one per consumer and keep it.
    public static func make() -> MeterPeakReader {
        MeterPeakReader(id: nextID.loadThenWrappingIncrement(ordering: .relaxed))
    }
}

/// Peak-since-last-read for several readers at once, fed by an audio thread.
///
/// Why it exists: both engines kept ONE pending peak per channel and the
/// read cleared it, so the GUI tick and the web meter stream (macOS), or two
/// dashboard tabs (Linux), took peaks from each other -- whichever read
/// second saw only what arrived in between. The ALSA engine also
/// OVERWROTE its published peak every period instead of holding the
/// maximum until it was read, so a reader at 20 Hz saw one 5 ms period in
/// ten.
///
/// Writer side (`record`, real-time safe): lock-free and allocation-free.
/// Every value is max-folded into each ACTIVE reader slot with a
/// compare-exchange, so nothing a reader has not taken is ever lost or
/// lowered. Non-negative finite Floats order like their bit patterns, which
/// is what lets the fold run on `UInt32`.
///
/// Reader side (`take`): a reader's slot is claimed on its first read (so a
/// reader never has to register, and an engine restart needs nothing from
/// it); the take exchanges each channel with zero, so a peak landing between
/// two reads is kept for the next one. Slot 0 belongs to `MeterPeakReader.shared`
/// and is always active. When every slot is taken, a slot idle for
/// `idleEvictionSeconds` is reused; failing that the reader falls back to
/// the shared slot (degraded, never wrong-signed).
public final class MultiReaderPeakAccumulator: @unchecked Sendable {
    /// What one `take` returns.
    public struct Take: Sendable {
        /// The slot the reader holds; index per-reader reader-side state by it.
        public let slot: Int
        /// True when the slot was (re)claimed by this read: any reader-side
        /// state kept for the slot belongs to a previous reader and must be
        /// reset.
        public let claimedNow: Bool
        /// Peak per channel since this reader's previous take (0 = none).
        public let peaks: [Float]
    }

    public let channelCount: Int
    public let slotCount: Int
    public let idleEvictionSeconds: Double

    private let values: UnsafeMutablePointer<UnsafeAtomic<UInt32>.Storage>
    private let active: UnsafeMutablePointer<UnsafeAtomic<Bool>.Storage>

    // Reader-side table (never touched by the writer).
    private let tableLock = NSLock()
    private var owners: [UInt64?]
    private var lastUsed: [Double]

    public init(channels: Int, slots: Int = 8, idleEvictionSeconds: Double = 10.0) {
        precondition(channels > 0 && slots > 0)
        channelCount = channels
        slotCount = slots
        self.idleEvictionSeconds = idleEvictionSeconds
        values = .allocate(capacity: channels * slots)
        for i in 0..<(channels * slots) {
            (values + i).initialize(to: UnsafeAtomic<UInt32>.Storage(0))
        }
        active = .allocate(capacity: slots)
        for s in 0..<slots {
            (active + s).initialize(to: UnsafeAtomic<Bool>.Storage(s == 0))
        }
        owners = Array(repeating: nil, count: slots)
        owners[0] = MeterPeakReader.shared.id
        lastUsed = Array(repeating: 0, count: slots)
    }

    deinit {
        for i in 0..<(channelCount * slotCount) {
            _ = (values + i).pointee.dispose()
        }
        values.deinitialize(count: channelCount * slotCount)
        values.deallocate()
        for s in 0..<slotCount {
            _ = (active + s).pointee.dispose()
        }
        active.deinitialize(count: slotCount)
        active.deallocate()
    }

    @inline(__always)
    private func value(slot: Int, channel: Int) -> UnsafeAtomic<UInt32> {
        UnsafeAtomic(at: values + (slot * channelCount + channel))
    }

    @inline(__always)
    private func isActive(_ slot: Int) -> UnsafeAtomic<Bool> {
        UnsafeAtomic(at: active + slot)
    }

    /// Fold one peak (linear magnitude) into every active reader. Real-time
    /// safe. NaN, Inf, negative and zero values are ignored.
    @inline(__always)
    public func record(channel: Int, peak: Float) {
        guard channel >= 0, channel < channelCount, peak.isFinite, peak > 0 else { return }
        let bits = peak.bitPattern
        for slot in 0..<slotCount where isActive(slot).load(ordering: .relaxed) {
            let atom = value(slot: slot, channel: channel)
            var current = atom.load(ordering: .relaxed)
            while bits > current {
                let (exchanged, original) = atom.compareExchange(
                    expected: current, desired: bits, ordering: .relaxed)
                if exchanged { break }
                current = original
            }
        }
    }

    /// The reader's peaks since its previous take; clears only its own slot.
    /// `now` is any monotonic clock in seconds (used for idle eviction).
    public func take(_ reader: MeterPeakReader, now: Double) -> Take {
        tableLock.lock()
        defer { tableLock.unlock() }
        var claimedNow = false
        let slot: Int
        if let owned = owners.firstIndex(of: reader.id) {
            slot = owned
        } else if let claimed = claimSlot(now: now) {
            slot = claimed
            owners[slot] = reader.id
            claimedNow = true
        } else {
            slot = 0
        }
        lastUsed[slot] = now
        var peaks = [Float](repeating: 0, count: channelCount)
        for channel in 0..<channelCount {
            let bits = value(slot: slot, channel: channel).exchange(0, ordering: .relaxed)
            peaks[channel] = Float(bitPattern: bits)
        }
        return Take(slot: slot, claimedNow: claimedNow, peaks: peaks)
    }

    /// Give a reader's slot back (a meter stream that ended). Unknown or
    /// shared readers are ignored.
    public func release(_ reader: MeterPeakReader) {
        guard reader != .shared else { return }
        tableLock.lock()
        defer { tableLock.unlock() }
        guard let slot = owners.firstIndex(of: reader.id), slot != 0 else { return }
        deactivate(slot)
    }

    /// Clear every reader's pending peaks (engine stop). Slots stay claimed.
    public func reset() {
        for i in 0..<(channelCount * slotCount) {
            UnsafeAtomic<UInt32>(at: values + i).store(0, ordering: .relaxed)
        }
    }

    /// Caller holds `tableLock`.
    private func claimSlot(now: Double) -> Int? {
        var candidate: Int?
        for slot in 1..<max(1, slotCount) where owners[slot] == nil {
            candidate = slot
            break
        }
        if candidate == nil {
            var oldest: Double = .infinity
            for slot in 1..<max(1, slotCount)
            where now - lastUsed[slot] >= idleEvictionSeconds && lastUsed[slot] < oldest {
                oldest = lastUsed[slot]
                candidate = slot
            }
        }
        guard let slot = candidate else { return nil }
        // Clear BEFORE activating, so the new reader starts from nothing and
        // a stale value of the previous owner cannot leak into its first read.
        isActive(slot).store(false, ordering: .relaxed)
        for channel in 0..<channelCount {
            value(slot: slot, channel: channel).store(0, ordering: .relaxed)
        }
        isActive(slot).store(true, ordering: .releasing)
        return slot
    }

    /// Caller holds `tableLock`.
    private func deactivate(_ slot: Int) {
        isActive(slot).store(false, ordering: .relaxed)
        for channel in 0..<channelCount {
            value(slot: slot, channel: channel).store(0, ordering: .relaxed)
        }
        owners[slot] = nil
        lastUsed[slot] = 0
    }
}
