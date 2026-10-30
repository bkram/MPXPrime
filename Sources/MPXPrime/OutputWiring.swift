import Atomics
import Foundation

/// The output-side decisions both audio engines make -- `AudioOutputEngine`
/// (macOS) and `ALSAAudioEngine` (Linux) -- as pure functions they both call,
/// so a test can run the production line instead of re-deriving it
/// (test-suite review 2026-10 finding 10). Before this, each engine
/// held its own copy of every formula and the tests computed the same
/// algebra themselves: a sign flip in the deviation scale, a line trim
/// applied outside composite mode, or a deleted monitor seed left the suite
/// green. `RobustnessOutputWiringTests` pins each one, and each test was
/// shown to fail under its mutation.
enum OutputWiring {

    /// Factor that takes the METERED composite peak back to the modulation
    /// domain for the deviation readout. The composite is metered after
    /// `output_gain_db`, so the trim is divided back out, or the readout
    /// under-reads by exactly that trim (field-measured: 30.2 kHz displayed
    /// against about 75 kHz on air at -7.89 dB). Composite mode only:
    /// processed audio has no deviation, and the scale is 1 there.
    static func modulationReferenceScale(outputGainDB: Float, mode: AudioOutputMode) -> Float {
        mode == .mpxComposite ? powf(10.0, -outputGainDB / 20.0) : 1.0
    }

    /// Linear scale of the composite line-output trim
    /// (`mpx_line_output_dbfs`). It applies in composite mode only, at the
    /// DAC write -- after every meter and scope capture, on the live-input
    /// AND the test-tone path -- and is exactly 1 everywhere else, so a
    /// caller that applies it unconditionally is still right. 0 dBFS gives
    /// exactly 1.0, which the macOS render path skips to stay bit-identical.
    static func lineOutputScale(lineOutputDBFS: Float, mode: AudioOutputMode) -> Float {
        mode == .mpxComposite ? powf(10.0, lineOutputDBFS / 20.0) : 1.0
    }

    /// The DAC Peak readout: the composite-domain peak times the line scale
    /// actually applied at the DAC, so the readout and the trim cannot
    /// disagree.
    static func dacPeak(compositePeak: Float, lineOutputScale: Float) -> Float {
        compositePeak * lineOutputScale
    }

    /// Bit pattern a monitor player publishes for a level change. The
    /// players hold the level in a `ManagedAtomic<UInt32>` that the audio
    /// thread adopts at its next block.
    static func monitorGainBitPattern(gainDB: Double) -> UInt32 {
        powf(10.0, Float(gainDB) / 20.0).bitPattern
    }

    /// Configure a monitor conditioner for a run AND seed the player's
    /// pending-gain atomic with the configured level, in one call. The
    /// atomics default to unity, so a player that configured the
    /// conditioner but skipped the seed faded a monitor configured at, say,
    /// -12 dB up to 0 dB over its first block and kept it there until the
    /// next control change. Binding the seed to the configure means an
    /// engine cannot do one without the other.
    static func configureMonitor(
        _ conditioner: inout MonitorConditioner,
        shape: MonitorConditioner.Shape,
        sampleRate: Float,
        gainDB: Double,
        pendingGain: ManagedAtomic<UInt32>
    ) {
        conditioner.configure(shape: shape, sampleRate: sampleRate, gainDB: gainDB)
        conditioner.reset()
        pendingGain.store(conditioner.publishedGainBitPattern, ordering: .relaxed)
    }
}
