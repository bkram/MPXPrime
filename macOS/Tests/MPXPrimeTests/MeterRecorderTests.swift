import Foundation
import Testing

@testable import MPXPrimeRecording

// Regression tests for the MPX Prime Meter recorder. The bug these guard against
// was periodic clicks in recordings: dropped/discontinuous samples in the saved
// WAV. The recorder now writes at the capture rate (no real-time resampling) on
// a background queue, so a clean, continuous input must come back out of the
// file byte-for-byte (within 24-bit quantization) with no gaps, drops, or
// reordering -- a click would show up as a value mismatch or a frame-count
// mismatch. Device-free and deterministic: a synthetic signal, no audio I/O.
@Suite struct MeterRecorderTests {

    /// Decode a canonical 24-bit PCM WAV into per-channel float arrays.
    private func readWav(_ url: URL) throws -> (rate: Int, channels: Int, frames: Int, ch: [[Float]]) {
        let d = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1])<<8 | Int(d[o+2])<<16 | Int(d[o+3])<<24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1])<<8 }
        #expect(Array(d[0..<4]) == Array("RIFF".utf8))
        #expect(Array(d[8..<12]) == Array("WAVE".utf8))
        // Canonical writer: fmt at 12 (16-byte body), data at 36. No padding chunks.
        #expect(Array(d[12..<16]) == Array("fmt ".utf8))
        let channels = u16(22)
        let rate = u32(24)
        let bits = u16(34)
        #expect(bits == 24)
        #expect(Array(d[36..<40]) == Array("data".utf8))
        let dataBytes = u32(40)
        let dataStart = 44
        #expect(dataStart + dataBytes <= d.count)
        let bytesPerFrame = channels * 3
        let frames = dataBytes / bytesPerFrame
        var ch = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        for f in 0..<frames {
            for c in 0..<channels {
                let o = dataStart + (f * channels + c) * 3
                var v = Int(d[o]) | Int(d[o+1])<<8 | Int(d[o+2])<<16
                if v & 0x800000 != 0 { v -= 0x1000000 }
                ch[c][f] = Float(v) / 8_388_608.0
            }
        }
        return (rate, channels, frames, ch)
    }

    /// Stereo: a continuous sine fed in irregular block sizes (mirroring the
    /// analysis thread, where the input ring occasionally yields short blocks)
    /// must come back contiguous and sample-accurate -- no clicks, no drops.
    @Test func stereoRecordingIsContiguousAndComplete() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpxprime-rectest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let rate = 192_000.0
        let rec = try MeterRecorder(url: url, sampleRate: rate, channels: 2)

        var expL = [Float](); var expR = [Float]()
        var phase = 0.0
        let dphi = 2.0 * Double.pi * 1000.0 / rate   // continuous 1 kHz tone
        let blocks = [8192, 8192, 500, 8192, 777, 8192, 256, 3333, 8192, 8192]
        for blk in blocks {
            var l = [Float](repeating: 0, count: blk)
            var r = [Float](repeating: 0, count: blk)
            for i in 0..<blk {
                let s = Float(0.5 * sin(phase))
                l[i] = s; r[i] = -s
                expL.append(s); expR.append(-s)
                phase += dphi
            }
            rec.write(left: l, right: r, count: blk)
        }
        rec.finish()

        let (sr, channels, frames, ch) = try readWav(url)
        #expect(sr == 192_000)
        #expect(channels == 2)
        // No samples dropped or duplicated: every fed frame is present.
        #expect(frames == expL.count)

        var maxErr: Float = 0
        for i in 0..<min(frames, expL.count) {
            maxErr = max(maxErr, abs(ch[0][i] - expL[i]), abs(ch[1][i] - expR[i]))
        }
        // 24-bit quantization is ~1.2e-7; a click/drop would be orders larger.
        #expect(maxErr < 1e-5)
    }

    /// Mono (raw MPX) path: same contiguity guarantee at the capture rate.
    @Test func monoRecordingIsContiguousAndComplete() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpxprime-rectest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let rate = 192_000.0
        let rec = try MeterRecorder(url: url, sampleRate: rate, channels: 1)

        var exp = [Float]()
        var phase = 0.0
        let dphi = 2.0 * Double.pi * 5000.0 / rate
        for blk in [8192, 8192, 333, 8192, 8192] {
            var m = [Float](repeating: 0, count: blk)
            for i in 0..<blk { let s = Float(0.7 * sin(phase)); m[i] = s; exp.append(s); phase += dphi }
            rec.writeMono(m, count: blk)
        }
        rec.finish()

        let (sr, channels, frames, ch) = try readWav(url)
        #expect(sr == 192_000)
        #expect(channels == 1)
        #expect(frames == exp.count)
        var maxErr: Float = 0
        for i in 0..<min(frames, exp.count) { maxErr = max(maxErr, abs(ch[0][i] - exp[i])) }
        #expect(maxErr < 1e-5)
    }

    /// Samples beyond +/-1.0 must clamp (not wrap) so a hot decode can't produce
    /// full-scale wrap-around clicks.
    @Test func writerClampsOutOfRangeSamples() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpxprime-rectest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let rec = try MeterRecorder(url: url, sampleRate: 48_000.0, channels: 1)
        let over: [Float] = [2.0, -2.0, 1.5, -1.5, 0.0]
        rec.writeMono(over, count: over.count)
        rec.finish()

        let (_, _, frames, ch) = try readWav(url)
        #expect(frames == over.count)
        for v in ch[0] { #expect(v <= 1.0 && v >= -1.0) }
        #expect(ch[0][0] > 0.99)    // +2.0 clamped to ~+1.0
        #expect(ch[0][1] < -0.99)   // -2.0 clamped to ~-1.0
    }
}
