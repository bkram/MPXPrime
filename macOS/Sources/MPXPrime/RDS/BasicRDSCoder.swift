// Platform split: on macOS these resolve to the real Accelerate / Darwin /
// os modules (numerics and locking untouched); on Linux the
// MPXPrimeAcceleration shim provides same-name vDSP/vvtanhf functions and an
// OSAllocatedUnfairLock polyfill, and Glibc provides libm.
#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Atomics
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import MPXPrimeCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest on Linux corelibs
#endif
#if canImport(os)
import os
#endif

private struct RDSGroupSpec {
    let type: Int
    let versionB: Bool
}

private struct RTPlusTag {
    let contentType: Int
    let start: Int
    let length: Int
}

struct TimedTextFrame: Equatable {
    let duration: Double
    let transmits: Int
    let text: String

    init(duration: Double, text: String) {
        self.duration = duration
        self.transmits = 0
        self.text = text
    }

    init(transmits: Int, text: String) {
        self.duration = 0
        self.transmits = max(1, transmits)
        self.text = text
    }
}

// Block-level encoder (CRC, offset words, four-block group assembly,
// and the segment-counter patterns in groups 0/2) is an initial port
// of the Python `RDSHelper` in ryanginn/rds-master
// (https://github.com/ryanginn/rds-master). The shaping FIRs, the
// pilot-locked 57 kHz subcarrier generator, the real-time live-apply
// pipeline, RT+ ODA, AF Method B, CT/PTYN/Long PS/ECC group builders,
// and the audio-thread safety work (pre-allocated bit buffer, atomic
// CT cache, monotonic-clock timing) are MPX Prime's own additions.
final class BasicRDSCoder {
    private static let bitrate = Float(1187.5)
    private static let crcPoly = 0x5B9
    private static let offsetA = 0x0FC
    private static let offsetB = 0x198
    private static let offsetC = 0x168
    private static let offsetCp = 0x1E0
    private static let offsetD = 0x1B4
    private static let gregorianCalendar = Calendar(identifier: .gregorian)

    private struct CachedClockTimeGroup {
        let minuteToken: Int
        let b2Tail: Int
        let b3Value: Int
        let b4Value: Int
    }

    private var enabled: Bool
    private let levelScale: Float
    private var piCode: Int
    private var pty: Int
    private var tpFlag: Bool
    private var taFlag: Bool
    private var msFlag: Bool
    private var diStereoFlag: Bool
    private var diHeadFlag: Bool
    private var diCompFlag: Bool
    private var diDynFlag: Bool
    private var afEnabled: Bool
    private var afMethod: String
    private var afCodes: [Int]
    private var psCentered: Bool
    // PS banks: 4 text banks (A/B/C/D) with a single active selector.
    // Live-apply — switching the active bank rebuilds psSequence/psFrames.
    private var psBanks: [String]
    private var psActiveBankIndex: Int
    private var psFrameSeconds: Double
    private let rtManualBuffers: Bool
    private var rtCycleAB: Bool
    private var rtRawText: String
    private var rtRawBuffers: [String]
    private let rtBuffers: [String]
    private var rtBufferEnabled: [Bool]
    private var rtCR: Bool
    private var rtCentered: Bool
    private var rtMode2B: Bool
    private let rtCycle: Bool
    private var rtCycleTime: Double
    private let rtActiveBuffer: Int
    private var rtABCycleCount: Int
    private let gaussianEnabled: Bool
    private let gaussianBWHZ: Float
    private let gaussianTaps: Int
    private var schedule: [RDSGroupSpec]
    private var schedulerAuto: Bool
    private var schedulerStandard: Bool
    private var schedulerStandardLPS: Bool
    private var psFrames: [String]
    private var psFrameBytes: [[UInt8]]
    private var rtFrames: [String]
    private var psSequence: [TimedTextFrame]
    private var rtSequence: [TimedTextFrame]
    private var ptynEnabled: Bool
    private var ptynCentered: Bool
    private var ptynRawText: String
    private var ptynFrames: [String]
    private var ptynFrameBytes: [[UInt8]]
    private var ptynSequence: [TimedTextFrame]
    private var lpsEnabled: Bool
    private var lpsCentered: Bool
    private var lpsCR: Bool
    private var lpsRawText: String
    private var lpsFrames: [String]
    private var lpsPreparedFrameBytes: [[UInt8]]
    private var lpsSequence: [TimedTextFrame]
    private var rtPlusEnabled: Bool
    private var rtPlusFormatA: String
    private var rtPlusFormatB: String
    private var nowPlayingEnabled: Bool
    private let nowPlayingState: NowPlayingState?
    private var enCT: Bool
    private var enID: Bool
    private var eccCode: Int
    private var licCode: Int
    /// Programme Item Number for Group 1A block 4 (0 = disabled / no PIN).
    private var pinCode: Int
    private var tzOffset: Double
    private let cachedGroup1Variant = ManagedAtomic<Int>(0)
    private let cachedCTMinuteToken = ManagedAtomic<Int>(-1)
    private let cachedCTPacked = ManagedAtomic<UInt64>(0)
    private let clockUpdateQueue = DispatchQueue(label: "MPXPrime.RDSClockCache", qos: .utility)
    private var clockUpdateTimer: DispatchSourceTimer?

    private var sampleRate: Float
    private var carrierPhase: Float = 0.0
    private var carrierStep: Float = 0.0
    /// Instantaneous pilot recurrence value sin(theta) supplied by the
    /// generator's pilot oscillator. The 57 kHz RDS carrier is derived
    /// from this via the triple-angle identity so it stays bit-exactly
    /// locked to 3x the emitted pilot (EN 50067 Sec 2.1.4) instead of
    /// drifting off a separate phase accumulator.
    private var pilotSinForRDS: Float = 0.0
    private var bitPhase: Float = 0.0
    private var differentialBit: Int = 0
    /// Pre-allocated 104-byte buffer (4 RDS blocks × 26 bits) reused
    /// for every `buildGroupBits` call. The audio thread's `dequeueBit`
    /// path consumes via `self.bitBuffer[i]` and refills via subscript
    /// assignment in `buildGroupBits` — Swift Array's CoW keeps storage
    /// allocation at zero in steady state, since the only reference to
    /// the underlying buffer is `self.bitBuffer` itself. External
    /// callers (tests) that retain the returned `[UInt8]` trigger CoW
    /// on the next refill, paying for one allocation per held reference
    /// — paid by the test, not the audio thread.
    private var bitBuffer: [UInt8] = Array(repeating: 0, count: 104)
    /// Start past the end so the first `dequeueBit` triggers a refill —
    /// avoids returning the zero-initialized buffer as 104 phantom bits
    /// before any group is actually built.
    private var bitBufferIndex: Int = 104

    private var scheduleIndex: Int = 0
    /// Pre-computed RDS group schedules — cached so the audio thread
    /// doesn't allocate a fresh `[RDSGroupSpec]` on every `nextGroupBits`
    /// call (~11×/sec). Rebuilt at init and on `applyRDSRuntimeConfig`
    /// when any of `rtMode2B` / `rtPlusEnabled` change.
    private var cachedAutoSchedule: [RDSGroupSpec] = []
    private var cachedStandardSchedule: [RDSGroupSpec] = []
    /// Flag set when the operator toggles TA. Per UECP §2.5.1.1 a TA
    /// edge must produce an immediate "own TA flag change" group ahead
    /// of the regular schedule so traffic-aware receivers see the flip
    /// within one group time. We force the next emitted group to be 0A
    /// (which carries TP/TA in block B) and clear the flag.
    private var forceNextGroupForTAEdge: Bool = false

    /// Monotonic elapsed-seconds clock for audio-thread elapsed-time
    /// math (PS/RT/PTYN/LPS sequence advance, applyRDSRuntimeConfig
    /// seq-start markers). `ProcessInfo.systemUptime` is real-time
    /// safe — it reads `mach_continuous_time` via the commpage, no
    /// syscall. `Date()` would also typically resolve via commpage on
    /// modern Apple platforms but takes a slow path under some
    /// configurations. Use this for elapsed math; use `Date()` only
    /// where wall-clock time-of-day is genuinely needed (CT cache
    /// refresh on the background queue, RT {time}/{date} macros).
    @inline(__always)
    private static func monotonicSeconds() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
    private var afPointer: Int = 0
    private var ctMinuteLock: Int = -1
    private var psSegment: Int = 0
    private var psFrameIndex: Int = 0
    private var psSeqIndex: Int = 0
    private var psSeqStart: Double = 0.0
    private var psSeqTransmits: Int = 0
    private var rtSegment: Int = 0
    private var rtFrameIndex: Int = 0
    private var rtSeqIndex: Int = 0
    private var rtSeqStart: Double = 0.0
    private var rtSeqTransmits: Int = 0
    private var rtABFlag: Int = 0
    private var rtABCycles: Int = 0
    private var lastManualRTBuffer: Int = -1
    private var ptynSegment: Int = 0
    private var ptynFrameIndex: Int = 0
    private var ptynSeqIndex: Int = 0
    private var ptynSeqStart: Double = 0.0
    private var ptynSeqTransmits: Int = 0
    private var lpsSegment: Int = 0
    private var lpsFrameIndex: Int = 0
    private var lpsSeqIndex: Int = 0
    private var lpsSeqStart: Double = 0.0
    private var lpsSeqTransmits: Int = 0
    private var rtPlusToggle: Int = 0
    private var rtPlusTags: [RTPlusTag] = []
    private var rtPlusSignature: String = ""
    private var rtDynamicSignature: String = ""
    // Cache of the last parsed dynamic RT sequence, to avoid re-running
    // parseTimedSequence on the audio thread every buildGroup2 call when the
    // RT text (with now-playing macros expanded) hasn't changed. Keyed by the
    // signature string plus the limit/centered values so mode changes still
    // invalidate the cache.
    private var rtDynamicSequenceCache: [TimedTextFrame] = []
    private var rtDynamicCacheLimit: Int = 0
    private var rtDynamicCacheCentered: Bool = false
    // Cheap-to-compute "should we bother rebuilding?" keys so the audio
    // thread can skip expandNowPlayingMacros (which does DateFormatter work
    // and multiple string replacements) when nothing relevant has changed.
    private var rtDynamicCacheRevision = UInt64.max
    private var rtDynamicCacheMinuteEpoch = Int64.min
    private var rtDynamicCacheDayEpoch = Int64.min

    private var biphaseKernel: [Float] = []
    private var gaussianKernel: [Float] = []
    private var shapingKernel: [Float] = []
    private var biphaseOverlapAdd: [Float] = []
    private var biphaseOverlapIndex: Int = 0
    private var shapingPeak: Float = 1.0

    // Live snapshot of the most recently transmitted RDS frame text per field.
    // Updated on the audio thread after each buildGroupX call; polled by the
    // UI for an accurate Monitoring view.
    //
    // Uses OSAllocatedUnfairLock (os_unfair_lock under the hood) — on macOS
    // this performs priority inheritance, so when the real-time audio thread
    // contends with the main thread (e.g. the UI pulling a snapshot during
    // heavy launch-time setup) the holder's priority is temporarily raised
    // and the audio thread is not stalled. NSLock does NOT do this and can
    // cause priority inversion → render deadline misses → ring overflow.
    private struct SnapshotState {
        var ps: String = ""
        var rt: String = ""
        var ptyn: String = ""
        var longPS: String = ""
    }
    private let snapshotLock = OSAllocatedUnfairLock<SnapshotState>(initialState: SnapshotState())

    struct LiveSnapshot {
        let ps: String
        let rt: String
        let ptyn: String
        let longPS: String
    }

    func currentLiveSnapshot() -> LiveSnapshot {
        snapshotLock.withLock { state in
            LiveSnapshot(ps: state.ps, rt: state.rt, ptyn: state.ptyn, longPS: state.longPS)
        }
    }

    private func writeSnapshot(ps: String? = nil, rt: String? = nil, ptyn: String? = nil, longPS: String? = nil) {
        snapshotLock.withLock { state in
            if let ps = ps { state.ps = ps }
            if let rt = rt { state.rt = rt }
            if let ptyn = ptyn { state.ptyn = ptyn }
            if let longPS = longPS { state.longPS = longPS }
        }
    }

    init(config: AppConfig, sampleRate: Float, nowPlayingState: NowPlayingState? = nil) {
        self.enabled = config.enRDS && (config.rdsLevel > 0.0)
        self.levelScale = clampf(Float(config.rdsLevel) / 75.0, 0.0, 0.25)
        self.piCode = Self.parseHexWord(config.rdsPI)
        self.pty = max(0, min(31, config.rdsPTY))
        self.tpFlag = config.rdsTP
        self.taFlag = config.rdsTA
        self.msFlag = config.rdsMS
        self.diStereoFlag = config.rdsDI_STEREO
        self.diHeadFlag = config.rdsDI_HEAD
        self.diCompFlag = config.rdsDI_COMP
        self.diDynFlag = config.rdsDI_DYN
        self.afEnabled = config.rdsEnableAF
        self.afMethod = config.rdsAFMethod.uppercased()
        self.afCodes = Self.parseAFList(config.rdsAFList)
        self.psCentered = config.rdsPSCentered
        self.psBanks = [config.rdsPSA, config.rdsPSB, config.rdsPSC, config.rdsPSD]
        self.psActiveBankIndex = Self.psBankIndex(config.rdsPSActiveBank)
        self.psFrameSeconds = max(0.1, config.rdsPSFrameSeconds)
        self.rtManualBuffers = config.rdsRTManualBuffers
        self.rtCycleAB = config.rdsRTCycleAB
        self.rtRawText = config.rdsRTText
        self.rtRawBuffers = [config.rdsRTA, config.rdsRTB, config.rdsRTC, config.rdsRTD]
        self.rtBuffers = rtRawBuffers.map { Self.sanitizeText($0, uppercase: false) }
        self.rtBufferEnabled = [
            config.rdsRTBufferAEnabled,
            config.rdsRTBufferBEnabled,
            config.rdsRTBufferCEnabled,
            config.rdsRTBufferDEnabled
        ]
        self.rtCR = config.rdsRTCR
        self.rtCentered = config.rdsRTCentered
        self.rtMode2B = config.rdsRTMode.uppercased() == "2B"
        self.rtCycle = config.rdsRTCycle
        self.rtCycleTime = max(1.0, config.rdsRTCycleTime)
        self.rtActiveBuffer = max(0, min(3, config.rdsRTActiveBuffer))
        self.rtABCycleCount = max(1, config.rdsRTABCycleCount)
        self.gaussianEnabled = config.rdsGaussianEnabled
        self.gaussianBWHZ = clampf(Float(config.rdsGaussianBWHZ), 600.0, 6000.0)
        self.gaussianTaps = max(9, config.rdsGaussianTaps | 1)
        self.schedule = Self.parseGroupSequence(config.rdsGroupSequence)
        self.schedulerAuto = config.rdsSchedulerAuto
        self.schedulerStandard = config.rdsSchedulerStandard
        self.schedulerStandardLPS = config.rdsSchedulerStandardLPS
        let initialPSText = psBanks[psActiveBankIndex]
        self.psFrames = Self.parseTimedFrames(
            initialPSText, width: 8, uppercase: false, center: psCentered,
            allowScroll: true, defaultDuration: self.psFrameSeconds)
        self.psFrameBytes = psFrames.map(Self.rdsBytes)
        self.rtFrames = Self.parseTimedFrames(
            config.rdsRTText,
            width: rtMode2B ? 32 : 64,
            uppercase: false,
            center: rtCentered
        )
        self.psSequence = Self.parseTimedSequence(
            initialPSText, width: 8, uppercase: false, center: psCentered,
            allowScroll: true, defaultDuration: self.psFrameSeconds)
        self.rtSequence = Self.parseTimedSequence(
            config.rdsRTText,
            width: rtMode2B ? 32 : 64,
            uppercase: false,
            center: rtCentered
        )
        self.ptynEnabled = config.rdsEnablePTYN
        self.ptynCentered = config.rdsPTYNCentered
        self.ptynRawText = config.rdsPTYN
        self.ptynFrames = Self.parseTimedFrames(
            config.rdsPTYN, width: 8, uppercase: true, center: ptynCentered)
        self.ptynFrameBytes = ptynFrames.map(Self.rdsBytes)
        self.ptynSequence = Self.parseTimedSequence(
            config.rdsPTYN, width: 8, uppercase: true, center: ptynCentered)
        self.lpsEnabled = config.rdsEnableLPS
        self.lpsCentered = config.rdsLPSCentered
        self.lpsCR = config.rdsLPSCR
        self.lpsRawText = config.rdsLongPS32
        self.lpsFrames = Self.parseTimedFrames(
            config.rdsLongPS32, width: 32, uppercase: false, center: lpsCentered)
        self.lpsPreparedFrameBytes = lpsFrames.map {
            Self.rdsBytes(config.rdsLPSCR ? Self.prepareCRFrame($0, width: 32) : $0)
        }
        self.lpsSequence = Self.parseTimedSequence(
            config.rdsLongPS32, width: 32, uppercase: false, center: lpsCentered)
        self.rtPlusEnabled = config.rdsEnableRTPlus
        self.rtPlusFormatA = config.rdsRTPlusFormatA
        self.rtPlusFormatB = config.rdsRTPlusFormatB
        self.nowPlayingEnabled = config.rdsNowPlayingEnabled
        self.nowPlayingState = nowPlayingState
        self.enCT = config.rdsEnableCT
        self.enID = config.rdsEnableID
        self.eccCode = Self.parseHexByte(config.rdsECC)
        self.licCode = Self.parseHexByte(config.rdsLIC)
        self.pinCode = config.rdsPINValue
        self.tzOffset = config.rdsTZOffset
        self.sampleRate = max(8_000.0, sampleRate)
        let now = Self.monotonicSeconds()
        self.psSeqStart = now
        self.rtSeqStart = now
        self.ptynSeqStart = now
        self.lpsSeqStart = now
        updateDerivedRates()
        updateShapingFilters()
        startClockCacheIfNeeded()
        rebuildScheduleCaches()
    }

    deinit {
        clockUpdateTimer?.cancel()
    }

    func setSampleRate(_ newSampleRate: Float) {
        sampleRate = max(8_000.0, newSampleRate)
        updateDerivedRates()
        updateShapingFilters()
    }

    static func psBankIndex(_ name: String) -> Int {
        switch name.uppercased() {
        case "A": return 0
        case "B": return 1
        case "C": return 2
        case "D": return 3
        default:  return 0
        }
    }

    private func rebuildPSSequence() {
        let text = psBanks[psActiveBankIndex]
        psFrames = Self.parseTimedFrames(
            text, width: 8, uppercase: false, center: psCentered,
            allowScroll: true, defaultDuration: psFrameSeconds)
        psFrameBytes = psFrames.map(Self.rdsBytes)
        psSequence = Self.parseTimedSequence(
            text, width: 8, uppercase: false, center: psCentered,
            allowScroll: true, defaultDuration: psFrameSeconds)
        psSeqIndex = 0
        psSeqStart = Self.monotonicSeconds()
        psSeqTransmits = 0
        psSegment = 0
    }

    func applyRDSRuntimeConfig(_ config: MPXGenerator.RDSRuntimeConfig) {
        // Master enable + identification ---------------------------------
        let wasEnabled = enabled
        enabled = config.enabled
        if !wasEnabled && enabled {
            // Re-engage cleanly: reset bit phase + scheduling so the
            // first transmitted bits are aligned, not whatever was
            // sitting in the disabled state.
            bitPhase = 0.0
            bitBufferIndex = bitBuffer.count
            scheduleIndex = 0
        }

        piCode = config.pi
        pty = max(0, min(31, config.pty))
        eccCode = config.eccCode
        licCode = config.licCode
        pinCode = config.pinCode

        // Flags ----------------------------------------------------------
        // Detect TA-edge before the assignment so we can schedule a
        // forced 0A. Per UECP §2.5.1.1, TA flag transitions trigger
        // immediate emission ahead of the regular group sequence.
        let previousTA = taFlag
        tpFlag = config.tp
        taFlag = config.ta
        if previousTA != taFlag {
            forceNextGroupForTAEdge = true
        }
        msFlag = config.ms
        diStereoFlag = config.diStereo
        diHeadFlag = config.diHead
        diCompFlag = config.diComp
        diDynFlag = config.diDyn

        // Alternative Frequencies ----------------------------------------
        afEnabled = config.afEnabled
        afCodes = config.afCodes
        afMethod = config.afMethod.uppercased()
        afPointer = 0

        // Clock ----------------------------------------------------------
        let ctWas = enCT
        let idWas = enID
        enCT = config.enableCT
        enID = config.enableID
        tzOffset = config.tzOffset
        // If CT or ID just turned on for the first time since init,
        // make sure the clock-cache timer is running and pre-populate
        // the cache so the next 4A/1A schedule entry has data ready.
        if (!ctWas && enCT) || (!idWas && enID) {
            startClockCacheIfNeeded()
        }

        // PS banks -------------------------------------------------------
        let previousBanks = psBanks
        let previousActive = psActiveBankIndex
        let previousCentered = psCentered
        let previousPSFrameSeconds = psFrameSeconds
        if !config.psBanks.isEmpty {
            psBanks = Array(config.psBanks.prefix(4))
                + Array(repeating: "", count: max(0, 4 - config.psBanks.count))
        }
        psActiveBankIndex = Self.psBankIndex(config.psActiveBank)
        psCentered = config.psCentered
        psFrameSeconds = max(0.1, config.psFrameSeconds)
        if psBanks != previousBanks
            || psActiveBankIndex != previousActive
            || psCentered != previousCentered
            || psFrameSeconds != previousPSFrameSeconds {
            rebuildPSSequence()
        }

        // PTYN -----------------------------------------------------------
        let ptynChanged =
            ptynEnabled != config.ptynEnabled
            || ptynCentered != config.ptynCentered
            || ptynRawText != config.ptynText
        ptynEnabled = config.ptynEnabled
        ptynCentered = config.ptynCentered
        ptynRawText = config.ptynText
        if ptynChanged {
            ptynFrames = Self.parseTimedFrames(
                config.ptynText, width: 8, uppercase: true, center: ptynCentered)
            ptynFrameBytes = ptynFrames.map(Self.rdsBytes)
            ptynSequence = Self.parseTimedSequence(
                config.ptynText, width: 8, uppercase: true, center: ptynCentered)
            ptynSeqIndex = 0
            ptynSegment = 0
            ptynFrameIndex = 0
            ptynSeqTransmits = 0
            ptynSeqStart = Self.monotonicSeconds()
        }

        // Long PS --------------------------------------------------------
        let lpsChanged =
            lpsEnabled != config.lpsEnabled
            || lpsCentered != config.lpsCentered
            || lpsCR != config.lpsCR
            || lpsRawText != config.longPSText
        lpsEnabled = config.lpsEnabled
        lpsCentered = config.lpsCentered
        lpsCR = config.lpsCR
        lpsRawText = config.longPSText
        if lpsChanged {
            lpsFrames = Self.parseTimedFrames(
                config.longPSText, width: 32, uppercase: false, center: lpsCentered)
            lpsPreparedFrameBytes = lpsFrames.map {
                Self.rdsBytes(lpsCR ? Self.prepareCRFrame($0, width: 32) : $0)
            }
            lpsSequence = Self.parseTimedSequence(
                config.longPSText, width: 32, uppercase: false, center: lpsCentered)
            lpsSeqStart = Self.monotonicSeconds()
        }

        // Radiotext ------------------------------------------------------
        rtRawText = config.rtText
        rtRawBuffers =
            Array(config.rtBuffers.prefix(4))
            + Array(repeating: "", count: max(0, 4 - config.rtBuffers.count))
        rtBufferEnabled =
            Array(config.rtBufferEnabled.prefix(4))
            + Array(repeating: false, count: max(0, 4 - config.rtBufferEnabled.count))
        let previousRTMode2B = rtMode2B
        let previousRTPlusEnabled = rtPlusEnabled
        rtCR = config.rtCR
        rtCentered = config.rtCentered
        rtMode2B = config.rtMode2B
        rtCycleTime = max(1.0, config.rtCycleTime)
        rtCycleAB = config.rtCycleAB
        rtABCycleCount = max(1, config.rtABCycleCount)
        rtPlusEnabled = config.rtPlusEnabled
        rtPlusFormatA = config.rtPlusFormatA
        rtPlusFormatB = config.rtPlusFormatB
        nowPlayingEnabled = config.nowPlayingEnabled

        // Scheduler ------------------------------------------------------
        let newSchedule = Self.parseGroupSequence(config.groupSequenceRaw)
        let scheduleChanged =
            newSchedule.count != schedule.count
            || zip(newSchedule, schedule).contains { $0.type != $1.type || $0.versionB != $1.versionB }
        let schedulerFlagsChanged =
            schedulerAuto != config.schedulerAuto
            || schedulerStandard != config.schedulerStandard
            || schedulerStandardLPS != config.schedulerStandardLPS
        schedule = newSchedule
        schedulerAuto = config.schedulerAuto
        schedulerStandard = config.schedulerStandard
        schedulerStandardLPS = config.schedulerStandardLPS

        if scheduleChanged || schedulerFlagsChanged {
            scheduleIndex = 0
        }

        // Rebuild RT-derived caches if mode flipped or RT+ toggled, or
        // if the schedule shape changed (different cached groups apply).
        if rtMode2B != previousRTMode2B
            || rtPlusEnabled != previousRTPlusEnabled
            || scheduleChanged || schedulerFlagsChanged {
            rebuildScheduleCaches()
        }

        let width = rtMode2B ? 32 : 64
        rtFrames = Self.parseTimedFrames(
            rtRawText,
            width: width,
            uppercase: false,
            center: rtCentered
        )
        rtSequence = Self.parseTimedSequence(
            rtRawText,
            width: width,
            uppercase: false,
            center: rtCentered
        )

        let now = Self.monotonicSeconds()
        rtSeqStart = now
        rtSeqIndex = 0
        rtSegment = 0
        rtSeqTransmits = 0
        rtABCycles = 0
        rtDynamicSignature = ""
        rtDynamicSequenceCache = []
        lastManualRTBuffer = -1
    }

    func nextSample() -> Float {
        guard enabled else { return 0.0 }

        let previousPhase = bitPhase
        var impulse: Float = 0.0
        bitPhase += Self.bitrate / sampleRate
        while bitPhase >= 1.0 {
            bitPhase -= 1.0
            let nextBit = dequeueBit()
            differentialBit ^= Int(nextBit)
            impulse += differentialBit == 0 ? -1.0 : 1.0
        }
        if previousPhase < 0.5, bitPhase >= 0.5 {
            impulse += differentialBit == 0 ? 1.0 : -1.0
        }

        let shaped = nextShapingSample(impulse: impulse)

        let carrier = sinf(carrierPhase)
        carrierPhase += carrierStep
        if carrierPhase >= twoPi {
            carrierPhase -= twoPi
        }
        let normalized = shaped / max(1e-6, shapingPeak)
        return normalized * carrier * levelScale
    }

    func nextSampleWithPilotLock() -> Float {
        guard enabled else { return 0.0 }

        // RDS subcarrier is 57 kHz = 3x the 19 kHz pilot. The pilot's
        // instantaneous sin(theta) is supplied externally via
        // updateRDSPilotSin() from the same recurrence oscillator that
        // emits the broadcast pilot; the carrier sin(3*theta) is recovered
        // with the triple-angle identity sin(3t) = 3*sin t - 4*sin^3 t.
        // This keeps RDS exactly locked to the emitted pilot rather than
        // tracking a separate additive phase accumulator that slowly
        // drifts against the recurrence (~9 deg / 5 s pre-fix).
        let s = pilotSinForRDS
        let carrier = (3.0 - (4.0 * s * s)) * s

        let previousPhase = bitPhase
        var impulse: Float = 0.0
        bitPhase += Self.bitrate / sampleRate
        while bitPhase >= 1.0 {
            bitPhase -= 1.0
            let nextBit = dequeueBit()
            differentialBit ^= Int(nextBit)
            impulse += differentialBit == 0 ? -1.0 : 1.0
        }
        if previousPhase < 0.5, bitPhase >= 0.5 {
            impulse += differentialBit == 0 ? 1.0 : -1.0
        }

        let shaped = nextShapingSample(impulse: impulse)

        let normalized = shaped / max(1e-6, shapingPeak)
        return normalized * carrier * levelScale
    }

    private func updateDerivedRates() {
        // EN 50067 Sec 2.1.4: RDS subcarrier is 57 kHz, locked to 3x pilot.
        // The production render path uses `nextSampleWithPilotLock()` which
        // derives the carrier from the pilot recurrence directly; this
        // constant exists only for the free-running `nextSample()` path
        // used by tests.
        carrierStep = twoPi * 57_000.0 / sampleRate
    }

    /// Supply the pilot oscillator's instantaneous sin(theta). The RDS
    /// carrier sin(3*theta) is derived from it in nextSampleWithPilotLock().
    func updateRDSPilotSin(_ pilotSin: Float) {
        pilotSinForRDS = pilotSin
    }

    private func updateShapingFilters() {
        biphaseKernel = Self.biphaseShapingTaps(
            sampleRate: sampleRate, bitrate: Self.bitrate, tapCount: 301)
        if gaussianEnabled {
            gaussianKernel = Self.gaussianTaps(
                sampleRate: sampleRate, bandwidthHz: gaussianBWHZ, tapCount: gaussianTaps)
        } else {
            gaussianKernel = [1.0]
        }

        shapingKernel = Self.convolveKernels(biphaseKernel, gaussianKernel)
        if shapingKernel.isEmpty {
            shapingKernel = [1.0]
        }
        let olaSize = max(4096, shapingKernel.count * 8)
        biphaseOverlapAdd = Array(repeating: 0.0, count: olaSize)
        biphaseOverlapIndex = 0
        shapingPeak = estimateShapingPeak()
    }

    private func estimateShapingPeak() -> Float {
        let frames = 8192
        var peak: Float = 1e-6
        var testPhase: Float = 0.0
        var testBit: Int = 0
        var localOLA = Array(repeating: Float.zero, count: max(1024, shapingKernel.count * 6))
        var localIndex = 0
        for _ in 0..<frames {
            let previousPhase = testPhase
            var impulse: Float = 0.0
            testPhase += Self.bitrate / sampleRate
            while testPhase >= 1.0 {
                testPhase -= 1.0
                testBit ^= 1
                impulse += testBit == 0 ? -1.0 : 1.0
            }
            if previousPhase < 0.5, testPhase >= 0.5 {
                impulse += testBit == 0 ? 1.0 : -1.0
            }
            let shaped = Self.nextShapingSampleLocal(
                impulse: impulse,
                kernel: shapingKernel,
                overlapAdd: &localOLA,
                index: &localIndex
            )
            let a = fabsf(shaped)
            if a > peak {
                peak = a
            }
        }
        return max(peak, 1e-6)
    }

    private func nextShapingSample(impulse: Float) -> Float {
        Self.nextShapingSampleLocal(
            impulse: impulse,
            kernel: shapingKernel,
            overlapAdd: &biphaseOverlapAdd,
            index: &biphaseOverlapIndex
        )
    }

    private static func nextShapingSampleLocal(
        impulse: Float,
        kernel: [Float],
        overlapAdd: inout [Float],
        index: inout Int
    ) -> Float {
        guard !overlapAdd.isEmpty else { return 0.0 }
        let n = overlapAdd.count
        var idx = index
        let y = overlapAdd[idx]
        overlapAdd[idx] = 0.0

        if impulse != 0.0, !kernel.isEmpty {
            let scaledImpulse = impulse
            var tap = 0
            var pos = idx
            while tap < kernel.count, pos < n {
                overlapAdd[pos] += scaledImpulse * kernel[tap]
                tap += 1
                pos += 1
            }
            pos = 0
            while tap < kernel.count {
                overlapAdd[pos] += scaledImpulse * kernel[tap]
                tap += 1
                pos += 1
            }
        }

        idx += 1
        if idx >= n {
            idx = 0
        }
        index = idx
        return y
    }

    private static func biphaseShapingTaps(sampleRate: Float, bitrate: Float, tapCount: Int)
        -> [Float] {
        // Match Python path intent: firwin2-shaped EN50067 biphase impulse response.
        let count = max(9, tapCount | 1)
        let sr = max(8_000.0, sampleRate)
        let nyquist = sr * 0.5
        let td = 1.0 / max(1.0, bitrate)
        let fmax = max(1.0, min(nyquist, 2.0 * bitrate))
        let points = 128

        var freqs = Array(repeating: Float.zero, count: points + 1)
        var gains = Array(repeating: Float.zero, count: points + 1)
        for i in 0..<points {
            let ratio = Float(i) / Float(max(1, points - 1))
            let f = ratio * fmax
            freqs[i] = f
            gains[i] = cosf(Float.pi * f * td * 0.25)
        }
        freqs[points] = nyquist
        gains[points] = 0.0

        let mid = count / 2
        var taps = Array(repeating: Float.zero, count: count)
        for n in 0..<count {
            let m = Float(n - mid)
            var integral: Float = 0.0
            for k in 0..<points {
                let f0 = freqs[k]
                let f1 = freqs[k + 1]
                let g0 = gains[k]
                let g1 = gains[k + 1]
                let c0 = cosf(twoPi * f0 * m / sr)
                let c1 = cosf(twoPi * f1 * m / sr)
                integral += 0.5 * ((g0 * c0) + (g1 * c1)) * (f1 - f0)
            }
            var h = (2.0 / sr) * integral
            let window = 0.54 - (0.46 * cosf(twoPi * Float(n) / Float(max(1, count - 1))))
            h *= window
            taps[n] = h
        }

        var energy: Float = 0.0
        for t in taps {
            energy += t * t
        }
        if energy > 1e-12 {
            let inv = 1.0 / sqrtf(energy)
            for i in 0..<taps.count {
                taps[i] *= inv
            }
        }
        return taps
    }

    private static func gaussianTaps(sampleRate: Float, bandwidthHz: Float, tapCount: Int)
        -> [Float] {
        let count = max(9, tapCount | 1)
        let sr = max(8_000.0, sampleRate)
        let bw = max(100.0, bandwidthHz)
        let sigma = sr / (twoPi * bw)
        let half = count / 2
        var taps = Array(repeating: Float.zero, count: count)
        var sum: Float = 0.0
        for i in 0..<count {
            let x = Float(i - half)
            let v = expf(-0.5 * (x / max(1e-6, sigma)) * (x / max(1e-6, sigma)))
            taps[i] = v
            sum += v
        }
        if sum > 0 {
            for i in 0..<count {
                taps[i] /= sum
            }
        }
        return taps
    }

    private static func convolveKernels(_ a: [Float], _ b: [Float]) -> [Float] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var out = Array(repeating: Float.zero, count: a.count + b.count - 1)
        for i in 0..<a.count {
            let ai = a[i]
            if ai == 0 { continue }
            for j in 0..<b.count {
                out[i + j] += ai * b[j]
            }
        }
        return out
    }

    private func dequeueBit() -> UInt8 {
        if bitBufferIndex >= bitBuffer.count {
            bitBuffer = nextGroupBits()
            bitBufferIndex = 0
        }
        let bit = bitBuffer[bitBufferIndex]
        bitBufferIndex += 1
        return bit
    }

    func nextGroupBits() -> [UInt8] {
        if let ctBits = buildClockTimeGroupIfNeeded() {
            return ctBits
        }

        // TA-edge auto-injection (UECP §2.5.1.1). One forced 0A ahead
        // of the schedule, then the schedule resumes from where it was.
        // CT (above) takes priority — it's minute-aligned and cannot be
        // deferred.
        if forceNextGroupForTAEdge {
            forceNextGroupForTAEdge = false
            return buildGroup0(versionB: false)
        }

        let activeSchedule: [RDSGroupSpec]
        if schedulerStandard {
            activeSchedule = cachedStandardSchedule
        } else if schedulerAuto {
            activeSchedule = cachedAutoSchedule
        } else {
            activeSchedule = schedule
        }
        if activeSchedule.isEmpty {
            return buildGroup0(versionB: false)
        }

        let entry = activeSchedule[scheduleIndex % activeSchedule.count]
        scheduleIndex += 1
        switch entry.type {
        case 2:
            return buildGroup2(versionB: entry.versionB)
        case 3:
            return rtPlusEnabled ? buildGroup3A() : buildGroup0(versionB: false)
        case 4:
            return enCT
                ? (buildClockTimeGroupImmediate() ?? buildGroup0(versionB: false))
                : buildGroup0(versionB: false)
        case 10:
            return ptynEnabled ? buildGroup10A() : buildGroup0(versionB: false)
        case 11:
            // Skip 11A when no usable tags extracted from current RT — an
            // all-zero-content-type 11A reads as "RT+ withdrawn" on several
            // receivers (Pioneer / Sony car radios) and causes the RT+
            // display to flicker on / off. Substitute 0A so the group rate
            // stays constant; the next valid tag set will resume RT+.
            return (rtPlusEnabled && !rtPlusTags.isEmpty)
                ? buildGroup11A()
                : buildGroup0(versionB: false)
        case 15:
            return lpsEnabled ? buildGroup15A() : buildGroup0(versionB: false)
        case 1:
            return enID ? buildGroup1A() : buildGroup0(versionB: false)
        default:
            return buildGroup0(versionB: entry.versionB)
        }
    }

    func buildGroup0(versionB: Bool) -> [UInt8] {
        updatePSSequenceIfNeeded()
        let psFrameText = psSequence.isEmpty
            ? (psFrames.isEmpty ? String(repeating: " ", count: 8) : psFrames[psFrameIndex])
            : psSequence[psSeqIndex].text
        let bytes = psSequence.isEmpty ? psFrameBytes[psFrameIndex] : Self.rdsBytes(psFrameText)
        writeSnapshot(ps: psFrameText)
        let segment = psSegment % 4
        psSegment += 1
        if psSegment % 4 == 0 {
            psSeqTransmits += 1
        }
        let diBit = diBitForSegment(segment) ? 0x04 : 0x00
        let b2Tail = (taFlag ? 0x10 : 0) | (msFlag ? 0x08 : 0) | diBit | segment
        let b3Value: Int
        if versionB {
            b3Value = piCode
        } else if afEnabled, !afCodes.isEmpty {
            // Both Method A and Method B emit via the same dispatcher;
            // it switches internally on `afMethod`.
            b3Value = nextAFBlockValue()
        } else {
            b3Value = 0xE0E0
        }
        let idx = segment * 2
        let b4Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
        return buildGroupBits(
            groupType: 0,
            versionB: versionB,
            b2Tail: b2Tail,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    func buildGroup2(versionB: Bool) -> [UInt8] {
        let useVersionB = rtMode2B || versionB
        let limit = useVersionB ? 32 : 64
        let frameData = currentRTFrame(limit: limit)
        let frame = frameData.text
        let bytes = frameData.bytes
        writeSnapshot(rt: frame)
        let segment = rtSegment % 16
        rtSegment += 1
        if rtSegment % 16 == 0 {
            rtSeqTransmits += 1
        }
        let abFlag = rtABFlag & 1
        let b2Tail = ((abFlag & 1) << 4) | segment
        if rtPlusEnabled {
            let snapshot = currentNowPlayingSnapshot()
            let selectedFormat =
                (nowPlayingEnabled && snapshot.hasContent)
                ? ""
                : ((abFlag == 0) ? rtPlusFormatA : rtPlusFormatB)
            refreshRTPlusTagsIfNeeded(
                text: frame,
                format: selectedFormat,
                snapshot: snapshot
            )
        }
        if useVersionB {
            let idx = segment * 2
            let b4Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
            return buildGroupBits(
                groupType: 2,
                versionB: true,
                b2Tail: b2Tail,
                b3Value: piCode,
                b4Value: b4Value
            )
        }
        let idx = segment * 4
        let b3Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
        let b4Value = (Int(bytes[idx + 2]) << 8) | Int(bytes[idx + 3])
        return buildGroupBits(
            groupType: 2,
            versionB: false,
            b2Tail: b2Tail,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    private func buildGroup3A() -> [UInt8] {
        // ODA application identification for RT+ (AID 0x4BD7)
        return buildGroupBits(
            groupType: 3,
            versionB: false,
            b2Tail: 22,
            b3Value: 0x0000,
            b4Value: 0x4BD7
        )
    }

    func buildGroup10A() -> [UInt8] {
        updatePTYNSequenceIfNeeded()
        let ptynText = ptynSequence.isEmpty
            ? (ptynFrames.isEmpty ? String(repeating: " ", count: 8) : ptynFrames[ptynFrameIndex])
            : ptynSequence[ptynSeqIndex].text
        let bytes = ptynSequence.isEmpty ? ptynFrameBytes[ptynFrameIndex] : Self.rdsBytes(ptynText)
        writeSnapshot(ptyn: ptynText)
        let segment = ptynSegment % 2
        ptynSegment += 1
        if ptynSegment % 2 == 0 {
            ptynSeqTransmits += 1
        }
        let idx = segment * 4
        let b3Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
        let b4Value = (Int(bytes[idx + 2]) << 8) | Int(bytes[idx + 3])
        return buildGroupBits(
            groupType: 10,
            versionB: false,
            b2Tail: segment,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    func buildGroup11A() -> [UInt8] {
        var t1Type = 0
        var t1Start = 0
        var t1Length = 0
        var t2Type = 0
        var t2Start = 0
        var t2Length = 0

        let orderedTags = Array(rtPlusTags.prefix(2))
        if !orderedTags.isEmpty {
            t1Type = orderedTags[0].contentType
            t1Start = max(0, min(63, orderedTags[0].start))
            t1Length = max(0, min(63, orderedTags[0].length > 0 ? orderedTags[0].length - 1 : 0))
        }
        if orderedTags.count > 1 {
            t2Type = orderedTags[1].contentType
            t2Start = max(0, min(63, orderedTags[1].start))
            t2Length = max(0, min(31, orderedTags[1].length > 0 ? orderedTags[1].length - 1 : 0))
        }

        let b2Tail = ((rtPlusToggle & 1) << 4) | 0x08 | ((t1Type >> 3) & 0x07)
        let b3Value =
            ((t1Type & 0x07) << 13)
            | ((t1Start & 0x3F) << 7)
            | ((t1Length & 0x3F) << 1)
            | ((t2Type >> 5) & 0x01)
        let b4Value =
            ((t2Type & 0x1F) << 11)
            | ((t2Start & 0x3F) << 5)
            | (t2Length & 0x1F)
        return buildGroupBits(
            groupType: 11,
            versionB: false,
            b2Tail: b2Tail,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    func buildGroup15A() -> [UInt8] {
        updateLPSSequenceIfNeeded()
        let bytes: [UInt8]
        let lpsFrameText: String
        if lpsSequence.isEmpty {
            lpsFrameText = lpsFrames.isEmpty ? String(repeating: " ", count: 32) : lpsFrames[lpsFrameIndex]
            bytes = lpsPreparedFrameBytes[lpsFrameIndex]
        } else {
            let frame = lpsSequence[lpsSeqIndex].text
            lpsFrameText = frame
            let prepared = lpsCR ? Self.prepareCRFrame(frame, width: 32) : frame
            bytes = Self.rdsBytes(prepared)
        }
        writeSnapshot(longPS: lpsFrameText)
        let segment = lpsSegment % 8
        lpsSegment += 1
        if lpsSegment % 8 == 0 {
            lpsSeqTransmits += 1
        }
        let idx = segment * 4
        let b3Value = (Int(bytes[idx]) << 8) | Int(bytes[idx + 1])
        let b4Value = (Int(bytes[idx + 2]) << 8) | Int(bytes[idx + 3])
        return buildGroupBits(
            groupType: 15,
            versionB: false,
            b2Tail: segment,
            b3Value: b3Value,
            b4Value: b4Value
        )
    }

    private func buildGroup1A() -> [UInt8] {
        // Alternate ECC/LIC variants similar to Python scheduler behavior.
        let variants = [0, 3]
        let selector = cachedGroup1Variant.load(ordering: .acquiring) & 1
        let variant = variants[selector]
        let idValue = (variant == 0) ? eccCode : licCode
        let b3Value = ((variant & 0x0F) << 12) | (idValue & 0xFF)
        // Block 4 always carries the Programme Item Number (0 = no PIN).
        return buildGroupBits(
            groupType: 1,
            versionB: false,
            b2Tail: 0,
            b3Value: b3Value,
            b4Value: pinCode & 0xFFFF
        )
    }

    private func buildClockTimeGroupIfNeeded() -> [UInt8]? {
        guard enCT else { return nil }
        guard let cached = currentCachedClockTimeGroup() else { return nil }
        guard cached.minuteToken != ctMinuteLock else { return nil }
        ctMinuteLock = cached.minuteToken
        return buildGroupBits(
            groupType: 4,
            versionB: false,
            b2Tail: cached.b2Tail,
            b3Value: cached.b3Value,
            b4Value: cached.b4Value
        )
    }

    func buildClockTimeGroupImmediate() -> [UInt8]? {
        guard enCT else { return nil }
        guard let cached = currentCachedClockTimeGroup() else { return nil }
        return buildGroupBits(
            groupType: 4,
            versionB: false,
            b2Tail: cached.b2Tail,
            b3Value: cached.b3Value,
            b4Value: cached.b4Value
        )
    }

    private func makeClockTimeGroupPayload(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> (b2Tail: Int, b3Value: Int, b4Value: Int) {
        let mjd = Self.modifiedJulianDay(year: year, month: month, day: day)
        let tzHalfHours = max(0, min(31, Int(abs(tzOffset) * 2.0)))
        let tzSign = tzOffset < 0 ? 1 : 0
        let b2Tail = (mjd >> 15) & 0x3
        let b3Value = ((mjd & 0x7FFF) << 1) | ((hour >> 4) & 0x1)
        let b4Value =
            ((hour & 0x0F) << 12) | ((minute & 0x3F) << 6) | (tzSign << 5) | (tzHalfHours & 0x1F)
        return (b2Tail, b3Value, b4Value)
    }

    private func generateAutoSchedule() -> [RDSGroupSpec] {
        var seq: [RDSGroupSpec] = [
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false)
        ]
        if lpsEnabled {
            seq.append(RDSGroupSpec(type: 15, versionB: false))
            seq.append(RDSGroupSpec(type: 15, versionB: false))
        }
        if ptynEnabled {
            seq.append(RDSGroupSpec(type: 10, versionB: false))
            seq.append(RDSGroupSpec(type: 10, versionB: false))
        }
        if enID {
            seq.append(RDSGroupSpec(type: 1, versionB: false))
        }
        if rtPlusEnabled {
            // Emit 3A AID registration every cycle (was every other cycle).
            // Several receivers require seeing 3A within ~5-10 s of tune-in
            // to keep treating subsequent 11A groups as RT+; the prior
            // every-other-cycle cadence (~4.5 s) was on the edge and could
            // miss the receiver's window depending on tune-in timing.
            seq.append(RDSGroupSpec(type: 3, versionB: false))
            seq.append(RDSGroupSpec(type: 11, versionB: false))
        }
        return seq
    }

    /// Recompute both auto and standard schedule caches. Must be called
    /// from a non-audio context (init or live-apply path) — never from
    /// `nextGroupBits`. The cached arrays are read-only from the audio
    /// thread thereafter, so allocation pressure stays at zero in steady
    /// state.
    private func rebuildScheduleCaches() {
        cachedAutoSchedule = generateAutoSchedule()
        cachedStandardSchedule = generateStandardSchedule()
    }

    private func generateStandardSchedule() -> [RDSGroupSpec] {
        var seq: [RDSGroupSpec] = [
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 2, versionB: rtMode2B),
            RDSGroupSpec(type: 0, versionB: false),
            RDSGroupSpec(type: 0, versionB: false)
        ]
        if enID {
            seq.append(RDSGroupSpec(type: 1, versionB: false))
        }
        if ptynEnabled {
            seq.append(RDSGroupSpec(type: 10, versionB: false))
        }
        if rtPlusEnabled {
            seq.append(RDSGroupSpec(type: 3, versionB: false))
            seq.append(RDSGroupSpec(type: 11, versionB: false))
        }
        if schedulerStandardLPS && lpsEnabled {
            seq.append(RDSGroupSpec(type: 15, versionB: false))
        }
        return seq
    }

    private func startClockCacheIfNeeded() {
        guard enCT || enID else { return }
        refreshClockCache()
        if enCT, let cached = currentCachedClockTimeGroup() {
            // Prime the cache for immediate Group 4A requests without forcing a
            // once-per-minute CT burst right after startup.
            ctMinuteLock = cached.minuteToken
        }
        // Idempotent: if a timer is already running (e.g. from init or a
        // prior live-toggle), keep it instead of leaking a second one.
        guard clockUpdateTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: clockUpdateQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.refreshClockCache()
        }
        clockUpdateTimer = timer
        timer.resume()
    }

    private func refreshClockCache() {
        let now = Date()
        if enID {
            cachedGroup1Variant.store(
                Int(now.timeIntervalSince1970 / 2.0) & 1,
                ordering: .releasing
            )
        }
        guard enCT else { return }
        let comps = Self.gregorianCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: now
        )
        guard let year = comps.year,
            let month = comps.month,
            let day = comps.day,
            let hour = comps.hour,
            let minute = comps.minute
        else {
            return
        }
        let payload = makeClockTimeGroupPayload(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        let minuteToken = (((year * 100 + month) * 100 + day) * 100 + hour) * 100 + minute
        cachedCTPacked.store(
            packCachedClockTimeGroup(
                minuteToken: minuteToken,
                b2Tail: payload.b2Tail,
                b3Value: payload.b3Value,
                b4Value: payload.b4Value
            ),
            ordering: .releasing
        )
        cachedCTMinuteToken.store(minuteToken, ordering: .releasing)
    }

    private func currentCachedClockTimeGroup() -> CachedClockTimeGroup? {
        let minuteToken = cachedCTMinuteToken.load(ordering: .acquiring)
        guard minuteToken >= 0 else { return nil }
        let packed = cachedCTPacked.load(ordering: .acquiring)
        return unpackCachedClockTimeGroup(minuteToken: minuteToken, packed: packed)
    }

    private func packCachedClockTimeGroup(
        minuteToken: Int,
        b2Tail: Int,
        b3Value: Int,
        b4Value: Int
    ) -> UInt64 {
        _ = minuteToken
        return (UInt64(b2Tail & 0x1F) << 32)
            | (UInt64(b3Value & 0xFFFF) << 16)
            | UInt64(b4Value & 0xFFFF)
    }

    private func unpackCachedClockTimeGroup(minuteToken: Int, packed: UInt64) -> CachedClockTimeGroup {
        CachedClockTimeGroup(
            minuteToken: minuteToken,
            b2Tail: Int((packed >> 32) & 0x1F),
            b3Value: Int((packed >> 16) & 0xFFFF),
            b4Value: Int(packed & 0xFFFF)
        )
    }

    private func diBitForSegment(_ segment: Int) -> Bool {
        switch segment % 4 {
        case 0: return diDynFlag
        case 1: return diCompFlag
        case 2: return diHeadFlag
        default: return diStereoFlag
        }
    }

    private func nextAFBlockValue() -> Int {
        guard !afCodes.isEmpty else { return 0xE0E0 }
        if afMethod == "B" {
            return nextAFBlockValueMethodB()
        }
        return nextAFBlockValueMethodA()
    }

    /// Method A (EN 50067 §3.2.1.6.4 / IEC 62106-2 §7.5.2): flat AF
    /// list. First block carries `(count_code, freq[0])`; subsequent
    /// blocks carry pairs `(freq[N], freq[N+1])`. Filler 0xCD (205)
    /// pads odd-count tails. Receivers cannot tell Method A from B
    /// from a single 0A — they deduce by tuned-frequency repetition
    /// across many groups (Method B repeats the tuned frequency in
    /// every pair; Method A does not).
    private func nextAFBlockValueMethodA() -> Int {
        if afPointer == 0 {
            afPointer = 1
            let countCode = (224 + min(25, afCodes.count)) & 0xFF
            return (countCode << 8) | (afCodes[0] & 0xFF)
        }
        let f1 = afCodes[min(afPointer, afCodes.count - 1)] & 0xFF
        let f2: Int
        if afPointer + 1 < afCodes.count {
            f2 = afCodes[afPointer + 1] & 0xFF
            afPointer += 2
            if afPointer >= afCodes.count {
                afPointer = 0
            }
        } else {
            f2 = 205
            afPointer = 0
        }
        return (f1 << 8) | f2
    }

    /// Method B (EN 50067 §3.2.1.6.4 / IEC 62106-2 §7.5.3): tuned
    /// frequency repeated in every pair so receivers can group AF
    /// lists across regional variants. Convention: `afCodes[0]` is
    /// the tuned frequency; `afCodes[1...]` are alternatives. Each
    /// 0A block C carries:
    ///   1st block:    (count_code, tuned)
    ///   subsequent:   (tuned, alternative[N])
    /// Method B caps lists at 12 pairs (EN 50067 §3.2.1.6.4); we
    /// honour that by limiting the count code to 224+12=236 max
    /// when the operator configures more frequencies.
    /// Falls back to Method A semantics if afCodes has only the
    /// tuned frequency (no alternatives to pair with).
    private func nextAFBlockValueMethodB() -> Int {
        guard afCodes.count >= 2 else {
            return nextAFBlockValueMethodA()
        }
        let tuned = afCodes[0] & 0xFF
        let altCount = afCodes.count - 1
        if afPointer == 0 {
            afPointer = 1
            // Count = tuned + alternatives. EN 50067 caps Method B at
            // 12 pairs; clamp accordingly.
            let totalFreqs = min(13, 1 + altCount)
            let countCode = (224 + totalFreqs) & 0xFF
            return (countCode << 8) | tuned
        }
        let altIndex = afPointer
        let alt = afCodes[min(altIndex, afCodes.count - 1)] & 0xFF
        afPointer += 1
        if afPointer >= afCodes.count {
            afPointer = 0
        }
        return (tuned << 8) | alt
    }

    static func shouldAdvanceSequence(
        _ frame: TimedTextFrame, seqStart: Double, transmits: Int, now: Double
    ) -> Bool {
        if frame.transmits > 0 {
            return transmits >= frame.transmits
        }
        return (now - seqStart) >= frame.duration
    }

    private func updatePSSequenceIfNeeded() {
        guard !psSequence.isEmpty else { return }
        let now = Self.monotonicSeconds()
        let current = psSequence[min(psSeqIndex, psSequence.count - 1)]
        if Self.shouldAdvanceSequence(
            current, seqStart: psSeqStart, transmits: psSeqTransmits, now: now
        ) {
            psSeqIndex = (psSeqIndex + 1) % psSequence.count
            psSeqStart = now
            psSegment = 0
            psSeqTransmits = 0
        }
    }

    private func updatePTYNSequenceIfNeeded() {
        guard !ptynSequence.isEmpty else { return }
        let now = Self.monotonicSeconds()
        let current = ptynSequence[min(ptynSeqIndex, ptynSequence.count - 1)]
        if Self.shouldAdvanceSequence(
            current, seqStart: ptynSeqStart, transmits: ptynSeqTransmits, now: now
        ) {
            ptynSeqIndex = (ptynSeqIndex + 1) % ptynSequence.count
            ptynSeqStart = now
            ptynSegment = 0
            ptynSeqTransmits = 0
        }
    }

    private func updateLPSSequenceIfNeeded() {
        guard !lpsSequence.isEmpty else { return }
        let now = Self.monotonicSeconds()
        let current = lpsSequence[min(lpsSeqIndex, lpsSequence.count - 1)]
        if Self.shouldAdvanceSequence(
            current, seqStart: lpsSeqStart, transmits: lpsSeqTransmits, now: now
        ) {
            lpsSeqIndex = (lpsSeqIndex + 1) % lpsSequence.count
            lpsSeqStart = now
            lpsSegment = 0
            lpsSeqTransmits = 0
        }
    }

    private func enabledManualRTBuffers() -> [Int] {
        let enabled = rtBufferEnabled.enumerated().compactMap { index, isEnabled in
            let hasText = !rtRawBuffers[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (isEnabled && hasText) ? index : nil
        }
        return enabled
    }

    private func currentManualRTFrame(limit: Int, snapshot: NowPlayingSnapshot)
        -> (index: Int, text: String, bytes: [UInt8]) {
        let enabledBuffers = enabledManualRTBuffers()
        guard !enabledBuffers.isEmpty else {
            let frame = Self.prepareRTFrame("", width: limit, centered: rtCentered, appendCR: rtCR)
            return (0, frame, Self.rdsBytes(frame))
        }

        var sequence: [TimedTextFrame] = []
        for bufferIndex in enabledBuffers {
            let raw = rtRawBuffers[bufferIndex]
            let expanded =
                nowPlayingEnabled ? Self.expandNowPlayingMacros(raw, snapshot: snapshot) : raw
            sequence.append(
                contentsOf: Self.parseRTBufferSequence(
                    expanded,
                    width: limit,
                    center: rtCentered,
                    defaultDuration: max(1.0, rtCycleTime)
                )
            )
        }

        guard !sequence.isEmpty else {
            let frame = Self.prepareRTFrame("", width: limit, centered: rtCentered, appendCR: rtCR)
            return (0, frame, Self.rdsBytes(frame))
        }

        if sequence.count == 1 {
            let prepared = Self.prepareRTFrame(
                sequence[0].text,
                width: limit,
                centered: rtCentered,
                appendCR: rtCR
            )
            return (0, prepared, Self.rdsBytes(prepared))
        }

        let total = sequence.reduce(0.0) { $0 + max(0.1, $1.duration) }
        let elapsed = (Self.monotonicSeconds() - rtSeqStart).truncatingRemainder(
            dividingBy: max(0.1, total)
        )
        var acc = 0.0
        for (index, frame) in sequence.enumerated() {
            acc += max(0.1, frame.duration)
            if elapsed <= acc {
                let prepared = Self.prepareRTFrame(
                    frame.text,
                    width: limit,
                    centered: rtCentered,
                    appendCR: rtCR
                )
                return (index, prepared, Self.rdsBytes(prepared))
            }
        }

        let prepared = Self.prepareRTFrame(
            sequence[sequence.count - 1].text,
            width: limit,
            centered: rtCentered,
            appendCR: rtCR
        )
        return (sequence.count - 1, prepared, Self.rdsBytes(prepared))
    }

    private func currentRTFrame(limit: Int) -> (text: String, bytes: [UInt8]) {
        let nowPlayingSnapshot = currentNowPlayingSnapshot()
        if !enabledManualRTBuffers().isEmpty {
            let manual = currentManualRTFrame(limit: limit, snapshot: nowPlayingSnapshot)
            if manual.index != lastManualRTBuffer {
                rtSegment = 0
                rtSeqTransmits = 0
                rtABCycles = 0
                if lastManualRTBuffer >= 0 && !rtCycleAB {
                    rtABFlag ^= 1
                }
                lastManualRTBuffer = manual.index
            }
            return (manual.text, manual.bytes)
        }

        if nowPlayingEnabled {
            // Fast-path cache: skip macro expansion and parseTimedSequence
            // unless one of the inputs that could change the result has
            // actually changed. We're called ~6x/sec on the audio thread, so
            // avoiding DateFormatter + regex + string replacement when there's
            // nothing to do is critical.
            let now = Date()
            let nowEpoch = Int64(now.timeIntervalSince1970)
            let minuteEpoch = nowEpoch / 60
            let dayEpoch = nowEpoch / 86_400
            let containsTimeMacro = rtRawText.contains("{time}")
            let containsDateMacro = rtRawText.contains("{date}")
            let minuteChanged = containsTimeMacro && minuteEpoch != rtDynamicCacheMinuteEpoch
            let dayChanged = containsDateMacro && dayEpoch != rtDynamicCacheDayEpoch
            let revisionChanged = nowPlayingSnapshot.revision != rtDynamicCacheRevision
            let modeChanged = limit != rtDynamicCacheLimit || rtCentered != rtDynamicCacheCentered
            let cacheCold = rtDynamicSequenceCache.isEmpty

            if revisionChanged || minuteChanged || dayChanged || modeChanged || cacheCold {
                let resolvedRaw = Self.expandNowPlayingMacros(rtRawText, snapshot: nowPlayingSnapshot)
                let signature = "\(resolvedRaw)|\(nowPlayingSnapshot.revision)"
                if signature != rtDynamicSignature {
                    rtSegment = 0
                    rtSeqTransmits = 0
                    if !rtCycleAB {
                        rtABFlag ^= 1
                    }
                }
                rtDynamicSignature = signature
                rtDynamicCacheLimit = limit
                rtDynamicCacheCentered = rtCentered
                rtDynamicCacheRevision = nowPlayingSnapshot.revision
                rtDynamicCacheMinuteEpoch = minuteEpoch
                rtDynamicCacheDayEpoch = dayEpoch
                rtDynamicSequenceCache = Self.parseTimedSequence(
                    resolvedRaw,
                    width: limit,
                    uppercase: false,
                    center: rtCentered
                )
            }
            let dynamicSequence = rtDynamicSequenceCache
            guard !dynamicSequence.isEmpty else {
                let frame = Self.prepareRTFrame("", width: limit, centered: rtCentered, appendCR: rtCR)
                return (frame, Self.rdsBytes(frame))
            }

            let seqTime = now.timeIntervalSinceReferenceDate
            let current = dynamicSequence[min(rtSeqIndex, dynamicSequence.count - 1)]
            if Self.shouldAdvanceSequence(
                current, seqStart: rtSeqStart, transmits: rtSeqTransmits, now: seqTime
            ) {
                let prev = rtSeqIndex
                rtSeqIndex = (rtSeqIndex + 1) % dynamicSequence.count
                rtSeqStart = seqTime
                rtSegment = 0
                rtSeqTransmits = 0
                if !rtCycleAB && rtSeqIndex != prev {
                    rtABFlag ^= 1
                }
            }

            if rtCycleAB, rtSegment > 0, (rtSegment % 16) == 0 {
                rtABCycles += 1
                if rtABCycles >= rtABCycleCount {
                    rtABFlag ^= 1
                    rtABCycles = 0
                }
            }

            let frame = dynamicSequence[min(rtSeqIndex, dynamicSequence.count - 1)].text
            let prepared = Self.prepareRTFrame(frame, width: limit, centered: rtCentered, appendCR: rtCR)
            return (prepared, Self.rdsBytes(prepared))
        }

        guard !rtSequence.isEmpty else {
            let frame = Self.prepareRTFrame(
                rtFrames[rtFrameIndex], width: limit, centered: rtCentered, appendCR: rtCR)
            return (frame, Self.rdsBytes(frame))
        }

        let now = Self.monotonicSeconds()
        let current = rtSequence[min(rtSeqIndex, rtSequence.count - 1)]
        if Self.shouldAdvanceSequence(
            current, seqStart: rtSeqStart, transmits: rtSeqTransmits, now: now
        ) {
            let prev = rtSeqIndex
            rtSeqIndex = (rtSeqIndex + 1) % rtSequence.count
            rtSeqStart = now
            rtSegment = 0
            rtSeqTransmits = 0
            if !rtCycleAB && rtSeqIndex != prev {
                rtABFlag ^= 1
            }
        }

        if rtCycleAB, rtSegment > 0, (rtSegment % 16) == 0 {
            rtABCycles += 1
            if rtABCycles >= rtABCycleCount {
                rtABFlag ^= 1
                rtABCycles = 0
            }
        }

        let frame = rtSequence[min(rtSeqIndex, rtSequence.count - 1)].text
        let prepared = Self.prepareRTFrame(frame, width: limit, centered: rtCentered, appendCR: rtCR)
        return (prepared, Self.rdsBytes(prepared))
    }

    private func currentNowPlayingSnapshot() -> NowPlayingSnapshot {
        guard nowPlayingEnabled, let nowPlayingState else { return .empty }
        return nowPlayingState.currentSnapshot()
    }

    private static func rdsBytes(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D, 0x20...0x7E:
                out.append(UInt8(scalar.value))
            default:
                if let mapped = rdsDirectByteMap[scalar.value] {
                    out.append(mapped)
                } else {
                    out.append(UInt8(ascii: "?"))
                }
            }
        }
        return out
    }

    private func buildGroupBits(
        groupType: Int,
        versionB: Bool,
        b2Tail: Int,
        b3Value: Int,
        b4Value: Int
    ) -> [UInt8] {
        let b1Data = piCode & 0xFFFF
        let b2Data =
            ((groupType & 0x0F) << 12)
            | ((versionB ? 1 : 0) << 11)
            | ((tpFlag ? 1 : 0) << 10)
            | ((pty & 0x1F) << 5)
            | (b2Tail & 0x1F)
        let b3Offset = versionB ? Self.offsetCp : Self.offsetC
        let block1 = Self.withCheckword(word: b1Data, offset: Self.offsetA)
        let block2 = Self.withCheckword(word: b2Data, offset: Self.offsetB)
        let block3 = Self.withCheckword(word: b3Value & 0xFFFF, offset: b3Offset)
        let block4 = Self.withCheckword(word: b4Value & 0xFFFF, offset: Self.offsetD)

        // Subscript-assign into the pre-allocated 104-byte bitBuffer.
        // Avoids the per-call [UInt8] allocation (~11x/sec on the audio
        // thread) and the inner 4-element [block1..block4] array
        // allocation. Unrolled four block writes — each writes 26 bits
        // MSB-first starting at offsets 0, 26, 52, 78.
        Self.writeBlockBits(block1, into: &bitBuffer, atOffset: 0)
        Self.writeBlockBits(block2, into: &bitBuffer, atOffset: 26)
        Self.writeBlockBits(block3, into: &bitBuffer, atOffset: 52)
        Self.writeBlockBits(block4, into: &bitBuffer, atOffset: 78)
        return bitBuffer
    }

    @inline(__always)
    private static func writeBlockBits(_ block: Int, into out: inout [UInt8], atOffset offset: Int) {
        for i in 0..<26 {
            out[offset + i] = UInt8((block >> (25 - i)) & 1)
        }
    }

    private static func withCheckword(word: Int, offset: Int) -> Int {
        let checkword = crc(word: word, offset: offset)
        return ((word & 0xFFFF) << 10) | (checkword & 0x03FF)
    }

    private static func crc(word: Int, offset: Int) -> Int {
        var reg = (word & 0xFFFF) << 10
        for _ in 0..<16 {
            if ((reg >> 25) & 1) == 1 {
                reg ^= (crcPoly << 15)
            }
            reg = (reg << 1) & 0x03FF_FFFF
        }
        return ((reg >> 16) & 0x03FF) ^ offset
    }

    static func parseHexWord(_ text: String) -> Int {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleaned = upper.filter { ch in
            switch ch {
            case "0"..."9", "A"..."F":
                return true
            default:
                return false
            }
        }
        if cleaned.isEmpty {
            return 0
        }
        if let parsed = Int(cleaned, radix: 16) {
            return parsed & 0xFFFF
        }
        return 0
    }

    private static func parseGroupSequence(_ raw: String) -> [RDSGroupSpec] {
        let tokens =
            raw
            .uppercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var out: [RDSGroupSpec] = []
        for token in tokens {
            guard !token.isEmpty else { continue }
            var digits = ""
            var suffix = ""
            for scalar in token.unicodeScalars {
                if scalar.value >= 48, scalar.value <= 57 {
                    digits.append(Character(scalar))
                } else {
                    suffix.append(Character(scalar))
                }
            }
            guard let groupType = Int(digits) else { continue }
            let versionB = (groupType == 0 || groupType == 2) && suffix == "B"
            if groupType == 0 || groupType == 1 || groupType == 2 || groupType == 3
                || groupType == 4
                || groupType == 10 || groupType == 11 || groupType == 15 {
                out.append(RDSGroupSpec(type: groupType, versionB: versionB))
            }
        }
        if out.isEmpty {
            return [
                RDSGroupSpec(type: 0, versionB: false),
                RDSGroupSpec(type: 0, versionB: false),
                RDSGroupSpec(type: 2, versionB: false),
                RDSGroupSpec(type: 0, versionB: false)
            ]
        }
        return out
    }

    private func refreshRTPlusTagsIfNeeded(
        text: String,
        format: String,
        snapshot: NowPlayingSnapshot
    ) {
        let signature =
            text + "|" + format + "|" + snapshot.display + "|" + snapshot.artist + "|" + snapshot.title
        if signature == rtPlusSignature {
            return
        }
        rtPlusSignature = signature
        rtPlusToggle ^= 1
        rtPlusTags = Self.parseRTPlusTags(text: text, format: format, snapshot: snapshot)
    }

    static func parseTimedFrames(
        _ raw: String,
        width: Int,
        uppercase: Bool,
        center: Bool,
        allowScroll: Bool = false,
        defaultDuration: Double = 2.5
    ) -> [String] {
        return parseTimedSequence(
            raw, width: width, uppercase: uppercase, center: center,
            allowScroll: allowScroll, defaultDuration: defaultDuration
        ).map(\.text)
    }

    static func parseRTBufferSequence(
        _ raw: String,
        width: Int,
        center: Bool,
        defaultDuration: Double
    ) -> [TimedTextFrame] {
        let sequence = parseTimedSequence(raw, width: width, uppercase: false, center: center)
        guard !containsTimedCommand(raw) else {
            // Manual RT buffers cycle by wall-clock elapsed time across the
            // whole sequence (see currentManualRTFrame). Normalize any
            // transmit-count frames to the configured cycle time so the
            // duration-sum model stays valid.
            let fallback = max(0.1, defaultDuration)
            return sequence.map { frame in
                if frame.transmits > 0 {
                    return TimedTextFrame(duration: fallback, text: frame.text)
                }
                return frame
            }
        }
        let duration = max(0.1, defaultDuration)
        return sequence.map { TimedTextFrame(duration: duration, text: $0.text) }
    }

    static func containsTimedCommand(_ raw: String) -> Bool {
        RDSTextParser.containsTimedCommand(raw)
    }

    static func parseTimedSequence(
        _ raw: String,
        width: Int,
        uppercase: Bool,
        center: Bool,
        allowScroll: Bool = false,
        defaultDuration: Double = 2.5
    ) -> [TimedTextFrame] {
        let resolved = resolveTextMarkers(raw) ?? raw
        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [TimedTextFrame(duration: 10.0, text: String(repeating: " ", count: width))]
        }

        // Apply Stereotool escape handling: \\< \\> \\| \\: \\/ \\\\ become
        // private-use sentinels so they survive separator splitting; they
        // are decoded back to literals immediately before sanitize/chunk.
        let encoded = RDSTextParser.encodeEscapes(trimmed)
        // || word-wrap toggle is accepted but a no-op (word-wrap is always on).
        let stripped = RDSTextParser.stripWrapMarkers(encoded)

        var out: [TimedTextFrame] = []

        func emit(
            timing: RDSTextTiming,
            body: String,
            fallbackDuration: Double
        ) {
            // Scroll detection runs on the still-encoded body so escaped
            // `\<` and `\>` (now private-use sentinels) do NOT re-trigger
            // scroll. Decode only after we know this isn't a scroll spec.
            let trimmedEncoded = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if allowScroll, let scroll = RDSTextParser.parseScrollMarker(trimmedEncoded) {
                let decodedScrollText = RDSTextParser.decodeEscapes(scroll.text)
                let decodedSpec = RDSScrollSpec(
                    text: decodedScrollText,
                    direction: scroll.direction,
                    speed: scroll.speed
                )
                let windows = RDSTextParser.scrollWindows(decodedSpec, width: width)
                for window in windows {
                    let sanitized = sanitizeText(window, uppercase: uppercase)
                    let padded = Self.padToWidth(sanitized, width: width, center: false)
                    out.append(TimedTextFrame(transmits: 1, text: padded))
                }
                return
            }
            let decoded = RDSTextParser.decodeEscapes(trimmedEncoded)
            let chunks = splitAndPad(decoded, width: width, uppercase: uppercase, center: center)
            let frames: [String] = chunks.isEmpty
                ? [String(repeating: " ", count: width)]
                : chunks
            switch timing {
            case .seconds(let d):
                let duration = d > 0 ? d : fallbackDuration
                for chunk in frames {
                    out.append(TimedTextFrame(duration: duration, text: chunk))
                }
            case .transmits(let n):
                for chunk in frames {
                    out.append(TimedTextFrame(transmits: n, text: chunk))
                }
            }
        }

        // Split on '/' separators once. A leading '/' (operator wrote
        // "/2s:A/2s:B" for symmetry with the inter-segment separators)
        // produces an empty first part which is filtered out — we still
        // recognise the input as a timed sequence as long as any
        // non-empty part starts with a timing prefix.
        let slashParts = RDSTextParser.splitTopLevel(stripped)
            .filter { !$0.isEmpty }
        let startsTimed =
            RDSTextParser.startsWithTimingPrefix(stripped)
            || slashParts.contains { RDSTextParser.startsWithTimingPrefix($0) }

        if startsTimed {
            if slashParts.count > 1 {
                for part in slashParts {
                    let (timing, body) = RDSTextParser.parseTimingPrefix(
                        part, defaultDuration: defaultDuration)
                    emit(timing: timing, body: body, fallbackDuration: defaultDuration)
                }
            } else {
                // Single top-level segment that may contain inline
                // `1s:A 2t:B` whitespace-separated timed tokens.
                let inline = RDSTextParser.extractInlineSegments(
                    stripped, defaultDuration: defaultDuration)
                if inline.count > 1 {
                    for seg in inline {
                        emit(timing: seg.timing, body: seg.body, fallbackDuration: defaultDuration)
                    }
                } else {
                    let part = slashParts.first ?? stripped
                    let (timing, body) = RDSTextParser.parseTimingPrefix(
                        part, defaultDuration: defaultDuration)
                    emit(timing: timing, body: body, fallbackDuration: defaultDuration)
                }
            }
        } else {
            // No timing prefix — treat the whole thing as one body. Untimed
            // single-chunk content holds for 10s; untimed multi-chunk content
            // rotates at the configured default duration per chunk.
            let trimmedEncoded = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedEncoded.isEmpty {
                return [TimedTextFrame(duration: 10.0, text: String(repeating: " ", count: width))]
            }
            if allowScroll, let scroll = RDSTextParser.parseScrollMarker(trimmedEncoded) {
                let decodedScrollText = RDSTextParser.decodeEscapes(scroll.text)
                let decodedSpec = RDSScrollSpec(
                    text: decodedScrollText,
                    direction: scroll.direction,
                    speed: scroll.speed
                )
                let windows = RDSTextParser.scrollWindows(decodedSpec, width: width)
                for window in windows {
                    let sanitized = sanitizeText(window, uppercase: uppercase)
                    let padded = Self.padToWidth(sanitized, width: width, center: false)
                    out.append(TimedTextFrame(transmits: 1, text: padded))
                }
            } else {
                let decoded = RDSTextParser.decodeEscapes(trimmedEncoded)
                let chunks = splitAndPad(decoded, width: width, uppercase: uppercase, center: center)
                if chunks.count <= 1 {
                    let single = chunks.first ?? String(repeating: " ", count: width)
                    out.append(TimedTextFrame(duration: 10.0, text: single))
                } else {
                    for chunk in chunks {
                        out.append(TimedTextFrame(duration: defaultDuration, text: chunk))
                    }
                }
            }
        }

        if out.isEmpty {
            return [TimedTextFrame(duration: 10.0, text: String(repeating: " ", count: width))]
        }
        return out
    }

    private static func padToWidth(_ text: String, width: Int, center: Bool) -> String {
        let count = text.count
        if count >= width { return String(text.prefix(width)) }
        let pad = width - count
        if center {
            let left = pad / 2
            let right = pad - left
            return String(repeating: " ", count: left) + text
                + String(repeating: " ", count: right)
        }
        return text + String(repeating: " ", count: pad)
    }

    private static func splitAndPad(_ raw: String, width: Int, uppercase: Bool, center: Bool)
        -> [String] {
        let normalized = sanitizeText(raw, uppercase: uppercase)
        let words = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.isEmpty {
            return [String(repeating: " ", count: width)]
        }
        var out: [String] = []
        var current = ""

        func pad(_ value: String) -> String {
            let clipped = value.count <= width ? value : String(value.prefix(width))
            if clipped.count >= width {
                return clipped
            }
            let padding = width - clipped.count
            if center {
                let left = padding / 2
                let right = padding - left
                return String(repeating: " ", count: left) + clipped
                    + String(repeating: " ", count: right)
            }
            return clipped + String(repeating: " ", count: padding)
        }

        func chunkWord(_ word: String) -> [String] {
            guard word.count > width else { return [word] }
            let chars = Array(word)
            var chunks: [String] = []
            var idx = 0
            while idx < chars.count {
                let end = min(chars.count, idx + width)
                chunks.append(String(chars[idx..<end]))
                idx = end
            }
            return chunks
        }

        for word in words {
            if word.count > width {
                if !current.isEmpty {
                    out.append(pad(current))
                    current = ""
                }
                let chunks = chunkWord(word)
                if chunks.count > 1 {
                    for chunk in chunks.dropLast() {
                        out.append(pad(chunk))
                    }
                }
                current = chunks.last ?? ""
                continue
            }
            let test = current.isEmpty ? word : "\(current) \(word)"
            if test.count <= width {
                current = test
            } else {
                if !current.isEmpty {
                    out.append(pad(current))
                }
                current = word
            }
        }
        if !current.isEmpty {
            out.append(pad(current))
        }
        if out.isEmpty {
            out.append(String(repeating: " ", count: width))
        }
        return out
    }

    private static let rdsDirectByteMap: [UInt32: UInt8] = [
        0x00D8: 0xE7,
        0x00F8: 0xF7
    ]

    private static let rdsTransliterationMap: [UInt32: String] = [
        0x00C9: "E", 0x00C8: "E", 0x00CA: "E", 0x00CB: "E",
        0x00E9: "e", 0x00E8: "e", 0x00EA: "e", 0x00EB: "e",
        0x00C1: "A", 0x00C0: "A", 0x00C2: "A", 0x00C4: "A", 0x00C5: "A",
        0x00E1: "a", 0x00E0: "a", 0x00E2: "a", 0x00E4: "a", 0x00E5: "a",
        0x00CD: "I", 0x00CC: "I", 0x00CE: "I", 0x00CF: "I",
        0x00ED: "i", 0x00EC: "i", 0x00EE: "i", 0x00EF: "i",
        0x00D3: "O", 0x00D2: "O", 0x00D4: "O", 0x00D6: "O",
        0x00F3: "o", 0x00F2: "o", 0x00F4: "o", 0x00F6: "o",
        0x00DA: "U", 0x00D9: "U", 0x00DB: "U", 0x00DC: "U",
        0x00FA: "u", 0x00F9: "u", 0x00FB: "u", 0x00FC: "u",
        0x00C7: "C", 0x00E7: "c",
        0x00D1: "N", 0x00F1: "n",
        0x00C6: "AE", 0x00E6: "ae",
        0x0152: "OE", 0x0153: "oe",
        0x00DF: "ss",
        0x20AC: "E",
        0x00B0: " ", 0x2122: " ", 0x00AE: " "
    ]

    private static func resolveTextMarkers(_ text: String) -> String? {
        guard text.contains("\\") else { return text }
        var failed = false
        var resolved = text
        // \R and \F load a file and force uppercase. Stereotool distinguishes
        // "raw" (\R/\r) from "formatted" (\F/\f) file loads; we treat the
        // formatted variants as aliases since loaded content re-enters the
        // parser and inherits all markers that way.
        resolved = replaceMarkers(in: resolved, pattern: #"\\[RF]\"([^\"]+)\""#) { path in
            guard let loaded = loadTextFromFile(path) else {
                failed = true
                return ""
            }
            return cleanMarkerSpaces(transliterateRDSText(loaded)).uppercased()
        }
        resolved = replaceMarkers(in: resolved, pattern: #"\\[rf]\"([^\"]+)\""#) { path in
            guard let loaded = loadTextFromFile(path) else {
                failed = true
                return ""
            }
            return cleanMarkerSpaces(transliterateRDSText(loaded))
        }
        resolved = replaceMarkers(in: resolved, pattern: #"\\w\"([^\"]+)\""#) { source in
            guard let loaded = loadTextFromURL(source) else {
                failed = true
                return ""
            }
            return cleanMarkerSpaces(transliterateRDSText(loaded))
        }
        return failed ? nil : resolved
    }

    private static func replaceMarkers(
        in source: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return source
        }
        let ns = source as NSString
        let matches = regex.matches(
            in: source, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            return source
        }
        var out = source
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let wholeRange = match.range(at: 0)
            let capRange = match.range(at: 1)
            let token = ns.substring(with: capRange)
            let replacement = transform(token)
            if let r = Range(wholeRange, in: out) {
                out.replaceSubrange(r, with: replacement)
            }
        }
        return out
    }

    private static func loadTextFromFile(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func loadTextFromURL(_ source: String) -> String? {
        guard let url = URL(string: source) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        let semaphore = DispatchSemaphore(value: 0)
        final class PayloadBox: @unchecked Sendable {
            var value: String?
        }
        let box = PayloadBox()
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data else { return }
            box.value = String(data: data, encoding: .utf8)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2.5)
        task.cancel()
        return box.value
    }

    private static func cleanMarkerSpaces(_ text: String) -> String {
        return text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(
            of: "\n", with: " ")
    }

    private static func transliterateRDSText(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0D || (scalar.value >= 0x20 && scalar.value <= 0x7E) {
                out.append(Character(scalar))
            } else if rdsDirectByteMap[scalar.value] != nil {
                out.append(Character(scalar))
            } else if let mapped = rdsTransliterationMap[scalar.value] {
                out += mapped
            } else {
                let folded = String(scalar).folding(
                    options: [.diacriticInsensitive, .widthInsensitive],
                    locale: .current
                )
                var appended = false
                for foldedScalar in folded.unicodeScalars {
                    if foldedScalar.value == 0x0D
                        || (foldedScalar.value >= 0x20 && foldedScalar.value <= 0x7E) {
                        out.append(Character(foldedScalar))
                        appended = true
                    }
                }
                if !appended {
                    out += "?"
                }
            }
        }
        return out
    }

    private static func sanitizeText(_ raw: String, uppercase: Bool) -> String {
        let transliterated = transliterateRDSText(raw)
        let mapped = transliterated.unicodeScalars.map { scalar -> Character in
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                return Character(scalar)
            }
            return " "
        }
        let base = String(mapped)
        if uppercase {
            return base.uppercased()
        }
        return base
    }

    private static func prepareRTFrame(_ raw: String, width: Int, centered: Bool, appendCR: Bool)
        -> String {
        let sanitized = sanitizeText(raw, uppercase: false)
        let limited = String(sanitized.prefix(width))
        if appendCR {
            let trimmed = limited.trimmingCharacters(in: .whitespacesAndNewlines)
            let withCR = trimmed + "\r"
            if withCR.count >= width {
                return String(withCR.prefix(width))
            }
            return withCR + String(repeating: " ", count: width - withCR.count)
        }
        if centered, limited.count < width {
            let total = width - limited.count
            let left = total / 2
            let right = total - left
            return String(repeating: " ", count: left) + limited
                + String(repeating: " ", count: right)
        }
        if limited.count < width {
            return limited + String(repeating: " ", count: width - limited.count)
        }
        return limited
    }

    private static func prepareCRFrame(_ raw: String, width: Int) -> String {
        let sanitized = sanitizeText(raw, uppercase: false)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        let withCR = trimmed + "\r"
        if withCR.count >= width {
            return String(withCR.prefix(width))
        }
        return withCR + String(repeating: " ", count: width - withCR.count)
    }

    static func parseAFList(_ raw: String) -> [Int] {
        let tokens = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out: [Int] = []
        for token in tokens {
            guard let mhz = Double(token) else { continue }
            if mhz >= 87.6, mhz <= 107.9 {
                out.append(Int((mhz - 87.5) / 0.1 + 0.5))
            }
        }
        return out
    }

    static func parseHexByte(_ raw: String) -> Int {
        let cleaned =
            raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { ch in
                switch ch {
                case "0"..."9", "A"..."F":
                    return true
                default:
                    return false
                }
            }
        if cleaned.isEmpty {
            return 0
        }
        let trimmed = cleaned.count > 2 ? String(cleaned.suffix(2)) : cleaned
        return Int(trimmed, radix: 16) ?? 0
    }

    private static func modifiedJulianDay(year: Int, month: Int, day: Int) -> Int {
        var y = year
        var m = month
        if m <= 2 {
            y -= 1
            m += 12
        }
        let a = y / 100
        let b = 2 - a + (a / 4)
        let jd = Int(
            Double(Int(365.25 * Double(y + 4716)))
                + Double(Int(30.6001 * Double(m + 1)))
                + Double(day + b) - 1524.5)
        return jd - 2_400_001
    }

    private static func parseRTPlusTags(
        text: String,
        format: String,
        snapshot: NowPlayingSnapshot? = nil
    ) -> [RTPlusTag] {
        if text.isEmpty {
            return []
        }
        if let snapshot, snapshot.hasContent, format.isEmpty {
            return parseRTPlusTagsFromSnapshot(text: text, snapshot: snapshot)
        }
        if format.isEmpty {
            return []
        }

        var escaped = NSRegularExpression.escapedPattern(for: format)
        let nowPlayingPattern = capturePattern(
            name: "now_playing",
            exactValue: snapshot?.display
        )
        let displayPattern = capturePattern(
            name: "display",
            exactValue: snapshot?.display
        )
        let artistPattern = capturePattern(
            name: "artist",
            exactValue: snapshot?.artist
        )
        let titlePattern = capturePattern(
            name: "title",
            exactValue: snapshot?.title
        )
        escaped = escaped.replacingOccurrences(
            of: "\\{now_playing\\}", with: nowPlayingPattern)
        escaped = escaped.replacingOccurrences(of: "\\{display\\}", with: displayPattern)
        escaped = escaped.replacingOccurrences(of: "\\{artist\\}", with: artistPattern)
        escaped = escaped.replacingOccurrences(of: "\\{title\\}", with: titlePattern)
        guard let regex = try? NSRegularExpression(pattern: escaped, options: []) else {
            return []
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else {
            return []
        }

        func makeTag(name: String, contentType: Int) -> RTPlusTag? {
            let range = match.range(withName: name)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            let start = max(0, min(63, range.location))
            let length = max(1, min(64 - start, range.length))
            return RTPlusTag(contentType: contentType, start: start, length: length)
        }

        var tags: [RTPlusTag] = []
        if let titleTag = makeTag(name: "title", contentType: 1) {
            tags.append(titleTag)
        }
        if tags.isEmpty, let nowPlayingTag = makeTag(name: "now_playing", contentType: 1) {
            tags.append(nowPlayingTag)
        }
        if tags.isEmpty, let displayTag = makeTag(name: "display", contentType: 1) {
            tags.append(displayTag)
        }
        if let artistTag = makeTag(name: "artist", contentType: 4) {
            tags.append(artistTag)
        }
        // Order so the longer element becomes tag 1: the 11A tag-2 length
        // marker is only 5 bits (max 32 chars), while tag 1 is 6 bits (max 64).
        // Putting the longer element (e.g. a long title) in tag 1 avoids
        // clipping it to 32 chars; per the RT+ spec at most one element may
        // exceed 32 chars, so this guarantees it lands in tag 1. Tag order
        // within the group does not affect receivers -- each tag carries its
        // own content type, start and length.
        return tags.sorted {
            if $0.length != $1.length {
                return $0.length > $1.length
            }
            if $0.start != $1.start {
                return $0.start < $1.start
            }
            return $0.contentType < $1.contentType
        }
    }

    private static func expandNowPlayingMacros(_ text: String, snapshot: NowPlayingSnapshot) -> String {
        NowPlayingFormatter.expandTemplate(text, snapshot: snapshot)
    }

    private static func capturePattern(name: String, exactValue: String?) -> String {
        let trimmed = exactValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "(?<\(name)>.+?)"
        }
        let escapedValue = NSRegularExpression.escapedPattern(for: trimmed)
        return "(?<\(name)>\(escapedValue))"
    }

    private static func parseRTPlusTagsFromSnapshot(
        text: String,
        snapshot: NowPlayingSnapshot
    ) -> [RTPlusTag] {
        let nsText = text as NSString

        func firstTag(for value: String, contentType: Int) -> RTPlusTag? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let range = nsText.range(of: trimmed)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            let start = max(0, min(63, range.location))
            let length = max(1, min(64 - start, range.length))
            return RTPlusTag(contentType: contentType, start: start, length: length)
        }

        var tags: [RTPlusTag] = []
        if let artistTag = firstTag(for: snapshot.artist, contentType: 4) {
            tags.append(artistTag)
        }
        if let titleTag = firstTag(for: snapshot.title, contentType: 1) {
            tags.append(titleTag)
        } else if let displayTag = firstTag(for: snapshot.display, contentType: 1) {
            tags.append(displayTag)
        }

        // Order so the longer element becomes tag 1: the 11A tag-2 length
        // marker is only 5 bits (max 32 chars), while tag 1 is 6 bits (max 64).
        // Putting the longer element (e.g. a long title) in tag 1 avoids
        // clipping it to 32 chars; per the RT+ spec at most one element may
        // exceed 32 chars, so this guarantees it lands in tag 1. Tag order
        // within the group does not affect receivers -- each tag carries its
        // own content type, start and length.
        return tags.sorted {
            if $0.length != $1.length {
                return $0.length > $1.length
            }
            if $0.start != $1.start {
                return $0.start < $1.start
            }
            return $0.contentType < $1.contentType
        }
    }
}
