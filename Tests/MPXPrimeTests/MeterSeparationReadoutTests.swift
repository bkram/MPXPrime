import Foundation
import MPXPrimeCore
import Testing

// The Meter's SEPARATION readout is 20*log10(stronger / weaker decoded
// channel): an L/R imbalance that only means separation on single-channel
// content. Since the 2026-10-20 stereo audit `MeterAnalysis` publishes it
// only while the decoded side / mid ratio is within 10 % of 1.0, so panned
// programme with mono bass (bass in both channels) and anti-phase-leaning
// width no longer read as a separation loss. These tests pin that gate with
// synthesised composites of exactly known content.

private let sr: Float = 192_000.0
private let fullScale: Float = 150.0  // amplitude 1.0 == 150 kHz deviation
private let blockLen = 8192

/// Standard composite for stereo (left, right) at sample index `i`:
/// M + S sin(2 theta) + pilot sin(theta), the encoder's and the verifier's
/// convention. 0.5 keeps a full-scale audio pair at 75 kHz of the 150 kHz
/// full scale; pilot at 9 % of 75 kHz.
private func composite(_ i: Int, left: Double, right: Double) -> Float {
    let theta = 2.0 * Double.pi * 19_000.0 * Double(i) / Double(sr)
    let mid = 0.5 * (left + right)
    let side = 0.5 * (left - right)
    return Float(0.5 * (mid + (side * sin(2.0 * theta)) + (0.09 * sin(theta))))
}

private func tone(_ hz: Double, _ i: Int) -> Double {
    sin(2.0 * Double.pi * hz * Double(i) / Double(sr))
}

/// Feed `seconds` of a stereo source through the analysis in engine-sized
/// blocks; `offset` continues a previous feed's sample index.
private func feed(
    _ analysis: MeterAnalysis, seconds: Float, offset: Int = 0,
    _ source: (Int) -> (Double, Double)
) -> Int {
    let total = Int(seconds * sr)
    var block = [Float](repeating: 0.0, count: blockLen)
    var t0 = 0
    while t0 < total {
        let n = min(blockLen, total - t0)
        for i in 0..<n {
            let (l, r) = source(offset + t0 + i)
            block[i] = composite(offset + t0 + i, left: l, right: r)
        }
        block.withUnsafeBufferPointer {
            analysis.process(UnsafeBufferPointer(rebasing: $0[0..<n]))
        }
        t0 += n
    }
    return offset + total
}

/// Hard-panned tone: left only.
private func hardPannedTone(_ i: Int) -> (Double, Double) {
    (0.7 * tone(1_000.0, i), 0.0)
}

/// Panned programme with mono bass: the body and presence of the programme
/// are left only, the 55 Hz bass sits in both channels (what the mono-bass
/// stage does below its corner). Decoded S/M is about 0.4.
private func pannedProgrammeWithMonoBass(_ i: Int) -> (Double, Double) {
    let bass = 0.35 * tone(55.0, i)
    let body = 0.30 * tone(880.0, i)
    let presence = 0.12 * tone(3_200.0, i)
    return (bass + body + presence, bass)
}

/// Anti-phase-leaning width: R = -0.5 L, S/M = 3. The L/R imbalance is 6 dB
/// and is not a separation figure.
private func antiPhaseLeaningWidth(_ i: Int) -> (Double, Double) {
    let t = 0.5 * tone(1_000.0, i)
    return (t, -0.5 * t)
}

@Suite("Meter SEPARATION readout validity gate")
struct MeterSeparationReadoutTests {
    @Test func hardPannedToneReadsAValidSeparationOfAtLeast50dB() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        _ = feed(a, seconds: 3.0, hardPannedTone)
        let s = a.snapshot()
        #expect(s.stereoDecodeActive, "fixture problem: the pilot did not lock")
        #expect(s.separationValid, "a left-only tone is the one content the readout is for")
        #expect(s.bestSeparationDB >= 50.0, "left-only 1 kHz read \(s.bestSeparationDB) dB")
    }

    @Test func pannedProgrammeWithMonoBassGivesNoValidReading() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        _ = feed(a, seconds: 3.0, pannedProgrammeWithMonoBass)
        let s = a.snapshot()
        #expect(s.stereoDecodeActive, "fixture problem: the pilot did not lock")
        // The old readout published 20*log10(L / R) here: about 3 dB,
        // presented as "separation" -- the audit's Meter finding.
        #expect(!s.separationValid,
            "panned programme with mono bass must not publish an imbalance of \(s.bestSeparationDB) dB as separation")
        #expect(s.leftRMSDBFS > s.rightRMSDBFS, "fixture problem: the programme is not panned left")
    }

    @Test func antiPhaseLeaningWidthGivesNoValidReading() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        _ = feed(a, seconds: 3.0, antiPhaseLeaningWidth)
        let s = a.snapshot()
        #expect(s.stereoDecodeActive, "fixture problem: the pilot did not lock")
        #expect(!s.separationValid, "S/M = 3 is width, not single-channel content")
    }

    @Test func heldValueSurvivesProgrammeButIsFlaggedInvalid() {
        let a = MeterAnalysis(sampleRate: sr, fullScaleKHz: fullScale)
        let next = feed(a, seconds: 3.0, hardPannedTone)
        let afterTone = a.snapshot()
        #expect(afterTone.separationValid)
        let held = afterTone.bestSeparationDB
        _ = feed(a, seconds: 1.0, offset: next, pannedProgrammeWithMonoBass)
        let s = a.snapshot()
        #expect(!s.separationValid, "the current block is not single-channel content")
        #expect(s.bestSeparationDB == held, "the held value must survive (\(s.bestSeparationDB) vs \(held))")
    }
}
