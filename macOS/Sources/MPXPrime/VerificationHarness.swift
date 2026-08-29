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
    captureBaseline: Bool = false,
    strictBaseline: Bool = false
) throws -> Int32 {
    let config = try AppConfig.load(fromINI: configPath)
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
    if !captureBaseline {
        if FileManager.default.fileExists(atPath: baselineURL.path) {
            do {
                let loaded = try loadVerifierBaseline(from: baselineURL)
                loadedBaseline = loaded
                print("Baseline: \(baselineURL.lastPathComponent) (captured \(loaded.capturedAt))")
            } catch {
                print("Baseline: failed to load (\(error))")
            }
        } else {
            print("Baseline: none — run with --capture-baseline to create.")
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
    var anyOverBudget = false
    var scenarioMetrics: [(VerificationScenario, VerificationMetrics)] = []
    var qualityWarnings: [String] = []

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
        anyOverBudget = anyOverBudget || metrics.overBudget
        qualityWarnings.append(
            contentsOf: qualityFindings(scenario: scenario, metrics: metrics).map { "\(scenario.name): \($0)" }
        )

        let line =
            "\(padded(scenario.name, width: 20))  "
            + "\(leftPadded(dbfsString(metrics.peakAbs), width: 9))"
            + "  \(leftPadded(deviationString(peakAbs: metrics.peakAbs, targetDeviationKHz: config.mpxDeviationKHz), width: 7))"
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
                (scenario.name, buildBaselineRecord(
                    metrics: metrics,
                    targetDeviationKHz: config.mpxDeviationKHz
                ))
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
    print("Composite budget exceeded: \(anyOverBudget ? "yes" : "no")")

    if !baselineDrift.isEmpty {
        print("Baseline drift (\(baselineDrift.count) finding\(baselineDrift.count == 1 ? "" : "s")):")
        for finding in baselineDrift {
            print("- \(finding.formattedLine)")
        }
    }

    // Post-injection overshoot is checked FIRST and is a HARD failure
    // (exit 3): the subcarrier budget being violated after injection means
    // the composite is out of spec regardless of any softer finding. It
    // used to sit behind the quality/signature branches, where a
    // coinciding TIGHT finding masked it down to exit 1.
    let naturalResult: Int32
    if !qualityWarnings.isEmpty {
        print("Quality warnings:")
        for warning in qualityWarnings { print("- \(warning)") }
    }
    if worstPostInjectionOvershoot > 1e-4 { naturalResult = 3
    } else if !qualityWarnings.isEmpty { naturalResult = 1
    } else if anyOverBudget { naturalResult = 2
    // Since 0.45 the final look-ahead limiter is the designed stage that
    // rides the composite clipper's guard-band overshoot (the protected
    // pilot / stereo / RDS bands are restored to the clean input, so the
    // clipper alone cannot bound the peak). ~1.5 dB on bright_dense is its
    // normal duty, not a safety event; the old 0.25 / 1.0 dB bounds date
    // from when it sat idle behind the shaper.
    } else if worstSafety > 3.0 { naturalResult = 2
    } else if worstMargin < -0.25 { naturalResult = 2
    } else if worstMargin < 0.0 || worstSafety > 2.0 { naturalResult = 1
    } else { naturalResult = 0 }

    let result: Int32
    if baselineDrift.isEmpty { result = naturalResult } else if strictBaseline { result = max(naturalResult, 2) } else { result = max(naturalResult, 1) }

    switch result {
    case 3:
        print("Result: FAIL - post-injection composite overshoot (subcarrier budget violated after pilot/RDS injection).")
    case 2:
        if strictBaseline && !baselineDrift.isEmpty {
            print("Result: WARN - stored-baseline drift in --baseline-strict mode.")
        } else if worstSafety > 1.0 {
            print("Result: WARN - safety limiter is doing significant work.")
        } else if anyOverBudget || worstPostInjectionOvershoot > 1e-4 {
            print("Result: WARN - post-injection composite budget exceeded.")
        } else {
            print("Result: WARN - composite budget exceeded on at least one scenario.")
        }
    case 1:
        if !qualityWarnings.isEmpty {
            print("Result: TIGHT - composite safety is OK, but decoded-audio quality drift exceeded expected bounds.")
        } else if !baselineDrift.isEmpty {
            print("Result: TIGHT - stored-baseline drift detected (use --baseline-strict to fail the run).")
        } else {
            print("Result: TIGHT - verification stayed close to the composite budget limit.")
        }
    default:
        print(
            longRun
                ? "Result: OK - no obvious long-run compliance or safety regression."
                : "Result: OK - no obvious composite-budget or safety-limiter issue."
        )
    }
    return result
}
