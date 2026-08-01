import Foundation
import Testing

@testable import MPXPrime

// The RT / PS / RT+ templates must never air a half-filled now-playing line:
// a segment referencing {artist}/{title}/{display} whose value is empty is
// dropped (per-macro, not all-or-nothing). A "/"-segmented template thus
// falls back to its static segment when metadata is missing or partial.
@Suite("Now-playing empty-macro skip")
struct NowPlayingSkipTests {
    private func snap(artist: String = "", title: String = "", display: String = "")
        -> NowPlayingSnapshot {
        NowPlayingSnapshot(display: display, artist: artist, title: title, revision: 1)
    }

    @Test func fullMetadataRendersTemplate() {
        let out = NowPlayingFormatter.expandTemplate(
            "{artist} - {title}", snapshot: snap(artist: "Joe Bataan", title: "Rap-O Clap-O",
                                                 display: "Joe Bataan - Rap-O Clap-O"))
        #expect(out == "Joe Bataan - Rap-O Clap-O")
    }

    @Test func plainTemplateWithMissingArtistIsDropped() {
        // title present, artist empty -> the whole line references {artist},
        // so it is skipped rather than aired as " - Title".
        let out = NowPlayingFormatter.expandTemplate(
            "{artist} - {title}", snapshot: snap(title: "Rap-O Clap-O", display: "Rap-O Clap-O"))
        #expect(out.isEmpty)
    }

    @Test func segmentedTemplateFallsBackToStaticWhenNothingPlaying() {
        // Nothing playing -> the track segment drops, the station segment stays.
        let out = NowPlayingFormatter.expandTemplate(
            "10s:{artist} - {title}/10s:My Station", snapshot: snap())
        #expect(out == "10s:My Station")
    }

    @Test func segmentedTemplateSkipsTrackSegmentOnPartialMetadata() {
        // Title only -> the {artist} track segment drops, static stays.
        let out = NowPlayingFormatter.expandTemplate(
            "10s:{artist} - {title}/10s:My Station",
            snapshot: snap(title: "Rap-O Clap-O", display: "Rap-O Clap-O"))
        #expect(out == "10s:My Station")
    }

    @Test func emptyScriptPathNeverResolvesToADirectory() {
        // The 0.43 poller bug: normalizeScriptPath("") resolved to the launch
        // directory, which the poller then tried to execute every poll --
        // failing, and clearing any API-pushed track. Empty (or whitespace)
        // input must stay empty; real paths must still normalize.
        #expect(NowPlayingFormatter.normalizeScriptPath("") == "")
        #expect(NowPlayingFormatter.normalizeScriptPath("   ") == "")
        #expect(NowPlayingFormatter.normalizeScriptPath("\n\t") == "")
        #expect(NowPlayingFormatter.normalizeScriptPath("/usr/local/bin/np.sh")
            == "/usr/local/bin/np.sh")
        #expect(NowPlayingFormatter.normalizeScriptPath("~/np.sh").hasSuffix("/np.sh"))
        #expect(!NowPlayingFormatter.normalizeScriptPath("~/np.sh").contains("~"))
    }

    @Test func nonNowPlayingMacrosPassThrough() {
        // A template with no now-playing macro is never filtered (it may carry
        // {time}/{date} or static text).
        let out = NowPlayingFormatter.expandTemplate("My Station", snapshot: snap())
        #expect(out == "My Station")
    }

    // Regression: an empty script path must resolve to empty, not the working
    // directory. normalizeScriptPath("") used to return the CWD, so the poller
    // launched it, failed, and cleared API-pushed now-playing every poll.
    @Test func emptyScriptPathStaysEmpty() {
        var cfg = AppConfig()
        cfg.rdsNowPlayingEnabled = true
        cfg.rdsNowPlayingScript = ""
        let settings = NowPlayingScriptRunner.Settings(config: cfg)
        #expect(settings.scriptPath.isEmpty)
        cfg.rdsNowPlayingScript = "   "
        #expect(NowPlayingScriptRunner.Settings(config: cfg).scriptPath.isEmpty)
    }
}
