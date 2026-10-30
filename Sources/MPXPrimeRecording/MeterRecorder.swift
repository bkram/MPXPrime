import Foundation

/// Writes captured audio to a canonical 24-bit PCM WAV (via CanonicalWavWriter,
/// so any FFT/analysis tool reads it). Fed from the meter's analysis thread,
/// block by block. Two modes, both at the capture sample rate:
///   - stereo (channels = 2): the decoded L/R audio
///   - mono (channels = 1): the raw MPX composite
///
/// Both are written at the capture rate with no real-time sample-rate
/// conversion. An earlier build resampled the stereo file to 48 kHz on the
/// analysis thread; the `.max` SRC plus its per-block allocations intermittently
/// stalled that thread (which also drains the real-time-fed input ring) long
/// enough for the ring to overflow and drop samples -- audible as periodic
/// clicks. Writing at the native rate removes the SRC entirely; resample the
/// file afterwards with any tool if a 48 kHz copy is wanted.
///
/// Disk work still runs on a private serial queue so a filesystem flush never
/// stalls capture: `write`/`writeMono` copy the block and hand it off.
///
/// Failure contract (0.45): `failureReason` is non-nil once writing has
/// stopped for any reason -- disk error, the RIFF 4 GiB limit, or a
/// channel-count misuse. The engine polls it so the UI can stop the recording
/// and say why instead of silently discarding blocks; the file on disk stays
/// readable (the writer patches its header periodically and finalizes at the
/// limit).
///
/// `@unchecked Sendable`: the interleave scratch is touched only on `ioQueue`.
public final class MeterRecorder: @unchecked Sendable {
    public let channels: Int
    private let writer: CanonicalWavWriter
    private let ioQueue = DispatchQueue(label: "com.mpxprime.meter.recorder", qos: .utility)
    private var interleave: [Float] = []   // touched only on ioQueue

    public convenience init(url: URL, sampleRate: Double, channels: Int) throws {
        try self.init(url: url, sampleRate: sampleRate, channels: channels,
                      headerPatchEveryBytes: 2_097_152,
                      maxDataBytes: CanonicalWavWriter.riffDataLimit)
    }

    /// Internal designated init with test hooks for the header-patch interval
    /// and the size limit.
    init(url: URL, sampleRate: Double, channels: Int,
         headerPatchEveryBytes: UInt64, maxDataBytes: UInt64) throws {
        self.channels = channels
        writer = try CanonicalWavWriter(
            url: url, sampleRate: Int(sampleRate.rounded()), channels: channels,
            headerPatchEveryBytes: headerPatchEveryBytes, maxDataBytes: maxDataBytes)
    }

    deinit { finish() }

    /// Non-nil once writing has stopped (disk error, size limit, misuse).
    /// Poll from the UI; the reason is operator-readable.
    public var failureReason: String? { writer.failureReason }

    /// Flush queued writes and finalize the header. Idempotent.
    public func finish() {
        ioQueue.sync {}
        writer.close()
    }

    /// Wait for queued writes and header patches to reach the file without
    /// closing it. Test hook.
    func drainForTesting() {
        ioQueue.sync {}
        writer.drainForTesting()
    }

    /// Stereo write (decoded L/R) at the capture rate.
    /// Copies the block on the caller; interleave + pack + disk run on `ioQueue`.
    public func write(left: [Float], right: [Float], count: Int) {
        guard count > 0 else { return }
        guard channels == 2 else {
            writer.reportMisuse("stereo write on a \(channels)-channel recorder")
            return
        }
        let l = Array(left[0..<count])
        let r = Array(right[0..<count])
        ioQueue.async { [self] in
            if interleave.count < count * 2 { interleave = [Float](repeating: 0, count: count * 2) }
            for i in 0..<count { interleave[i * 2] = l[i]; interleave[i * 2 + 1] = r[i] }
            interleave.withUnsafeBufferPointer { writer.write($0, frames: count) }
        }
    }

    /// Mono write (MPX composite) at the capture rate.
    public func writeMono(_ samples: [Float], count: Int) {
        guard count > 0 else { return }
        guard channels == 1 else {
            writer.reportMisuse("mono write on a \(channels)-channel recorder")
            return
        }
        let s = Array(samples[0..<count])
        ioQueue.async { [self] in
            s.withUnsafeBufferPointer { writer.write($0, frames: s.count) }
        }
    }
}
