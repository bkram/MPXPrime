import Foundation
import Testing

@testable import MPXPrime

/// The device-volume arithmetic and decisions, tested on whatever platform
/// this runs on: the HAL binding is macOS-only, but which element to use,
/// how a slider position becomes a percent and a dB figure, when a configured
/// level is re-asserted and when the output earns a routing note are plain
/// logic (the `ALSAMixerMath` pattern).
///
/// Why this exists: the station's DX3 Pro+ sat at -5.00 dB in CoreAudio
/// (scalar 0.9228, dB range -127..0) while the app applied -5 dBFS line
/// output as well, and nothing in the app could see it.
@Suite("CoreAudio device volume math")
struct CoreAudioDeviceVolumeMathTests {
    typealias Math = CoreAudioDeviceVolumeMath

    /// The DX3 Pro+ as the HAL reported it on 2026-10-20.
    private func dx3(decibels: Double = -5.0, muted: Bool? = false) -> Math.Probe {
        Math.Probe(
            mainHasVolume: true, channelElements: [1, 2], scalar: 0.9228, decibels: decibels,
            rangeDB: ControlDBRange(minDB: -127, maxDB: 0), muted: muted, settable: true)
    }

    @Test func theMainElementWinsOverTheChannels() {
        #expect(Math.elementChoice(mainHasVolume: true, channelElements: [1, 2]) == .main)
        #expect(Math.elementChoice(mainHasVolume: false, channelElements: [1, 2]) == .channels([1, 2]))
        // BlackHole: no volume anywhere, which is "no control", not an error.
        #expect(Math.elementChoice(mainHasVolume: false, channelElements: []) == .none)
    }

    @Test func percentIsTheSliderPositionClamped() {
        #expect(abs(Math.percent(fromScalar: 0.9228) - 92.28) < 0.001)
        #expect(Math.percent(fromScalar: 1.0) == 100)
        #expect(Math.percent(fromScalar: 1.7) == 100)
        #expect(Math.percent(fromScalar: -0.2) == 0)
        #expect(Math.scalar(fromPercent: 50) == 0.5)
        #expect(Math.scalar(fromPercent: 120) == 1.0)
        #expect(Math.scalar(fromPercent: -3) == 0.0)
    }

    @Test func theDBEstimateIsOnlyForDevicesWithoutADBScale() {
        // The device's own figure always wins: the DX3's 0.9228 is -5 dB on
        // its scale, where the amplitude formula would say -0.7 dB.
        #expect(Math.effectiveDecibels(dx3()) == -5.0)
        var scalarOnly = dx3()
        scalarOnly.decibels = nil
        let estimate = Math.effectiveDecibels(scalarOnly)
        #expect(estimate != nil)
        if let estimate { #expect(abs(estimate - (-0.698)) < 0.01) }
        // Full scale is 0 dB, silence bottoms out at the range floor.
        #expect(Math.estimatedDecibels(fromScalar: 1.0, range: nil) == 0)
        #expect(Math.estimatedDecibels(fromScalar: 0.0, range: ControlDBRange(minDB: -96, maxDB: 0)) == -96)
        #expect(Math.estimatedDecibels(fromScalar: 0.0, range: nil) == Math.estimateFloorDB)
        // And back, clamped to a scalar.
        #expect(abs(Math.estimatedScalar(fromDecibels: -6.0206) - 0.5) < 0.001)
        #expect(Math.estimatedScalar(fromDecibels: 3) == 1.0)
    }

    @Test func aRequestedLevelIsClampedIntoTheDeviceRange() {
        let range = ControlDBRange(minDB: -127, maxDB: 0)
        #expect(Math.clampedDecibels(3, range: range) == 0)
        #expect(Math.clampedDecibels(-200, range: range) == -127)
        #expect(Math.clampedDecibels(-5, range: range) == -5)
        #expect(Math.clampedDecibels(-5, range: nil) == -5)
        // An inverted range is ignored rather than trusted.
        #expect(Math.clampedDecibels(-5, range: ControlDBRange(minDB: 0, maxDB: -10)) == -5)
    }

    @Test func assertingMovesOnlyADriftedLevelAndUnmutesAManagedOutput() {
        // Within the tolerance: leave the device alone (every 5 s, forever).
        #expect(Math.assertActions(have: -0.1, muted: false, want: 0) == .init(setLevel: false, unmute: false))
        #expect(Math.assertActions(have: 0.25, muted: false, want: 0) == .init(setLevel: false, unmute: false))
        // The field case: -5 dB against a configured 0 dB.
        #expect(Math.assertActions(have: -5.0, muted: false, want: 0) == .init(setLevel: true, unmute: false))
        // No dB reading: nothing to compare, like the ALSA path.
        #expect(Math.assertActions(have: nil, muted: false, want: 0) == .init(setLevel: false, unmute: false))
        // A managed output that is muted delivers nothing: unmute it.
        #expect(Math.assertActions(have: 0, muted: true, want: 0) == .init(setLevel: false, unmute: true))
        #expect(Math.assertActions(have: 0, muted: nil, want: 0) == .init(setLevel: false, unmute: false))
    }

    @Test func theRoutingNoteFiresBelowUnityOrMuted() {
        let note = Math.lowOutputNote(deviceName: "DX3 Pro+", probe: dx3())
        #expect(note == "DX3 Pro+ output volume is -5.0 dB in CoreAudio; the composite reaches the exciter "
            + "5 dB low. Set it to 0 dB here or in Audio MIDI Setup.")
        #expect(Math.lowOutputNote(deviceName: "DX3 Pro+", probe: dx3(decibels: 0)) == nil)
        #expect(Math.lowOutputNote(deviceName: "DX3 Pro+", probe: dx3(decibels: -0.05)) == nil)
        #expect(Math.lowOutputNote(deviceName: "DX3 Pro+", probe: dx3(decibels: -0.2)) != nil)
        let muted = Math.lowOutputNote(deviceName: "DX3 Pro+", probe: dx3(decibels: 0, muted: true))
        #expect(muted == "DX3 Pro+ output is muted in CoreAudio; nothing reaches the exciter. "
            + "Unmute it here or in Audio MIDI Setup.")
        // No control at all: nothing to say about it.
        #expect(Math.lowOutputNote(deviceName: "BlackHole 2ch", probe: Math.Probe()) == nil)
        // A half-dB shortfall keeps its decimal; a whole number drops it.
        #expect(Math.compactDB(2.5) == "2.5")
        #expect(Math.compactDB(5.0) == "5")
        #expect(Math.compactDB(4.96) == "5")
    }

    @Test func theDashboardControlCarriesTheDeviceAsOneControl() {
        let playback = Math.control(deviceName: "DX3 Pro+", side: .playback, probe: dx3())
        #expect(playback?.name == "DX3 Pro+")
        #expect(playback?.index == 0)
        #expect(playback?.playbackDB == -5.0)
        #expect(playback?.playbackMuted == false)
        #expect(playback?.capturePercent == nil)
        if let percent = playback?.playbackPercent { #expect(abs(percent - 92.28) < 0.001) }
        let capture = Math.control(deviceName: "Scarlett", side: .capture, probe: dx3(decibels: 0))
        #expect(capture?.captureDB == 0)
        #expect(capture?.playbackPercent == nil)
        // No volume: no control, so the dashboard draws no row.
        #expect(Math.control(deviceName: "BlackHole 2ch", side: .capture, probe: Math.Probe()) == nil)
    }

    @Test func aPatchMustNameTheDeviceOrNothing() {
        #expect(Math.patchNamesDevice("DX3 Pro+", deviceName: "DX3 Pro+"))
        #expect(Math.patchNamesDevice("", deviceName: "DX3 Pro+"))
        #expect(!Math.patchNamesDevice("Headphone", deviceName: "DX3 Pro+"))
    }

    @Test func theGUIRowReadsTheMixerPayload() {
        var mixer = ControlMixer(available: true, card: nil, controls: [], note: nil)
        guard let control = Math.control(deviceName: "DX3 Pro+", side: .playback, probe: dx3()) else {
            Issue.record("no playback control from the DX3 probe")
            return
        }
        mixer.controls = [control]
        mixer.playbackDeviceName = "DX3 Pro+"
        mixer.playbackSettable = true
        mixer.playbackDBEstimated = false
        let display = Math.display(from: mixer, side: .playback)
        #expect(display?.deviceName == "DX3 Pro+")
        #expect(display?.text == "-5.0 dB (92 %)")
        #expect(display?.atUnity == false)
        #expect(display?.settable == true)
        #expect(Math.display(from: mixer, side: .capture) == nil)

        var unity = Math.display(deviceName: "DX3 Pro+", probe: dx3(decibels: 0))
        #expect(unity?.atUnity == true)
        #expect(unity?.text == "0.0 dB (92 %)")
        unity?.muted = true
        #expect(unity?.atUnity == false)
        #expect(unity?.text == "muted, 0.0 dB (92 %)")

        var scalarOnly = dx3()
        scalarOnly.decibels = nil
        let estimated = Math.display(deviceName: "Generic USB", probe: scalarOnly)
        #expect(estimated?.estimated == true)
        #expect(estimated?.text == "approx. -0.7 dB (92 %)")
    }

    @Test func theUnityPatchSetsZeroDBAndUnmutesOneSide() {
        let playback = Math.unityPatch(deviceName: "DX3 Pro+", side: .playback)
        #expect(playback.name == "DX3 Pro+")
        #expect(playback.playbackDB == 0)
        #expect(playback.playbackMuted == false)
        #expect(playback.captureDB == nil && playback.captureMuted == nil)
        let capture = Math.unityPatch(deviceName: "Scarlett", side: .capture)
        #expect(capture.captureDB == 0)
        #expect(capture.playbackDB == nil)
    }

    @Test func theUnavailableServiceIsANormalEmptyAnswer() {
        let mixer = DeviceVolumeService.unavailable.read(nil, nil)
        #expect(!mixer.available)
        #expect(mixer.controls.isEmpty)
        #expect(mixer.note != nil)
        #expect(DeviceVolumeService.unavailable.apply(ControlMixerPatch(name: ""), nil, nil) == nil)
        #expect(DeviceVolumeService.unavailable.assertLevels(0, 0, nil, nil).isEmpty)
        #expect(DeviceVolumeService.unavailable.outputNote(nil) == nil)
    }
}

/// The platform-neutral `card_*` level keys and their pre-0.65 `alsa_*`
/// aliases: one storage, both spellings written, the new one decides when
/// present, the API accepts either and the backends classify both as their
/// own (`none`, never restart-class).
@Suite("Sound-card level keys and aliases")
struct DeviceVolumeConfigKeysTests {

    @Test func aLegacyINIStillLoadsTheAlsaSpelling() throws {
        let legacy = """
        [INTERFACES]
        alsa_playback_volume_db = -2.0
        alsa_capture_volume_db = 3.5
        """
        let cfg = try AppConfig.loadFromINIString(legacy)
        #expect(cfg.alsaPlaybackVolumeDB == -2.0)
        #expect(cfg.alsaCaptureVolumeDB == 3.5)
        // And it is written back under both names.
        let text = try cfg.captureAsINIString()
        #expect(text.contains("card_playback_volume_db = -2.0"))
        #expect(text.contains("alsa_playback_volume_db = -2.0"))
        #expect(text.contains("card_capture_volume_db = 3.5"))
    }

    @Test func thePlatformNeutralKeyDecidesWheneverItIsPresent() throws {
        // A hand-blanked card_* key means unmanaged even if a stale alias
        // still carries a value (a saved INI always carries card_*).
        let blanked = """
        [INTERFACES]
        card_playback_volume_db =
        alsa_playback_volume_db = -2.0
        """
        #expect(try AppConfig.loadFromINIString(blanked).alsaPlaybackVolumeDB == nil)
        let both = """
        [INTERFACES]
        card_playback_volume_db = 0
        alsa_playback_volume_db = -2.0
        """
        #expect(try AppConfig.loadFromINIString(both).alsaPlaybackVolumeDB == 0)
    }

    @Test func eitherSpellingPatchesBothWithoutARestart() throws {
        let cfg = AppConfig()
        for key in ["card_playback_volume_db", "alsa_playback_volume_db"] {
            let (patched, outcomes, planes) = try ConfigPatch.apply([key: "-3"], to: cfg)
            #expect(outcomes[0].disposition == .none, "\(key) reported \(outcomes[0].disposition)")
            #expect(!planes.restartRequired && !planes.dspLive && !planes.rdsLive)
            #expect(patched.alsaPlaybackVolumeDB == -3.0)
            let sections = try ConfigPatch.sectionedValues(of: patched)
            #expect(sections["INTERFACES"]?["card_playback_volume_db"] == "-3.0")
            #expect(sections["INTERFACES"]?["alsa_playback_volume_db"] == "-3.0")
            // Clearing through either spelling clears the one value.
            let (cleared, outcome, _) = try ConfigPatch.apply([key: ""], to: patched)
            #expect(outcome[0].disposition == .none)
            #expect(cleared.alsaPlaybackVolumeDB == nil)
        }
        #expect(ConfigPatch.backendOwnedKeys == [
            "card_playback_volume_db", "card_capture_volume_db",
            "alsa_playback_volume_db", "alsa_capture_volume_db"
        ])
    }

    @Test func theLevelKeysSurviveASnapshotLoad() throws {
        var live = AppConfig()
        live.alsaPlaybackVolumeDB = 0
        live.alsaCaptureVolumeDB = -1.5
        var snapshot = AppConfig()
        snapshot.alsaPlaybackVolumeDB = -9
        snapshot.finalDriveDB = 7
        let merged = AppConfig.applyingSnapshot(
            iniText: try snapshot.captureAsINIString(), preservingInstallationFrom: live)
        #expect(merged.alsaPlaybackVolumeDB == 0)
        #expect(merged.alsaCaptureVolumeDB == -1.5)
        #expect(merged.finalDriveDB == 7)
        for key in AppConfig.cardVolumeKeys.keys {
            #expect(AppConfig.installationPreservedKeysBySection["INTERFACES"]?.contains(key) == true)
        }
    }
}
