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
    @Published var pilotNorm: Double = 0
    @Published var pilotText = "0.0 kHz"
    @Published var rdsNorm: Double = 0
    @Published var rdsText = "0.0 kHz"
    @Published var maxDevNorm: Double = 0
    @Published var maxDevText = "0.0 kHz"

    // Modulation analysis: MPX power (BS.412), +/- peak-hold deviation, best
    // stereo separation. Text "--" when not yet valid.
    @Published var mpxPowerText = "--"
    @Published var mpxPowerNorm: Double = 0      // 0..1 over a -12..+3 dBr display range
    @Published var posPeakText = "0.0"
    @Published var negPeakText = "0.0"
    @Published var separationText = "--"

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
}
