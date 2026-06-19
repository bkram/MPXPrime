import Foundation

struct AppConfig {
    static let appVersion: String = "0.37"

    // App-support folder / config filename for MPX Prime Studio (the encoder,
    // paired with "MPX Prime Meter").
    static let appSupportDirName = "MPX Prime Studio"
    static let configFileName = "MPX Prime Studio.ini"

    static var defaultINIPath: String {
        let fileManager = FileManager.default
        if let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return appSupport
                .appendingPathComponent(appSupportDirName, isDirectory: true)
                .appendingPathComponent(configFileName, isDirectory: false)
                .path
        }
        return ((NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/\(appSupportDirName)/\(configFileName)")
            as NSString)
            .standardizingPath
    }

    // Parameter apply behaviour:
    //
    // Live-apply (via RuntimeConfig — changes take effect immediately):
    //   sourceMode (input ↔ tone — flips render branch live),
    //   testToneMode/Freq/LevelDB/Type (tone-generator parameters),
    //   inputGainDB, outputGainDB, finalDriveDB, mpxDeviationKHz,
    //   preEncodeAudioLimiterEnabled, preEncodeThreshold, preEncodeReleaseMS,
    //   preEncodeBandlimitedResidualEnabled/Taps/CutoffFraction,
    //   preEncodeLookaheadMS, preEncodeLookaheadHFOnly, preEncodeLookaheadHFCutoffHz,
    //   widebandAGCEnabled/Target/Attack/Release/MaxGain/MinGain,
    //   primeBassEnabled/Amount/FreqHz/Harmonics/Drive/Density/Subharmonics*,
    //   monoBassEnabled/FreqHz,
    //   stereoWidenEnabled/Width/Center/Mix,
    //   multiband Enabled/Mode/X1-X4Hz/Thresholds/Ratios/Attack/Release/
    //     KneeDB/LinkStrength/MakeupDB/ReleaseProgramDependent/
    //     TransientAwareAttack/InterBandCoupling,
    //   phaseRotationEnabled/FreqHz, parametricEQEnabled/B1-B4(Freq/Gain/Q),
    //   multibandLimiterEnabled/ThresholdDB/AttackMS/ReleaseMS,
    //   downwardExpanderEnabled/ThresholdDB/Ratio/AttackMS/ReleaseMS,
    //   bassClipperEnabled/CrossoverHz/ThresholdDB/Drive,
    //   dcClipperEnabled/CeilingDB/CancelFreqHz,
    //   bs412Enabled/ThresholdDB/WindowSeconds
    //
    // Live-apply RDS (via RDSRuntimeConfig — changes take effect immediately):
    //   Master:    enRDS
    //   Identity:  rdsPI, rdsPTY, rdsPTYN/Enable/Centered, rdsECC, rdsLIC
    //   Flags:     rdsTP, rdsTA (TA-edge force-injects 0A per UECP §2.5.1.1),
    //              rdsMS, rdsDI_STEREO/HEAD/COMP/DYN
    //   PS:        rdsPSA/B/C/D, rdsPSActiveBank, rdsPSCentered, rdsPSFrameSeconds
    //   Long PS:   rdsLongPS32, rdsEnableLPS, rdsLPSCentered, rdsLPSCR
    //   RT:        rdsRTText, rdsRTA/B/C/D, rdsRT*BufferEnabled,
    //              rdsRTMode, rdsRTCycleTime, rdsRTCycleAB, rdsRTABCycleCount,
    //              rdsRTCR, rdsRTCentered, rdsEnableRTPlus,
    //              rdsRTPlusFormatA/B, rdsNowPlayingEnabled
    //   AF:        rdsEnableAF, rdsAFList, rdsAFMethod (Method A and Method B both supported)
    //   Schedule:  rdsGroupSequence, rdsSchedulerAuto/Standard/StandardLPS,
    //              rdsEnableCT, rdsEnableID, rdsTZOffset
    //
    // Restart-required (engine must be restarted):
    //   sampleRate, blockSize, device UIDs, monitorEnabled,
    //   monoMode, preemphasisUS, pilotLevel, sumLevel, diffLevel,
    //   programLowpassHz, limitMPX/Threshold/Lookahead*, processingBypass,
    //   hpfHz, hfTrimDB/Hz,
    //   audioCompositeSoftClipEnabled, audioCompositeSmootherEnabled,
    //   finalMPXSoftClipEnabled,
    //   RDS physical-layer: rdsLevel (injection kHz),
    //                       rdsGaussianEnabled/BWHZ/Taps (modulator FIR)

    var sampleRate: Double = 192_000.0
    var fftWindow96kHz: Bool = true
    var blockSize: Int = 1024
    // Dual-rate audio chain (plan.md "Next up" #1, Phase 2 LANDED 0.30).
    //
    // When enabled, the entire audio domain (program stereo, multiband,
    // AGC, EQ, image protection, pre-emphasis, pre-encode limiter) runs
    // at `dualRateAudioDomainRateHz` (48 kHz default) inside a
    // Kaiser-windowed sinc polyphase resampler boundary, while the MPX
    // domain (composite assembly, BS.412, composite clipper, audio-
    // composite bandwidth FIR, final-MPX safety limiter, pilot + RDS
    // injection) stays at the engine's MPX rate. Measured payoff on
    // M1 Pro: ~42% relative CPU saving at 192 kHz output, with stereo
    // separation preserved (1k/10k/14k matches the boundary-off
    // baseline within run-to-run noise).
    //
    // Only INTEGER engine:audio rate ratios are supported (192/48 = 4,
    // 96/48 = 2). Non-integer ratios (176.4/48, 128/48) silently
    // disable the boundary at engine start and run the audio domain at
    // the MPX rate as in pre-Phase-2.
    //
    // Restart-required: allocates the resampler delay lines and
    // re-configures every audio-domain stage at the chosen audio rate.
    //
    // Default-ON since 0.30 (the 2026-05-23 cutover commit). Operators
    // who want the legacy single-rate chain can set this to False in
    // their INI.
    var dualRateAudioDomainEnabled: Bool = true
    var dualRateAudioDomainRateHz: Double = 48_000.0
    var sourceMode: String = "input"
    var inputDeviceUID: String?
    var outputDeviceUID: String?
    var monitorDeviceUID: String?
    // Human device names stored alongside the UIDs. Core Audio device UIDs can
    // change when a USB interface is moved to a different port; the name is the
    // stable fallback used to re-match the same device, and to show which device
    // is remembered when it is currently unplugged.
    var inputDeviceName: String?
    var outputDeviceName: String?
    var monitorDeviceName: String?
    var monitorEnabled: Bool = false
    // Output mode. When true, the MPX output device emits processed stereo L/R
    // audio (post pre-encode limiter) instead of the FM composite — for feeding
    // an external stereo coder / RDS encoder. No pilot / subcarrier / RDS /
    // composite clipper / BS.412 in this mode. Restart-required (changes render
    // rate, device format, and FIR plumbing). Takes precedence over
    // `monitorEnabled` (the decoded-MPX monitor is meaningless without a composite).
    var processedAudioOutput: Bool = false
    var processingBypass: Bool = false
    var testToneMode: String = "mono"
    var testToneFreq: Double = 1000.0
    var testToneLevelDB: Double = -20.0   // Broadcast line-reference default
    var testToneType: String = "sine"     // "sine" | "pink" | "white"
    var pilotLevel: Double = 0.08
    var sumLevel: Double = 1.0
    var diffLevel: Double = 1.0
    var monoMode: Bool = false
    var inputGainDB: Double = 0.0
    var outputGainDB: Double = 0.0
    var finalDriveDB: Double = 6.0
    var finalStagePresetID: String = "balanced"
    // Top-level "Station Format" profile that atomically applies a coherent
    // bundle of multiband / final-stage / PrimeBass / widener / composite-
    // clipper settings per music format (Pop, Rock, CHR, EDM, Urban,
    // Jazz/Classical, News/Talk, Community Radio). Cosmetic label only —
    // the actual chain state is determined by the individual per-stage IDs
    // set when the profile is applied. INI key: `format_profile_id`.
    var formatProfileID: String = "community_radio"
    var preemphasisUS: Int = 50
    var hpfHz: Double = 30.0
    var hfTrimDB: Double = 0.0
    var hfTrimHz: Double = 4000.0
    var programLowpassHz: Double = 16_000.0
    var limitMPX: Bool = true
    var limitThreshold: Double = 0.98
    var limitLookaheadMS: Double = 5.0
    var limitLookaheadEnabled: Bool = true
    var preEncodeAudioLimiterEnabled: Bool = true
    var preEncodeThreshold: Double = 0.85
    var preEncodeReleaseMS: Double = 50.0
    var preEncodeBandlimitedResidualEnabled: Bool = false
    var preEncodeBandlimitedResidualTapCount: Int = 33
    var preEncodeBandlimitedResidualCutoffFraction: Double = 0.25
    var preEncodeLookaheadMS: Double = 1.0
    var preEncodeLookaheadHFOnly: Bool = true
    var preEncodeLookaheadHFCutoffHz: Double = 4_000.0
    // TX-path encoder bandwidth guard: linear-phase FIR (~1.67 ms latency at
    // 192 kHz, >80 dB stop-band) instead of the default Butterworth (~0.2 ms
    // latency, ~40 dB stop-band). Only active when running in composite
    // output mode; monitor mode always uses the low-latency Butterworth.
    var encoderFIREnabled: Bool = true
    // TX-path multiband crossovers: linear-phase FIR splitters in place of
    // the IIR LR4 cascade. Phase-flat band reconstruction (all bands share
    // the same group delay) prevents the transient smear / inter-band
    // pumping that makes IIR-LR4 multiband sound worse than single-band
    // on percussive content.
    //
    // The 4× ~2049-tap convolutions per host sample run through vDSP_dotpr
    // (Apple Silicon SIMD/AMX) so the FIR path costs ~24% more than IIR
    // on real hardware. Without vDSP this would be 30-50× and overrun
    // real-time. Latency cost: ~5.3 ms at 192 kHz. Monitor mode always
    // uses the low-latency LR4 path. Restart-required.
    var multibandFIREnabled: Bool = true
    var audioCompositeSoftClipEnabled: Bool = true
    // The legacy one-pole composite smoother rolls off the upper stereo
    // sideband enough to limit 10/14 kHz receiver separation. Keep it
    // available as an opt-in compatibility cleanup stage, but default the
    // normal chain to the cleaner softclip-only path.
    var audioCompositeSmootherEnabled: Bool = false
    var finalMPXSoftClipEnabled: Bool = true
    var mpxDeviationKHz: Double = 75.0
    var enRDS: Bool = true
    // AGC defaults: research-grounded "Pop Medium" tuning. AGC ON because
    // every commercial processor (Orban, Omnia, Stereo Tool) ships with
    // AGC engaged — amateur source material (mixed-era MP3s, podcasts,
    // vinyl rips) needs level-evening or single-band peak management
    // pumps on bass-heavy program. Numerics from Orban 8500/8700i manual
    // ranges; widened release cap supplied by 0.10 program-dependent path.
    var widebandAGCEnabled: Bool = true
    var widebandAGCTargetDB: Double = -14.0
    var widebandAGCAttackMS: Double = 6.0
    var widebandAGCReleaseMS: Double = 1500.0
    var widebandAGCMaxGainDB: Double = 10.0
    var widebandAGCMinGainDB: Double = -10.0
    /// Use a BS.1770-flavoured pre-filter (HPF ~38 Hz + high-shelf
    /// +4 dB @ ~1.5 kHz) on the AGC's power detector so the detector
    /// tracks perceived loudness rather than flat RMS. Default on —
    /// the original unweighted detector is preserved when disabled.
    var widebandAGCKWeightingEnabled: Bool = true
    /// Slow AGC release on dense/busy program, speed it up on flat
    /// program. Scales the effective release coefficient up to 3x
    /// based on a 0.5 s density estimate of the detector envelope.
    var widebandAGCReleaseProgramDependent: Bool = true
    /// Bass-desensitise the AGC sidechain (opt-in, default off): clip LF transient
    /// peaks out of the detector (US 4,249,042) + duration-aware fast recovery for
    /// brief reductions (US 3,790,896), so a kick / heavy bass line doesn't pump
    /// the whole chain.
    var widebandAGCBassDesensitizeEnabled: Bool = false
    var primeBassEnabled: Bool = false
    var primeBassPresetID: String = "ac"
    var primeBassAmount: Double = 0.22
    var primeBassFreqHz: Double = 95.0
    var primeBassHarmonics: Double = 0.18
    var primeBassDrive: Double = 0.78
    var primeBassDensity: Double = 0.45
    var primeBassSubharmonicsEnabled: Bool = false
    var primeBassSubharmonicsAmount: Double = 0.20
    var stereoWidenEnabled: Bool = false
    var monoBassEnabled: Bool = true
    var monoBassFreqHz: Double = 125.0
    var stereoWidenWidth: Double = 0.5
    var stereoWidenCenter: Double = 0.5
    var stereoWidenMix: Double = 1.0
    // Multiband defaults: 5-band AC/Pop preset at "Normal" intensity. ON
    // because no commercial processor ships multiband disabled — amateur
    // source mix needs band-aware compression to keep speech and music
    // coherent. "Normal" is the published 5_ac recipe with no multiplier;
    // "Light" (offsets +1.5 dB / ratios ×0.9 / attack ×1.2 / release ×1.15)
    // makes the chain so transparent it sounds like multiband isn't doing
    // anything. The audible-but-clean middle ground is "Normal".
    var multibandEnabled: Bool = true
    var multibandMode: Int = 5
    var multibandPresetID: String = "5_ac"
    var multibandIntensity: String = "normal"
    var multibandX1Hz: Double = 90.0
    var multibandX2Hz: Double = 350.0
    var multibandX3Hz: Double = 1800.0
    var multibandX4Hz: Double = 6800.0
    var multibandLowHz: Double = 320.0
    var multibandHighHz: Double = 2550.0
    var multibandLowThresholdDB: Double = -17.5
    var multibandMidThresholdDB: Double = -16.0
    var multibandHighThresholdDB: Double = -14.5
    var multibandLowRatio: Double = 1.75
    var multibandMidRatio: Double = 1.55
    var multibandHighRatio: Double = 1.28
    var multibandLowAttackMS: Double = 28.0
    var multibandMidAttackMS: Double = 19.0
    var multibandHighAttackMS: Double = 13.0
    var multibandLowReleaseMS: Double = 375.0
    var multibandMidReleaseMS: Double = 300.0
    var multibandHighReleaseMS: Double = 225.0
    var multibandKneeDB: Double = 3.6
    var multibandLinkStrength: Double = 0.52
    var multibandReleaseProgramDependent: Bool = true
    var multibandTransientAwareAttackEnabled: Bool = false
    var multibandInterBandCouplingEnabled: Bool = false
    var multibandMakeupDB: Double = 0.0
    var phaseRotationEnabled: Bool = false
    var phaseRotationFreqHz: Double = 200.0
    var parametricEQEnabled: Bool = false
    // Bands 1 and 4 are shelves (no Q); bands 2 and 3 are peaking (Q exposed).
    var peqB1FreqHz: Double = 80.0
    var peqB1GainDB: Double = 0.0
    var peqB2FreqHz: Double = 500.0
    var peqB2GainDB: Double = 0.0
    var peqB2Q: Double = 1.0
    var peqB3FreqHz: Double = 3000.0
    var peqB3GainDB: Double = 0.0
    var peqB3Q: Double = 1.0
    var peqB4FreqHz: Double = 8000.0
    var peqB4GainDB: Double = 0.0
    var multibandLimiterEnabled: Bool = false
    var multibandLimiterThresholdDB: Double = -3.0
    var multibandLimiterAttackMS: Double = 0.5
    var multibandLimiterReleaseMS: Double = 50.0
    var downwardExpanderEnabled: Bool = false
    var expanderThresholdDB: Double = -45.0
    var expanderRatio: Double = 2.0
    var expanderAttackMS: Double = 10.0
    var expanderReleaseMS: Double = 200.0
    // Bass clipper defaults: ON, gentle drive. Orban + Omnia run bass
    // clipping in every factory preset — uncontrolled LF peaks waste 2-3
    // dB of total modulation budget on inaudible sub-content.
    // Distortion-cancelled bass clipping is sonically transparent at
    // moderate drive.
    var bassClipperEnabled: Bool = true
    var bassClipperCrossoverHz: Double = 150.0
    var bassClipperThresholdDB: Double = -3.0
    var bassClipperDrive: Double = 1.5
    // Pre-emphasis-aware HF clipper (opt-in, default off). Clips the high band
    // of the pre-emphasized L/R so HF transients are tamed by a dedicated stage
    // instead of forcing the broadband pre-encode limiter to dull everything.
    // De-emphasis-correct (limits pre-emphasized HF; receiver restores curve).
    var hfClipperEnabled: Bool = false
    var hfClipperCrossoverHz: Double = 5_000.0
    var hfClipperThresholdDB: Double = -3.0
    var hfClipperDrive: Double = 1.2
    var dcClipperEnabled: Bool = false
    var dcClipperCeilingDB: Double = -1.0
    var dcClipperCancelFreqHz: Double = 2000.0
    // Processed-audio output: optional final loudness clipper for the L/R feed.
    // Framed around the external coder: when it has its OWN clipper (default), MPX
    // Prime stays clean (no extra clip) to avoid double-clipping; when it does not,
    // MPX Prime applies an oversampled final clipper driven by the drive control to
    // add density. Only active in processed-audio output mode.
    var processedAudioCoderHasClipper: Bool = true
    var processedAudioFinalClipDriveDB: Double = 6.0
    var bs412Enabled: Bool = false
    var bs412ThresholdDB: Double = -10.0
    var bs412WindowSeconds: Double = 60.0
    // Composite clipper defaults: ON with additive distortion cancellation
    // (Orban US 4,460,871 / 5,737,434, expired). Threshold/ceiling tuned for
    // ~1.5 dB perceived loudness lift on real program.
    //
    // Cancellation toggles subtract bandpass-filtered clip residual from
    // protected bands of the output. Defaults:
    //   cancelAudio  = false → audio band keeps full clipping (peak control)
    //   cancelStereo = true  → 23–53 kHz (L-R) subcarrier rides through
    //                          clean → stereo separation preserved
    //   cancelPilot  = true  → 17–21 kHz pilot guard kept clean for the
    //                          post-stage 19 kHz pilot injection
    //   cancelRDS    = true  → 55–59 kHz RDS guard kept clean for the
    //                          post-stage 57 kHz RDS injection
    var compositeClipperEnabled: Bool = true
    var compositeClipperThresholdDB: Double = -1.0
    var compositeClipperCeilingDB: Double = -0.3
    var compositeClipperCancelAudio: Bool = false
    var compositeClipperCancelStereo: Bool = true
    var compositeClipperCancelPilot: Bool = true
    var compositeClipperCancelRDS: Bool = true
    // Look-ahead composite peak control (0.0 disables; recommended preset: 2.0 ms).
    // Sliding-window-max detector + half-cosine attack + 200 Hz smoothed gain
    // applied pre-clip so the soft-clip kernel sees an already-shaved signal.
    // See plan.md "Enterprise-parity status" / 0.26 release plan.
    var compositeClipperLookaheadMS: Double = 0.0
    // Composite clipper oversampling factor. 16 (default) matches Optimod
    // 8X00 / Omnia.11 / Stereotool industry practice. 8 trades some
    // alias suppression for ~50% lower CPU on this stage (useful on weaker
    // hardware). 32 gives ~6 dB further alias suppression at hot drives
    // but roughly doubles this stage's CPU — recommended only with
    // hardware headroom. Restart-required: changes the FIR decimator tap
    // count, the Lagrange interpolator step count, and the per-host batch
    // buffer sizes.
    var compositeClipperOversampling: Int = 16
    var compositeMultibandClipperEnabled: Bool = false
    var rdsLevel: Double = 2.0
    var rdsPI: String = "82FF"
    var rdsPTY: Int = 8
    // PTY genre-table region for the UI picker / status label only. The
    // transmitted 5-bit PTY code is identical either way; Europe (RDS,
    // EN 50067) and North America (RBDS, NRSC-4) just label the same code
    // with different genres and receivers pick the table by region. UI /
    // authoring preference only -- no on-air effect (runtimeDisposition .none).
    var rdsPtyRBDS: Bool = false
    var rdsTP: Bool = false
    var rdsTA: Bool = false
    var rdsMS: Bool = true
    var rdsDI_STEREO: Bool = true
    var rdsDI_HEAD: Bool = false
    var rdsDI_COMP: Bool = true
    var rdsDI_DYN: Bool = false
    var rdsEnableAF: Bool = false
    var rdsAFList: String = "88.1, 98.8, 106.6"
    var rdsAFMethod: String = "A"
    // PS dynamic text is stored as 4 banks, with exactly one active at a time.
    // On load, the legacy `ps_dynamic` key (if present and the new bank keys
    // are empty) migrates into bank A. The active bank's text is transmitted;
    // selecting an empty bank transmits 8 spaces.
    var rdsPSA: String = "3s:Stereo- 3s:Fool 3s:MAC 3s:App 3s:FM 3s:MPX 3s:+RDS"
    var rdsPSB: String = ""
    var rdsPSC: String = ""
    var rdsPSD: String = ""
    var rdsPSActiveBank: String = "A"
    var rdsPSCentered: Bool = true
    /// Default duration in seconds for each PS segment when the source text
    /// has no explicit `Ns:` / `Nt:` timing marker. Typical professional
    /// rotation cadence is 3 seconds per 8-character chunk.
    var rdsPSFrameSeconds: Double = 3.0

    /// Returns the raw text of the currently active PS bank. Empty string if
    /// the active bank is empty or the selector is invalid.
    var activePSBankText: String {
        switch rdsPSActiveBank.uppercased() {
        case "A": return rdsPSA
        case "B": return rdsPSB
        case "C": return rdsPSC
        case "D": return rdsPSD
        default:  return rdsPSA
        }
    }
    /// Programme Item Number packed for Group 1A block 4: 5 bits day (1-31),
    /// 5 bits hour (0-23), 6 bits minute (0-59). 0 when disabled (no PIN).
    var rdsPINValue: Int {
        guard rdsEnablePIN else { return 0 }
        let day = min(31, max(1, rdsPINDay))
        let hour = min(23, max(0, rdsPINHour))
        let minute = min(59, max(0, rdsPINMinute))
        return (day << 11) | (hour << 6) | minute
    }

    var rdsRTText: String =
        "10s:MPX Prime Studio FM MPX Generator/10s:Native macOS Swift App"
    var rdsRTManualBuffers: Bool = false
    var rdsRTCycleAB: Bool = false
    var rdsRTA: String = "MPX Prime Studio: FM MPX + RDS Audio Processor"
    var rdsRTB: String = "MPX Prime Studio: FM MPX Generator"
    var rdsRTC: String = ""
    var rdsRTD: String = ""
    var rdsRTBufferAEnabled: Bool = true
    var rdsRTBufferBEnabled: Bool = true
    var rdsRTBufferCEnabled: Bool = false
    var rdsRTBufferDEnabled: Bool = false
    var rdsRTCR: Bool = true
    var rdsRTCentered: Bool = false
    var rdsRTMode: String = "2A"
    var rdsRTCycle: Bool = true
    var rdsRTCycleTime: Double = 5.0
    var rdsRTActiveBuffer: Int = 0
    var rdsRTABCycleCount: Int = 2
    var rdsPTYN: String = "-STEREO-"
    var rdsEnablePTYN: Bool = true
    var rdsPTYNCentered: Bool = false
    var rdsLongPS32: String = "MPX Prime Studio Stereo+RDS"
    var rdsEnableLPS: Bool = true
    var rdsLPSCentered: Bool = false
    var rdsLPSCR: Bool = true
    var rdsEnableRTPlus: Bool = false
    var rdsRTPlusFormatA: String = "{artist} - {title}"
    var rdsRTPlusFormatB: String = "{artist} - {title}"
    var rdsNowPlayingEnabled: Bool = false
    var rdsNowPlayingScript: String = ""
    var rdsNowPlayingPollSeconds: Double = 5.0
    var rdsNowPlayingTimeoutSeconds: Double = 1.0
    var rdsECC: String = "E3"
    var rdsLIC: String = "1D"
    // Programme Item Number (Group 1A, block 4): the scheduled start of the
    // current programme item. Off by default (transmits 0). Day 1-31, hour
    // 0-23, minute 0-59 -- a static value the operator sets, per spec intent.
    var rdsEnablePIN: Bool = false
    var rdsPINDay: Int = 1
    var rdsPINHour: Int = 0
    var rdsPINMinute: Int = 0
    var rdsTZOffset: Double = 1.0
    var rdsEnableCT: Bool = true
    var rdsEnableID: Bool = true
    var rdsAutoStart: Bool = false
    var rdsGroupSequence: String = "0A 0A 2A 0A"
    var rdsSchedulerAuto: Bool = true
    var rdsSchedulerStandard: Bool = true
    var rdsSchedulerStandardLPS: Bool = true
    var rdsGaussianEnabled: Bool = true
    var rdsGaussianBWHZ: Double = 2400.0
    var rdsGaussianTaps: Int = 81

    static func load(fromINI path: String) throws -> AppConfig {
        let resolvedPath = resolveINIPath(path, forWrite: false)
        let parsed = try INIParser.parseFile(resolvedPath)

        let mpx = parsed["MPX"] ?? [:]
        let interfaces = parsed["INTERFACES"] ?? [:]
        let rds = parsed["RDS"] ?? [:]
        var cfg = AppConfig()

        cfg.sourceMode = interfaces.string(
            "source_mode",
            defaultValue: mpx.string("source_mode", defaultValue: cfg.sourceMode)
        )
        cfg.inputDeviceUID = interfaces.optionalString("input_device_uid")
        cfg.outputDeviceUID = interfaces.optionalString("output_device_uid")
        cfg.monitorDeviceUID = interfaces.optionalString("monitor_device_uid")
        cfg.inputDeviceName = interfaces.optionalString("input_device_name")
        cfg.outputDeviceName = interfaces.optionalString("output_device_name")
        cfg.monitorDeviceName = interfaces.optionalString("monitor_device_name")
        cfg.monitorEnabled = interfaces.bool("monitor_enabled", defaultValue: cfg.monitorEnabled)
        cfg.processedAudioOutput = interfaces.bool(
            "processed_audio_output", defaultValue: cfg.processedAudioOutput)
        cfg.processingBypass = mpx.bool("processing_bypass", defaultValue: cfg.processingBypass)
        cfg.testToneMode = mpx.string("test_tone_mode", defaultValue: cfg.testToneMode)
        cfg.testToneFreq = mpx.double("test_tone_freq", defaultValue: cfg.testToneFreq)
        cfg.testToneLevelDB = mpx.double(
            "test_tone_level_db", defaultValue: cfg.testToneLevelDB)
        cfg.testToneType = mpx.string("test_tone_type", defaultValue: cfg.testToneType)
        cfg.pilotLevel = mpx.double("pilot_level", defaultValue: cfg.pilotLevel)
        cfg.sumLevel = mpx.double("sum_level", defaultValue: cfg.sumLevel)
        cfg.diffLevel = mpx.double("diff_level", defaultValue: cfg.diffLevel)
        cfg.monoMode = mpx.bool("mono_mode", defaultValue: cfg.monoMode)
        cfg.inputGainDB = mpx.double("input_gain_db", defaultValue: cfg.inputGainDB)
        cfg.outputGainDB = mpx.double("output_gain_db", defaultValue: cfg.outputGainDB)
        cfg.finalDriveDB = mpx.double("final_drive_db", defaultValue: cfg.finalDriveDB)
        cfg.finalStagePresetID = mpx.string("final_stage_preset_id", defaultValue: cfg.finalStagePresetID)
        cfg.formatProfileID = mpx.string("format_profile_id", defaultValue: cfg.formatProfileID)
        cfg.preemphasisUS = mpx.int("preemphasis_us", defaultValue: cfg.preemphasisUS)
        cfg.hpfHz = mpx.double("hpf_hz", defaultValue: cfg.hpfHz)
        cfg.hfTrimDB = mpx.double("hf_trim_db", defaultValue: cfg.hfTrimDB)
        cfg.hfTrimHz = mpx.double("hf_trim_hz", defaultValue: cfg.hfTrimHz)
        cfg.programLowpassHz = mpx.double("program_lowpass_hz", defaultValue: cfg.programLowpassHz)
        cfg.limitMPX = mpx.bool("limit_mpx", defaultValue: cfg.limitMPX)
        cfg.limitThreshold = mpx.double("limit_threshold", defaultValue: cfg.limitThreshold)
        cfg.limitLookaheadMS = mpx.double("limit_lookahead_ms", defaultValue: cfg.limitLookaheadMS)
        cfg.limitLookaheadEnabled = mpx.bool(
            "limit_lookahead_enabled", defaultValue: cfg.limitLookaheadEnabled)
        cfg.preEncodeAudioLimiterEnabled = mpx.bool(
            "pre_encode_limiter_enabled", defaultValue: cfg.preEncodeAudioLimiterEnabled)
        cfg.preEncodeThreshold = mpx.double(
            "pre_encode_threshold", defaultValue: cfg.preEncodeThreshold)
        cfg.preEncodeReleaseMS = mpx.double(
            "pre_encode_release_ms", defaultValue: cfg.preEncodeReleaseMS)
        cfg.preEncodeBandlimitedResidualEnabled = mpx.bool(
            "pre_encode_bandlimited_residual_enabled",
            defaultValue: cfg.preEncodeBandlimitedResidualEnabled
        )
        cfg.preEncodeBandlimitedResidualTapCount = mpx.int(
            "pre_encode_bandlimited_residual_taps",
            defaultValue: cfg.preEncodeBandlimitedResidualTapCount
        )
        cfg.preEncodeBandlimitedResidualCutoffFraction = mpx.double(
            "pre_encode_bandlimited_residual_cutoff_fraction",
            defaultValue: cfg.preEncodeBandlimitedResidualCutoffFraction
        )
        cfg.preEncodeLookaheadMS = mpx.double(
            "pre_encode_lookahead_ms",
            defaultValue: cfg.preEncodeLookaheadMS
        )
        cfg.preEncodeLookaheadHFOnly = mpx.bool(
            "pre_encode_lookahead_hf_only",
            defaultValue: cfg.preEncodeLookaheadHFOnly
        )
        cfg.preEncodeLookaheadHFCutoffHz = mpx.double(
            "pre_encode_lookahead_hf_cutoff_hz",
            defaultValue: cfg.preEncodeLookaheadHFCutoffHz
        )
        cfg.encoderFIREnabled = mpx.bool(
            "encoder_fir_enabled", defaultValue: cfg.encoderFIREnabled)
        cfg.multibandFIREnabled = mpx.bool(
            "multiband_fir_enabled", defaultValue: cfg.multibandFIREnabled)
        cfg.audioCompositeSoftClipEnabled = mpx.bool(
            "audio_composite_softclip_enabled",
            defaultValue: cfg.audioCompositeSoftClipEnabled
        )
        cfg.audioCompositeSmootherEnabled = mpx.bool(
            "audio_composite_smoother_enabled",
            defaultValue: cfg.audioCompositeSmootherEnabled
        )
        cfg.finalMPXSoftClipEnabled = mpx.bool(
            "final_mpx_softclip_enabled",
            defaultValue: cfg.finalMPXSoftClipEnabled
        )
        cfg.mpxDeviationKHz = mpx.double("mpx_deviation_khz", defaultValue: cfg.mpxDeviationKHz)
        cfg.enRDS = mpx.bool("en_rds", defaultValue: rds.bool("en_rds", defaultValue: cfg.enRDS))
        cfg.widebandAGCEnabled = mpx.bool(
            "wideband_agc_enabled", defaultValue: cfg.widebandAGCEnabled)
        cfg.widebandAGCTargetDB = mpx.double(
            "wideband_agc_target_db", defaultValue: cfg.widebandAGCTargetDB)
        cfg.widebandAGCAttackMS = mpx.double(
            "wideband_agc_attack_ms", defaultValue: cfg.widebandAGCAttackMS)
        cfg.widebandAGCReleaseMS = mpx.double(
            "wideband_agc_release_ms", defaultValue: cfg.widebandAGCReleaseMS)
        cfg.widebandAGCKWeightingEnabled = mpx.bool(
            "wideband_agc_k_weighting", defaultValue: cfg.widebandAGCKWeightingEnabled)
        cfg.widebandAGCReleaseProgramDependent = mpx.bool(
            "wideband_agc_release_program_dependent",
            defaultValue: cfg.widebandAGCReleaseProgramDependent)
        cfg.widebandAGCBassDesensitizeEnabled = mpx.bool(
            "wideband_agc_bass_desensitize",
            defaultValue: cfg.widebandAGCBassDesensitizeEnabled)
        cfg.widebandAGCMaxGainDB = mpx.double(
            "wideband_agc_max_gain_db", defaultValue: cfg.widebandAGCMaxGainDB)
        cfg.widebandAGCMinGainDB = mpx.double(
            "wideband_agc_min_gain_db", defaultValue: cfg.widebandAGCMinGainDB)
        // PrimeBass keys (formerly `orbass_*` — renamed in 0.20 to remove
        // the Orban-trademark adjacency). The legacy `orbass_*` keys are
        // still read first as a fallback so existing user INIs keep
        // working; they will be removed in a future release.
        cfg.primeBassEnabled = mpx.bool(
            "primebass_enabled",
            defaultValue: mpx.bool("orbass_enabled", defaultValue: cfg.primeBassEnabled))
        cfg.primeBassPresetID = mpx.string(
            "primebass_preset_id",
            defaultValue: mpx.string("orbass_preset_id", defaultValue: cfg.primeBassPresetID))
        cfg.primeBassAmount = mpx.double(
            "primebass_amount",
            defaultValue: mpx.double("orbass_amount", defaultValue: cfg.primeBassAmount))
        cfg.primeBassFreqHz = mpx.double(
            "primebass_freq_hz",
            defaultValue: mpx.double("orbass_freq_hz", defaultValue: cfg.primeBassFreqHz))
        cfg.primeBassHarmonics = mpx.double(
            "primebass_harmonics",
            defaultValue: mpx.double("orbass_harmonics", defaultValue: cfg.primeBassHarmonics))
        cfg.primeBassDrive = mpx.double(
            "primebass_drive",
            defaultValue: mpx.double("orbass_drive", defaultValue: cfg.primeBassDrive))
        cfg.primeBassDensity = mpx.double(
            "primebass_density",
            defaultValue: mpx.double("orbass_density", defaultValue: cfg.primeBassDensity))
        cfg.primeBassSubharmonicsEnabled = mpx.bool(
            "primebass_subharmonics_enabled",
            defaultValue: mpx.bool(
                "orbass_subharmonics_enabled",
                defaultValue: cfg.primeBassSubharmonicsEnabled))
        cfg.primeBassSubharmonicsAmount = mpx.double(
            "primebass_subharmonics_amount",
            defaultValue: mpx.double(
                "orbass_subharmonics_amount",
                defaultValue: cfg.primeBassSubharmonicsAmount))
        cfg.stereoWidenEnabled = mpx.bool(
            "stereo_widen_enabled", defaultValue: cfg.stereoWidenEnabled)
        cfg.monoBassEnabled = mpx.bool("mono_bass_enabled", defaultValue: cfg.monoBassEnabled)
        cfg.monoBassFreqHz = mpx.double("mono_bass_freq_hz", defaultValue: cfg.monoBassFreqHz)
        cfg.stereoWidenWidth = mpx.double("stereo_widen_width", defaultValue: cfg.stereoWidenWidth)
        cfg.stereoWidenCenter = mpx.double(
            "stereo_widen_center", defaultValue: cfg.stereoWidenCenter)
        cfg.stereoWidenMix = mpx.double("stereo_widen_mix", defaultValue: cfg.stereoWidenMix)
        cfg.multibandEnabled = mpx.bool("multiband_enabled", defaultValue: cfg.multibandEnabled)
        cfg.multibandMode = mpx.int("multiband_mode", defaultValue: cfg.multibandMode)
        cfg.multibandPresetID = mpx.string("multiband_preset_id", defaultValue: cfg.multibandPresetID)
        cfg.multibandIntensity = mpx.string("multiband_intensity", defaultValue: cfg.multibandIntensity)
        cfg.multibandLowHz = mpx.double("multiband_low_hz", defaultValue: cfg.multibandLowHz)
        cfg.multibandHighHz = mpx.double("multiband_high_hz", defaultValue: cfg.multibandHighHz)
        cfg.multibandX1Hz = mpx.double("multiband_x1_hz", defaultValue: cfg.multibandX1Hz)
        cfg.multibandX2Hz = mpx.double("multiband_x2_hz", defaultValue: cfg.multibandX2Hz)
        cfg.multibandX3Hz = mpx.double("multiband_x3_hz", defaultValue: cfg.multibandX3Hz)
        cfg.multibandX4Hz = mpx.double("multiband_x4_hz", defaultValue: cfg.multibandX4Hz)
        cfg.multibandLowThresholdDB = mpx.double(
            "multiband_low_threshold_db", defaultValue: cfg.multibandLowThresholdDB)
        cfg.multibandMidThresholdDB = mpx.double(
            "multiband_mid_threshold_db", defaultValue: cfg.multibandMidThresholdDB)
        cfg.multibandHighThresholdDB = mpx.double(
            "multiband_high_threshold_db", defaultValue: cfg.multibandHighThresholdDB)
        cfg.multibandLowRatio = mpx.double(
            "multiband_low_ratio", defaultValue: cfg.multibandLowRatio)
        cfg.multibandMidRatio = mpx.double(
            "multiband_mid_ratio", defaultValue: cfg.multibandMidRatio)
        cfg.multibandHighRatio = mpx.double(
            "multiband_high_ratio", defaultValue: cfg.multibandHighRatio)
        cfg.multibandLowAttackMS = mpx.double(
            "multiband_low_attack_ms", defaultValue: cfg.multibandLowAttackMS)
        cfg.multibandMidAttackMS = mpx.double(
            "multiband_mid_attack_ms", defaultValue: cfg.multibandMidAttackMS)
        cfg.multibandHighAttackMS = mpx.double(
            "multiband_high_attack_ms", defaultValue: cfg.multibandHighAttackMS)
        cfg.multibandLowReleaseMS = mpx.double(
            "multiband_low_release_ms", defaultValue: cfg.multibandLowReleaseMS)
        cfg.multibandMidReleaseMS = mpx.double(
            "multiband_mid_release_ms", defaultValue: cfg.multibandMidReleaseMS)
        cfg.multibandHighReleaseMS = mpx.double(
            "multiband_high_release_ms", defaultValue: cfg.multibandHighReleaseMS)
        cfg.multibandKneeDB = mpx.double("multiband_knee_db", defaultValue: cfg.multibandKneeDB)
        cfg.multibandLinkStrength = mpx.double(
            "multiband_link_strength", defaultValue: cfg.multibandLinkStrength)
        cfg.multibandReleaseProgramDependent = mpx.bool(
            "multiband_release_program_dependent",
            defaultValue: cfg.multibandReleaseProgramDependent
        )
        cfg.multibandTransientAwareAttackEnabled = mpx.bool(
            "multiband_transient_aware_attack_enabled",
            defaultValue: cfg.multibandTransientAwareAttackEnabled
        )
        cfg.multibandInterBandCouplingEnabled = mpx.bool(
            "multiband_inter_band_coupling_enabled",
            defaultValue: cfg.multibandInterBandCouplingEnabled
        )
        cfg.multibandMakeupDB = mpx.double(
            "multiband_makeup_db", defaultValue: cfg.multibandMakeupDB)
        cfg.phaseRotationEnabled = mpx.bool(
            "phase_rotation_enabled", defaultValue: cfg.phaseRotationEnabled)
        cfg.phaseRotationFreqHz = mpx.double(
            "phase_rotation_freq_hz", defaultValue: cfg.phaseRotationFreqHz)
        cfg.parametricEQEnabled = mpx.bool(
            "parametric_eq_enabled", defaultValue: cfg.parametricEQEnabled)
        cfg.peqB1FreqHz = mpx.double("peq_b1_freq_hz", defaultValue: cfg.peqB1FreqHz)
        cfg.peqB1GainDB = mpx.double("peq_b1_gain_db", defaultValue: cfg.peqB1GainDB)
        cfg.peqB2FreqHz = mpx.double("peq_b2_freq_hz", defaultValue: cfg.peqB2FreqHz)
        cfg.peqB2GainDB = mpx.double("peq_b2_gain_db", defaultValue: cfg.peqB2GainDB)
        cfg.peqB2Q = mpx.double("peq_b2_q", defaultValue: cfg.peqB2Q)
        cfg.peqB3FreqHz = mpx.double("peq_b3_freq_hz", defaultValue: cfg.peqB3FreqHz)
        cfg.peqB3GainDB = mpx.double("peq_b3_gain_db", defaultValue: cfg.peqB3GainDB)
        cfg.peqB3Q = mpx.double("peq_b3_q", defaultValue: cfg.peqB3Q)
        cfg.peqB4FreqHz = mpx.double("peq_b4_freq_hz", defaultValue: cfg.peqB4FreqHz)
        cfg.peqB4GainDB = mpx.double("peq_b4_gain_db", defaultValue: cfg.peqB4GainDB)
        cfg.multibandLimiterEnabled = mpx.bool(
            "multiband_limiter_enabled", defaultValue: cfg.multibandLimiterEnabled)
        cfg.multibandLimiterThresholdDB = mpx.double(
            "multiband_limiter_threshold_db", defaultValue: cfg.multibandLimiterThresholdDB)
        cfg.multibandLimiterAttackMS = mpx.double(
            "multiband_limiter_attack_ms", defaultValue: cfg.multibandLimiterAttackMS)
        cfg.multibandLimiterReleaseMS = mpx.double(
            "multiband_limiter_release_ms", defaultValue: cfg.multibandLimiterReleaseMS)
        cfg.downwardExpanderEnabled = mpx.bool(
            "downward_expander_enabled", defaultValue: cfg.downwardExpanderEnabled)
        cfg.expanderThresholdDB = mpx.double(
            "expander_threshold_db", defaultValue: cfg.expanderThresholdDB)
        cfg.expanderRatio = mpx.double("expander_ratio", defaultValue: cfg.expanderRatio)
        cfg.expanderAttackMS = mpx.double("expander_attack_ms", defaultValue: cfg.expanderAttackMS)
        cfg.expanderReleaseMS = mpx.double("expander_release_ms", defaultValue: cfg.expanderReleaseMS)
        cfg.bassClipperEnabled = mpx.bool(
            "bass_clipper_enabled", defaultValue: cfg.bassClipperEnabled)
        cfg.bassClipperCrossoverHz = mpx.double(
            "bass_clipper_crossover_hz", defaultValue: cfg.bassClipperCrossoverHz)
        cfg.bassClipperThresholdDB = mpx.double(
            "bass_clipper_threshold_db", defaultValue: cfg.bassClipperThresholdDB)
        cfg.bassClipperDrive = mpx.double(
            "bass_clipper_drive", defaultValue: cfg.bassClipperDrive)
        cfg.hfClipperEnabled = mpx.bool(
            "hf_clipper_enabled", defaultValue: cfg.hfClipperEnabled)
        cfg.hfClipperCrossoverHz = mpx.double(
            "hf_clipper_crossover_hz", defaultValue: cfg.hfClipperCrossoverHz)
        cfg.hfClipperThresholdDB = mpx.double(
            "hf_clipper_threshold_db", defaultValue: cfg.hfClipperThresholdDB)
        cfg.hfClipperDrive = mpx.double(
            "hf_clipper_drive", defaultValue: cfg.hfClipperDrive)
        cfg.dcClipperEnabled = mpx.bool(
            "dc_clipper_enabled", defaultValue: cfg.dcClipperEnabled)
        cfg.dcClipperCeilingDB = mpx.double(
            "dc_clipper_ceiling_db", defaultValue: cfg.dcClipperCeilingDB)
        cfg.dcClipperCancelFreqHz = mpx.double(
            "dc_clipper_cancel_freq_hz", defaultValue: cfg.dcClipperCancelFreqHz)
        cfg.processedAudioCoderHasClipper = mpx.bool(
            "processed_audio_coder_has_clipper", defaultValue: cfg.processedAudioCoderHasClipper)
        cfg.processedAudioFinalClipDriveDB = mpx.double(
            "processed_audio_final_clip_drive_db", defaultValue: cfg.processedAudioFinalClipDriveDB)
        cfg.bs412Enabled = mpx.bool("bs412_enabled", defaultValue: cfg.bs412Enabled)
        cfg.bs412ThresholdDB = mpx.double(
            "bs412_threshold_db", defaultValue: cfg.bs412ThresholdDB)
        cfg.bs412WindowSeconds = mpx.double(
            "bs412_window_seconds", defaultValue: cfg.bs412WindowSeconds)
        cfg.compositeClipperEnabled = mpx.bool(
            "mpx_clipper_enabled", defaultValue: cfg.compositeClipperEnabled)
        cfg.compositeClipperThresholdDB = mpx.double(
            "mpx_clipper_threshold_db", defaultValue: cfg.compositeClipperThresholdDB)
        cfg.compositeClipperCeilingDB = mpx.double(
            "mpx_clipper_ceiling_db", defaultValue: cfg.compositeClipperCeilingDB)
        cfg.compositeClipperCancelAudio = mpx.bool(
            "mpx_clipper_cancel_audio", defaultValue: cfg.compositeClipperCancelAudio)
        cfg.compositeClipperCancelStereo = mpx.bool(
            "mpx_clipper_cancel_stereo", defaultValue: cfg.compositeClipperCancelStereo)
        cfg.compositeClipperCancelPilot = mpx.bool(
            "mpx_clipper_cancel_pilot", defaultValue: cfg.compositeClipperCancelPilot)
        cfg.compositeClipperCancelRDS = mpx.bool(
            "mpx_clipper_cancel_rds", defaultValue: cfg.compositeClipperCancelRDS)
        cfg.compositeClipperLookaheadMS = mpx.double(
            "mpx_clipper_lookahead_ms", defaultValue: cfg.compositeClipperLookaheadMS)
        cfg.compositeClipperOversampling = mpx.int(
            "mpx_clipper_oversampling", defaultValue: cfg.compositeClipperOversampling)
        cfg.compositeMultibandClipperEnabled = mpx.bool(
            "mpx_multiband_clipper_enabled",
            defaultValue: cfg.compositeMultibandClipperEnabled
        )
        cfg.rdsLevel = rds.double("rds_level", defaultValue: cfg.rdsLevel)
        cfg.rdsPI = rds.string("pi", defaultValue: cfg.rdsPI)
        cfg.rdsPTY = rds.int("pty", defaultValue: cfg.rdsPTY)
        cfg.rdsPtyRBDS = rds.bool("pty_rbds", defaultValue: cfg.rdsPtyRBDS)
        cfg.rdsTP = rds.bool("tp", defaultValue: cfg.rdsTP)
        cfg.rdsTA = rds.bool("ta", defaultValue: cfg.rdsTA)
        cfg.rdsMS = rds.bool("ms", defaultValue: cfg.rdsMS)
        cfg.rdsDI_STEREO = rds.bool("di_stereo", defaultValue: cfg.rdsDI_STEREO)
        cfg.rdsDI_HEAD = rds.bool("di_head", defaultValue: cfg.rdsDI_HEAD)
        cfg.rdsDI_COMP = rds.bool("di_comp", defaultValue: cfg.rdsDI_COMP)
        cfg.rdsDI_DYN = rds.bool("di_dyn", defaultValue: cfg.rdsDI_DYN)
        cfg.rdsEnableAF = rds.bool("en_af", defaultValue: cfg.rdsEnableAF)
        cfg.rdsAFList = rds.string("af_list", defaultValue: cfg.rdsAFList)
        cfg.rdsAFMethod = rds.string("af_method", defaultValue: cfg.rdsAFMethod)
        // PS banks: new keys win; `ps_dynamic` migrates into bank A if the
        // new key is absent (preserves upgrades from pre-0.10 installs).
        let legacyPSDynamic = rds.string("ps_dynamic", defaultValue: "")
        cfg.rdsPSA = rds.string("ps_a", defaultValue: legacyPSDynamic.isEmpty ? cfg.rdsPSA : legacyPSDynamic)
        cfg.rdsPSB = rds.string("ps_b", defaultValue: cfg.rdsPSB)
        cfg.rdsPSC = rds.string("ps_c", defaultValue: cfg.rdsPSC)
        cfg.rdsPSD = rds.string("ps_d", defaultValue: cfg.rdsPSD)
        cfg.rdsPSActiveBank = rds.string("ps_active_bank", defaultValue: cfg.rdsPSActiveBank)
        cfg.rdsPSCentered = rds.bool("ps_centered", defaultValue: cfg.rdsPSCentered)
        cfg.rdsPSFrameSeconds = rds.double("ps_frame_seconds", defaultValue: cfg.rdsPSFrameSeconds)
        cfg.rdsRTText = rds.string("rt_text", defaultValue: cfg.rdsRTText)
        cfg.rdsRTManualBuffers = rds.bool("rt_manual_buffers", defaultValue: cfg.rdsRTManualBuffers)
        cfg.rdsRTCycleAB = rds.bool("rt_cycle_ab", defaultValue: cfg.rdsRTCycleAB)
        cfg.rdsRTA = rds.string("rt_a", defaultValue: cfg.rdsRTA)
        cfg.rdsRTB = rds.string("rt_b", defaultValue: cfg.rdsRTB)
        cfg.rdsRTC = rds.string("rt_c", defaultValue: cfg.rdsRTC)
        cfg.rdsRTD = rds.string("rt_d", defaultValue: cfg.rdsRTD)
        cfg.rdsRTBufferAEnabled = rds.bool("rt_a_enabled", defaultValue: cfg.rdsRTBufferAEnabled)
        cfg.rdsRTBufferBEnabled = rds.bool("rt_b_enabled", defaultValue: cfg.rdsRTBufferBEnabled)
        cfg.rdsRTBufferCEnabled = rds.bool("rt_c_enabled", defaultValue: cfg.rdsRTBufferCEnabled)
        cfg.rdsRTBufferDEnabled = rds.bool("rt_d_enabled", defaultValue: cfg.rdsRTBufferDEnabled)
        cfg.rdsRTCR = rds.bool("rt_cr", defaultValue: cfg.rdsRTCR)
        cfg.rdsRTCentered = rds.bool("rt_centered", defaultValue: cfg.rdsRTCentered)
        cfg.rdsRTMode = rds.string("rt_mode", defaultValue: cfg.rdsRTMode)
        cfg.rdsRTCycle = rds.bool("rt_cycle", defaultValue: cfg.rdsRTCycle)
        cfg.rdsRTCycleTime = rds.double("rt_cycle_time", defaultValue: cfg.rdsRTCycleTime)
        cfg.rdsRTActiveBuffer = rds.int("rt_active_buffer", defaultValue: cfg.rdsRTActiveBuffer)
        cfg.rdsRTABCycleCount = rds.int("rt_ab_cycle_count", defaultValue: cfg.rdsRTABCycleCount)
        cfg.rdsPTYN = rds.string("ptyn", defaultValue: cfg.rdsPTYN)
        cfg.rdsEnablePTYN = rds.bool("en_ptyn", defaultValue: cfg.rdsEnablePTYN)
        cfg.rdsPTYNCentered = rds.bool("ptyn_centered", defaultValue: cfg.rdsPTYNCentered)
        cfg.rdsLongPS32 = rds.string("ps_long_32", defaultValue: cfg.rdsLongPS32)
        cfg.rdsEnableLPS = rds.bool("en_lps", defaultValue: cfg.rdsEnableLPS)
        cfg.rdsLPSCentered = rds.bool("lps_centered", defaultValue: cfg.rdsLPSCentered)
        cfg.rdsLPSCR = rds.bool("lps_cr", defaultValue: cfg.rdsLPSCR)
        cfg.rdsEnableRTPlus = rds.bool("en_rt_plus", defaultValue: cfg.rdsEnableRTPlus)
        cfg.rdsRTPlusFormatA = rds.string("rt_plus_format_a", defaultValue: cfg.rdsRTPlusFormatA)
        cfg.rdsRTPlusFormatB = rds.string("rt_plus_format_b", defaultValue: cfg.rdsRTPlusFormatB)
        cfg.rdsNowPlayingEnabled = rds.bool(
            "now_playing_enabled", defaultValue: cfg.rdsNowPlayingEnabled)
        cfg.rdsNowPlayingScript = rds.string(
            "now_playing_script", defaultValue: cfg.rdsNowPlayingScript)
        cfg.rdsNowPlayingPollSeconds = rds.double(
            "now_playing_poll_seconds", defaultValue: cfg.rdsNowPlayingPollSeconds)
        cfg.rdsNowPlayingTimeoutSeconds = rds.double(
            "now_playing_timeout_seconds", defaultValue: cfg.rdsNowPlayingTimeoutSeconds)
        cfg.rdsECC = rds.string("ecc", defaultValue: cfg.rdsECC)
        cfg.rdsLIC = rds.string("lic", defaultValue: cfg.rdsLIC)
        cfg.rdsEnablePIN = rds.bool("pin_enabled", defaultValue: cfg.rdsEnablePIN)
        cfg.rdsPINDay = rds.int("pin_day", defaultValue: cfg.rdsPINDay)
        cfg.rdsPINHour = rds.int("pin_hour", defaultValue: cfg.rdsPINHour)
        cfg.rdsPINMinute = rds.int("pin_minute", defaultValue: cfg.rdsPINMinute)
        cfg.rdsTZOffset = rds.double("tz_offset", defaultValue: cfg.rdsTZOffset)
        cfg.rdsEnableCT = rds.bool("en_ct", defaultValue: cfg.rdsEnableCT)
        cfg.rdsEnableID = rds.bool("en_id", defaultValue: cfg.rdsEnableID)
        cfg.rdsAutoStart = rds.bool("auto_start", defaultValue: cfg.rdsAutoStart)
        cfg.rdsGroupSequence = rds.string("group_sequence", defaultValue: cfg.rdsGroupSequence)
        cfg.rdsSchedulerAuto = rds.bool("scheduler_auto", defaultValue: cfg.rdsSchedulerAuto)
        cfg.rdsSchedulerStandard = rds.bool(
            "scheduler_standard", defaultValue: cfg.rdsSchedulerStandard)
        cfg.rdsSchedulerStandardLPS = rds.bool(
            "scheduler_standard_lps", defaultValue: cfg.rdsSchedulerStandardLPS)
        cfg.rdsGaussianEnabled = rds.bool(
            "rds_gaussian_enabled", defaultValue: cfg.rdsGaussianEnabled)
        cfg.rdsGaussianBWHZ = rds.double("rds_gaussian_bw_hz", defaultValue: cfg.rdsGaussianBWHZ)
        cfg.rdsGaussianTaps = rds.int("rds_gaussian_taps", defaultValue: cfg.rdsGaussianTaps)
        cfg.sampleRate = interfaces.double("sample_rate", defaultValue: cfg.sampleRate)
        cfg.blockSize = interfaces.int("blocksize", defaultValue: cfg.blockSize)
        cfg.fftWindow96kHz = interfaces.bool("fft_window_92khz", defaultValue: cfg.fftWindow96kHz)
        cfg.dualRateAudioDomainEnabled = interfaces.bool(
            "dual_rate_audio_domain_enabled",
            defaultValue: cfg.dualRateAudioDomainEnabled
        )
        cfg.dualRateAudioDomainRateHz = interfaces.double(
            "dual_rate_audio_domain_rate_hz",
            defaultValue: cfg.dualRateAudioDomainRateHz
        )
        cfg.validate()
        return cfg
    }

    mutating func validate() {
        // Gain parameters — powf(10, x/20) overflows Float beyond ~±680 dB;
        // sane broadcast range is much smaller.
        inputGainDB = max(-40.0, min(40.0, inputGainDB))
        outputGainDB = max(-40.0, min(40.0, outputGainDB))
        finalDriveDB = max(-20.0, min(20.0, finalDriveDB))

        // Pilot / sum / diff levels
        pilotLevel = max(0.0, min(0.12, pilotLevel))
        sumLevel = max(0.0, min(2.0, sumLevel))
        diffLevel = max(0.0, min(2.0, diffLevel))

        // Test tone
        testToneFreq = max(20.0, min(20_000.0, testToneFreq))
        testToneLevelDB = max(-60.0, min(0.0, testToneLevelDB))
        // Validate type against the supported set; fall back to sine.
        if !["sine", "pink", "white"].contains(testToneType.lowercased()) {
            testToneType = "sine"
        }
        // Validate stereo mode against the supported set; fall back to mono.
        if !["mono", "stereo", "left", "right"].contains(testToneMode.lowercased()) {
            testToneMode = "mono"
        }
        // sourceMode lives outside this block (interfaces section); both
        // "input" and "tone" are valid. The Test Tone tab toggles
        // between them via live-apply.

        // Filter frequencies
        hpfHz = max(10.0, min(200.0, hpfHz))
        hfTrimDB = max(-12.0, min(0.0, hfTrimDB))
        hfTrimHz = max(500.0, min(12_000.0, hfTrimHz))
        programLowpassHz = max(8_000.0, min(16_000.0, programLowpassHz))

        // Limiter
        limitThreshold = max(0.5, min(0.999, limitThreshold))
        limitLookaheadMS = max(0.0, min(20.0, limitLookaheadMS))
        preEncodeThreshold = max(0.5, min(0.999, preEncodeThreshold))
        preEncodeReleaseMS = max(10.0, min(200.0, preEncodeReleaseMS))
        preEncodeBandlimitedResidualTapCount = max(5, min(129, preEncodeBandlimitedResidualTapCount | 1))
        preEncodeBandlimitedResidualCutoffFraction = max(0.05, min(0.49, preEncodeBandlimitedResidualCutoffFraction))
        preEncodeLookaheadMS = max(0.0, min(5.0, preEncodeLookaheadMS))
        preEncodeLookaheadHFCutoffHz = max(1_000.0, min(12_000.0, preEncodeLookaheadHFCutoffHz))

        // MPX deviation
        mpxDeviationKHz = max(25.0, min(100.0, mpxDeviationKHz))

        // Pre-emphasis — ITU-R BS.450-4 (50 us EU/ITU) and FCC 73.317
        // (75 us US/Japan) are the only FM broadcast values; 0 disables
        // pre-emphasis for already-flat program lines.
        if ![0, 50, 75].contains(preemphasisUS) {
            preemphasisUS = 50
        }

        // Wideband AGC
        widebandAGCTargetDB = max(-40.0, min(0.0, widebandAGCTargetDB))
        widebandAGCAttackMS = max(1.0, min(5_000.0, widebandAGCAttackMS))
        widebandAGCReleaseMS = max(10.0, min(10_000.0, widebandAGCReleaseMS))
        widebandAGCMaxGainDB = max(0.0, min(30.0, widebandAGCMaxGainDB))
        widebandAGCMinGainDB = max(-30.0, min(0.0, widebandAGCMinGainDB))
        if widebandAGCMaxGainDB < widebandAGCMinGainDB {
            widebandAGCMaxGainDB = 12.0
            widebandAGCMinGainDB = -12.0
        }

        // PrimeBass
        primeBassAmount = max(0.0, min(1.0, primeBassAmount))
        primeBassFreqHz = max(45.0, min(220.0, primeBassFreqHz))
        primeBassHarmonics = max(0.0, min(1.0, primeBassHarmonics))
        primeBassDrive = max(0.0, min(2.5, primeBassDrive))
        primeBassDensity = max(0.0, min(1.0, primeBassDensity))
        primeBassSubharmonicsAmount = max(0.0, min(1.0, primeBassSubharmonicsAmount))

        // Stereo widener
        stereoWidenWidth = max(0.0, min(1.0, stereoWidenWidth))
        stereoWidenCenter = max(0.0, min(1.0, stereoWidenCenter))
        stereoWidenMix = max(0.0, min(1.0, stereoWidenMix))
        monoBassFreqHz = max(60.0, min(250.0, monoBassFreqHz))

        // Multiband
        multibandMode = (multibandMode == 5) ? 5 : 3
        multibandX1Hz = max(40.0, min(300.0, multibandX1Hz))
        multibandX2Hz = max(100.0, min(1_000.0, multibandX2Hz))
        multibandX3Hz = max(500.0, min(5_000.0, multibandX3Hz))
        multibandX4Hz = max(2_000.0, min(16_000.0, multibandX4Hz))
        multibandLowHz = max(80.0, min(1_000.0, multibandLowHz))
        multibandHighHz = max(500.0, min(8_000.0, multibandHighHz))
        multibandLowThresholdDB = max(-40.0, min(0.0, multibandLowThresholdDB))
        multibandMidThresholdDB = max(-40.0, min(0.0, multibandMidThresholdDB))
        multibandHighThresholdDB = max(-40.0, min(0.0, multibandHighThresholdDB))
        multibandLowRatio = max(1.0, min(20.0, multibandLowRatio))
        multibandMidRatio = max(1.0, min(20.0, multibandMidRatio))
        multibandHighRatio = max(1.0, min(20.0, multibandHighRatio))
        multibandLowAttackMS = max(0.1, min(200.0, multibandLowAttackMS))
        multibandMidAttackMS = max(0.1, min(200.0, multibandMidAttackMS))
        multibandHighAttackMS = max(0.1, min(200.0, multibandHighAttackMS))
        multibandLowReleaseMS = max(10.0, min(2_000.0, multibandLowReleaseMS))
        multibandMidReleaseMS = max(10.0, min(2_000.0, multibandMidReleaseMS))
        multibandHighReleaseMS = max(10.0, min(2_000.0, multibandHighReleaseMS))
        multibandKneeDB = max(0.0, min(12.0, multibandKneeDB))
        multibandLinkStrength = max(0.0, min(1.0, multibandLinkStrength))
        multibandMakeupDB = max(-12.0, min(12.0, multibandMakeupDB))

        // Phase rotator
        phaseRotationFreqHz = max(50.0, min(500.0, phaseRotationFreqHz))

        // Parametric EQ
        peqB1FreqHz = max(20.0, min(500.0, peqB1FreqHz))
        peqB1GainDB = max(-12.0, min(12.0, peqB1GainDB))
        peqB2FreqHz = max(100.0, min(5000.0, peqB2FreqHz))
        peqB2GainDB = max(-12.0, min(12.0, peqB2GainDB))
        peqB2Q = max(0.1, min(10.0, peqB2Q))
        peqB3FreqHz = max(500.0, min(12000.0, peqB3FreqHz))
        peqB3GainDB = max(-12.0, min(12.0, peqB3GainDB))
        peqB3Q = max(0.1, min(10.0, peqB3Q))
        peqB4FreqHz = max(1000.0, min(16000.0, peqB4FreqHz))
        peqB4GainDB = max(-12.0, min(12.0, peqB4GainDB))

        // Multiband limiter
        multibandLimiterThresholdDB = max(-20.0, min(0.0, multibandLimiterThresholdDB))
        multibandLimiterAttackMS = max(0.01, min(10.0, multibandLimiterAttackMS))
        multibandLimiterReleaseMS = max(10.0, min(500.0, multibandLimiterReleaseMS))

        // Downward expander
        expanderThresholdDB = max(-60.0, min(-20.0, expanderThresholdDB))
        expanderRatio = max(1.0, min(8.0, expanderRatio))
        expanderAttackMS = max(0.1, min(100.0, expanderAttackMS))
        expanderReleaseMS = max(10.0, min(2000.0, expanderReleaseMS))

        // Bass clipper
        bassClipperCrossoverHz = max(60.0, min(300.0, bassClipperCrossoverHz))
        bassClipperThresholdDB = max(-12.0, min(0.0, bassClipperThresholdDB))
        bassClipperDrive = max(0.5, min(3.0, bassClipperDrive))
        hfClipperCrossoverHz = max(3_000.0, min(8_000.0, hfClipperCrossoverHz))
        hfClipperThresholdDB = max(-12.0, min(0.0, hfClipperThresholdDB))
        hfClipperDrive = max(0.5, min(3.0, hfClipperDrive))

        // Distortion-cancelled clipper
        dcClipperCeilingDB = max(-6.0, min(0.0, dcClipperCeilingDB))
        dcClipperCancelFreqHz = max(500.0, min(4000.0, dcClipperCancelFreqHz))
        processedAudioFinalClipDriveDB = max(0.0, min(12.0, processedAudioFinalClipDriveDB))

        // BS.412
        bs412ThresholdDB = max(-20.0, min(0.0, bs412ThresholdDB))
        // ITU-R BS.412-9 canonical rolling-average window is ~60 s.
        // Allow ±30 s of regulator latitude; anything outside this range
        // stops being BS.412 and becomes a generic fast AGC.
        bs412WindowSeconds = max(30.0, min(90.0, bs412WindowSeconds))
        compositeClipperThresholdDB = max(-12.0, min(0.0, compositeClipperThresholdDB))
        compositeClipperCeilingDB = max(-6.0, min(0.0, compositeClipperCeilingDB))
        if compositeClipperCeilingDB <= compositeClipperThresholdDB + 0.2 {
            compositeClipperCeilingDB = min(0.0, compositeClipperThresholdDB + 0.5)
        }
        compositeClipperLookaheadMS = max(0.0, min(5.0, compositeClipperLookaheadMS))
        // Clamp oversampling to the supported set {8, 16, 32}. Snap to
        // the nearest supported value rather than rejecting — INI typos
        // or experimental values shouldn't break engine start.
        switch compositeClipperOversampling {
        case ...12: compositeClipperOversampling = 8
        case 13...23: compositeClipperOversampling = 16
        default: compositeClipperOversampling = 32
        }

        // Engine
        sampleRate = max(44_100.0, min(384_000.0, sampleRate))
        // Dual-rate audio domain rate. Clamp to the common audio rates;
        // 48 kHz is the default and most likely operator choice. The
        // engine-rate vs audio-rate ratio integer-check happens at engine
        // configure time, not here — sanitize() doesn't have that context.
        dualRateAudioDomainRateHz = max(32_000.0, min(96_000.0, dualRateAudioDomainRateHz))
        // 512-sample minimum: throughput-validated by `DSPThroughputTests`.
        // Lower than 512 hits AVAudioEngine HAL limits on most macOS devices
        // and pushes per-callback overhead past the per-sample DSP work.
        blockSize = max(512, min(8192, blockSize))

        // RDS
        rdsPI = Self.sanitizedPICode(rdsPI)
        rdsPTY = max(0, min(31, rdsPTY))
        let upperBank = rdsPSActiveBank.uppercased()
        rdsPSActiveBank = ["A", "B", "C", "D"].contains(upperBank) ? upperBank : "A"
        rdsRTMode = (rdsRTMode.uppercased() == "2B") ? "2B" : "2A"
        rdsRTCycleTime = max(1.0, min(60.0, rdsRTCycleTime))
        rdsRTActiveBuffer = max(0, min(3, rdsRTActiveBuffer))
        rdsRTABCycleCount = max(1, min(99, rdsRTABCycleCount))
        rdsECC = Self.sanitizedHexByte(rdsECC)
        rdsLIC = Self.sanitizedHexByte(rdsLIC)
        rdsPINDay = min(31, max(1, rdsPINDay))
        rdsPINHour = min(23, max(0, rdsPINHour))
        rdsPINMinute = min(59, max(0, rdsPINMinute))
        rdsTZOffset = max(-12.0, min(14.0, rdsTZOffset))
        rdsLevel = max(0.0, min(7.5, rdsLevel))
        rdsGaussianBWHZ = max(600.0, min(6_000.0, rdsGaussianBWHZ))
        rdsGaussianTaps = max(9, min(401, rdsGaussianTaps | 1))
        rdsNowPlayingPollSeconds = max(1.0, min(300.0, rdsNowPlayingPollSeconds))
        rdsNowPlayingTimeoutSeconds = max(0.2, min(30.0, rdsNowPlayingTimeoutSeconds))
    }

    static func resolvedINIPath(_ path: String, forWrite: Bool = false) -> String {
        resolveINIPath(path, forWrite: forWrite)
    }

    /// Returns the canonical INI representation as a string without
    /// touching the filesystem. Used by the snapshot system (Snapshots
    /// embed configs as INI text inside their JSON envelope so schema
    /// migrations stay handled by the existing INI parser's defaults).
    /// Implementation defers to `save(toINI:)` via a temp file rather
    /// than duplicating the per-section line assembly.
    func captureAsINIString() throws -> String {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MPXPrime-snapshot-\(UUID().uuidString).ini")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try save(toINI: tempURL.path)
        return try String(contentsOf: tempURL, encoding: .utf8)
    }

    /// Inverse of `captureAsINIString` — parse a snapshot's embedded
    /// INI text back into an `AppConfig`. Uses the existing
    /// `load(fromINI:)` so missing-key defaults and validators apply
    /// the same way as a normal disk load.
    static func loadFromINIString(_ text: String) throws -> AppConfig {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MPXPrime-snapshot-load-\(UUID().uuidString).ini")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try text.write(to: tempURL, atomically: true, encoding: .utf8)
        return try AppConfig.load(fromINI: tempURL.path)
    }

    func save(toINI path: String) throws {
        let mpxLines: [String] = [
            "[MPX]",
            "pilot_level = \(Self.formatFloat(pilotLevel))",
            "sum_level = \(Self.formatFloat(sumLevel))",
            "diff_level = \(Self.formatFloat(diffLevel))",
            "mono_mode = \(Self.boolString(monoMode))",
            "processing_bypass = \(Self.boolString(processingBypass))",
            "preemphasis_us = \(preemphasisUS)",
            "program_lowpass_hz = \(Self.formatFloat(programLowpassHz))",
            "input_gain_db = \(Self.formatFloat(inputGainDB))",
            "output_gain_db = \(Self.formatFloat(outputGainDB))",
            "final_drive_db = \(Self.formatFloat(finalDriveDB))",
            "final_stage_preset_id = \(finalStagePresetID)",
            "format_profile_id = \(formatProfileID)",
            "hpf_hz = \(Self.formatFloat(hpfHz))",
            "hf_trim_db = \(Self.formatFloat(hfTrimDB))",
            "hf_trim_hz = \(Self.formatFloat(hfTrimHz))",
            "limit_mpx = \(Self.boolString(limitMPX))",
            "limit_threshold = \(Self.formatFloat(limitThreshold))",
            "limit_lookahead_enabled = \(Self.boolString(limitLookaheadEnabled))",
            "limit_lookahead_ms = \(Self.formatFloat(limitLookaheadMS))",
            "pre_encode_limiter_enabled = \(Self.boolString(preEncodeAudioLimiterEnabled))",
            "pre_encode_threshold = \(Self.formatFloat(preEncodeThreshold))",
            "pre_encode_release_ms = \(Self.formatFloat(preEncodeReleaseMS))",
            "pre_encode_bandlimited_residual_enabled = \(Self.boolString(preEncodeBandlimitedResidualEnabled))",
            "pre_encode_bandlimited_residual_taps = \(preEncodeBandlimitedResidualTapCount)",
            "pre_encode_bandlimited_residual_cutoff_fraction = \(Self.formatFloat(preEncodeBandlimitedResidualCutoffFraction))",
            "pre_encode_lookahead_ms = \(Self.formatFloat(preEncodeLookaheadMS))",
            "pre_encode_lookahead_hf_only = \(Self.boolString(preEncodeLookaheadHFOnly))",
            "pre_encode_lookahead_hf_cutoff_hz = \(Self.formatFloat(preEncodeLookaheadHFCutoffHz))",
            "encoder_fir_enabled = \(Self.boolString(encoderFIREnabled))",
            "multiband_fir_enabled = \(Self.boolString(multibandFIREnabled))",
            "audio_composite_softclip_enabled = \(Self.boolString(audioCompositeSoftClipEnabled))",
            "audio_composite_smoother_enabled = \(Self.boolString(audioCompositeSmootherEnabled))",
            "final_mpx_softclip_enabled = \(Self.boolString(finalMPXSoftClipEnabled))",
            "mpx_deviation_khz = \(Self.formatFloat(mpxDeviationKHz))",
            "en_rds = \(Self.boolString(enRDS))",
            "wideband_agc_enabled = \(Self.boolString(widebandAGCEnabled))",
            "wideband_agc_target_db = \(Self.formatFloat(widebandAGCTargetDB))",
            "wideband_agc_attack_ms = \(Self.formatFloat(widebandAGCAttackMS))",
            "wideband_agc_release_ms = \(Self.formatFloat(widebandAGCReleaseMS))",
            "wideband_agc_k_weighting = \(Self.boolString(widebandAGCKWeightingEnabled))",
            "wideband_agc_release_program_dependent = \(Self.boolString(widebandAGCReleaseProgramDependent))",
            "wideband_agc_bass_desensitize = \(Self.boolString(widebandAGCBassDesensitizeEnabled))",
            "wideband_agc_max_gain_db = \(Self.formatFloat(widebandAGCMaxGainDB))",
            "wideband_agc_min_gain_db = \(Self.formatFloat(widebandAGCMinGainDB))",
            "primebass_enabled = \(Self.boolString(primeBassEnabled))",
            "primebass_preset_id = \(primeBassPresetID)",
            "primebass_amount = \(Self.formatFloat(primeBassAmount))",
            "primebass_freq_hz = \(Self.formatFloat(primeBassFreqHz))",
            "primebass_harmonics = \(Self.formatFloat(primeBassHarmonics))",
            "primebass_drive = \(Self.formatFloat(primeBassDrive))",
            "primebass_density = \(Self.formatFloat(primeBassDensity))",
            "primebass_subharmonics_enabled = \(Self.boolString(primeBassSubharmonicsEnabled))",
            "primebass_subharmonics_amount = \(Self.formatFloat(primeBassSubharmonicsAmount))",
            "stereo_widen_enabled = \(Self.boolString(stereoWidenEnabled))",
            "mono_bass_enabled = \(Self.boolString(monoBassEnabled))",
            "mono_bass_freq_hz = \(Self.formatFloat(monoBassFreqHz))",
            "stereo_widen_width = \(Self.formatFloat(stereoWidenWidth))",
            "stereo_widen_center = \(Self.formatFloat(stereoWidenCenter))",
            "stereo_widen_mix = \(Self.formatFloat(stereoWidenMix))",
            "multiband_enabled = \(Self.boolString(multibandEnabled))",
            "multiband_mode = \(multibandMode)",
            "multiband_preset_id = \(multibandPresetID)",
            "multiband_intensity = \(multibandIntensity)",
            "multiband_low_hz = \(Self.formatFloat(multibandLowHz))",
            "multiband_high_hz = \(Self.formatFloat(multibandHighHz))",
            "multiband_x1_hz = \(Self.formatFloat(multibandX1Hz))",
            "multiband_x2_hz = \(Self.formatFloat(multibandX2Hz))",
            "multiband_x3_hz = \(Self.formatFloat(multibandX3Hz))",
            "multiband_x4_hz = \(Self.formatFloat(multibandX4Hz))",
            "multiband_low_threshold_db = \(Self.formatFloat(multibandLowThresholdDB))",
            "multiband_mid_threshold_db = \(Self.formatFloat(multibandMidThresholdDB))",
            "multiband_high_threshold_db = \(Self.formatFloat(multibandHighThresholdDB))",
            "multiband_low_ratio = \(Self.formatFloat(multibandLowRatio))",
            "multiband_mid_ratio = \(Self.formatFloat(multibandMidRatio))",
            "multiband_high_ratio = \(Self.formatFloat(multibandHighRatio))",
            "multiband_low_attack_ms = \(Self.formatFloat(multibandLowAttackMS))",
            "multiband_mid_attack_ms = \(Self.formatFloat(multibandMidAttackMS))",
            "multiband_high_attack_ms = \(Self.formatFloat(multibandHighAttackMS))",
            "multiband_low_release_ms = \(Self.formatFloat(multibandLowReleaseMS))",
            "multiband_mid_release_ms = \(Self.formatFloat(multibandMidReleaseMS))",
            "multiband_high_release_ms = \(Self.formatFloat(multibandHighReleaseMS))",
            "multiband_knee_db = \(Self.formatFloat(multibandKneeDB))",
            "multiband_link_strength = \(Self.formatFloat(multibandLinkStrength))",
            "multiband_release_program_dependent = \(Self.boolString(multibandReleaseProgramDependent))",
            "multiband_transient_aware_attack_enabled = \(Self.boolString(multibandTransientAwareAttackEnabled))",
            "multiband_inter_band_coupling_enabled = \(Self.boolString(multibandInterBandCouplingEnabled))",
            "multiband_makeup_db = \(Self.formatFloat(multibandMakeupDB))",
            "phase_rotation_enabled = \(Self.boolString(phaseRotationEnabled))",
            "phase_rotation_freq_hz = \(Self.formatFloat(phaseRotationFreqHz))",
            "parametric_eq_enabled = \(Self.boolString(parametricEQEnabled))",
            "peq_b1_freq_hz = \(Self.formatFloat(peqB1FreqHz))",
            "peq_b1_gain_db = \(Self.formatFloat(peqB1GainDB))",
            "peq_b2_freq_hz = \(Self.formatFloat(peqB2FreqHz))",
            "peq_b2_gain_db = \(Self.formatFloat(peqB2GainDB))",
            "peq_b2_q = \(Self.formatFloat(peqB2Q))",
            "peq_b3_freq_hz = \(Self.formatFloat(peqB3FreqHz))",
            "peq_b3_gain_db = \(Self.formatFloat(peqB3GainDB))",
            "peq_b3_q = \(Self.formatFloat(peqB3Q))",
            "peq_b4_freq_hz = \(Self.formatFloat(peqB4FreqHz))",
            "peq_b4_gain_db = \(Self.formatFloat(peqB4GainDB))",
            "multiband_limiter_enabled = \(Self.boolString(multibandLimiterEnabled))",
            "multiband_limiter_threshold_db = \(Self.formatFloat(multibandLimiterThresholdDB))",
            "multiband_limiter_attack_ms = \(Self.formatFloat(multibandLimiterAttackMS))",
            "multiband_limiter_release_ms = \(Self.formatFloat(multibandLimiterReleaseMS))",
            "downward_expander_enabled = \(Self.boolString(downwardExpanderEnabled))",
            "expander_threshold_db = \(Self.formatFloat(expanderThresholdDB))",
            "expander_ratio = \(Self.formatFloat(expanderRatio))",
            "expander_attack_ms = \(Self.formatFloat(expanderAttackMS))",
            "expander_release_ms = \(Self.formatFloat(expanderReleaseMS))",
            "bass_clipper_enabled = \(Self.boolString(bassClipperEnabled))",
            "bass_clipper_crossover_hz = \(Self.formatFloat(bassClipperCrossoverHz))",
            "bass_clipper_threshold_db = \(Self.formatFloat(bassClipperThresholdDB))",
            "bass_clipper_drive = \(Self.formatFloat(bassClipperDrive))",
            "hf_clipper_enabled = \(Self.boolString(hfClipperEnabled))",
            "hf_clipper_crossover_hz = \(Self.formatFloat(hfClipperCrossoverHz))",
            "hf_clipper_threshold_db = \(Self.formatFloat(hfClipperThresholdDB))",
            "hf_clipper_drive = \(Self.formatFloat(hfClipperDrive))",
            "dc_clipper_enabled = \(Self.boolString(dcClipperEnabled))",
            "dc_clipper_ceiling_db = \(Self.formatFloat(dcClipperCeilingDB))",
            "dc_clipper_cancel_freq_hz = \(Self.formatFloat(dcClipperCancelFreqHz))",
            "processed_audio_coder_has_clipper = \(Self.boolString(processedAudioCoderHasClipper))",
            "processed_audio_final_clip_drive_db = \(Self.formatFloat(processedAudioFinalClipDriveDB))",
            "bs412_enabled = \(Self.boolString(bs412Enabled))",
            "bs412_threshold_db = \(Self.formatFloat(bs412ThresholdDB))",
            "bs412_window_seconds = \(Self.formatFloat(bs412WindowSeconds))",
            "mpx_clipper_enabled = \(Self.boolString(compositeClipperEnabled))",
            "mpx_clipper_threshold_db = \(Self.formatFloat(compositeClipperThresholdDB))",
            "mpx_clipper_ceiling_db = \(Self.formatFloat(compositeClipperCeilingDB))",
            "mpx_clipper_cancel_audio = \(Self.boolString(compositeClipperCancelAudio))",
            "mpx_clipper_cancel_stereo = \(Self.boolString(compositeClipperCancelStereo))",
            "mpx_clipper_cancel_pilot = \(Self.boolString(compositeClipperCancelPilot))",
            "mpx_clipper_cancel_rds = \(Self.boolString(compositeClipperCancelRDS))",
            "mpx_clipper_lookahead_ms = \(Self.formatFloat(compositeClipperLookaheadMS))",
            "mpx_clipper_oversampling = \(compositeClipperOversampling)",
            "mpx_multiband_clipper_enabled = \(Self.boolString(compositeMultibandClipperEnabled))",
            "test_tone_mode = \(testToneMode)",
            "test_tone_freq = \(Self.formatFloat(testToneFreq))",
            "test_tone_level_db = \(Self.formatFloat(testToneLevelDB))",
            "test_tone_type = \(testToneType)"
        ]
        let rdsLines: [String] = [
            "[RDS]",
            "en_rds = \(Self.boolString(enRDS))",
            "rds_level = \(Self.formatFloat(rdsLevel))",
            "pi = \(Self.sanitizedPICode(rdsPI))",
            "pty = \(max(0, min(31, rdsPTY)))",
            "pty_rbds = \(Self.boolString(rdsPtyRBDS))",
            "tp = \(Self.boolString(rdsTP))",
            "ta = \(Self.boolString(rdsTA))",
            "ms = \(Self.boolString(rdsMS))",
            "di_stereo = \(Self.boolString(rdsDI_STEREO))",
            "di_head = \(Self.boolString(rdsDI_HEAD))",
            "di_comp = \(Self.boolString(rdsDI_COMP))",
            "di_dyn = \(Self.boolString(rdsDI_DYN))",
            "en_af = \(Self.boolString(rdsEnableAF))",
            "af_list = \(rdsAFList)",
            "af_method = \(rdsAFMethod)",
            "ps_a = \(rdsPSA)",
            "ps_b = \(rdsPSB)",
            "ps_c = \(rdsPSC)",
            "ps_d = \(rdsPSD)",
            "ps_active_bank = \(rdsPSActiveBank)",
            "ps_dynamic = \(activePSBankText)",
            "ps_centered = \(Self.boolString(rdsPSCentered))",
            "ps_frame_seconds = \(String(format: "%.2f", rdsPSFrameSeconds))",
            "rt_text = \(rdsRTText)",
            "rt_manual_buffers = \(Self.boolString(rdsRTManualBuffers))",
            "rt_cycle_ab = \(Self.boolString(rdsRTCycleAB))",
            "rt_a = \(rdsRTA)",
            "rt_b = \(rdsRTB)",
            "rt_c = \(rdsRTC)",
            "rt_d = \(rdsRTD)",
            "rt_a_enabled = \(Self.boolString(rdsRTBufferAEnabled))",
            "rt_b_enabled = \(Self.boolString(rdsRTBufferBEnabled))",
            "rt_c_enabled = \(Self.boolString(rdsRTBufferCEnabled))",
            "rt_d_enabled = \(Self.boolString(rdsRTBufferDEnabled))",
            "rt_cr = \(Self.boolString(rdsRTCR))",
            "rt_centered = \(Self.boolString(rdsRTCentered))",
            "rt_mode = \(rdsRTMode)",
            "rt_cycle = \(Self.boolString(rdsRTCycle))",
            "rt_cycle_time = \(Self.formatFloat(max(1.0, min(60.0, rdsRTCycleTime))))",
            "rt_active_buffer = \(max(0, min(3, rdsRTActiveBuffer)))",
            "rt_ab_cycle_count = \(max(1, min(99, rdsRTABCycleCount)))",
            "ptyn = \(rdsPTYN)",
            "en_ptyn = \(Self.boolString(rdsEnablePTYN))",
            "ptyn_centered = \(Self.boolString(rdsPTYNCentered))",
            "ps_long_32 = \(rdsLongPS32)",
            "en_lps = \(Self.boolString(rdsEnableLPS))",
            "lps_centered = \(Self.boolString(rdsLPSCentered))",
            "lps_cr = \(Self.boolString(rdsLPSCR))",
            "en_rt_plus = \(Self.boolString(rdsEnableRTPlus))",
            "rt_plus_format_a = \(rdsRTPlusFormatA)",
            "rt_plus_format_b = \(rdsRTPlusFormatB)",
            "now_playing_enabled = \(Self.boolString(rdsNowPlayingEnabled))",
            "now_playing_script = \(rdsNowPlayingScript)",
            "now_playing_poll_seconds = \(Self.formatFloat(max(1.0, min(300.0, rdsNowPlayingPollSeconds))))",
            "now_playing_timeout_seconds = \(Self.formatFloat(max(0.2, min(30.0, rdsNowPlayingTimeoutSeconds))))",
            "ecc = \(Self.sanitizedHexByte(rdsECC))",
            "lic = \(Self.sanitizedHexByte(rdsLIC))",
            "pin_enabled = \(Self.boolString(rdsEnablePIN))",
            "pin_day = \(rdsPINDay)",
            "pin_hour = \(rdsPINHour)",
            "pin_minute = \(rdsPINMinute)",
            "tz_offset = \(Self.formatFloat(max(-12.0, min(14.0, rdsTZOffset))))",
            "en_ct = \(Self.boolString(rdsEnableCT))",
            "en_id = \(Self.boolString(rdsEnableID))",
            "auto_start = \(Self.boolString(rdsAutoStart))",
            "group_sequence = \(rdsGroupSequence)",
            "scheduler_auto = \(Self.boolString(rdsSchedulerAuto))",
            "scheduler_standard = \(Self.boolString(rdsSchedulerStandard))",
            "scheduler_standard_lps = \(Self.boolString(rdsSchedulerStandardLPS))",
            "rds_gaussian_enabled = \(Self.boolString(rdsGaussianEnabled))",
            "rds_gaussian_bw_hz = \(Self.formatFloat(max(600.0, min(6_000.0, rdsGaussianBWHZ))))",
            "rds_gaussian_taps = \(max(9, min(401, rdsGaussianTaps | 1)))"
        ]
        let interfacesLines: [String] = [
            "[INTERFACES]",
            "source_mode = \(sourceMode)",
            "monitor_enabled = \(Self.boolString(monitorEnabled))",
            "processed_audio_output = \(Self.boolString(processedAudioOutput))",
            "monitor_rate_hz = \(Self.formatFloat(sampleRate))",
            "blocksize = \(blockSize)",
            "fft_window_92khz = \(Self.boolString(fftWindow96kHz))",
            "dual_rate_audio_domain_enabled = \(Self.boolString(dualRateAudioDomainEnabled))",
            "dual_rate_audio_domain_rate_hz = \(Self.formatFloat(dualRateAudioDomainRateHz))",
            "input_device_uid = \(inputDeviceUID ?? "")",
            "output_device_uid = \(outputDeviceUID ?? "")",
            "monitor_device_uid = \(monitorDeviceUID ?? "")",
            "input_device_name = \(inputDeviceName ?? "")",
            "output_device_name = \(outputDeviceName ?? "")",
            "monitor_device_name = \(monitorDeviceName ?? "")"
        ]
        let text = (mpxLines + [""] + rdsLines + [""] + interfacesLines + [""]).joined(
            separator: "\n")
        let resolvedPath = Self.resolveINIPath(path, forWrite: true)
        let fileManager = FileManager.default
        let parentDirectory = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent().path
        if !parentDirectory.isEmpty && parentDirectory != "/" {
            try fileManager.createDirectory(
                atPath: parentDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        try text.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
    }

    private static func boolString(_ value: Bool) -> String {
        value ? "True" : "False"
    }

    private static func formatFloat(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(format: "%.6g", value)
    }

    private static func sanitizedPICode(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let filtered = upper.filter { ch in
            switch ch {
            case "0"..."9", "A"..."F":
                return true
            default:
                return false
            }
        }
        if filtered.isEmpty {
            return "0000"
        }
        if filtered.count >= 4 {
            return String(filtered.prefix(4))
        }
        return String(repeating: "0", count: 4 - filtered.count) + filtered
    }

    private static func sanitizedHexByte(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let filtered = upper.filter { ch in
            switch ch {
            case "0"..."9", "A"..."F":
                return true
            default:
                return false
            }
        }
        if filtered.isEmpty {
            return "00"
        }
        if filtered.count >= 2 {
            return String(filtered.suffix(2))
        }
        return "0" + filtered
    }

    private static func resolveINIPath(_ rawPath: String, forWrite: Bool) -> String {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        let expandedNSString = expandedPath as NSString
        if expandedNSString.isAbsolutePath {
            return expandedNSString.standardizingPath
        }

        let fileManager = FileManager.default
        var candidates: [String] = []
        var seen: Set<String> = []

        func appendCandidate(_ candidate: String) {
            let normalized = (candidate as NSString).standardizingPath
            if seen.insert(normalized).inserted {
                candidates.append(normalized)
            }
        }

        func appendRelativeCandidate(base: String) {
            let combined = (base as NSString).appendingPathComponent(expandedPath)
            appendCandidate(combined)
        }

        // Check PWD environment variable first (respects shell launch context)
        if let pwdEnv = ProcessInfo.processInfo.environment["PWD"], !pwdEnv.isEmpty {
            appendRelativeCandidate(base: pwdEnv)
        }

        appendRelativeCandidate(base: fileManager.currentDirectoryPath)

        if let execPath = CommandLine.arguments.first, !execPath.isEmpty {
            var base = (execPath as NSString).deletingLastPathComponent
            while !base.isEmpty {
                appendRelativeCandidate(base: base)
                let parent = (base as NSString).deletingLastPathComponent
                if parent == base {
                    break
                }
                base = parent
            }
        }

        if let existingFile = candidates.first(where: { candidate in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory) else {
                return false
            }
            return !isDirectory.boolValue
        }) {
            return existingFile
        }

        if forWrite {
            if let writableCandidate = candidates.first(where: { candidate in
                let parent = (candidate as NSString).deletingLastPathComponent
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: parent, isDirectory: &isDirectory) else {
                    return false
                }
                return isDirectory.boolValue
            }) {
                return writableCandidate
            }
        }

        if let firstCandidate = candidates.first {
            return firstCandidate
        }
        let fallback = (fileManager.currentDirectoryPath as NSString).appendingPathComponent(
            expandedPath)
        return (fallback as NSString).standardizingPath
    }
}

extension Dictionary where Key == String, Value == String {
    fileprivate func string(_ key: String, defaultValue: String) -> String {
        guard let raw = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            return defaultValue
        }
        return raw
    }

    fileprivate func optionalString(_ key: String) -> String? {
        guard let raw = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    fileprivate func double(_ key: String, defaultValue: Double) -> Double {
        guard let raw = self[key],
            let val = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return defaultValue
        }
        return val
    }

    fileprivate func int(_ key: String, defaultValue: Int) -> Int {
        guard let raw = self[key],
            let val = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return defaultValue
        }
        return val
    }

    fileprivate func bool(_ key: String, defaultValue: Bool) -> Bool {
        guard let raw = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}
