#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

// MARK: - PrimeBass missing-fundamental gate (--verify-primebass)
//
// PrimeBass is a psychoacoustic bass enhancer: for bass below F0 it adds a
// level-tracking harmonic series in F0 .. 5 F0 (the ear reconstructs the
// pitch from the series) and leaves everything else alone. This gate renders
// synthetic bass scenarios through the REAL engine twice -- PrimeBass on and
// off, otherwise identical config -- decodes both composites with the
// receiver model and measures the ENHANCEMENT as the difference of the two
// decoded mono signals. Working on the difference attributes every metric to
// PrimeBass alone, so the same thresholds hold on the shipped defaults and
// on the hot Music - Loud chain (whose own clippers would otherwise dominate
// an absolute IMD figure).
//
// Scenarios and thresholds (F0 = 50 Hz test tone, cutoff at the profile's
// `primebass_freq_hz`):
//   bass tone -20 dBFS   2 F0 re fundamental inside the design window, 3 F0
//                        not above 2 F0 + 3 dB, fundamental unchanged within
//                        1 dB, energy above 5 F0 <= -40 dB re the harmonic
//                        band, DC <= -80 dBFS, peak growth <= 1.5 dB,
//                        sample-to-sample jump of the enhancement <= 0.5 x
//                        its RMS (no gate steps)
//   -30 vs -10 dBFS      2 F0 ratio moves < 2 dB (level invariance)
//   50 Hz + 1 kHz        IMD at 950 / 1050 Hz <= -70 dB re the 1 kHz tone
//   1 kHz alone          enhancement <= -90 dB re the dry decode
//   50 + 70 Hz           peak growth <= 1.5 dB; 20 / 120 Hz products reported
//   disabled             composite with PrimeBass off is bit-identical to the
//                        stage's own identity path (amount 0, subharmonics
//                        off): the enable flag adds nothing but the stage
// Exit 0 = every metric PASS, 1 = at least one FAIL.

/// The chain's own peak controllers after PrimeBass -- the Bass Clipper
/// first of all -- run Float biquads at 4x oversampling whose rounding noise
/// sits near -80 dBFS and is re-randomised by ANY upstream change, and a
/// clipper turns an asymmetric (even-harmonic) waveform into DC. Both would
/// mask the two stage-intrinsic metrics that look below -80 dB (DC of the
/// enhancement, the 1 kHz residual), so those two rows measure a "stage
/// view": the same profile with every nonlinear stage after PrimeBass off.
/// AGC, multiband and mono bass ahead of it stay as configured.
private func primeBassStageView(_ config: AppConfig) -> AppConfig {
    var c = config
    c.bassClipperEnabled = false
    c.dcClipperEnabled = false
    c.hfLimiterEnabled = false
    c.preEncodeAudioLimiterEnabled = false
    c.limitMPX = false
    c.compositeClipperEnabled = false
    c.audioCompositeSoftClipEnabled = false
    c.bs412Enabled = false
    return c
}

private struct PrimeBassFinding {
    let scenario: String
    let metric: String
    let value: String
    let threshold: String
    /// nil = informational (no threshold).
    let pass: Bool?
}

private struct PrimeBassRender {
    /// Receiver-decoded mono over the analysis window.
    let mono: [Float]
    /// Full composite render.
    let composite: [Float]
}

private func renderPrimeBassScenario(
    config: AppConfig,
    durationSeconds: Double,
    sample: (Int, Double) -> (Float, Float)
) -> PrimeBassRender {
    let sampleRate = max(8_000.0, config.sampleRate)
    let frames = max(1, Int((durationSeconds * sampleRate).rounded()))
    let generator = MPXGenerator(config: config, sampleRate: sampleRate)
    var mpx = [Float](repeating: 0.0, count: frames)
    for frame in 0..<frames {
        let source = sample(frame, sampleRate)
        mpx[frame] = generator.renderSingleSample(leftIn: source.0, rightIn: source.1)
    }
    let fftSize = primeBassAnalysisSize(frames: frames)
    let start = frames - fftSize
    // Receiver side, as --verify-hf-transients: coherent decode with the
    // pilot phase estimated from the composite itself, expectedSide 0.
    let pilot = estimatePilotPhase(samples: mpx, sampleRate: sampleRate, start: start, count: fftSize)
    let decoded = decodeMPXWithReference(
        samples: mpx, pilotPhase: pilot.phase, config: config,
        programActivity: 0.5, expectedSide: 0.0)
    var mono = [Float](repeating: 0.0, count: fftSize)
    for i in 0..<fftSize {
        mono[i] = (decoded.left[start + i] + decoded.right[start + i]) * 0.5
    }
    return PrimeBassRender(mono: mono, composite: mpx)
}

/// Last power-of-two block (<= 131072 samples, 0.68 s at 192 kHz: 1.46 Hz
/// bins), so AGC / multiband settling is excluded.
private func primeBassAnalysisSize(frames: Int) -> Int {
    1 << Int(floor(log2(Double(max(1_024, min(frames / 2, 131_072))))))
}

private func primeBassToneLevelDB(
    _ spectrum: [Float], sampleRate: Double, fftSize: Int, hz: Double, halfWidthHz: Double = 3.0
) -> Double {
    let power = bandPower(
        spectrum, sampleRate: sampleRate, fftSize: fftSize, lowHz: hz - halfWidthHz, highHz: hz + halfWidthHz)
    return 10.0 * log10(max(1e-30, power))
}

private func primeBassRMS(_ x: [Float]) -> Double {
    var sum = 0.0
    for v in x { sum += Double(v * v) }
    return sqrt(sum / Double(max(1, x.count)))
}

private func primeBassPeak(_ x: [Float]) -> Double {
    var peak: Float = 0.0
    for v in x { peak = max(peak, fabsf(v)) }
    return Double(peak)
}

/// Mean over a whole number of periods of `periodHz`, so a periodic
/// enhancement contributes exactly its DC and not a partial-cycle residue.
private func primeBassMeanOverPeriods(_ x: [Float], sampleRate: Double, periodHz: Double) -> Double {
    let period = max(1, Int((sampleRate / periodHz).rounded()))
    let count = max(period, (x.count / period) * period)
    var sum = 0.0
    for i in 0..<min(count, x.count) { sum += Double(x[i]) }
    return sum / Double(min(count, x.count))
}

private func primeBassMaxJump(_ x: [Float]) -> Double {
    var maxJump: Float = 0.0
    for i in 1..<x.count { maxJump = max(maxJump, fabsf(x[i] - x[i - 1])) }
    return Double(maxJump)
}

private func primeBassDB(_ ratio: Double) -> Double {
    20.0 * log10(max(1e-30, ratio))
}

private func primeBassFormat(_ value: Double) -> String {
    String(format: "%.2f", value)
}

/// Design window for 2 F0 relative to the fundamental on a sustained 50 Hz
/// tone. On a steady sine the 2nd harmonic adds in phase at the
/// fundamental's peak, so the +1.5 dB peak guard, not `amount`, sets the
/// level: measured 2026-10-10 at -18.6 dB on the shipped defaults (amount
/// 0.22, F0 95 Hz, where 100 Hz also sits at the output highpass corner)
/// and -16.6 dB on Music - Loud (CHR preset, amount 0.34, F0 78 Hz). The
/// window brackets both with margin and rejects a dead generator (below
/// -22 dB) or a guard that lets the series run away (above -8 dB).
private let primeBassSecondHarmonicWindowDB: ClosedRange<Double> = -22.0 ... -8.0

private func measurePrimeBassProfile(
    enabledConfig: AppConfig,
    durationSeconds: Double
) -> [PrimeBassFinding] {
    var disabledConfig = enabledConfig
    disabledConfig.primeBassEnabled = false
    let stageOn = primeBassStageView(enabledConfig)
    var stageOff = stageOn
    stageOff.primeBassEnabled = false
    let sampleRate = max(8_000.0, enabledConfig.sampleRate)
    let f0 = 50.0
    let amp20 = 0.1  // -20 dBFS

    func tone(_ hz: Double, _ amplitude: Double) -> (Int, Double) -> (Float, Float) {
        { frame, rate in
            let v = Float(amplitude * sin(2.0 * Double.pi * hz * Double(frame) / rate))
            return (v, v)
        }
    }
    func twoTone(_ hz1: Double, _ hz2: Double, _ amplitude: Double) -> (Int, Double) -> (Float, Float) {
        { frame, rate in
            let t = Double(frame) / rate
            let v = Float(amplitude * (sin(2.0 * Double.pi * hz1 * t) + sin(2.0 * Double.pi * hz2 * t)))
            return (v, v)
        }
    }
    func render(_ config: AppConfig, _ sample: (Int, Double) -> (Float, Float)) -> PrimeBassRender {
        renderPrimeBassScenario(config: config, durationSeconds: durationSeconds, sample: sample)
    }
    func difference(_ on: PrimeBassRender, _ off: PrimeBassRender) -> [Float] {
        var d = [Float](repeating: 0.0, count: on.mono.count)
        for i in 0..<d.count { d[i] = on.mono[i] - off.mono[i] }
        return d
    }
    func spectrum(_ x: [Float]) -> [Float] {
        hannPowerSpectrum(x, start: 0, fftSize: x.count)
    }
    func level(_ spec: [Float], _ hz: Double, fftSize: Int) -> Double {
        primeBassToneLevelDB(spec, sampleRate: sampleRate, fftSize: fftSize, hz: hz)
    }

    var findings: [PrimeBassFinding] = []
    func add(_ scenario: String, _ metric: String, _ value: Double, _ threshold: String, _ pass: Bool?) {
        findings.append(PrimeBassFinding(
            scenario: scenario, metric: metric, value: primeBassFormat(value),
            threshold: threshold, pass: pass))
    }

    // Bass tone at -20 dBFS -------------------------------------------------
    let bassOn = render(enabledConfig, tone(f0, amp20))
    let bassOff = render(disabledConfig, tone(f0, amp20))
    let fftSize = bassOn.mono.count
    let bassDiff = difference(bassOn, bassOff)
    let specOff = spectrum(bassOff.mono)
    let specOn = spectrum(bassOn.mono)
    let specDiff = spectrum(bassDiff)
    let fundamentalOff = level(specOff, f0, fftSize: fftSize)
    let fundamentalOn = level(specOn, f0, fftSize: fftSize)
    let second = level(specDiff, 2.0 * f0, fftSize: fftSize) - fundamentalOff
    let third = level(specDiff, 3.0 * f0, fftSize: fftSize) - fundamentalOff
    let scenarioBass = "50 Hz -20 dBFS"
    add(scenarioBass, "2F0 re fundamental (dB)", second,
        "\(primeBassFormat(primeBassSecondHarmonicWindowDB.lowerBound)) .. \(primeBassFormat(primeBassSecondHarmonicWindowDB.upperBound))",
        primeBassSecondHarmonicWindowDB.contains(second))
    add(scenarioBass, "3F0 re fundamental (dB)", third, "<= 2F0 + 3", third <= second + 3.0)
    let fundamentalDelta = fundamentalOn - fundamentalOff
    add(scenarioBass, "fundamental change (dB)", fundamentalDelta, "|x| <= 1", abs(fundamentalDelta) <= 1.0)
    let cutoff = Double(enabledConfig.primeBassFreqHz)
    let harmonicBand = bandPower(
        specDiff, sampleRate: sampleRate, fftSize: fftSize, lowHz: f0 + 5.0, highHz: 5.0 * cutoff + 5.0)
    let aboveBand = bandPower(
        specDiff, sampleRate: sampleRate, fftSize: fftSize, lowHz: 5.0 * cutoff + 5.0, highHz: 15_000.0)
    let above5 = 10.0 * log10(max(1e-30, aboveBand) / max(1e-30, harmonicBand))
    add(scenarioBass, "energy above 5F0 re band (dB)", above5, "<= -40", above5 <= -40.0)
    let stageBassOn = render(stageOn, tone(f0, amp20))
    let stageBassOff = render(stageOff, tone(f0, amp20))
    let dc = primeBassDB(abs(primeBassMeanOverPeriods(
        difference(stageBassOn, stageBassOff), sampleRate: sampleRate, periodHz: f0)))
    add(scenarioBass + " (stage view)", "DC of enhancement (dBFS)", dc, "<= -80", dc <= -80.0)
    let peakGrowth = primeBassDB(primeBassPeak(bassOn.mono) / max(1e-30, primeBassPeak(bassOff.mono)))
    add(scenarioBass, "peak growth (dB)", peakGrowth, "<= 1.5", peakGrowth <= 1.5)
    let smoothness = primeBassMaxJump(bassDiff) / max(1e-30, primeBassRMS(bassDiff))
    add(scenarioBass, "max jump / RMS of enhancement", smoothness, "<= 0.5", smoothness <= 0.5)

    // Level invariance ------------------------------------------------------
    func secondRatio(_ amplitude: Double) -> Double {
        let on = render(enabledConfig, tone(f0, amplitude))
        let off = render(disabledConfig, tone(f0, amplitude))
        let n = on.mono.count
        let sOff = spectrum(off.mono)
        let sDiff = spectrum(difference(on, off))
        return level(sDiff, 2.0 * f0, fftSize: n) - level(sOff, f0, fftSize: n)
    }
    let ratioQuiet = secondRatio(0.0316)  // -30 dBFS
    let ratioLoud = secondRatio(0.316)  // -10 dBFS
    let invariance = ratioLoud - ratioQuiet
    add("50 Hz -30 vs -10 dBFS", "2F0 ratio change (dB)", invariance, "|x| < 2", abs(invariance) < 2.0)

    // Isolation -------------------------------------------------------------
    let mixOn = render(enabledConfig, twoTone(f0, 1_000.0, amp20))
    let mixOff = render(disabledConfig, twoTone(f0, 1_000.0, amp20))
    let mixDiff = spectrum(difference(mixOn, mixOff))
    let mixOffSpec = spectrum(mixOff.mono)
    let toneLevel = level(mixOffSpec, 1_000.0, fftSize: fftSize)
    let imdPower =
        bandPower(mixDiff, sampleRate: sampleRate, fftSize: fftSize, lowHz: 947.0, highHz: 953.0)
        + bandPower(mixDiff, sampleRate: sampleRate, fftSize: fftSize, lowHz: 1_047.0, highHz: 1_053.0)
    let imd = 10.0 * log10(max(1e-30, imdPower)) - toneLevel
    add("50 Hz + 1 kHz -20 dBFS", "IMD 950 / 1050 Hz re 1 kHz (dB)", imd, "<= -70", imd <= -70.0)

    let toneOn = render(stageOn, tone(1_000.0, amp20))
    let toneOff = render(stageOff, tone(1_000.0, amp20))
    let toneResidual = primeBassDB(
        primeBassRMS(difference(toneOn, toneOff)) / max(1e-30, primeBassRMS(toneOff.mono)))
    add("1 kHz alone (stage view)", "enhancement re dry (dB)", toneResidual, "<= -90", toneResidual <= -90.0)

    // Two-tone bass ---------------------------------------------------------
    let pairOn = render(enabledConfig, twoTone(f0, 70.0, amp20))
    let pairOff = render(disabledConfig, twoTone(f0, 70.0, amp20))
    let pairGrowth = primeBassDB(primeBassPeak(pairOn.mono) / max(1e-30, primeBassPeak(pairOff.mono)))
    add("50 + 70 Hz -20 dBFS each", "peak growth (dB)", pairGrowth, "<= 1.5", pairGrowth <= 1.5)
    let pairDiff = spectrum(difference(pairOn, pairOff))
    let pairFundamental = level(spectrum(pairOff.mono), f0, fftSize: fftSize)
    add("50 + 70 Hz -20 dBFS each", "20 Hz product re 50 Hz (dB)",
        level(pairDiff, 20.0, fftSize: fftSize) - pairFundamental, "info", nil)
    add("50 + 70 Hz -20 dBFS each", "120 Hz product re 50 Hz (dB)",
        level(pairDiff, 120.0, fftSize: fftSize) - pairFundamental, "info", nil)

    // Disabled path ---------------------------------------------------------
    var identityConfig = enabledConfig
    identityConfig.primeBassAmount = 0.0
    identityConfig.primeBassSubharmonicsEnabled = false
    let identity = render(identityConfig, twoTone(f0, 1_000.0, amp20))
    var maxDiff: Float = 0.0
    for i in 0..<min(identity.composite.count, mixOff.composite.count) {
        maxDiff = max(maxDiff, fabsf(identity.composite[i] - mixOff.composite[i]))
    }
    add("disabled vs stage identity", "max |composite diff|", Double(maxDiff), "== 0", maxDiff == 0.0)
    return findings
}

private func printPrimeBassFindings(_ findings: [PrimeBassFinding]) {
    print("Scenario                   Metric                            Value      Threshold       Result")
    print("-------------------------  --------------------------------  ---------  --------------  ------")
    for f in findings {
        let result = f.pass.map { $0 ? "PASS" : "FAIL" } ?? "info"
        print(
            "\(padded(f.scenario, width: 25))  \(padded(f.metric, width: 32))  "
                + "\(leftPadded(f.value, width: 9))  \(padded(f.threshold, width: 14))  \(result)")
    }
    print("")
}

private func primeBassKnobSummary(_ c: AppConfig) -> String {
    "F0 \(Int(c.primeBassFreqHz.rounded())) Hz, amount \(String(format: "%.2f", c.primeBassAmount)), "
        + "harmonics \(String(format: "%.2f", c.primeBassHarmonics)), drive \(String(format: "%.2f", c.primeBassDrive)), "
        + "density \(String(format: "%.2f", c.primeBassDensity)), "
        + "subharmonics \(c.primeBassSubharmonicsEnabled ? String(format: "%.2f", c.primeBassSubharmonicsAmount) : "off")"
}

func runPrimeBassVerification(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let duration = max(2.0, min(durationSeconds, 6.0))
    print("PrimeBass missing-fundamental gate: every metric is measured on the DIFFERENCE of the")
    print("receiver-decoded mono with PrimeBass on and off (same config otherwise), so it attributes")
    print("to the stage alone. Test tone F0 = 50 Hz; 2F0 / 3F0 are relative to the decoded fundamental.")
    print("Rows marked (stage view) switch the chain's peak controllers after PrimeBass off: their Float")
    print("rounding noise (about -80 dBFS, re-randomised by any upstream change) and the DC a clipper makes")
    print("of an asymmetric waveform would otherwise hide what the stage itself adds below -80 dB.")
    print("")

    // Defaults: AppConfig defaults (what a fresh install ships) with PrimeBass
    // switched on at its default knobs -- NOT the loaded Verification.ini,
    // whose multiband_enabled=False would make the chain unrepresentative.
    var defaults = AppConfig()
    defaults.sampleRate = baseConfig.sampleRate
    defaults.sourceMode = "input"
    defaults.enRDS = false
    defaults.primeBassEnabled = true

    var loud = AppConfig()
    loud.sampleRate = baseConfig.sampleRate
    loud.sourceMode = "input"
    loud.enRDS = false
    _ = PresetCatalog.applyFormatProfile(id: "music_loud", to: &loud)
    loud.primeBassEnabled = true

    var failures = 0
    for (label, config) in [("Defaults", defaults), ("Profile Music - Loud", loud)] {
        print("\(label): \(primeBassKnobSummary(config))")
        let findings = measurePrimeBassProfile(enabledConfig: config, durationSeconds: duration)
        printPrimeBassFindings(findings)
        failures += findings.filter { $0.pass == false }.count
    }

    #if canImport(AVFoundation)
    if let musicDir = ProcessInfo.processInfo.environment["MPXPRIME_MUSIC_DIR"], !musicDir.isEmpty,
        FileManager.default.fileExists(atPath: musicDir) {
        printPrimeBassProgramMaterial(path: musicDir, config: loud)
    } else {
        print("Program material: MPXPRIME_MUSIC_DIR not set or missing; real-music rows skipped.")
        print("")
    }
    #endif

    if failures > 0 {
        print("Result: FAIL - \(failures) metric(s) outside threshold.")
        return 1
    }
    print("Result: OK - every PrimeBass metric inside threshold.")
    return 0
}

#if canImport(AVFoundation)
/// Real-music rows (informational, no thresholds): the same decoded-mono
/// view as the synthetic rows on each file of the operator corpus, Music -
/// Loud with PrimeBass on vs off. Crest = decoded peak / RMS; the band rows
/// are on-minus-off energy deltas, 60-120 Hz = the harmonic band of a
/// 30-60 Hz fundamental, 120-500 Hz = the upper series, 500-2000 Hz = the
/// midrange that intermodulation products land in ("mud").
private func printPrimeBassProgramMaterial(path: String, config enabledConfig: AppConfig) {
    let files = programABInputFiles(path: path)
    guard !files.isEmpty else {
        print("Program material: no decodable audio files at \(path); real-music rows skipped.")
        print("")
        return
    }
    var disabledConfig = enabledConfig
    disabledConfig.primeBassEnabled = false
    let sampleRate = max(8_000.0, enabledConfig.sampleRate)
    let excerptSeconds = 30.0
    print("Program material (\(path), \(files.count) file(s), \(Int(excerptSeconds)) s excerpts, Music - Loud, on minus off):")
    print("Track                                     Crest off  Crest on  d60-120  d120-500  d500-2k  Peak dB")
    print("----------------------------------------  ---------  --------  -------  --------  -------  -------")
    for file in files {
        guard let program = decodeProgramFile(url: file, targetRate: sampleRate, excerptSeconds: excerptSeconds)
        else {
            print("\(padded(file.lastPathComponent, width: 40))  decode failed, skipped")
            continue
        }
        func render(_ config: AppConfig) -> [Float] {
            let generator = MPXGenerator(config: config, sampleRate: sampleRate)
            let frames = min(program.left.count, program.right.count)
            var mpx = [Float](repeating: 0.0, count: frames)
            for i in 0..<frames {
                mpx[i] = generator.renderSingleSample(leftIn: program.left[i], rightIn: program.right[i])
            }
            let fftSize = 65_536
            let settle = min(frames - fftSize, Int(sampleRate))
            let pilot = estimatePilotPhase(samples: mpx, sampleRate: sampleRate, start: max(0, settle), count: fftSize)
            let decoded = decodeMPXWithReference(
                samples: mpx, pilotPhase: pilot.phase, config: config,
                programActivity: 0.5, expectedSide: 0.0)
            var mono = [Float](repeating: 0.0, count: frames)
            for i in 0..<frames { mono[i] = (decoded.left[i] + decoded.right[i]) * 0.5 }
            return mono
        }
        let monoOn = render(enabledConfig)
        let monoOff = render(disabledConfig)
        let fftSize = 65_536
        let settle = Int(sampleRate)
        guard monoOn.count > settle + fftSize else {
            print("\(padded(file.lastPathComponent, width: 40))  too short, skipped")
            continue
        }
        func stats(_ mono: [Float]) -> (crest: Double, bands: [Double], peak: Double) {
            var sumSq = 0.0
            var peak: Float = 0.0
            var bands = [0.0, 0.0, 0.0]
            var windows = 0
            var start = settle
            while start + fftSize <= mono.count {
                let spec = hannPowerSpectrum(mono, start: start, fftSize: fftSize)
                bands[0] += bandPower(spec, sampleRate: sampleRate, fftSize: fftSize, lowHz: 60.0, highHz: 120.0)
                bands[1] += bandPower(spec, sampleRate: sampleRate, fftSize: fftSize, lowHz: 120.0, highHz: 500.0)
                bands[2] += bandPower(spec, sampleRate: sampleRate, fftSize: fftSize, lowHz: 500.0, highHz: 2_000.0)
                windows += 1
                start += fftSize
            }
            for i in settle..<mono.count {
                sumSq += Double(mono[i] * mono[i])
                peak = max(peak, fabsf(mono[i]))
            }
            let rms = sqrt(sumSq / Double(max(1, mono.count - settle)))
            let crest = primeBassDB(Double(peak) / max(1e-30, rms))
            return (crest, bands.map { 10.0 * log10(max(1e-30, $0 / Double(max(1, windows)))) }, Double(peak))
        }
        let on = stats(monoOn)
        let off = stats(monoOff)
        print(
            "\(padded(String(file.lastPathComponent.prefix(40)), width: 40))  "
                + "\(leftPadded(primeBassFormat(off.crest), width: 9))  "
                + "\(leftPadded(primeBassFormat(on.crest), width: 8))  "
                + "\(leftPadded(String(format: "%+.2f", on.bands[0] - off.bands[0]), width: 7))  "
                + "\(leftPadded(String(format: "%+.2f", on.bands[1] - off.bands[1]), width: 8))  "
                + "\(leftPadded(String(format: "%+.2f", on.bands[2] - off.bands[2]), width: 7))  "
                + "\(leftPadded(String(format: "%+.2f", primeBassDB(on.peak / max(1e-30, off.peak))), width: 7))")
    }
    print("")
}
#endif
