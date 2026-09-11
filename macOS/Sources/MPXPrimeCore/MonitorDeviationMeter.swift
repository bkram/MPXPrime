// MonitorDeviationMeter.swift
// MPX Prime Meter -- optional monitor-ballistics (integrating) deviation
// detector, shown ALONGSIDE the SM.1268 true-peak readouts, never instead of
// them.
//
// Hardware modulation monitors derive deviation from a rectified, RC-smoothed
// detector level, so they integrate on the order of a millisecond and cannot
// see the sub-millisecond peak structure a densely clipped composite carries.
// Comparing such an instrument with the Meter's SM.1268 MAX (true peak within
// 50 ms windows) on dense program therefore always shows the monitor lower --
// measured 2026-08-31 on identical captures, a 0.5 ms sliding mean of the
// measurement-filtered |composite| reproduced a reference monitor's max-hold
// within ~1.5 kHz (64.0 computed vs 65-66 shown) while the Meter's MAX read
// 76. This detector implements exactly that: the 0.5 ms sliding mean, with a
// block max for a steady live readout and a max hold that clears with the
// peak accumulators.
//
// Semantics notes, deliberate:
// - This is a DISPLAY convention for comparing against hardware monitors.
//   MAX / PEAK +/- / the histogram / >77 kHz / BS.412 all stay SM.1268-based;
//   nothing regulatory derives from this detector.
// - On mid-frequency tones an integrating detector genuinely reads below the
//   true deviation (a 1 kHz sine reads ~0.64x here: the window mean of |sin|),
//   and real monitors add their own quirks on top (the reference unit also
//   high-passes its detector path, so it under-reads bass-dominated program).
//   Expect agreement on dense program, not on test tones -- the true-peak MAX
//   next to it is the calibrated number.
//
// Thread-confined to the analysis thread; allocation-free after init.
public struct MonitorDeviationMeter {
    /// Integration window. 0.5 ms is the empirically matched constant for the
    /// max-hold behavior of the monitor class (see header).
    public static let windowSeconds: Float = 0.0005

    private var ring: [Float]
    private var write = 0
    private var runningSum: Float = 0.0
    private var primedSamples = 0
    private let invLen: Float
    private var blockMax: Float = 0.0
    private var maxHold: Float = 0.0

    public init(sampleRate: Float) {
        let len = max(8, Int(sampleRate * Self.windowSeconds))
        ring = [Float](repeating: 0.0, count: len)
        invLen = 1.0 / Float(len)
    }

    /// Feed one measurement-path sample (the DC-tracked, measurement-filtered
    /// composite; sign kept by the caller passing |x| is NOT wanted here --
    /// pass the raw sample, rectification happens inside).
    @inline(__always)
    public mutating func process(_ x: Float) {
        let a = x.magnitude
        runningSum += a - ring[write]
        ring[write] = a
        write += 1
        if write == ring.count {
            write = 0
            // Recompute the sum exactly once per wrap: the incremental float
            // sum drifts over hours, and one 96-element pass per 0.5 ms of
            // audio is free at analysis-thread rates.
            var s: Float = 0.0
            for v in ring { s += v }
            runningSum = s
        }
        if primedSamples < ring.count {
            primedSamples += 1
            return  // window not full: a partial mean would read low, not wrong
        }
        let mean = runningSum * invLen
        if mean > blockMax { blockMax = mean }
        if mean > maxHold { maxHold = mean }
    }

    /// Highest window mean since the last call (the live readout for one
    /// snapshot interval), and clears the block accumulator.
    public mutating func takeBlockMax() -> Float {
        let v = blockMax
        blockMax = 0.0
        return v
    }

    /// Highest window mean since the last peak reset.
    public var maxHoldValue: Float { maxHold }

    /// Clears the max hold (Reset Peaks / calibration change), keeping the
    /// window state so the live reading continues seamlessly.
    public mutating func resetPeaks() {
        maxHold = 0.0
        blockMax = 0.0
    }

    /// Full reset (input restart / rate change).
    public mutating func reset() {
        for i in ring.indices { ring[i] = 0.0 }
        write = 0
        runningSum = 0.0
        primedSamples = 0
        blockMax = 0.0
        maxHold = 0.0
    }
}
