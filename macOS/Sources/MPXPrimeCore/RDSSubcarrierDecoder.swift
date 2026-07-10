#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// RDS 57 kHz subcarrier front-end: composite samples -> recovered 1187.5 bps
/// data bits -> `RDSStreamDecoder`. This is the receive-side counterpart to
/// `BasicRDSCoder`'s subcarrier generator and the piece the MPX Prime Meter
/// needs to turn a captured composite into a decoded RDS readout.
///
/// Pipeline (one pass, streaming):
///  1. Pilot lock (`PilotPLL`) recovers the 19 kHz pilot phase `p`.
///  2. Coherent dual-axis 57 kHz demod: the composite is mixed with BOTH
///     `sin(3p)` and `cos(3p)` (triple-angle identities, mirroring the
///     encoder's pilot-locked carrier) and each product is lowpassed to
///     ~3 kHz. Two axes are required for real signals: EN 50067 Sec 2.1.4
///     allows the RDS subcarrier to be locked either in phase OR in
///     quadrature to the third pilot harmonic, and a tuner's MPX output
///     filtering adds its own arbitrary 57 kHz-vs-19 kHz phase rotation.
///     Demodulating one fixed axis costs cos(phi) of the amplitude --
///     decodable on a strong signal but with badly degraded BER.
///  3. Biphase matched filter per axis: a running Manchester correlation
///     (recent half-bit minus previous half-bit) over one bit period. Its
///     output peaks, with sign, at each symbol center.
///  4. Carrier-axis recovery: at each symbol strobe the (I, Q) matched-filter
///     pair is folded into slow second-moment accumulators; the dominant
///     signal axis is `0.5 * atan2(2*cIQ, cII - cQQ)` and the symbol value is
///     the projection onto it. The 180-degree axis ambiguity inverts every
///     level bit, which the differential decode cancels.
///  5. Symbol timing: the bit RATE is pilot-locked (19000/16 = 1187.5 bps)
///     but the receiver's sample clock (DAC/SDR) and the broadcast clock are
///     independent oscillators, so the strobe is steered by a Gardner
///     timing-error detector + PI loop (clamped to +/-1000 ppm) instead of a
///     fixed-rate clock. Initial bit phase comes from a one-shot acquisition
///     scan that maximizes matched-filter energy over a 300 ms window.
///  6. Biphase -> level bit (sign of the projected sample) -> differential
///     decode (`d_k = e_k XOR e_{k-1}`, the inverse of the encoder's
///     `differentialBit ^= dataBit`) -> `RDSStreamDecoder.feed(bit:)`.
///  7. Re-acquire watchdog: once per second in track, if almost every block
///     is failing its checkword (retune, signal loss) the front-end drops
///     back to acquisition instead of free-running on a stale bit phase.
///
/// `configure()` allocates buffers; call it off the real-time audio thread.
/// `process(_:)` is allocation-free. Not thread-safe.
public final class RDSSubcarrierDecoder {

    private enum Phase {
        case warmup    // let the pilot lock-in settle
        case acquire   // buffer matched-filter output, estimate bit phase
        case track     // Gardner-steered symbol strobing
    }

    public let stream = RDSStreamDecoder()

    private var sampleRate: Float = 192_000.0
    private var pilot = PilotPLL()
    private var basebandLPI = BiquadCascade6()
    private var basebandLPQ = BiquadCascade6()

    // Bit timing.
    private var samplesPerBit: Float = 161.68
    private var bitLen: Int = 162      // L: matched-filter window in samples
    private var halfLen: Int = 81      // H: recent-half length

    // Running Manchester correlation per axis over the last `bitLen` baseband
    // samples: y = sum(newest H) - sum(previous L-H).
    private var ringI: [Float] = []
    private var ringQ: [Float] = []
    private var ringPos: Int = 0
    private var recentSumI: Float = 0.0
    private var oldSumI: Float = 0.0
    private var recentSumQ: Float = 0.0
    private var oldSumQ: Float = 0.0

    // Matched-filter history so the strobe can be evaluated at fractional
    // sample positions (linear interpolation).
    private var yHistI: [Float] = []
    private var yHistQ: [Float] = []
    private var histLen: Int = 0

    // Acquisition.
    private var phase: Phase = .warmup
    private var globalN: Int = 0
    private var warmupSamples: Int = 0
    private var acquireSamples: Int = 0
    private var acqYI: [Float] = []
    private var acqYQ: [Float] = []
    private var acqCount: Int = 0
    private var acqStartN: Int = 0

    // Carrier-axis recovery: exponentially-forgotten second moments of the
    // per-symbol (I, Q) matched-filter pair. ~200-symbol (~170 ms) memory.
    private var cII: Float = 0.0
    private var cQQ: Float = 0.0
    private var cIQ: Float = 0.0
    private var axisCos: Float = 1.0
    private var axisSin: Float = 0.0
    private let axisForget: Float = 0.995

    // Symbol-timing recovery (Gardner TED + PI loop). Gains sized for the
    // heavily-oversampled (~162 samples/bit) MF output; TED sign set
    // empirically against the clock-offset round-trip test. +/-1000 ppm
    // covers any real DAC/SDR clock offset.
    //
    // strobePos holds an ABSOLUTE sample index and must be Double: Float32's
    // 24-bit mantissa stops representing consecutive integers past ~16.7M
    // samples (~87 s at 192 kHz), after which `strobePos += periodEst`
    // quantizes and the symbol strobe develops runtime-growing jitter --
    // observed live as block-error rate climbing with time-on-air.
    private var strobePos: Double = 0.0   // global sample index of the next symbol center
    private var periodEst: Double = 0.0   // tracked samples/bit
    private var prevCenterY: Float = 0.0  // projected y at the previous symbol center
    private var haveTimingHistory = false
    private let timingKp: Double = 0.10
    private let timingKi: Double = 0.004
    private let timingSign: Double = -1.0
    private let maxPeriodFraction: Double = 0.001

    // Re-acquire watchdog (track phase, once per second): if nearly all
    // recent blocks fail their checkword, the bit phase is stale -- re-acquire
    // immediately. A decode stuck at a mediocre error rate (timing/axis crept
    // off but not catastrophically) re-acquires after several consecutive bad
    // seconds instead of persisting degraded forever.
    private var watchdogInterval: Int = 0
    private var nextWatchdogN: Int = 0
    private var prevBlocksReceived: Int = 0
    private var prevBlocksValid: Int = 0
    private var mediocreSeconds: Int = 0

    // Differential decode.
    private var lastLevel: Int = 0
    private var haveLast: Bool = false

    private var lastMag2: Float = 0.0

    public init(sampleRate: Float = 192_000.0) {
        configure(sampleRate: sampleRate)
    }

    public func configure(sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        self.sampleRate = sr
        pilot.configure(sampleRate: sr)
        // ~3 kHz lowpass isolates the +/-2.4 kHz RDS baseband after demod; the
        // nearest demod image (pilot -> 38 kHz) is far above it.
        basebandLPI.configureLowpass(cutoffHz: 3_000.0, sampleRate: sr)
        basebandLPQ.configureLowpass(cutoffHz: 3_000.0, sampleRate: sr)

        samplesPerBit = sr / 1187.5
        bitLen = max(4, Int(samplesPerBit.rounded()))
        halfLen = bitLen / 2

        ringI = Array(repeating: 0.0, count: bitLen)
        ringQ = Array(repeating: 0.0, count: bitLen)
        histLen = 2 * bitLen + 16
        yHistI = Array(repeating: 0.0, count: histLen)
        yHistQ = Array(repeating: 0.0, count: histLen)
        warmupSamples = Int((0.060 * sr).rounded())
        acquireSamples = Int((0.300 * sr).rounded())
        acqYI = Array(repeating: 0.0, count: acquireSamples)
        acqYQ = Array(repeating: 0.0, count: acquireSamples)
        watchdogInterval = Int(sr.rounded())

        resetState()
    }

    public func reset() {
        pilot.configure(sampleRate: sampleRate)
        basebandLPI.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        basebandLPQ.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        stream.reset()
        resetState()
    }

    private func resetState() {
        for i in ringI.indices { ringI[i] = 0.0 }
        for i in ringQ.indices { ringQ[i] = 0.0 }
        for i in yHistI.indices { yHistI[i] = 0.0 }
        for i in yHistQ.indices { yHistQ[i] = 0.0 }
        ringPos = 0
        recentSumI = 0.0
        oldSumI = 0.0
        recentSumQ = 0.0
        oldSumQ = 0.0
        phase = .warmup
        globalN = 0
        acqCount = 0
        acqStartN = 0
        cII = 0.0
        cQQ = 0.0
        cIQ = 0.0
        axisCos = 1.0
        axisSin = 0.0
        strobePos = 0.0
        periodEst = Double(samplesPerBit)
        prevCenterY = 0.0
        haveTimingHistory = false
        nextWatchdogN = 0
        prevBlocksReceived = 0
        prevBlocksValid = 0
        mediocreSeconds = 0
        lastLevel = 0
        haveLast = false
        lastMag2 = 0.0
    }

    public var state: RDSReceiverState { stream.state }

    /// Test seam (@testable): pre-advance the absolute sample counter as if
    /// the decoder had already been running for `n` samples. Regression
    /// coverage for strobe precision at large sample indices -- a Float32
    /// strobe position quantizes past ~16.7M samples (~87 s at 192 kHz) and
    /// the symbol clock develops runtime-growing jitter.
    func _testAdvanceSampleIndex(to n: Int) {
        globalN = n
        nextWatchdogN = n + watchdogInterval
    }

    /// True once the pilot lock-in has meaningful energy and the front-end has
    /// finished bit-phase acquisition.
    public var locked: Bool { phase == .track && lastMag2 > 1e-6 }

    /// Convenience: feed a contiguous block of composite samples.
    public func process(_ samples: [Float]) {
        for s in samples { process(s) }
    }

    public func process(_ sample: Float) {
        let recovered = pilot.process(sample)
        lastMag2 = recovered.mag2

        // Dual-axis 57 kHz carrier from the recovered pilot phase:
        //   sin(3p) = sin(p) * (3 - 4 sin^2(p))
        //   cos(3p) = cos(p) * (1 - 4 sin^2(p))
        let sinP = recovered.sinP
        let cosP = recovered.cosP
        let sin2 = sinP * sinP
        let carrierI = (3.0 - (4.0 * sin2)) * sinP
        let carrierQ = (1.0 - (4.0 * sin2)) * cosP
        let basebandI = basebandLPI.process(2.0 * sample * carrierI)
        let basebandQ = basebandLPQ.process(2.0 * sample * carrierQ)

        // Update the running Manchester correlations (shared indices).
        let crossingIdx = (ringPos - halfLen + bitLen) % bitLen
        let dropI = ringI[ringPos]
        let crossingI = ringI[crossingIdx]
        recentSumI += basebandI - crossingI
        oldSumI += crossingI - dropI
        ringI[ringPos] = basebandI
        let dropQ = ringQ[ringPos]
        let crossingQ = ringQ[crossingIdx]
        recentSumQ += basebandQ - crossingQ
        oldSumQ += crossingQ - dropQ
        ringQ[ringPos] = basebandQ
        ringPos += 1
        if ringPos >= bitLen { ringPos = 0 }
        let yI = recentSumI - oldSumI
        let yQ = recentSumQ - oldSumQ

        let n = globalN
        globalN += 1
        let histIdx = n % histLen
        yHistI[histIdx] = yI
        yHistQ[histIdx] = yQ

        switch phase {
        case .warmup:
            if n >= warmupSamples {
                phase = .acquire
                acqStartN = n
                acqCount = 0
            }
        case .acquire:
            if acqCount < acquireSamples {
                acqYI[acqCount] = yI
                acqYQ[acqCount] = yQ
                acqCount += 1
            }
            if acqCount >= acquireSamples {
                finishAcquisition()
            }
        case .track:
            // Evaluate each symbol center once it (and its interpolation
            // neighbor) is safely in the past.
            while Double(n) >= strobePos + 1.0 {
                let yIk = interp(yHistI, strobePos)
                let yQk = interp(yHistQ, strobePos)
                updateAxis(yI: yIk, yQ: yQk)
                let yk = (yIk * axisCos) + (yQk * axisSin)
                decideSymbol(yk)
                if haveTimingHistory {
                    // Gardner TED on the projected matched-filter output: the
                    // midpoint sample sits at the inter-symbol boundary
                    // (y ~ 0 when timing is correct).
                    let mid = strobePos - (periodEst * 0.5)
                    let ymid = (interp(yHistI, mid) * axisCos) + (interp(yHistQ, mid) * axisSin)
                    let raw = ymid * (yk - prevCenterY)
                    let denom = (yk * yk) + (prevCenterY * prevCenterY) + 1e-6
                    var e = timingSign * Double(raw / denom)
                    if e > 0.5 { e = 0.5 } else if e < -0.5 { e = -0.5 }
                    periodEst += timingKi * e
                    let lo = Double(samplesPerBit) * (1.0 - maxPeriodFraction)
                    let hi = Double(samplesPerBit) * (1.0 + maxPeriodFraction)
                    if periodEst < lo { periodEst = lo } else if periodEst > hi { periodEst = hi }
                    strobePos += periodEst + (timingKp * e)
                } else {
                    strobePos += periodEst
                    haveTimingHistory = true
                }
                prevCenterY = yk
            }
            if n >= nextWatchdogN {
                runWatchdog(at: n)
            }
        }
    }

    /// Fold one symbol's (I, Q) pair into the axis estimate and refresh the
    /// projection vector. The axis is the dominant eigenvector of the (I, Q)
    /// second-moment matrix; `0.5 * atan2` collapses the 180-degree ambiguity
    /// (harmless -- differential decode cancels a global inversion).
    private func updateAxis(yI: Float, yQ: Float) {
        cII = (axisForget * cII) + (yI * yI)
        cQQ = (axisForget * cQQ) + (yQ * yQ)
        cIQ = (axisForget * cIQ) + (yI * yQ)
        let energy = cII + cQQ
        guard energy > 1e-9 else { return }
        let angle = 0.5 * atan2f(2.0 * cIQ, cII - cQQ)
        axisCos = cosf(angle)
        axisSin = sinf(angle)
    }

    /// Once per second in track: if nearly every recent block failed its
    /// checkword while bits kept flowing, the bit phase / axis is stale
    /// (retune, signal swap) -- drop back to acquisition. The stream decoder's
    /// own state is left alone; it resynchronizes itself on the fresh bits.
    private func runWatchdog(at n: Int) {
        nextWatchdogN = n + watchdogInterval
        let received = stream.state.blocksReceived
        let valid = stream.state.blocksValid
        let deltaReceived = received - prevBlocksReceived
        let deltaValid = valid - prevBlocksValid
        prevBlocksReceived = received
        prevBlocksValid = valid
        guard deltaReceived >= 32 else { return }
        let ratio = Float(deltaValid) / Float(deltaReceived)
        if ratio < 0.20 {
            reacquire(at: n)
            return
        }
        // Persistent mediocre decode (> ~35% block errors for 5 s straight):
        // a fresh acquisition is cheap (~0.36 s of bits) compared to staying
        // degraded indefinitely.
        if ratio < 0.65 {
            mediocreSeconds += 1
            if mediocreSeconds >= 5 {
                reacquire(at: n)
            }
        } else {
            mediocreSeconds = 0
        }
    }

    private func reacquire(at n: Int) {
        phase = .acquire
        acqStartN = n
        acqCount = 0
        cII = 0.0
        cQQ = 0.0
        cIQ = 0.0
        mediocreSeconds = 0
    }

    /// Linear interpolation of a matched-filter history at a fractional global
    /// sample index. Caller must ensure `pos` and `pos+1` are within the most
    /// recent `histLen` samples. `pos` is Double: the fractional part stays
    /// exact at arbitrarily large absolute sample indices.
    private func interp(_ hist: [Float], _ pos: Double) -> Float {
        let g0 = Int(pos.rounded(.down))
        let frac = Float(pos - Double(g0))
        let i0 = ((g0 % histLen) + histLen) % histLen
        let i1 = (((g0 + 1) % histLen) + histLen) % histLen
        return (hist[i0] * (1.0 - frac)) + (hist[i1] * frac)
    }

    /// Scan sub-bit offsets for the alignment that maximizes summed
    /// matched-filter energy (I^2 + Q^2, axis-independent) at predicted symbol
    /// centers, estimate the carrier axis at that alignment, then decode every
    /// buffered symbol and hand off to the timing loop.
    private func finishAcquisition() {
        let t = samplesPerBit
        let maxOffset = bitLen
        var bestOffset = 0
        var bestScore: Float = -1.0
        var off = 0
        while off < maxOffset {
            var score: Float = 0.0
            var k = 0
            while true {
                let idx = Int((Float(off) + Float(k) * t).rounded())
                if idx >= acqCount { break }
                score += (acqYI[idx] * acqYI[idx]) + (acqYQ[idx] * acqYQ[idx])
                k += 1
            }
            if score > bestScore {
                bestScore = score
                bestOffset = off
            }
            off += 1
        }

        // Seed the carrier axis from the buffered strobes at the chosen
        // alignment, then decode every buffered symbol with the projection so
        // no bits are lost during acquisition.
        cII = 0.0
        cQQ = 0.0
        cIQ = 0.0
        var center = Float(bestOffset)
        while true {
            let idx = Int(center.rounded())
            if idx >= acqCount { break }
            cII += acqYI[idx] * acqYI[idx]
            cQQ += acqYQ[idx] * acqYQ[idx]
            cIQ += acqYI[idx] * acqYQ[idx]
            center += t
        }
        if (cII + cQQ) > 1e-9 {
            let angle = 0.5 * atan2f(2.0 * cIQ, cII - cQQ)
            axisCos = cosf(angle)
            axisSin = sinf(angle)
        }

        center = Float(bestOffset)
        while true {
            let idx = Int(center.rounded())
            if idx >= acqCount { break }
            decideSymbol((acqYI[idx] * axisCos) + (acqYQ[idx] * axisSin))
            center += t
        }

        // `center` is now the first center beyond the buffer, in acquisition-
        // relative samples; convert to a global index and seed the timing loop.
        // Double throughout: Float(acqStartN) rounds once the run is past
        // ~16.7M samples, which would mis-seed the strobe on a late re-acquire.
        strobePos = Double(acqStartN) + Double(center)
        periodEst = Double(samplesPerBit)
        prevCenterY = 0.0
        haveTimingHistory = false
        nextWatchdogN = globalN + watchdogInterval
        prevBlocksReceived = stream.state.blocksReceived
        prevBlocksValid = stream.state.blocksValid
        phase = .track
    }

    private func decideSymbol(_ y: Float) {
        let level = y > 0.0 ? 1 : 0   // recovered differentially-encoded bit e_k
        if haveLast {
            let dataBit = UInt8(level ^ lastLevel)   // d_k = e_k XOR e_{k-1}
            stream.feed(bit: dataBit)
        }
        lastLevel = level
        haveLast = true
    }
}
