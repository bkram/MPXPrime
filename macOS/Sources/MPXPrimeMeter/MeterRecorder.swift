import AVFoundation
import Foundation

/// Writes the decoded L/R audio to a stereo WAV file. Fed from the analysis
/// thread (one writer), block by block, at the composite sample rate -- a
/// faithful, high-quality capture of what the decoder produced (24-bit PCM).
final class MeterRecorder: @unchecked Sendable {
    private let file: AVAudioFile
    private let processingFormat: AVAudioFormat
    private let buffer: AVAudioPCMBuffer
    private var warned = false

    init(url: URL, sampleRate: Double, maxBlock: Int = 16384) throws {
        // File format: 24-bit signed PCM stereo (broadly compatible, high
        // quality). Buffers are provided as deinterleaved float32 (our native
        // sample format); AVAudioFile converts on write.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(maxBlock)) else {
            throw NSError(domain: "MeterRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not allocate write buffer"])
        }
        processingFormat = fmt
        buffer = buf
    }

    func write(left: [Float], right: [Float], count: Int) {
        guard count > 0, count <= Int(buffer.frameCapacity),
              let ch = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        left.withUnsafeBufferPointer { lp in
            if let base = lp.baseAddress { ch[0].update(from: base, count: count) }
        }
        right.withUnsafeBufferPointer { rp in
            if let base = rp.baseAddress { ch[1].update(from: base, count: count) }
        }
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
