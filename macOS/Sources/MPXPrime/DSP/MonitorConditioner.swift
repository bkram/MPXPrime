#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

/// Turns the feed a mode produces into something an operator can LISTEN to on
/// the monitor device, and applies the monitor level.
///
/// The monitor is a listening aid, never the on-air signal, so each mode is
/// conditioned to sound like what the receiving end will hear:
///
/// | Mode | Feed on the wire | What the monitor plays |
/// | --- | --- | --- |
/// | `mpx` | FM composite | the composite demodulated like a receiver (done in `MPXGenerator`; nothing to do here) |
/// | `fm` | processed L/R, pre-emphasised if the operator chose to apply it | the same, with pre-emphasis REMOVED -- a coder feeds a transmitter whose receivers de-emphasise |
/// | `hd` | flat, full-bandwidth L/R | the same; nothing to undo |
/// | `am` | mono, NRSC pre-emphasised | the same, with the NRSC curve removed |
///
/// `DeemphasisFilter` is the exact algebraic inverse of the encoder's
/// pre-emphasis network (`PreemphasisDesign`), so the un-emphasis is correct
/// rather than approximate, and it self-disables at 0 us.
///
/// Real-time safe: biquads and vDSP over caller-owned buffers, no allocation.
struct MonitorConditioner {

    /// What has to be undone for this mode, decided once at configure time.
    enum Shape: Equatable {
        /// The generator already produced decoded audio (MPX Output).
        case decodedComposite
        /// Remove a pre-emphasis curve of `tauUS` microseconds.
        case deemphasised(tauUS: Int)
        /// Pass through unchanged.
        case flat
    }

    private(set) var shape: Shape = .flat
    /// Linear monitor level (`monitor_gain_db`).
    var gainLinear: Float = 1.0

    private var deemphL = DeemphasisFilter()
    private var deemphR = DeemphasisFilter()

    /// The shape a mode needs. `hd` is flat by construction (the digital
    /// target forces pre-emphasis off), so it stays flat whatever
    /// `preemphasis_us` still says in the INI.
    static func shape(for mode: AppConfig.OperatingMode, config: AppConfig) -> Shape {
        switch mode {
        case .mpx: return .decodedComposite
        case .fm: return config.preemphasisUS > 0 ? .deemphasised(tauUS: config.preemphasisUS) : .flat
        case .hd: return .flat
        case .am: return config.amPreemphasisUS > 0 ? .deemphasised(tauUS: config.amPreemphasisUS) : .flat
        }
    }

    mutating func configure(shape: Shape, sampleRate: Float, gainDB: Double) {
        self.shape = shape
        self.gainLinear = powf(10.0, Float(gainDB) / 20.0)
        switch shape {
        case .deemphasised(let tauUS):
            deemphL.configure(tauUS: tauUS, sampleRate: sampleRate)
            deemphR.configure(tauUS: tauUS, sampleRate: sampleRate)
        case .decodedComposite, .flat:
            deemphL.configure(tauUS: 0, sampleRate: sampleRate)
            deemphR.configure(tauUS: 0, sampleRate: sampleRate)
        }
    }

    mutating func reset() {
        deemphL.reset()
        deemphR.reset()
    }

    /// Condition one block in place.
    mutating func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        if case .deemphasised = shape {
            for i in 0..<frameCount {
                left[i] = deemphL.process(left[i])
                right[i] = deemphR.process(right[i])
            }
        }
        guard gainLinear != 1.0 else { return }
        var g = gainLinear
        vDSP_vsmul(left, 1, &g, left, 1, vDSP_Length(frameCount))
        vDSP_vsmul(right, 1, &g, right, 1, vDSP_Length(frameCount))
        if g > 1.0 {
            // A boosted monitor must not hand the converter something it will
            // fold over; clamp here where it is deterministic.
            var lo: Float = -1.0
            var hi: Float = 1.0
            vDSP_vclip(left, 1, &lo, &hi, left, 1, vDSP_Length(frameCount))
            vDSP_vclip(right, 1, &lo, &hi, right, 1, vDSP_Length(frameCount))
        }
    }
}
