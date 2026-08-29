#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

func keyMultibandPresetSweeps() -> [VerificationPresetSweep] {
    [
        VerificationPresetSweep(id: "5_ac", title: "5B AC/Pop") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_ac"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 90.0
            config.multibandX2Hz = 350.0
            config.multibandX3Hz = 1800.0
            config.multibandX4Hz = 6800.0
            config.multibandLowThresholdDB = -17.5
            config.multibandMidThresholdDB = -16.0
            config.multibandHighThresholdDB = -14.5
            config.multibandLowRatio = 1.75
            config.multibandMidRatio = 1.55
            config.multibandHighRatio = 1.28
            config.multibandLowAttackMS = 28.0
            config.multibandMidAttackMS = 19.0
            config.multibandHighAttackMS = 13.0
            config.multibandLowReleaseMS = 375.0
            config.multibandMidReleaseMS = 300.0
            config.multibandHighReleaseMS = 225.0
            config.multibandKneeDB = 3.6
            config.multibandLinkStrength = 0.52
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_chr", title: "5B CHR/EDM") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_chr"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 90.0
            config.multibandX2Hz = 320.0
            config.multibandX3Hz = 1600.0
            config.multibandX4Hz = 6200.0
            config.multibandLowThresholdDB = -23.0
            config.multibandMidThresholdDB = -21.0
            config.multibandHighThresholdDB = -19.0
            config.multibandLowRatio = 2.25
            config.multibandMidRatio = 1.9
            config.multibandHighRatio = 1.6
            config.multibandLowAttackMS = 20.0
            config.multibandMidAttackMS = 13.0
            config.multibandHighAttackMS = 8.0
            config.multibandLowReleaseMS = 320.0
            config.multibandMidReleaseMS = 240.0
            config.multibandHighReleaseMS = 180.0
            config.multibandKneeDB = 2.6
            config.multibandLinkStrength = 0.48
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_rock", title: "5B Rock") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_rock"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 90.0
            config.multibandX2Hz = 340.0
            config.multibandX3Hz = 1550.0
            config.multibandX4Hz = 6100.0
            config.multibandLowThresholdDB = -21.0
            config.multibandMidThresholdDB = -19.0
            config.multibandHighThresholdDB = -18.0
            config.multibandLowRatio = 2.1
            config.multibandMidRatio = 1.85
            config.multibandHighRatio = 1.55
            config.multibandLowAttackMS = 20.0
            config.multibandMidAttackMS = 13.0
            config.multibandHighAttackMS = 8.0
            config.multibandLowReleaseMS = 320.0
            config.multibandMidReleaseMS = 240.0
            config.multibandHighReleaseMS = 175.0
            config.multibandKneeDB = 2.5
            config.multibandLinkStrength = 0.46
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_talk", title: "5B Talk") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_talk"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 110.0
            config.multibandX2Hz = 420.0
            config.multibandX3Hz = 2200.0
            config.multibandX4Hz = 7600.0
            config.multibandLowThresholdDB = -12.5
            config.multibandMidThresholdDB = -11.8
            config.multibandHighThresholdDB = -11.2
            config.multibandLowRatio = 1.24
            config.multibandMidRatio = 1.18
            config.multibandHighRatio = 1.08
            config.multibandLowAttackMS = 48.0
            config.multibandMidAttackMS = 40.0
            config.multibandHighAttackMS = 30.0
            config.multibandLowReleaseMS = 560.0
            config.multibandMidReleaseMS = 450.0
            config.multibandHighReleaseMS = 360.0
            config.multibandKneeDB = 5.2
            config.multibandLinkStrength = 0.46
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_news", title: "5B News") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_news"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 110.0
            config.multibandX2Hz = 450.0
            config.multibandX3Hz = 2100.0
            config.multibandX4Hz = 7600.0
            config.multibandLowThresholdDB = -15.0
            config.multibandMidThresholdDB = -14.0
            config.multibandHighThresholdDB = -13.0
            config.multibandLowRatio = 1.4
            config.multibandMidRatio = 1.35
            config.multibandHighRatio = 1.25
            config.multibandLowAttackMS = 40.0
            config.multibandMidAttackMS = 34.0
            config.multibandHighAttackMS = 24.0
            config.multibandLowReleaseMS = 500.0
            config.multibandMidReleaseMS = 400.0
            config.multibandHighReleaseMS = 320.0
            config.multibandKneeDB = 4.3
            config.multibandLinkStrength = 0.64
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_urban", title: "5B Urban") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_urban"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 85.0
            config.multibandX2Hz = 300.0
            config.multibandX3Hz = 1300.0
            config.multibandX4Hz = 5400.0
            config.multibandLowThresholdDB = -23.0
            config.multibandMidThresholdDB = -21.0
            config.multibandHighThresholdDB = -19.0
            config.multibandLowRatio = 2.3
            config.multibandMidRatio = 2.0
            config.multibandHighRatio = 1.7
            config.multibandLowAttackMS = 18.0
            config.multibandMidAttackMS = 12.0
            config.multibandHighAttackMS = 7.0
            config.multibandLowReleaseMS = 295.0
            config.multibandMidReleaseMS = 220.0
            config.multibandHighReleaseMS = 155.0
            config.multibandKneeDB = 2.2
            config.multibandLinkStrength = 0.42
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_dance", title: "5B Dance") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_dance"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 80.0
            config.multibandX2Hz = 290.0
            config.multibandX3Hz = 1200.0
            config.multibandX4Hz = 5000.0
            config.multibandLowThresholdDB = -24.0
            config.multibandMidThresholdDB = -22.0
            config.multibandHighThresholdDB = -20.0
            config.multibandLowRatio = 2.5
            config.multibandMidRatio = 2.1
            config.multibandHighRatio = 1.75
            config.multibandLowAttackMS = 16.0
            config.multibandMidAttackMS = 11.0
            config.multibandHighAttackMS = 6.0
            config.multibandLowReleaseMS = 285.0
            config.multibandMidReleaseMS = 215.0
            config.multibandHighReleaseMS = 150.0
            config.multibandKneeDB = 2.0
            config.multibandLinkStrength = 0.40
            config.multibandReleaseProgramDependent = true
        }
    ]
}

func presetQualityOverride(
    for sweep: VerificationPresetSweep,
    scenario: VerificationScenario
) -> QualityExpectations? {
    guard sweep.id == "5_talk" || sweep.id == "5_news" else { return nil }
    switch scenario.name {
    case "vocal_sibilant":
        return QualityExpectations(
            maxCorrelationDelta: 0.24,
            maxOutputCorrelation: 0.95,
            minSideRetention: 0.60,
            maxAbsRMSDeltaDB: 3.2,
            maxOccupied999Hz: 58_500.0,
            maxAbove60kRatioDB: -40.0,
            maxAbove67kRatioDB: -50.0
        )
    case "transient_push":
        return QualityExpectations(
            maxCorrelationDelta: 0.18,
            maxOutputCorrelation: 0.92,
            minSideRetention: 0.68,
            maxAbsRMSDeltaDB: 3.4,
            maxOccupied999Hz: 58_500.0,
            maxAbove60kRatioDB: -44.0,
            maxAbove67kRatioDB: -52.0
        )
    default:
        return nil
    }
}

func runPresetSweepVerification(
    baseConfig: AppConfig,
    durationSeconds: Double,
    captureBaseline: Bool = false,
    strictBaseline: Bool = false
) -> Int32 {
    let sweepDuration = min(durationSeconds, 1.0)
    let scenarios = verificationScenarios().filter {
        ["bright_dense", "vocal_sibilant", "transient_push"].contains($0.name)
    }
    let sweeps = keyMultibandPresetSweeps()
    var worstExit: Int32 = 0
    // Per-(preset, scenario) records for the strict baseline, keyed
    // "<presetID>/<scenario>" in the same VerifierBaselineFile schema.
    var measured: [String: VerifierBaselineRecord] = [:]

    let baselineURL = defaultPresetBaselinePath()
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
            print("Baseline: none — run --verify-presets --capture-baseline to create.")
        }
    }

    print("Preset Sweep")
    print("Count: \(sweeps.count)")
    print("Preset                Peak dBFS  Margin  POvr   Bdg  Result")
    print("--------------------  ---------  ------  -----  ---  ------")

    for sweep in sweeps {
        var config = baseConfig
        sweep.apply(&config)

        var presetWorstPeak: Float = 0.0
        var presetWorstMargin: Float = .greatestFiniteMagnitude
        var presetWarnings: [String] = []
        var presetWorstOvershoot: Float = 0.0
        var presetOverBudget = false

        for scenario in scenarios {
            let metrics = verifyScenario(
                config: config,
                durationSeconds: sweepDuration,
                scenario: scenario
            )
            let expectationsOverride = presetQualityOverride(for: sweep, scenario: scenario)
            measured["\(sweep.id)/\(scenario.name)"] = buildBaselineRecord(
                metrics: metrics,
                targetDeviationKHz: config.mpxDeviationKHz
            )
            presetWorstPeak = max(presetWorstPeak, metrics.peakAbs)
            presetWorstMargin = min(presetWorstMargin, metrics.minBudgetMarginDB)
            presetWorstOvershoot = max(presetWorstOvershoot, metrics.maxPostInjectionOvershoot)
            presetOverBudget = presetOverBudget || metrics.overBudget
            presetWarnings.append(
                contentsOf: qualityFindings(
                    scenario: scenario,
                    metrics: metrics,
                    expectationsOverride: expectationsOverride
                ).map {
                    "\(scenario.name): \($0)"
                }
            )
        }

        let resultText: String
        let exitCode: Int32
        // Post-injection overshoot is a hard FAIL (exit 3) for presets:
        // a shipped preset must never violate the subcarrier budget.
        if presetWorstOvershoot > 1e-4 {
            resultText = "FAIL"
            exitCode = 3
        } else if presetOverBudget || presetWorstMargin < -0.25 {
            resultText = "WARN"
            exitCode = 2
        } else if !presetWarnings.isEmpty || presetWorstMargin < 0.0 {
            resultText = "TIGHT"
            exitCode = 1
        } else {
            resultText = "OK"
            exitCode = 0
        }
        worstExit = max(worstExit, exitCode)

        print(
            "\(padded(sweep.title, width: 20))  "
                + "\(leftPadded(dbfsString(presetWorstPeak), width: 9))"
                + "  \(String(format: "%6.1f", presetWorstMargin))"
                + "  \(String(format: "%5.4f", presetWorstOvershoot))"
                + "  \(presetOverBudget ? "YES" : " no")"
                + "  \(resultText)"
        )

        for warning in presetWarnings {
            print("  - \(warning)")
        }
    }

    print("")
    if captureBaseline {
        let file = VerifierBaselineFile(
            schemaVersion: VerifierBaselineFile.currentSchemaVersion,
            capturedAt: verifierBaselineTimestampNow(),
            configPath: "presets",
            renderSampleRateHz: Int(baseConfig.sampleRate),
            blockSize: baseConfig.blockSize,
            durationSeconds: sweepDuration,
            scenarios: measured,
            encoderSidebands: nil
        )
        do {
            try saveVerifierBaseline(file, to: baselineURL)
            print("Baseline captured: \(baselineURL.path)")
            print("  \(measured.count) preset/scenario records written.")
        } catch {
            print("Baseline capture FAILED: \(error)")
        }
    } else if let baseline = loadedBaseline {
        let drift = compareBaseline(measured: measured, baseline: baseline)
        if !drift.isEmpty {
            print("Baseline drift:")
            for finding in drift { print("- \(finding.formattedLine)") }
            worstExit = max(worstExit, strictBaseline ? 2 : 1)
        }
    }
    return worstExit
}
