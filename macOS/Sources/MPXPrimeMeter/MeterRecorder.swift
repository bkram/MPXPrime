import AVFoundation
import Foundation

/// Writes captured audio to a WAV file. Fed from the analysis thread (one
/// writer), block by block, at the composite sample rate -- a faithful,
/// high-quality 24-bit PCM capture. Two modes:
///   - stereo (channels = 2): the decoded L/R audio (`write(left:right:)`)
///   - mono (channels = 1): the raw MPX composite (`writeMono(_:count:)`)
final class MeterRecorder: @unchecked Sendable {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    let channels: Int
    private var warned = false

    init(url: URL, sampleRate: Double, channels: Int, maxBlock: Int = 16384) throws {
        self.channels = channels
        // 24-bit signed PCM (broadly compatible, high quality). Buffers are
        // provided as deinterleaved float32 (our native format); AVAudioFile
        // converts on write.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels)),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(maxBlock)) else {
            throw NSError(domain: "MeterRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not allocate write buffer"])
        }
        buffer = buf
    }

    /// Stereo write (decoded L/R). No-op unless the file is 2-channel.
    func write(left: [Float], right: [Float], count: Int) {
        guard channels == 2, count > 0, count <= Int(buffer.frameCapacity),
              let ch = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        left.withUnsafeBufferPointer { lp in
            if let base = lp.baseAddress { ch[0].update(from: base, count: count) }
        }
        right.withUnsafeBufferPointer { rp in
            if let base = rp.baseAddress { ch[1].update(from: base, count: count) }
        }
        flush()
    }

    /// Mono write (MPX composite). No-op unless the file is 1-channel.
    func writeMono(_ samples: [Float], count: Int) {
        guard channels == 1, count > 0, count <= Int(buffer.frameCapacity),
              let ch = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { sp in
            if let base = sp.baseAddress { ch[0].update(from: base, count: count) }
        }
        flush()
    }

    private func flush() {
        do {
            try file.write(from: buffer)
        } catch {
            if !warned {
                FileHandle.standardError.write(Data("WARNING: WAV write failed: \(error)\n".utf8))
                warned = true
            }
        }
    }
}
