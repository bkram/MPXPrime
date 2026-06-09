import SwiftUI

// High-frequency monitoring telemetry, split out of MPXPrimeViewModel so a
// metering tick does NOT fire the view model's objectWillChange.
//
// Why this exists: every live meter / scope / spectrum value used to be an
// @Published property on MPXPrimeViewModel. refreshMonitoringSnapshot writes
// ~60 of them up to 30 times a second, so each tick invalidated the entire
// view model -- re-evaluating and re-running the SwiftUI layout engine across
// every observing card, Form, and window, even though only the Canvas leaves
// changed. With a monitoring window left open for hours that per-tick
// whole-window layout pass compounded in AppKit's constraint engine into a
// near-frozen GUI (audio, on its own real-time thread, was unaffected).
//
// Now those values live here. MPXPrimeViewModel keeps one-line computed
// properties that forward to this object, so the existing writer code in the
// update methods is unchanged, but the WRITES land on LiveTelemetry's
// objectWillChange, not the view model's. Only views wrapped in
// `LiveTelemetryView` observe it, so a tick repaints those (Canvas) leaves
// without touching the rest of the window. See the project memory
// "meters must use Canvas" for the companion rule on the leaves themselves.
final class LiveTelemetry: ObservableObject {
    @Published var runtimeText: String = "Not running"
    @Published var inputRingText: String = "Input ring: n/a"
    @Published var inputBufferValue: Double = 0.0
    @Published var inputBufferMax: Double = 1.0
    @Published var inputBufferWarning: Double = 0.7
    @Published var inputBufferCritical: Double = 0.9
    @Published var bufferFillSmoothed: Double = 0.0
    @Published var streamHealth: MonitoringStreamHealth = .stopped

    @Published var inputLLevel: Double = 0.0
    @Published var inputRLevel: Double = 0.0
    @Published var agcOutputLLevel: Double = 0.0
    @Published var agcOutputRLevel: Double = 0.0
    @Published var outputLevel: Double = 0.0
    @Published var modulationLevel: Double = 0.0
    @Published var inputLPeakHoldLevel: Double = 0.0
    @Published var inputRPeakHoldLevel: Double = 0.0
    @Published var agcOutputLPeakHoldLevel: Double = 0.0
    @Published var agcOutputRPeakHoldLevel: Double = 0.0
    @Published var outputPeakHoldLevel: Double = 0.0
    @Published var modulationPeakHoldLevel: Double = 0.0

    @Published var inputLText: String = "-inf dBFS"
    @Published var inputRText: String = "-inf dBFS"
    @Published var agcOutputLText: String = "-inf dBFS"
    @Published var agcOutputRText: String = "-inf dBFS"
    @Published var outputText: String = "-inf dBFS"
    @Published var modulationText: String = "0.0 kHz"

    @Published var limiterStateText: String = "Off"
    @Published var limiterDetailText: String = "Drive 0.0 dB • GR 0.0 dB • Safe 0.0 dB • Peak -inf dBFS"
    @Published var compositeBudgetStateText: String = "Off"
    @Published var compositeCalibrationText: String = "Pilot 0.0% • RDS 0.0% • Audio -inf dBFS • Margin 0.0 dB"
    @Published var estimatedDeviationPeakKHz: Float = 0.0
    @Published var pilotInjectionPercentValue: Float = 0.0
    @Published var rdsInjectionPercentValue: Float = 0.0
    @Published var audioCompositePeakLinear: Float = 0.0
    @Published var compositeBudgetMarginDBValue: Float = 0.0
    @Published var postInjectionOvershootValue: Float = 0.0
    @Published var compositeOverBudget: Bool = false
    @Published var compositeClipperGainReductionDBValue: Float = 0.0
    @Published var compositeClipperLookaheadGainReductionDBValue: Float = 0.0
    @Published var preEncodeLimiterGainReductionDBValue: Float = 0.0
    @Published var safetyLimiterGainReductionDBValue: Float = 0.0
    @Published var stereoImageText: String = "Corr +1.00 • Side 0.00x"
    @Published var agcStateText: String = "Off"
    @Published var agcDetailText: String = "Detector -inf dB • Gain 0.0 dB"
    @Published var multibandStateText: String = "Off"
    @Published var primeBassStateText: String = "Off"
    @Published var widenerStateText: String = "Off"

    @Published var rdsPS: String = "-"
    @Published var rdsPI: String = "-"
    @Published var rdsPTY: String = "-"
    @Published var rdsPTYN: String = "-"
    @Published var rdsAID: String = "AID: OFF"
    @Published var rdsLongPS: String = "-"
    @Published var rdsRadiotext: String = "-"
    @Published var rdsNowPlayingStatus: String = "Now Playing: off"

    @Published var inputScopeLeft: [Float] = Array(repeating: 0.0, count: 128)
    @Published var inputScopeRight: [Float] = Array(repeating: 0.0, count: 128)
    @Published var outputScope: [Float] = Array(repeating: 0.0, count: 128)
    @Published var mpxSpectrumDB: [Float] = Array(repeating: -100.0, count: 512)
    @Published var mpxSpectrumMaxHz: Double = 92_000.0
    @Published var mpxSpectrumNyquistHz: Double = 0.0
    @Published var preMPXSpectrumLeftDB: [Float] = Array(repeating: -100.0, count: 128)
    @Published var preMPXSpectrumRightDB: [Float] = Array(repeating: -100.0, count: 128)
    @Published var preMPXSpectrumMaxHz: Double = 16_000.0
    @Published var preMPXSpectrumNyquistHz: Double = 0.0
}

// Observes ONLY the LiveTelemetry object, so wrapping a live widget in this
// view confines a metering tick's re-evaluation + layout to the wrapped
// subtree. The enclosing card / Form holds `model` (the view model) and
// passes `model.telemetry` in WITHOUT observing it -- handing an object to a
// child initializer does not subscribe the parent -- so the card body does
// not re-evaluate on a tick. Keep the wrapped content a fixed-size Canvas
// leaf (meter / scope / spectrum) or a fixed-width readout so the repaint
// never propagates a layout change back out to the card.
struct LiveTelemetryView<Content: View>: View {
    @ObservedObject var telemetry: LiveTelemetry
    @ViewBuilder let content: (LiveTelemetry) -> Content

    var body: some View {
        content(telemetry)
    }
}
