import Foundation

// 32-bit float WAV writer for offline listening capture.
// Lives in the test target only; production code never imports this.
//
// Layout (RIFF/WAVE, format = 0x0003 IEEE float):
//   "RIFF" <riff-size> "WAVE"
//   "fmt " <16> <1*16-byte fmt block>
//   "data" <data-size> <interleaved Float32 LE samples...>

enum WAVExport {

    static func writeMono(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try writeInterleaved(samples, channels: 1, sampleRate: sampleRate, to: url)
    }

    static func writeStereo(left: [Float], right: [Float], sampleRate: Double, to url: URL) throws {
        precondition(left.count == right.count, "stereo channels must be the same length")
        var interleaved = [Float](repeating: 0.0, count: left.count * 2)
        for i in 0..<left.count {
            interleaved[2 * i] = left[i]
            interleaved[2 * i + 1] = right[i]
        }
        try writeInterleaved(interleaved, channels: 2, sampleRate: sampleRate, to: url)
    }

    private static func writeInterleaved(_ samples: [Float], channels: UInt16,
                                         sampleRate: Double, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bytesPerSample: UInt16 = 4
        let dataSize = UInt32(samples.count * Int(bytesPerSample))
        let fmtChunkSize: UInt32 = 16
        let riffSize: UInt32 = 4 + (8 + fmtChunkSize) + (8 + dataSize)

        var out = Data()
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(uint32LE: riffSize)
        out.append(contentsOf: Array("WAVE".utf8))

        out.append(contentsOf: Array("fmt ".utf8))
        out.append(uint32LE: fmtChunkSize)
        out.append(uint16LE: 3)                            // format: IEEE float
        out.append(uint16LE: channels)
        out.append(uint32LE: UInt32(sampleRate))
        out.append(uint32LE: UInt32(sampleRate) * UInt32(channels) * UInt32(bytesPerSample))
        out.append(uint16LE: channels * bytesPerSample)
        out.append(uint16LE: 32)                           // bits per sample

        out.append(contentsOf: Array("data".utf8))
        out.append(uint32LE: dataSize)
        samples.withUnsafeBufferPointer { buf in
            out.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }

        try out.write(to: url)
    }
}

private extension Data {
    mutating func append(uint16LE v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
    mutating func append(uint32LE v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
    mutating func append(_ buffer: UnsafeBufferPointer<Float>) {
        buffer.withMemoryRebound(to: UInt8.self) { byteBuf in
            self.append(byteBuf.baseAddress!, count: byteBuf.count)
        }
    }
}
