import Foundation

// Helpers for decoding RDS group bitstreams emitted by BasicRDSCoder.
//
// An RDS group is 104 bits = 4 blocks × 26 bits. Each block carries a 16-bit
// data word MSB first, followed by a 10-bit CRC that is XOR'd with a fixed
// offset word (A / B / C / Cp / D) so receivers can recover block alignment.
// This module mirrors the RDS CRC logic in BasicRDSCoder so tests can verify
// that emitted groups encode exactly what we expect, and that every block's
// CRC is correct.

struct RDSDecodedGroup {
    let piCode: Int            // block A word (16 bits)
    let groupType: Int         // bits 15-12 of block B
    let versionB: Bool         // bit 11 of block B
    let tpFlag: Bool           // bit 10 of block B
    let pty: Int               // bits 9-5 of block B (5 bits)
    let b2Tail: Int            // bits 4-0 of block B (5 bits)
    let block3: Int            // block C / Cp data word
    let block4: Int            // block D data word
    let crcOK: [Bool]          // per-block CRC check result
}

enum RDSGroupDecoder {

    // Mirror of BasicRDSCoder.crc — same polynomial, same offset XOR.
    private static let crcPoly = 0x5B9
    static let offsetA = 0x0FC
    static let offsetB = 0x198
    static let offsetC = 0x168
    static let offsetCp = 0x1E0
    static let offsetD = 0x1B4

    static func crc(word: Int, offset: Int) -> Int {
        var reg = (word & 0xFFFF) << 10
        for _ in 0..<16 {
            if ((reg >> 25) & 1) == 1 {
                reg ^= (crcPoly << 15)
            }
            reg = (reg << 1) & 0x03FF_FFFF
        }
        return ((reg >> 16) & 0x03FF) ^ offset
    }

    /// Extract a contiguous bit range as an unsigned integer (MSB first).
    static func extractBits(_ bits: [UInt8], _ start: Int, _ count: Int) -> Int {
        var value = 0
        for i in 0..<count {
            value = (value << 1) | Int(bits[start + i])
        }
        return value
    }

    /// Decode a 104-bit RDS group. Input must be exactly 104 bits.
    static func decode(_ bits: [UInt8]) -> RDSDecodedGroup {
        precondition(bits.count == 104, "RDS group must be 104 bits, got \(bits.count)")
        let block1 = extractBits(bits, 0, 26)
        let block2 = extractBits(bits, 26, 26)
        let block3 = extractBits(bits, 52, 26)
        let block4 = extractBits(bits, 78, 26)

        let b1Data = (block1 >> 10) & 0xFFFF
        let b1CRC = block1 & 0x3FF
        let b2Data = (block2 >> 10) & 0xFFFF
        let b2CRC = block2 & 0x3FF
        let b3Data = (block3 >> 10) & 0xFFFF
        let b3CRC = block3 & 0x3FF
        let b4Data = (block4 >> 10) & 0xFFFF
        let b4CRC = block4 & 0x3FF

        let versionB = ((b2Data >> 11) & 1) == 1
        let b3Offset = versionB ? offsetCp : offsetC

        let crcChecks = [
            b1CRC == crc(word: b1Data, offset: offsetA),
            b2CRC == crc(word: b2Data, offset: offsetB),
            b3CRC == crc(word: b3Data, offset: b3Offset),
            b4CRC == crc(word: b4Data, offset: offsetD),
        ]

        return RDSDecodedGroup(
            piCode: b1Data,
            groupType: (b2Data >> 12) & 0x0F,
            versionB: versionB,
            tpFlag: ((b2Data >> 10) & 1) == 1,
            pty: (b2Data >> 5) & 0x1F,
            b2Tail: b2Data & 0x1F,
            block3: b3Data,
            block4: b4Data,
            crcOK: crcChecks
        )
    }

    /// Segment index from a group 0 b2Tail (bits 0-1 only).
    static func psSegment(_ group: RDSDecodedGroup) -> Int {
        group.b2Tail & 0x03
    }

    /// Segment index from a group 2 b2Tail (bits 0-3, 16 segments).
    static func rtSegment(_ group: RDSDecodedGroup) -> Int {
        group.b2Tail & 0x0F
    }

    /// AB flag from a group 2 b2Tail (bit 4).
    static func rtABFlag(_ group: RDSDecodedGroup) -> Int {
        (group.b2Tail >> 4) & 0x01
    }

    /// Segment index from a group 10A / 15A b2Tail (bits 0-0 for 10A, 0-2 for 15A).
    static func ptynSegment(_ group: RDSDecodedGroup) -> Int {
        group.b2Tail & 0x01
    }

    static func lpsSegment(_ group: RDSDecodedGroup) -> Int {
        group.b2Tail & 0x07
    }

    /// Extract PS characters (2 per group 0) from block D.
    static func psChars(_ group: RDSDecodedGroup) -> (Character, Character) {
        let high = UInt8((group.block4 >> 8) & 0xFF)
        let low = UInt8(group.block4 & 0xFF)
        return (charFromByte(high), charFromByte(low))
    }

    /// Extract RT characters (4 per group 2A, 2 per group 2B) from blocks C and D.
    static func rtChars(_ group: RDSDecodedGroup, versionB: Bool) -> [Character] {
        if versionB {
            let hi = UInt8((group.block4 >> 8) & 0xFF)
            let lo = UInt8(group.block4 & 0xFF)
            return [charFromByte(hi), charFromByte(lo)]
        }
        return [
            charFromByte(UInt8((group.block3 >> 8) & 0xFF)),
            charFromByte(UInt8(group.block3 & 0xFF)),
            charFromByte(UInt8((group.block4 >> 8) & 0xFF)),
            charFromByte(UInt8(group.block4 & 0xFF)),
        ]
    }

    /// RDS bytes 0x20-0x7E map directly to ASCII. Bytes outside that range
    /// appear in the basic RDS character table but tests only need ASCII
    /// for assertions. Non-ASCII bytes are passed through as their scalar.
    private static func charFromByte(_ byte: UInt8) -> Character {
        if let scalar = Unicode.Scalar(UInt32(byte)) {
            return Character(scalar)
        }
        return " "
    }
}

extension RDSGroupDecoder {
    /// Reconstruct a full PS frame (8 chars) by collecting one PS segment from
    /// each of 4 consecutive group 0 emissions. Caller must pass the 4 groups
    /// in transmission order starting from segment 0.
    static func reconstructPS(groups: [RDSDecodedGroup]) -> String {
        precondition(groups.count == 4, "PS needs 4 groups")
        var chars: [Character] = Array(repeating: " ", count: 8)
        for group in groups {
            let seg = psSegment(group)
            let (high, low) = psChars(group)
            chars[seg * 2] = high
            chars[seg * 2 + 1] = low
        }
        return String(chars)
    }

    /// Reconstruct one full RT frame (64 chars for 2A, 32 chars for 2B) by
    /// collecting characters from N consecutive group 2 emissions. Caller
    /// passes groups in transmission order starting from segment 0.
    static func reconstructRT(groups: [RDSDecodedGroup], versionB: Bool) -> String {
        let charsPerSegment = versionB ? 2 : 4
        let segments = versionB ? 16 : 16
        var chars: [Character] = Array(repeating: " ", count: segments * charsPerSegment)
        for group in groups {
            let seg = rtSegment(group)
            let rt = rtChars(group, versionB: versionB)
            let base = seg * charsPerSegment
            for (i, ch) in rt.enumerated() {
                if base + i < chars.count {
                    chars[base + i] = ch
                }
            }
        }
        return String(chars)
    }
}
