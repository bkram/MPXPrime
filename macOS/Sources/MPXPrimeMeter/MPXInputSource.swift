import Atomics
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore

/// Abstraction over a source of MPX composite samples. The AUHAL audio backend
/// and a stdin/pipe backend conform today; a future SDR backend (rtl-sdr ->
/// composite samples) conforms the same way. The source is fully configured at
/// construction; `start()` returns the stream's sample rate and channel count.
protocol MPXInputSource: AnyObject {
    /// Invoked from the capture thread with planar L/R frames. The composite is
    /// a single real signal; mono sources pass the same pointer for both.
    /// Pointers are valid only for the duration of the call.
    var frameSink: ((_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ frames: Int) -> Void)? { get set }
    var isRunning: Bool { get }

    @discardableResult
    func start() throws -> (sampleRate: Double, channels: Int)
    func stop()
}

/// Core Audio AUHAL backend (TN2091), wrapping the shared `InputAUHAL`.
final class AUHALInputSource: MPXInputSource {
    private let au = InputAUHAL()
    private let deviceID: AudioDeviceID
    private let maxFramesPerSlice: Int

    init(deviceID: AudioDeviceID, maxFramesPerSlice: Int = 4096) {
        self.deviceID = deviceID
        self.maxFramesPerSlice = maxFramesPerSlice
    }

    var frameSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)? {
        get { au.frameSink }
        set { au.frameSink = newValue }
    }

    var isRunning: Bool { au.isRunning }

    @discardableResult
    func start() throws -> (sampleRate: Double, channels: Int) {
        let fmt = try au.start(deviceID: deviceID, maxFramesPerSlice: maxFramesPerSlice)
        return (fmt.deviceSampleRate, fmt.deviceChannelCount)
    }

    func stop() { au.stop() }
}

/// Reads a mono MPX composite from a file descriptor (default stdin / a FIFO).
/// Accepts a canonical WAV stream (skips the header) or raw little-endian
/// int16 PCM. Used to pipe an external tuner's MPX output into the meter.
///
/// `@unchecked Sendable`: the cross-thread state is the two atomic flags
/// (`runningFlag` / `finishedFlag`); `frameSink` and `thread` are set on the
/// main thread before the reader thread starts and not mutated afterwards.
final class StdinInputSource: MPXInputSource, @unchecked Sendable {
    private let fd: Int32
    private let assumedRate: Double
    /// When set, the reader thread opens this FIFO itself (non-blocking) instead
    /// of reading `fd`. Used by the GUI's SDR path: the tuner subprocess is the
    /// writer and may not have opened its end yet when the meter starts, so we
    /// poll until samples appear rather than blocking the open. nil = read `fd`
    /// (the `--stdin` CLI path, fd 0).
    private let fifoPath: String?

    var frameSink: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)?

    // Cross-thread flags (read on the CLI/main thread, written on the reader
    // thread): atomic to avoid a data race on the shared Bool.
    private let runningFlag = ManagedAtomic<Bool>(false)
    private let finishedFlag = ManagedAtomic<Bool>(false)
    private var thread: Thread?
    /// True once the source reaches EOF (writer closed) -- the CLI loop exits.
    var finished: Bool { finishedFlag.load(ordering: .relaxed) }

    init(fileDescriptor: Int32 = 0, sampleRate: Double) {
        self.fd = fileDescriptor
        self.assumedRate = sampleRate
        self.fifoPath = nil
    }

    /// Read the MPX stream from a named FIFO the reader thread opens itself.
    init(fifoPath: String, sampleRate: Double) {
        self.fd = -1
        self.assumedRate = sampleRate
        self.fifoPath = fifoPath
    }

    var isRunning: Bool { runningFlag.load(ordering: .relaxed) }

    @discardableResult
    func start() throws -> (sampleRate: Double, channels: Int) {
        runningFlag.store(true, ordering: .relaxed)
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "com.mpxprime.meter.stdin"
        t.qualityOfService = .userInitiated
        t.start()
        thread = t
        return (assumedRate, 1)
    }

    func stop() { runningFlag.store(false, ordering: .relaxed) }

    private func readLoop() {
        let readChunk = 16384
        var raw = [UInt8](repeating: 0, count: readChunk)
        // Pending odd byte that didn't complete an int16 sample.
        var pendingByte: UInt8?
        var hasPendingByte = false
        var headerHandled = false
        var headerScan = [UInt8]()
        var floatScratch = [Float](repeating: 0.0, count: readChunk / 2 + 2)

        // FIFO path: open our own non-blocking read end so the open never
        // stalls the thread before the tuner (the writer) appears.
        var readFD = fd
        let ownsFD: Bool
        if let path = fifoPath {
            readFD = open(path, O_RDONLY | O_NONBLOCK)
            if readFD < 0 {
                finishedFlag.store(true, ordering: .relaxed)
                runningFlag.store(false, ordering: .relaxed)
                return
            }
            ownsFD = true
        } else {
            ownsFD = false
        }
        defer { if ownsFD { close(readFD) } }
        // Only treat a 0-byte read / hangup as EOF once the writer has actually
        // delivered samples; before that it just means "tuner not up yet".
        var sawData = false

        while runningFlag.load(ordering: .relaxed) {
            let got: Int
            if ownsFD {
                var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                let pr = poll(&pfd, 1, 200)  // 200 ms: lets stop() be observed
                if pr <= 0 { continue }      // timeout / EINTR -> recheck running
                if (Int32(pfd.revents) & POLLIN) == 0 {
                    // Hangup with no data: real EOF only after we've seen samples.
                    if sawData { break }
                    usleep(100_000)
                    continue
                }
                got = raw.withUnsafeMutableBytes { read(readFD, $0.baseAddress, readChunk) }
                if got < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    break
                }
                if got == 0 {
                    if sawData { break }
                    usleep(100_000)
                    continue
                }
                sawData = true
            } else {
                got = raw.withUnsafeMutableBytes { read(readFD, $0.baseAddress, readChunk) }
                if got <= 0 { break }
            }
            var sampleBytesStart = 0
            var bytes = Array(raw[0..<got])

            // One-time WAV-header skip: a canonical RIFF/WAVE stream begins with
            // "RIFF"...."WAVE" and a "data" chunk; sample data starts 8 bytes
            // after the "data" tag. Anything not starting with "RIFF" is raw.
            if !headerHandled {
                headerScan.append(contentsOf: bytes)
                if headerScan.count < 4 { continue }
                if headerScan[0] == 0x52, headerScan[1] == 0x49,
                   headerScan[2] == 0x46, headerScan[3] == 0x46 {  // "RIFF"
                    guard let d = findData(headerScan) else { continue }
                    headerHandled = true
                    bytes = Array(headerScan[(d + 8)...])
                    sampleBytesStart = 0
                    headerScan = []
                } else {
                    headerHandled = true
                    bytes = headerScan
                    headerScan = []
                }
            }
            _ = sampleBytesStart

            // Convert little-endian int16 -> float, carrying any odd byte that
            // splits an int16 across reads.
            var idx = 0
            var outCount = 0
            if hasPendingByte, let pb = pendingByte, !bytes.isEmpty {
                let s = Int16(bitPattern: UInt16(pb) | (UInt16(bytes[0]) << 8))
                floatScratch[outCount] = Float(s) / 32768.0
                outCount += 1
                idx = 1
                hasPendingByte = false
                pendingByte = nil
            }
            while idx + 1 < bytes.count {
                let s = Int16(bitPattern: UInt16(bytes[idx]) | (UInt16(bytes[idx + 1]) << 8))
                floatScratch[outCount] = Float(s) / 32768.0
                outCount += 1
                idx += 2
            }
            if idx == bytes.count - 1 {  // one trailing byte
                pendingByte = bytes[idx]
                hasPendingByte = true
            }

            if outCount > 0, let sink = frameSink {
                floatScratch.withUnsafeBufferPointer { bp in
                    if let base = bp.baseAddress {
                        sink(base, base, outCount)  // mono: same buffer both channels
                    }
                }
            }
        }
        // The loop exits either on stop() (runningFlag cleared by another thread
        // -- not EOF) or on a read EOF / FIFO hangup (break). Mark finished so
        // the CLI loop / GUI can observe the stream ended, and clear running.
        finishedFlag.store(true, ordering: .relaxed)
        runningFlag.store(false, ordering: .relaxed)
    }

    /// Locate the "data" chunk tag in an accumulated WAV header. Returns its
    /// byte offset, or nil if not yet present.
    private func findData(_ buf: [UInt8]) -> Int? {
        guard buf.count >= 12 else { return nil }
        var i = 12
        while i + 8 <= buf.count {
            if buf[i] == 0x64, buf[i + 1] == 0x61, buf[i + 2] == 0x74, buf[i + 3] == 0x61 {  // "data"
                return i
            }
            let sz = UInt32(buf[i + 4]) | (UInt32(buf[i + 5]) << 8)
                | (UInt32(buf[i + 6]) << 16) | (UInt32(buf[i + 7]) << 24)
            i += 8 + Int(sz)
        }
        return nil
    }
}
