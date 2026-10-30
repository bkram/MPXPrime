#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

// MARK: - Stereo-separation gates (2026-10-20 stereo audit, C4 / D2 / D3)
//
// Three measurements that `--verify-receiver` lacked, each one a way a
// separation regression used to pass every gate:
//
// 1. An L-only TONE SET (D2): 1 / 5 / 10 / 14 kHz at 0.1 / 0.3 / 0.5 FS on
//    the shipped default (Music - Clean) and Music - Loud profiles, each
//    rendered processed AND with `processing_bypass`, coherent decode. The
//    existing tone test drives one level (0.45) on Verification.ini only.
// 2. The processed-vs-bypass A/B (C4): the per-tone delta of (1), gated at
//    `separationBypassLossGateDB` at 1 / 10 kHz. Nothing compared the two
//    before, which is exactly the operator's complaint.
// 3. PANNED PROGRAMME crosstalk (D3): the `panned_program` scenario
//    (program_mix into the left channel only) decoded coherently, R / L
//    RMS per octave band, processed vs bypass, on Verification.ini and the
//    two shipped profiles. The composite clipper's stereo guard (A1) and
//    mono bass (A2) are visible only on programme, never on a steady tone.
//
// Everything renders through `MPXGenerator` as `--verify-receiver` does;
// nothing here touches the engine.

/// Decoded-crosstalk floors for the panned-programme table, dB (R / L RMS
/// per band). The clipper task (C2, `mpx_clipper_stereo_guard`) may need to
/// tune these two numbers once the guard's default is re-decided with
/// separation in the criterion; they are the audit's D3 expectation.
let pannedProgramCrosstalkGateDB: Float = 40.0  // 200 Hz - 10 kHz
let pannedProgramCrosstalkGateHFDB: Float = 30.0  // 10 - 15 kHz
/// The bypass render is the reference the processed figure is read against
/// (D3: bypass >= 60 dB). Reported as a note, not a gate: bypass still runs
/// Final Drive and the composite peak chain, so it is a property of the
/// encoder, not of the processing under test.
let pannedProgramBypassReferenceDB: Float = 60.0

/// Coherent-decode separation floors for an L-only tone (D2). The same
/// numbers gate the 1 / 10 / 14 kHz tone test in `ReceiverModel.swift`
/// (raised from 18 / 16 dB; the stored baseline reads 98 / 98 / 70).
let separationGateDB: Float = 40.0
let separationGate14kDB: Float = 30.0
/// Processed-minus-bypass loss allowed at 1 / 10 kHz (C4 / D2).
let separationBypassLossGateDB: Float = 6.0
/// Separations above this are beyond any receiver. The A/B delta is taken
/// on figures clamped here so a 120 -> 98 dB "loss" at the numerical floor
/// cannot fire the 6 dB gate; the absolute floors and the 2 dB baseline
/// compare still catch drift up there.
let separationABClampDB: Float = 60.0

/// Driven-band level window (dB under the loudest driven band) inside which
/// a band counts as carrying programme and is gated; see
/// `DecodedCrosstalkResult.hasProgramme`.
let pannedProgramContentWindowDB: Float = 30.0

/// Bands whose lower edge sits under this multiple of the mono-bass corner
/// are reported but not gated when mono bass is on: the stage puts the
/// whole bass into the quiet channel by design (A2), and its linear-phase
/// side highpass reaches its 40 dB stopband about 1.5 x above the corner.
let monoBassCrosstalkExclusionFactor: Double = 3.0

struct CrosstalkBand {
    let lowerHz: Double
    let upperHz: Double
    let gateDB: Float

    var label: String {
        func short(_ hz: Double) -> String {
            if hz >= 1_000.0 {
                let k = hz / 1_000.0
                return k == k.rounded() ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
            }
            return String(format: "%.0f", hz)
        }
        return "\(short(lowerHz))-\(short(upperHz))"
    }
}

/// Octave bands 200 Hz - 10 kHz plus the 10 - 15 kHz top band (D3).
let pannedProgramCrosstalkBands: [CrosstalkBand] = [
    CrosstalkBand(lowerHz: 200.0, upperHz: 400.0, gateDB: pannedProgramCrosstalkGateDB),
    CrosstalkBand(lowerHz: 400.0, upperHz: 800.0, gateDB: pannedProgramCrosstalkGateDB),
    CrosstalkBand(lowerHz: 800.0, upperHz: 1_600.0, gateDB: pannedProgramCrosstalkGateDB),
    CrosstalkBand(lowerHz: 1_600.0, upperHz: 3_200.0, gateDB: pannedProgramCrosstalkGateDB),
    CrosstalkBand(lowerHz: 3_200.0, upperHz: 6_400.0, gateDB: pannedProgramCrosstalkGateDB),
    CrosstalkBand(lowerHz: 6_400.0, upperHz: 10_000.0, gateDB: pannedProgramCrosstalkGateDB),
    CrosstalkBand(lowerHz: 10_000.0, upperHz: 15_000.0, gateDB: pannedProgramCrosstalkGateHFDB)
]

struct DecodedBandCrosstalk {
    let band: CrosstalkBand
    /// Band RMS of the driven (left) decoded channel, dBFS (approximate:
    /// Hann-windowed FFT power, exact for tones inside the band).
    let drivenDBFS: Float
    /// Band RMS of the undriven (right) decoded channel, dBFS.
    let otherDBFS: Float
    /// Driven minus undriven: the decoded separation in that band.
    var crosstalkDB: Float { drivenDBFS - otherDBFS }
}

struct DecodedCrosstalkResult {
    let bands: [DecodedBandCrosstalk]
    /// Wideband decoded side / mid RMS ratio over the analysis window
    /// (1.0 for a perfect L-only decode).
    let sideToMidRatio: Float
    /// Wideband decoded left / right RMS, dB: the figure the Meter's
    /// SEPARATION readout shows on this content.
    let leftToRightDB: Float
    let analysisSeconds: Double

    /// A band is gated only when the driven channel holds programme there:
    /// within `pannedProgramContentWindowDB` of its loudest band. Below
    /// that the band carries only noise and intermodulation, and an R / L
    /// ratio against a near-empty L band measures distortion against
    /// nothing (program_mix has tones at 220 / 880 / 3200 Hz and white
    /// noise at about -45 dBFS; its 400-800 Hz band sits near -60 dBFS).
    func hasProgramme(_ band: DecodedBandCrosstalk) -> Bool {
        guard let loudest = bands.map(\.drivenDBFS).max() else { return false }
        return band.drivenDBFS >= loudest - pannedProgramContentWindowDB
    }
}

/// Largest power-of-two FFT that fits in half the render, capped at 2^17
/// (0.68 s at 192 kHz, 1.46 Hz bins).
private func crosstalkFFTSize(sampleCount: Int) -> Int {
    let maxSize = min(sampleCount / 2, 131_072)
    guard maxSize >= 1024 else { return 0 }
    return 1 << Int(floor(log2(Double(maxSize))))
}

/// Per-band RMS (dBFS, approximate) of `samples[start..<start+fftSize]`
/// from one Hann-windowed real FFT. `vDSP_fft_zrip` returns twice the DFT,
/// so a sine of amplitude A lands as |X| = A * N / 2 after the window's 0.5
/// coherent gain; `2 / N^2` turns the summed squared magnitudes back into a
/// mean-square. Only the L-vs-R ratio is gated; the absolute scale is for
/// the human reading the table.
func fftBandRMSDB(
    samples: [Float],
    sampleRate: Double,
    start: Int,
    fftSize: Int,
    bands: [CrosstalkBand]
) -> [Float] {
    guard fftSize >= 1024, start >= 0, start + fftSize <= samples.count else {
        return [Float](repeating: -200.0, count: bands.count)
    }
    let log2n = vDSP_Length(log2(Double(fftSize)))
    var window = [Float](repeating: 0.0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    let signal = Array(samples[start..<(start + fftSize)])
    var windowed = [Float](repeating: 0.0, count: fftSize)
    vDSP_vmul(signal, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

    let halfSize = fftSize / 2
    var real = [Float](repeating: 0.0, count: halfSize)
    var imag = [Float](repeating: 0.0, count: halfSize)
    var mags = [Float](repeating: 0.0, count: halfSize)
    real.withUnsafeMutableBufferPointer { realPtr in
        imag.withUnsafeMutableBufferPointer { imagPtr in
            mags.withUnsafeMutableBufferPointer { magsPtr in
                guard let realBase = realPtr.baseAddress,
                    let imagBase = imagPtr.baseAddress,
                    let magsBase = magsPtr.baseAddress
                else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                windowed.withUnsafeBufferPointer { windowedPtr in
                    guard let windowedBase = windowedPtr.baseAddress else { return }
                    windowedBase.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_destroy_fftsetup(fftSetup)
                vDSP_zvmags(&split, 1, magsBase, 1, vDSP_Length(halfSize))
            }
        }
    }

    let binHz = sampleRate / Double(fftSize)
    let scale = 2.0 / (Double(fftSize) * Double(fftSize))
    return bands.map { band in
        let firstBin = max(1, Int((band.lowerHz / binHz).rounded(.up)))
        let lastBin = min(halfSize - 1, Int((band.upperHz / binHz).rounded(.down)))
        guard firstBin <= lastBin else { return -200.0 }
        var power = 0.0
        for bin in firstBin...lastBin { power += Double(mags[bin]) }
        return dbfs(sqrt(max(power * scale, 1e-24)))
    }
}

/// Render `source` through the chain in `config`, decode it coherently
/// (exact pilot-phase fit, `decodeMPXWithReference`, the same decode
/// `--verify-receiver` scores its tones with) and read the per-band RMS of
/// both decoded channels over the settled tail of the render.
func decodedBandCrosstalk(
    config: AppConfig,
    durationSeconds: Double,
    bands: [CrosstalkBand] = pannedProgramCrosstalkBands,
    source: (_ frameIndex: Int, _ sampleRate: Double) -> (Float, Float)
) -> DecodedCrosstalkResult {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds, source: source)
    let sampleRate = cfg.sampleRate
    let fftSize = crosstalkFFTSize(sampleCount: samples.count)
    guard fftSize > 0 else {
        return DecodedCrosstalkResult(bands: [], sideToMidRatio: 0.0, leftToRightDB: 0.0, analysisSeconds: 0.0)
    }
    let start = samples.count - fftSize
    let pilot = estimatePilotPhase(samples: samples, sampleRate: sampleRate, start: start, count: fftSize)
    let decoded = decodeMPXWithReference(
        samples: samples,
        pilotPhase: pilot.phase,
        config: cfg,
        programActivity: 0.5,
        expectedSide: 0.0
    )
    let left = fftBandRMSDB(samples: decoded.left, sampleRate: sampleRate, start: start, fftSize: fftSize, bands: bands)
    let right = fftBandRMSDB(samples: decoded.right, sampleRate: sampleRate, start: start, fftSize: fftSize, bands: bands)
    let leftWindow = Array(decoded.left[start..<(start + fftSize)])
    let rightWindow = Array(decoded.right[start..<(start + fftSize)])
    let wide = computeStereoSignalMetrics(left: leftWindow, right: rightWindow)
    var leftSq = 0.0
    var rightSq = 0.0
    for i in 0..<fftSize {
        leftSq += Double(leftWindow[i]) * Double(leftWindow[i])
        rightSq += Double(rightWindow[i]) * Double(rightWindow[i])
    }
    let leftToRight = dbfs(sqrt(max(leftSq, 1e-24))) - dbfs(sqrt(max(rightSq, 1e-24)))
    var rows: [DecodedBandCrosstalk] = []
    for (index, band) in bands.enumerated() {
        rows.append(DecodedBandCrosstalk(band: band, drivenDBFS: left[index], otherDBFS: right[index]))
    }
    return DecodedCrosstalkResult(
        bands: rows,
        sideToMidRatio: wide.sideToMidRatio,
        leftToRightDB: leftToRight,
        analysisSeconds: Double(fftSize) / sampleRate
    )
}

/// Coherent-decode separation of a left-only sine at an arbitrary level:
/// `receiverToneMetrics` with the amplitude as a parameter (that one is
/// fixed at 0.45).
func coherentLeftOnlyToneSeparationDB(
    config: AppConfig,
    toneHz: Double,
    amplitude: Double,
    durationSeconds: Double
) -> Float {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, 0.0)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples, sampleRate: cfg.sampleRate, start: window.start, count: window.count)
    let decoded = decodeMPXWithReference(
        samples: samples,
        pilotPhase: pilot.phase,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let left = toneVector(
        samples: decoded.left, sampleRate: cfg.sampleRate, frequencyHz: toneHz,
        start: window.start, count: window.count)
    let right = toneVector(
        samples: decoded.right, sampleRate: cfg.sampleRate, frequencyHz: toneHz,
        start: window.start, count: window.count)
    return drivenChannelSeparation(driven: left, other: right).separationDB
}

/// A chain variant for the separation tables: the Verification.ini chain
/// as-is, or that chain with a shipped Format Profile's fan-out applied.
struct SeparationChainVariant {
    let label: String
    /// nil = the base config untouched.
    let profileID: String?

    func config(from base: AppConfig) -> AppConfig {
        var cfg = base
        if let profileID {
            _ = PresetCatalog.applyFormatProfile(id: profileID, to: &cfg)
        }
        return cfg
    }

    static let verificationINI = SeparationChainVariant(label: "Verification.ini", profileID: nil)
    static let musicClean = SeparationChainVariant(label: "music_clean (default)", profileID: "music_clean")
    static let musicLoud = SeparationChainVariant(label: "music_loud", profileID: "music_loud")
}

struct LeftOnlyToneSeparationRow {
    let variant: SeparationChainVariant
    let amplitude: Double
    let toneHz: Double
    let processedDB: Float
    let bypassDB: Float
    /// Bypass minus processed, both clamped at `separationABClampDB`.
    var lossDB: Float {
        min(separationABClampDB, bypassDB) - min(separationABClampDB, processedDB)
    }
    var gateDB: Float { toneHz >= 14_000.0 ? separationGate14kDB : separationGateDB }
    var lossGated: Bool { toneHz == 1_000.0 || toneHz == 10_000.0 }
}

let leftOnlyToneSetFrequencies: [Double] = [1_000.0, 5_000.0, 10_000.0, 14_000.0]
let leftOnlyToneSetAmplitudes: [Double] = [0.1, 0.3, 0.5]
let separationProfileVariants: [SeparationChainVariant] = [.musicClean, .musicLoud]

/// D2: the L-only tone set, processed and bypass, on the shipped profiles.
func leftOnlyToneSeparationRows(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> [LeftOnlyToneSeparationRow] {
    var rows: [LeftOnlyToneSeparationRow] = []
    for variant in separationProfileVariants {
        let processedConfig = variant.config(from: baseConfig)
        var bypassConfig = processedConfig
        bypassConfig.processingBypass = true
        for amplitude in leftOnlyToneSetAmplitudes {
            for toneHz in leftOnlyToneSetFrequencies {
                let processed = coherentLeftOnlyToneSeparationDB(
                    config: processedConfig, toneHz: toneHz, amplitude: amplitude,
                    durationSeconds: durationSeconds)
                let bypass = coherentLeftOnlyToneSeparationDB(
                    config: bypassConfig, toneHz: toneHz, amplitude: amplitude,
                    durationSeconds: durationSeconds)
                rows.append(LeftOnlyToneSeparationRow(
                    variant: variant, amplitude: amplitude, toneHz: toneHz,
                    processedDB: processed, bypassDB: bypass))
            }
        }
    }
    return rows
}

struct PannedProgramCrosstalkRow {
    let variant: SeparationChainVariant
    let monoBassCornerHz: Double?
    let processed: DecodedCrosstalkResult
    /// `processing_bypass` as the operator's A/B has it: Final Drive and the
    /// composite peak chain still run, so on a hot profile this row is a
    /// clipped composite, not a clean encoder (audit section 0).
    let bypass: DecodedCrosstalkResult
    /// `processing_bypass` with Final Drive at 0 dB: the composite sits
    /// under the clipper threshold and this is the encoder alone -- the
    /// clean reference the >= 60 dB note is read against.
    let encoderOnly: DecodedCrosstalkResult
    /// The processed chain with the stereo-image protector flipped against
    /// the variant's own setting (an option since 2026-10, default OFF):
    /// informational, so the table shows what the stage does to panned
    /// programme in either direction.
    let protectorFlipped: DecodedCrosstalkResult
    /// True when the variant itself runs the protector (then
    /// `protectorFlipped` is the chain without it).
    let protectorOnInVariant: Bool

    /// False for a band the mono-bass stage legitimately fills.
    func outsideMonoBass(_ band: CrosstalkBand) -> Bool {
        guard let corner = monoBassCornerHz else { return true }
        return band.lowerHz >= corner * monoBassCrosstalkExclusionFactor
    }
}

/// D3: `panned_program` through Verification.ini and the shipped profiles,
/// processed and bypass.
func pannedProgramCrosstalkRows(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> [PannedProgramCrosstalkRow]? {
    guard let scenario = verificationScenarios().first(where: { $0.name == "panned_program" }) else {
        return nil
    }
    var rows: [PannedProgramCrosstalkRow] = []
    for variant in [SeparationChainVariant.verificationINI] + separationProfileVariants {
        let processedConfig = variant.config(from: baseConfig)
        var bypassConfig = processedConfig
        bypassConfig.processingBypass = true
        var encoderOnlyConfig = bypassConfig
        encoderOnlyConfig.finalDriveDB = 0.0
        // The scenario's noise generators are shared state inside the
        // closure, so each render takes a fresh scenario table: the three
        // renders then see identical noise streams.
        func render(_ cfg: AppConfig) -> DecodedCrosstalkResult {
            guard let fresh = verificationScenarios().first(where: { $0.name == scenario.name }) else {
                return DecodedCrosstalkResult(bands: [], sideToMidRatio: 0.0, leftToRightDB: 0.0, analysisSeconds: 0.0)
            }
            return decodedBandCrosstalk(config: cfg, durationSeconds: durationSeconds, source: fresh.sample)
        }
        var protectorFlippedConfig = processedConfig
        protectorFlippedConfig.stereoImageProtectEnabled.toggle()
        rows.append(PannedProgramCrosstalkRow(
            variant: variant,
            monoBassCornerHz: processedConfig.monoBassEnabled ? processedConfig.monoBassFreqHz : nil,
            processed: render(processedConfig),
            bypass: render(bypassConfig),
            encoderOnly: render(encoderOnlyConfig),
            protectorFlipped: render(protectorFlippedConfig),
            protectorOnInVariant: processedConfig.stereoImageProtectEnabled))
    }
    return rows
}

/// Prints the D2 / D3 tables and returns the gate findings: `warnings` are
/// TIGHT (exit 1) lines for `runReceiverModelVerification`, `notes` are
/// informational.
func runSeparationGateSection(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> (warnings: [String], notes: [String]) {
    var warnings: [String] = []
    var notes: [String] = []
    let toneDuration = max(1.5, min(durationSeconds, 2.5))
    let programDuration = max(2.0, min(durationSeconds, 4.0))

    // D2 + the processed-vs-bypass A/B.
    let toneRows = leftOnlyToneSeparationRows(baseConfig: baseConfig, durationSeconds: toneDuration)
    print("")
    print("L-Only Tone Set: processed vs bypass (coherent decode, shipped profiles)")
    print(
        "Gate: processed >= \(String(format: "%.0f", separationGateDB)) dB"
            + " (\(String(format: "%.0f", separationGate14kDB)) dB at 14 kHz) at every level;"
            + " loss (bypass - processed, both clamped at \(String(format: "%.0f", separationABClampDB)) dB)"
            + " <= \(String(format: "%.0f", separationBypassLossGateDB)) dB at 1 / 10 kHz."
    )
    print("Profile                 Level  Tone Hz  Processed  Bypass   Loss   Gate")
    print("----------------------  -----  -------  ---------  -------  -----  ----")
    for row in toneRows {
        var verdict = "OK"
        if row.processedDB < row.gateDB {
            verdict = "LOW"
            warnings.append(
                "L-only \(Int(row.toneHz)) Hz at \(String(format: "%.1f", row.amplitude)) FS on \(row.variant.label):"
                    + " processed separation \(String(format: "%.1f", row.processedDB)) dB"
                    + " < \(String(format: "%.0f", row.gateDB)) dB"
            )
        }
        if row.lossGated, row.lossDB > separationBypassLossGateDB {
            verdict = verdict == "OK" ? "LOSS" : "\(verdict)+LOSS"
            warnings.append(
                "L-only \(Int(row.toneHz)) Hz at \(String(format: "%.1f", row.amplitude)) FS on \(row.variant.label):"
                    + " processing costs \(String(format: "%.1f", row.lossDB)) dB of separation vs bypass"
                    + " (> \(String(format: "%.0f", separationBypassLossGateDB)) dB)"
            )
        }
        print(
            "\(padded(row.variant.label, width: 22))"
                + "  \(String(format: "%5.2f", row.amplitude))"
                + "  \(leftPadded(String(format: "%.0f", row.toneHz), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", row.processedDB), width: 9))"
                + "  \(leftPadded(String(format: "%.1f", row.bypassDB), width: 7))"
                + "  \(String(format: "%+5.1f", row.lossDB))"
                + "  \(verdict)"
        )
    }

    // D3.
    print("")
    print("Panned Programme Crosstalk (program_mix into L only, coherent decode, L - R band RMS in dB)")
    print(
        "Gate on the processed row: >= \(String(format: "%.0f", pannedProgramCrosstalkGateDB)) dB"
            + " 200 Hz - 10 kHz, >= \(String(format: "%.0f", pannedProgramCrosstalkGateHFDB)) dB 10 - 15 kHz"
            + " (`pannedProgramCrosstalkGateDB`, the clipper task may tune it)."
    )
    print(
        "Rows: processed; bypass (processing_bypass, Final Drive and the composite clipper still run);"
            + " encoder only (bypass at 0 dB drive, the clean reference, >= \(String(format: "%.0f", pannedProgramBypassReferenceDB)) dB is a note);"
            + " L dBFS (the driven channel's band level, processed row)."
    )
    print(
        "'mb' marks a band under \(String(format: "%.0f", monoBassCrosstalkExclusionFactor)) x the mono-bass corner,"
            + " 'nc' a band more than \(String(format: "%.0f", pannedProgramContentWindowDB)) dB under the loudest driven band"
            + " (noise and IM only): both reported, not gated. L/R = wideband decoded L - R RMS."
    )
    guard let programRows = pannedProgramCrosstalkRows(baseConfig: baseConfig, durationSeconds: programDuration) else {
        warnings.append("panned_program scenario missing from verificationScenarios(); crosstalk table skipped")
        return (warnings, notes)
    }
    let modeWidth = 13
    var header = "\(padded("Config", width: 22))  \(padded("Mode", width: modeWidth))"
    for band in pannedProgramCrosstalkBands { header += "  \(leftPadded(band.label, width: 9))" }
    header += "    S/M    L/R"
    print(header)
    print(String(repeating: "-", count: header.count))
    func gatedBands(_ result: DecodedCrosstalkResult, _ row: PannedProgramCrosstalkRow) -> [DecodedBandCrosstalk] {
        result.bands.filter { row.outsideMonoBass($0.band) && result.hasProgramme($0) }
    }
    func line(_ label: String, _ mode: String, _ result: DecodedCrosstalkResult, _ row: PannedProgramCrosstalkRow, marks: Bool) -> String {
        var text = "\(padded(label, width: 22))  \(padded(mode, width: modeWidth))"
        for band in result.bands {
            var mark = ""
            if marks {
                if !row.outsideMonoBass(band.band) { mark = " mb" } else if !result.hasProgramme(band) { mark = " nc" }
            }
            text += "  \(leftPadded(String(format: "%.1f", band.crosstalkDB) + mark, width: 9))"
        }
        text += "  \(String(format: "%5.3f", result.sideToMidRatio))"
        text += "  \(String(format: "%5.1f", result.leftToRightDB))"
        return text
    }
    for row in programRows {
        print(line(row.variant.label, "processed", row.processed, row, marks: true))
        print(line("", row.protectorOnInVariant ? "protector OFF" : "protector ON", row.protectorFlipped, row, marks: true))
        print(line("", "bypass", row.bypass, row, marks: false))
        print(line("", "encoder only", row.encoderOnly, row, marks: false))
        var levels = "\(padded("", width: 22))  \(padded("L dBFS", width: modeWidth))"
        for band in row.processed.bands { levels += "  \(leftPadded(String(format: "%.1f", band.drivenDBFS), width: 9))" }
        print(levels)
        for band in gatedBands(row.processed, row) where band.crosstalkDB < band.band.gateDB {
            warnings.append(
                "panned programme on \(row.variant.label), \(band.band.label) Hz:"
                    + " processed crosstalk \(String(format: "%.1f", band.crosstalkDB)) dB"
                    + " < \(String(format: "%.0f", band.band.gateDB)) dB"
            )
        }
        for band in gatedBands(row.encoderOnly, row) where band.crosstalkDB < pannedProgramBypassReferenceDB {
            notes.append(
                "panned programme on \(row.variant.label), \(band.band.label) Hz:"
                    + " encoder-only reference \(String(format: "%.1f", band.crosstalkDB)) dB"
                    + " < \(String(format: "%.0f", pannedProgramBypassReferenceDB)) dB"
            )
        }
    }
    var gateLine = "\(padded("gate", width: 22))  \(padded("", width: modeWidth))"
    for band in pannedProgramCrosstalkBands {
        gateLine += "  \(leftPadded(String(format: "%.0f", band.gateDB), width: 9))"
    }
    print(gateLine)
    return (warnings, notes)
}
