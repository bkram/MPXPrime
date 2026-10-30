import Foundation
import Testing
@testable import MPXPrime

/// `ps_frame_seconds` is clamped on load to the range the GUI and the
/// dashboard offer (0.5 ... 30 s); the coder only floored it at 0.1 s.
@Suite("Encoder config clamps")
struct EncoderConfigClampTests {
    private static func psFrameSeconds(_ text: String) throws -> Double {
        try AppConfig.loadFromINIString("[RDS]\nps_frame_seconds = \(text)\n").rdsPSFrameSeconds
    }

    @Test func psFrameSecondsIsClampedToTheOfferedRange() throws {
        #expect(try Self.psFrameSeconds("0.1") == 0.5)
        #expect(try Self.psFrameSeconds("0.5") == 0.5)
        #expect(try Self.psFrameSeconds("4.0") == 4.0)
        #expect(try Self.psFrameSeconds("30") == 30.0)
        #expect(try Self.psFrameSeconds("120") == 30.0)
    }
}
