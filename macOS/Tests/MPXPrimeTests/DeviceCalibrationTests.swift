import Foundation
import Testing

@testable import MPXPrime
#if os(macOS)
import MPXPrimeCore
#endif

// Per-device calibration memory (Audio I/O): the `.devicecal.json` sidecar
// remembers Input Gain per input device and MPX Output Level + Line Output
// per output device (per operating mode), recalled automatically on a device
// or mode change. Headless like every suite: no CoreAudio, stub device
// listers, temp config paths.

@Suite("Device calibration store")
struct DeviceCalibrationStoreTests {

    private func tempConfigPath() -> String {
        NSTemporaryDirectory() + "MPXPrime-DevCal-\(UUID().uuidString).ini"
    }

    private func config(
        inUID: String? = nil, outUID: String? = nil,
        inputGain: Double = 0, outputGain: Double = 0, line: Double = 0,
        processed: Bool = false
    ) -> AppConfig {
        var cfg = AppConfig()
        cfg.inputDeviceUID = inUID
        cfg.outputDeviceUID = outUID
        cfg.inputGainDB = inputGain
        cfg.outputGainDB = outputGain
        cfg.mpxLineOutputDBFS = line
        cfg.processedAudioOutput = processed
        return cfg
    }

    @Test func roundTripPersistsEntries() throws {
        let path = tempConfigPath()
        var file = DeviceCalibrationFile.empty
        _ = file.capture(
            from: config(inUID: "in-a", outUID: "out-a", inputGain: 3.5, outputGain: -6.7, line: -2.0),
            inputName: "Input A", outputName: "BOMGE USB", connectedUIDs: ["in-a", "out-a"])
        try DeviceCalibrationStore.write(file, configPath: path)
        let loaded = DeviceCalibrationStore.load(configPath: path)
        // Field-wise compare: ISO8601 truncates updatedAt to whole seconds.
        #expect(loaded.inputs.keys.sorted() == file.inputs.keys.sorted())
        #expect(loaded.outputs.keys.sorted() == file.outputs.keys.sorted())
        #expect(loaded.inputs["in-a"]?.inputGainDB == 3.5)
        #expect(loaded.outputs["out-a"]?.compositeOutputGainDB == -6.7)
        #expect(loaded.outputs["out-a"]?.compositeLineOutputDBFS == -2.0)
        #expect(loaded.outputs["out-a"]?.name == "BOMGE USB")
    }

    @Test func missingAndCorruptFilesLoadEmpty() throws {
        let path = tempConfigPath()
        #expect(DeviceCalibrationStore.load(configPath: path) == .empty)
        try "not json {{{".write(
            toFile: DeviceCalibrationStore.filePath(forConfigPath: path),
            atomically: true, encoding: .utf8)
        #expect(DeviceCalibrationStore.load(configPath: path) == .empty)
    }

    @Test func recallRestoresPerModeLevels() {
        var file = DeviceCalibrationFile.empty
        // Same output device calibrated in BOTH modes.
        _ = file.capture(
            from: config(outUID: "out-a", outputGain: -6.7, line: -3.0),
            inputName: nil, outputName: "Rig A", connectedUIDs: [])
        _ = file.capture(
            from: config(outUID: "out-a", outputGain: 4.0, processed: true),
            inputName: nil, outputName: "Rig A", connectedUIDs: [])

        var composite = config(outUID: "out-a")
        #expect(file.recall(into: &composite, recallInput: false, recallOutput: true,
                            inputName: nil, outputName: nil))
        #expect(composite.outputGainDB == -6.7)
        #expect(composite.mpxLineOutputDBFS == -3.0)

        var processed = config(outUID: "out-a", processed: true)
        #expect(file.recall(into: &processed, recallInput: false, recallOutput: true,
                            inputName: nil, outputName: nil))
        #expect(processed.outputGainDB == 4.0)
        #expect(processed.mpxLineOutputDBFS == 0.0)  // composite-only field untouched
    }

    @Test func recallMissKeepsCurrentValues() {
        let file = DeviceCalibrationFile.empty
        var cfg = config(inUID: "in-x", outUID: "out-x", inputGain: 2.0, outputGain: -4.0, line: -1.0)
        #expect(file.recall(into: &cfg, recallInput: true, recallOutput: true,
                            inputName: nil, outputName: nil) == false)
        #expect(cfg.inputGainDB == 2.0)
        #expect(cfg.outputGainDB == -4.0)
        #expect(cfg.mpxLineOutputDBFS == -1.0)
    }

    @Test func entryFromOtherModeOnlyKeepsCurrentValue() {
        var file = DeviceCalibrationFile.empty
        _ = file.capture(  // calibrated in processed mode only
            from: config(outUID: "out-a", outputGain: 6.0, processed: true),
            inputName: nil, outputName: nil, connectedUIDs: [])
        var composite = config(outUID: "out-a", outputGain: -9.0, line: -5.0)
        #expect(file.recall(into: &composite, recallInput: false, recallOutput: true,
                            inputName: nil, outputName: nil) == false)
        #expect(composite.outputGainDB == -9.0)
        #expect(composite.mpxLineOutputDBFS == -5.0)
    }

    @Test func nameFallbackSurvivesUIDDriftAndDedupes() {
        var file = DeviceCalibrationFile.empty
        _ = file.capture(  // the rig on its OLD usb-port UID
            from: config(outUID: "usb-port-1", outputGain: -6.7, line: -2.0),
            inputName: nil, outputName: "BOMGE USB", connectedUIDs: ["usb-port-1"])

        // Re-plugged: new UID, same name -- recall finds it by name.
        var cfg = config(outUID: "usb-port-2")
        #expect(file.recall(into: &cfg, recallInput: false, recallOutput: true,
                            inputName: nil, outputName: "BOMGE USB"))
        #expect(cfg.outputGainDB == -6.7)

        // The next capture migrates the entry and drops the disconnected orphan.
        _ = file.capture(
            from: cfg, inputName: nil, outputName: "BOMGE USB",
            connectedUIDs: ["usb-port-2"])
        #expect(file.outputs["usb-port-2"] != nil)
        #expect(file.outputs["usb-port-1"] == nil)
    }

    @Test func sameNameBothConnectedAreKept() {
        var file = DeviceCalibrationFile.empty
        _ = file.capture(
            from: config(outUID: "twin-1", outputGain: -3.0),
            inputName: nil, outputName: "Twin DAC", connectedUIDs: ["twin-1", "twin-2"])
        _ = file.capture(
            from: config(outUID: "twin-2", outputGain: -8.0),
            inputName: nil, outputName: "Twin DAC", connectedUIDs: ["twin-1", "twin-2"])
        #expect(file.outputs["twin-1"]?.compositeOutputGainDB == -3.0)
        #expect(file.outputs["twin-2"]?.compositeOutputGainDB == -8.0)
    }

    @Test func captureSkipsEmptyUIDs() {
        var file = DeviceCalibrationFile.empty
        #expect(file.capture(
            from: config(inputGain: 5.0, outputGain: -5.0),
            inputName: nil, outputName: nil, connectedUIDs: []) == false)
        #expect(file == .empty)
    }

    @Test func capEvictsOldestEntries() {
        var file = DeviceCalibrationFile.empty
        for i in 0..<(DeviceCalibrationStore.maxEntriesPerDirection + 1) {
            var entry = DeviceCalibration(name: "dev \(i)", updatedAt: Date(timeIntervalSince1970: Double(i)))
            entry.compositeOutputGainDB = Double(-i)
            file.outputs["uid-\(i)"] = entry
        }
        _ = file.capture(
            from: config(outUID: "uid-live", outputGain: -1.0),
            inputName: nil, outputName: "Live", connectedUIDs: [])
        #expect(file.outputs.count <= DeviceCalibrationStore.maxEntriesPerDirection)
        #expect(file.outputs["uid-0"] == nil)   // oldest evicted first
        #expect(file.outputs["uid-live"] != nil)
    }
}

#if os(macOS)
@Suite("Device calibration - view model hooks")
@MainActor
struct ViewModelDeviceCalibrationTests {

    private static let stubDevices = [
        AudioDevice(id: 1, uid: "in-a", name: "Input A", inputChannels: 2, outputChannels: 0),
        AudioDevice(id: 2, uid: "in-b", name: "Input B", inputChannels: 2, outputChannels: 0),
        AudioDevice(id: 3, uid: "out-a", name: "Rig A", inputChannels: 0, outputChannels: 2),
        AudioDevice(id: 4, uid: "out-b", name: "Rig B", inputChannels: 0, outputChannels: 2)
    ]

    private func makeModel() -> (MPXPrimeViewModel, String) {
        let path = NSTemporaryDirectory() + "MPXPrime-DevCalVM-\(UUID().uuidString).ini"
        let model = MPXPrimeViewModel(configPath: path, deviceLister: { Self.stubDevices })
        return (model, path)
    }

    @Test func switchingDevicesRecallsEachRigsCalibration() {
        let (model, path) = makeModel()
        model.selectedInputUID = "in-a"
        model.selectedOutputUID = "out-a"
        model.persistBasicConfig()
        model.setInputGainLive(4.0)
        model.config.outputGainDB = -6.7
        model.config.mpxLineOutputDBFS = -2.0
        model.persistBasicConfig()  // capture rig A

        model.selectedInputUID = "in-b"
        model.selectedOutputUID = "out-b"
        model.persistBasicConfig()  // first selection: keeps values, seeds B
        model.setInputGainLive(-3.0)
        model.config.outputGainDB = -12.0
        model.config.mpxLineOutputDBFS = -10.0
        model.persistBasicConfig()  // capture rig B

        model.selectedInputUID = "in-a"
        model.selectedOutputUID = "out-a"
        model.persistBasicConfig()  // recall rig A
        #expect(model.config.inputGainDB == 4.0)
        #expect(model.inputGainDB == 4.0)  // published mirror synced
        #expect(model.config.outputGainDB == -6.7)
        #expect(model.config.mpxLineOutputDBFS == -2.0)
        #expect(model.statusText.contains("Recalled calibration"))

        model.selectedInputUID = "in-b"
        model.selectedOutputUID = "out-b"
        model.persistBasicConfig()  // recall rig B
        #expect(model.config.inputGainDB == -3.0)
        #expect(model.config.outputGainDB == -12.0)
        #expect(model.config.mpxLineOutputDBFS == -10.0)

        // The sidecar exists next to the INI.
        #expect(FileManager.default.fileExists(
            atPath: DeviceCalibrationStore.filePath(forConfigPath: path)))
    }

    @Test func monitorDeviceChangeDoesNotRecall() {
        let (model, _) = makeModel()
        model.selectedOutputUID = "out-a"
        model.persistBasicConfig()
        model.config.outputGainDB = -5.0
        model.persistBasicConfig()
        model.selectedMonitorUID = "out-b"
        model.persistBasicConfig()
        #expect(model.config.outputGainDB == -5.0)
        #expect(!model.statusText.contains("Recalled"))
    }

    @Test func remotePatchRecallsAndExplicitLevelWins() throws {
        let (model, _) = makeModel()
        model.selectedOutputUID = "out-a"
        model.persistBasicConfig()
        model.config.outputGainDB = -6.0
        model.persistBasicConfig()  // rig A remembered at -6

        _ = try model.applyRemoteConfigPatch(["output_device_uid": "out-b"])
        model.config.outputGainDB = -15.0
        model.persistBasicConfig()  // rig B remembered at -15

        // Pure device patch back to A: recall wins.
        _ = try model.applyRemoteConfigPatch(["output_device_uid": "out-a"])
        #expect(model.config.outputGainDB == -6.0)

        // Combined device + explicit level patch: the explicit level wins
        // over rig B's remembered -15 and is stored under B.
        _ = try model.applyRemoteConfigPatch(
            ["output_device_uid": "out-b", "output_gain_db": "-2.5"])
        #expect(model.config.outputGainDB == -2.5)
    }

    @Test func externalINIReloadNeverRecalls() {
        let (model, _) = makeModel()
        model.selectedInputUID = "in-a"
        model.persistBasicConfig()
        model.setInputGainLive(4.0)
        model.persistBasicConfig()  // in-a remembered at 4.0

        // Hand-edited INI: device AND gain changed together -- the INI is
        // authoritative, the store must not fight it.
        var edited = model.config
        edited.inputDeviceUID = "in-b"
        edited.inputGainDB = 7.5
        _ = model.applyLoadedConfig(edited, origin: .external)
        #expect(model.config.inputGainDB == 7.5)
    }
}
#endif  // os(macOS)

@Suite("Device calibration - headless backend")
struct HeadlessDeviceCalibrationTests {

    struct NoEngine: Error {}

    private func makeBackend(configPath: String) -> HeadlessControlBackend {
        HeadlessControlBackend(
            config: AppConfig(),
            configPath: configPath,
            engine: nil,
            engineFactory: { _ in throw NoEngine() },
            deviceEnumerator: {
                (inputs: [ControlDevice(id: "hw:in", name: "Stub In", canInput: true, canOutput: false)],
                 outputs: [
                    ControlDevice(id: "hw:rig", name: "Stub Rig", canInput: false, canOutput: true),
                    ControlDevice(id: "hw:out-b", name: "Rig B", canInput: false, canOutput: true)
                 ],
                 note: "")
            }
        )
    }

    @Test func devicePatchRecallsSeededCalibration() async throws {
        let path = NSTemporaryDirectory() + "MPXPrime-DevCalHL-\(UUID().uuidString).ini"
        var seeded = DeviceCalibrationFile.empty
        var entry = DeviceCalibration(name: "Rig B", updatedAt: Date())
        entry.compositeOutputGainDB = -5.5
        entry.compositeLineOutputDBFS = -12.0
        seeded.outputs["hw:out-b"] = entry
        try DeviceCalibrationStore.write(seeded, configPath: path)

        let backend = makeBackend(configPath: path)
        _ = try await backend.applyConfigPatch(["output_device_uid": "hw:out-b"])
        let sections = try await backend.configSections()
        #expect(sections["MPX"]?["output_gain_db"].flatMap(Double.init) == -5.5)
        #expect(sections["MPX"]?["mpx_line_output_dbfs"].flatMap(Double.init) == -12.0)
    }

    @Test func levelPatchWritesThroughUnderCurrentDevice() async throws {
        let path = NSTemporaryDirectory() + "MPXPrime-DevCalHL-\(UUID().uuidString).ini"
        let backend = makeBackend(configPath: path)
        _ = try await backend.applyConfigPatch(["output_device_uid": "hw:rig"])
        _ = try await backend.applyConfigPatch(["output_gain_db": "-7.25"])
        let store = DeviceCalibrationStore.load(configPath: path)
        #expect(store.outputs["hw:rig"]?.compositeOutputGainDB == -7.25)
    }

    @Test func snapshotLoadPreservesInstallationKeys() async throws {
        let path = NSTemporaryDirectory() + "MPXPrime-DevCalHL-\(UUID().uuidString).ini"
        let backend = makeBackend(configPath: path)
        // Save a snapshot at defaults, then move installation + sound keys.
        _ = try await backend.snapshotSave(slot: 0, name: "Sound")
        _ = try await backend.applyConfigPatch([
            "output_device_uid": "hw:rig",
            "output_gain_db": "-9.0",
            "pilot_level": "0.10",
        ])
        _ = try await backend.snapshotLoad(slot: 0)
        let sections = try await backend.configSections()
        // Installation preserved from live...
        #expect(sections["INTERFACES"]?["output_device_uid"] == "hw:rig")
        #expect(sections["MPX"]?["output_gain_db"].flatMap(Double.init) == -9.0)
        // ...sound restored from the snapshot.
        #expect(sections["MPX"]?["pilot_level"].flatMap(Double.init) == 0.08)
    }
}
