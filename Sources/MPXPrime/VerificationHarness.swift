#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

func runVerificationHarness(
    configPath: String,
    durationSeconds: Double,
    presetSweep: Bool = false,
    longRun: Bool = false,
    receiverModel: Bool = false,
    multibandCouplingComparison: Bool = false,
    advancedDynamicsComparison: Bool = false,
    ssbStereoComparison: Bool = false,
    hfTransientsComparison: Bool = false,
    stereoGuardSweep: Bool = false,
    finalRideIsolation: Bool = false,
    primeBassGate: Bool = false,
    primeBassSweep: Bool = false,
    programAB: Bool = false,
    programABPath: String = "",
    programABProfile: String = "music_clean",
    programABCSV: String? = nil,
    captureBaseline: Bool = false,
    strictBaseline: Bool = false
) throws -> Int32 {
    let config = try AppConfig.load(fromINI: configPath)
    if programAB {
        print("MPX Prime Program A/B Verification (Advanced Dynamics campaign)")
        print("Config: \(configPath) (render rate only; chains use profile defaults)")
        print("")
        return runProgramABVerification(
            baseConfig: config,
            path: programABPath,
            profileID: programABProfile,
            durationSeconds: durationSeconds,
            csvPath: programABCSV
        )
    }
    if primeBassSweep {
        print("MPX Prime PrimeBass Control-Range Sweep")
        print("Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(1.5, min(durationSeconds, 4.0)))) s per scenario")
        print("")
        return runPrimeBassSweep(baseConfig: config, durationSeconds: durationSeconds)
    }
    if primeBassGate {
        print("MPX Prime PrimeBass Verification")
        print("Config: \(configPath) (render rate only; chains use shipped defaults / profile)")
        print("Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(2.0, min(durationSeconds, 6.0)))) s per scenario")
        print("")
        return runPrimeBassVerification(baseConfig: config, durationSeconds: durationSeconds)
    }
    if finalRideIsolation {
        print("MPX Prime Final-MPX Limiter Ride Isolation")
        print("Config: \(configPath)")
        print("Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(3.0, min(durationSeconds, 6.0)))) s per row")
        print("")
        return runFinalRideIsolation(baseConfig: config, durationSeconds: durationSeconds)
    }
    if stereoGuardSweep {
        print("MPX Prime Composite Clipper Stereo Guard Sweep")
        print("Config: \(configPath)")
        print("Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(3.0, min(durationSeconds, 6.0)))) s per point")
        print("")
        return runStereoGuardSweep(baseConfig: config, durationSeconds: durationSeconds)
    }
    if hfTransientsComparison {
        print("MPX Prime HF Transient (hi-hat / cymbal) Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(5.0, min(durationSeconds, 8.0)))) s per variant/scenario"
        )
        print("")
        return runHFTransientVerification(
            baseConfig: config,
            durationSeconds: durationSeconds
        )
    }
    if ssbStereoComparison {
        print("MPX Prime SSB Stereo Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(2.0, durationSeconds))) s"
        )
        print("")
        return runSSBStereoComparison(
            baseConfig: config,
            durationSeconds: durationSeconds
        )
    }
    if advancedDynamicsComparison {
        print("MPX Prime Advanced Dynamics Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(2.0, durationSeconds))) s"
        )
        print("")
        return runAdvancedDynamicsComparison(
            baseConfig: config,
            durationSeconds: durationSeconds
        )
    }
    if multibandCouplingComparison {
        print("MPX Prime Multiband Coupling Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(1.0, durationSeconds))) s"
        )
        print("")
        return runMultibandCouplingComparison(
            baseConfig: config,
            durationSeconds: durationSeconds
        )
    }
    if receiverModel {
        print("MPX Prime Receiver Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz • Duration \(String(format: "%.1f", max(1.0, durationSeconds))) s"
        )
        print("")
        return runReceiverModelVerification(
            baseConfig: config,
            configPath: configPath,
            durationSeconds: durationSeconds,
            captureBaseline: captureBaseline,
            strictBaseline: strictBaseline
        )
    }
    if presetSweep {
        print("MPX Prime Preset Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz • Block \(config.blockSize) • Sweep Duration \(String(format: "%.1f", min(durationSeconds, 1.0))) s"
        )
        print("")
        return runPresetSweepVerification(
            baseConfig: config,
            durationSeconds: durationSeconds,
            captureBaseline: captureBaseline,
            strictBaseline: strictBaseline
        )
    }
    let scenarios = longRun ? longRunVerificationScenarios() : verificationScenarios()

    print(longRun ? "MPX Prime Long-Run Verification" : "MPX Prime Verification")
    print("Config: \(configPath)")
    print(
        "Render: \(Int(config.sampleRate)) Hz • Block \(config.blockSize) • Duration \(String(format: "%.1f", durationSeconds)) s"
    )
    print(
        "Final Stage: composite clipper \(config.compositeClipperEnabled ? "on" : "off")"
            + " • MPX safety limiter \(config.limitMPX ? "on" : "off")"
            + " • safety soft clip \(config.audioCompositeSoftClipEnabled ? "on" : "off")"
    )
    if longRun {
        print("Scope: focused program-material compliance/regression scenarios")
    }

    // Long-run pins its own baseline file (different scenario set + 30 s
    // duration); the default sweep keeps default.json. Both platform-suffixed.
    let baselineURL = longRun ? defaultLongRunBaselinePath() : defaultVerifierBaselinePath()
    var loadedBaseline: VerifierBaselineFile?
    var baselineAvailability = BaselineAvailability.loaded
    if !captureBaseline {
        // A missing, undecodable or other-schema baseline is reported here
        // and, under --baseline-strict, fails the run (WARN) instead of
        // silently falling back to the physical limits.
        let attempt = classifyBaselineLoad { try loadVerifierBaseline(from: baselineURL) }
        loadedBaseline = attempt.value
        baselineAvailability = attempt.availability
        switch attempt.availability {
        case .loaded:
            if let loaded = attempt.value {
                print("Baseline: \(baselineURL.lastPathComponent) (captured \(loaded.capturedAt))")
            }
        case .missing:
            print("Baseline: none at \(baselineURL.path) - run with --capture-baseline to create.")
        case .unreadable(let reason):
            print("Baseline: failed to load (\(reason))")
        }
    }

    print("")
    print(
        "Scenario              Peak dBFS  Dev kHz  LimGR  SafeGR  AudioPk  POvr   Bdg  Pilot  RDS   Margin  AGC"
    )
    print(
        "--------------------  ---------  -------  -----  ------  -------  -----  ---  -----  ----  ------  ----"
    )

    var worstPeak: Float = 0.0
    var worstSafety: Float = 0.0
    var worstMargin: Float = .greatestFiniteMagnitude
    var worstPostInjectionOvershoot: Float = 0.0
    var worstTruePeakOvershootDB: Float = 0.0
    var worstTruePeakAbs: Float = 0.0
    var anyOverBudget = false
    var scenarioMetrics: [(VerificationScenario, VerificationMetrics)] = []
    var qualityWarnings: [String] = []
    if config.widebandAGCEnabled, config.widebandAGCAttackMS < 50.0 {
        // 0.45 B1: the AGC is a gain rider; peaks belong to the limiter. A
        // limiter-fast attack ducks whole-program level on every drum hit and
        // holds it for the release (Orban WP "hole punching").
        qualityWarnings.append(
            "wideband AGC attack \(String(format: "%.0f", config.widebandAGCAttackMS)) ms is limiter-fast (< 50 ms); profiles use 100-200 ms")
    }

    for scenario in scenarios {
        let metrics = verifyScenario(
            config: config,
            durationSeconds: durationSeconds,
            scenario: scenario
        )
        scenarioMetrics.append((scenario, metrics))
        worstPeak = max(worstPeak, metrics.peakAbs)
        worstSafety = max(worstSafety, metrics.maxSafetyGRDB)
        worstMargin = min(worstMargin, metrics.minBudgetMarginDB)
        worstPostInjectionOvershoot = max(worstPostInjectionOvershoot, metrics.maxPostInjectionOvershoot)
        worstTruePeakOvershootDB = max(worstTruePeakOvershootDB, truePeakOvershootDB(metrics: metrics))
        worstTruePeakAbs = max(worstTruePeakAbs, metrics.truePeakAbs)
        anyOverBudget = anyOverBudget || metrics.overBudget
        qualityWarnings.append(
            contentsOf: qualityFindings(scenario: scenario, metrics: metrics).map { "\(scenario.name): \($0)" }
        )

        let line =
            "\(padded(scenario.name, width: 20))  "
            + "\(leftPadded(dbfsString(metrics.peakAbs), width: 9))"
            + "  \(leftPadded(deviationString(peakAbs: metrics.peakAbs), width: 7))"
            + "  \(String(format: "%5.1f", nonNegative(metrics.maxLimiterGRDB)))"
            + "  \(String(format: "%6.1f", nonNegative(metrics.maxSafetyGRDB)))"
            + "  \(leftPadded(dbfsString(metrics.maxAudioCompositePeak), width: 7))"
            + "  \(String(format: "%5.4f", metrics.maxPostInjectionOvershoot))"
            + "  \(metrics.overBudget ? "YES" : " no")"
            + "  \(String(format: "%5.1f", metrics.pilotPercent))"
            + "  \(String(format: "%4.1f", metrics.rdsPercent))"
            + "  \(String(format: "%6.1f", metrics.minBudgetMarginDB))"
            + "  \(String(format: "%4.1f", metrics.maxAGCReductionDB))"
        print(line)
    }

    print("")
    print("Stereo Quality")
    print(
        "Scenario              InCorr  OutCorr  InSide  OutSide  dRMS"
    )
    print(
        "--------------------  ------  -------  ------  -------  -----"
    )

    for (scenario, metrics) in scenarioMetrics {
        let qualityFlag = qualityFindings(scenario: scenario, metrics: metrics).isEmpty ? "OK" : "WARN"
        let line =
            "\(padded(scenario.name, width: 20))  "
            + "\(String(format: "%6.2f", metrics.inputSignal.correlation))"
            + "  \(String(format: "%7.2f", metrics.outputSignal.correlation))"
            + "  \(ratioString(metrics.inputSignal.sideToMidRatio, width: 6))"
            + "  \(ratioString(metrics.outputSignal.sideToMidRatio, width: 7))"
            + "  \(String(format: "%5.1f", metrics.rmsDeltaDB))"
            + "  \(qualityFlag)"
        print(line)
    }

    print("")
    print("MPX Width")
    print(
        "Scenario              Occ999 Hz  >60k/In  >67k/In"
    )
    print(
        "--------------------  ---------  -------  -------"
    )

    for (scenario, metrics) in scenarioMetrics {
        let line =
            "\(padded(scenario.name, width: 20))  "
            + "\(leftPadded(String(format: "%.0f", metrics.bandwidth.occupied999Hz), width: 9))"
            + "  \(leftPadded(String(format: "%.1f", metrics.bandwidth.above60kRatioDB), width: 7))"
            + "  \(leftPadded(String(format: "%.1f", metrics.bandwidth.above67kRatioDB), width: 7))"
        print(line)
    }

    var baselineDrift: [BaselineDriftFinding] = []
    do {
        let measured: [String: VerifierBaselineRecord] = Dictionary(
            uniqueKeysWithValues: scenarioMetrics.map { scenario, metrics in
                (scenario.name, buildBaselineRecord(metrics: metrics))
            }
        )
        // Encoder-side sideband fingerprint: computed only when capturing
        // or when there is a stored fingerprint to compare against, so a
        // plain `--verify` with no baseline doesn't pay the extra renders.
        // Long-run skips it: the fingerprint is a default-sweep concept and
        // long.json pins scenario metrics only.
        let needSidebands = !longRun
            && (captureBaseline || (loadedBaseline?.encoderSidebands != nil))
        let sidebandDuration = max(0.75, min(durationSeconds, 1.0))
        let measuredSidebands: EncoderSidebandBaselineRecord? = needSidebands
            ? buildEncoderSidebandBaseline(config: config, durationSeconds: sidebandDuration)
            : nil

        if captureBaseline {
            let file = VerifierBaselineFile(
                schemaVersion: VerifierBaselineFile.currentSchemaVersion,
                capturedAt: verifierBaselineTimestampNow(),
                configPath: configPath,
                renderSampleRateHz: Int(config.sampleRate),
                blockSize: config.blockSize,
                durationSeconds: durationSeconds,
                scenarios: measured,
                encoderSidebands: measuredSidebands
            )
            do {
                try saveVerifierBaseline(file, to: baselineURL)
                print("")
                print("Baseline captured: \(baselineURL.path)")
                print("  \(measured.count) scenarios written.")
                if measuredSidebands != nil {
                    print("  encoder sideband fingerprint written (1/10/14 kHz).")
                }
            } catch {
                print("")
                print("Baseline capture FAILED: \(error)")
            }
        } else if let baseline = loadedBaseline {
            baselineDrift = compareBaseline(measured: measured, baseline: baseline)
            if let storedSidebands = baseline.encoderSidebands,
                let measuredSidebands = measuredSidebands {
                baselineDrift.append(contentsOf: compareEncoderSidebands(
                    measured: measuredSidebands,
                    baseline: storedSidebands
                ))
            }
        }
    }

    print("")
    print("Assessment")
    print("Worst MPX peak: \(dbfsString(worstPeak)) dBFS")
    print("Worst safety limiter GR: \(String(format: "%.1f", nonNegative(worstSafety))) dB")
    print("Worst composite margin: \(String(format: "%.1f", worstMargin)) dB")
    print("Worst post-injection overshoot: \(String(format: "%.6f", worstPostInjectionOvershoot))")
    print("Worst inter-sample (4x true-peak) overshoot: \(String(format: "%.2f", worstTruePeakOvershootDB)) dB")
    print("Worst 4x true peak: \(dbfsString(worstTruePeakAbs)) dBFS")
    print("Composite budget exceeded: \(anyOverBudget ? "yes" : "no")")

    if !baselineDrift.isEmpty {
        print("Baseline drift (\(baselineDrift.count) finding\(baselineDrift.count == 1 ? "" : "s")):")
        for finding in baselineDrift {
            print("- \(finding.formattedLine)")
        }
    }

    // Every rule is evaluated on its own and the exit code is the STRONGEST
    // (`compositeVerdict`, Verification/VerifierVerdict.swift): post-injection
    // overshoot FAIL (3), then the WARN rules (over budget, safety limiter
    // above 4 dB, margin below -0.25 dB, true peak above +0.25 dBFS, strict
    // baseline drift or an unusable strict baseline), then TIGHT. The old
    // if / else-if ladder tested the quality warnings before the WARN rules,
    // so a coinciding TIGHT masked an over-budget composite.
    if !qualityWarnings.isEmpty {
        print("Quality warnings:")
        for warning in qualityWarnings { print("- \(warning)") }
    }
    let verdictInputs = CompositeVerdictInputs(
        worstPostInjectionOvershoot: worstPostInjectionOvershoot,
        qualityWarningCount: qualityWarnings.count,
        anyOverBudget: anyOverBudget,
        worstSafetyGRDB: worstSafety,
        worstBudgetMarginDB: worstMargin,
        worstTruePeakDBFS: worstTruePeakAbs > 1e-9 ? 20.0 * log10f(worstTruePeakAbs) : -.infinity,
        baselineDriftCount: baselineDrift.count,
        baselineUnavailable: !captureBaseline && !baselineAvailability.isUsable,
        strictBaseline: strictBaseline
    )
    let findings = compositeVerdictFindings(verdictInputs)
    let result = findings.first?.level ?? 0
    if let strongest = findings.first {
        print("Result: \(strongest.message)")
        for other in findings.dropFirst() { print("  also: \(other.message)") }
    } else {
        print(
            longRun
                ? "Result: OK - no obvious long-run compliance or safety regression."
                : "Result: OK - no obvious composite-budget or safety-limiter issue."
        )
    }
    return result
}
