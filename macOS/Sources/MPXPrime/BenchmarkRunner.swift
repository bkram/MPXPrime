import Foundation

// Benchmark runner — produces the per-stage / per-rate DSP cost report.
//
// Lives in Sources/MPXPrime (not Tests/) so it can be invoked from the
// CLI via `MPXPrime --bench` on any machine with just Command Line Tools
// (no full Xcode required, no Testing.framework dependency). The
// existing `BenchmarkSuite` @Test wrapper in Tests/ delegates here so
// the `MPXPRIME_BENCH=1 swift test --filter Benchmark` workflow still
// works on the dev machine.
//
// Run on the dev machine (M1 Pro):
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     MPXPRIME_BENCH=1 swift test -c release --package-path macOS --filter Benchmark
//
// Run on a CLT-only machine (Intel MBP via SSH, etc):
//   swift build --package-path macOS -c release
//   macOS/.build/release/MPXPrime --bench
//
// Save the stdout output as the captured baseline for that machine.

struct BenchmarkRunner {

    // Rates worth sweeping. 96 kHz cannot carry RDS (Nyquist 48 < 57)
    // so RDS is disabled at that rate; same for the upper sideband at
    // 53 kHz which sits above 48 kHz Nyquist (stereo subcarrier folds).
    // At 96 kHz we therefore measure mono-composite cost only; 128 / 176.4
    // / 192 kHz carry the full MPX with RDS.
    private struct SweepRate: Sendable {
        let hz: Double
        let label: String
        let rdsAndStereo: Bool
    }
    private static let sweepRates: [SweepRate] = [
        SweepRate(hz: 96_000, label: "96.0", rdsAndStereo: false),
        SweepRate(hz: 128_000, label: "128.0", rdsAndStereo: true),
        SweepRate(hz: 176_400, label: "176.4", rdsAndStereo: true),
        SweepRate(hz: 192_000, label: "192.0", rdsAndStereo: true)
    ]

    private let blockSize: Int = 512
    private let durationSeconds: Double = 1.0

    // MARK: - Public entry point

    /// Run the full benchmark and return the markdown report as a string.
    /// Progress messages are written to stderr so the stdout return value
    /// is a clean markdown document.
    func run() -> String {
        var out = ""
        out += header()
        out += "\n"
        out += rateSweepSection()
        out += "\n"
        out += oversamplingSweepSection()
        out += "\n"
        out += dualRateBoundarySection()
        out += "\n"
        out += perStageSection()
        out += "\n"
        out += summarySection()
        return out
    }

    // MARK: - Fixture

    private func makeFullChain(sampleRate: Double, withRDSAndStereo: Bool) -> AppConfig {
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
        cfg.preEncodeLookaheadMS = 1.0
        cfg.widebandAGCEnabled = true
        cfg.primeBassEnabled = true
        cfg.stereoWidenEnabled = true
        cfg.monoBassEnabled = true
        cfg.multibandEnabled = true
        cfg.multibandMode = 5
        cfg.phaseRotationEnabled = true
        cfg.parametricEQEnabled = true
        cfg.multibandLimiterEnabled = true
        cfg.bassClipperEnabled = true
        cfg.dcClipperEnabled = true
        cfg.bs412Enabled = true
        cfg.compositeClipperEnabled = true
        cfg.enRDS = withRDSAndStereo
        cfg.rdsLevel = withRDSAndStereo ? 2.0 : 0.0
        cfg.rdsNowPlayingEnabled = false
        cfg.rdsEnableRTPlus = false
        cfg.rdsEnableCT = false
        cfg.rdsEnableID = false
        return cfg
    }

    private func generateHeavyStereo(frames: Int, sampleRate: Double) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let sr = sampleRate
        for i in 0..<frames {
            let t = Double(i) / sr
            let base =
                0.32 * sin(2.0 * .pi * 1_000.0 * t)
                + 0.28 * sin(2.0 * .pi * 4_000.0 * t)
                + 0.22 * sin(2.0 * .pi * 10_000.0 * t)
            let jitter = 0.08 * sin(2.0 * .pi * 30.0 * t)
            left[i] = Float(base + jitter)
            right[i] = Float(base * 0.96 + 0.04 * sin(2.0 * .pi * 800.0 * t + 0.7))
        }
        return (left, right)
    }

    // MARK: - Measurement

    private func renderWall(config: AppConfig, samples: Int) -> Double {
        let gen = MPXGenerator(config: config, sampleRate: config.sampleRate)
        var (left, right) = generateHeavyStereo(frames: samples, sampleRate: config.sampleRate)
        let blocks = (samples + blockSize - 1) / blockSize

        // Warm-up block. First call allocates filter state, loads code,
        // warms caches. Discard.
        var warmL = [Float](repeating: 0.0, count: blockSize)
        var warmR = [Float](repeating: 0.0, count: blockSize)
        warmL.withUnsafeMutableBufferPointer { lBuf in
            warmR.withUnsafeMutableBufferPointer { rBuf in
                // swiftlint:disable force_unwrapping
                // baseAddress is non-nil for non-empty pre-allocated arrays (vDSP idiom).
                gen.renderFromInputInPlace(
                    frameCount: blockSize,
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!
                )
                // swiftlint:enable force_unwrapping
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                for _ in 0..<blocks {
                    let remain = samples - offset
                    let frames = min(blockSize, remain)
                    guard frames > 0 else { break }
                    // swiftlint:disable force_unwrapping
                    // baseAddress is non-nil for non-empty pre-allocated arrays.
                    gen.renderFromInputInPlace(
                        frameCount: frames,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    // swiftlint:enable force_unwrapping
                    offset += frames
                }
            }
        }
        let elapsed = clock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Median of 3 to reject one outlier (GC pause, kernel preempt, etc).
    private func medianWall(config: AppConfig, samples: Int) -> Double {
        var samplesArr = [Double]()
        for _ in 0..<3 {
            samplesArr.append(renderWall(config: config, samples: samples))
        }
        samplesArr.sort()
        return samplesArr[1]
    }

    // MARK: - Domain classification
    //
    // Audio-domain stages process L/R below the stereo encoder. Under
    // the dual-rate architecture these run at the audio rate (48 kHz);
    // MPX-domain stages process the composite at the high rate.

    private enum Domain: String, Sendable {
        case audio = "audio"
        case mpx = "MPX"
    }

    private struct StageProbe: Sendable {
        let name: String
        let domain: Domain
        let mutate: @Sendable (inout AppConfig) -> Void  // mutation that DISABLES the stage
    }

    private static let stageProbes: [StageProbe] = [
        StageProbe(name: "Multiband (5-band, FIR)", domain: .audio, mutate: { $0.multibandEnabled = false }),
        StageProbe(name: "Wideband AGC", domain: .audio, mutate: { $0.widebandAGCEnabled = false }),
        StageProbe(name: "Parametric EQ", domain: .audio, mutate: { $0.parametricEQEnabled = false }),
        StageProbe(name: "PrimeBass", domain: .audio, mutate: { $0.primeBassEnabled = false }),
        StageProbe(name: "Stereo widener", domain: .audio, mutate: { $0.stereoWidenEnabled = false }),
        StageProbe(name: "Mono bass", domain: .audio, mutate: { $0.monoBassEnabled = false }),
        StageProbe(name: "Phase rotation", domain: .audio, mutate: { $0.phaseRotationEnabled = false }),
        StageProbe(name: "Bass clipper", domain: .audio, mutate: { $0.bassClipperEnabled = false }),
        StageProbe(name: "DC clipper", domain: .audio, mutate: { $0.dcClipperEnabled = false }),
        StageProbe(name: "Multiband limiter", domain: .audio, mutate: { $0.multibandLimiterEnabled = false }),
        StageProbe(name: "Pre-emphasis", domain: .audio, mutate: { $0.preemphasisUS = 0 }),
        StageProbe(name: "Pre-encode limiter", domain: .audio, mutate: { $0.preEncodeAudioLimiterEnabled = false }),
        StageProbe(name: "Pre-encode look-ahead", domain: .audio, mutate: { $0.preEncodeLookaheadMS = 0.0 }),
        StageProbe(name: "Composite clipper", domain: .mpx, mutate: { $0.compositeClipperEnabled = false }),
        StageProbe(name: "BS.412", domain: .mpx, mutate: { $0.bs412Enabled = false }),
        StageProbe(name: "RDS encoder", domain: .mpx, mutate: { $0.enRDS = false; $0.rdsLevel = 0.0 })
    ]

    // MARK: - Sections

    private func header() -> String {
        var lines = ["# MPXPrime DSP benchmark"]
        lines.append("")
        lines.append("Captured: \(ISO8601DateFormatter().string(from: Date()))")
        #if os(macOS)
        lines.append("Machine: \(sysctlString("hw.model")) / \(sysctlString("machdep.cpu.brand_string"))")
        #else
        lines.append("Machine: \(linuxCPUModel())")
        #endif
        lines.append("Cores: \(ProcessInfo.processInfo.processorCount) logical, \(ProcessInfo.processInfo.activeProcessorCount) active")
        lines.append("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if DEBUG
        lines.append("Build: DEBUG (not representative — use -c release for valid numbers)")
        #else
        lines.append("Build: release")
        #endif
        return lines.joined(separator: "\n") + "\n"
    }

    private func rateSweepSection() -> String {
        var lines = ["## Rate sweep (full chain)"]
        lines.append("")
        lines.append("| Rate (kHz) | RDS+stereo | Wall (s) | Audio (s) | % of real-time |")
        lines.append("| ---------: | :--------: | -------: | --------: | -------------: |")
        for rate in Self.sweepRates {
            FileHandle.standardError.write(Data("[bench] rate sweep: \(rate.label) kHz\n".utf8))
            let cfg = makeFullChain(sampleRate: rate.hz, withRDSAndStereo: rate.rdsAndStereo)
            let samples = Int(rate.hz * durationSeconds)
            let wall = medianWall(config: cfg, samples: samples)
            let audio = Double(samples) / rate.hz
            let pct = wall / audio * 100.0
            let rateStr = pad(rate.label, to: 10, right: true)
            let rdsStr = pad(rate.rdsAndStereo ? "yes" : "no", to: 10, right: true)
            let wallStr = String(format: "%8.4f", wall)
            let audioStr = String(format: "%9.4f", audio)
            let pctStr = String(format: "%13.2f%%", pct)
            lines.append("| \(rateStr) | \(rdsStr) | \(wallStr) | \(audioStr) | \(pctStr) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Composite clipper oversampling sweep — full chain @ 192 kHz with
    /// the OS factor varied across 8 / 16 / 32. Quantifies the cost knob
    /// exposed by the UI picker.
    private func oversamplingSweepSection() -> String {
        var lines = ["## Composite clipper oversampling sweep (full chain @ 192 kHz)"]
        lines.append("")
        lines.append("| Oversampling | Wall (s) | Delta vs 16x | % of real-time |")
        lines.append("| -----------: | -------: | -----------: | -------------: |")

        let rate = 192_000.0
        let samples = Int(rate * durationSeconds)
        let audio = Double(samples) / rate

        // Measure all three first so the 16x reference is known before
        // we render the table rows.
        var walls: [Int: Double] = [:]
        for os in [8, 16, 32] {
            FileHandle.standardError.write(Data("[bench] oversampling sweep: \(os)x\n".utf8))
            var cfg = makeFullChain(sampleRate: rate, withRDSAndStereo: true)
            cfg.compositeClipperOversampling = os
            walls[os] = medianWall(config: cfg, samples: samples)
        }
        let sixteenWall = walls[16] ?? 0.0
        for os in [8, 16, 32] {
            let wall = walls[os] ?? 0.0
            let delta = wall - sixteenWall
            let deltaStr = (os == 16) ? "(reference)" : String(format: "%+.2f ms/s", delta * 1000.0)
            let osStr = pad("\(os)x", to: 12, right: true)
            let wallStr = String(format: "%8.4f", wall)
            let deltaPad = pad(deltaStr, to: 12, right: true)
            let pctStr = String(format: "%13.2f%%", wall / audio * 100.0)
            lines.append("| \(osStr) | \(wallStr) | \(deltaPad) | \(pctStr) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Dual-rate audio boundary sweep — full chain @ 192 kHz with the
    /// boundary off vs on. After Phase 2 cutover (0.30) the on row runs
    /// the entire audio domain at 48 kHz inside the boundary.
    private func dualRateBoundarySection() -> String {
        var lines = ["## Dual-rate boundary sweep (full chain @ 192 kHz, audio 48 kHz)"]
        lines.append("")
        lines.append("| Boundary | Wall (s) | Delta vs off | % of real-time |")
        lines.append("| -------- | -------: | -----------: | -------------: |")

        let rate = 192_000.0
        let samples = Int(rate * durationSeconds)
        let audio = Double(samples) / rate

        var cfgOff = makeFullChain(sampleRate: rate, withRDSAndStereo: true)
        cfgOff.dualRateAudioDomainEnabled = false
        FileHandle.standardError.write(Data("[bench] dual-rate sweep: off\n".utf8))
        let wallOff = medianWall(config: cfgOff, samples: samples)

        var cfgOn = makeFullChain(sampleRate: rate, withRDSAndStereo: true)
        cfgOn.dualRateAudioDomainEnabled = true
        cfgOn.dualRateAudioDomainRateHz = 48_000.0
        FileHandle.standardError.write(Data("[bench] dual-rate sweep: on (audio 48 kHz)\n".utf8))
        let wallOn = medianWall(config: cfgOn, samples: samples)

        let delta = wallOn - wallOff
        let pctOff = wallOff / audio * 100.0
        let pctOn = wallOn / audio * 100.0
        lines.append("| \(pad("off", to: 8, right: false)) | \(String(format: "%8.4f", wallOff)) | \(pad("(reference)", to: 12, right: true)) | \(String(format: "%13.2f%%", pctOff)) |")
        let deltaStr = String(format: "%+.2f ms/s", delta * 1000.0)
        lines.append("| \(pad("on", to: 8, right: false)) | \(String(format: "%8.4f", wallOn)) | \(pad(deltaStr, to: 12, right: true)) | \(String(format: "%13.2f%%", pctOn)) |")
        let savedPP = pctOff - pctOn
        let relPct = (savedPP / max(0.001, pctOff)) * 100.0
        lines.append("")
        lines.append(String(format: "Savings: **%+.2f percentage points** (%+.1f%% relative).", -savedPP, -relPct))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Per-stage cost as the delta when each stage is enabled vs
    /// disabled, all other stages held at the full-chain defaults at
    /// 192 kHz with RDS + stereo enabled. Median of 3 per stage.
    private func perStageSection() -> String {
        var lines = ["## Per-stage cost @ 192 kHz (full chain on, stage A/B)"]
        lines.append("")
        lines.append("| Stage                     | Domain | With (s) | Without (s) | Delta (ms/s) | % of real-time |")
        lines.append("| :------------------------ | :----- | -------: | ----------: | -----------: | -------------: |")

        let rate = 192_000.0
        let samples = Int(rate * durationSeconds)
        let audio = Double(samples) / rate

        // Baseline full chain (everything on)
        let baseCfg = makeFullChain(sampleRate: rate, withRDSAndStereo: true)
        let baseWall = medianWall(config: baseCfg, samples: samples)
        let baseNameStr = pad("(baseline, all on)", to: 25, right: false)
        let baseDomainStr = pad("-", to: 6, right: false)
        let baseWallStr = String(format: "%8.4f", baseWall)
        let basePctStr = String(format: "%13.2f%%", baseWall / audio * 100.0)
        lines.append("| \(baseNameStr) | \(baseDomainStr) | \(baseWallStr) | \(pad("-", to: 11, right: true)) | \(pad("-", to: 12, right: true)) | \(basePctStr) |")

        var audioDeltaTotal = 0.0
        var mpxDeltaTotal = 0.0

        for probe in Self.stageProbes {
            FileHandle.standardError.write(Data("[bench] per-stage A/B: \(probe.name)\n".utf8))
            var cfg = baseCfg
            probe.mutate(&cfg)
            let withoutWall = medianWall(config: cfg, samples: samples)
            let deltaSeconds = baseWall - withoutWall
            let deltaMs = deltaSeconds * 1000.0
            let deltaPct = (deltaSeconds / audio) * 100.0
            let nameStr = pad(probe.name, to: 25, right: false)
            let domainStr = pad(probe.domain.rawValue, to: 6, right: false)
            let withStr = String(format: "%8.4f", baseWall)
            let withoutStr = String(format: "%11.4f", withoutWall)
            let deltaMsStr = String(format: "%12.2f", deltaMs)
            let deltaPctStr = String(format: "%13.2f%%", deltaPct)
            lines.append("| \(nameStr) | \(domainStr) | \(withStr) | \(withoutStr) | \(deltaMsStr) | \(deltaPctStr) |")

            if deltaSeconds > 0 {
                switch probe.domain {
                case .audio: audioDeltaTotal += deltaSeconds
                case .mpx:   mpxDeltaTotal += deltaSeconds
                }
            }
        }

        lines.append("")
        lines.append(String(format: "**Sum audio-domain deltas:** %.2f ms/s (%.2f%% of real-time)",
                            audioDeltaTotal * 1000.0,
                            audioDeltaTotal / audio * 100.0))
        lines.append(String(format: "**Sum MPX-domain deltas:**   %.2f ms/s (%.2f%% of real-time)",
                            mpxDeltaTotal * 1000.0,
                            mpxDeltaTotal / audio * 100.0))
        lines.append("")
        lines.append("Note: deltas are not strictly additive — stages can interact (e.g. a hot stage feeding more limiter work). Treat as first-order estimate, not algebra.")
        return lines.joined(separator: "\n") + "\n"
    }

    private func summarySection() -> String {
        // Re-measure the relevant numbers cheaply so the summary stands
        // alone if pasted out of the report.
        let rate = 192_000.0
        let samples = Int(rate * durationSeconds)
        let audio = Double(samples) / rate
        let baseCfg = makeFullChain(sampleRate: rate, withRDSAndStereo: true)
        let baseWall = medianWall(config: baseCfg, samples: samples)
        let basePct = baseWall / audio * 100.0

        // Re-derive audio-domain delta sum since we cleared it after
        // perStageSection().
        var audioDeltaTotal = 0.0
        var mpxDeltaTotal = 0.0
        for probe in Self.stageProbes {
            var cfg = baseCfg
            probe.mutate(&cfg)
            let withoutWall = medianWall(config: cfg, samples: samples)
            let delta = baseWall - withoutWall
            if delta > 0 {
                switch probe.domain {
                case .audio: audioDeltaTotal += delta
                case .mpx:   mpxDeltaTotal += delta
                }
            }
        }

        let resamplerOverheadFraction = 0.05
        let estimatedDualRateWall =
            (audioDeltaTotal / 4.0)
            + mpxDeltaTotal
            + (baseWall - audioDeltaTotal - mpxDeltaTotal)
            + (baseWall * resamplerOverheadFraction)
        let estimatedDualRatePct = estimatedDualRateWall / audio * 100.0
        let savingsPct = basePct - estimatedDualRatePct

        var lines = ["## Summary"]
        lines.append("")
        lines.append(String(format: "Current chain cost @ 192 kHz, full features: **%.2f%% of real-time**", basePct))
        lines.append(String(format: "  - audio-domain stages contribute ~%.2f%% of real-time", audioDeltaTotal / audio * 100.0))
        lines.append(String(format: "  - MPX-domain stages contribute   ~%.2f%% of real-time", mpxDeltaTotal / audio * 100.0))
        lines.append("")
        lines.append(String(format: "Estimated dual-rate cost (audio @ 48 kHz, MPX @ 192 kHz, +%.0f%% resampler): **%.2f%% of real-time**",
                            resamplerOverheadFraction * 100.0, estimatedDualRatePct))
        lines.append(String(format: "Estimated savings: **%.2f percentage points** (%.0f%% relative)",
                            savingsPct, savingsPct / basePct * 100.0))
        lines.append("")
        lines.append("Caveats: audio-domain scaling is modeled as 1/4 (192k -> 48k linear). Actual scaling may differ for stages with internal oversampling (bass clipper, DCC) — their internal rate stays the same and only the outer rate changes; net cost still scales ~linearly with outer rate. Resampler overhead is a 5% placeholder; real overhead depends on filter design (target a Kaiser-windowed sinc polyphase, similar to LinearPhaseFIRDecimator).")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    /// Right- or left-pad a string to a width.
    private func pad(_ s: String, to width: Int, right: Bool) -> String {
        if s.count >= width { return s }
        let space = String(repeating: " ", count: width - s.count)
        return right ? (space + s) : (s + space)
    }

    #if os(macOS)
    private func sysctlString(_ name: String) -> String {
        var size = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 { return "?" }
        var buf = [UInt8](repeating: 0, count: size)
        if sysctlbyname(name, &buf, &size, nil, 0) != 0 { return "?" }
        let nullIdx = buf.firstIndex(of: 0) ?? buf.endIndex
        return String(bytes: buf[..<nullIdx], encoding: .utf8) ?? "?"
    }
    #else
    /// Linux counterpart of the sysctl machine line: CPU model from /proc.
    private func linuxCPUModel() -> String {
        guard let cpuinfo = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8)
        else { return "?" }
        for line in cpuinfo.split(separator: "\n") where line.hasPrefix("model name") {
            if let value = line.split(separator: ":", maxSplits: 1).last {
                return value.trimmingCharacters(in: .whitespaces)
            }
        }
        return "?"
    }
    #endif
}
