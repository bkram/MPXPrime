import Testing
import Foundation
@testable import MPXPrime

// Listening-capture driver for the look-ahead composite peak control
// (0.26 Phase C). Renders the same input program through the full
// MPXGenerator chain at four lookahead settings (0.0 / 1.0 / 2.0 /
// 3.0 ms) and captures the demodulated audio + raw composite to WAV
// for sample-aligned A/B in a DAW.
//
// Env-gated: only runs when MPXPRIME_AUDIT_CAPTURE=1 is set. Skipped
// by default so a normal `swift test` doesn't spam the filesystem with
// WAV files.
//
// Output: macOS/.audit-out/lookahead/<scenario>/{demod,mpx}-<arrangement>.wav
// where <arrangement> is "lookahead-0.0ms" / "lookahead-1.0ms" / etc.
//
// Usage:
//   MPXPRIME_AUDIT_CAPTURE=1 \
//     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     swift test --package-path macOS \
//       --filter CompositeClipperLookaheadCaptureTests

@Suite(
    "Composite clipper look-ahead — listening capture",
    .enabled(if: ProcessInfo.processInfo.environment["MPXPRIME_AUDIT_CAPTURE"] == "1")
)
struct CompositeClipperLookaheadCaptureTests {

    private let sampleRate: Double = 192_000.0
    private let durationSeconds: Double = 8.0
    private let blockSize: Int = 1024

    private var auditOutRoot: URL {
        // Resolve relative to #file so cwd doesn't matter.
        let here = URL(fileURLWithPath: #filePath)
        let macOSRoot = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return macOSRoot.appendingPathComponent(".audit-out/lookahead", isDirectory: true)
    }

    private func makeHeavyConfig(lookaheadMS: Double) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = blockSize
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.processingBypass = false
        cfg.preemphasisUS = 50
        cfg.mpxDeviationKHz = 75.0
        cfg.limitMPX = true
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.widebandAGCEnabled = true
        cfg.primeBassEnabled = true
        cfg.stereoWidenEnabled = true
        cfg.monoBassEnabled = true
        cfg.multibandEnabled = true
        cfg.multibandMode = 5
        cfg.phaseRotationEnabled = true
        cfg.parametricEQEnabled = true
        cfg.multibandLimiterEnabled = true
        cfg.bassClipperEnabled = true
        cfg.dcClipperEnabled = true
        cfg.bs412Enabled = true
        // Composite clipper engaged — that's the whole point.
        cfg.compositeClipperEnabled = true
        cfg.compositeClipperLookaheadMS = lookaheadMS
        cfg.enRDS = true
        cfg.rdsLevel = 2.0
        cfg.rdsNowPlayingEnabled = false
        cfg.rdsEnableRTPlus = false
        cfg.rdsEnableCT = false
        cfg.rdsEnableID = false
        return cfg
    }

    // Test programs designed to stress different aspects of the look-
    // ahead mechanism. Same generators as the chain-order audit (with
    // additions) — the look-ahead's value shows up most on transient-
    // rich content.

    /// Raised-cosine fade-in/out window. Returns 0..1 envelope value
    /// for the given index inside a windowed event of `length` samples
    /// with `fadeLen` raised-cosine fades at each end. Avoids broadband
    /// click content that hard truncation would produce in the test
    /// signal itself.
    private func raisedCosineEnvelope(idx: Int, length: Int, fadeLen: Int) -> Double {
        guard idx >= 0, idx < length else { return 0.0 }
        if idx < fadeLen {
            return 0.5 * (1.0 - cos(.pi * Double(idx) / Double(fadeLen)))
        }
        if idx >= length - fadeLen {
            let outIdx = length - 1 - idx
            return 0.5 * (1.0 - cos(.pi * Double(outIdx) / Double(fadeLen)))
        }
        return 1.0
    }

    private func brightDenseProgram(frames: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let crashLen = 1_500
        let crashFade = 64
        let crashStride = 19_200
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let lf = 0.30 * sin(2.0 * .pi * 80.0 * t)
            let mid = 0.28 * sin(2.0 * .pi * 1_000.0 * t)
            let upper = 0.26 * sin(2.0 * .pi * 4_500.0 * t)
            let hf = 0.22 * sin(2.0 * .pi * 9_500.0 * t)
            let crashEnv = raisedCosineEnvelope(idx: i % crashStride, length: crashLen, fadeLen: crashFade)
            let crash = crashEnv * 0.18 * sin(2.0 * .pi * 12_000.0 * t)
            let v = lf + mid + upper + hf + crash
            left[i] = Float(v)
            right[i] = Float(v * 0.94 + 0.04 * sin(2.0 * .pi * 600.0 * t + 0.7))
        }
        return (left, right)
    }

    private func transientPushProgram(frames: Int) -> (left: [Float], right: [Float]) {
        // Recurring brick-wall transients — the headline stress for
        // look-ahead. A 2 kHz tone at sustained level with periodic
        // impulse-like onsets every ~120 ms. The pulse uses an
        // exponential decay with a raised-cosine fade-in so there's
        // no step discontinuity at the pulse onset.
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let pulseLen = 384
        let pulseFade = 24
        let pulseStride = 23_040
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let sustain = 0.35 * sin(2.0 * .pi * 2_000.0 * t)
            let pIdx = i % pulseStride
            var pulse = 0.0
            if pIdx < pulseLen {
                let decay = 0.85 * exp(-Double(pIdx) / 80.0)
                let env = raisedCosineEnvelope(idx: pIdx, length: pulseLen, fadeLen: pulseFade)
                pulse = decay * env * sin(2.0 * .pi * 4_000.0 * t)
            }
            let v = sustain + pulse
            left[i] = Float(v)
            right[i] = Float(v * 0.92)
        }
        return (left, right)
    }

    private func wideBassProgram(frames: Int) -> (left: [Float], right: [Float]) {
        // Sustained low-frequency content with brief LF transients.
        // Look-ahead's effect on perceived bass character matters
        // listening-wise.
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let bass = 0.45 * sin(2.0 * .pi * 70.0 * t)
            let bass2 = 0.30 * sin(2.0 * .pi * 110.0 * t + 0.3)
            let mid = 0.18 * sin(2.0 * .pi * 700.0 * t)
            let kick = (i % 32_000 < 600) ? 0.55 * exp(-Double(i % 32_000) / 200.0) * sin(2.0 * .pi * 60.0 * t) : 0.0
            let v = bass + bass2 + mid + kick
            left[i] = Float(v)
            right[i] = Float(v)
        }
        return (left, right)
    }

    @Test func captureLookaheadWAVs() throws {
        let frames = Int(sampleRate * durationSeconds)
        let outRoot = auditOutRoot

        let scenarios: [(String, (left: [Float], right: [Float]))] = [
            ("bright_dense", brightDenseProgram(frames: frames)),
            ("transient_push", transientPushProgram(frames: frames)),
            ("wide_bass", wideBassProgram(frames: frames)),
        ]

        let lookaheadValues: [Double] = [0.0, 1.0, 2.0, 3.0]

        for lookaheadMS in lookaheadValues {
            let arrangement = String(format: "lookahead-%.1fms", lookaheadMS)
            for (scenarioName, program) in scenarios {
                let cfg = makeHeavyConfig(lookaheadMS: lookaheadMS)
                let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)

                var inputL = program.left
                var inputR = program.right
                var mpxBufL = [Float](repeating: 0.0, count: frames)
                var mpxBufR = [Float](repeating: 0.0, count: frames)

                inputL.withUnsafeMutableBufferPointer { lBuf in
                    inputR.withUnsafeMutableBufferPointer { rBuf in
                        mpxBufL.withUnsafeMutableBufferPointer { mpxL in
                            mpxBufR.withUnsafeMutableBufferPointer { mpxR in
                                var offset = 0
                                while offset < frames {
                                    let chunk = min(blockSize, frames - offset)
                                    gen.renderFromInputAndMonitorInPlace(
                                        frameCount: chunk,
                                        left: lBuf.baseAddress!.advanced(by: offset),
                                        right: rBuf.baseAddress!.advanced(by: offset),
                                        mpxLeft: mpxL.baseAddress!.advanced(by: offset),
                                        mpxRight: mpxR.baseAddress!.advanced(by: offset)
                                    )
                                    offset += chunk
                                }
                            }
                        }
                    }
                }

                let scenarioDir = outRoot.appendingPathComponent(scenarioName, isDirectory: true)
                try WAVExport.writeStereo(
                    left: inputL, right: inputR,
                    sampleRate: sampleRate,
                    to: scenarioDir.appendingPathComponent("demod-\(arrangement).wav")
                )
                try WAVExport.writeMono(
                    mpxBufL,
                    sampleRate: sampleRate,
                    to: scenarioDir.appendingPathComponent("mpx-\(arrangement).wav")
                )
                print("[capture] \(arrangement)/\(scenarioName) wrote demod + mpx WAVs")
            }
        }
    }
}
