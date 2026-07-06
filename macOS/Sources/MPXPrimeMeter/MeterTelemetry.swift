import Foundation
import SwiftUI

// Per-tick monitoring values for the Meter window. Lives on its OWN
// ObservableObject (not the view model) so a 25 Hz refresh repaints only the
// Canvas leaves wrapped in `LiveTelemetryView`, never the whole window -- the
// freeze-prevention rule. The view model holds only structural + slow (RDS)
// state and is not invalidated per tick.
final class MeterTelemetry: ObservableObject {
    // Levels: normalized 0..1 (dBFS -36..0) + display strings.
    @Published var inputNorm: Double = 0
    @Published var inputText = "-inf"
    @Published var leftNorm: Double = 0
    @Published var leftText = "-inf"
    @Published var rightNorm: Double = 0
    @Published var rightText = "-inf"
    @Published var midNorm: Double = 0
    @Published var midText = "-inf"
    @Published var sideNorm: Double = 0
    @Published var sideText = "-inf"
    @Published var correlation: Double = 1
    @Published var correlationText = "+1.00"

    // Deviation: normalized 0..1 (0..100 kHz for the modulation meter) + text.
    // Idle defaults are unitless to match the live format (the kHz unit is shown
    // once in the "Deviation (kHz)" group header); a unit here would also shrink
    // the value via minimumScaleFactor in the narrow scale-less strips.
    @Published var pilotNorm: Double = 0
    @Published var pilotText = "0.00"
    @Published var rdsNorm: Double = 0
    @Published var rdsText = "0.00"
    @Published var maxDevNorm: Double = 0
    @Published var maxDevText = "0.0"

    // Modulation analysis: MPX power (BS.412), +/- peak-hold deviation, best
    // stereo separation. Text "--" when not yet valid.
    @Published var mpxPowerText = "--"
    @Published var mpxPowerNorm: Double = 0      // 0..1 over a -12..+3 dBr display range
    @Published var mpxPowerDBr: Double = -120    // raw value for over-limit coloring
    @Published var mpxPowerValid = false
    @Published var posPeakText = "0.0"
    @Published var negPeakText = "0.0"
    @Published var posPeakKHz: Double = 0        // raw +peak for over-limit coloring
    @Published var negPeakKHz: Double = 0        // raw -peak (signed) for coloring
    @Published var separationText = "--"

    // SDR signal level (relative RSSI, dBFS). rssiValid is false for the
    // audio-device input (no RF level there).
    @Published var rssiText = "--"
    @Published var rssiNorm: Double = 0          // 0..1 over a -80..0 dBFS range
    @Published var rssiValid = false

    // Scrolling trend history (oldest -> newest).
    @Published var devHistoryKHz: [Float] = []
    @Published var mpxPowerHistoryDBr: [Float] = []

    // Waveforms / spectrum.
    @Published var compositeScope: [Float] = []
    @Published var decodedLScope: [Float] = []
    @Published var decodedRScope: [Float] = []
    @Published var spectrumDB: [Float] = []
    @Published var spectrumMaxHz: Double = 100_000
    @Published var spectrumNyquistHz: Double = 0
    @Published var decodedLSpectrumDB: [Float] = []
    @Published var decodedRSpectrumDB: [Float] = []
    @Published var audioSpectrumMaxHz: Double = 20_000
    @Published var audioSpectrumNyquistHz: Double = 0
}
