import Testing
import Foundation
@testable import MPXPrime

// The multiband compressor's transient-aware detector holds a "drive" value
// for a short window after a percussive front so the attack stays stretched
// across the whole transient. Until 0.60 that hold was seeded from
// `transientDriveObserved`, a value that only ever increased: once a band
// had seen one loud transient, every later hold window started from that
// historical maximum, however long ago and however much quieter the
// programme had become. `AdvancedDynamicsLeveler` always had the intended
// shape -- a current hold that decays -- and `MonoCompressor` now matches it
// (0.60 audit, P0-3).
//
// The stage is `multiband_transient_aware_attack_enabled`, off by default,
// so no baseline moves; these tests are what keeps the shape correct.
@Suite("Transient hold expiry")
struct TransientHoldTests {

    private func configured(sampleRate: Float) -> MonoCompressor {
        var compressor = MonoCompressor()
        compressor.configure(
            sampleRate: sampleRate,
            thresholdDB: -24.0,
            ratio: 4.0,
            attackMS: 3.0,
            releaseMS: 180.0,
            makeupDB: 0.0,
            kneeDB: 1.0,
            transientAwareAttackEnabled: true
        )
        return compressor
    }

    private func bed(_ compressor: inout MonoCompressor, seconds: Double, sampleRate: Float) {
        let frames = Int(Double(sampleRate) * seconds)
        for i in 0..<frames {
            let tone = Float(0.32 * sin(2.0 * Double.pi * 220.0 * Double(i) / Double(sampleRate)))
            _ = compressor.process(tone)
        }
    }

    /// A 6 ms decaying hit with an instantaneous front -- a cosine, so the
    /// onset really is a transient. (A sine ramps up over a quarter period,
    /// by which time the RMS detector has caught up and the hold window
    /// never opens, which is why a sine cannot exercise this code at all.)
    /// Returns the peak the compressor let through and
    /// the largest hold value the detector reached while it played -- the
    /// hold decays inside the burst itself, so it has to be sampled there.
    @discardableResult
    private func burst(
        _ compressor: inout MonoCompressor, amplitude: Double, sampleRate: Float
    ) -> (peak: Float, hold: Float) {
        let frames = Int(Double(sampleRate) * 0.006)
        var peak: Float = 0.0
        var hold: Float = 0.0
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            let env = exp(-t / 0.004)
            let hit = Float(amplitude * cos(2.0 * Double.pi * 110.0 * t) * env)
            peak = max(peak, abs(compressor.process(hit)))
            hold = max(hold, compressor.transientHoldValue)
        }
        return (peak, hold)
    }

    // MARK: - The hold must track the transient that opened it

    /// The heart of P0-3. A bigger transient must open a bigger hold; the
    /// value is what stretches the attack, so a hold that ignores the
    /// programme makes the whole feature a constant.
    ///
    /// On the pre-0.60 code every one of these reads 0.94. The seed was
    /// `transientDriveObserved`, a running maximum, and that maximum reaches
    /// 1.0 within the first few samples after `configure` no matter what is
    /// playing: the RMS detector starts at zero, so the first non-silent
    /// sample has an unbounded peak-to-RMS ratio and saturates the drive.
    /// From then on every hold window opened at 0.94 -- the transient-aware
    /// attack was permanently at maximum rather than following the music.
    @Test func theHoldTracksTheSizeOfTheTransient() {
        let sr: Float = 48_000.0
        var holds: [Float] = []
        for amplitude in [0.6, 0.8, 0.95] {
            var compressor = configured(sampleRate: sr)
            bed(&compressor, seconds: 0.120, sampleRate: sr)
            holds.append(burst(&compressor, amplitude: amplitude, sampleRate: sr).hold)
        }
        #expect(holds[0] < holds[1] && holds[1] < holds[2],
                "hold values \(holds) do not increase with transient size")
        #expect(holds[2] - holds[0] > 0.2,
                "hold barely moves across a 4 dB range of transient size: \(holds)")
    }

    @Test func aModestTransientDoesNotOpenAMaximumHold() {
        let sr: Float = 48_000.0
        var compressor = configured(sampleRate: sr)
        bed(&compressor, seconds: 0.120, sampleRate: sr)
        let hit = burst(&compressor, amplitude: 0.6, sampleRate: sr)
        #expect(hit.hold > 0.05,
                "a 0.6 transient opened no hold window at all (\(hit.hold))")
        #expect(hit.hold < 0.5,
                """
                a modest transient opened a hold of \(hit.hold) -- at or near the \
                ceiling, which means the hold is not being sized by this transient
                """)
    }

    // MARK: - Expiry

    @Test func theHoldExpiresWhenTheProgrammeStopsProducingTransients() {
        let sr: Float = 48_000.0
        var compressor = configured(sampleRate: sr)
        bed(&compressor, seconds: 0.120, sampleRate: sr)
        let loud = burst(&compressor, amplitude: 0.95, sampleRate: sr)
        #expect(loud.hold > 0.5,
                "the burst did not open a hold window at all (hold reached \(loud.hold))")
        // The window is 10 ms and the value decays inside it; 300 ms of
        // steady programme later there must be nothing left of it.
        bed(&compressor, seconds: 0.300, sampleRate: sr)
        #expect(compressor.transientHoldValue < 0.01,
                "the hold is still \(compressor.transientHoldValue) after 300 ms of steady programme")
    }

    @Test func repeatedIdenticalBurstsAreHandledIdentically() {
        let sr: Float = 48_000.0
        var compressor = configured(sampleRate: sr)
        bed(&compressor, seconds: 0.120, sampleRate: sr)
        var peaks: [Float] = []
        for _ in 0..<4 {
            peaks.append(burst(&compressor, amplitude: 0.8, sampleRate: sr).peak)
            bed(&compressor, seconds: 0.300, sampleRate: sr)
        }
        // Some settling between the first and the rest is legitimate (the
        // GR smoother is slower than the hold); what must not happen is a
        // drift that tracks the running maximum.
        let last = peaks[3]
        let second = peaks[1]
        let deltaDB = 20.0 * log10(max(last, 1e-9) / max(second, 1e-9))
        #expect(abs(deltaDB) < 0.20,
                "identical bursts drift by \(deltaDB) dB across a sequence")
    }

    // MARK: - Rate invariance

    @Test func theHoldBehavesTheSameAtEveryRate() {
        // The decay used to be a fixed 0.94 per sample, i.e. 0.34 ms at the
        // 48 kHz audio domain but 0.08 ms with the dual-rate boundary off.
        // It is a time constant now, so the same programme must be handled
        // the same way at any rate.
        var peaks: [Float] = []
        for sr in [Float(48_000.0), Float(96_000.0), Float(192_000.0)] {
            var compressor = configured(sampleRate: sr)
            bed(&compressor, seconds: 0.120, sampleRate: sr)
            burst(&compressor, amplitude: 0.95, sampleRate: sr)
            bed(&compressor, seconds: 0.020, sampleRate: sr)
            peaks.append(burst(&compressor, amplitude: 0.6, sampleRate: sr).peak)
        }
        for (i, sr) in [48_000, 96_000, 192_000].enumerated() where i > 0 {
            let deltaDB = 20.0 * log10(max(peaks[i], 1e-9) / max(peaks[0], 1e-9))
            #expect(abs(deltaDB) < 0.35,
                    "\(sr) Hz handles the same transient \(deltaDB) dB differently from 48 kHz")
        }
    }
}
