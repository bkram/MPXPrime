import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// Integrity of the Meter's PLL stereo decode (0.45 audit, P1.3). Two defects
// pinned here:
//  - M1: the pilot-lock gate was an ABSOLUTE `mag2 > 1e-4` (pilot amplitude
//    0.02 in raw units), 20 dB above the Meter's own pilot-present threshold,
//    so a composite patched in at -20 dBFS (or a weak SDR station) silently
//    decoded MONO while PILOT read present. The gate is now relative to the
//    input level, and `stereoDecodeActive` says when stereo decode is off.
//  - M2: the 38 kHz recovery had no frequency tracking -- a pilot offset
//    (capture-clock ppm, transmitter tolerance) left a lock-in phase lag of
//    atan(2 pi df tau), doubled at 38 kHz: an untrimmed RTL dongle (100 ppm)
//    capped decoded separation at ~25 dB. The loop now pulls the NCO onto
//    the pilot frequency.

@Suite("Meter PLL decode integrity")
struct MeterDecodeIntegrityTests {

    private let sampleRate: Float = 192_000.0

    /// Standard composite, left-only 1 kHz tone, with the WHOLE broadcast
    /// (pilot + subcarrier, phase-locked) offset by `ppm` -- the capture-clock
    /// error model -- and the composite scaled by `level`.
    private func composite(ppm: Double, level: Double, frames: Int) -> [Float] {
        let scale = 1.0 + ppm * 1e-6
        let wt = 2.0 * Double.pi * 1_000.0 / Double(sampleRate)
        let wp = 2.0 * Double.pi * 19_000.0 * scale / Double(sampleRate)
        var out = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let l = 0.8 * sin(wt * Double(i))
            let m = l * 0.5
            let s = l * 0.5
            let theta = wp * Double(i)
            out[i] = Float(level * (m + (s * sin(2.0 * theta)) + (0.09 * sin(theta))))
        }
        return out
    }

    /// PLL-decode and return (separationDB, stereoDecodeActive) over the tail.
    private func pllSeparation(_ mpx: [Float]) -> (sepDB: Double, active: Bool) {
        var decoder = MPXDecoder()
        decoder.configure(sampleRate: sampleRate, preemphasisUS: 50)
        let start = mpx.count - Int(0.5 * sampleRate)
        var lAcc = 0.0
        var rAcc = 0.0
        for i in 0..<mpx.count {
            let d = decoder.process(mpx[i], referenceSubcarrier: nil, programActivity: 0.4, expectedSide: 0.0)
            if i >= start {
                lAcc += Double(d.0 * d.0)
                rAcc += Double(d.1 * d.1)
            }
        }
        let sep = 10.0 * log10(max(lAcc, 1e-20) / max(rAcc, 1e-20))
        return (sep, decoder.stereoDecodeActive)
    }

    @Test(arguments: [0.0, 25.0, 100.0])
    func pilotFrequencyOffsetDoesNotCapSeparation(_ ppm: Double) {
        // 2.5 s: the ~2 Hz PLL needs ~0.5 s to pull in; measure the last 0.5 s.
        let mpx = composite(ppm: ppm, level: 1.0, frames: Int(2.5 * sampleRate))
        let r = pllSeparation(mpx)
        print(String(format: "PLL separation at %+.0f ppm pilot offset: %.1f dB", ppm, r.sepDB))
        #expect(r.active)
        // Measured A/B with the frequency tracking disabled (2026-08-31):
        // 64.4 dB on frequency, 47.7 dB at 25 ppm, 24.8 dB at 100 ppm. With
        // the loop closed all three read 64.4 dB -- the offset no longer
        // limits separation at all. The old absolute pilot gate (1e-4, i.e.
        // pilot amplitude 0.02) would also have decoded the 0.05-level case
        // as mono: its pilot amplitude is 0.0045.
        #expect(r.sepDB > 40.0, "\(Int(ppm)) ppm capped separation at \(r.sepDB) dB")
    }

    @Test func lowLevelCompositeStillDecodesStereo() {
        // Composite at 0.05 absolute: pilot amplitude 0.0045 -- far below the
        // old absolute gate (0.02) that silently decoded this as mono.
        let mpx = composite(ppm: 0.0, level: 0.05, frames: Int(2.0 * sampleRate))
        let r = pllSeparation(mpx)
        print(String(format: "PLL separation at 0.05 absolute level: %.1f dB", r.sepDB))
        #expect(r.active, "a clean composite at -26 dBFS must decode stereo")
        #expect(r.sepDB > 30.0)
    }

    @Test func silenceReportsStereoDecodeInactive() {
        let mpx = [Float](repeating: 0.0, count: Int(0.5 * sampleRate))
        let r = pllSeparation(mpx)
        #expect(!r.active, "silence must not claim an active stereo decode")
        #expect(r.sepDB.isFinite)
    }

    @Test func subNyquistRateDisablesStereoDecode() {
        // 48 kHz cannot represent the 38 kHz subcarrier; the decoder must
        // decode M-only with the flag off instead of demodulating aliases.
        var decoder = MPXDecoder()
        decoder.configure(sampleRate: 48_000.0, preemphasisUS: 50)
        var maxDiff: Float = 0.0
        for i in 0..<24_000 {
            let x = Float(0.5 * sin(2.0 * Double.pi * 1_000.0 * Double(i) / 48_000.0))
            let d = decoder.process(x, referenceSubcarrier: nil, programActivity: 0.4, expectedSide: 0.0)
            maxDiff = max(maxDiff, abs(d.0 - d.1))
        }
        #expect(!decoder.stereoDecodeActive)
        #expect(maxDiff < 1e-6, "sub-Nyquist decode must be exactly M on both channels")
    }
}
