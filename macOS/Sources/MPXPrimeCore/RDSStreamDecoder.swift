import Foundation

// Symmetric RDS decoder for the receive side (MPX Prime Meter) and offline
// analysis. The encoder is `BasicRDSCoder` (still in the MPXPrime target);
// this decoder is the receive-side counterpart the plan calls for, living in
// the shared MPXPrimeCore so the future MPXPrimeMeter app can reuse it.
//
// SCOPE: this operates on *recovered RDS data bits* — the differentially-
// decoded, biphase-demodulated 1187.5 bps data stream. The 57 kHz subcarrier
// front-end (mix down, biphase symbol + clock recovery, differential decode)
// is a separate later increment; this layer is everything from "I have a
// continuous, possibly-unaligned bit stream" onward: block synchronization,
// group assembly, CRC checking, and field accumulation (PI / PTY / TP / TA /
// MS / DI / PS) for the meter's basic readout.
//
// An RDS group is 104 bits = 4 blocks x 26 bits. Each 26-bit block is a 16-bit
// info word (MSB first) followed by a 10-bit checkword that is the BCH
// remainder of the info word under g(x) = x^10+x^8+x^7+x^5+x^4+x^3+1 (0x5B9),
// XOR'd with a fixed 10-bit offset word (A/B/C/C'/D). Receivers use the offset
// words to recover block alignment: a 26-bit window whose syndrome equals a
// known offset's syndrome is a valid block of that type.

/// One decoded, CRC-checked RDS group (the receiver's view of 104 bits).
public struct RDSGroup: Equatable {
    public let pi: Int           // block A info word (16 bits)
    public let groupType: Int    // bits 15-12 of block B
    public let versionB: Bool    // bit 11 of block B
    public let tp: Bool          // bit 10 of block B
    public let pty: Int          // bits 9-5 of block B
    public let b2Tail: Int       // bits 4-0 of block B
    public let block3: Int       // block C / C' info word
    public let block4: Int       // block D info word
    public let blocksValid: Int  // 0...4 blocks whose checkword matched

    public var allBlocksValid: Bool { blocksValid == 4 }
}

/// Decoded RDS Clock-Time (group 4A). Time is UTC; `offsetHalfHours` is the
/// signed local-time offset in half-hour steps (multiply by 0.5 for hours).
public struct RDSClockTime: Equatable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int       // UTC
    public var minute: Int     // UTC
    public var offsetHalfHours: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, offsetHalfHours: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.offsetHalfHours = offsetHalfHours
    }
}

/// One RadioText+ (RT+) tag: a content type (EN 50067 / IEC 62106 RT+ class
/// code, e.g. 1 = ITEM.TITLE, 4 = ITEM.ARTIST) and the substring of the
/// current RadioText it points at.
public struct RDSRTPlusTag: Equatable {
    public let contentType: Int
    public let text: String

    public init(contentType: Int, text: String) {
        self.contentType = contentType
        self.text = text
    }
}

/// Accumulated receiver state for the meter's RDS readout. Fields are optional
/// or empty until first observed so the UI can show "--" before lock.
public struct RDSReceiverState: Equatable {
    public var synced: Bool = false
    public var pi: Int?
    public var pty: Int?
    public var tp: Bool?
    public var ta: Bool?
    public var ms: Bool?
    /// Program Service name, 8 chars. Spaces until segments arrive.
    public var programService: String = "        "

    /// RadioText (groups 2A/2B), assembled and trimmed at the 0x0D terminator.
    public var radioText: String = ""
    /// Last observed RadioText A/B flag (toggling it signals a new message).
    public var radioTextABFlag: Bool?
    /// Programme Type Name (group 10A), 8 chars; empty until seen.
    public var programTypeName: String = ""
    /// Extended Country Code (group 1A, variant 0).
    public var ecc: Int?
    /// Decoded Clock-Time (group 4A).
    public var clockTime: RDSClockTime?
    /// Alternative Frequencies (group 0A), MHz, sorted ascending.
    public var alternativeFrequenciesMHz: [Double] = []
    /// Long PS (group 15A), assembled 32-char station name; empty until seen.
    public var longPS: String = ""
    /// RadioText+ tags (group 11A, ODA AID 0x4BD7) resolved against the
    /// current RadioText. Empty until a tagged item is decoded.
    public var rtPlusTags: [RDSRTPlusTag] = []
    /// Count of decoded groups by type, indexed `groupType * 2 + (versionB ? 1 : 0)`.
    public var groupCounts: [Int] = Array(repeating: 0, count: 32)
    /// The most recently received group buckets in transmission ORDER (oldest
    /// first), same index base as `groupCounts`. Counts say what the encoder
    /// sends; the order says how it interleaves -- which is what reveals a
    /// scheduler's repeating pattern, a starved group type, or a burst of one
    /// type crowding out the rest. Capped at `groupOrderCapacity`.
    public var groupOrder: [Int] = []
    /// How many recent groups `groupOrder` keeps.
    public static let groupOrderCapacity = 18

    public var groupsDecoded: Int = 0
    public var blocksReceived: Int = 0
    public var blocksValid: Int = 0

    /// Fraction of received blocks that failed their checkword. A coarse
    /// link-quality indicator for the meter (0 = clean).
    public var blockErrorRate: Double {
        guard blocksReceived > 0 else { return 0.0 }
        return Double(blocksReceived - blocksValid) / Double(blocksReceived)
    }

    public init() {}
}

/// Stateful RDS bit-stream decoder. Feed recovered data bits one at a time;
/// it acquires block sync, assembles 104-bit groups, and accumulates the
/// basic readout fields. Not thread-safe — drive it from one consumer (e.g.
/// the meter's analysis thread) and snapshot `state` for the UI.
public final class RDSStreamDecoder {

    // BCH / offset constants — mirror of BasicRDSCoder (kept in lockstep; see
    // RDSBitstreamHelpers in the test target which uses the same values).
    @usableFromInline static let genLow10 = 0x1B9   // 0x5B9 with the x^10 term dropped
    @usableFromInline static let offsetA = 0x0FC
    @usableFromInline static let offsetB = 0x198
    @usableFromInline static let offsetC = 0x168
    @usableFromInline static let offsetCp = 0x1E0
    @usableFromInline static let offsetD = 0x1B4

    /// Block position within a group, identified from the matched offset word.
    private enum BlockSlot: Int { case a = 0, b = 1, c = 2, d = 3 }

    // Precomputed syndromes of the offset words. A valid block of a given type
    // has window-syndrome equal to that offset's syndrome (because the data is
    // a true codeword whose own syndrome is 0, and syndrome is linear).
    private static let synA = syndrome(offsetA)
    private static let synB = syndrome(offsetB)
    private static let synC = syndrome(offsetC)
    private static let synCp = syndrome(offsetCp)
    private static let synD = syndrome(offsetD)

    private var window: Int = 0      // last 26 bits seen (LSB = newest)
    private var bitsSeen: Int = 0
    private var locked = false
    private var bitInGroup = 0       // 0...103, position of the *newest* bit within the group grid
    private var blocks = [Int](repeating: 0, count: 4)
    private var blocksOK = [Bool](repeating: false, count: 4)

    private var receiver = RDSReceiverState()

    // Assembly buffers for multi-segment fields.
    private var rtChars = [UInt8](repeating: 0x20, count: 64)
    private var rtABFlag = -1
    private var ptynChars = [UInt8](repeating: 0x20, count: 8)
    private var lpsChars = [UInt8](repeating: 0x20, count: 32)
    private var afCodes = Set<Int>()
    // RT+ ODA: the group type carrying AID 0x4BD7, learned from a 3A
    // announcement. nil -> assume 11A (the near-universal RT+ assignment).
    private static let rtPlusAID = 0x4BD7
    private var rtPlusGroupType: Int?

    public init() {}

    public var state: RDSReceiverState { receiver }

    public func reset() {
        window = 0
        bitsSeen = 0
        locked = false
        bitInGroup = 0
        blocks = [Int](repeating: 0, count: 4)
        blocksOK = [Bool](repeating: false, count: 4)
        receiver = RDSReceiverState()
        rtChars = [UInt8](repeating: 0x20, count: 64)
        rtABFlag = -1
        ptynChars = [UInt8](repeating: 0x20, count: 8)
        lpsChars = [UInt8](repeating: 0x20, count: 32)
        afCodes = []
        rtPlusGroupType = nil
    }

    /// Feed one recovered data bit (0/1). Returns a fully-assembled group when
    /// the newest bit completes block D of a synchronized group, else nil.
    @discardableResult
    public func feed(bit: UInt8) -> RDSGroup? {
        window = ((window << 1) | Int(bit & 1)) & 0x03FF_FFFF
        bitsSeen += 1
        guard bitsSeen >= 26 else { return nil }

        if !locked {
            // Search: does the current 26-bit window match a known block? If
            // so, anchor the group grid so this block sits in its proper slot.
            if let slot = Self.slot(forSyndrome: Self.syndrome(window)) {
                locked = true
                bitInGroup = slot.rawValue * 26 + 25   // newest bit is this block's last bit
                captureBlock(slot.rawValue)
                return finishGroupIfComplete(at: slot.rawValue)
            }
            return nil
        }

        // Locked: advance the grid and capture at each block boundary.
        bitInGroup = (bitInGroup + 1) % 104
        if bitInGroup % 26 == 25 {
            let slotIndex = bitInGroup / 26
            captureBlock(slotIndex)
            return finishGroupIfComplete(at: slotIndex)
        }
        return nil
    }

    private func captureBlock(_ slotIndex: Int) {
        blocks[slotIndex] = window
        // A block's expected offset depends on its slot; block C uses C or C'
        // per the version bit, which we only know once block B is decoded. We
        // validate C against either offset and accept the matching one.
        blocksOK[slotIndex] = Self.blockValid(window, slotIndex: slotIndex)
    }

    private func finishGroupIfComplete(at slotIndex: Int) -> RDSGroup? {
        guard slotIndex == BlockSlot.d.rawValue else { return nil }

        let b1 = (blocks[0] >> 10) & 0xFFFF
        let b2 = (blocks[1] >> 10) & 0xFFFF
        let b3 = (blocks[2] >> 10) & 0xFFFF
        let b4 = (blocks[3] >> 10) & 0xFFFF
        let valid = blocksOK.reduce(0) { $0 + ($1 ? 1 : 0) }

        let group = RDSGroup(
            pi: b1,
            groupType: (b2 >> 12) & 0x0F,
            versionB: ((b2 >> 11) & 1) == 1,
            tp: ((b2 >> 10) & 1) == 1,
            pty: (b2 >> 5) & 0x1F,
            b2Tail: b2 & 0x1F,
            block3: b3,
            block4: b4,
            blocksValid: valid
        )

        receiver.blocksReceived += 4
        receiver.blocksValid += valid

        // Lock maintenance: a group with too many bad blocks means we lost
        // alignment. Drop back to search rather than emit garbage.
        if valid < 2 {
            locked = false
            return nil
        }

        receiver.synced = true
        receiver.groupsDecoded += 1
        accumulate(group)
        return group
    }

    /// Fold a decoded group's fields into the running receiver state, by group
    /// type. PI/PTY/TP are present in every group; the rest are type-specific.
    private func accumulate(_ group: RDSGroup) {
        // PI (block A) and PTY/TP (block B) are present in every group and
        // only count if their own block checked out.
        if blocksOK[0] { receiver.pi = group.pi }
        if blocksOK[1] {
            receiver.pty = group.pty
            receiver.tp = group.tp
            let bucket = (group.groupType * 2) + (group.versionB ? 1 : 0)
            if bucket >= 0, bucket < receiver.groupCounts.count {
                receiver.groupCounts[bucket] += 1
                receiver.groupOrder.append(bucket)
                if receiver.groupOrder.count > RDSReceiverState.groupOrderCapacity {
                    receiver.groupOrder.removeFirst(
                        receiver.groupOrder.count - RDSReceiverState.groupOrderCapacity)
                }
            }
        }

        switch group.groupType {
        case 0:  accumulateGroup0(group)
        case 1:  accumulateGroup1(group)
        case 2:  accumulateRadioText(group)
        case 3:  accumulateODA(group)
        case 4:  accumulateClockTime(group)
        case 10: accumulatePTYN(group)
        case 15: accumulateLongPS(group)
        default: break
        }

        // RT+ is an ODA: it rides whichever group 3A assigned to AID 0x4BD7
        // (commonly 11A, but 12A and others occur -- e.g. SunriseFM uses 12A).
        // Route by the learned group, defaulting to 11A before any 3A is seen.
        if !group.versionB, group.groupType == (rtPlusGroupType ?? 11) {
            accumulateRTPlus(group)
        }
    }

    /// Group 0A/0B: TA/MS/DI flags, PS name (block D), and (0A only) the AF
    /// pair in block C.
    private func accumulateGroup0(_ group: RDSGroup) {
        if blocksOK[1] {
            receiver.ta = ((group.b2Tail >> 4) & 1) == 1
            receiver.ms = ((group.b2Tail >> 3) & 1) == 1
        }
        if !group.versionB, blocksOK[2] {
            ingestAF(UInt8((group.block3 >> 8) & 0xFF))
            ingestAF(UInt8(group.block3 & 0xFF))
        }
        // PS: 2 chars per group in block D, segment from b2Tail bits 1-0.
        guard blocksOK[1], blocksOK[3] else { return }
        let seg = group.b2Tail & 0x03
        var chars = Array(receiver.programService)
        if chars.count == 8 {
            chars[seg * 2] = Self.char(UInt8((group.block4 >> 8) & 0xFF))
            chars[seg * 2 + 1] = Self.char(UInt8(group.block4 & 0xFF))
            receiver.programService = String(chars)
        }
    }

    /// Group 1A variant 0: Extended Country Code (block C low byte).
    private func accumulateGroup1(_ group: RDSGroup) {
        guard !group.versionB, blocksOK[2] else { return }
        let variant = (group.block3 >> 12) & 0x0F
        if variant == 0 {
            receiver.ecc = group.block3 & 0xFF
        }
    }

    /// Groups 2A/2B: RadioText. 2A carries 4 chars (blocks C+D) per segment,
    /// 2B carries 2 chars (block D) per segment. The A/B flag toggling clears
    /// the buffer (new message).
    private func accumulateRadioText(_ group: RDSGroup) {
        guard blocksOK[1] else { return }
        let ab = (group.b2Tail >> 4) & 1
        if ab != rtABFlag {
            for i in rtChars.indices { rtChars[i] = 0x20 }
            rtABFlag = ab
            receiver.radioTextABFlag = ab == 1
        }
        let seg = group.b2Tail & 0x0F
        if group.versionB {
            guard blocksOK[3] else { return }
            setRTChar(seg * 2, UInt8((group.block4 >> 8) & 0xFF))
            setRTChar(seg * 2 + 1, UInt8(group.block4 & 0xFF))
        } else {
            if blocksOK[2] {
                setRTChar(seg * 4, UInt8((group.block3 >> 8) & 0xFF))
                setRTChar(seg * 4 + 1, UInt8(group.block3 & 0xFF))
            }
            if blocksOK[3] {
                setRTChar(seg * 4 + 2, UInt8((group.block4 >> 8) & 0xFF))
                setRTChar(seg * 4 + 3, UInt8(group.block4 & 0xFF))
            }
        }
        receiver.radioText = assembleRadioText()
    }

    /// Group 4A: Clock-Time. MJD + UTC hour/minute + signed local offset.
    private func accumulateClockTime(_ group: RDSGroup) {
        guard !group.versionB, blocksOK[1], blocksOK[2], blocksOK[3] else { return }
        let mjd = ((group.b2Tail & 0x03) << 15) | ((group.block3 >> 1) & 0x7FFF)
        let hour = ((group.block3 & 0x1) << 4) | ((group.block4 >> 12) & 0x0F)
        let minute = (group.block4 >> 6) & 0x3F
        let sign = (group.block4 >> 5) & 0x1
        let half = group.block4 & 0x1F
        guard hour < 24, minute < 60, mjd > 0 else { return }
        let (y, m, d) = Self.gregorian(fromMJD: mjd)
        receiver.clockTime = RDSClockTime(
            year: y, month: m, day: d, hour: hour, minute: minute,
            offsetHalfHours: sign == 1 ? -half : half)
    }

    /// Group 10A: Programme Type Name, 8 chars over 2 segments (4 chars each
    /// from blocks C+D).
    private func accumulatePTYN(_ group: RDSGroup) {
        guard !group.versionB, blocksOK[1] else { return }
        let seg = group.b2Tail & 0x1
        if blocksOK[2] {
            ptynChars[seg * 4] = UInt8((group.block3 >> 8) & 0xFF)
            ptynChars[seg * 4 + 1] = UInt8(group.block3 & 0xFF)
        }
        if blocksOK[3] {
            ptynChars[seg * 4 + 2] = UInt8((group.block4 >> 8) & 0xFF)
            ptynChars[seg * 4 + 3] = UInt8(group.block4 & 0xFF)
        }
        receiver.programTypeName = String(ptynChars.map { Self.char($0) })
    }

    /// Group 3A: ODA application identification. Block D is the 16-bit AID;
    /// block B bits 4-0 are the application group code (group<<1 | version).
    /// Learn which group carries RT+ (AID 0x4BD7).
    private func accumulateODA(_ group: RDSGroup) {
        guard !group.versionB, blocksOK[1], blocksOK[3] else { return }
        if group.block4 == Self.rtPlusAID {
            rtPlusGroupType = (group.b2Tail & 0x1F) >> 1
        }
    }

    /// RadioText+ (ODA AID 0x4BD7): two tags, each a content type + start +
    /// length into the current RT. The caller has already confirmed this group
    /// is the RT+ carrier.
    private func accumulateRTPlus(_ group: RDSGroup) {
        guard blocksOK[1] else { return }

        var tags: [RDSRTPlusTag] = []
        if blocksOK[2] {
            let t1Type = ((group.b2Tail & 0x07) << 3) | ((group.block3 >> 13) & 0x07)
            let t1Start = (group.block3 >> 7) & 0x3F
            let t1Len = (group.block3 >> 1) & 0x3F
            if t1Type != 0 {
                let text = rtPlusSubstring(start: t1Start, length: t1Len + 1)
                if !text.isEmpty { tags.append(RDSRTPlusTag(contentType: t1Type, text: text)) }
            }
        }
        if blocksOK[2], blocksOK[3] {
            let t2Type = ((group.block3 & 0x01) << 5) | ((group.block4 >> 11) & 0x1F)
            let t2Start = (group.block4 >> 5) & 0x3F
            let t2Len = group.block4 & 0x1F
            if t2Type != 0 {
                let text = rtPlusSubstring(start: t2Start, length: t2Len + 1)
                if !text.isEmpty { tags.append(RDSRTPlusTag(contentType: t2Type, text: text)) }
            }
        }
        // Only replace when this group produced resolvable tags, so a tag
        // whose RT segments have not arrived yet doesn't clear a good reading.
        if !tags.isEmpty { receiver.rtPlusTags = tags }
    }

    /// Group 15A: Long PS, 32 chars over 8 segments (4 chars each, blocks C+D).
    private func accumulateLongPS(_ group: RDSGroup) {
        guard !group.versionB, blocksOK[1] else { return }
        let seg = group.b2Tail & 0x07
        if blocksOK[2] {
            lpsChars[seg * 4] = UInt8((group.block3 >> 8) & 0xFF)
            lpsChars[seg * 4 + 1] = UInt8(group.block3 & 0xFF)
        }
        if blocksOK[3] {
            lpsChars[seg * 4 + 2] = UInt8((group.block4 >> 8) & 0xFF)
            lpsChars[seg * 4 + 3] = UInt8(group.block4 & 0xFF)
        }
        var out = ""
        for byte in lpsChars {
            if byte == 0x0D { break }
            out.append(Self.char(byte))
        }
        while out.hasSuffix(" ") { out.removeLast() }
        receiver.longPS = out
    }

    /// Extract an RT+ tag's substring from the RAW (untrimmed) RadioText
    /// buffer, since RT+ start/length index into the full transmitted text.
    private func rtPlusSubstring(start: Int, length: Int) -> String {
        guard length > 0, start >= 0, start < rtChars.count else { return "" }
        let end = min(rtChars.count, start + length)
        var out = ""
        for i in start..<end { out.append(Self.char(rtChars[i])) }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private func setRTChar(_ index: Int, _ byte: UInt8) {
        guard index >= 0, index < rtChars.count else { return }
        rtChars[index] = byte
    }

    /// Assemble the RadioText buffer to a string, terminating at the 0x0D
    /// carriage return (EN 50067 end-of-message) and trimming trailing spaces.
    private func assembleRadioText() -> String {
        var out = ""
        for byte in rtChars {
            if byte == 0x0D { break }
            out.append(Self.char(byte))
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Map an AF code byte to a VHF frequency (MHz) and record it. Codes
    /// 1...204 are 87.5 + n*0.1 MHz; everything else (count codes 224-249,
    /// filler 205, LF/MF marker 250, spares) is skipped.
    private func ingestAF(_ code: UInt8) {
        let n = Int(code)
        guard n >= 1, n <= 204 else { return }
        if afCodes.insert(n).inserted {
            receiver.alternativeFrequenciesMHz =
                afCodes.sorted().map { 87.5 + (Double($0) * 0.1) }
        }
    }

    /// Modified Julian Day -> Gregorian (year, month, day), EN 50067 Annex G.
    static func gregorian(fromMJD mjd: Int) -> (Int, Int, Int) {
        let mjdD = Double(mjd)
        let yPrime = Int((mjdD - 15078.2) / 365.25)
        let mPrime = Int((mjdD - 14956.1 - Double(Int(Double(yPrime) * 365.25))) / 30.6001)
        let day = mjd - 14956 - Int(Double(yPrime) * 365.25) - Int(Double(mPrime) * 30.6001)
        let k = (mPrime == 14 || mPrime == 15) ? 1 : 0
        let year = yPrime + k + 1900
        let month = mPrime - 1 - (k * 12)
        return (year, month, day)
    }

    // MARK: - BCH syndrome

    /// 10-bit BCH syndrome (remainder under g(x)) of a 26-bit block, MSB first.
    @usableFromInline
    static func syndrome(_ block26: Int) -> Int {
        var reg = 0
        var i = 25
        while i >= 0 {
            let inBit = (block26 >> i) & 1
            let out = (reg >> 9) & 1
            reg = ((reg << 1) & 0x3FF) | inBit
            if out == 1 { reg ^= genLow10 }
            i -= 1
        }
        return reg
    }

    private static func slot(forSyndrome s: Int) -> BlockSlot? {
        switch s {
        case synA: return .a
        case synB: return .b
        case synC, synCp: return .c
        case synD: return .d
        default: return nil
        }
    }

    private static func blockValid(_ block26: Int, slotIndex: Int) -> Bool {
        let s = syndrome(block26)
        switch slotIndex {
        case 0: return s == synA
        case 1: return s == synB
        case 2: return s == synC || s == synCp
        case 3: return s == synD
        default: return false
        }
    }

    /// RDS basic character set bytes 0x20-0x7E map directly to ASCII; other
    /// bytes are shown as space for the meter's PS readout.
    private static func char(_ byte: UInt8) -> Character {
        if byte >= 0x20, byte <= 0x7E, let scalar = Unicode.Scalar(UInt32(byte)) {
            return Character(scalar)
        }
        return " "
    }
}
