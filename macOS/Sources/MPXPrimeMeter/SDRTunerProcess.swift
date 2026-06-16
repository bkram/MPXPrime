import Darwin
import Foundation

// Spawns the external FM-SDR-Tuner (an RTL-SDR FM tuner) and streams its mono
// MPX composite into the meter over a FIFO -- the GUI equivalent of
// run-meter-sdr.sh. The tuner writes a 16-bit / 192 kHz WAV stream to the FIFO;
// `StdinInputSource(fifoPath:)` reads it. Locating the binary mirrors the
// script: FM_SDR_TUNER env override, then ./bin/fm-sdr-tuner (CWD), then the
// sibling FM-SDR-Tuner build dir under $HOME.
// @unchecked Sendable: the only state touched off the main thread is the
// control FIFO write (controlFD + controlPath), and that is confined to the
// serial `controlQueue`. `process` and the paths are set up on the main thread
// before any background work and not mutated concurrently.
final class SDRTunerProcess: @unchecked Sendable {
    enum SDRError: LocalizedError {
        case binaryNotFound(triedPaths: [String])
        case fifoCreateFailed(path: String, errno: Int32)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let tried):
                return "FM-SDR-Tuner binary not found. Place it in bin/ or set "
                    + "FM_SDR_TUNER. Tried: \(tried.joined(separator: ", "))"
            case .fifoCreateFailed(let path, let err):
                return "Could not create FIFO at \(path): \(String(cString: strerror(err)))"
            }
        }
    }

    /// FIFO the tuner writes the MPX WAV stream to (read by StdinInputSource).
    let fifoPath: String
    /// Tuner stdout/stderr log (so the WAV stream on the FIFO stays clean).
    let logPath: String

    private let binaryPath: String
    private let frequencyKHz: Int
    private let mpxRate = 192_000
    private let process = Process()

    /// The vendored `mpx-tuner` accepts a live-control FIFO; the external
    /// `fm-sdr-tuner` does not (so the GUI restarts it on a frequency change).
    let supportsLiveControl: Bool
    /// FIFO carrying live commands (freq/gain/gainmode) to the helper.
    private let controlPath: String
    private let controlQueue = DispatchQueue(label: "com.mpxprime.meter.sdrcontrol")
    private var controlFD: Int32 = -1

    /// - Throws: `SDRError.binaryNotFound` if no tuner binary resolves.
    init(frequencyKHz: Int) throws {
        self.frequencyKHz = frequencyKHz
        let candidates = SDRTunerProcess.candidatePaths()
        guard let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw SDRError.binaryNotFound(triedPaths: candidates)
        }
        self.binaryPath = found
        self.supportsLiveControl = (found as NSString).lastPathComponent == "mpx-tuner"

        let token = UUID().uuidString.prefix(8)
        let tmp = NSTemporaryDirectory()
        self.fifoPath = (tmp as NSString).appendingPathComponent("mpxprime-mpx-\(token).fifo")
        self.logPath = (tmp as NSString).appendingPathComponent("fm-sdr-tuner-\(token).log")
        self.controlPath = (tmp as NSString).appendingPathComponent("mpxprime-ctl-\(token).fifo")
    }

    /// False once the tuner subprocess has exited (e.g. no RTL-SDR found, or it
    /// lost the device). The GUI polls this to surface an early exit.
    var isRunning: Bool { process.isRunning }

    /// Whether a tuner binary is resolvable -- lets the UI enable/disable SDR.
    static func isAvailable() -> Bool {
        candidatePaths().contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func candidatePaths() -> [String] {
        var paths: [String] = []
        // Explicit dev override always wins.
        if let env = ProcessInfo.processInfo.environment["FM_SDR_TUNER"], !env.isEmpty {
            paths.append(env)
        }
        // The bundled, self-contained helper inside the shipped .app
        // (Contents/Helpers/mpx-tuner) -- absent for an unbundled `swift run`.
        paths.append((Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/Helpers/mpx-tuner"))
        // Dev fallbacks: a local bin/ copy, then a sibling FM-SDR-Tuner build.
        let cwd = FileManager.default.currentDirectoryPath
        paths.append((cwd as NSString).appendingPathComponent("bin/fm-sdr-tuner"))
        paths.append((cwd as NSString).appendingPathComponent("tuner/build/mpx-tuner"))
        let home = NSHomeDirectory()
        paths.append((home as NSString)
            .appendingPathComponent("Projects/git/FM-SDR-Tuner/build/fm-sdr-tuner"))
        return paths
    }

    /// Create the FIFO and launch the tuner. The tuner opens the FIFO's write
    /// end once it has locked the station (~1-3 s); the reader polls until then.
    func start() throws {
        unlink(fifoPath)
        if mkfifo(fifoPath, 0o600) != 0 {
            throw SDRError.fifoCreateFailed(path: fifoPath, errno: errno)
        }

        let log = FileHandle.forWritingToFile(path: logPath)

        process.executableURL = URL(fileURLWithPath: binaryPath)
        // The bundled `mpx-tuner` and the full `fm-sdr-tuner` take different
        // flags for "write MPX to this FIFO at this rate". mpx-tuner also
        // accepts a live-control FIFO.
        if supportsLiveControl {
            unlink(controlPath)
            _ = mkfifo(controlPath, 0o600)  // best-effort; control is optional
            process.arguments = [
                "-f", "\(frequencyKHz)",
                "-o", fifoPath,
                "--control", controlPath,
                "--mpx-rate", "\(mpxRate)"
            ]
        } else {
            process.arguments = [
                "-f", "\(frequencyKHz)",
                "--auto-start",
                "--no-audio",
                "--mpx-wav", fifoPath,
                "--mpx-rate", "\(mpxRate)"
            ]
        }
        if let log {
            process.standardOutput = log
            process.standardError = log
        }
        try process.run()

        // Open the control FIFO's write end once the helper's reader is up.
        // O_WRONLY|O_NONBLOCK returns ENXIO until then, so retry briefly on a
        // background queue (never blocks the UI; bounded so a dead helper can't
        // hang us).
        if supportsLiveControl {
            controlQueue.async { [weak self] in
                guard let self else { return }
                for _ in 0..<40 {  // ~2 s
                    let fd = open(self.controlPath, O_WRONLY | O_NONBLOCK)
                    if fd >= 0 { self.controlFD = fd; return }
                    usleep(50_000)
                }
            }
        }
    }

    // MARK: - Live control (mpx-tuner only)

    func setFrequencyKHz(_ khz: Int) { sendControl("freq \(khz)") }
    /// Manual gain in dB (also switches the tuner to manual gain mode).
    func setGainDB(_ db: Double) { sendControl(String(format: "gain %.1f", db)) }
    func setGainAuto(_ auto: Bool) { sendControl("gainmode \(auto ? "auto" : "manual")") }

    private func sendControl(_ command: String) {
        guard supportsLiveControl else { return }
        controlQueue.async { [weak self] in
            guard let self, self.controlFD >= 0 else { return }
            let line = command + "\n"
            _ = line.utf8CString.withUnsafeBufferPointer { buf in
                // Drop the trailing NUL; write the bytes only.
                write(self.controlFD, buf.baseAddress, buf.count - 1)
            }
        }
    }

    /// Terminate the tuner and remove the FIFOs. Idempotent / best-effort.
    func stop() {
        controlQueue.sync {
            if controlFD >= 0 { close(controlFD); controlFD = -1 }
        }
        if process.isRunning {
            process.terminate()
            // Give it a moment to release the SDR + close the FIFO write end.
            process.waitUntilExit()
        }
        unlink(fifoPath)
        unlink(controlPath)
    }
}

private extension FileHandle {
    /// Open (creating/truncating) a file for writing; nil on failure.
    static func forWritingToFile(path: String) -> FileHandle? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
}
