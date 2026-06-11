import Darwin
import Foundation

/// RDS 57 kHz subcarrier front-end: composite samples -> recovered 1187.5 bps
/// data bits -> `RDSStreamDecoder`. This is the receive-side counterpart to
/// `BasicRDSCoder`'s subcarrier generator and the piece the MPX Prime Meter
/// needs to turn a captured composite into a decoded RDS readout.
///
/// Pipeline (one pass, streaming):
///  1. Pilot lock (`PilotPLL`) recovers the 19 kHz pilot phase `p`.
///  2. Coherent 57 kHz demod: the carrier is `sin(3p)` via the triple-angle
///     identity `3*sin(p) - 4*sin^3(p)` (exactly mirroring the encoder, which
///     locks RDS to 3x the emitted pilot). Multiply the composite by it and
///     lowpass to ~3 kHz -> baseband biphase signal.
///  3. Biphase matched filter: a running Manchester correlation (recent
///     half-bit minus previous half-bit) over one bit period. Its output
///     peaks, with sign, at each symbol center.
///  4. Symbol timing: the bit RATE is pilot-locked and known exactly
///     (19000/16 = 1187.5 bps, i.e. sampleRate/1187.5 samples/bit). The bit
///     PHASE is acquired once by scanning sub-bit offsets for the alignment
///     that maximizes summed |matched-filter| over an acquisition window
///     (clean-signal acquisition; a tracking loop is the deferred robustness
///     upgrade for weak off-air pilots). Thereafter a fixed-rate clock samples
///     the matched-filter output at each symbol center.
///  5. Biphase -> level bit (sign of the sample) -> differential decode
///     (`d_k = e_k XOR e_{k-1}`, the inverse of the encoder's
///     `differentialBit ^= dataBit`) -> `RDSStreamDecoder.feed(bit:)`.
///
/// A global carrier-phase inversion or a half-bit timing flip both invert
/// every recovered level bit, which differential decoding cancels -- so only
/// the demod AXIS (not its sign) and the symbol CENTER (not which of the two
/// half-bit slots) must be right, both of which the steps above guarantee.
///
/// `configure()` allocates the acquisition buffer; call it off the real-time
/// audio thread. `process(_:)` is allocation-free. Not thread-safe.
public final class RDSSubcarrierDecoder {

    private enum Phase {
        case warmup    // let the pilot lock-in settle
        case acquire   // buffer matched-filter output, estimate bit phase
        case track     // fixed-rate symbol sampling
    }

    public let stream = RDSStreamDecoder()

    private var sampleRate: Float = 192_000.0
    private var pilot = PilotPLL()
    private var basebandLP = BiquadCascade6()

    // Bit timing.
    private var samplesPerBit: Float = 161.68
    private var bitLen: Int = 162      // L: matched-filter window in samples
    private var halfLen: Int = 81      // H: recent-half length

    // Running Manchester correlation over the last `bitLen` baseband samples:
    //   y = sum(newest H) - sum(previous L-H).
    private var ring: [Float] = []
    private var ringPos: Int = 0
    private var recentSum: Float = 0.0
    private var oldSum: Float = 0.0

    // Acquisition.
    private var phase: Phase = .warmup
    private var globalN: Int = 0
    private var warmupSamples: Int = 0
    private var acquireSamples: Int = 0
    private var acqY: [Float] = []
    private var acqCount: Int = 0
    private var acqStartN: Int = 0

    // Tracking + differential decode.
    private var nextCenter: Float = 0.0   // global sample index of the next symbol center
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
        basebandLP.configureLowpass(cutoffHz: 3_000.0, sampleRate: sr)

        samplesPerBit = sr / 1187.5
        bitLen = max(4, Int(samplesPerBit.rounded()))
        halfLen = bitLen / 2

        ring = Array(repeating: 0.0, count: bitLen)
        warmupSamples = Int((0.060 * sr).rounded())
        acquireSamples = Int((0.300 * sr).rounded())
        acqY = Array(repeating: 0.0, count: acquireSamples)

        resetState()
    }

    public func reset() {
        pilot.configure(sampleRate: sampleRate)
        basebandLP.configureLowpass(cutoffHz: 3_000.0, sampleRate: sampleRate)
        stream.reset()
        resetState()
    }

    private func resetState() {
        for i in ring.indices { ring[i] = 0.0 }
        ringPos = 0
        recentSum = 0.0
        oldSum = 0.0
        phase = .warmup
        globalN = 0
        acqCount = 0
        acqStartN = 0
        nextCenter = 0.0
        lastLevel = 0
        haveLast = false
        lastMag2 = 0.0
    }

    public var state: RDSReceiverState { stream.state }

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

        // 57 kHz carrier = sin(3p) via triple-angle identity.
        let sinP = recovered.sinP
        let carrier57 = (3.0 - (4.0 * sinP * sinP)) * sinP
        let demod = 2.0 * sample * carrier57
        let baseband = basebandLP.process(demod)

        // Update the running Manchester correlation.
        let drop = ring[ringPos]                              // x[n-L]
        let crossing = ring[(ringPos - halfLen + bitLen) % bitLen]  // x[n-H]
        recentSum += baseband - crossing
        oldSum += crossing - drop
        ring[ringPos] = baseband
        ringPos += 1
        if ringPos >= bitLen { ringPos = 0 }
        let y = recentSum - oldSum

        let n = globalN
        globalN += 1

        switch phase {
        case .warmup:
            if n >= warmupSamples {
                phase = .acquire
                acqStartN = n
                acqCount = 0
            }
        case .acquire:
            if acqCount < acquireSamples {
                acqY[acqCount] = y
                acqCount += 1
            }
            if acqCount >= acquireSamples {
                finishAcquisition()
            }
        case .track:
            if Float(n) >= nextCenter {
                decideSymbol(y)
                nextCenter += samplesPerBit
            }
        }
    }

    /// Scan sub-bit offsets for the alignment that maximizes summed
    /// |matched-filter| at predicted symbol centers, then decode every buffered
    /// symbol and hand off to the fixed-rate tracker.
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
                score += fabsf(acqY[idx])
                k += 1
            }
            if score > bestScore {
                bestScore = score
                bestOffset = off
            }
            off += 1
        }

        // Decode every symbol center that falls inside the acquisition buffer,
        // in order, so no bits are lost during acquisition.
        var center = Float(bestOffset)
        while true {
            let idx = Int(center.rounded())
            if idx >= acqCount { break }
            decideSymbol(acqY[idx])
            center += t
        }
        // `center` is now the first center beyond the buffer, in acquisition-
        // relative samples; convert to a global index for the tracker.
        nextCenter = Float(acqStartN) + center
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
