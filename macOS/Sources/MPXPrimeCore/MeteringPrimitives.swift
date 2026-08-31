#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
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
// - `PilotRDSPhaseMeter`: the EN 50067 sec 1.2 subcarrier-phase angle between
//   the 57 kHz RDS subcarrier and the third harmonic of the 19 kHz pilot --
//   the "RDS phase" reading of a Belar RDS-1 / DEVA analyzer.

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
/// The reading is the PEAK deviation of the subcarrier -- the injection
/// level RDS encoders set (they normalize the shaped biphase waveform by
/// its peak, so "rds_level 2.0 kHz" means the envelope peak hits 2.0 kHz;
/// EN 50067's "deviation range +/-1.0 to +/-7.5 kHz" is likewise a peak
/// range, and the 75 kHz total-deviation budget sums peak contributions).
///
/// HOW it is derived matters on real off-air signals: the statistic is the
/// coherent in-band RMS scaled by the EN 50067 shaped-biphase peak/RMS
/// form factor (`shapedBiphasePeakOverRMSSqrt2` = 1.320, a constant of the
/// spec's cos(pi*f*td/4) pulse shaping measured from a spec-exact encoder;
/// see `encoderRoundTripReadsTheSetInjection`). A raw RMS-equivalent
/// reading (2*sqrt(E[|z|^2])) sits ~24% LOW on real shaped biphase because
/// the envelope dips through zero at symbol transitions -- the 0.39
/// under-read. A raw envelope-PEAK detector is exact on a clean loopback
/// but rides composite-clipper intermod spikes inside the 57 kHz window on
/// heavily-processed stations (measured 2.5-3x over-read off-air, and
/// unsteady) -- peaks add linearly, power adds quadratically, so the
/// RMS-derived reading is far more robust to in-band IM and noise while
/// still reporting the encoder's set injection for spec-shaped data.
/// For x = a(t)*cos(57k*t + phi), the mixed+filtered z = (a/2)*e^{j phi}.
/// A free-running NCO suffices because a few Hz of rotation does not
/// change |z|. Thread-confined; allocation-free after init.
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
    /// Peak/(RMS*sqrt2) of EN 50067 shaped biphase with random group data --
    /// a constant of the spec's pulse shaping, measured from the spec-exact
    /// BasicRDSCoder (envelope peak 2.000 vs RMS*sqrt2 1.515 at any level).
    /// Pinned by the encoder round-trip test.
    public static let shapedBiphasePeakOverRMSSqrt2: Float = 1.320
    // Coherent in-band mean-square |z|^2, EMA'd over ~1 s for a steady
    // display; the reading applies sqrt + the form factor above.
    private var meanSquare: Float = 0.0
    private var primed = false
    private let emaAlphaPerSample: Float

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
        // ~1 s smoothing, applied per decimated sample.
        emaAlphaPerSample = 1.0 - expf(-1.0 / (1.0 * decRate))
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
            let envSq = outI[i] * outI[i] + outQ[i] * outQ[i]
            if primed {
                meanSquare += emaAlphaPerSample * (envSq - meanSquare)
            } else {
                meanSquare = envSq
                primed = true
            }
        }
    }

    /// Peak deviation amplitude of the 57 kHz subcarrier -- the injection
    /// level the encoder was set to for EN 50067 shaped biphase: coherent
    /// in-band RMS scaled to the shaped waveform's envelope peak by the spec
    /// form factor (robust to in-band clipper IM / noise, which a raw peak
    /// detector rides).
    public var peakAmplitude: Float {
        guard primed else { return 0.0 }
        return 2.0 * sqrtf(max(0.0, meanSquare)) * Self.shapedBiphasePeakOverRMSSqrt2
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

/// One complex lock-in chain: per-sample mixer products (against a sine and a
/// cosine reference) in, decimated low-pass baseband out. Anti-alias
/// `BiquadCascade6` at 3 kHz, decimate to ~12 kHz, then a linear-phase Kaiser
/// FIR at 2.6 kHz -- the selectivity `RDSSubcarrierLevelMeter` documents.
///
/// Exists as its own type so `PilotRDSPhaseMeter` can run TWO of them with
/// byte-identical parameters. That is not tidiness: identical chains have
/// identical group delay, which is precisely what cancels the phase error a
/// pilot frequency offset would otherwise inject (see the note there).
private final class QuadratureLockInChain {
    private var lpI = BiquadCascade6()
    private var lpQ = BiquadCascade6()
    private let firI: BlockFIRFilter
    private let firQ: BlockFIRFilter
    private let sampleRate: Float
    private let decim: Int
    private var decimPhase = 0
    private var decI: [Float]
    private var decQ: [Float]
    private var decCount = 0
    /// Decimated, filtered baseband, valid for `[0..<outCount]` after
    /// `finishBlock()`.
    private(set) var outI: [Float]
    private(set) var outQ: [Float]
    private(set) var outCount = 0
    /// Decimated sample rate -- the rate `outI`/`outQ` advance at.
    let decimatedRate: Float

    init(sampleRate: Float, maxBlock: Int) {
        self.sampleRate = sampleRate
        lpI.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        lpQ.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        decim = max(1, Int(sampleRate / 12_000.0))
        decimatedRate = sampleRate / Float(decim)
        let taps = FIRDesign.kaiserLowpass(
            cutoffHz: 2_600.0, sampleRate: decimatedRate,
            transitionHz: min(1_000.0, 0.45 * decimatedRate - 2_600.0), stopbandDB: 70.0)
        let maxDec = maxBlock / decim + 2
        firI = BlockFIRFilter(taps: taps, maxBlock: maxDec)
        firQ = BlockFIRFilter(taps: taps, maxBlock: maxDec)
        decI = [Float](repeating: 0.0, count: maxDec)
        decQ = [Float](repeating: 0.0, count: maxDec)
        outI = [Float](repeating: 0.0, count: maxDec)
        outQ = [Float](repeating: 0.0, count: maxDec)
    }

    /// Feed one sample's mixer products. Call `startBlock()` before the first
    /// sample of a block and `finishBlock()` after the last.
    @inline(__always)
    func push(i: Float, q: Float) {
        let bi = lpI.process(i)
        let bq = lpQ.process(q)
        decimPhase += 1
        if decimPhase >= decim {
            decimPhase = 0
            if decCount < decI.count {
                decI[decCount] = bi
                decQ[decCount] = bq
                decCount += 1
            }
        }
    }

    func startBlock() { decCount = 0 }

    func finishBlock() {
        outCount = decCount
        guard decCount > 0 else { return }
        decI.withUnsafeBufferPointer { firI.process(input: $0, output: &outI, count: decCount) }
        decQ.withUnsafeBufferPointer { firQ.process(input: $0, output: &outQ, count: decCount) }
    }

    func reset() {
        decimPhase = 0
        decCount = 0
        outCount = 0
        // Reconfigure = zero the recursive state with the same coefficients.
        lpI.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        lpQ.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        firI.reset()
        firQ.reset()
    }
}

/// EN 50067 sec 1.2 compliance verdict for a measured pilot-to-RDS subcarrier
/// phase angle. The standard allows TWO conventions -- in phase with, or in
/// quadrature to, the third harmonic of the pilot -- each with a +/- 10 deg
/// tolerance, so both 0 and 90 deg are correct answers and everything between
/// is a mis-set (or absent) phase lock.
public enum RDSPhaseCompliance: Sendable, Equatable {
    /// Locked in phase with the pilot's third harmonic (0 deg +/- 10).
    case inPhase
    /// Locked in quadrature to the pilot's third harmonic (90 deg +/- 10).
    case quadrature
    /// Neither convention: outside both +/- 10 deg windows.
    case outOfSpec

    /// Tolerance on the phase angle, EN 50067 sec 1.2.
    public static let toleranceDeg: Float = 10.0

    /// Classify a folded 0..90 deg reading (`PilotRDSPhaseMeter.phaseDegrees`).
    public init(degrees: Float) {
        if degrees <= Self.toleranceDeg {
            self = .inPhase
        } else if degrees >= 90.0 - Self.toleranceDeg {
            self = .quadrature
        } else {
            self = .outOfSpec
        }
    }

    /// Short operator-facing label.
    public var label: String {
        switch self {
        case .inPhase: return "in phase"
        case .quadrature: return "quadrature"
        case .outOfSpec: return "out of spec"
        }
    }

    public var isCompliant: Bool { self != .outOfSpec }
}

/// Coherent measurement of the phase angle between the 57 kHz RDS subcarrier
/// and the third harmonic of the 19 kHz pilot -- EN 50067 sec 1.2, the "RDS
/// phase" reading of a Belar RDS-1 / DEVA modulation analyzer. The standard
/// requires the subcarrier to be locked either IN PHASE or IN QUADRATURE to
/// that third harmonic, +/- 10 deg; a reading stuck between the two means the
/// encoder is not genuinely pilot-locked.
///
/// Method. A single free-running 19 kHz NCO provides both references: the
/// pilot reference is its `(sin, cos)` pair, and the 57 kHz reference is that
/// same pair put through the triple-angle identities -- so the two references
/// are phase-coherent by construction, not merely nominally 3x apart. Each
/// drives an identical `QuadratureLockInChain`, giving
/// `zp = (Ap/2) e^{j phi_p}` and `zr = (a/2) e^{j phi_r}`, both measured
/// against the same NCO. The answer is `phi_r - 3 phi_p`: the NCO's own phase
/// (and any error in it) cancels exactly.
///
/// Why identical chains, and why a free-running NCO is enough. The NCO never
/// sits exactly on the pilot -- the transmitter's pilot is 19 kHz +/- 2 Hz and
/// the capture clock (dongle crystal / sound card) adds tens of ppm, so the
/// baseband phasors rotate slowly: `phi_p` at `w`, `phi_r` at `3w`. Each
/// filter chain lags its input by its group delay `tau`, so the estimates are
/// `phi_p - w*tau_p` and `phi_r - 3w*tau_r`, and the answer picks up an error
/// of `3w(tau_p - tau_r)`. With mismatched delays that is real: 2 Hz of offset
/// through a 2.5 ms mismatch is 5.4 deg, half the spec window. Running the two
/// paths through the SAME chain design makes `tau_p == tau_r` and the error
/// vanish identically, for any offset -- no frequency estimator, no loop, no
/// tuning constants. (Using `PilotPLL` here instead would NOT work: its 20 ms
/// lock-in is unmatched, and 0.5 Hz of offset alone would bias the reading
/// ~11 deg.)
///
/// Resolving the BPSK ambiguity. RDS is suppressed-carrier DSB: the modulating
/// biphase symbol is bipolar, so `zr` sits at `phi_r` or `phi_r + 180` from
/// symbol to symbol. Squaring removes it (the classic Viterbi & Viterbi m=2
/// carrier-phase estimator): `zr^2 * conj(e^{j 3 phi_p})^2` is a static
/// phasor at `2(phi_r - 3 phi_p)`, averaged over ~2 s and halved. The result
/// is therefore known modulo 180 deg, which loses nothing -- an anti-phase
/// subcarrier is the in-phase case with inverted data, and the receiver's
/// differential decoding cannot tell them apart either.
///
/// Reading convention: `phaseDegrees` is folded to 0..90, matching instrument
/// practice (0 = in phase, 90 = quadrature). Folding to the magnitude is not
/// just cosmetic -- a signed reading of a quadrature station would flicker
/// between +90 and -90 as noise pushed the estimate across the wrap, whereas
/// the folded value is continuous everywhere on the modulo-180 circle.
///
/// Thread-confined; allocation-free after init.
public final class PilotRDSPhaseMeter {
    private var oscC: Float = 1.0
    private var oscS: Float = 0.0
    private let rotC: Float
    private let rotS: Float
    private let pilotChain: QuadratureLockInChain
    private let rdsChain: QuadratureLockInChain
    // Averaged squared-phase phasor (numerator) and in-band power
    // (denominator). Their ratio is the coherence, which is exactly the
    // in-band SNR: additive noise contributes to |zr|^2 but averages out of
    // E[zr^2].
    private var accWReal: Float = 0.0
    private var accWImag: Float = 0.0
    private var accPower: Float = 0.0
    private var primed = false
    private let emaAlphaPerSample: Float
    // A second, much faster average of the same phasor. Comparing the two
    // angles is the stability gate: coherence is scale-free and says nothing
    // about whether the angle is STANDING STILL, so a free-running encoder
    // (RDS carrier not locked to the pilot) walks the angle 0 -> 90 -> 0 at
    // sub-Hz rate with coherence high the whole way, and the readout labels
    // the sweep in-spec/out-of-spec as it passes (audit M5).
    private var fastWReal: Float = 0.0
    private var fastWImag: Float = 0.0
    private let fastAlphaPerSample: Float
    // Decimated samples accumulated since the last reset. The coherence ratio
    // primes at EXACTLY 1.0 on its first sample (|zr^2| == |zr|^2 for a single
    // sample), so without a count gate `valid` was true for the ~2 s EMA
    // settling time on ANYTHING -- noise included, whose folded angle has
    // expectation 45 deg. That is where the phantom "45.4 deg" readings after
    // every retune came from (audit M4).
    private var accumulatedSamples = 0
    private let minSamplesForValid: Int
    /// Below this coherence the reading is noise, not a measurement. ~0.3
    /// corresponds to a 57 kHz in-band SNR of about -3.7 dB, well under what
    /// RDS needs to decode, so a station whose data is readable at all reads
    /// a trustworthy phase.
    public static let minCoherence: Float = 0.3

    /// Whether the sample rate can carry a 57 kHz subcarrier at all.
    public let usable: Bool

    public init(sampleRate: Float, maxBlock: Int) {
        usable = sampleRate > 120_000.0
        let w = 2.0 * Float.pi * 19_000.0 / max(1.0, sampleRate)
        rotC = cosf(w)
        rotS = sinf(w)
        pilotChain = QuadratureLockInChain(sampleRate: sampleRate, maxBlock: maxBlock)
        rdsChain = QuadratureLockInChain(sampleRate: sampleRate, maxBlock: maxBlock)
        // ~2 s smoothing: the angle is a static property of the transmitter,
        // so trade settling time for a rock-steady readout.
        emaAlphaPerSample = 1.0 - expf(-1.0 / (2.0 * pilotChain.decimatedRate))
        // ~0.25 s: fast enough to follow a drifting angle, slow enough not to
        // be noise itself.
        fastAlphaPerSample = 1.0 - expf(-1.0 / (0.25 * pilotChain.decimatedRate))
        // One full EMA time constant of averaging before the angle is
        // published. That is enough for the gate's purpose: over 2 s the
        // coherence of NOISE averages down to ~1/sqrt(N) (order 0.01, far
        // under the 0.3 floor), whereas at the priming sample it is exactly
        // 1.0 and passed everything.
        minSamplesForValid = Int(2.0 * pilotChain.decimatedRate)
    }

    /// Feed a block of composite samples; updates the smoothed phase estimate.
    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard usable, !samples.isEmpty else { return }
        pilotChain.startBlock()
        rdsChain.startBlock()
        for x in samples {
            let c = oscC
            let s = oscS
            // 57 kHz reference = the exact third harmonic of the SAME NCO
            // (sin 3t = 3s - 4s^3, cos 3t = 4c^3 - 3c) -- not a second
            // oscillator that would drift against this one.
            let s3 = (3.0 - 4.0 * s * s) * s
            let c3 = (4.0 * c * c - 3.0) * c
            // Lock-in convention (matching PilotPLL): correlate against sin
            // for I and cos for Q, so a component A*sin(ref + phi) yields
            // (A/2)*e^{j phi}.
            pilotChain.push(i: x * s, q: x * c)
            rdsChain.push(i: x * s3, q: x * c3)
            let nc = c * rotC - s * rotS
            let ns = c * rotS + s * rotC
            oscC = nc
            oscS = ns
        }
        // Renormalize the oscillator once per block (drift is ~1e-7/sample).
        let mag = sqrtf(oscC * oscC + oscS * oscS)
        if mag > 0.0 {
            oscC /= mag
            oscS /= mag
        }
        pilotChain.finishBlock()
        rdsChain.finishBlock()

        let n = min(pilotChain.outCount, rdsChain.outCount)
        guard n > 0 else { return }
        for i in 0..<n {
            let pI = pilotChain.outI[i]
            let pQ = pilotChain.outQ[i]
            let magP2 = pI * pI + pQ * pQ
            // No pilot -> no reference to measure against; skip rather than
            // feed the accumulator a random angle.
            guard magP2 > 1e-16 else { continue }
            let invP = 1.0 / sqrtf(magP2)
            let uc = pI * invP  // cos(phi_p)
            let us = pQ * invP  // sin(phi_p)
            // e^{j 3 phi_p}, again by triple angle.
            let c3 = (4.0 * uc * uc - 3.0) * uc
            let s3 = (3.0 - 4.0 * us * us) * us
            // e^{j 6 phi_p} = (e^{j 3 phi_p})^2 -- the squared domain the
            // BPSK ambiguity is removed in.
            let c6 = c3 * c3 - s3 * s3
            let s6 = 2.0 * c3 * s3

            let rI = rdsChain.outI[i]
            let rQ = rdsChain.outQ[i]
            let power = rI * rI + rQ * rQ
            // zr^2
            let zr2R = rI * rI - rQ * rQ
            let zr2I = 2.0 * rI * rQ
            // w = zr^2 * conj(e^{j 6 phi_p}) = |zr|^2 * e^{j 2 (phi_r - 3 phi_p)}
            let wR = zr2R * c6 + zr2I * s6
            let wI = zr2I * c6 - zr2R * s6

            if primed {
                accWReal += emaAlphaPerSample * (wR - accWReal)
                accWImag += emaAlphaPerSample * (wI - accWImag)
                accPower += emaAlphaPerSample * (power - accPower)
                fastWReal += fastAlphaPerSample * (wR - fastWReal)
                fastWImag += fastAlphaPerSample * (wI - fastWImag)
            } else {
                accWReal = wR
                accWImag = wI
                accPower = power
                fastWReal = wR
                fastWImag = wI
                primed = true
            }
            if accumulatedSamples < Int.max { accumulatedSamples += 1 }
        }
    }

    /// Phase angle between the RDS subcarrier and the pilot's third harmonic,
    /// folded to 0..90 deg (0 = in phase, 90 = quadrature; see the type note
    /// on why the reading is unsigned). Meaningless unless `valid`.
    public var phaseDegrees: Float {
        guard primed else { return 0.0 }
        let doubled = atan2f(accWImag, accWReal)  // 2 * (phi_r - 3 phi_p)
        return fabsf(doubled * 0.5 * 180.0 / Float.pi)
    }

    /// Estimate quality, 0..1: `|E[zr^2]| / E[|zr|^2]`, i.e. the coherent
    /// fraction of the in-band power -- 1 for a clean subcarrier at a fixed
    /// phase, ~0 for noise or an absent subcarrier.
    public var coherence: Float {
        guard primed, accPower > 1e-16 else { return 0.0 }
        let m = sqrtf(accWReal * accWReal + accWImag * accWImag)
        return min(1.0, m / accPower)
    }

    /// How closely a fast (~0.25 s) average of the same phasor agrees with the
    /// slow (~2 s) one, in degrees of PHASE (half the doubled-domain
    /// difference). Small = the angle is standing still, which is what a
    /// pilot-locked subcarrier does; large = it is walking.
    public var driftDegrees: Float {
        guard primed else { return 180.0 }
        let slowMag = sqrtf(accWReal * accWReal + accWImag * accWImag)
        let fastMag = sqrtf(fastWReal * fastWReal + fastWImag * fastWImag)
        guard slowMag > 1e-20, fastMag > 1e-20 else { return 180.0 }
        // Angle between the two doubled-domain phasors, via atan2 of the
        // cross/dot product (numerically better than differencing angles).
        let dot = (accWReal * fastWReal) + (accWImag * fastWImag)
        let cross = (accWReal * fastWImag) - (accWImag * fastWReal)
        let doubled = fabsf(atan2f(cross, dot))
        return doubled * 0.5 * 180.0 / Float.pi
    }

    /// Above this fast-vs-slow disagreement the angle is drifting, not being
    /// measured. 4 deg: well inside the +/- 10 deg spec window the reading is
    /// judged against, so a compliant station never trips it.
    public static let maxDriftDegrees: Float = 4.0

    /// True when a subcarrier and a pilot are both present, enough of them has
    /// been averaged, the estimate is coherent, and the angle is stable.
    public var valid: Bool {
        usable && primed
            && accumulatedSamples >= minSamplesForValid
            && coherence >= Self.minCoherence
            && driftDegrees <= Self.maxDriftDegrees
    }

    /// EN 50067 sec 1.2 verdict for the current reading.
    public var compliance: RDSPhaseCompliance { RDSPhaseCompliance(degrees: phaseDegrees) }

    public func reset() {
        accWReal = 0.0
        accWImag = 0.0
        accPower = 0.0
        fastWReal = 0.0
        fastWImag = 0.0
        primed = false
        accumulatedSamples = 0
        oscC = 1.0
        oscS = 0.0
        pilotChain.reset()
        rdsChain.reset()
    }
}
