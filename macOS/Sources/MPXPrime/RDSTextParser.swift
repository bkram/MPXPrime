import Foundation

// Stereotool-compatible RDS text syntax helpers.
//
// Supported grammar (summary):
//   Ns:TEXT         timed segment, N may be fractional (e.g. 1.5s:)
//   Nt:TEXT         transmit-count segment, advances after N full transmissions
//   /               separates segments (unescaped)
//   ||              word-wrap toggle (word-wrap is always on; accepted as a no-op)
//   <  < <          scroll-left marker (PS only; repeat count sets chars per tick)
//   >  > >          scroll-right marker (PS only; repeat count sets chars per tick)
//   \\<  \\>  \\|  \\:  \\/  \\\\   literal escapes for the special chars above
//   \R"path"  \r"path"  \F"path"  \f"path"   file-load markers (caller resolves)
//
// This namespace is pure and side-effect free. BasicRDSCoder orchestrates
// resolution of file-load markers, sanitize/transliteration, and final byte
// encoding separately.

enum RDSTextTiming: Equatable {
    case seconds(Double)
    case transmits(Int)
}

struct RDSTextSegment: Equatable {
    let timing: RDSTextTiming
    let body: String
}

struct RDSScrollSpec: Equatable {
    let text: String
    let direction: Int  // -1 scroll left, +1 scroll right
    let speed: Int      // chars per tick, >= 1
}

enum RDSTextParser {

    // Private-use-area sentinels for escaped specials. Chosen so they survive
    // regex splitting but can be swapped back to literals before final sanitize.
    static let sentinelLT: Character      = "\u{E000}"
    static let sentinelGT: Character      = "\u{E001}"
    static let sentinelPipe: Character    = "\u{E002}"
    static let sentinelColon: Character   = "\u{E003}"
    static let sentinelSlash: Character   = "\u{E004}"
    static let sentinelBSlash: Character  = "\u{E005}"

    // MARK: - Escape handling

    /// Replace `\\X` escape sequences with private-use-area sentinels so the
    /// remainder of the parser can split on unescaped specials without eating
    /// user-intended literals.
    static func encodeEscapes(_ input: String) -> String {
        guard input.contains("\\") else { return input }
        var out = String()
        out.reserveCapacity(input.count)
        var iter = input.makeIterator()
        while let c = iter.next() {
            if c != "\\" {
                out.append(c)
                continue
            }
            guard let next = iter.next() else {
                out.append("\\")
                break
            }
            switch next {
            case "<":  out.append(sentinelLT)
            case ">":  out.append(sentinelGT)
            case "|":  out.append(sentinelPipe)
            case ":":  out.append(sentinelColon)
            case "/":  out.append(sentinelSlash)
            case "\\": out.append(sentinelBSlash)
            default:
                // File-load markers (\R \r \F \f \w) and any other backslash
                // sequence pass through unchanged for later resolution.
                out.append("\\")
                out.append(next)
            }
        }
        return out
    }

    /// Restore private-use sentinels to their literal characters. Call after
    /// all structural parsing / splitting is done, before sanitize.
    static func decodeEscapes(_ input: String) -> String {
        // Fast path: if the string contains no sentinels there's nothing to
        // decode, so avoid the full character-by-character rebuild (this
        // function is called on the audio thread per RT group and the
        // default case — unescaped input — is the overwhelmingly common
        // one).
        if !input.unicodeScalars.contains(where: { scalar in
            (scalar.value >= 0xE000 && scalar.value <= 0xE005)
        }) {
            return input
        }
        var out = String()
        out.reserveCapacity(input.count)
        for c in input {
            switch c {
            case sentinelLT:     out.append("<")
            case sentinelGT:     out.append(">")
            case sentinelPipe:   out.append("|")
            case sentinelColon:  out.append(":")
            case sentinelSlash:  out.append("/")
            case sentinelBSlash: out.append("\\")
            default:             out.append(c)
            }
        }
        return out
    }

    // MARK: - Structural helpers

    /// Strip `||` word-wrap toggles. Word-wrap is always on; `||` is accepted
    /// for Stereotool compatibility but is a no-op.
    static func stripWrapMarkers(_ input: String) -> String {
        guard input.contains("||") else { return input }
        return input.replacingOccurrences(of: "||", with: "")
    }

    private static let timingPrefixRegex: NSRegularExpression = {
        // group 1: number (optional fractional), group 2: "s" or "t"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: #"^\s*(\d+(?:\.\d+)?)([st]):"#, options: []
        )
    }()

    private static let startsTimedRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: #"^\s*\d+(?:\.\d+)?[st]:"#, options: []
        )
    }()

    private static let inlineTimedRegex: NSRegularExpression = {
        // Non-greedy body up to next timed token at a whitespace boundary.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: #"(\d+(?:\.\d+)?)([st]):(.*?)(?=(?:\s+\d+(?:\.\d+)?[st]:)|$)"#,
            options: []
        )
    }()

    private static let hasTimingTokenRegex: NSRegularExpression = {
        // Matches at start of string OR after whitespace or '/'.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: #"(^|[\s/])\d+(?:\.\d+)?[st]:"#, options: []
        )
    }()

    static func startsWithTimingPrefix(_ text: String) -> Bool {
        let ns = text as NSString
        return startsTimedRegex.firstMatch(
            in: text, options: [], range: NSRange(location: 0, length: ns.length)
        ) != nil
    }

    /// Parse a timing prefix (Ns: or Nt:) at the start of `text`. Returns the
    /// timing and the remainder of the text. If no prefix is present, returns
    /// `(.seconds(defaultDuration), text)`.
    static func parseTimingPrefix(
        _ text: String, defaultDuration: Double
    ) -> (timing: RDSTextTiming, body: String) {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = timingPrefixRegex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 3
        else {
            return (.seconds(defaultDuration), text)
        }
        let numStr = ns.substring(with: match.range(at: 1))
        let unit = ns.substring(with: match.range(at: 2))
        let upper = match.range(at: 0).location + match.range(at: 0).length
        let rest = ns.substring(from: upper)
        if unit == "t" {
            let n = max(1, Int(numStr) ?? 1)
            return (.transmits(n), rest)
        }
        let d = max(0.1, Double(numStr) ?? defaultDuration)
        return (.seconds(d), rest)
    }

    /// Extract inline `Ns:A 2t:B 3s:C` space-separated segments when a single
    /// top-level part contains multiple timed tokens. Returns an empty array
    /// if the text does not start with a timing token (caller should fall
    /// back to a single-segment parse).
    static func extractInlineSegments(
        _ text: String, defaultDuration: Double
    ) -> [RDSTextSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard startsWithTimingPrefix(trimmed) else { return [] }
        let ns = trimmed as NSString
        let matches = inlineTimedRegex.matches(
            in: trimmed, options: [], range: NSRange(location: 0, length: ns.length)
        )
        var out: [RDSTextSegment] = []
        for match in matches where match.numberOfRanges >= 4 {
            let numStr = ns.substring(with: match.range(at: 1))
            let unit = ns.substring(with: match.range(at: 2))
            let body = ns.substring(with: match.range(at: 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let timing: RDSTextTiming
            if unit == "t" {
                timing = .transmits(max(1, Int(numStr) ?? 1))
            } else {
                timing = .seconds(max(0.1, Double(numStr) ?? defaultDuration))
            }
            out.append(RDSTextSegment(timing: timing, body: body))
        }
        return out
    }

    /// Returns true if `raw` contains at least one timed command (Ns: or Nt:).
    /// Used to distinguish "manual RT buffer with explicit timing" from
    /// "manual RT buffer that should use the configured cycle time".
    static func containsTimedCommand(_ raw: String) -> Bool {
        let encoded = encodeEscapes(raw)
        let ns = encoded as NSString
        return hasTimingTokenRegex.firstMatch(
            in: encoded, options: [], range: NSRange(location: 0, length: ns.length)
        ) != nil
    }

    /// Split an escape-encoded string on top-level `/` separators, preserving
    /// `\/` literals encoded as `sentinelSlash`.
    static func splitTopLevel(_ encoded: String) -> [String] {
        encoded.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Scroll

    /// Detect a leading `<` or `>` scroll marker on `text`. The count of
    /// leading markers sets scroll speed (chars per tick). Returns `nil` if
    /// no scroll marker is present.
    static func parseScrollMarker(_ text: String) -> RDSScrollSpec? {
        var chars = Array(text)
        guard let first = chars.first, first == "<" || first == ">" else {
            return nil
        }
        let direction = (first == "<") ? -1 : 1
        var speed = 0
        while let head = chars.first {
            if (direction == -1 && head == "<") || (direction == 1 && head == ">") {
                speed += 1
                chars.removeFirst()
                continue
            }
            break
        }
        let body = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        return RDSScrollSpec(text: body, direction: direction, speed: max(1, speed))
    }

    /// Produce the sequence of width-sized window strings for a scroll spec.
    /// The source text is padded with `width` spaces on each side so the text
    /// enters and exits the visible window cleanly.
    static func scrollWindows(
        _ spec: RDSScrollSpec, width: Int
    ) -> [String] {
        guard width > 0, !spec.text.isEmpty else {
            return [String(repeating: " ", count: max(0, width))]
        }
        let pad = String(repeating: " ", count: width)
        let source = pad + spec.text + pad
        let chars = Array(source)
        var frames: [String] = []
        let step = max(1, spec.speed)
        if spec.direction == -1 {
            var i = 0
            while i + width <= chars.count {
                frames.append(String(chars[i..<(i + width)]))
                i += step
            }
            if frames.isEmpty {
                let window = Array(chars.prefix(width))
                frames.append(String(window) + String(repeating: " ", count: max(0, width - window.count)))
            }
        } else {
            var i = chars.count - width
            while i >= 0 {
                frames.append(String(chars[i..<(i + width)]))
                i -= step
            }
            if frames.isEmpty {
                let window = Array(chars.suffix(width))
                frames.append(String(repeating: " ", count: max(0, width - window.count)) + String(window))
            }
        }
        return frames
    }
}
