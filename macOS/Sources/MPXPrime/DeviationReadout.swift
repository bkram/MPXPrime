import Foundation

/// The deviation readout's one rule, shared by both engines.
///
/// The generator scales the WHOLE composite -- subcarriers included -- by
/// `mpx_deviation_khz / 75`, so composite amplitude 1.0 is 75 kHz whatever
/// the configured deviation is (that is what keeps pilot injection at 9 % of
/// the chosen deviation: pilot amplitude 0.09 at 75 kHz, 0.06 at 50 kHz).
/// A kHz figure therefore multiplies a composite peak by 75 -- never by the
/// configured deviation. Both engines did the latter until 0.60: exact at
/// the default, so nobody saw it, and 33 kHz for full modulation at a
/// 50 kHz setting. `modulationReferenceScale` divides `output_gain_db` back
/// out so the figure is in the modulation domain, not the electrical one.
enum DeviationReadout {
    static func kilohertz(compositePeak: Float, modulationReferenceScale: Float) -> Float {
        compositePeak * MPXGenerator.referenceDeviationKHz * modulationReferenceScale
    }
}
