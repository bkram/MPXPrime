import Foundation

// Minimal canonical WAV writer: a clean RIFF/fmt/data 24-bit PCM file with no
// padding chunks, so any FFT/analysis tool reads it (AVAudioFile inserts JUNK +
// FLLR alignment chunks that strict parsers mishandle). Float input is clamped
// and packed to 24-bit LE signed.
//
// Disk writes run on a private serial queue, NOT the caller's thread. The
// recorder is driven from the meter's analysis thread, which also drains the
// real-time-fed input ring; a synchronous file write there can stall long
// enough (a filesystem flush) for the ring to overflow and drop samples -- which
// shows up as periodic clicks in the recording. Packing is cheap and stays on
// the caller; only the blocking write is handed off.
//
// Robustness contract (0.45, Meter audit P0):
//  - Non-finite samples never crash: NaN packs as 0, +/-Inf clamps (the old
//    code fed NaN into `Int32(_:)`, which traps -- an SDR overload while
//    recording looked like a random app crash).
//  - The byte counter is 64-bit and the writer STOPS CLEANLY at the RIFF
//    4 GiB boundary (~62 min of 24-bit stereo at 192 kHz) instead of
//    overflow-trapping; the file is finalized at a whole-frame boundary and
//    `failureReason` says why.
//  - The RIFF/data sizes are patched periodically during recording, so a
//    crash / SIGKILL / power loss loses seconds, not the whole capture (the
//    old header stayed zero until close() and strict parsers read the file
//    as empty).
//  - A failed write (disk full, volume gone) is remembered in
//    `failureReason` for the UI to surface; subsequent writes are dropped.
//
// `@unchecked Sendable`: all mutable state (handle, dataBytes, failure,
// closed) is touched only on `ioQueue` (a serial queue) after the synchronous
// header write in init, so the cross-thread hand-off is safe.
final class CanonicalWavWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let channels: Int
    private let blockAlign: Int
    private let headerPatchEveryBytes: UInt64
    private let maxDataBytes: UInt64
    private let ioQueue = DispatchQueue(label: "com.mpxprime.meter.wavwrite", qos: .utility)
    // Touched only on ioQueue.
    private var dataBytes: UInt64 = 0
    private var lastPatchedAt: UInt64 = 0
    private var failure: String?
    private var closed = false

    /// The largest data chunk a classic RIFF file can carry (header excluded).
    static let riffDataLimit: UInt64 = UInt64(UInt32.max) - 44

    init(
        url: URL,
        sampleRate: Int,
        channels: Int,
        headerPatchEveryBytes: UInt64 = 2_097_152,   // ~1.8 s of 24-bit stereo at 192 kHz
        maxDataBytes: UInt64 = CanonicalWavWriter.riffDataLimit
    ) throws {
        self.channels = channels
        let bits = 24
        blockAlign = channels * bits / 8
        self.headerPatchEveryBytes = max(UInt64(blockAlign), headerPatchEveryBytes)
        // Frame-align the limit so the finalized file never ends mid-frame.
        let capped = min(maxDataBytes, Self.riffDataLimit)
        self.maxDataBytes = capped - (capped % UInt64(blockAlign))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        let byteRate = sampleRate * blockAlign
        var h = Data()
        func u32(_ v: UInt32) { h.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                                                       UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }
        func u16(_ v: UInt16) { h.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
        func tag(_ s: String) { h.append(contentsOf: Array(s.utf8)) }
        tag("RIFF"); u32(0)            // RIFF size (patched periodically + on close)
        tag("WAVE")
        tag("fmt "); u32(16)
        u16(1)                         // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bits))
        tag("data"); u32(0)            // data size (patched periodically + on close)
        try handle.write(contentsOf: h)
    }

    /// Why writing stopped, if it did (disk error, size limit, misuse).
    /// Nil while healthy. Safe from any thread.
    var failureReason: String? {
        ioQueue.sync { failure }
    }

    /// Record a caller-level misuse (e.g. a channel-count mismatch) so the UI
    /// can surface it the same way as a disk failure.
    func reportMisuse(_ reason: String) {
        ioQueue.async { [self] in
            if failure == nil { failure = reason }
        }
    }

    /// Append `frames` of interleaved float samples (channels per frame). Packs
    /// to 24-bit LE on the caller, then writes to disk asynchronously so the
    /// caller (analysis thread) never blocks on I/O.
    func write(_ interleaved: UnsafeBufferPointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let total = frames * channels
        var bytes = [UInt8]()
        bytes.reserveCapacity(total * 3)
        for i in 0..<total {
            let raw = interleaved[i]
            // Clamp order matters: +/-Inf satisfy the comparisons and clamp;
            // NaN fails both and the isFinite check, packing as silence. The
            // old code let NaN reach Int32(_:), which traps at runtime.
            let s: Float
            if raw > 1.0 {
                s = 1.0
            } else if raw < -1.0 {
                s = -1.0
            } else if raw.isFinite {
                s = raw
            } else {
                s = 0.0
            }
            let v = Int32(s * 8_388_607.0)
            bytes.append(UInt8(truncatingIfNeeded: v))
            bytes.append(UInt8(truncatingIfNeeded: v >> 8))
            bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        }
        let data = Data(bytes)
        ioQueue.async { [self] in
            guard failure == nil, !closed else { return }
            var payload = data
            var hitLimit = false
            let remaining = maxDataBytes - dataBytes
            if UInt64(payload.count) > remaining {
                // Frame-aligned truncation (remaining is aligned by
                // construction), then stop accepting: finalize what we have.
                payload = payload.prefix(Int(remaining))
                hitLimit = true
            }
            do {
                if !payload.isEmpty {
                    try handle.write(contentsOf: payload)
                    dataBytes += UInt64(payload.count)
                }
            } catch {
                let reason = "WAV write failed: \(error.localizedDescription)"
                failure = reason
                FileHandle.standardError.write(Data("WARNING: \(reason)\n".utf8))
                return
            }
            if hitLimit {
                failure = "reached the 4 GB WAV size limit -- file finalized; start a new recording"
                patchSizes()
                return
            }
            if dataBytes - lastPatchedAt >= headerPatchEveryBytes {
                patchSizes()
                // Return the handle to the end of the data chunk for the next
                // append.
                try? handle.seek(toOffset: 44 + dataBytes)
            }
        }
    }

    /// Patch the RIFF + data chunk sizes to the current data length. Called on
    /// ioQueue only.
    private func patchSizes() {
        func patch(_ offset: UInt64, _ v: UInt32) {
            try? handle.seek(toOffset: offset)
            try? handle.write(contentsOf: Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                                                UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]))
        }
        let size = UInt32(min(dataBytes, Self.riffDataLimit))
        patch(4, 36 + size)    // RIFF chunk size
        patch(40, size)        // data chunk size
        lastPatchedAt = dataBytes
    }

    /// Wait for every queued write to reach the file and the header to be
    /// current. Test hook; safe from any thread.
    func drainForTesting() {
        ioQueue.sync {
            patchSizes()
            // Leave the handle at the end of the data chunk so later appends
            // do not overwrite from the header position.
            try? handle.seek(toOffset: 44 + dataBytes)
        }
    }

    /// Flush pending writes, patch the RIFF + data sizes, and close. Idempotent.
    func close() {
        ioQueue.sync {
            guard !closed else { return }
            closed = true
            patchSizes()
            try? handle.close()
        }
    }
}
