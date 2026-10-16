import Foundation
import Testing
import MPXPrimeCore

@testable import MPXPrime

/// The `[INTERFACES]` channel keys (`input_channels`, `output_channels`,
/// `monitor_channels`): how they round-trip through the INI, that the stereo
/// default stays an EMPTY key, and that they are installation keys with the
/// same disposition as the device they belong to.
@Suite("Channel keys in AppConfig")
struct ChannelKeysConfigTests {

    private func interfaces(_ cfg: AppConfig) throws -> [String: String] {
        INIParser.parse(try cfg.captureAsINIString())["INTERFACES"] ?? [:]
    }

    @Test func defaultsWriteEmptyKeys() throws {
        let keys = try interfaces(AppConfig())
        #expect(keys["input_channels"] == "")
        #expect(keys["output_channels"] == "")
        #expect(keys["monitor_channels"] == "")
        let cfg = AppConfig()
        #expect(cfg.inputChannels == nil && cfg.outputChannels == nil && cfg.monitorChannels == nil)
    }

    @Test func pairsRoundTripOneBased() throws {
        var cfg = AppConfig()
        cfg.inputChannels = ChannelPair(left: 2, right: 3)
        cfg.outputChannels = ChannelPair(left: 6, right: 7)
        cfg.monitorChannels = ChannelPair(left: 4, right: 4)
        let keys = try interfaces(cfg)
        #expect(keys["input_channels"] == "3,4")
        #expect(keys["output_channels"] == "7,8")
        #expect(keys["monitor_channels"] == "5")
        let back = try AppConfig.loadFromINIString(try cfg.captureAsINIString())
        #expect(back.inputChannels == ChannelPair(left: 2, right: 3))
        #expect(back.outputChannels == ChannelPair(left: 6, right: 7))
        #expect(back.monitorChannels == ChannelPair(left: 4, right: 4))
    }

    @Test func theStereoDefaultIsAnEmptyKey() throws {
        // An explicit 1,2 is what every installation had before the keys
        // existed: it must not start writing "1,2" into every INI.
        var cfg = AppConfig()
        cfg.outputChannels = .stereoDefault
        #expect(try interfaces(cfg)["output_channels"] == "")
        let back = try AppConfig.loadFromINIString("[INTERFACES]\noutput_channels = 1,2\n")
        #expect(back.outputChannels == nil)
        #expect(AppConfig.channelsINIValue(.stereoDefault) == "")
        #expect(AppConfig.parseChannels("2,1") == nil, "order does not matter: 2,1 is the default pair")
    }

    @Test func unparsableValuesFallBackToTheDefault() throws {
        for raw in ["x", "0", "1,2,3", "-1", " "] {
            let back = try AppConfig.loadFromINIString("[INTERFACES]\ninput_channels = \(raw)\n")
            #expect(back.inputChannels == nil, "\(raw) parsed as \(String(describing: back.inputChannels))")
        }
    }

    @Test func theLowerNumberedChannelIsLeft() throws {
        let back = try AppConfig.loadFromINIString("[INTERFACES]\ninput_channels = 4, 3\n")
        #expect(back.inputChannels == ChannelPair(left: 2, right: 3))
        #expect(try interfaces(back)["input_channels"] == "3,4")
    }

    @Test func channelKeysAreInstallationKeys() {
        let kept = AppConfig.installationPreservedKeysBySection["INTERFACES"] ?? []
        for key in ["input_channels", "output_channels", "monitor_channels"] {
            #expect(kept.contains(key), "\(key) must ride with its device key")
        }
    }

    @Test func snapshotLoadKeepsTheLiveChannels() throws {
        // A colleague's preset carries their wiring; loading it must not
        // retarget which channels the feed leaves on.
        var theirs = AppConfig()
        theirs.outputChannels = ChannelPair(left: 0, right: 1)
        theirs.inputChannels = ChannelPair(left: 4, right: 5)
        theirs.pilotLevel = 0.09
        var live = AppConfig()
        live.outputChannels = ChannelPair(left: 6, right: 7)
        live.monitorChannels = ChannelPair(left: 2, right: 3)
        let merged = AppConfig.applyingSnapshot(
            iniText: try theirs.captureAsINIString(), preservingInstallationFrom: live)
        #expect(merged.outputChannels == ChannelPair(left: 6, right: 7))
        #expect(merged.monitorChannels == ChannelPair(left: 2, right: 3))
        #expect(merged.inputChannels == nil, "the live config had no input choice; the snapshot's must not leak in")
        #expect(abs(merged.pilotLevel - 0.09) < 1e-9, "the sound still comes from the snapshot")
    }

    @Test func dispositionsFollowTheDeviceKeys() throws {
        // The transmitter's and the input's channels are restart-class like
        // their devices; the monitor's are live like its device.
        let cfg = AppConfig()
        let (patched, outcomes, planes) = try ConfigPatch.apply([
            "input_channels": "3,4",
            "output_channels": "7,8",
            "monitor_channels": "4, 3"
        ], to: cfg)
        let byKey = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.key, $0) })
        #expect(byKey["input_channels"]?.disposition == .restartRequired)
        #expect(byKey["output_channels"]?.disposition == .restartRequired)
        #expect(byKey["monitor_channels"]?.disposition == .live)
        #expect(planes.restartRequired && planes.dspLive)
        #expect(byKey["output_channels"]?.effectiveValue == "7,8")
        #expect(byKey["monitor_channels"]?.effectiveValue == "3,4",
                "the effective value is the normalised INI spelling")
        #expect(patched.inputChannels == ChannelPair(left: 2, right: 3))
        #expect(patched.outputChannels == ChannelPair(left: 6, right: 7))
        #expect(patched.monitorChannels == ChannelPair(left: 2, right: 3))
    }

    @Test func patchingTheDefaultPairChangesNothing() throws {
        // "2,1" IS the default (lower-numbered is left), so on a config that
        // never chose channels it is a no-op, spelled "" in the response.
        let (patched, outcomes, planes) = try ConfigPatch.apply(
            ["output_channels": "2,1"], to: AppConfig())
        #expect(outcomes.first?.disposition == .unchanged)
        #expect(outcomes.first?.effectiveValue == "")
        #expect(!planes.restartRequired)
        #expect(patched.outputChannels == nil)
    }

    @Test func clearingAKeyReturnsToTheDefault() throws {
        var cfg = AppConfig()
        cfg.outputChannels = ChannelPair(left: 6, right: 7)
        let (patched, outcomes, _) = try ConfigPatch.apply(["output_channels": ""], to: cfg)
        #expect(patched.outputChannels == nil)
        #expect(outcomes.first?.disposition == .restartRequired)
    }

    @Test func theControlListingSpellsThemLikeTheINI() {
        var cfg = AppConfig()
        cfg.monitorChannels = ChannelPair(left: 2, right: 3)
        #expect(AppConfig.channelsINIValue(cfg.monitorChannels) == "3,4")
        #expect(AppConfig.channelsINIValue(cfg.inputChannels) == "")
    }
}
