import Testing
@testable import MPXPrime

/// `/api/status` reports the rate the engine RENDERS at and says so when the
/// device did not take the configured one. Found on the Intel MacBook: its
/// built-in output tops out at 96 kHz, the engine rendered at 96 kHz, and
/// status read the configured 48000 without a word.
@Suite("Status sample-rate note")
struct StatusRateNoteTests {
    @Test func silentWhenTheDeviceTookTheConfiguredRate() {
        #expect(HeadlessControlBackend.rateMismatchNote(configured: 192_000, actual: 192_000) == nil)
        #expect(HeadlessControlBackend.rateMismatchNote(configured: 48_000, actual: 48_000.4) == nil,
                "sub-hertz float noise is not a mismatch")
        #expect(HeadlessControlBackend.rateMismatchNote(configured: 192_000, actual: 0) == nil,
                "no engine, no note")
    }

    @Test func namesBothRatesWhenTheyDiffer() {
        let note = HeadlessControlBackend.rateMismatchNote(configured: 48_000, actual: 96_000)
        #expect(note?.contains("96000 Hz") == true)
        #expect(note?.contains("48000 Hz") == true)
    }
}
