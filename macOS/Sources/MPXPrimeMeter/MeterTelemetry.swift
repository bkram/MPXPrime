import Foundation
import Observation
import SwiftUI

// Per-tick monitoring values for the Meter window. Lives on its OWN observable
// object (not the view model) so a 25 Hz refresh repaints only the Canvas
// leaves wrapped in `LiveObservationView`, never the whole window -- the
// freeze-prevention rule. The view model holds only structural + slow (RDS)
// state and is not invalidated per tick.
//
// Uses the @Observable macro (per-property tracking), NOT ObservableObject/
// @Published: profiling a long SDR session showed SwiftUI's dependency
// tracking for the ObservableObject bridge accumulating (ObservationRegistrar
// AnyKeyPath-set hashing grew from ~36% to ~87% process CPU over 14 minutes),
// which degraded the GUI and starved the audio thread until a fresh launch.
// With @Observable, a tick re-evaluates only the leaves whose read properties
// actually changed, and the per-tick tracking cost stays flat.
@Observable
final class MeterTelemetry {
    // Levels: normalized 0..1 (dBFS -36..0) + display strings.
    var inputNorm: Double = 0
    var inputText = "-inf"
    var leftNorm: Double = 0
    var leftText = "-inf"
    var rightNorm: Double = 0
    var rightText = "-inf"
    var midNorm: Double = 0
    var midText = "-inf"
    var sideNorm: Double = 0
    var sideText = "-inf"
    var correlation: Double = 1
    var correlationText = "+1.00"

    // Deviation: normalized 0..1 (0..100 kHz for the modulation meter) + text.
    // Idle defaults are unitless to match the live format (the kHz unit is shown
    // once in the "Deviation (kHz)" group header); a unit here would also shrink
    // the value via minimumScaleFactor in the narrow scale-less strips.
    var pilotNorm: Double = 0
    var pilotText = "0.00"
    var rdsNorm: Double = 0
    var rdsText = "0.00"
    var maxDevNorm: Double = 0
    var maxDevText = "0.0"

    // Modulation analysis: MPX power (BS.412), +/- peak-hold deviation, best
    // stereo separation. Text "--" when not yet valid.
    var mpxPowerText = "--"
    var mpxPowerNorm: Double = 0      // 0..1 over a -12..+3 dBr display range
    var mpxPowerDBr: Double = -120    // raw value for over-limit coloring
    var mpxPowerValid = false
    var posPeakText = "0.0"
    var negPeakText = "0.0"
    var posPeakKHz: Double = 0        // raw +peak for over-limit coloring
    var negPeakKHz: Double = 0        // raw -peak (signed) for coloring
    // ITU-R SM.1268-5 exceedance: % of deviation samples > 77 kHz since reset.
    var exceedanceText = "--"
    var exceedancePct: Double = 0     // raw value for over-limit coloring
    var exceedanceValid = false
    // Highest fully-primed 60 s sliding MPX power since reset (BS.412
    // compliance = max over window placements).
    var mpxPowerMaxText = "--"
    var mpxPowerMaxDBr: Double = -120
    var mpxPowerMaxValid = false
    var separationText = "--"

    // SDR signal level (relative RSSI, dBFS). rssiValid is false for the
    // audio-device input (no RF level there).
    var rssiText = "--"
    var rssiNorm: Double = 0          // 0..1 over a -80..0 dBFS range
    var rssiValid = false

    // RDS display strings (decoded text + group histogram). On telemetry, not
    // the view model: the group counters advance with every received group
    // (~10/s) and must never invalidate the window body / toolbar.
    // (rdsStatusText = the decoder status line; rdsText above is the
    // deviation strip's kHz reading.)
    var rdsStatusText = "--"
    var ptyText = "--"
    var ptynText = "--"
    var eccText = "--"
    var psText = "--"
    var rtText = "--"
    var rtPlusText = "--"
    var longPSText = "--"
    var ctText = "--"
    var afText = "--"
    var groupText = "--"

    /// Vectorscope display gain (auto-ridden or the manual zoom).
    var vectorZoom: Double = 1

    // Scrolling trend history (oldest -> newest).
    var devHistoryKHz: [Float] = []
    var mpxPowerHistoryDBr: [Float] = []

    // Waveforms / spectrum.
    var compositeScope: [Float] = []
    var decodedLScope: [Float] = []
    var decodedRScope: [Float] = []
    var spectrumDB: [Float] = []
    var spectrumMaxHz: Double = 100_000
    var spectrumNyquistHz: Double = 0
    var decodedLSpectrumDB: [Float] = []
    var decodedRSpectrumDB: [Float] = []
    var audioSpectrumMaxHz: Double = 20_000
    var audioSpectrumNyquistHz: Double = 0
}
