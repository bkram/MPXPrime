import Foundation
import Testing

@testable import MPXPrime
@testable import MPXPrimeRecording

/// Headless coverage for the --verify-program-ab building blocks: the
/// pumping detector on synthesized envelopes, the crest/envelope helpers,
/// and the audio-file decode path round-tripped through the repo's own
/// CanonicalWavWriter (no repo-checked-in audio, no devices).
@Suite("Program A/B metrics")
struct ProgramABMetricsTests {

    @Test func pumpingDetectorFlagsBeatRateModulation() {
        // B/A envelope ratio wobbling +/-2 dB at 2 Hz, traced at 100 Hz:
        // the index reads the peak-to-peak-equivalent swing (~4 dB).
        let traceRate = 100.0
        let n = 3_000
        var envA = [Float](repeating: -20.0, count: n)
        var envB = [Float](repeating: -20.0, count: n)
        for i in 0..<n {
            let t = Double(i) / traceRate
            envB[i] = -20.0 + Float(2.0 * sin(2.0 * Double.pi * 2.0 * t))
        }
        let index = programABPumpingDB(envA: envA, envB: envB)
        #expect(index > 3.0 && index < 5.0, "pumping index \(index) for a 4 dB p-p 2 Hz wobble")
        // And zero when the chains track each other exactly.
        envB = envA
        envA[0] = -20.0
        #expect(programABPumpingDB(envA: envA, envB: envB) < 0.05)
    }

    @Test func pumpingDetectorAlignsOutChainGroupDelay() {
        // envB = envA delayed by one 10 ms hop (the leveler chain's extra
        // group delay). Without alignment every beat edge would read as
        // beat-rate ratio wiggle; aligned, the index must stay near zero.
        let traceRate = 100.0
        let n = 3_000
        var envA = [Float](repeating: -40.0, count: n)
        for i in 0..<n {
            let t = Double(i) / traceRate
            // Kick-style envelope at 2 Hz: sharp 100 ms bumps to -15 dB.
            if t.truncatingRemainder(dividingBy: 0.5) < 0.1 { envA[i] = -15.0 }
        }
        var envB = envA
        envB.removeLast()
        envB.insert(-40.0, at: 0)
        let index = programABPumpingDB(envA: envA, envB: envB)
        #expect(index < 0.3, "pure chain delay misread as pumping: \(index) dB")
    }

    @Test func pumpingDetectorIgnoresSlowLoudnessDrift() {
        // A one-way 3 dB drift over 30 s is leveling, not pumping.
        let n = 3_000
        let envA = [Float](repeating: -20.0, count: n)
        var envB = [Float](repeating: -20.0, count: n)
        for i in 0..<n {
            envB[i] = -20.0 + 3.0 * Float(i) / Float(n)
        }
        let index = programABPumpingDB(envA: envA, envB: envB)
        #expect(index < 0.5, "slow drift misread as pumping: \(index) dB")
    }

    @Test func crestAndEnvelopeHelpersReadKnownSignals() {
        let sampleRate = 48_000.0
        var sine = [Float](repeating: 0.0, count: 48_000)
        for i in 0..<sine.count {
            sine[i] = 0.5 * sinf(2.0 * Float.pi * 997.0 * Float(i) / Float(sampleRate))
        }
        // Sine crest = 3.01 dB (p99.9 of |x| sits at the peak).
        let crest = programCrestDB(sine)
        #expect(abs(crest - 3.01) < 0.3, "sine crest read \(crest) dB")
        // Envelope of a -6 dBFS-amplitude sine: 10*log10(0.5^2/2) = -9.03 dB.
        let env = programEnvelopeDB(sine, sampleRate: sampleRate, hopSeconds: 0.010)
        #expect(env.count == 100)
        #expect(abs((env[50]) - (-9.03)) < 0.2, "envelope read \(env[50]) dB")
    }

    #if canImport(AVFoundation)
    @Test func decodeRoundTripsACanonicalWav() throws {
        // Write a known 2 s stereo program with the repo's own 24-bit WAV
        // writer, then decode it through the program-AB loader at 192 kHz.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("program-ab-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")

        let sourceRate = 48_000
        let frames = 2 * sourceRate
        let writer = try CanonicalWavWriter(url: url, sampleRate: sourceRate, channels: 2)
        var interleaved = [Float](repeating: 0.0, count: frames * 2)
        for i in 0..<frames {
            let t = Float(i) / Float(sourceRate)
            interleaved[2 * i] = 0.5 * sinf(2.0 * Float.pi * 1_000.0 * t)
            interleaved[(2 * i) + 1] = 0.25 * sinf(2.0 * Float.pi * 3_000.0 * t)
        }
        interleaved.withUnsafeBufferPointer { writer.write($0, frames: frames) }
        writer.close()
        #expect(writer.failureReason == nil)

        let decoded = try #require(
            decodeProgramFile(url: url, targetRate: 192_000.0, excerptSeconds: 1.5))
        // ~1.5 s at 192 kHz (the converter may trim a priming tail).
        #expect(abs(Double(decoded.left.count) - 1.5 * 192_000.0) < 0.05 * 192_000.0)
        func rms(_ x: [Float]) -> Float {
            var s: Double = 0
            for v in x { s += Double(v * v) }
            return Float(sqrt(s / Double(x.count)))
        }
        // Levels survive decode + SRC: 0.5 sine -> 0.354 RMS, 0.25 -> 0.177.
        #expect(abs(rms(decoded.left) - 0.3536) < 0.01)
        #expect(abs(rms(decoded.right) - 0.1768) < 0.01)

        // Excerpt capping: asking for more than the file returns the file.
        let full = try #require(
            decodeProgramFile(url: url, targetRate: 192_000.0, excerptSeconds: 600.0))
        #expect(abs(Double(full.left.count) - 2.0 * 192_000.0) < 0.05 * 192_000.0)
    }
    #endif
}
