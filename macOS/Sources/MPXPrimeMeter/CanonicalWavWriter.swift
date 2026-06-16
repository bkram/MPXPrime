import Foundation

// Minimal canonical WAV writer: a clean RIFF/fmt/data 24-bit PCM file with no
// padding chunks, so any FFT/analysis tool reads it (AVAudioFile inserts JUNK +
// FLLR alignment chunks that strict parsers mishandle). Header sizes are
// finalized on close(). Float input is clamped and packed to 24-bit LE signed.
final class CanonicalWavWriter {
    private let handle: FileHandle
    private let channels: Int
    private var dataBytes: UInt32 = 0
    private var scratch = [UInt8]()
    private var ok = true

    init(url: URL, sampleRate: Int, channels: Int) throws {
        self.channels = channels
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        let bits = 24
        let blockAlign = channels * bits / 8
        let byteRate = sampleRate * blockAlign
        var h = Data()
        func u32(_ v: UInt32) { h.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                                                       UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }
        func u16(_ v: UInt16) { h.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
        func tag(_ s: String) { h.append(contentsOf: Array(s.utf8)) }
        tag("RIFF"); u32(0)            // RIFF size (patched on close)
        tag("WAVE")
        tag("fmt "); u32(16)
        u16(1)                         // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bits))
        tag("data"); u32(0)            // data size (patched on close)
        try? handle.write(contentsOf: h)
    }

    /// Append `frames` of interleaved float samples (channels per frame).
    func write(_ interleaved: UnsafeBufferPointer<Float>, frames: Int) {
        guard ok, frames > 0 else { return }
        let total = frames * channels
        scratch.removeAll(keepingCapacity: true)
        scratch.reserveCapacity(total * 3)
        for i in 0..<total {
            var s = interleaved[i]
            if s > 1 { s = 1 } else if s < -1 { s = -1 }
            let v = Int32(s * 8_388_607.0)
            scratch.append(UInt8(truncatingIfNeeded: v))
            scratch.append(UInt8(truncatingIfNeeded: v >> 8))
            scratch.append(UInt8(truncatingIfNeeded: v >> 16))
        }
        do {
            try handle.write(contentsOf: Data(scratch))
            dataBytes += UInt32(total * 3)
        } catch {
            if ok { FileHandle.standardError.write(Data("WARNING: WAV write failed: \(error)\n".utf8)) }
            ok = false
        }
    }

    /// Patch the RIFF + data sizes and close. Idempotent.
    func close() {
        func patch(_ offset: UInt64, _ v: UInt32) {
            try? handle.seek(toOffset: offset)
            try? handle.write(contentsOf: Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                                                UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]))
        }
        patch(4, 36 + dataBytes)   // RIFF chunk size
        patch(40, dataBytes)        // data chunk size
        try? handle.close()
    }
}
