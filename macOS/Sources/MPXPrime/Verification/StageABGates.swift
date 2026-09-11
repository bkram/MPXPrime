#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

func multibandCouplingComparisonScenarios() -> [VerificationScenario] {
    var denseNoiseL = DeterministicNoise(seed: 0xC011_0000_0000_0001)
    var denseNoiseR = DeterministicNoise(seed: 0xC011_0000_0000_0002)
    var speechNoise = DeterministicNoise(seed: 0xC011_0000_0000_0003)
    return [
        VerificationScenario(
            name: "bass_dense",
            description: "Dense bass-heavy music bed",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let kickEnv = pow(max(0.0, sin(2.0 * Double.pi * 2.1 * t)), 8.0)
            let bass = (0.50 + (0.35 * kickEnv)) * sin(2.0 * Double.pi * 62.0 * t)
            let lowMid = 0.20 * sin(2.0 * Double.pi * 240.0 * t)
            let vocal = 0.18 * sin(2.0 * Double.pi * 1_300.0 * t)
            let air = 0.10 * sin(2.0 * Double.pi * 7_200.0 * t)
            let l = Float(bass + lowMid + vocal + air) + (denseNoiseL.next() * 0.025)
            let r = Float((0.92 * bass) + (0.18 * lowMid) - (0.14 * vocal) + (0.08 * air))
                + (denseNoiseR.next() * 0.025)
            return (l, r)
        },
        VerificationScenario(
            name: "kick_vocal",
            description: "Kick/bass under vocal presence",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let beat = pow(max(0.0, sin(2.0 * Double.pi * 2.0 * t)), 10.0)
            let kick = beat * sin(2.0 * Double.pi * 78.0 * t)
            let bass = 0.44 * sin(2.0 * Double.pi * 118.0 * t)
            let vowel = 0.22 * sin(2.0 * Double.pi * 720.0 * t)
            let consonant = 0.16 * sin(2.0 * Double.pi * 3_100.0 * t)
            let l = Float((0.46 * kick) + bass + vowel + consonant + (0.05 * sin(2.0 * Double.pi * 6_400.0 * t)))
            let r = Float((0.43 * kick) + (0.96 * bass) + (0.20 * vowel) - (0.13 * consonant))
            return (l, r)
        },
        VerificationScenario(
            name: "italo_pump",
            description: "Four-on-floor dance-style bass and bright synths",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let kickEnv = pow(max(0.0, sin(2.0 * Double.pi * 2.0 * t)), 12.0)
            let kick = kickEnv * sin(2.0 * Double.pi * 54.0 * t)
            let bass = 0.46 * sin(2.0 * Double.pi * 108.0 * t)
            let synth = 0.22 * sin(2.0 * Double.pi * 1_700.0 * t)
            let hat = 0.13 * sin(2.0 * Double.pi * 9_200.0 * t)
            return (
                Float((0.62 * kick) + bass + synth + hat),
                Float((0.58 * kick) + (0.92 * bass) - (0.18 * synth) + (0.10 * hat))
            )
        },
        VerificationScenario(
            name: "wide_bass",
            description: "Wide bass stereo stress from standard verifier",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let bass = sin(2.0 * Double.pi * 72.0 * t)
            let upper = sin(2.0 * Double.pi * 1_600.0 * t)
            return (
                Float((0.62 * bass) + (0.20 * upper)),
                Float((-0.38 * bass) + (0.18 * upper))
            )
        },
        VerificationScenario(
            name: "speech_bed",
            description: "Speech-like mids over a music bed",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let bed = 0.30 * sin(2.0 * Double.pi * 95.0 * t)
            let speechEnv = 0.42 + (0.20 * sin(2.0 * Double.pi * 3.7 * t))
            let speech =
                speechEnv
                * ((0.20 * sin(2.0 * Double.pi * 480.0 * t))
                    + (0.18 * sin(2.0 * Double.pi * 1_250.0 * t))
                    + (0.10 * sin(2.0 * Double.pi * 2_800.0 * t)))
            let n = Double(speechNoise.next()) * 0.030
            return (Float(bed + speech + n), Float((0.96 * bed) + (0.92 * speech) + n))
        }
    ]
}

func runMultibandCouplingComparison(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let compareDuration = max(1.0, min(durationSeconds, 5.0))
    var disabledConfig = baseConfig
    disabledConfig.widebandAGCEnabled = false
    disabledConfig.multibandEnabled = true
    disabledConfig.multibandMode = 5
    disabledConfig.multibandLowThresholdDB = -30.0
    disabledConfig.multibandMidThresholdDB = -22.0
    disabledConfig.multibandHighThresholdDB = -20.0
    disabledConfig.multibandLowRatio = 4.0
    disabledConfig.multibandMidRatio = 1.8
    disabledConfig.multibandHighRatio = 1.45
    disabledConfig.multibandLinkStrength = 0.65
    disabledConfig.multibandInterBandCouplingEnabled = false

    var enabledConfig = disabledConfig
    enabledConfig.multibandInterBandCouplingEnabled = true

    print("Multiband Inter-Band Coupling A/B")
    print("Toggle: multiband_inter_band_coupling_enabled")
    print("Scope: forced multiband-on, AGC-off program scenarios; production default remains toggle-off")
    print("")
    print("Scenario              LowDelta  MidDelta  HighDelta  RMSDelta  CorrDelta  SideDelta  PeakDelta  POvrOn")
    print("--------------------  --------  --------  ---------  --------  ---------  ---------  ---------  ------")

    var warnings: [String] = []
    var usefulCount = 0
    var offNanos: UInt64 = 0
    var onNanos: UInt64 = 0

    for scenario in multibandCouplingComparisonScenarios() {
        let offStart = DispatchTime.now().uptimeNanoseconds
        let off = verifyScenario(
            config: disabledConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        offNanos += DispatchTime.now().uptimeNanoseconds - offStart

        let onStart = DispatchTime.now().uptimeNanoseconds
        let on = verifyScenario(
            config: enabledConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        onNanos += DispatchTime.now().uptimeNanoseconds - onStart

        let lowDelta = on.outputBands.lowDBFS - off.outputBands.lowDBFS
        let midDelta = on.outputBands.midDBFS - off.outputBands.midDBFS
        let highDelta = on.outputBands.highDBFS - off.outputBands.highDBFS
        let rmsDelta = on.rmsDeltaDB - off.rmsDeltaDB
        let corrDelta = on.outputSignal.correlation - off.outputSignal.correlation
        let sideDelta = ratioDB(on.outputSignal.sideToMidRatio, off.outputSignal.sideToMidRatio)
        let peakDelta = dbfsValue(on.peakAbs) - dbfsValue(off.peakAbs)

        if on.maxPostInjectionOvershoot > 1e-4 || on.overBudget {
            warnings.append("\(scenario.name): enabled path exceeded composite budget")
        }
        if abs(corrDelta) > 0.15 {
            warnings.append("\(scenario.name): output correlation changed by \(String(format: "%+.2f", corrDelta))")
        }
        if sideDelta < -1.5 {
            warnings.append("\(scenario.name): side/mid fell by \(String(format: "%.1f", -sideDelta)) dB")
        }
        if highDelta < -0.05 || midDelta < -0.05 {
            usefulCount += 1
        }

        print(
            "\(padded(scenario.name, width: 20))  "
                + "\(String(format: "%+8.2f", lowDelta))"
                + "  \(String(format: "%+8.2f", midDelta))"
                + "  \(String(format: "%+9.2f", highDelta))"
                + "  \(String(format: "%+8.2f", rmsDelta))"
                + "  \(String(format: "%+9.2f", corrDelta))"
                + "  \(String(format: "%+9.2f", sideDelta))"
                + "  \(String(format: "%+9.2f", peakDelta))"
                + "  \(String(format: "%6.4f", on.maxPostInjectionOvershoot))"
        )
    }

    let costRatio = Double(onNanos) / max(1.0, Double(offNanos))
    print("")
    print("Cost ratio: \(String(format: "%.2fx", costRatio)) (enabled/offline render wall time)")
    print("")
    print("Assessment")
    if usefulCount == 0 {
        warnings.append("enabled path did not measurably reduce mid/high energy on the comparison scenarios")
    }
    if costRatio > 1.25 {
        warnings.append("enabled path cost ratio \(String(format: "%.2fx", costRatio)) exceeds 1.25x")
    }
    if warnings.isEmpty {
        print("Result: OK - coupling stayed safe and measurably shaped upper-band energy.")
        return 0
    }
    print("Comparison notes:")
    for warning in warnings {
        print("- \(warning)")
    }
    print("Result: TIGHT - coupling is implemented, but preset use needs review.")
    return 1
}

/// A/B: classic DSB stereo encoding vs the SSB-leaning
/// encoder, on program scenarios plus tone-based sideband and
/// receiver-decode measurements. This is the HARD GATE for the SSB
/// asymmetry: it reports the composite-peak headroom actually reclaimed
/// AND fails to TIGHT when coherent decode separation degrades past
/// tolerance, so the trick can never ship a separation regression.
func runSSBStereoComparison(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let compareDuration = max(2.0, min(durationSeconds, 6.0))
    var offConfig = baseConfig
    offConfig.ssbStereoEnabled = false
    var onConfig = offConfig
    onConfig.ssbStereoEnabled = true

    // Headroom-reclaim measurement needs a LINEAR composite: downstream
    // peak controllers flatten both variants to the same ceiling, hiding
    // exactly the effect being measured. The scenario table therefore runs
    // with clipper/limiter/soft-clip off; the tone table below runs the
    // full production chain for the safety metrics.
    var offLinear = offConfig
    offLinear.compositeClipperEnabled = false
    offLinear.limitMPX = false
    offLinear.audioCompositeSoftClipEnabled = false
    var onLinear = offLinear
    onLinear.ssbStereoEnabled = true

    print("SSB Stereo A/B (classic DSB stereo vs SSB-leaning encoder)")
    print("Toggle: mpx_ssb_stereo_enabled  (ssb_amount \(String(format: "%.2f", onConfig.ssbStereoAmount)))")
    print("Scope: program scenarios (LINEAR composite -- peak controllers off, so the")
    print("encoder's raw headroom effect is visible) + tone sidebands + coherent decode")
    print("on the full chain; production default remains toggle-off")
    print("")
    print("Scenario              PeakDelta  AudioPkDelta  CorrDelta  SideDelta  POvrOn")
    print("--------------------  ---------  ------------  ---------  ---------  ------")

    var warnings: [String] = []
    var totalReclaimDB: Float = 0.0
    var scenarioCount = 0

    for scenario in advancedDynamicsComparisonScenarios() {
        let off = verifyScenario(
            config: offLinear, durationSeconds: compareDuration, scenario: scenario)
        let on = verifyScenario(
            config: onLinear, durationSeconds: compareDuration, scenario: scenario)

        let peakDelta = dbfsValue(on.peakAbs) - dbfsValue(off.peakAbs)
        let audioPkDelta = dbfsValue(on.maxAudioCompositePeak) - dbfsValue(off.maxAudioCompositePeak)
        let corrDelta = on.outputSignal.correlation - off.outputSignal.correlation
        let sideDelta = ratioDB(on.outputSignal.sideToMidRatio, off.outputSignal.sideToMidRatio)
        totalReclaimDB += -audioPkDelta
        scenarioCount += 1

        if on.maxPostInjectionOvershoot > 1e-4 || on.overBudget {
            warnings.append("\(scenario.name): SSB path exceeded composite budget")
        }
        if abs(corrDelta) > 0.2 {
            warnings.append("\(scenario.name): output correlation changed by \(String(format: "%+.2f", corrDelta))")
        }

        print(
            "\(padded(scenario.name, width: 20))  "
                + "\(String(format: "%+9.2f", peakDelta))"
                + "  \(String(format: "%+12.2f", audioPkDelta))"
                + "  \(String(format: "%+9.2f", corrDelta))"
                + "  \(String(format: "%+9.2f", sideDelta))"
                + "  \(String(format: "%6.4f", on.maxPostInjectionOvershoot))"
        )
    }

    // Tone-based sideband shape: the SSB action itself (asymmetry should
    // GROW with the toggle) and the receiver-decode cost (coherent
    // separation must stay within tolerance).
    print("")
    print("Tone      AsymOff   AsymOn   SepOff    SepOn    SepDelta")
    print("--------  -------  -------  -------  -------  ---------")
    let toneDuration = max(3.0, compareDuration)
    var minSeparationOn: Float = 1_000.0
    for toneHz in [1_000.0, 10_000.0, 14_000.0] {
        let sbOff = encoderSidebandMetrics(
            config: offConfig, toneHz: toneHz, drivenChannel: "L", durationSeconds: toneDuration)
        let sbOn = encoderSidebandMetrics(
            config: onConfig, toneHz: toneHz, drivenChannel: "L", durationSeconds: toneDuration)
        let sepOff = receiverToneAnalysis(
            config: offConfig, toneHz: toneHz, durationSeconds: toneDuration).coherent.separationDB
        let sepOn = receiverToneAnalysis(
            config: onConfig, toneHz: toneHz, durationSeconds: toneDuration).coherent.separationDB
        minSeparationOn = min(minSeparationOn, sepOn)
        let sepDelta = sepOn - sepOff
        if sepDelta < -6.0 {
            warnings.append("\(Int(toneHz)) Hz: coherent separation dropped \(String(format: "%.1f", -sepDelta)) dB (> 6 dB)")
        }
        print(
            "\(padded("\(Int(toneHz)) Hz", width: 8))  "
                + "\(String(format: "%7.2f", sbOff.asymmetryDB))"
                + "  \(String(format: "%7.2f", sbOn.asymmetryDB))"
                + "  \(String(format: "%7.1f", sepOff))"
                + "  \(String(format: "%7.1f", sepOn))"
                + "  \(String(format: "%+9.1f", sepDelta))"
        )
    }

    let meanReclaimDB = scenarioCount > 0 ? totalReclaimDB / Float(scenarioCount) : 0.0
    print("")
    print("Mean audio-composite peak reclaim: \(String(format: "%.2f", meanReclaimDB)) dB")
    print("")
    print("Assessment")
    if minSeparationOn < 20.0 {
        warnings.append("coherent separation fell below 20 dB with SSB on (\(String(format: "%.1f", minSeparationOn)) dB)")
    }
    if meanReclaimDB < 0.05 {
        warnings.append("SSB path reclaimed no measurable composite headroom on the comparison scenarios")
    }
    if warnings.isEmpty {
        print("Result: OK - SSB leaning reclaimed headroom without a decode regression.")
        return 0
    }
    print("Comparison notes:")
    for warning in warnings {
        print("- \(warning)")
    }
    print("Result: TIGHT - SSB Stereo is implemented, but preset use needs review.")
    return 1
}

// MARK: - Composite clipper stereo guard sweep (--verify-stereo-guard)
//
// Chain review 2026-08-30, finding B1: with the stereo guard at 1 the 22-53 kHz
// clipping residual is restored in full, so the composite clipper only ever
// removes the MONO share of an M+S peak. The output then exceeds the ceiling and
// the Final-MPX limiter rides the difference. Orban's half-cosine limiter
// (US 6,434,241) does not protect 23-53 kHz at all and Thimeo / Omnia clip the
// full composite; the trade is HF stereo separation on dense program against
// loudness / limiter duty. This sweep prints that trade, on the shipped Music -
// Loud profile and on the config as loaded, so the default is a measured choice.

private func printStereoGuardTable(label: String, config: AppConfig, durationSeconds duration: Double)
    -> [(guardShare: Double, finalGR: Float, sep14: Float)] {
    let scenarios = verificationScenarios()
    guard let dense = scenarios.first(where: { $0.name == "bright_dense" }) else { return [] }

    print("\(label): clipper drive \(String(format: "%.1f", config.finalDriveDB)) dB, threshold \(String(format: "%.1f", config.compositeClipperThresholdDB)) dB, ceiling \(String(format: "%.1f", config.compositeClipperCeilingDB)) dB, multiband \(config.multibandEnabled ? "on" : "off")")
    print("Guard  ClipGR  FinalGR  Peak dBFS  Dev kHz  Sep10k  Sep14k  S-M@14k  RideSINAD  HatSINAD")
    print("-----  ------  -------  ---------  -------  ------  ------  -------  ---------  --------")
    var points: [(guardShare: Double, finalGR: Float, sep14: Float)] = []
    for share in [0.0, 0.25, 0.5, 0.75, 1.0] {
        var cfg = config
        cfg.compositeClipperStereoGuard = share
        let d = verifyScenario(config: cfg, durationSeconds: duration, scenario: dense)
        let tone14 = receiverToneAnalysis(config: cfg, toneHz: 14_000.0, durationSeconds: duration)
        let sep10 = receiverToneAnalysis(config: cfg, toneHz: 10_000.0, durationSeconds: duration).coherent.separationDB
        let sep14 = tone14.coherent.separationDB
        let sideMono14 = tone14.encoderSideband.sideMonoDeltaDB
        // Fresh HF scenarios per point: their noise generators carry state.
        let hf = hfTransientScenarios()
        let ride = hf.first(where: { $0.name == "ride_multitone" }).map {
            measureHFTransient(config: cfg, scenario: $0, durationSeconds: max(5.0, duration)).hfSINADDB ?? 0.0
        } ?? 0.0
        let hat = hf.first(where: { $0.name == "hat_multitone" }).map {
            measureHFTransient(config: cfg, scenario: $0, durationSeconds: max(5.0, duration)).hfSINADDB ?? 0.0
        } ?? 0.0
        let deviationKHz = d.peakAbs * Float(cfg.mpxDeviationKHz)
        points.append((share, d.maxSafetyGRDB, sep14))
        print(
            "\(String(format: "%5.2f", share))  "
                + "\(String(format: "%6.2f", d.maxLimiterGRDB))"
                + "  \(String(format: "%7.2f", d.maxSafetyGRDB))"
                + "  \(String(format: "%9.2f", dbfsValue(d.peakAbs)))"
                + "  \(String(format: "%7.2f", deviationKHz))"
                + "  \(String(format: "%6.1f", sep10))"
                + "  \(String(format: "%6.1f", sep14))"
                + "  \(String(format: "%+7.2f", sideMono14))"
                + "  \(String(format: "%9.1f", ride))"
                + "  \(String(format: "%8.1f", hat))"
        )
    }
    print("")
    return points
}

func runStereoGuardSweep(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let duration = max(3.0, min(durationSeconds, 6.0))
    var loud = baseConfig
    _ = PresetCatalog.applyFormatProfile(id: "music_loud", to: &loud)

    print("Per point: bright_dense (ClipGR = composite clipper, FinalGR = Final-MPX limiter duty, peak,")
    print("deviation), 10 / 14 kHz left-only tones (coherent separation; S-M@14k = encoder-side")
    print("sideband-sum minus mono at 14 kHz, 0 = balanced M/S), ride / hat HF SINAD (receiver-side,")
    print("de-emphasised). Measured 2026-08-30: on Music - Loud the share changes nothing; on a hot")
    print("config the Final-MPX ride is 1.19 dB at 0 and 1.33 dB at 1 (the ride is NOT the guard's),")
    print("guard 1 costs ~5 dB of 14 kHz tone separation and buys ~3 dB of decoded hat / ride SINAD.")
    print("")
    let loudPoints = printStereoGuardTable(label: "Profile Music - Loud", config: loud, durationSeconds: duration)
    _ = printStereoGuardTable(label: "Config as loaded", config: baseConfig, durationSeconds: duration)

    print("Assessment")
    print("Shipped default: mpx_clipper_stereo_guard = \(String(format: "%.2f", AppConfig().compositeClipperStereoGuard))")
    let acceptable = loudPoints.filter { $0.finalGR <= 0.5 && $0.sep14 >= 20.0 }
    if let best = acceptable.max(by: { $0.sep14 < $1.sep14 }) {
        print("Music - Loud: guard shares with final-limiter duty <= 0.5 dB and 14 kHz separation >= 20 dB: "
            + acceptable.map { String(format: "%.2f", $0.guardShare) }.joined(separator: ", ")
            + "; best separation among them at \(String(format: "%.2f", best.guardShare)).")
    } else {
        print("Music - Loud: no guard share meets final-limiter duty <= 0.5 dB with 14 kHz separation >= 20 dB.")
    }
    print("Result: OK - sweep printed; the shipped default is chosen from this table (docs/studio-settings-reference.md, Composite Clipper).")
    return 0
}
