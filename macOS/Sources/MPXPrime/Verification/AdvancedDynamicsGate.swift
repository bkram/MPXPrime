#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

// --verify-advanced-dynamics: the A/B gate for the single-stage Advanced
// Dynamics leveler vs the classic wideband AGC + 5-band multiband pair.
// Moved out of StageABGates.swift as a pure move (0.45), then hardened for
// the default-flip campaign: real per-scenario quality expectations on the
// B chain, RMS-parity checks, two failure-class scenarios (crossover-skirt
// lift, solo-bell decay), and gain-trajectory probes reading
// `advancedDynamicsStatus`. The SSB gate reuses
// advancedDynamicsComparisonScenarios() as its program table (programs
// only -- it never evaluates the quality expectations).

// Timing contract of the solo_bell_decay scenario, shared between the
// signal closure and the decay-swell analyzer.
private let bellCycleSeconds = 4.0
private let bellDecayStartSeconds = 1.5
private let bellDecayTauSeconds = 0.8

func advancedDynamicsComparisonScenarios() -> [VerificationScenario] {
    var denseNoiseL = DeterministicNoise(seed: 0xAD00_0000_0000_0001)
    var denseNoiseR = DeterministicNoise(seed: 0xAD00_0000_0000_0002)
    return [
        VerificationScenario(
            name: "level_jump",
            description: "Program jumping -26 -> -6 dB mid-scenario (the leveler's core case)",
            // Leveling the 20 dB jump is the point, so no RMS-parity bound;
            // image and bandwidth must still hold.
            quality: QualityExpectations(
                maxCorrelationDelta: 0.20,
                maxOutputCorrelation: nil,
                minSideRetention: 0.50,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -45.0,
                maxAbove67kRatioDB: -53.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            // Alternate quiet / loud every 1.25 s: a 20 dB program jump.
            let loud = Int(t / 1.25) % 2 == 1
            let amp = loud ? 0.50 : 0.05
            let bass = 0.6 * sin(2.0 * Double.pi * 82.0 * t)
            let vocal = 0.5 * sin(2.0 * Double.pi * 1_100.0 * t)
            let air = 0.25 * sin(2.0 * Double.pi * 6_800.0 * t)
            let l = Float(amp * (bass + vocal + air))
            let r = Float(amp * ((0.9 * bass) + (0.8 * vocal) + (1.1 * air)))
            return (l, r)
        },
        VerificationScenario(
            name: "bass_dense",
            description: "Dense bass-heavy music bed",
            // Dense steady program: A and B should agree on loudness (the
            // RMS-parity scenario), and the anti-phase vocal makes this the
            // image-integrity scenario.
            quality: QualityExpectations(
                maxCorrelationDelta: 0.45,
                maxOutputCorrelation: nil,
                minSideRetention: 0.45,
                maxAbsRMSDeltaDB: 6.0,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -40.0,
                maxAbove67kRatioDB: -44.0
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
            name: "quiet_ballad",
            description: "Low-level sparse program (max-lift territory)",
            // Lift is the point (no RMS bound); the lifted program must
            // keep its image and stay inside the occupied bandwidth.
            quality: QualityExpectations(
                maxCorrelationDelta: 0.20,
                maxOutputCorrelation: nil,
                minSideRetention: 0.50,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -40.0,
                maxAbove67kRatioDB: -48.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let piano = 0.05 * sin(2.0 * Double.pi * 440.0 * t)
                * (0.6 + 0.4 * sin(2.0 * Double.pi * 0.7 * t))
            let bass = 0.035 * sin(2.0 * Double.pi * 110.0 * t)
            let l = Float(piano + bass)
            let r = Float((0.85 * piano) + bass)
            return (l, r)
        },
        VerificationScenario(
            name: "hf_transients",
            description: "Percussive HF content (transient-catch check)",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.30,
                maxOutputCorrelation: nil,
                minSideRetention: 0.50,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -40.0,
                maxAbove67kRatioDB: -48.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let hatEnv = pow(max(0.0, sin(2.0 * Double.pi * 4.0 * t)), 24.0)
            let hat = (0.55 * hatEnv) * sin(2.0 * Double.pi * 9_000.0 * t)
            let snap = (0.4 * pow(max(0.0, sin(2.0 * Double.pi * 2.0 * t + 1.2)), 30.0))
                * sin(2.0 * Double.pi * 3_400.0 * t)
            let bed = 0.22 * sin(2.0 * Double.pi * 520.0 * t)
            let l = Float(hat + snap + bed)
            let r = Float((0.8 * hat) + (1.1 * snap) + (0.9 * bed))
            return (l, r)
        }
    ]
}

/// Failure-class scenarios added for the default-flip campaign. Separate
/// from the core table so the SSB gate's program set is unchanged.
func advancedDynamicsHardeningScenarios(x3Hz: Double) -> [VerificationScenario] {
    var bedNoiseL = DeterministicNoise(seed: 0xAD00_0000_0000_0003)
    var bedNoiseR = DeterministicNoise(seed: 0xAD00_0000_0000_0004)
    // Slightly above the mid/high crossover: the 0.45 non-brick-wall
    // splitters put this tone on both bands' skirts, where a multiband
    // leveler can lift it by the neighbouring band's full range
    // (plan.md Step 3 finding).
    let skirtHz = 1.06 * x3Hz
    return [
        VerificationScenario(
            name: "crossover_skirt",
            description: "Tone on the x3 crossover skirt over a quiet bed (skirt-lift check)",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.20,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -45.0,
                maxAbove67kRatioDB: -53.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            // Quiet on purpose: the skirt fault is on the LIFT side (a tone
            // both bands see gets lifted by the neighbour's full range).
            let tone = 0.05 * sin(2.0 * Double.pi * skirtHz * t)
            let l = Float(tone) + (bedNoiseL.next() * 0.008)
            let r = Float(0.95 * tone) + (bedNoiseR.next() * 0.008)
            return (l, r)
        },
        VerificationScenario(
            name: "solo_bell_decay",
            description: "Solo bell with a natural exponential decay (decay-guard check)",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.20,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -45.0,
                maxAbove67kRatioDB: -53.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let tc = t.truncatingRemainder(dividingBy: bellCycleSeconds)
            let amp = tc < bellDecayStartSeconds
                ? 0.1
                : 0.1 * exp(-(tc - bellDecayStartSeconds) / bellDecayTauSeconds)
            let bell = amp * sin(2.0 * Double.pi * 880.0 * t)
            let partial = 0.25 * amp * sin(2.0 * Double.pi * 2_640.0 * t)
            let l = Float(bell + partial)
            let r = Float(0.92 * (bell + partial))
            return (l, r)
        }
    ]
}

/// A/B: (A) classic wideband AGC + 5-band multiband compressor vs (B) the
/// single-stage Advanced Dynamics leveler, on identical program scenarios.
/// Also measures re-processing idempotency: feeding the leveler's output
/// through a fresh leveler should barely change it ("inaudible doubling").
func runAdvancedDynamicsComparison(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let compareDuration = max(2.0, min(durationSeconds, 6.0))
    // A: the production two-stage path, forced on.
    var classicConfig = baseConfig
    classicConfig.advancedDynamicsEnabled = false
    classicConfig.widebandAGCEnabled = true
    classicConfig.multibandEnabled = true
    classicConfig.multibandMode = 5

    // B: the fused single-stage leveler (AGC + multiband auto-bypassed).
    var leveledConfig = classicConfig
    leveledConfig.advancedDynamicsEnabled = true

    print("Advanced Dynamics A/B (classic AGC+multiband vs single-stage leveler)")
    print("Toggle: advanced_dynamics_enabled")
    print("Scope: forced dynamics-on program scenarios; production default remains toggle-off")
    print("")
    print("Scenario              RMSDelta  LowDelta  MidDelta  HighDelta  CorrDelta  SideDelta  PeakDelta  POvrOn")
    print("--------------------  --------  --------  --------  ---------  ---------  ---------  ---------  ------")

    var warnings: [String] = []
    var offNanos: UInt64 = 0
    var onNanos: UInt64 = 0
    var maxAbsRMSDelta: Float = 0.0
    // Scenarios where the leveler is expected to land at the same loudness
    // as the classic chain (dense/steady program). The leveling showcases
    // (level_jump, quiet_ballad, hf_transients) are expected hotter, and
    // crossover_skirt stays diagnostic until band coupling (plan.md Step 7)
    // cures the known skirt lift -- those only carry the runaway bound.
    let rmsParityScenarios: Set<String> = ["bass_dense"]
    var bChainAbsolutes: [(name: String, metrics: VerificationMetrics)] = []

    let scenarios = advancedDynamicsComparisonScenarios()
        + advancedDynamicsHardeningScenarios(x3Hz: baseConfig.multibandX3Hz)
    for scenario in scenarios {
        let offStart = DispatchTime.now().uptimeNanoseconds
        let off = verifyScenario(
            config: classicConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        offNanos += DispatchTime.now().uptimeNanoseconds - offStart

        let onStart = DispatchTime.now().uptimeNanoseconds
        let on = verifyScenario(
            config: leveledConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        onNanos += DispatchTime.now().uptimeNanoseconds - onStart

        let rmsDelta = on.rmsDeltaDB - off.rmsDeltaDB
        let lowDelta = on.outputBands.lowDBFS - off.outputBands.lowDBFS
        let midDelta = on.outputBands.midDBFS - off.outputBands.midDBFS
        let highDelta = on.outputBands.highDBFS - off.outputBands.highDBFS
        let corrDelta = on.outputSignal.correlation - off.outputSignal.correlation
        let sideDelta = ratioDB(on.outputSignal.sideToMidRatio, off.outputSignal.sideToMidRatio)
        let peakDelta = dbfsValue(on.peakAbs) - dbfsValue(off.peakAbs)
        maxAbsRMSDelta = max(maxAbsRMSDelta, abs(rmsDelta))
        bChainAbsolutes.append((scenario.name, on))

        if on.maxPostInjectionOvershoot > 1e-4 || on.overBudget {
            warnings.append("\(scenario.name): leveler path exceeded composite budget")
        }
        // 0.35: band re-leveling legitimately moves broadband correlation
        // when the band balance changes on side-weighted program (measured
        // -0.26 on bass_dense, whose anti-phase vocal rides the lifted mid
        // band). Image INTEGRITY is gated by the per-scenario B-chain
        // expectations below; this A/B delta only catches a gross change.
        if abs(corrDelta) > 0.35 {
            warnings.append("\(scenario.name): output correlation changed by \(String(format: "%+.2f", corrDelta))")
        }
        if sideDelta < -3.0 {
            warnings.append("\(scenario.name): side/mid fell by \(String(format: "%.1f", -sideDelta)) dB")
        }
        // Loudness parity vs the classic chain (calibrated 2026-09-04:
        // bass_dense +0.9 dB). A leveling showcase may run hotter, but
        // anything past the runaway bound means the gain structure broke.
        if rmsParityScenarios.contains(scenario.name), abs(rmsDelta) > 3.0 {
            warnings.append("\(scenario.name): leveler loudness differs from the classic chain by \(String(format: "%+.1f", rmsDelta)) dB (parity bound 3.0)")
        } else if abs(rmsDelta) > 8.0 {
            warnings.append("\(scenario.name): leveler loudness differs from the classic chain by \(String(format: "%+.1f", rmsDelta)) dB (runaway bound 8.0)")
        }
        // Per-scenario quality expectations on the leveler chain itself
        // (input -> output image, RMS drift, occupied bandwidth).
        for finding in qualityFindings(scenario: scenario, metrics: on) {
            warnings.append("\(scenario.name): B-chain \(finding)")
        }

        print(
            "\(padded(scenario.name, width: 20))  "
                + "\(String(format: "%+8.2f", rmsDelta))"
                + "  \(String(format: "%+8.2f", lowDelta))"
                + "  \(String(format: "%+8.2f", midDelta))"
                + "  \(String(format: "%+9.2f", highDelta))"
                + "  \(String(format: "%+9.2f", corrDelta))"
                + "  \(String(format: "%+9.2f", sideDelta))"
                + "  \(String(format: "%+9.2f", peakDelta))"
                + "  \(String(format: "%6.4f", on.maxPostInjectionOvershoot))"
        )
    }

    // B-chain absolutes: the numbers the per-scenario expectations gate on,
    // printed so recalibration never needs a debugger.
    print("")
    print("B-chain absolutes (leveler chain, input -> output)")
    print("Scenario              CorrIn  CorrOut  SideRet  RMSDrift  Occ999   >60k   >67k")
    print("--------------------  ------  -------  -------  --------  ------  -----  -----")
    for entry in bChainAbsolutes {
        let m = entry.metrics
        let sideRet = m.inputSignal.sideToMidRatio > 0.05
            ? m.outputSignal.sideToMidRatio / max(0.001, m.inputSignal.sideToMidRatio)
            : Float.nan
        print(
            "\(padded(entry.name, width: 20))  "
                + "\(String(format: "%+6.2f", m.inputSignal.correlation))"
                + "  \(String(format: "%+7.2f", m.outputSignal.correlation))"
                + "  \(sideRet.isNaN ? "     --" : String(format: "%7.2f", sideRet))"
                + "  \(String(format: "%+8.1f", m.rmsDeltaDB))"
                + "  \(String(format: "%6.0f", m.bandwidth.occupied999Hz))"
                + "  \(String(format: "%5.0f", m.bandwidth.above60kRatioDB))"
                + "  \(String(format: "%5.0f", m.bandwidth.above67kRatioDB))"
        )
    }

    // Gain-trajectory probes (advancedDynamicsStatus): per-band travel,
    // slew, and beat-rate (0.5-4.5 Hz) modulation depth. Bass pumping the
    // mid/high bands at the kick rate is THE classic multiband fault.
    print("")
    print("Leveler gain trajectory (B chain)")
    print("Scenario              Band   MinG   MaxG  p95Slew  BeatMod")
    print("--------------------  ----  -----  -----  -------  -------")
    var beatModWarnBands: [Int] = []
    for probeName in ["bass_dense", "crossover_skirt"] {
        guard let probeScenario = (advancedDynamicsComparisonScenarios()
            + advancedDynamicsHardeningScenarios(x3Hz: baseConfig.multibandX3Hz))
            .first(where: { $0.name == probeName })
        else { continue }
        let stats = advancedDynamicsTrajectoryProbe(
            config: leveledConfig,
            scenario: probeScenario,
            durationSeconds: 6.0,
            settleSeconds: 1.5
        )
        for (band, stat) in stats.enumerated() {
            print(
                "\(padded(probeName, width: 20))  "
                    + "\(String(format: "%4d", band + 1))"
                    + "  \(String(format: "%+5.1f", stat.minGainDB))"
                    + "  \(String(format: "%+5.1f", stat.maxGainDB))"
                    + "  \(String(format: "%7.1f", stat.p95SlewDBPerSec))"
                    + "  \(String(format: "%7.2f", stat.beatModulationDB))"
            )
            // Calibrated 2026-09-04: measured <= 0.02 dB on bands 3-5 (the
            // kick rides band 1 at ~0.16 dB); 1.0 dB of beat-rate movement
            // on an upper band is audible pumping.
            if probeName == "bass_dense", band >= 2, stat.beatModulationDB > 1.0 {
                beatModWarnBands.append(band + 1)
            }
        }
    }
    if !beatModWarnBands.isEmpty {
        warnings.append(
            "bass_dense: band(s) \(beatModWarnBands.map(String.init).joined(separator: ",")) modulate > 3.0 dB at the beat rate (bass pumping the upper bands)")
    }

    // Decay guard through the FULL chain: the decoded output of a naturally
    // decaying bell must keep falling -- a swell means the lift is chasing
    // the fade (the "Hide and Seek" fault class; unit-level guard exists,
    // this proves it end to end).
    // Calibrated 2026-09-04: measured 0.11 dB through the full chain; the
    // pre-guard fault class swelled fades by ~3 dB and up.
    let decaySwell = advancedDynamicsDecaySwellDB(config: leveledConfig)
    print("")
    print("Solo-bell decay swell (decoded B chain): \(String(format: "%.2f", decaySwell)) dB (bound 2.0)")
    if decaySwell > 2.0 {
        warnings.append("solo_bell_decay: decoded envelope swells \(String(format: "%.1f", decaySwell)) dB during a natural fade (decay guard not holding through the chain)")
    }

    // Idempotency: process program through the leveler, then feed that
    // output through a FRESH leveler. A target-density design should
    // barely move the second time (Stereo Tool's "inaudible doubling").
    let idempotencyDeltaDB = advancedDynamicsIdempotencyDeltaDB(config: leveledConfig)
    let costRatio = Double(onNanos) / max(1.0, Double(offNanos))
    print("")
    print("Re-processing idempotency: \(String(format: "%+.2f", idempotencyDeltaDB)) dB RMS change on second pass (target ~0)")
    print("Max |RMS delta| vs classic chain: \(String(format: "%.2f", maxAbsRMSDelta)) dB")
    print("Cost ratio vs AGC+multiband: \(String(format: "%.2fx", costRatio))")
    print("")
    print("Assessment")
    if abs(idempotencyDeltaDB) > 2.0 {
        warnings.append("second-pass RMS moved \(String(format: "%+.2f", idempotencyDeltaDB)) dB (>2 dB): leveler is not settling at its own target density")
    }
    if costRatio > 1.5 {
        warnings.append("leveler cost ratio \(String(format: "%.2fx", costRatio)) exceeds 1.5x the two stages it replaces")
    }
    if warnings.isEmpty {
        print("Result: OK - single-stage leveler tracks the classic chain safely.")
        return 0
    }
    print("Comparison notes:")
    for warning in warnings {
        print("- \(warning)")
    }
    print("Result: TIGHT - Advanced Dynamics is implemented, but preset use needs review.")
    return 1
}

struct AdvancedDynamicsBandTrajectoryStats {
    var minGainDB: Float
    var maxGainDB: Float
    var p95SlewDBPerSec: Float
    /// Peak-to-peak-equivalent gain swing (dB) in the 0.5-4.5 Hz beat band.
    var beatModulationDB: Float
}

/// Renders the B chain over a scenario, sampling `advancedDynamicsStatus`
/// every 64 frames into per-band gain traces, and reduces each trace to
/// travel / slew / beat-modulation statistics (post-settle window).
func advancedDynamicsTrajectoryProbe(
    config: AppConfig,
    scenario: VerificationScenario,
    durationSeconds: Double,
    settleSeconds: Double
) -> [AdvancedDynamicsBandTrajectoryStats] {
    let sampleRate = max(8_000.0, config.sampleRate)
    let chunk = 64
    let frames = Int(sampleRate * durationSeconds)
    let generator = MPXGenerator(config: config, sampleRate: sampleRate)
    var traces = [[Float]](repeating: [], count: 5)
    var left = [Float](repeating: 0.0, count: chunk)
    var right = [Float](repeating: 0.0, count: chunk)
    var frame = 0
    while frame < frames {
        let count = min(chunk, frames - frame)
        for i in 0..<count {
            let (l, r) = scenario.sample(frame + i, sampleRate)
            left[i] = l
            right[i] = r
        }
        generator.renderFromInputInPlace(frameCount: count, left: &left, right: &right)
        let status = generator.advancedDynamicsStatus
        traces[0].append(status.bandGainsDB.0)
        traces[1].append(status.bandGainsDB.1)
        traces[2].append(status.bandGainsDB.2)
        traces[3].append(status.bandGainsDB.3)
        traces[4].append(status.bandGainsDB.4)
        frame += count
    }

    let traceRate = sampleRate / Double(chunk)
    let settleSamples = Int(traceRate * settleSeconds)
    return traces.map { trace in
        let window = Array(trace.dropFirst(min(settleSamples, max(0, trace.count - 2))))
        guard window.count >= 8 else {
            return AdvancedDynamicsBandTrajectoryStats(
                minGainDB: 0, maxGainDB: 0, p95SlewDBPerSec: 0, beatModulationDB: 0)
        }
        let minG = window.min() ?? 0
        let maxG = window.max() ?? 0
        var slews: [Float] = []
        slews.reserveCapacity(window.count - 1)
        for i in 1..<window.count {
            slews.append(fabsf(window[i] - window[i - 1]) * Float(traceRate))
        }
        slews.sort()
        let p95 = slews[min(slews.count - 1, Int(Double(slews.count) * 0.95))]
        return AdvancedDynamicsBandTrajectoryStats(
            minGainDB: minG,
            maxGainDB: maxG,
            p95SlewDBPerSec: p95,
            beatModulationDB: beatBandModulationDB(trace: window, traceRate: traceRate)
        )
    }
}

/// Peak-to-peak-equivalent modulation (dB) of a gain trace in the 0.5-4.5 Hz
/// beat band: time-domain RMS of the detrended trace scaled by the spectral
/// share of the beat band (scale-safe -- the FFT's absolute scaling cancels).
/// Also reused by --verify-program-ab as the pumping index of the B/A
/// envelope-ratio trace.
func beatBandModulationDB(trace: [Float], traceRate: Double) -> Float {
    let n = trace.count
    var fftSize = 1_024
    while fftSize * 2 <= n { fftSize *= 2 }
    guard n >= 1_024 else { return 0.0 }
    var mean: Float = 0.0
    for v in trace { mean += v }
    mean /= Float(n)
    var ac = [Float](repeating: 0.0, count: n)
    var sumSq: Double = 0.0
    let start = n - fftSize
    for i in 0..<n {
        ac[i] = trace[i] - mean
        if i >= start { sumSq += Double(ac[i] * ac[i]) }
    }
    let rms = Float(sqrt(sumSq / Double(fftSize)))
    let spectrum = hannPowerSpectrum(ac, start: start, fftSize: fftSize)
    let total = bandPower(
        spectrum, sampleRate: traceRate, fftSize: fftSize,
        lowHz: 0.05, highHz: traceRate / 2.0)
    guard total > 0.0 else { return 0.0 }
    let beat = bandPower(
        spectrum, sampleRate: traceRate, fftSize: fftSize, lowHz: 0.5, highHz: 4.5)
    return rms * sqrtf(Float(beat / total)) * 2.0 * sqrtf(2.0)
}

/// Max envelope swell (dB) of the DECODED output during the input's natural
/// decay windows of the solo_bell_decay scenario. Fixed 8 s render (two
/// bell cycles) regardless of --seconds, like the idempotency probe.
func advancedDynamicsDecaySwellDB(config: AppConfig) -> Float {
    let sampleRate = max(8_000.0, config.sampleRate)
    let seconds = 2.0 * bellCycleSeconds
    let frames = Int(sampleRate * seconds)
    guard let scenario = advancedDynamicsHardeningScenarios(x3Hz: config.multibandX3Hz)
        .first(where: { $0.name == "solo_bell_decay" })
    else { return 0.0 }
    let generator = MPXGenerator(config: config, sampleRate: sampleRate)

    let chunk = 4_096
    var left = [Float](repeating: 0.0, count: chunk)
    var right = [Float](repeating: 0.0, count: chunk)
    var mpxL = [Float](repeating: 0.0, count: chunk)
    var mpxR = [Float](repeating: 0.0, count: chunk)
    var mono = [Float](repeating: 0.0, count: frames)
    var frame = 0
    while frame < frames {
        let count = min(chunk, frames - frame)
        for i in 0..<count {
            let (l, r) = scenario.sample(frame + i, sampleRate)
            left[i] = l
            right[i] = r
        }
        generator.renderFromInputAndMonitorInPlace(
            frameCount: count,
            left: &left,
            right: &right,
            mpxLeft: &mpxL,
            mpxRight: &mpxR
        )
        for i in 0..<count {
            mono[frame + i] = 0.5 * (left[i] + right[i])
        }
        frame += count
    }

    // 10 ms RMS envelope.
    let hop = max(1, Int(sampleRate * 0.010))
    var envDB: [Float] = []
    envDB.reserveCapacity(frames / hop)
    var i = 0
    while i + hop <= frames {
        var sumSq: Double = 0.0
        for j in i..<(i + hop) { sumSq += Double(mono[j] * mono[j]) }
        envDB.append(10.0 * Float(log10(max(1e-12, sumSq / Double(hop)))))
        i += hop
    }

    // Decay windows: [cycle + 1.8 s, cycle + 3.8 s] (0.3 s past the decay
    // start absorbs chain group delay + detector release; the floor skips
    // the near-silent tail where the envelope is noise).
    let envRate = sampleRate / Double(hop)
    var maxSwell: Float = 0.0
    for cycle in 0..<2 {
        let startIdx = Int((Double(cycle) * bellCycleSeconds + bellDecayStartSeconds + 0.3) * envRate)
        let endIdx = min(envDB.count, Int((Double(cycle) * bellCycleSeconds + 3.8) * envRate))
        guard startIdx < endIdx else { continue }
        var runningMin = envDB[startIdx]
        for k in startIdx..<endIdx {
            let e = envDB[k]
            if e < -65.0 { continue }
            runningMin = min(runningMin, e)
            maxSwell = max(maxSwell, e - runningMin)
        }
    }
    return maxSwell
}

/// RMS change (dB) between the leveler's first-pass output and a second
/// pass of that output through a fresh leveler instance. Small = the stage
/// recognises already-processed material and stops.
func advancedDynamicsIdempotencyDeltaDB(config: AppConfig) -> Float {
    let sampleRate: Float = 48_000.0
    let seconds: Float = 8.0
    let frames = Int(sampleRate * seconds)
    let measureStart = frames - Int(sampleRate * 2.0)

    func makeLeveler() -> AdvancedDynamicsLeveler {
        var leveler = AdvancedDynamicsLeveler()
        leveler.configureStructure(
            sampleRate: sampleRate,
            x1Hz: Float(config.multibandX1Hz),
            x2Hz: Float(config.multibandX2Hz),
            x3Hz: Float(config.multibandX3Hz),
            x4Hz: Float(config.multibandX4Hz)
        )
        leveler.setParameters(
            targetDB: Float(config.advancedDynamicsTargetDB),
            lowOffsetDB: Float(config.advancedDynamicsLowOffsetDB),
            midOffsetDB: Float(config.advancedDynamicsMidOffsetDB),
            highOffsetDB: Float(config.advancedDynamicsHighOffsetDB),
            maxGainDB: Float(config.advancedDynamicsMaxGainDB),
            density: Float(config.advancedDynamicsDensity),
            speed: Float(config.advancedDynamicsSpeed)
        )
        return leveler
    }

    var first = makeLeveler()
    var firstOutL = [Float](repeating: 0.0, count: frames)
    var firstOutR = [Float](repeating: 0.0, count: frames)
    var firstSumSq: Double = 0.0
    for i in 0..<frames {
        let t = Float(i) / sampleRate
        let bass = 0.35 * sinf(2.0 * Float.pi * 90.0 * t)
        let vocal = 0.3 * sinf(2.0 * Float.pi * 1_200.0 * t)
        let air = 0.12 * sinf(2.0 * Float.pi * 7_000.0 * t)
        let x = bass + vocal + air
        let (l, r) = first.process(left: x, right: 0.9 * x)
        firstOutL[i] = l
        firstOutR[i] = r
        if i >= measureStart {
            firstSumSq += Double((l * l) + (r * r)) * 0.5
        }
    }

    var second = makeLeveler()
    var secondSumSq: Double = 0.0
    for i in 0..<frames {
        let (l, r) = second.process(left: firstOutL[i], right: firstOutR[i])
        if i >= measureStart {
            secondSumSq += Double((l * l) + (r * r)) * 0.5
        }
    }

    let n = Double(frames - measureStart)
    let firstRMS = sqrt(firstSumSq / n)
    let secondRMS = sqrt(secondSumSq / n)
    return Float(20.0 * log10(max(1e-9, secondRMS) / max(1e-9, firstRMS)))
}
