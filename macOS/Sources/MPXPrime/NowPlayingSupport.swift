import Foundation

struct NowPlayingSnapshot {
    var display: String
    var artist: String
    var title: String
    var revision: UInt64

    static let empty = NowPlayingSnapshot(display: "", artist: "", title: "", revision: 0)

    var hasContent: Bool {
        !display.isEmpty || !artist.isEmpty || !title.isEmpty
    }
}

final class NowPlayingState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = NowPlayingSnapshot.empty

    func currentSnapshot() -> NowPlayingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func update(display: String, artist: String, title: String) {
        lock.lock()
        defer { lock.unlock() }
        if snapshot.display == display && snapshot.artist == artist && snapshot.title == title {
            return
        }
        snapshot = NowPlayingSnapshot(
            display: display,
            artist: artist,
            title: title,
            revision: snapshot.revision &+ 1
        )
    }

    func clear() {
        update(display: "", artist: "", title: "")
    }
}

enum NowPlayingFormatter {
    static func expandTemplate(_ template: String, snapshot: NowPlayingSnapshot) -> String {
        let filteredTemplate = filterEmptyNowPlayingSegments(template, snapshot: snapshot)
        let now = Date()
        return filteredTemplate
            .replacingOccurrences(of: "{now_playing}", with: snapshot.display)
            .replacingOccurrences(of: "{display}", with: snapshot.display)
            .replacingOccurrences(of: "{artist}", with: snapshot.artist)
            .replacingOccurrences(of: "{title}", with: snapshot.title)
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: now))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: now))
    }

    static func normalizeScriptPath(_ rawPath: String) -> String {
        // Empty means "no script" and must never resolve to a directory: the
        // relative-path branch below would turn "" into the launch directory
        // itself, which the 0.43 poller bug then tried to EXECUTE every poll
        // (failing, and clearing any API-pushed track). The call site guards
        // this too; keep the helper safe for the next caller.
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let pathNSString = expanded as NSString
        if pathNSString.isAbsolutePath {
            return pathNSString.standardizingPath
        }
        let launchDirectory =
            ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
        let combined = (launchDirectory as NSString).appendingPathComponent(expanded)
        return (combined as NSString).standardizingPath
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func filterEmptyNowPlayingSegments(
        _ template: String,
        snapshot: NowPlayingSnapshot
    ) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to filter if the template references no now-playing macro
        // ({time}/{date}-only or static text passes through untouched).
        guard containsNowPlayingMacro(trimmed) else { return template }

        if trimmed.contains("/") {
            let segments = template
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            let filtered = segments.filter { segment in
                !hasUnresolvedNowPlayingMacro(segment, snapshot: snapshot)
            }
            return filtered.joined(separator: "/")
        }

        if let regex = try? NSRegularExpression(
            pattern: #"([0-9]+(?:\.[0-9]+)?)s:(.*?)(?=(?:\s+[0-9]+(?:\.[0-9]+)?s:)|$)"#,
            options: []
        ) {
            let ns = trimmed as NSString
            let matches = regex.matches(
                in: trimmed,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            )
            if !matches.isEmpty, matches[0].range.location == 0 {
                let kept = matches.compactMap { match -> String? in
                    guard match.numberOfRanges >= 3 else { return nil }
                    let duration = ns.substring(with: match.range(at: 1))
                    let text = ns.substring(with: match.range(at: 2)).trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !hasUnresolvedNowPlayingMacro(text, snapshot: snapshot) else { return nil }
                    return "\(duration)s:\(text)"
                }
                return kept.joined(separator: "/")
            }
        }

        // Plain single template: keep it only if every macro it references
        // resolves to a non-empty value; otherwise drop it entirely so we
        // never air a half-filled "Now playing:  - Title".
        return hasUnresolvedNowPlayingMacro(trimmed, snapshot: snapshot) ? "" : template
    }

    private static func containsNowPlayingMacro(_ text: String) -> Bool {
        text.contains("{now_playing}")
            || text.contains("{display}")
            || text.contains("{artist}")
            || text.contains("{title}")
    }

    /// True when `text` references a now-playing macro whose value is empty in
    /// the snapshot -- i.e. this segment can't be rendered fully, so the
    /// caller drops it (per-macro emptiness, not all-or-nothing). This is why
    /// a template like `10s:{artist} - {title}/10s:My Station` gracefully
    /// falls back to the static segment when there is no track metadata, and
    /// skips the track segment when only a partial tag (e.g. title, no artist)
    /// is available.
    private static func hasUnresolvedNowPlayingMacro(
        _ text: String, snapshot: NowPlayingSnapshot
    ) -> Bool {
        if text.contains("{artist}") && snapshot.artist.isEmpty { return true }
        if text.contains("{title}") && snapshot.title.isEmpty { return true }
        if (text.contains("{display}") || text.contains("{now_playing}"))
            && snapshot.display.isEmpty {
            return true
        }
        return false
    }
}

final class NowPlayingScriptRunner: @unchecked Sendable {
    struct Settings: Equatable {
        var enabled: Bool
        var scriptPath: String
        var pollSeconds: Double
        var timeoutSeconds: Double

        init(config: AppConfig) {
            // RDS metadata has no consumer outside MPX Output: there is no
            // composite to carry it. Polling an external script every few
            // seconds for a feed nobody transmits is exactly the kind of
            // "still running in a mode where it has no function" the 0.50
            // mode gating removes -- so the poller follows the mode, not just
            // its own enable flag.
            enabled = config.rdsNowPlayingEnabled
                && ChainFeature.rds.applies(in: config.operatingMode)
            // An empty/whitespace script means "no local script" -- keep it
            // empty. normalizeScriptPath("") would otherwise resolve to the
            // working directory (a non-empty path), which made the poller try
            // to launch the CWD, fail, and clear API-pushed now-playing state
            // every poll.
            let rawScript = config.rdsNowPlayingScript.trimmingCharacters(
                in: .whitespacesAndNewlines)
            scriptPath = rawScript.isEmpty
                ? ""
                : NowPlayingFormatter.normalizeScriptPath(config.rdsNowPlayingScript)
            pollSeconds = max(1.0, min(300.0, config.rdsNowPlayingPollSeconds))
            timeoutSeconds = max(0.2, min(30.0, config.rdsNowPlayingTimeoutSeconds))
        }
    }

    private let state: NowPlayingState
    private let queue = DispatchQueue(label: "MPXPrime.NowPlayingScript", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var settings = Settings(
        config: {
            var cfg = AppConfig()
            cfg.rdsNowPlayingEnabled = false
            return cfg
        }())
    private var isPolling = false
    private var statusHandler: @Sendable (String) -> Void

    init(state: NowPlayingState, statusHandler: @escaping @Sendable (String) -> Void = { _ in }) {
        self.state = state
        self.statusHandler = statusHandler
    }

    func setStatusHandler(_ statusHandler: @escaping @Sendable (String) -> Void) {
        queue.async {
            self.statusHandler = statusHandler
        }
    }

    func updateConfig(_ config: AppConfig) {
        let newSettings = Settings(config: config)
        queue.async {
            self.settings = newSettings
            self.reconfigureTimer()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.isPolling = false
        }
    }

    private func reconfigureTimer() {
        timer?.cancel()
        timer = nil

        guard settings.enabled else {
            state.clear()
            statusHandler("Now Playing: off")
            return
        }

        guard !settings.scriptPath.isEmpty else {
            // No local script: the poller idles, but do NOT clear the state --
            // it may be fed over the API (POST /api/nowplaying). Clearing here
            // wiped API-pushed tracks on every config change (onConfigChange ->
            // updateConfig -> here). Only the disabled case (above) and a real
            // script failure wipe the state.
            statusHandler("Now Playing: no local script (API push may feed it)")
            return
        }

        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now(), repeating: settings.pollSeconds)
        newTimer.setEventHandler { [weak self] in
            self?.pollIfNeeded()
        }
        timer = newTimer
        newTimer.resume()
    }

    private func pollIfNeeded() {
        guard settings.enabled, !settings.scriptPath.isEmpty, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        let result = runScript(path: settings.scriptPath, timeoutSeconds: settings.timeoutSeconds)
        switch result {
        case .success(let snapshot):
            state.update(display: snapshot.display, artist: snapshot.artist, title: snapshot.title)
            let rendered = snapshot.display.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
                ? snapshot.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
                    ? "-"
                    : snapshot.title
                : snapshot.display
            statusHandler("Now Playing: \(rendered)")
        case .failure(let error):
            state.clear()
            statusHandler("Now Playing: \(friendlyStatusMessage(for: error))")
        }
    }

    private func runScript(path: String, timeoutSeconds: Double) -> Result<NowPlayingSnapshot, ScriptFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure(ScriptFailure(message: "launch failed"))
        }

        let timeout = DispatchTime.now() + timeoutSeconds
        while process.isRunning && DispatchTime.now() < timeout {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return .failure(ScriptFailure(message: "timed out"))
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderr
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
                ?? "exit \(process.terminationStatus)"
            return .failure(ScriptFailure(message: message))
        }

        let snapshot = parseSnapshot(stdout)
        if snapshot.hasContent {
            return .success(snapshot)
        }
        return .failure(ScriptFailure(message: "empty output"))
    }

    private func parseSnapshot(_ raw: String) -> NowPlayingSnapshot {
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var values: [String: String] = [:]
        var plainText = ""

        for line in lines {
            if let equals = line.firstIndex(of: "=") {
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let value = String(line[line.index(after: equals)...]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                values[key] = value
            } else if plainText.isEmpty {
                plainText = line
            }
        }

        let artist = values["artist"] ?? ""
        var title = values["title"] ?? ""
        let display = values["display"] ?? values["now_playing"] ?? plainText

        if title.isEmpty && !display.isEmpty {
            title = display
        }

        return NowPlayingSnapshot(
            display: display,
            artist: artist,
            title: title,
            revision: 0
        )
    }

    private func friendlyStatusMessage(for error: ScriptFailure) -> String {
        let normalized = error.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "empty output" || normalized == "exit 1" {
            return "No Song Data"
        }
        return error.message
    }
}

private struct ScriptFailure: Error {
    let message: String
}
