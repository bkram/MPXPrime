import Testing
import Foundation
@testable import MPXPrime

/// The card-mixer arithmetic, tested on whatever platform this runs on: the
/// libasound binding itself is Linux-only, but the parts that can be wrong in
/// an interesting way -- which card a device string names, and how a percent
/// maps onto the control's own range -- are plain logic.
///
/// Why this exists at all: the ALSA mixer sits between the encoder and the
/// exciter, and it has cost this project real level twice (a mixer at zero
/// during the "stereo lamp but no RDS" hunt, and a stored level that came
/// back 2 dB down after a reboot).
@Suite("ALSA mixer math")
struct ALSAMixerMathTests {

    @Test func cardNameComesOutOfTheDeviceString() {
        #expect(ALSAMixerMath.cardName(fromDeviceUID: "hw:CARD=Device,DEV=0") == "Device")
        #expect(ALSAMixerMath.cardName(fromDeviceUID: "plughw:CARD=Loopback,DEV=1") == "Loopback")
        // The USB card name drifts between boots on this rig, so an index
        // suffix has to survive intact.
        #expect(ALSAMixerMath.cardName(fromDeviceUID: "hw:CARD=Device_1,DEV=0") == "Device_1")
        // No card in the string: there is no mixer to show.
        #expect(ALSAMixerMath.cardName(fromDeviceUID: "default") == nil)
        #expect(ALSAMixerMath.cardName(fromDeviceUID: "") == nil)
        #expect(ALSAMixerMath.cardName(fromDeviceUID: "hw:CARD=,DEV=0") == nil)
    }

    @Test func percentMatchesWhatAmixerReports() {
        // The rig's Headphone control is 0...45, and the two readings that
        // mattered in the field were 45 (100 %, 0 dB) and 43 (96 %, -2 dB).
        #expect(ALSAMixerMath.percent(value: 45, min: 0, max: 45) == 100.0)
        #expect(abs(ALSAMixerMath.percent(value: 43, min: 0, max: 45) - 95.55) < 0.01)
        #expect(ALSAMixerMath.percent(value: 0, min: 0, max: 45) == 0.0)
        // A control with no range cannot report a meaningful percent.
        #expect(ALSAMixerMath.percent(value: 7, min: 7, max: 7) == 0.0)
    }

    @Test func percentRoundTripsThroughTheRawValue() {
        for range in [(0, 45), (0, 25), (-10239, 400), (0, 65536)] {
            for pct in [0.0, 25.0, 50.0, 96.0, 100.0] {
                let raw = ALSAMixerMath.rawValue(percent: pct, min: range.0, max: range.1)
                #expect(raw >= range.0 && raw <= range.1, "raw \(raw) escaped \(range)")
                let back = ALSAMixerMath.percent(value: raw, min: range.0, max: range.1)
                // One raw step is the resolution floor, so allow it.
                let step = 100.0 / Double(range.1 - range.0)
                #expect(abs(back - pct) <= step, "\(pct) % -> \(raw) -> \(back) % on \(range)")
            }
        }
    }

    @Test func rawValueClampsInsteadOfEscapingTheRange() {
        // A slider cannot be talked into driving a control past its limits.
        #expect(ALSAMixerMath.rawValue(percent: 140, min: 0, max: 45) == 45)
        #expect(ALSAMixerMath.rawValue(percent: -20, min: 0, max: 45) == 0)
        #expect(ALSAMixerMath.rawValue(percent: 50, min: 7, max: 7) == 7)
    }
}
