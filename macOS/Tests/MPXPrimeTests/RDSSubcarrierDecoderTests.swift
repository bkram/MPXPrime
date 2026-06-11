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
    private func renderComposite(_ coder: BasicRDSCoder, seconds: Double) -> [Float] {
        let count = Int(Double(sampleRate) * seconds)
        var out = [Float](repeating: 0.0, count: count)
        let pilotAmp: Float = 0.09
        let twoPi = Float.pi * 2.0
        let pilotStep = twoPi * 19_000.0 / sampleRate
        let audioStep = twoPi * 1_000.0 / sampleRate
        var pilotPhase: Float = 0.0
        var audioPhase: Float = 0.0
        for i in 0..<count {
            let pilotSin = sinf(pilotPhase)
            coder.updateRDSPilotSin(pilotSin)
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

    @Test func reportsNoLockOnSilence() {
        // No pilot, no RDS: the front-end must not claim lock or sync.
        let decoder = RDSSubcarrierDecoder(sampleRate: sampleRate)
        decoder.process([Float](repeating: 0.0, count: Int(sampleRate)))
        #expect(!decoder.locked)
        #expect(!decoder.state.synced)
    }
}
