import Testing
import Foundation
import MPXPrimeCore
@testable import MPXPrime

// One non-finite input sample used to be permanent. NaN or Inf entering the
// chain propagates into every recursive filter and envelope detector, and
// nothing downstream can flush it: a one-pole smoother fed NaN stays NaN
// forever, and the self-heal paths cannot re-arm because their own state is
// already poisoned. The encoder then emits silence (or NaN) until the
// transport restarts. The same held for the Meter, whose DC tracker,
// measurement FIR, power accumulators and phase detectors all saw the raw
// block before the decoder's own 0.36-era guard could help.
//
// The policy both sides now implement (0.60, audit P0-4): a non-finite
// sample is silence, every finite sample passes through untouched --
// including legitimately over-range ones, which the peak stages exist to
// handle. These tests pin containment and, more importantly, RECOVERY.
@Suite("Non-finite ingress containment")
struct NonFiniteIngressTests {

    private let sampleRate: Double = 192_000.0
    private let block = 1024

    private static let poisons: [(String, Float)] = [
        ("NaN", Float.nan),
        ("+Inf", Float.infinity),
        ("-Inf", -Float.infinity),
    ]

    // MARK: - Fixtures

    /// A chain with plenty of recursive state: AGC, multiband, bass clipper,
    /// pre-emphasis, pre-encode limiter, composite clipper, final limiter.
    private func richConfig(mode: AppConfig.OperatingMode = .mpx) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = block
        cfg.operatingMode = mode
        cfg.processingBypass = false
        cfg.enRDS = false
        cfg.widebandAGCEnabled = true
        cfg.multibandEnabled = true
        cfg.bassClipperEnabled = true
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.compositeClipperEnabled = true
        cfg.limitMPX = true
        cfg.preemphasisUS = 75
        return cfg
    }

    private func programSample(_ i: Int) -> Float {
        let w = 2.0 * Double.pi * 440.0 / sampleRate
        let wLow = 2.0 * Double.pi * 90.0 / sampleRate
        return Float(0.5 * sin(w * Double(i)) + 0.3 * sin(wLow * Double(i)))
    }

    /// Render `frames` of programme, optionally replacing the samples in
    /// `poisonRange` with `poison`. Returns the composite (or processed
    /// audio) the generator produced.
    private func render(
        _ generator: MPXGenerator,
        frames: Int,
        poison: Float? = nil,
        poisonRange: Range<Int> = 0..<0,
        audioOnly: Bool = false,
        monitor: Bool = false
    ) -> [Float] {
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let v = programSample(i)
            left[i] = v
            right[i] = v * 0.8
        }
        if let poison {
            for i in poisonRange where i < frames {
                left[i] = poison
                right[i] = poison
            }
        }
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                while offset < frames {
                    let chunk = min(block, frames - offset)
                    // swiftlint:disable force_unwrapping
                    let l = lBuf.baseAddress!.advanced(by: offset)
                    let r = rBuf.baseAddress!.advanced(by: offset)
                    // swiftlint:enable force_unwrapping
                    if audioOnly {
                        generator.renderAudioOnlyFromInputInPlace(
                            frameCount: chunk, left: l, right: r)
                    } else if monitor {
                        generator.renderMonitorFromInputInPlace(
                            frameCount: chunk, left: l, right: r)
                    } else {
                        generator.renderFromInputInPlace(
                            frameCount: chunk, left: l, right: r)
                    }
                    offset += chunk
                }
            }
        }
        return left
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0.0 }
        var acc = 0.0
        for v in x { acc += Double(v) * Double(v) }
        return Float((acc / Double(x.count)).squareRoot())
    }

    // MARK: - Containment

    @Test func everyCompositeSampleStaysFiniteAfterAPoisonedInput() {
        let frames = Int(sampleRate * 0.2)
        for (name, poison) in Self.poisons {
            // First, middle and last sample of the first block: an ingress
            // guard applied per block rather than per sample would miss the
            // edges.
            for position in [0, block / 2, block - 1] {
                let gen = MPXGenerator(config: richConfig(), sampleRate: sampleRate)
                let out = render(gen, frames: frames, poison: poison,
                                 poisonRange: position..<(position + 1))
                let bad = out.firstIndex { !$0.isFinite }
                #expect(bad == nil,
                        "\(name) at frame \(position) produced a non-finite composite at frame \(bad ?? -1)")
            }
        }
    }

    @Test func theAudioOnlyAndMonitorPathsRecoverToo() {
        let frames = Int(sampleRate * 1.0)
        let tail = (frames - Int(sampleRate * 0.2))..<frames

        let cleanAudio = MPXGenerator(config: richConfig(mode: .fm), sampleRate: sampleRate)
        let audioReference = rms(render(cleanAudio, frames: frames, audioOnly: true)[tail])
        let cleanMon = MPXGenerator(config: richConfig(), sampleRate: sampleRate)
        let monReference = rms(render(cleanMon, frames: frames, monitor: true)[tail])

        for (name, poison) in Self.poisons {
            let audio = MPXGenerator(config: richConfig(mode: .fm), sampleRate: sampleRate)
            let audioOut = render(audio, frames: frames, poison: poison,
                                  poisonRange: 5_000..<5_064, audioOnly: true)
            #expect(audioOut.allSatisfy { $0.isFinite },
                    "\(name) poisoned the processed-audio render")
            let audioDelta = 20.0 * log10(max(rms(audioOut[tail]), 1e-12) / max(audioReference, 1e-12))
            #expect(abs(audioDelta) < 1.0,
                    "\(name): processed audio still reads \(audioDelta) dB off after the burst")

            let mon = MPXGenerator(config: richConfig(), sampleRate: sampleRate)
            let monOut = render(mon, frames: frames, poison: poison,
                                poisonRange: 5_000..<5_064, monitor: true)
            #expect(monOut.allSatisfy { $0.isFinite },
                    "\(name) poisoned the direct monitor render")
            let monDelta = 20.0 * log10(max(rms(monOut[tail]), 1e-12) / max(monReference, 1e-12))
            #expect(abs(monDelta) < 1.0,
                    "\(name): the monitor feed still reads \(monDelta) dB off after the burst")
        }
    }

    // MARK: - Recovery (the part that matters)

    @Test func theChainRecoversToTheCleanSignalAfterABurst() {
        let frames = Int(sampleRate * 1.0)
        let tail = (frames - Int(sampleRate * 0.2))..<frames
        let clean = MPXGenerator(config: richConfig(), sampleRate: sampleRate)
        let reference = rms(render(clean, frames: frames)[tail])
        #expect(reference > 0.01, "the reference render is silent, so recovery cannot be judged")

        for (name, poison) in Self.poisons {
            let gen = MPXGenerator(config: richConfig(), sampleRate: sampleRate)
            // A 64-sample burst, well past warm-up, into a chain whose AGC
            // and limiters are already riding.
            let out = render(gen, frames: frames, poison: poison,
                             poisonRange: 5_000..<5_064)
            let after = rms(out[tail])
            #expect(after > 0.0 && after.isFinite,
                    "\(name): the chain never came back -- tail RMS \(after)")
            let deltaDB = 20.0 * log10(max(after, 1e-12) / reference)
            #expect(abs(deltaDB) < 1.0,
                    "\(name): 200 ms of clean programme after the burst still reads \(deltaDB) dB off the clean render")
        }
    }

    @Test func theGuardCountsWhatItReplaced() {
        let gen = MPXGenerator(config: richConfig(), sampleRate: sampleRate)
        #expect(gen.nonFiniteInputSampleCount == 0)
        _ = render(gen, frames: block, poison: Float.nan, poisonRange: 4..<12)
        // Eight frames, both channels.
        #expect(gen.nonFiniteInputSampleCount >= 16,
                "expected at least one count per poisoned sample per channel, got \(gen.nonFiniteInputSampleCount)")
    }

    @Test func finiteOverRangeInputIsNotTouched() {
        // The guard must not become a limiter: a legitimately hot sample is
        // the peak stages' business, not the ingress guard's.
        let frames = block * 4
        let gen = MPXGenerator(config: richConfig(), sampleRate: sampleRate)
        _ = render(gen, frames: frames, poison: 8.0, poisonRange: 100..<200)
        #expect(gen.nonFiniteInputSampleCount == 0,
                "the guard replaced a finite over-range sample")
    }

    @Test func theCountReachesTheEngineTelemetry() {
        // The guard is only useful to an operator if they can SEE that their
        // source is sending rubbish. Pin the value the API and both front
        // ends read.
        let gen = MPXGenerator(config: richConfig(), sampleRate: sampleRate)
        #expect(gen.nonFiniteInputSampleCount == 0, "a clean start must read zero")
        _ = render(gen, frames: block * 2, poison: Float.infinity, poisonRange: 10..<20)
        let count = gen.nonFiniteInputSampleCount
        #expect(count >= 20,
                "ten poisoned frames on two channels should count at least 20, got \(count)")
        // And it must keep counting, not latch.
        _ = render(gen, frames: block * 2, poison: Float.nan, poisonRange: 0..<5)
        #expect(gen.nonFiniteInputSampleCount > count, "the counter stopped advancing")
    }

    // MARK: - Meter side

    @Test func meterReadingsRecoverAfterANonFiniteBlock() {
        let sr: Float = 192_000.0
        let fullScale: Float = 150.0
        let pilotAmp = 6.75 / fullScale
        let monoAmp = 40.0 / fullScale

        func feed(_ analysis: MeterAnalysis, seconds: Float, poison: Float? = nil) {
            let total = Int(seconds * sr)
            var buf = [Float](repeating: 0.0, count: 8192)
            var t0 = 0
            while t0 < total {
                let n = min(buf.count, total - t0)
                for i in 0..<n {
                    let t = Double(t0 + i) / Double(sr)
                    let mono = Double(monoAmp) * sin(2.0 * Double.pi * 1_000.0 * t)
                    let pilot = Double(pilotAmp) * cos(2.0 * Double.pi * 19_000.0 * t)
                    buf[i] = Float(mono + pilot)
                }
                if let poison { buf[n / 2] = poison }
                buf.withUnsafeBufferPointer {
                    analysis.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
                }
                t0 += n
            }
        }

        for (name, poison) in Self.poisons {
            let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
            feed(a, seconds: 1.0)
            feed(a, seconds: 0.2, poison: poison)
            feed(a, seconds: 2.0)
            let s = a.snapshot()
            #expect(s.pilotDevKHz.isFinite && abs(s.pilotDevKHz - 6.75) < 0.2,
                    "\(name): pilot reads \(s.pilotDevKHz) kHz after the fault cleared")
            #expect(s.maxDevKHz.isFinite && s.maxDevKHz > 1.0,
                    "\(name): MAX DEV reads \(s.maxDevKHz) kHz after the fault cleared")
            // The BS.412 power accumulator is the statistic that cannot
            // self-heal: a sliding sum never flushes a NaN, and an Inf
            // squared dominates the window for its whole length.
            // 40 kHz mono + 6.75 kHz pilot = 10*log10((40^2+6.75^2)/2 / (19^2/2)).
            #expect(s.mpxPowerDBr.isFinite && abs(s.mpxPowerDBr - 6.6) < 1.0,
                    "\(name): MPX power reads \(s.mpxPowerDBr) dBr after the fault cleared")
            #expect(a.nonFiniteInputSampleCount > 0,
                    "\(name): the Meter's guard did not count the fault")
        }
    }
}
