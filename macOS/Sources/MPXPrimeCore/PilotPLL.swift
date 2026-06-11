import Darwin
import Foundation

/// Lightweight 19 kHz pilot lock-in for receive-side coherent demodulation.
///
/// This is the same I/Q lock-in math `MPXDecoder` uses internally to recover
/// the 38 kHz stereo subcarrier, factored into a standalone primitive so the
/// RDS subcarrier front-end (and any future coherent demod) can share one
/// pilot reference. `MPXDecoder` deliberately keeps its own copy unchanged so
/// its verified, baseline-pinned output is not perturbed; consolidating the
/// two is a possible later cleanup.
///
/// Model: a free-running local oscillator advances at exactly 19 kHz. The
/// composite's pilot, `A*sin(p)`, is correlated against the local
/// `sin(theta)` / `cos(theta)`; the smoothed correlations are
/// `I ~ cos(phi)` and `Q ~ sin(phi)` where `phi = p - theta` is the constant
/// phase offset (constant because, for a clean signal, the pilot frequency
/// matches the local oscillator exactly). The recovered pilot phase is then
/// `p = theta + phi`, from which `sin(p)` and `cos(p)` follow by angle
/// addition. RDS needs `sin(3p)` (57 kHz = 3x pilot), obtained from `sin(p)`
/// via the triple-angle identity at the call site.
///
/// Not thread-safe; drive from one consumer.
public struct PilotPLL {
    @usableFromInline static let pilotHz: Float = 19_000.0

    @usableFromInline var sampleRate: Float = 192_000.0
    @usableFromInline var pllPhase: Float = 0.0
    @usableFromInline var pllStep: Float = 0.0
    @usableFromInline var lockI: Float = 0.0
    @usableFromInline var lockQ: Float = 0.0
    @usableFromInline var lockCoeff: Float = 0.0

    public init() {}

    public mutating func configure(sampleRate: Float) {
        let sr = max(8_000.0, sampleRate)
        self.sampleRate = sr
        pllPhase = 0.0
        pllStep = (Float.pi * 2.0 * Self.pilotHz) / sr
        lockI = 0.0
        lockQ = 0.0
        // 20 ms lock-in time constant, matching MPXDecoder.
        lockCoeff = expf(-1.0 / (0.020 * sr))
    }

    /// Magnitude-squared of the lock-in correlation. Proportional to the
    /// squared pilot amplitude once converged; a coarse lock indicator.
    @inlinable
    public var lockMagnitudeSquared: Float { (lockI * lockI) + (lockQ * lockQ) }

    /// Advance one sample. Returns the recovered pilot `sin(p)` and `cos(p)`
    /// plus the lock magnitude-squared. Until the lock-in converges
    /// (~20 ms) and while the pilot is absent, the returned phase is
    /// meaningless and `mag2` is near zero.
    @inlinable
    @inline(__always)
    public mutating func process(_ mpx: Float) -> (sinP: Float, cosP: Float, mag2: Float) {
        let oscSin = sinf(pllPhase)
        let oscCos = cosf(pllPhase)
        lockI = zapDenorm((lockCoeff * lockI) + ((1.0 - lockCoeff) * (mpx * oscSin)))
        lockQ = zapDenorm((lockCoeff * lockQ) + ((1.0 - lockCoeff) * (mpx * oscCos)))

        let mag2 = (lockI * lockI) + (lockQ * lockQ)
        var sinP: Float = 0.0
        var cosP: Float = 1.0
        if mag2 > 1e-9 {
            let invMag = 1.0 / sqrtf(mag2)
            let cosPhi = lockI * invMag   // ~cos(phi)
            let sinPhi = lockQ * invMag   // ~sin(phi)
            // p = theta + phi
            sinP = (oscSin * cosPhi) + (oscCos * sinPhi)
            cosP = (oscCos * cosPhi) - (oscSin * sinPhi)
        }

        pllPhase += pllStep
        if pllPhase >= (Float.pi * 2.0) {
            pllPhase -= Float.pi * 2.0
        } else if pllPhase < 0.0 {
            pllPhase += Float.pi * 2.0
        }
        return (sinP, cosP, mag2)
    }
}
