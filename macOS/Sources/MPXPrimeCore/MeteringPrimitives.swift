import Accelerate
import Foundation

// Measurement-grade DSP building blocks for the MPX Prime Meter analysis
// engine (MeterAnalysis). These implement the measurement practice of
// ITU-R SM.1268-5 and professional modulation analyzers:
//
// - `FIRDesign.kaiserLowpass` + `BlockFIRFilter`: a linear-phase FIR
//   measurement low-pass. The previous 6th-order Butterworth IIR rang and
//   overshot (~14% step overshoot) on the sharp edges of a clipped broadcast
//   composite, so the peak detector captured deviation the transmitter never
//   emitted. A linear-phase FIR passes a peak-controlled composite without
//   time-dispersion overshoot (Hershberger/Ogonowski/Orban 1998).
// - `DCTracker`: sub-Hz DC removal ahead of peak/power detection. An SDR
//   demod's carrier tuning offset appears as a DC term that adds linearly to
//   one deviation polarity (asymmetric +/- peaks) and biases MPX power.
// - `RDSSubcarrierLevelMeter`: coherent quadrature measurement of the 57 kHz
//   RDS subcarrier level -- the "equivalent unmodulated subcarrier" deviation
//   per EN 50067 sec 1.3 (the R&S "RMS x sqrt(2)" detector convention). The
//   previous single Q=10 biquad bandpass (~5.7 kHz BW, gentle skirts) leaked
//   53 kHz stereo energy and wideband noise into the reading.

/// Linear-phase FIR design helpers (Kaiser-windowed sinc).
public enum FIRDesign {
    /// Zeroth-order modified Bessel function of the first kind (series form),
    /// for the Kaiser window.
    static func besselI0(_ x: Double) -> Double {
        // Converges quickly for the beta range used here (< ~10).
        var sum = 1.0
        var term = 1.0
        let x2 = x * x / 4.0
        var k = 1.0
        while term > 1e-12 * sum {
            term *= x2 / (k * k)
            sum += term
            k += 1.0
        }
        return sum
    }

    /// Kaiser-windowed sinc low-pass. `cutoffHz` is the passband edge; the
    /// response falls to `stopbandDB` attenuation by `cutoffHz + transitionHz`.
    /// Tap count is derived from the Kaiser formula and forced odd so the
    /// filter is exactly linear-phase (type I). DC gain normalized to 1.
    public static func kaiserLowpass(
        cutoffHz: Float, sampleRate: Float, transitionHz: Float, stopbandDB: Float
    ) -> [Float] {
        let a = Double(max(21.0, stopbandDB))
        let beta: Double
        if a > 50.0 {
            beta = 0.1102 * (a - 8.7)
        } else {
            beta = 0.5842 * pow(a - 21.0, 0.4) + 0.07886 * (a - 21.0)
        }
        let dw = 2.0 * Double.pi * Double(transitionHz) / Double(sampleRate)
        var n = Int((a - 8.0) / (2.285 * dw) + 1.0)
        if n % 2 == 0 { n += 1 }
        n = max(11, n)
        let m = Double(n - 1) / 2.0
        // Design cutoff at the middle of the transition band (-6 dB point).
        let fc = Double(cutoffHz + 0.5 * transitionHz) / Double(sampleRate)
        let i0beta = besselI0(beta)
        var taps = [Float](repeating: 0.0, count: n)
        for k in 0..<n {
            let t = Double(k) - m
            let sinc: Double = t == 0.0
                ? 2.0 * fc
                : sin(2.0 * Double.pi * fc * t) / (Double.pi * t)
            let w = besselI0(beta * (1.0 - (t / m) * (t / m)).squareRoot()) / i0beta
            taps[k] = Float(sinc * w)
        }
        // Normalize DC gain to exactly 1 so the measurement scale is unity.
        var sum: Float = 0.0
        vDSP_sve(taps, 1, &sum, vDSP_Length(n))
        var inv = 1.0 / sum
        vDSP_vsmul(taps, 1, &inv, &taps, 1, vDSP_Length(n))
        return taps
    }
}

/// Streaming block convolution with a linear-phase FIR (vDSP_conv, one call
/// per block). Keeps taps-1 samples of history across blocks so the stream is
/// gapless. Group delay is (taps-1)/2 samples -- irrelevant for metering.
/// Thread-confined; allocation-free after init.
public final class BlockFIRFilter {
    private let taps: [Float]
    private var scratch: [Float]
    private let historyLen: Int

    public init(taps: [Float], maxBlock: Int) {
        precondition(taps.count % 2 == 1, "linear-phase FIR needs odd tap count")
        self.taps = taps
        self.historyLen = taps.count - 1
        self.scratch = [Float](repeating: 0.0, count: maxBlock + taps.count - 1)
    }

    public var groupDelaySamples: Int { historyLen / 2 }

    /// Filter `count` samples of `input` into `output` (which must hold at
    /// least `count` elements). vDSP_conv computes correlation; the taps are
    /// symmetric (linear phase), so correlation == convolution.
    public func process(
        input: UnsafeBufferPointer<Float>, output: inout [Float], count: Int
    ) {
        let n = min(count, output.count)
        guard n > 0 else { return }
        precondition(n + historyLen <= scratch.count, "block exceeds maxBlock")
        // scratch = [history | current block]
        scratch.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<n { buf[historyLen + i] = input[i] }
            vDSP_conv(
                base, 1, taps, 1, &output, 1,
                vDSP_Length(n), vDSP_Length(taps.count))
            // Save the last historyLen input samples for the next block.
            if n >= historyLen {
                for i in 0..<historyLen { buf[i] = input[n - historyLen + i] }
            } else {
                // Short block: shift history left by n, append the block.
                for i in 0..<(historyLen - n) { buf[i] = buf[i + n] }
                for i in 0..<n { buf[historyLen - n + i] = input[i] }
            }
        }
    }

    public func reset() {
        for i in scratch.indices { scratch[i] = 0.0 }
    }
}

/// One-pole DC tracker / sub-Hz high-pass for the deviation measurement path.
/// Removes SDR demod carrier-offset DC so +/- deviation peaks read
/// symmetrically and MPX power is not biased by a DC-squared term. The default
/// 0.2 Hz corner is far below the 20 Hz minimum modulating frequency.
public struct DCTracker {
    private var dc: Float = 0.0
    private var k: Float

    public init(cutoffHz: Float = 0.2, sampleRate: Float) {
        k = 1.0 - expf(-2.0 * Float.pi * cutoffHz / sampleRate)
    }

    /// Retune the tracking corner (e.g. fast acquisition during warm-up,
    /// then slow tracking). Keeps the current DC estimate.
    public mutating func setCutoff(_ cutoffHz: Float, sampleRate: Float) {
        k = 1.0 - expf(-2.0 * Float.pi * cutoffHz / sampleRate)
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        dc += k * (x - dc)
        return x - dc
    }

    /// Current DC estimate (diagnostic).
    public var estimate: Float { dc }

    public mutating func reset() { dc = 0.0 }
}

/// Coherent RDS subcarrier level meter: quadrature-mix the composite at
/// 57 kHz, low-pass the I/Q baseband (6th-order Butterworth at 3 kHz as
/// anti-alias), decimate to ~12 kHz, then a linear-phase FIR (passband
/// 2.6 kHz, stopband 3.6 kHz) for the selectivity a biquad bandpass cannot
/// give: 53 kHz stereo-difference energy lands at a 4 kHz offset after the
/// mix and is rejected > 85 dB in total, instead of ~8-10 dB.
///
/// The reading is the EN 50067 "equivalent unmodulated subcarrier" level:
/// for x = a(t)*cos(57k*t + phi), the mixed+filtered z = (a/2)*e^{j phi}, so
/// equivalentPeakAmplitude = 2*sqrt(E[|z|^2]) = sqrt(E[a^2]) -- the amplitude
/// an unmodulated subcarrier of the same power would have. Envelope-invariant
/// (a "solid reading" per instrument practice); a free-running NCO suffices
/// because a few Hz of rotation does not change |z|.
/// Thread-confined; allocation-free after init.
public final class RDSSubcarrierLevelMeter {
    private var oscC: Float = 1.0
    private var oscS: Float = 0.0
    private let rotC: Float
    private let rotS: Float
    private let sampleRate: Float
    private var lpI = BiquadCascade6()
    private var lpQ = BiquadCascade6()
    private let decim: Int
    private var decimPhase = 0
    private let firI: BlockFIRFilter
    private let firQ: BlockFIRFilter
    private var decI: [Float]
    private var decQ: [Float]
    private var outI: [Float]
    private var outQ: [Float]
    private let emaAlphaPerSample: Float
    /// EMA'd mean-square of the filtered baseband |z|^2 (~0.5 s).
    private var meanSquare: Float = 0.0
    private var primed = false

    /// Whether the sample rate can carry a 57 kHz subcarrier at all.
    public let usable: Bool

    public init(sampleRate: Float, maxBlock: Int) {
        self.sampleRate = sampleRate
        usable = sampleRate > 120_000.0
        let w = 2.0 * Float.pi * 57_000.0 / max(1.0, sampleRate)
        rotC = cosf(w)
        rotS = sinf(w)
        lpI.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        lpQ.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        decim = max(1, Int(sampleRate / 12_000.0))
        let decRate = sampleRate / Float(decim)
        let taps = FIRDesign.kaiserLowpass(
            cutoffHz: 2_600.0, sampleRate: decRate,
            transitionHz: min(1_000.0, 0.45 * decRate - 2_600.0), stopbandDB: 70.0)
        let maxDec = maxBlock / decim + 2
        firI = BlockFIRFilter(taps: taps, maxBlock: maxDec)
        firQ = BlockFIRFilter(taps: taps, maxBlock: maxDec)
        decI = [Float](repeating: 0.0, count: maxDec)
        decQ = [Float](repeating: 0.0, count: maxDec)
        outI = [Float](repeating: 0.0, count: maxDec)
        outQ = [Float](repeating: 0.0, count: maxDec)
        // ~0.5 s smoothing, applied per decimated sample.
        emaAlphaPerSample = 1.0 - expf(-1.0 / (0.5 * decRate))
    }

    /// Feed a block of composite samples; updates the smoothed level.
    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard usable, !samples.isEmpty else { return }
        var dn = 0
        for x in samples {
            // Quadrature mix at 57 kHz (recurrence oscillator).
            let bi = lpI.process(x * oscC)
            let bq = lpQ.process(x * -oscS)
            let nc = oscC * rotC - oscS * rotS
            let ns = oscC * rotS + oscS * rotC
            oscC = nc
            oscS = ns
            decimPhase += 1
            if decimPhase >= decim {
                decimPhase = 0
                if dn < decI.count {
                    decI[dn] = bi
                    decQ[dn] = bq
                    dn += 1
                }
            }
        }
        // Renormalize the oscillator once per block (drift is ~1e-7/sample).
        let mag = sqrtf(oscC * oscC + oscS * oscS)
        if mag > 0.0 {
            oscC /= mag
            oscS /= mag
        }
        guard dn > 0 else { return }
        decI.withUnsafeBufferPointer { firI.process(input: $0, output: &outI, count: dn) }
        decQ.withUnsafeBufferPointer { firQ.process(input: $0, output: &outQ, count: dn) }
        for i in 0..<dn {
            let ms = outI[i] * outI[i] + outQ[i] * outQ[i]
            if primed {
                meanSquare += emaAlphaPerSample * Float(decim) * (ms - meanSquare)
            } else {
                meanSquare = ms
                primed = true
            }
        }
    }

    /// Equivalent unmodulated-subcarrier peak amplitude (EN 50067 sec 1.3):
    /// the amplitude an unmodulated 57 kHz sine of the same power would have.
    public var equivalentPeakAmplitude: Float {
        primed ? 2.0 * sqrtf(max(0.0, meanSquare)) : 0.0
    }

    public func reset() {
        meanSquare = 0.0
        primed = false
        decimPhase = 0
        oscC = 1.0
        oscS = 0.0
        // Reconfigure = zero the recursive state with the same coefficients.
        lpI.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        lpQ.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        firI.reset()
        firQ.reset()
    }
}
