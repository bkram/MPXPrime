import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// Full RDS receive-chain round-trip: render a composite with a known RDS
// payload using the transmit-side BasicRDSCoder subcarrier generator (pilot +
// coherent 57 kHz RDS, exactly as the air chain emits it), then recover the
// data with the new MPXPrimeCore front-end:
//
//   composite samples -> RDSSubcarrierDecoder (pilot lock, 57 kHz coherent
//   demod, biphase matched filter, bit-phase acquisition, differential decode)
//   -> RDSStreamDecoder -> PI / PS / PTY / TP / TA / MS.
//
// This is the gate for Phase 1 (the missing subcarrier front-end): if the
// decoder recovers the encoder's fields with a near-zero block-error rate, the
// two halves agree end to end on carrier lock, biphase shaping, differential
// coding, and bit timing.

@Suite("RDS subcarrier decoder")
struct RDSSubcarrierDecoderTests {

    private let sampleRate: Float = 192_000.0

    private func makeConfig(
        piHex: String = "1234",
        pty: Int = 15,
        tp: Bool = true,
        ta: Bool = true,
        ms: Bool = true,
        ps: String = "HELLO"
    ) -> AppConfig {
        var cfg = AppConfig()
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsPI = piHex
        cfg.rdsPTY = pty
        cfg.rdsTP = tp
        cfg.rdsTA = ta
        cfg.rdsMS = ms
        cfg.rdsPSA = ps
        cfg.rdsPSActiveBank = "A"
        return cfg
    }

    /// Render a mono composite: baseband audio (proves the front-end rejects
    /// non-RDS content) + 19 kHz pilot + the coherent 57 kHz RDS subcarrier.
    /// RDS is locked to 3x the pilot via `updateRDSPilotSin` +
    /// `nextSampleWithPilotLock`, mirroring the production render path.
    ///
    /// `rdsCarrierPhaseDeg` rotates the RDS carrier relative to sin(3p) by
    /// feeding the coder a phase-shifted pilot (sin(p + deg/3) -> carrier
    /// sin(3p + deg)) while the emitted pilot stays sin(p). EN 50067 allows
    /// in-phase OR quadrature lock, and tuner MPX filtering adds arbitrary
    /// rotation on top -- the decoder must recover any axis.
    private func renderComposite(
        _ coder: BasicRDSCoder, seconds: Double, rdsCarrierPhaseDeg: Float = 0.0
    ) -> [Float] {
        let count = Int(Double(sampleRate) * seconds)
        var out = [Float](repeating: 0.0, count: count)
        let pilotAmp: Float = 0.09
        let twoPi = Float.pi * 2.0
        let pilotStep = twoPi * 19_000.0 / sampleRate
        let audioStep = twoPi * 1_000.0 / sampleRate
        let pilotDelta = (rdsCarrierPhaseDeg / 3.0) * Float.pi / 180.0
        var pilotPhase: Float = 0.0
        var audioPhase: Float = 0.0
        for i in 0..<count {
            let pilotSin = sinf(pilotPhase)
            coder.updateRDSPilotSin(pilotDelta == 0.0 ? pilotSin : sinf(pilotPhase + pilotDelta))
            let rds = coder.nextSampleWithPilotLock()
            let audio: Float = 0.30 * sinf(audioPhase)
            out[i] = audio + (pilotAmp * pilotSin) + rds

            pilotPhase += pilotStep
            if pilotPhase >= twoPi { pilotPhase -= twoPi }
            audioPhase += audioStep
            if audioPhase >= twoPi { audioPhase -= twoPi }
        }
        return out
    }

    @Test func recoversFieldsFromCleanComposite() {
        let coder = BasicRDSCoder(config: makeConfig(), sampleRate: sampleRate)
        let composite = renderComposite(coder, seconds: 2.5)

        let decoder = RDSSubcarrierDecoder(sampleRate: sampleRate)
        decoder.process(composite)

        let state = decoder.state
        #expect(decoder.locked, "front-end did not finish acquisition / lock")
        #expect(state.synced, "stream decoder failed to acquire block sync")
        #expect(state.pi == 0x1234)
        #expect(state.pty == 15)
        #expect(state.tp == true)
        #expect(state.ta == true)
        #expect(state.ms == true)
        // "HELLO" centered in 8 chars (default rdsPSCentered = true) -> " HELLO  ".
        #expect(state.programService == " HELLO  ", "PS was '\(state.programService)'")
        // Coherent, clean composite: once locked the block-error rate should be
        // tiny (only the acquisition transient contributes).
        #expect(state.blockErrorRate < 0.05,
                "block error rate \(state.blockErrorRate) too high on a clean composite")
        #expect(state.groupsDecoded >= 10,
                "expected many groups over 2.5 s, got \(state.groupsDecoded)")
    }

    @Test func recoversDistinctPayload() {
        // A second PI/PS to prove we are decoding the payload, not constants.
        let coder = BasicRDSCoder(
            config: makeConfig(piHex: "ABCD", pty: 10, ps: "JAZZ"),
            sampleRate: sampleRate)
        let composite = renderComposite(coder, seconds: 2.5)

        let decoder = RDSSubcarrierDecoder(sampleRate: sampleRate)
        decoder.process(composite)

        let state = decoder.state
        #expect(state.synced)
        #expect(state.pi == 0xABCD)
        #expect(state.pty == 10)
        // "JAZZ" centered in 8 chars -> "  JAZZ  ".
        #expect(state.programService == "  JAZZ  ", "PS was '\(state.programService)'")
    }

    /// Linear-resample to simulate the receiver's sample clock differing from
    /// the broadcast clock by `ratio` (a uniform frequency offset on pilot,
    /// stereo, RDS, and bit clock together).
    private func resample(_ x: [Float], ratio: Double) -> [Float] {
        guard ratio > 0, x.count > 1 else { return x }
        let outCount = Int(Double(x.count) / ratio)
        var out = [Float](repeating: 0.0, count: outCount)
        for m in 0..<outCount {
            let pos = Double(m) * ratio
            let i0 = Int(pos)
            if i0 + 1 >= x.count { out[m] = x[x.count - 1]; continue }
            let frac = Float(pos - Double(i0))
            out[m] = (x[i0] * (1.0 - frac)) + (x[i0 + 1] * frac)
        }
        return out
    }

    @Test(arguments: [0.9994, 1.0006])
    func tracksSampleClockOffset(ratio: Double) {
        // ~600 ppm offset over 3 s drifts the bit clock by ~2 bits -- a
        // fixed-rate clock would slip and burst block errors. The Gardner
        // timing loop must follow it and keep decoding.
        let coder = BasicRDSCoder(config: makeConfig(), sampleRate: sampleRate)
        let composite = renderComposite(coder, seconds: 3.0)
        let offset = resample(composite, ratio: ratio)

        let decoder = RDSSubcarrierDecoder(sampleRate: sampleRate)
        decoder.process(offset)

        let state = decoder.state
        #expect(state.synced, "lost sync under \(ratio) clock offset")
        #expect(state.pi == 0x1234, "PI lost under \(ratio) clock offset")
        #expect(state.programService == " HELLO  ",
                "PS '\(state.programService)' under \(ratio) clock offset")
        #expect(state.blockErrorRate < 0.12,
                "BER \(state.blockErrorRate) too high under \(ratio) clock offset")
    }

    @Test(arguments: [Float(90.0), Float(45.0), Float(150.0)])
    func recoversArbitraryCarrierPhase(phaseDeg: Float) {
        // 90 deg is the EN 50067-permitted quadrature lock (a single-axis
        // sin(3p) demod gets ~zero signal); 45/150 deg model the arbitrary
        // extra rotation a tuner's MPX output filtering applies at 57 kHz.
        let coder = BasicRDSCoder(config: makeConfig(), sampleRate: sampleRate)
        let composite = renderComposite(coder, seconds: 2.5, rdsCarrierPhaseDeg: phaseDeg)

        let decoder = RDSSubcarrierDecoder(sampleRate: sampleRate)
        decoder.process(composite)

        let state = decoder.state
        #expect(state.synced, "no block sync at carrier phase \(phaseDeg) deg")
        #expect(state.pi == 0x1234, "PI lost at carrier phase \(phaseDeg) deg")
        #expect(state.programService == " HELLO  ",
                "PS '\(state.programService)' at carrier phase \(phaseDeg) deg")
        #expect(state.blockErrorRate < 0.10,
                "BER \(state.blockErrorRate) at carrier phase \(phaseDeg) deg")
    }

    @Test func reportsNoLockOnSilence() {
        // No pilot, no RDS: the front-end must not claim lock or sync.
        let decoder = RDSSubcarrierDecoder(sampleRate: sampleRate)
        decoder.process([Float](repeating: 0.0, count: Int(sampleRate)))
        #expect(!decoder.locked)
        #expect(!decoder.state.synced)
    }
}
