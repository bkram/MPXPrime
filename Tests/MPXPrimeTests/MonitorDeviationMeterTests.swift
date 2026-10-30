// MonitorDeviationMeterTests.swift
// The monitor-ballistics (0.5 ms integrating) deviation detector: exact
// window-mean expectations on deterministic signals, hold/reset behavior,
// and the MeterAnalysis integration (same scale as the SM.1268 readouts,
// validity gated with them, never exceeding the true peak).

import Foundation
import Testing
@testable import MPXPrimeCore

@Suite("Monitor-ballistics deviation detector")
struct MonitorDeviationMeterTests {
    private let sr: Float = 192_000.0

    private func run(_ meter: inout MonitorDeviationMeter,
                     seconds: Float, _ gen: (Float) -> Float) -> Float {
        let n = Int(seconds * sr)
        for i in 0..<n { meter.process(gen(Float(i) / sr)) }
        return meter.takeBlockMax()
    }

    @Test("low-frequency sine reads near its peak")
    func lowFrequencySineNearPeak() {
        var m = MonitorDeviationMeter(sampleRate: sr)
        // 100 Hz at the 0.5 ms window: mean over the window around the crest
        // is sinc(w*T/2) = sin(0.157)/0.157 = 0.996 of the peak.
        let got = run(&m, seconds: 0.1) { t in sinf(2.0 * .pi * 100.0 * t) }
        #expect(abs(got - 0.996) < 0.005)
    }

    @Test("1 kHz sine reads the documented window mean (~0.64)")
    func midFrequencySineReadsWindowMean() {
        var m = MonitorDeviationMeter(sampleRate: sr)
        // 1 kHz: the 0.5 ms window spans half a cycle -- mean of |sin| around
        // the crest is sin(pi/2)/(pi/2) = 0.6366. This IS the integrating
        // behavior the readout documents ("expect agreement on dense program,
        // not on sines").
        let got = run(&m, seconds: 0.1) { t in sinf(2.0 * .pi * 1000.0 * t) }
        #expect(abs(got - 0.6366) < 0.01)
    }

    @Test("constant envelope (dense-clip proxy) reads the envelope exactly")
    func constantEnvelopeReadsEnvelope() {
        var m = MonitorDeviationMeter(sampleRate: sr)
        // A low-frequency square wave has |x| == 1 at every sample: the
        // window mean equals the envelope -- the reason integrating monitors
        // sit close to true peak on densely clipped program.
        let got = run(&m, seconds: 0.05) { t in
            sinf(2.0 * .pi * 200.0 * t) >= 0 ? 1.0 : -1.0
        }
        #expect(abs(got - 1.0) < 1e-3)
    }

    @Test("single-sample impulse under-reads by the window length")
    func impulseUnderReads() {
        var m = MonitorDeviationMeter(sampleRate: sr)
        let window = Int(sr * MonitorDeviationMeter.windowSeconds)
        // Prime with silence, one full-scale sample, silence after.
        for _ in 0..<(2 * window) { m.process(0.0) }
        m.process(1.0)
        for _ in 0..<(2 * window) { m.process(0.0) }
        let got = m.takeBlockMax()
        #expect(abs(got - 1.0 / Float(window)) < 1e-4)
    }

    @Test("max hold persists through silence; resetPeaks clears it")
    func maxHoldAndReset() {
        var m = MonitorDeviationMeter(sampleRate: sr)
        _ = run(&m, seconds: 0.02) { t in
            sinf(2.0 * .pi * 200.0 * t) >= 0 ? 0.8 : -0.8
        }
        _ = run(&m, seconds: 0.05) { _ in 0.0 }
        #expect(abs(m.maxHoldValue - 0.8) < 1e-3)
        m.resetPeaks()
        #expect(m.maxHoldValue == 0.0)
        // The window keeps running: a new burst re-registers immediately.
        let again = run(&m, seconds: 0.02) { t in
            sinf(2.0 * .pi * 200.0 * t) >= 0 ? 0.5 : -0.5
        }
        #expect(abs(again - 0.5) < 1e-3)
    }

    @Test("no reading before the window is primed")
    func primingGate() {
        var m = MonitorDeviationMeter(sampleRate: sr)
        let window = Int(sr * MonitorDeviationMeter.windowSeconds)
        for _ in 0..<(window - 2) { m.process(1.0) }
        #expect(m.takeBlockMax() == 0.0)
    }
}

@Suite("Monitor-ballistics deviation through MeterAnalysis")
struct MonitorDeviationAnalysisTests {
    private let sr: Float = 192_000.0
    private let fullScale: Float = 150.0

    private func feed(_ a: MeterAnalysis, seconds: Float, _ gen: (Float) -> Float) {
        let blockLen = 4096
        let total = Int(seconds * sr)
        var block = [Float](repeating: 0.0, count: blockLen)
        var t0 = 0
        while t0 < total {
            let n = min(blockLen, total - t0)
            for i in 0..<n { block[i] = gen(Float(t0 + i) / sr) }
            block.withUnsafeBufferPointer {
                a.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
            }
            t0 += n
        }
    }

    @Test("valid with a scale, same units, never above the true peak")
    func scaledAndBounded() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        // Pilot + heavy 1 kHz program: a realistic composite whose true peak
        // and window mean genuinely differ.
        feed(a, seconds: 3.0) { t in
            0.045 * cosf(2.0 * .pi * 19_000.0 * t)
                + 0.4 * sinf(2.0 * .pi * 1_000.0 * t)
        }
        let s = a.snapshot()
        #expect(s.monitorDevValid)
        #expect(s.monitorMaxDevKHz > 0.0)
        // The integrating figure sits below the SM.1268 true peak on tonal
        // program (window mean < window peak), and both share one scale.
        #expect(s.monitorMaxDevKHz < s.maxDevKHz)
        // 1 kHz dominates: expect roughly the 0.64 window-mean of the 60 kHz
        // audio deviation, +/- the pilot's small contribution.
        let audioKHz = 0.4 * fullScale
        #expect(abs(s.monitorMaxDevKHz - 0.6366 * audioKHz) < 0.15 * audioKHz)
    }

    @Test("no scale -> no monitor figure (validity invariant)")
    func gatedWithoutScale() {
        // Pilot-referenced path with NO pilot present: no deviation scale.
        let a = MeterAnalysis(sampleRate: sr, pilotRefKHz: 6.75, fullScaleKHz: nil)
        feed(a, seconds: 2.0) { t in 0.2 * sinf(2.0 * .pi * 1_000.0 * t) }
        let s = a.snapshot()
        #expect(!s.devScaleValid)
        #expect(!s.monitorDevValid)
        #expect(s.monitorDevKHz == 0.0)
        #expect(s.monitorMaxDevKHz == 0.0)
    }
}
