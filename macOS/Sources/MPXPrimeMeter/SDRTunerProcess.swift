import Darwin
import Foundation

// Spawns the external FM-SDR-Tuner (an RTL-SDR FM tuner) and streams its mono
// MPX composite into the meter over a FIFO -- the GUI equivalent of
// run-meter-sdr.sh. The tuner writes a 16-bit / 192 kHz WAV stream to the FIFO;
// `StdinInputSource(fifoPath:)` reads it. Locating the binary mirrors the
// script: FM_SDR_TUNER env override, then ./bin/fm-sdr-tuner (CWD), then the
// sibling FM-SDR-Tuner build dir under $HOME.
final class SDRTunerProcess {
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

        let token = UUID().uuidString.prefix(8)
        let tmp = NSTemporaryDirectory()
        self.fifoPath = (tmp as NSString).appendingPathComponent("mpxprime-mpx-\(token).fifo")
        self.logPath = (tmp as NSString).appendingPathComponent("fm-sdr-tuner-\(token).log")
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
        if let env = ProcessInfo.processInfo.environment["FM_SDR_TUNER"], !env.isEmpty {
            paths.append(env)
        }
        let cwd = FileManager.default.currentDirectoryPath
        paths.append((cwd as NSString).appendingPathComponent("bin/fm-sdr-tuner"))
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
        process.arguments = [
            "-f", "\(frequencyKHz)",
            "--auto-start",
            "--no-audio",
            "--mpx-wav", fifoPath,
            "--mpx-rate", "\(mpxRate)"
        ]
        if let log {
            process.standardOutput = log
            process.standardError = log
        }
        try process.run()
    }

    /// Terminate the tuner and remove the FIFO. Idempotent / best-effort.
    func stop() {
        if process.isRunning {
            process.terminate()
            // Give it a moment to release the SDR + close the FIFO write end.
            process.waitUntilExit()
        }
        unlink(fifoPath)
    }
}

private extension FileHandle {
    /// Open (creating/truncating) a file for writing; nil on failure.
    static func forWritingToFile(path: String) -> FileHandle? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
}
