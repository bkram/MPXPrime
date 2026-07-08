import Observation
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
@Observable
final class LiveTelemetry {
    var runtimeText: String = "Not running"
    var inputRingText: String = "Input ring: n/a"
    var inputBufferValue: Double = 0.0
    var inputBufferMax: Double = 1.0
    var inputBufferWarning: Double = 0.7
    var inputBufferCritical: Double = 0.9
    var bufferFillSmoothed: Double = 0.0
    var streamHealth: MonitoringStreamHealth = .stopped

    var inputLLevel: Double = 0.0
    var inputRLevel: Double = 0.0
    var agcOutputLLevel: Double = 0.0
    var agcOutputRLevel: Double = 0.0
    var outputLevel: Double = 0.0
    var modulationLevel: Double = 0.0
    var inputLPeakHoldLevel: Double = 0.0
    var inputRPeakHoldLevel: Double = 0.0
    var agcOutputLPeakHoldLevel: Double = 0.0
    var agcOutputRPeakHoldLevel: Double = 0.0
    var outputPeakHoldLevel: Double = 0.0
    var modulationPeakHoldLevel: Double = 0.0

    var inputLText: String = "-inf dBFS"
    var inputRText: String = "-inf dBFS"
    var agcOutputLText: String = "-inf dBFS"
    var agcOutputRText: String = "-inf dBFS"
    var outputText: String = "-inf dBFS"
    var modulationText: String = "0.0 kHz"

    var limiterStateText: String = "Off"
    var limiterDetailText: String = "Drive 0.0 dB • GR 0.0 dB • Safe 0.0 dB • Peak -inf dBFS"
    var compositeBudgetStateText: String = "Off"
    var compositeCalibrationText: String = "Pilot 0.0% • RDS 0.0% • Audio -inf dBFS • Margin 0.0 dB"
    var estimatedDeviationPeakKHz: Float = 0.0
    var pilotInjectionPercentValue: Float = 0.0
    var rdsInjectionPercentValue: Float = 0.0
    var audioCompositePeakLinear: Float = 0.0
    var compositeBudgetMarginDBValue: Float = 0.0
    var postInjectionOvershootValue: Float = 0.0
    var compositeOverBudget: Bool = false
    var compositeClipperGainReductionDBValue: Float = 0.0
    var compositeClipperLookaheadGainReductionDBValue: Float = 0.0
    var preEncodeLimiterGainReductionDBValue: Float = 0.0
    var safetyLimiterGainReductionDBValue: Float = 0.0
    var stereoImageText: String = "Corr +1.00 • Side 0.00x"
    var agcStateText: String = "Off"
    var agcDetailText: String = "Detector -inf dB • Gain 0.0 dB"
    var multibandStateText: String = "Off"
    var primeBassStateText: String = "Off"
    var widenerStateText: String = "Off"

    var rdsPS: String = "-"
    var rdsPI: String = "-"
    var rdsPTY: String = "-"
    var rdsPTYN: String = "-"
    var rdsAID: String = "AID: OFF"
    var rdsLongPS: String = "-"
    var rdsRadiotext: String = "-"
    var rdsNowPlayingStatus: String = "Now Playing: off"

    var inputScopeLeft: [Float] = Array(repeating: 0.0, count: 128)
    var inputScopeRight: [Float] = Array(repeating: 0.0, count: 128)
    var outputScope: [Float] = Array(repeating: 0.0, count: 128)
    var mpxSpectrumDB: [Float] = Array(repeating: -100.0, count: 512)
    var mpxSpectrumMaxHz: Double = 92_000.0
    var mpxSpectrumNyquistHz: Double = 0.0
    var preMPXSpectrumLeftDB: [Float] = Array(repeating: -100.0, count: 128)
    var preMPXSpectrumRightDB: [Float] = Array(repeating: -100.0, count: 128)
    var preMPXSpectrumMaxHz: Double = 16_000.0
    var preMPXSpectrumNyquistHz: Double = 0.0
}

// `LiveTelemetryView` (the generic isolation wrapper) now lives in the shared
// MPXPrimeUI target so both the transmit GUI and the Meter window reuse it.
