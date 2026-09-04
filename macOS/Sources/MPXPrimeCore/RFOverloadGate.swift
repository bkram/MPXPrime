// RFOverloadGate.swift
// MPX Prime Meter -- debounce for the tuner's IQ-overload (front-end
// clipping) indication.
//
// The tuner reports the share of railed IQ samples per demodulated block
// (~32 ms). A single hot block is not an operator problem; sustained railing
// is -- it inflates every level-derived reading with clipping products
// (measured 2026-08-31 on an RTL: an auto-gain capture of a strong local
// read baseband noise 4.1 kHz / "Unusable" where a correctly-set manual gain
// read 1.15 kHz / "Poor" on the same station -- the bench's "8-bit demod
// floor" was in fact front-end saturation). The gate latches on a railed
// block and holds for a few seconds so the badge is readable, not a
// flickering per-block state.

/// Latch for the RF OVERLOAD warning: fires when the railed-sample share of a
/// block crosses `threshold`, stays on for `holdSeconds` past the last hot
/// block. Thread-confined; feed it from one polling loop.
public struct RFOverloadGate: Sendable {
    /// Railed-sample share above which a block counts as overloaded. 0.001
    /// (0.1%) separates cleanly: a correctly-gained capture measures 0.0000,
    /// an auto-gain capture of a strong local measured 0.10-0.40.
    public let threshold: Double
    /// Seconds the warning holds after the last overloaded block.
    public let holdSeconds: Double
    private var activeUntil: Double = -.infinity

    public init(threshold: Double = 0.001, holdSeconds: Double = 2.0) {
        self.threshold = threshold
        self.holdSeconds = holdSeconds
    }

    /// Feed the latest block's railed-sample share; returns whether the
    /// warning is active at `now` (a monotonic clock, seconds).
    public mutating func update(ratio: Double, now: Double) -> Bool {
        if ratio > threshold {
            activeUntil = now + holdSeconds
        }
        return now < activeUntil
    }

    /// Drop the latch (input restarted / device changed).
    public mutating func reset() {
        activeUntil = -.infinity
    }
}
