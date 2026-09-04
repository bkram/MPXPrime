#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore
#if canImport(AVFoundation)
// @preconcurrency: AVAudioConverter's input block is invoked synchronously
// inside convert(to:error:withInputFrom:), but its type is marked @Sendable;
// without this the captured one-shot flag trips Swift 6 Sendable warnings.
@preconcurrency import AVFoundation
#endif

// --verify-program-ab <file-or-dir>: real-music A/B for the Advanced
// Dynamics default-flip campaign. Decodes user-supplied audio files (the
// captured-from-BlackHole corpus, see scripts/capture-program.sh), renders
// each excerpt through (A) the shipped Format Profile's AGC + multiband
// chain and (B) the same profile with Advanced Dynamics, and measures both
// composites with the Meter's measurement engine (`MeterAnalysis` -- the
// same BS.412 / deviation / exceedance numbers the live Meter shows) plus
// decoded-audio quality metrics. Identical input per chain, so the deltas
// are deterministic and re-runnable as a regression gate.
//
// RDS is disabled for the render: the RDS text scheduler paces by wall
// clock, so its bit sequence differs between renders; the subcarrier is
// constant-amplitude and identical in both chains, so leaving it out does
// not bias any A-vs-B delta. The pilot stays on.
//
// The mode is macOS-only (AVFoundation decodes the files); on Linux it
// exits 64 with a message.

/// Calibrated 2026-09-04 on the operator corpus (3 x 60 s captured program
/// sessions, music_clean + music_loud): measured worst-case per track was
/// power +1.44 dBr, HF crest -0.8, crest -0.7, |corr| 0.06, side -0.6,
/// band +2.8, pumping 3.82. Bounds sit above those with regression margin.
/// Re-calibrate (and re-date) when the corpus grows materially.
let programABGatesArmed = true

enum ProgramABThresholds {
    // any => TIGHT while armed
    static let maxAbsPowerDeltaDBr: Float = 2.0
    static let minHFCrestDeltaDB: Float = -2.0
    static let minCrestDeltaDB: Float = -1.5
    static let maxAbsCorrDelta: Float = 0.15
    static let minSideRetentionDeltaDB: Float = -3.0
    static let maxBandBalanceDeltaDB: Float = 3.5
    /// NOTE: the pumping index conflates the leveler's legitimate
    /// beat-adjacent leveling activity with true pumping (measured
    /// 1.5-3.8 dB on the calibration corpus vs an idle AGC); the bound
    /// catches a runaway, listening judges the character.
    static let maxPumpingExcessDB: Float = 5.0
}

struct ProgramABChainResult {
    var label: String = ""
    var mpxPowerDBr: Float = .nan
    var mpxPowerValid = false
    var mpxPowerMaxDBr: Float = .nan
    var mpxPowerMaxValid = false
    var maxDevKHz: Float = .nan
    var aveDevKHz: Float = .nan
    var posPeakDevKHz: Float = .nan
    var negPeakDevKHz: Float = .nan
    var exceedancePct: Float = .nan
    var stereo = StereoSignalMetrics()
    var bands = AudioBandRMSMetrics()
    var crestDB: Float = .nan
    var hfCrestDB: Float = .nan
    var maxAGCReductionDB: Float = 0.0
    var adBandMinDB: [Float] = []
    var adBandMaxDB: [Float] = []
    var overBudget = false
    var maxPostInjectionOvershoot: Float = 0.0
    /// 10 ms-hop RMS envelope (dB) of the decoded mono monitor.
    var envelopeDB: [Float] = []
}

func runProgramABVerification(
    baseConfig: AppConfig,
    path: String,
    profileID: String,
    durationSeconds: Double,
    csvPath: String?
) -> Int32 {
    #if !canImport(AVFoundation)
    fputs("--verify-program-ab needs AVFoundation to decode audio files (macOS only).\n", stderr)
    return 64
    #else
    let files = programABInputFiles(path: path)
    guard !files.isEmpty else {
        fputs("--verify-program-ab: no decodable audio files at \(path)\n", stderr)
        return 64
    }

    // Base config: AppConfig defaults + the shipped profile -- NOT the
    // loaded Verification.ini (its multiband_enabled=False would make
    // chain A unrepresentative). Only the render rate follows the INI.
    var profileConfig = AppConfig()
    profileConfig.sampleRate = baseConfig.sampleRate
    profileConfig.sourceMode = "input"
    profileConfig.enRDS = false
    guard PresetCatalog.applyFormatProfile(id: profileID, to: &profileConfig) != nil else {
        fputs("--verify-program-ab: unknown Format Profile id '\(profileID)'\n", stderr)
        return 64
    }
    var classicConfig = profileConfig
    classicConfig.advancedDynamicsEnabled = false
    var leveledConfig = profileConfig
    leveledConfig.advancedDynamicsEnabled = true

    let excerpt = durationSeconds
    print("Program A/B (profile \(profileID): AGC+multiband vs Advanced Dynamics)")
    print("Input: \(path) (\(files.count) file(s))")
    print("Excerpt: \(excerpt <= 0 ? "full track" : String(format: "%.0f s", excerpt)) - Render \(Int(profileConfig.sampleRate)) Hz - RDS off (wall-clock scheduler; identical in both chains)")
    print("Gates: \(programABGatesArmed ? "ARMED" : "report-only (thresholds uncalibrated; see programABGatesArmed)")")
    print("")

    var warnings: [String] = []
    var hardFailures: [String] = []
    var csvLines: [String] = [
        "track,chain,seconds,mpxPowerDBr,mpxPowerMaxDBr,maxDevKHz,aveDevKHz,posPeakKHz,negPeakKHz,exceedancePct,corr,sideToMid,lowDBFS,midDBFS,highDBFS,crestDB,hfCrestDB,agcMaxGRDB,adMinG1,adMinG2,adMinG3,adMinG4,adMinG5,adMaxG1,adMaxG2,adMaxG3,adMaxG4,adMaxG5,pumpingDB"
    ]

    for file in files {
        let name = file.lastPathComponent
        guard let program = decodeProgramFile(
            url: file, targetRate: profileConfig.sampleRate, excerptSeconds: excerpt)
        else {
            print("\(name): decode failed, skipped")
            continue
        }
        let seconds = Double(program.left.count) / profileConfig.sampleRate
        guard seconds >= 5.0 else {
            print("\(name): only \(String(format: "%.1f", seconds)) s decoded, skipped (need >= 5 s)")
            continue
        }

        let a = renderProgramChain(
            config: classicConfig, label: "A classic", left: program.left, right: program.right)
        let b = renderProgramChain(
            config: leveledConfig, label: "B leveler", left: program.left, right: program.right)

        // Pumping index: beat-band (0.5-4.5 Hz) modulation of the B-vs-A
        // decoded envelope ratio. Identical input, so the ratio isolates
        // what the two dynamics engines do differently over time.
        let pumpingDB = programABPumpingDB(envA: a.envelopeDB, envB: b.envelopeDB)

        print("Track: \(name) (\(String(format: "%.1f", seconds)) s)")
        print("  Chain      PwrdBr  PwrMax  MaxDev  AveDev  Pos/Neg kHz    Exc%   Corr  Side   Low/Mid/High dBFS      Crest  HFCrest")
        for r in [a, b] {
            print(
                "  \(padded(r.label, width: 9))"
                    + "  \(meterNum(r.mpxPowerDBr, valid: r.mpxPowerValid, width: 6))"
                    + "  \(meterNum(r.mpxPowerMaxDBr, valid: r.mpxPowerMaxValid, width: 6))"
                    + "  \(String(format: "%6.1f", r.maxDevKHz))"
                    + "  \(String(format: "%6.1f", r.aveDevKHz))"
                    + "  \(String(format: "%5.1f/%5.1f", r.posPeakDevKHz, r.negPeakDevKHz))"
                    + "  \(String(format: "%5.2f", r.exceedancePct))"
                    + "  \(String(format: "%+5.2f", r.stereo.correlation))"
                    + "  \(String(format: "%5.2f", r.stereo.sideToMidRatio))"
                    + "  \(String(format: "%6.1f/%6.1f/%6.1f", r.bands.lowDBFS, r.bands.midDBFS, r.bands.highDBFS))"
                    + "  \(String(format: "%5.1f", r.crestDB))"
                    + "  \(String(format: "%7.1f", r.hfCrestDB))"
            )
        }
        let powerDeltaValid = a.mpxPowerValid && b.mpxPowerValid
        let powerDelta = powerDeltaValid ? b.mpxPowerDBr - a.mpxPowerDBr : Float.nan
        let corrDelta = b.stereo.correlation - a.stereo.correlation
        let sideDelta = ratioDB(b.stereo.sideToMidRatio, a.stereo.sideToMidRatio)
        let crestDelta = b.crestDB - a.crestDB
        let hfCrestDelta = b.hfCrestDB - a.hfCrestDB
        let bandDeltas = [
            b.bands.lowDBFS - a.bands.lowDBFS,
            b.bands.midDBFS - a.bands.midDBFS,
            b.bands.highDBFS - a.bands.highDBFS
        ]
        let powerDeltaText = powerDeltaValid
            ? String(format: "%+.2f dBr", powerDelta) : "-- (window unprimed)"
        print("  Delta B-A: power \(powerDeltaText)" + String(
            format: " - corr %+.2f - side %+.1f dB - crest %+.1f dB - HF crest %+.1f dB - bands %+.1f/%+.1f/%+.1f dB - pumping %.2f dB",
            corrDelta, sideDelta, crestDelta, hfCrestDelta,
            bandDeltas[0], bandDeltas[1], bandDeltas[2], pumpingDB))
        if !b.adBandMinDB.isEmpty {
            let gains = zip(b.adBandMinDB, b.adBandMaxDB)
                .map { String(format: "%+.1f..%+.1f", $0, $1) }
                .joined(separator: " ")
            print("  B leveler band gains (min..max dB): \(gains)  -  A AGC max GR \(String(format: "%.1f", a.maxAGCReductionDB)) dB")
        }
        print("")

        for r in [a, b] {
            if r.overBudget || r.maxPostInjectionOvershoot > 1e-4 {
                hardFailures.append("\(name) \(r.label): composite budget violated (overshoot \(String(format: "%.5f", r.maxPostInjectionOvershoot)))")
            }
        }
        if programABGatesArmed {
            if powerDeltaValid, abs(powerDelta) > ProgramABThresholds.maxAbsPowerDeltaDBr {
                warnings.append("\(name): BS.412 power delta \(String(format: "%+.2f", powerDelta)) dBr")
            }
            if hfCrestDelta < ProgramABThresholds.minHFCrestDeltaDB {
                warnings.append("\(name): HF crest fell \(String(format: "%.1f", -hfCrestDelta)) dB")
            }
            if crestDelta < ProgramABThresholds.minCrestDeltaDB {
                warnings.append("\(name): crest fell \(String(format: "%.1f", -crestDelta)) dB")
            }
            if abs(corrDelta) > ProgramABThresholds.maxAbsCorrDelta {
                warnings.append("\(name): correlation moved \(String(format: "%+.2f", corrDelta))")
            }
            if sideDelta < ProgramABThresholds.minSideRetentionDeltaDB {
                warnings.append("\(name): side/mid fell \(String(format: "%.1f", -sideDelta)) dB")
            }
            if let worstBand = bandDeltas.map({ abs($0) }).max(),
                worstBand > ProgramABThresholds.maxBandBalanceDeltaDB {
                warnings.append("\(name): band balance moved \(String(format: "%.1f", worstBand)) dB")
            }
            if pumpingDB > ProgramABThresholds.maxPumpingExcessDB {
                warnings.append("\(name): pumping index \(String(format: "%.2f", pumpingDB)) dB")
            }
        }

        func csvRow(_ r: ProgramABChainResult, pumping: Float?) -> String {
            var fields: [String] = [
                "\"\(name.replacingOccurrences(of: "\"", with: "'"))\"",
                r.label.hasPrefix("A") ? "classic" : "leveler",
                String(format: "%.1f", seconds),
                String(format: "%.2f", r.mpxPowerDBr), String(format: "%.2f", r.mpxPowerMaxDBr),
                String(format: "%.2f", r.maxDevKHz), String(format: "%.2f", r.aveDevKHz),
                String(format: "%.2f", r.posPeakDevKHz), String(format: "%.2f", r.negPeakDevKHz),
                String(format: "%.3f", r.exceedancePct),
                String(format: "%.3f", r.stereo.correlation), String(format: "%.3f", r.stereo.sideToMidRatio),
                String(format: "%.2f", r.bands.lowDBFS), String(format: "%.2f", r.bands.midDBFS),
                String(format: "%.2f", r.bands.highDBFS),
                String(format: "%.2f", r.crestDB), String(format: "%.2f", r.hfCrestDB),
                String(format: "%.2f", r.maxAGCReductionDB)
            ]
            let mins = r.adBandMinDB.isEmpty ? [Float](repeating: 0, count: 5) : r.adBandMinDB
            let maxs = r.adBandMaxDB.isEmpty ? [Float](repeating: 0, count: 5) : r.adBandMaxDB
            fields += mins.map { String(format: "%.2f", $0) }
            fields += maxs.map { String(format: "%.2f", $0) }
            fields.append(pumping.map { String(format: "%.3f", $0) } ?? "")
            return fields.joined(separator: ",")
        }
        csvLines.append(csvRow(a, pumping: nil))
        csvLines.append(csvRow(b, pumping: pumpingDB))
    }

    if let csvPath {
        do {
            try csvLines.joined(separator: "\n").appending("\n")
                .write(toFile: csvPath, atomically: true, encoding: .utf8)
            print("CSV written: \(csvPath)")
        } catch {
            fputs("--verify-program-ab: could not write CSV \(csvPath): \(error)\n", stderr)
        }
    }

    print("Assessment")
    if !hardFailures.isEmpty {
        for failure in hardFailures { print("- \(failure)") }
        print("Result: FAIL - composite budget violated on program material.")
        return 3
    }
    if warnings.isEmpty {
        print(programABGatesArmed
            ? "Result: OK - leveler tracks the classic chain on this corpus."
            : "Result: OK (report-only) - calibrate thresholds on the corpus, then arm programABGatesArmed.")
        return 0
    }
    print("Comparison notes:")
    for warning in warnings { print("- \(warning)") }
    print("Result: TIGHT - review the flagged tracks before the default flip.")
    return 1
    #endif
}

#if canImport(AVFoundation)

private func programABInputFiles(path: String) -> [URL] {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
    let extensions: Set<String> = ["wav", "aif", "aiff", "caf", "mp3", "m4a", "aac", "flac"]
    let url = URL(fileURLWithPath: path)
    if !isDirectory.boolValue {
        return extensions.contains(url.pathExtension.lowercased()) ? [url] : []
    }
    let entries = (try? fm.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return entries
        .filter { extensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Decodes up to `excerptSeconds` (0 or negative = whole file) to
/// deinterleaved Float32 stereo at `targetRate`. Internal (not private)
/// so ProgramABMetricsTests can round-trip it against CanonicalWavWriter.
func decodeProgramFile(
    url: URL, targetRate: Double, excerptSeconds: Double
) -> (left: [Float], right: [Float])? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let sourceFormat = file.processingFormat
    let sourceFrames = excerptSeconds > 0
        ? min(file.length, AVAudioFramePosition(excerptSeconds * sourceFormat.sampleRate))
        : file.length
    guard sourceFrames > 0,
        let inBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(sourceFrames))
    else { return nil }
    do {
        try file.read(into: inBuffer, frameCount: AVAudioFrameCount(sourceFrames))
    } catch {
        return nil
    }

    let channels = min(2, Int(sourceFormat.channelCount))
    guard channels >= 1,
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
            channels: sourceFormat.channelCount, interleaved: false)
    else { return nil }

    let converted: AVAudioPCMBuffer
    if sourceFormat.sampleRate == targetRate, sourceFormat.commonFormat == .pcmFormatFloat32,
        !sourceFormat.isInterleaved {
        converted = inBuffer
    } else {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }
        let outCapacity = AVAudioFrameCount(
            (Double(sourceFrames) * targetRate / sourceFormat.sampleRate).rounded(.up) + 4_096)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outCapacity)
        else { return nil }
        // The input block's type is @Sendable, but convert() drives it
        // synchronously on this thread; box the one-shot flag to satisfy
        // strict concurrency without an isolation dance.
        final class OneShotInput: @unchecked Sendable { var handed = false }
        let oneShot = OneShotInput()
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if oneShot.handed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            oneShot.handed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, conversionError == nil else { return nil }
        converted = outBuffer
    }

    let frames = Int(converted.frameLength)
    guard frames > 0, let data = converted.floatChannelData else { return nil }
    let left = [Float](UnsafeBufferPointer(start: data[0], count: frames))
    let right = channels > 1
        ? [Float](UnsafeBufferPointer(start: data[1], count: frames))
        : left
    return (left, right)
}

private func renderProgramChain(
    config: AppConfig, label: String, left: [Float], right: [Float]
) -> ProgramABChainResult {
    let sampleRate = config.sampleRate
    let generator = MPXGenerator(config: config, sampleRate: sampleRate)
    let analysis = MeterAnalysis(
        sampleRate: Float(sampleRate),
        preemphasisUS: config.preemphasisUS,
        fullScaleKHz: Float(config.mpxDeviationKHz),
        maxBlock: 4_096,
        mpxPowerWindowSeconds: max(
            5, min(60, Int(Double(left.count) / sampleRate)))
    )

    var result = ProgramABChainResult()
    result.label = label
    let frames = min(left.count, right.count)
    let chunk = 4_096
    var monitorL = [Float](repeating: 0.0, count: frames)
    var monitorR = [Float](repeating: 0.0, count: frames)
    var chunkL = [Float](repeating: 0.0, count: chunk)
    var chunkR = [Float](repeating: 0.0, count: chunk)
    var mpxL = [Float](repeating: 0.0, count: chunk)
    var mpxR = [Float](repeating: 0.0, count: chunk)
    var adMin = [Float](repeating: .greatestFiniteMagnitude, count: 5)
    var adMax = [Float](repeating: -.greatestFiniteMagnitude, count: 5)
    var adSeen = false
    var frame = 0
    while frame < frames {
        let count = min(chunk, frames - frame)
        for i in 0..<count {
            chunkL[i] = left[frame + i]
            chunkR[i] = right[frame + i]
        }
        generator.renderFromInputAndMonitorInPlace(
            frameCount: count,
            left: &chunkL,
            right: &chunkR,
            mpxLeft: &mpxL,
            mpxRight: &mpxR
        )
        mpxL.withUnsafeBufferPointer { buf in
            analysis.process(UnsafeBufferPointer(rebasing: buf[0..<count]))
        }
        for i in 0..<count {
            monitorL[frame + i] = chunkL[i]
            monitorR[frame + i] = chunkR[i]
        }
        let agc = generator.agcStatus
        result.maxAGCReductionDB = max(result.maxAGCReductionDB, max(0.0, -agc.gainDB))
        let advDyn = generator.advancedDynamicsStatus
        if advDyn.enabled {
            adSeen = true
            let gains = [advDyn.bandGainsDB.0, advDyn.bandGainsDB.1, advDyn.bandGainsDB.2,
                         advDyn.bandGainsDB.3, advDyn.bandGainsDB.4]
            for (i, g) in gains.enumerated() {
                adMin[i] = min(adMin[i], g)
                adMax[i] = max(adMax[i], g)
            }
        }
        let cal = generator.compositeCalibrationStatus
        result.overBudget = result.overBudget || cal.overBudget
        result.maxPostInjectionOvershoot = max(
            result.maxPostInjectionOvershoot, cal.postInjectionOvershoot)
        frame += count
    }
    if adSeen {
        result.adBandMinDB = adMin
        result.adBandMaxDB = adMax
    }

    let snapshot = analysis.snapshot()
    result.mpxPowerDBr = snapshot.mpxPowerDBr
    result.mpxPowerValid = snapshot.mpxPowerValid
    result.mpxPowerMaxDBr = snapshot.mpxPowerMaxDBr
    result.mpxPowerMaxValid = snapshot.mpxPowerMaxValid
    result.maxDevKHz = snapshot.maxDevKHz
    result.aveDevKHz = snapshot.aveDevKHz
    result.posPeakDevKHz = snapshot.posPeakDevKHz
    result.negPeakDevKHz = snapshot.negPeakDevKHz
    result.exceedancePct = snapshot.exceedancePct

    // Decoded-audio metrics on the steady part (skip 1 s of chain settle).
    let skip = min(frames / 4, Int(sampleRate * 1.0))
    let steadyL = Array(monitorL[skip...])
    let steadyR = Array(monitorR[skip...])
    result.stereo = computeStereoSignalMetrics(left: steadyL, right: steadyR)
    result.bands = computeAudioBandRMSMetrics(
        left: steadyL, right: steadyR, sampleRate: Float(sampleRate))
    var mono = [Float](repeating: 0.0, count: steadyL.count)
    for i in 0..<mono.count { mono[i] = 0.5 * (steadyL[i] + steadyR[i]) }
    result.crestDB = programCrestDB(mono)
    result.hfCrestDB = hfCrestDB(mono, start: 0, count: mono.count, sampleRate: Float(sampleRate))
    result.envelopeDB = programEnvelopeDB(mono, sampleRate: sampleRate, hopSeconds: 0.010)
    return result
}

#endif

/// "--" for a reading whose validity gate is down, following the Meter's
/// own convention of never printing a number it cannot justify.
func meterNum(_ value: Float, valid: Bool, width: Int) -> String {
    let text = valid ? String(format: "%.1f", value) : "--"
    return String(repeating: " ", count: max(0, width - text.count)) + text
}

/// Full-band crest as 99.9th-percentile-of-|x| over RMS (the hfCrestDB
/// statistic without the highpass).
func programCrestDB(_ samples: [Float]) -> Float {
    guard samples.count > 16 else { return 0.0 }
    var magnitudes = [Float](repeating: 0.0, count: samples.count)
    var sumSq: Double = 0.0
    for (i, v) in samples.enumerated() {
        magnitudes[i] = fabsf(v)
        sumSq += Double(v * v)
    }
    magnitudes.sort()
    let index = min(samples.count - 1, Int(Double(samples.count) * 0.999))
    let p999 = magnitudes[max(0, index)]
    let rms = sqrt(max(1e-30, sumSq / Double(samples.count)))
    return 20.0 * Float(log10(Double(max(1e-9, p999)) / rms))
}

/// RMS envelope in dB at a fixed hop.
func programEnvelopeDB(_ samples: [Float], sampleRate: Double, hopSeconds: Double) -> [Float] {
    let hop = max(1, Int(sampleRate * hopSeconds))
    var env: [Float] = []
    env.reserveCapacity(samples.count / hop)
    var i = 0
    while i + hop <= samples.count {
        var sumSq: Double = 0.0
        for j in i..<(i + hop) { sumSq += Double(samples[j] * samples[j]) }
        env.append(10.0 * Float(log10(max(1e-12, sumSq / Double(hop)))))
        i += hop
    }
    return env
}

/// Pumping index: beat-band (0.5-4.5 Hz) modulation of the B-vs-A decoded
/// envelope ratio, in dB peak-to-peak equivalent. B is first ALIGNED to A
/// by the SSE-minimizing lag (+/-100 ms): the leveler chain carries ~10 ms
/// more group delay than the classic chain, and an unaligned kick edge
/// reads as beat-rate ratio wiggle -- a misalignment artifact, not pumping
/// (measured 2026-09-04: alignment matters on percussive program).
/// Program-absent hops (envelope below -60 dBFS) repeat the previous ratio
/// so the trace stays uniformly sampled for the spectral share.
func programABPumpingDB(envA: [Float], envB: [Float]) -> Float {
    let n = min(envA.count, envB.count)
    guard n >= 1_024 else { return 0.0 }

    let maxLag = 10  // hops of 10 ms
    var bestLag = 0
    var bestErr = Float.greatestFiniteMagnitude
    for lag in -maxLag...maxLag {
        var err: Float = 0.0
        var count = 0
        var i = max(0, -lag)
        let end = min(n, n - lag)
        while i < end {
            let a = envA[i]
            let b = envB[i + lag]
            if a > -60.0, b > -60.0 {
                err += (b - a) * (b - a)
                count += 1
            }
            i += 1
        }
        if count > 100 {
            err /= Float(count)
            if err < bestErr {
                bestErr = err
                bestLag = lag
            }
        }
    }

    var ratio = [Float](repeating: 0.0, count: n)
    var last: Float = 0.0
    for i in 0..<n {
        let j = i + bestLag
        if j >= 0, j < n, envA[i] > -60.0, envB[j] > -60.0 {
            last = envB[j] - envA[i]
        }
        ratio[i] = last
    }
    // 10 ms hop -> 100 Hz trace rate.
    return beatBandModulationDB(trace: ratio, traceRate: 100.0)
}
