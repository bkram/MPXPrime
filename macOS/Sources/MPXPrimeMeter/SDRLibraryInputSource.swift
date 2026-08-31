import CMPXTuner
import Darwin
import Foundation

// In-process RTL-SDR input: opens the device through the linked CMPXTuner C
// library (no subprocess, no FIFO) and forwards the float MPX blocks its
// capture thread delivers straight to the engine's `frameSink`. Replaces the
// old SDRTunerProcess + StdinInputSource(fifoPath:) pipe. The library is
// statically linked into the (Apple-Silicon-only) Meter, so SDR is always
// available; `start()` throws if no dongle is present.
//
// Calibration matches the former WAV path: the library scales samples so 1.0
// == 150 kHz deviation (the -6 dB headroom), and the engine is configured with
// `fullScaleKHz: 150`, so PILOT / RDS / MAX stay absolute measurements.
//
// `@unchecked Sendable`: `frameSink` is set on the main thread before start()
// and not mutated afterwards; `handle` is created/destroyed on the main thread
// and the C callback only reads `frameSink`.
final class SDRLibraryInputSource: MPXInputSource, @unchecked Sendable {
    enum SDRError: LocalizedError {
        case openFailed(String)
        var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "SDR start failed: \(msg)"
            }
        }
    }

    struct Config {
        var frequencyKHz: Int
        var mpxRate: Int = 192_000
        var autoGain: Bool = true
        var gainDB: Double = 30.0
        var bandwidthKHz: Int = 0   // 0 = auto / widest (full MPX)
        var biasTee: Bool = false
        var ppm: Int = 0
        var rtlAGC: Bool = false
        var antenna: Int = 0   // SDRplay antenna input index
        var lna: Int = 4       // SDRplay LNA state (front-end gain reduction step)
        /// Device selection: backend 0 = auto (SDRplay preferred), 1 = RTL-SDR,
        /// 2 = SDRplay; a non-empty serial pins the exact unit (multi-SDR
        /// benches -- selection persists by serial across replug/reorder).
        var deviceBackend: Int = 0
        var deviceSerial: String = ""
        /// IQ capture rate in kHz; 0 = the narrow default. This widens the RF
        /// SPECTRUM SPAN only -- the FM demod chain always runs at its own
        /// 250/256 kHz behind a decimator, so it cannot move the MPX
        /// measurements. Restart-required (the device is reconfigured at open).
        var iqRateKHz: Int = 0
    }

    /// One attached SDR (either backend), for the device picker.
    struct DeviceInfo: Identifiable, Hashable {
        let backend: Int       // 1 = RTL-SDR, 2 = SDRplay
        let index: Int
        let name: String
        let serial: String
        /// Stable identity: backend + serial (index as a fallback for units
        /// with blank serials).
        var id: String { "\(backend):\(serial.isEmpty ? "#\(index)" : serial)" }
        var isSDRplay: Bool { backend == 2 }
        var displayName: String {
            serial.isEmpty ? name : "\(name) (\(serial))"
        }
    }

    /// Enumerate attached SDRs across both backends (SDRplay first).
    static func listDevices() -> [DeviceInfo] {
        var raw = [MpxTunerDeviceInfo](repeating: MpxTunerDeviceInfo(), count: 16)
        let n = raw.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return mpxtuner_list_devices(base, Int32(buf.count))
        }
        return (0..<Int(n)).map { i in
            var info = raw[i]
            let name = withUnsafeBytes(of: &info.name) { ptr -> String in
                guard let base = ptr.bindMemory(to: CChar.self).baseAddress else { return "SDR" }
                return String(cString: base)
            }
            let serial = withUnsafeBytes(of: &info.serial) { ptr -> String in
                guard let base = ptr.bindMemory(to: CChar.self).baseAddress else { return "" }
                return String(cString: base)
            }
            return DeviceInfo(backend: Int(info.backend), index: Int(info.index),
                              name: name, serial: serial)
        }
    }

    var frameSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?

    /// Deliberately unused: the tuner's capture thread must not stall (its IQ
    /// ring would overflow one layer down instead, and that gap is what
    /// `mpxtuner_iq_drops()` reports). The composite ring's own overflow
    /// counter covers this path.
    var canAcceptFrames: (() -> Bool)?

    private let config: Config
    private let assumedRate: Double
    private var handle: OpaquePointer?

    init(config: Config) {
        self.config = config
        self.assumedRate = Double(config.mpxRate)
    }

    /// True while the capture thread is alive; false once the device is lost
    /// (the GUI polls this to surface an unplug).
    var isRunning: Bool {
        guard let handle else { return false }
        return mpxtuner_is_alive(handle) != 0
    }

    /// Latest filtered-channel signal level in dBFS (relative RSSI; <= 0).
    var signalDBFS: Double {
        guard let handle else { return -120 }
        return mpxtuner_signal_dbfs(handle)
    }

    /// Total gain currently in effect (dB). SDRplay reports its own "system
    /// gain", updated on every change including the AGC's own -- so a power
    /// reading derived from it stays correct with auto gain running. RTL
    /// reports its tuner stage only. nil when unknown.
    var systemGainDB: Double? {
        guard let handle else { return nil }
        let g = mpxtuner_system_gain_db(handle)
        return g <= -999.0 ? nil : g
    }

    /// IQ samples the tuner lost since it opened, because the demod thread
    /// fell behind and the IQ ring overwrote unread data. Monotonic; deliberate
    /// retune flushes are not counted. Non-zero means a gap is baked into the
    /// accumulated measurements, which is why the Meter raises SAMPLES DROPPED
    /// on it (before 0.45 the SDRplay ring counted nothing and RTL's counter
    /// was a function-local static nothing could read).
    var droppedIQSamples: UInt64 {
        guard let handle else { return 0 }
        return mpxtuner_iq_drops(handle)
    }

    /// IQ capture rate actually in use (Hz) -- may differ from the requested
    /// one if the device refused it. This is the RF spectrum's total span.
    var captureRateHz: Int {
        guard let handle else { return 0 }
        return Int(mpxtuner_capture_rate(handle))
    }

    /// Copy the latest RF spectrum frame (dB bins, fftshifted: index 0 is the
    /// low edge of the span, the centre index is the tuned frequency) into
    /// `bins`. Returns the number written and the span in Hz; 0 before the
    /// first frame. Safe to call from the display thread.
    @discardableResult
    func rfSpectrum(into bins: inout [Float]) -> (count: Int, spanHz: Double) {
        guard let handle, !bins.isEmpty else { return (0, 0) }
        var span: Double = 0
        let n = bins.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return mpxtuner_rf_spectrum(handle, base, Int32(buf.count), &span)
        }
        return (Int(n), span)
    }

    /// True when the active backend is an SDRplay RSP (vs RTL-SDR).
    var isSDRplay: Bool {
        guard let handle else { return false }
        return mpxtuner_backend(handle) != 0
    }

    /// Number of selectable antenna inputs (1 = none / RTL).
    var antennaCount: Int {
        guard let handle else { return 1 }
        return Int(mpxtuner_antenna_count(handle))
    }

    /// Serial of the ACTIVE device ("" if unknown) -- lets the picker list
    /// the in-use unit even when backend enumeration hides it (SDRplay
    /// GetDevices omits selected devices).
    var deviceSerial: String {
        guard let handle else { return "" }
        var buf = [CChar](repeating: 0, count: 64)
        buf.withUnsafeMutableBufferPointer { mpxtuner_device_serial(handle, $0.baseAddress, $0.count) }
        return buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return "" }
            return String(cString: base)
        }
    }

    /// Human device name, e.g. "SDRplay RSPdx" or "RTL-SDR R820T".
    var deviceName: String {
        guard let handle else { return "SDR" }
        var buf = [CChar](repeating: 0, count: 64)
        buf.withUnsafeMutableBufferPointer { mpxtuner_device_name(handle, $0.baseAddress, $0.count) }
        return buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return "SDR" }
            return String(cString: base)
        }
    }

    /// The library is always linked into the Meter, so SDR is always offered;
    /// device presence is reported by `start()`.
    static func isAvailable() -> Bool { true }

    /// Number of RTL-SDR dongles currently attached (cheap USB enumeration,
    /// does not open a device). Used to default the input source to SDR when a
    /// dongle is present at launch.
    static func deviceCount() -> Int { Int(mpxtuner_device_count()) }

    /// True if an SDRplay RSP is attached (so the auto-selected backend will be
    /// SDRplay) -- lets the UI show the right SDR controls before capture.
    static func sdrplayPresent() -> Bool { mpxtuner_sdrplay_present() != 0 }

    @discardableResult
    func start() throws -> (sampleRate: Double, channels: Int) {
        var cfg = MpxTunerConfig()
        cfg.device_index = 0
        cfg.freq_khz = UInt32(max(0, config.frequencyKHz))
        cfg.mpx_rate = UInt32(config.mpxRate)
        cfg.mpx_gain_db = -6.0   // full scale = 150 kHz, matches fullScaleKHz: 150
        cfg.gain_db = config.gainDB
        cfg.auto_gain = config.autoGain ? 1 : 0
        cfg.bandwidth_khz = Int32(config.bandwidthKHz)
        cfg.bias_tee = config.biasTee ? 1 : 0
        cfg.ppm = Int32(config.ppm)
        cfg.rtl_agc = config.rtlAGC ? 1 : 0
        cfg.antenna = Int32(config.antenna)
        cfg.lna = Int32(config.lna)
        cfg.backend = Int32(config.deviceBackend)
        cfg.iq_rate_khz = UInt32(max(0, config.iqRateKHz))
        withUnsafeMutableBytes(of: &cfg.device_serial) { ptr in
            let bytes = Array(config.deviceSerial.utf8.prefix(63))
            ptr.copyBytes(from: bytes)
            ptr[bytes.count] = 0
        }

        var errBuf = [CChar](repeating: 0, count: 256)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let opened: OpaquePointer? = withUnsafePointer(to: &cfg) { cfgPtr in
            errBuf.withUnsafeMutableBufferPointer { eb in
                mpxtuner_open(cfgPtr, sdrSampleTrampoline, ctx, eb.baseAddress, eb.count)
            }
        }
        guard let opened else {
            let msg = errBuf.withUnsafeBufferPointer { ptr -> String in
                guard let base = ptr.baseAddress else { return "device open failed" }
                return String(cString: base)
            }
            throw SDRError.openFailed(msg)
        }
        handle = opened
        return (assumedRate, 1)
    }

    func stop() {
        if let handle {
            mpxtuner_close(handle)  // joins the capture thread; no callback after this
            self.handle = nil
        }
    }

    deinit {
        // The tuner callback holds an UNRETAINED pointer to this object, so a
        // source released without an explicit stop() -- a failed start, a view
        // model dropping it -- left the capture thread calling into freed
        // memory. `stop()` is idempotent and joins that thread (audit B15).
        stop()
    }

    /// Termination-time variant: skips the register-writing RTL device close
    /// (a dead USB handle SEGVs in libusb; the kernel releases the claim as
    /// the process exits).
    func stopForTermination() {
        if let handle {
            mpxtuner_close_fast(handle)
            self.handle = nil
        }
    }

    // MARK: - Live control (applied on the capture thread, no restart)

    func setFrequencyKHz(_ khz: Int) {
        if let handle { mpxtuner_set_frequency_khz(handle, UInt32(max(0, khz))) }
    }
    /// Manual gain in dB (also switches the tuner to manual gain mode).
    func setGainDB(_ db: Double) { if let handle { mpxtuner_set_gain_db(handle, db) } }
    func setGainAuto(_ on: Bool) { if let handle { mpxtuner_set_gain_auto(handle, on ? 1 : 0) } }
    func setBandwidthKHz(_ khz: Int) { if let handle { mpxtuner_set_bandwidth_khz(handle, Int32(khz)) } }
    func setBiasTee(_ on: Bool) { if let handle { mpxtuner_set_bias_tee(handle, on ? 1 : 0) } }
    func setPPM(_ ppm: Int) { if let handle { mpxtuner_set_ppm(handle, Int32(ppm)) } }
    func setRTLAGC(_ on: Bool) { if let handle { mpxtuner_set_rtl_agc(handle, on ? 1 : 0) } }
    func setAntenna(_ index: Int) { if let handle { mpxtuner_set_antenna(handle, Int32(index)) } }
    func setLnaState(_ state: Int) { if let handle { mpxtuner_set_lna(handle, Int32(state)) } }
}

// C sample callback: forward the mono MPX block to the source's frameSink
// (mono -> same pointer for both channels). Top-level non-capturing function so
// Swift bridges it to a C function pointer.
private func sdrSampleTrampoline(
    _ samples: UnsafePointer<Float>?, _ count: Int, _ ctx: UnsafeMutableRawPointer?
) {
    guard let samples, let ctx, count > 0 else { return }
    let source = Unmanaged<SDRLibraryInputSource>.fromOpaque(ctx).takeUnretainedValue()
    source.frameSink?(samples, samples, count)
}
