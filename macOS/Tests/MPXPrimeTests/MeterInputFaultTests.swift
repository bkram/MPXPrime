import Foundation
import MPXPrimeCore
import Testing

@testable import MPXPrime

// A non-finite input sample is a HOLE in the measurement, not a value. The
// 0.60 ingress guard made the analyser survive it (NaN or Inf used to poison
// every sliding window permanently); this pins what the guard does to the
// readouts: the repaired block stays out of the accumulated statistics, the
// peaks are withheld while the hole is inside their window, MPX power while
// it is inside the BS.412 window, and the count reaches the snapshot so the
// Meter can say BAD INPUT. Short windows so the ageing-out is testable.
@Suite("Meter input faults")
struct MeterInputFaultTests {

    private let sr: Float = 192_000.0
    private let fullScale: Float = 150.0
    private let blockLen = 8192

    private func composite(_ t: Float) -> Float {
        let cycles = Double(1_000.0) * Double(t)
        let tone = Float(2.0 * Double.pi * (cycles - cycles.rounded(.down)))
        let pcycles = Double(19_000.0) * Double(t)
        let pilot = Float(2.0 * Double.pi * (pcycles - pcycles.rounded(.down)))
        return (40.0 / fullScale) * cosf(tone) + (6.75 / fullScale) * sinf(pilot)
    }

    private func feed(_ a: MeterAnalysis, seconds: Float, from start: inout Int,
                      poison: [Int: Float] = [:]) {
        let total = Int(seconds * sr)
        var block = [Float](repeating: 0.0, count: blockLen)
        var done = 0
        while done < total {
            let n = min(blockLen, total - done)
            for i in 0..<n {
                block[i] = poison[done + i] ?? composite(Float(start + done + i) / sr)
            }
            block.withUnsafeBufferPointer {
                a.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
            }
            done += n
        }
        start += total
    }

    private func counted(_ s: MeterSnapshot) -> Double {
        s.exceedanceBoundPct > 0.0 ? 100.0 / Double(s.exceedanceBoundPct) : 0.0
    }

    @Test func aHoleWithholdsTheWindowsItSitsInAndAgesOut() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale,
                              mpxPowerWindowSeconds: 4, peakWindowSeconds: 2)
        var t = 0
        feed(a, seconds: 3.0, from: &t)
        let clean = a.snapshot()
        #expect(clean.peakValid)
        #expect(clean.mpxPowerValid)
        #expect(clean.nonFiniteInputSamples == 0)
        #expect(!clean.inputFaultInWindow)
        #expect(a.nonFiniteInputSampleCount == 0)
        let countedBefore = counted(clean)
        #expect(countedBefore > 0.0)

        // One block carrying a NaN and an Inf.
        feed(a, seconds: Float(blockLen) / sr, from: &t,
             poison: [100: Float.nan, 200: Float.infinity])
        let faulted = a.snapshot()
        #expect(faulted.nonFiniteInputSamples == 2)
        #expect(a.nonFiniteInputSampleCount == 2)
        #expect(faulted.inputFaultInWindow)
        #expect(!faulted.peakValid, "peaks published across a hole")
        #expect(!faulted.mpxPowerValid, "MPX power published across a hole")
        #expect(faulted.posPeakDevKHz == 0.0 && faulted.negPeakDevKHz == 0.0)
        // The repaired block stayed out of the exceedance statistic.
        #expect(abs(counted(faulted) - countedBefore) < 1.0,
                "the repaired block was counted into the exceedance total")

        // Past the 2 s peak window the peaks are measurements again; the
        // 4 s BS.412 window still contains the hole.
        feed(a, seconds: 2.2, from: &t)
        let midway = a.snapshot()
        #expect(midway.peakValid)
        #expect(midway.posPeakDevKHz > 30.0)
        #expect(!midway.mpxPowerValid)
        #expect(midway.inputFaultInWindow)
        #expect(counted(midway) > countedBefore + 1_000.0, "counting did not resume after the hole")

        // Past the BS.412 window everything measures again; the count stays
        // until the operator resets, because the peak-hold / histogram /
        // max accumulators still carry the gap.
        feed(a, seconds: 2.0, from: &t)
        let aged = a.snapshot()
        #expect(aged.mpxPowerValid)
        #expect(!aged.inputFaultInWindow)
        #expect(aged.nonFiniteInputSamples == 2)

        a.requestPeakReset()
        feed(a, seconds: Float(blockLen) / sr, from: &t)
        #expect(a.snapshot().nonFiniteInputSamples == 0)
        #expect(a.nonFiniteInputSampleCount == 2, "the lifetime count is not a reset target")
    }

    @Test func aRetuneForgetsTheHoleWithTheWindow() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale,
                              mpxPowerWindowSeconds: 4, peakWindowSeconds: 2)
        var t = 0
        feed(a, seconds: 2.0, from: &t)
        feed(a, seconds: Float(blockLen) / sr, from: &t, poison: [7: -Float.infinity])
        #expect(a.snapshot().inputFaultInWindow)
        // A retune starts every window clean, hole included.
        a.requestFullReset()
        feed(a, seconds: 1.5, from: &t)
        let fresh = a.snapshot()
        #expect(!fresh.inputFaultInWindow)
        #expect(fresh.nonFiniteInputSamples == 0)
        #expect(fresh.mpxPowerValid)
    }
}
