import Foundation

/// Which device channels carry a stereo (or mono) signal: the operator's
/// choice of "device plus one or two channel numbers", the model Prime Mixer
/// uses for multichannel interfaces. Indices are ZERO-based in code and
/// ONE-based everywhere the operator sees them (UI, INI, CLI, notes).
///
/// Pure Swift, no CoreAudio: the Linux CLI parses the INI keys too (and
/// ignores them -- channel choice there is an ALSA route plugin), and the
/// tests run on both platforms.
public struct ChannelPair: Equatable, Hashable, Sendable, Codable {
    /// Zero-based device channel index of the left side.
    public var left: Int
    /// Zero-based device channel index of the right side; `== left` means
    /// mono on that one channel.
    public var right: Int

    /// Stores the indices as given; `parse` is the one place that reorders
    /// (the lower-numbered channel becomes left), so a caller building a pair
    /// by hand gets exactly what it asked for.
    public init(left: Int, right: Int) {
        self.left = left
        self.right = right
    }

    /// Channels 1 and 2: what every 2-channel path has always used.
    public static let stereoDefault = ChannelPair(left: 0, right: 1)

    public var isMono: Bool { left == right }

    public var maxIndex: Int { max(left, right) }

    /// `[left]` when mono, else `[left, right]`.
    public var indices: [Int] { isMono ? [left] : [left, right] }

    /// Parses the INI/CLI form, one-based: "1,2" is a stereo pair, "3" alone
    /// is mono on channel 3. Whitespace around the numbers is tolerated.
    /// The order in the text does not matter: "2,1" and "1,2" both give left
    /// 0, right 1, because the model is "the lower-numbered channel is left"
    /// (the channel grid in the UI cannot express anything else). "3,3" is
    /// mono on channel 3. nil for nil, empty, non-numeric, a number below 1,
    /// or more than two numbers.
    public static func parse(_ text: String?) -> ChannelPair? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 1 || parts.count == 2 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 1 else { return nil }
            numbers.append(n - 1)
        }
        if numbers.count == 1 {
            return ChannelPair(left: numbers[0], right: numbers[0])
        }
        return ChannelPair(left: min(numbers[0], numbers[1]), right: max(numbers[0], numbers[1]))
    }

    /// The INI/CLI form: "1,2" for a pair, "3" for mono (one-based).
    public var iniValue: String {
        indices.map { String($0 + 1) }.joined(separator: ",")
    }

    /// "Channels 3, 4" or "Channel 3" (one-based), for labels and notes.
    public var label: String {
        isMono ? "Channel \(numbers)" : "Channels \(numbers)"
    }

    /// One-based numbers only: "3, 4" or "3".
    public var numbers: String {
        indices.map { String($0 + 1) }.joined(separator: ", ")
    }

    /// True when every index exists on a device with `channelCount` channels.
    public func fits(channelCount: Int) -> Bool {
        min(left, right) >= 0 && maxIndex < channelCount
    }

    /// True when the two pairs share at least one device channel.
    public func overlaps(_ other: ChannelPair) -> Bool {
        !Set(indices).isDisjoint(with: other.indices)
    }

    /// The pair to actually use on a device with `channelCount` channels.
    ///
    /// A nil request is the stereo default (channels 1, 2), or mono on
    /// channel 1 when the device has a single channel. A request that fits is
    /// used as is. A request that does not fit falls back to that same default
    /// and explains itself in `note`, e.g.
    /// "Input channels 3, 4 are not on this device (it has 2); using 1, 2."
    /// (a mono request reads "Monitor channel 5 is not on this device ...").
    /// `role` is the capitalised word the note starts with: "Input", "Output",
    /// "Monitor".
    public static func resolve(requested: ChannelPair?, channelCount: Int, role: String)
        -> (pair: ChannelPair, note: String?) {
        let fallback = channelCount <= 1 ? ChannelPair(left: 0, right: 0) : stereoDefault
        guard let requested else { return (fallback, nil) }
        if requested.fits(channelCount: channelCount) {
            return (requested, nil)
        }
        let verb = requested.isMono ? "is" : "are"
        let note = "\(role) \(requested.label.lowercased()) \(verb) not on this device "
            + "(it has \(channelCount)); using \(fallback.numbers)."
        return (fallback, note)
    }
}
