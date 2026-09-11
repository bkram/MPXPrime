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

    // Test programs designed for clean A/B listening: sustained spectral
    // content within the chain's normal operating range (peak ≈ 0.7).
    // Earlier versions used synthetic "transient" pulses (sharp
    // amplitude jumps every ~100 ms), but those drove the AGC +
    // multiband + composite clipper chain into saturation, producing
    // rail-hitting periodic spikes that sounded like clicks at all
    // lookahead settings. Real broadcast program doesn't have such
    // signals, so the captures weren't measuring lookahead's behavior
    // on realistic input. These regenerated programs avoid sharp
    // synthetic transients entirely; lookahead engages on the
    // continuous near-clipping content of each program.

    private func brightDenseProgram(frames: Int) -> (left: [Float], right: [Float]) {
        // HF-rich pop spectrum: sustained tones across the audio band,
        // peak-summed near the clipper threshold so the clipper engages
        // continuously without saturating earlier stages.
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let lf = 0.20 * sin(2.0 * .pi * 80.0 * t)
            let mid = 0.18 * sin(2.0 * .pi * 1_000.0 * t)
            let upper = 0.15 * sin(2.0 * .pi * 4_500.0 * t)
            let hf = 0.12 * sin(2.0 * .pi * 9_500.0 * t)
            let v = lf + mid + upper + hf
            left[i] = Float(v)
            right[i] = Float(v * 0.94 + 0.03 * sin(2.0 * .pi * 600.0 * t + 0.7))
        }
        return (left, right)
    }

    private func transientPushProgram(frames: Int) -> (left: [Float], right: [Float]) {
        // Slow amplitude modulation (8 Hz tremolo on a 2 kHz tone)
        // sweeps the input level through the clipper's threshold
        // periodically. Lookahead should produce smoothly-varying gain
        // reduction without click artifacts. Replaces the earlier
        // brick-wall pulse design that produced rail-hitting spikes.
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            // 2 kHz carrier with 8 Hz amplitude modulation 0.4..0.7
            let modEnv = 0.55 + 0.15 * sin(2.0 * .pi * 8.0 * t)
            let carrier = sin(2.0 * .pi * 2_000.0 * t)
            // Companion mid tone for stereo difference
            let companion = 0.20 * sin(2.0 * .pi * 750.0 * t)
            let v = modEnv * carrier + companion
            left[i] = Float(v)
            right[i] = Float(v * 0.92 + 0.05 * sin(2.0 * .pi * 1_100.0 * t))
        }
        return (left, right)
    }

    private func wideBassProgram(frames: Int) -> (left: [Float], right: [Float]) {
        // Sustained low-frequency content with smoothly-decaying kick
        // every ~167 ms — already sounds clean per prior listening; LF
        // kick envelope is gentle enough that the chain doesn't saturate.
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let bass = 0.30 * sin(2.0 * .pi * 70.0 * t)
            let bass2 = 0.20 * sin(2.0 * .pi * 110.0 * t + 0.3)
            let mid = 0.12 * sin(2.0 * .pi * 700.0 * t)
            let kick = (i % 32_000 < 1_600)
                ? 0.40 * exp(-Double(i % 32_000) / 480.0) * sin(2.0 * .pi * 60.0 * t)
                : 0.0
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
