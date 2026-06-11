import Darwin
import Foundation
import MPXPrimeCore

/// One coherent snapshot of the meter's measurements, copied out for display.
struct MeterSnapshot {
    var hasSignal = false
    var inputPeakDBFS: Float = -120.0
    var inputRMSDBFS: Float = -120.0

    var pilotPresent = false
    /// Pilot amplitude as a percentage of the composite peak. With the input
    /// driven near full scale this approximates pilot injection; it is a
    /// RELATIVE figure, not calibrated kHz of deviation.
    var pilotPercent: Float = 0.0

    var leftRMSDBFS: Float = -120.0
    var rightRMSDBFS: Float = -120.0
    /// Decoded L/R correlation: ~+1 mono, lower for wide stereo.
    var stereoCorrelation: Float = 0.0

    var rdsLocked = false
    var rds = RDSReceiverState()
    /// Windowed block-error rate (~1 s smoothing). `rds.blockErrorRate` is
    /// cumulative since start and never recovers after a retune; this one
    /// reflects current link quality.
    var recentBlockErrorRate: Float = 0.0
}

/// Drives the receive chain over blocks of composite samples and accumulates a
/// `MeterSnapshot`. Thread-confined: create and call `process` on one thread.
final class MeterAnalysis {
    private let sampleRate: Float
    private var pilot = PilotPLL()
    private var decoder = MPXDecoder()
    private let rds: RDSSubcarrierDecoder
    private var snap = MeterSnapshot()

    // Windowed BER: diff the stream decoder's cumulative block counters per
    // process() call and smooth (~1 s) so the readout tracks current quality.
    private var prevBlocksReceived = 0
    private var prevBlocksValid = 0
    private var berEMA: Float = 0.0

    // Decoded L/R audio for the current block, for the monitor path. Filled by
    // `process`; valid for `[0..<lastBlockCount]`.
    private(set) var decodedL: [Float]
    private(set) var decodedR: [Float]
    private(set) var lastBlockCount = 0

    init(sampleRate: Float, preemphasisUS: Int = 50, maxBlock: Int = 16384) {
        self.sampleRate = sampleRate
        pilot.configure(sampleRate: sampleRate)
        decoder.configure(sampleRate: sampleRate, preemphasisUS: preemphasisUS)
        rds = RDSSubcarrierDecoder(sampleRate: sampleRate)
        decodedL = [Float](repeating: 0.0, count: maxBlock)
        decodedR = [Float](repeating: 0.0, count: maxBlock)
    }

    func process(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let n = Float(samples.count)
        let cap = decodedL.count

        var peak: Float = 0.0
        var sumSq: Float = 0.0
        var pilotMagMax: Float = 0.0
        var lSq: Float = 0.0
        var rSq: Float = 0.0
        var lr: Float = 0.0

        var i = 0
        for s in samples {
            let a = fabsf(s)
            if a > peak { peak = a }
            sumSq += s * s

            let p = pilot.process(s)
            if p.mag2 > pilotMagMax { pilotMagMax = p.mag2 }

            // expectedSide = 0 disables the decoder's stereo-collapse self-heal
            // (a meter must not silently reconfigure); programActivity = |s|
            // keeps the noise gate open while signal is present.
            let (l, r) = decoder.process(s, programActivity: a, expectedSide: 0.0)
            lSq += l * l
            rSq += r * r
            lr += l * r
            if i < cap {
                decodedL[i] = l
                decodedR[i] = r
            }

            rds.process(s)
            i += 1
        }
        lastBlockCount = min(samples.count, cap)

        let rms = sqrtf(sumSq / n)
        // PilotPLL lock-in I/Q each converge to (A/2)*{cos,sin}(phi); |I,Q| = A/2.
        let pilotAmp = 2.0 * sqrtf(pilotMagMax)
        let corr: Float = (lSq > 1e-12 && rSq > 1e-12) ? (lr / sqrtf(lSq * rSq)) : 0.0

        snap.hasSignal = peak > 1e-4
        snap.inputPeakDBFS = Self.dbfs(peak)
        snap.inputRMSDBFS = Self.dbfs(rms)
        snap.pilotPresent = pilotMagMax > 1e-6
        snap.pilotPercent = peak > 1e-6 ? (pilotAmp / peak * 100.0) : 0.0
        snap.leftRMSDBFS = Self.dbfs(sqrtf(lSq / n))
        snap.rightRMSDBFS = Self.dbfs(sqrtf(rSq / n))
        snap.stereoCorrelation = corr
        snap.rdsLocked = rds.locked
        snap.rds = rds.state

        let deltaReceived = snap.rds.blocksReceived - prevBlocksReceived
        let deltaValid = snap.rds.blocksValid - prevBlocksValid
        if deltaReceived > 0 {
            let instant = Float(deltaReceived - deltaValid) / Float(deltaReceived)
            berEMA = (0.95 * berEMA) + (0.05 * instant)
            prevBlocksReceived = snap.rds.blocksReceived
            prevBlocksValid = snap.rds.blocksValid
        }
        snap.recentBlockErrorRate = berEMA
    }

    func snapshot() -> MeterSnapshot { snap }

    private static func dbfs(_ x: Float) -> Float { 20.0 * log10f(max(1e-6, x)) }
}
