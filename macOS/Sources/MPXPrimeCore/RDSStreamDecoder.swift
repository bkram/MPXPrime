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

/// Accumulated receiver state for the meter's basic RDS readout. Fields are
/// optional until first observed so the UI can show "--" before lock.
public struct RDSReceiverState: Equatable {
    public var synced: Bool = false
    public var pi: Int?
    public var pty: Int?
    public var tp: Bool?
    public var ta: Bool?
    public var ms: Bool?
    /// Program Service name, 8 chars. Spaces until segments arrive.
    public var programService: String = "        "
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

    /// Fold a decoded group's always-present fields (PI, PTY, TP) and, for
    /// group 0A/0B, the flags + PS segment, into the running receiver state.
    private func accumulate(_ group: RDSGroup) {
        // PI (block A) and PTY/TP (block B) are present in every group and
        // only count if their own block checked out.
        if blocksOK[0] { receiver.pi = group.pi }
        if blocksOK[1] {
            receiver.pty = group.pty
            receiver.tp = group.tp
        }

        guard group.groupType == 0 else { return }   // PS lives in group 0A/0B
        if blocksOK[1] {
            receiver.ta = ((group.b2Tail >> 4) & 1) == 1
            receiver.ms = ((group.b2Tail >> 3) & 1) == 1
        }
        // PS: 2 chars per group in block D, segment from b2Tail bits 1-0.
        guard blocksOK[3] else { return }
        let seg = group.b2Tail & 0x03
        let hi = UInt8((group.block4 >> 8) & 0xFF)
        let lo = UInt8(group.block4 & 0xFF)
        var chars = Array(receiver.programService)
        if chars.count == 8 {
            chars[seg * 2] = Self.char(hi)
            chars[seg * 2 + 1] = Self.char(lo)
            receiver.programService = String(chars)
        }
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
