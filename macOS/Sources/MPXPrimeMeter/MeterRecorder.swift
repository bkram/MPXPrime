import AVFoundation
import Foundation

/// Writes captured audio to a canonical 24-bit PCM WAV (via CanonicalWavWriter,
/// so any FFT/analysis tool reads it). Fed from the analysis thread, block by
/// block. Two modes:
///   - stereo (channels = 2): the decoded L/R audio, resampled to 48 kHz
///     (a standard high-quality stereo audio file)
///   - mono (channels = 1): the raw MPX composite at the capture rate (the
///     composite needs the full bandwidth for pilot / subcarriers / RDS)
final class MeterRecorder: @unchecked Sendable {
    let channels: Int
    private let writer: CanonicalWavWriter
    private let captureRate: Double

    // Stereo only: resample captureRate -> 48 kHz.
    private static let stereoFileRate: Double = 48_000
    private let converter: AVAudioConverter?
    private let inBuf: AVAudioPCMBuffer?
    private let outFmt: AVAudioFormat?
    private var interleave: [Float] = []
    private var convFed = false   // one-shot input flag for the converter block

    init(url: URL, sampleRate: Double, channels: Int, maxBlock: Int = 16384) throws {
        self.channels = channels
        self.captureRate = sampleRate
        if channels == 2 {
            writer = try CanonicalWavWriter(
                url: url, sampleRate: Int(Self.stereoFileRate), channels: 2)
            guard let inFmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
                  let oFmt = AVAudioFormat(standardFormatWithSampleRate: Self.stereoFileRate, channels: 2),
                  let conv = AVAudioConverter(from: inFmt, to: oFmt),
                  let ib = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(maxBlock)) else {
                throw NSError(domain: "MeterRecorder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "stereo resampler init failed"])
            }
            conv.sampleRateConverterQuality = .max
            converter = conv; inBuf = ib; outFmt = oFmt
        } else {
            writer = try CanonicalWavWriter(
                url: url, sampleRate: Int(sampleRate.rounded()), channels: 1)
            converter = nil; inBuf = nil; outFmt = nil
        }
    }

    deinit { writer.close() }

    /// Stereo write (decoded L/R), resampled to 48 kHz. No-op unless 2-channel.
    func write(left: [Float], right: [Float], count: Int) {
        guard channels == 2, count > 0, let conv = converter, let ib = inBuf,
              let oFmt = outFmt, count <= Int(ib.frameCapacity),
              let ich = ib.floatChannelData else { return }
        ib.frameLength = AVAudioFrameCount(count)
        left.withUnsafeBufferPointer { if let b = $0.baseAddress { ich[0].update(from: b, count: count) } }
        right.withUnsafeBufferPointer { if let b = $0.baseAddress { ich[1].update(from: b, count: count) } }

        let outCap = AVAudioFrameCount(Double(count) * Self.stereoFileRate / captureRate) + 32
        guard let ob = AVAudioPCMBuffer(pcmFormat: oFmt, frameCapacity: outCap) else { return }
        // Feed exactly one input buffer per convert call. The block runs
        // synchronously on this (analysis) thread; state goes through `self`
        // (the class is @unchecked Sendable) to satisfy the @Sendable block.
        convFed = false
        var err: NSError?
        let status = conv.convert(to: ob, error: &err) { [self] _, outStatus in
            if convFed { outStatus.pointee = .noDataNow; return nil }
            convFed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, let och = ob.floatChannelData else { return }
        let frames = Int(ob.frameLength)
        guard frames > 0 else { return }
        if interleave.count < frames * 2 { interleave = [Float](repeating: 0, count: frames * 2) }
        for i in 0..<frames { interleave[i * 2] = och[0][i]; interleave[i * 2 + 1] = och[1][i] }
        interleave.withUnsafeBufferPointer { writer.write($0, frames: frames) }
    }

    /// Mono write (MPX composite) at the capture rate. No-op unless 1-channel.
    func writeMono(_ samples: [Float], count: Int) {
        guard channels == 1, count > 0 else { return }
        samples.withUnsafeBufferPointer {
            guard let base = $0.baseAddress else { return }
            writer.write(UnsafeBufferPointer(start: base, count: count), frames: count)
        }
    }
}
