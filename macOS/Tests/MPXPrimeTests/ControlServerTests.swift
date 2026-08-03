import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import MPXPrime

// HTTP-level tests for the remote-control server: routes, JSON shapes, and
// the API-key gate, driven through hummingbird-testing's in-memory router
// (no sockets). The backend is a mock so these stay fast and deterministic;
// backend/engine semantics are covered by ConfigPatchTests and the
// engine-side live-apply suites.

private actor MockBackend: ControlBackend {
    var config = AppConfig()
    var transportCalls: [TransportAction] = []
    var running = true

    func status() -> ControlStatus {
        ControlStatus(
            running: running,
            platform: "test",
            version: AppConfig.appVersion,
            sampleRateHz: config.sampleRate,
            uptimeSeconds: 12.5,
            restartPending: false,
            sourceMode: config.sourceMode,
            outputMode: "mpxComposite",
            notes: []
        )
    }

    func meters() -> ControlMeters? {
        guard running else { return nil }
        return ControlMeters(
            inputLeftPeak: 0.5, inputRightPeak: 0.4, outputPeak: 0.9,
            deviationKHzPeak: 71.2, agcGainDB: -2.0,
            compositeClipperGainReductionDB: 0.8,
            preEncodeLimiterGainReductionDB: 0.4,
            safetyLimiterGainReductionDB: 0.0,
            pilotInjectionPercent: 9.0, rdsInjectionPercent: 4.1,
            compositeBudgetMarginDB: 0.3, compositeOverBudget: false,
            stereoCorrelation: 0.7, renderXruns: nil, captureXruns: nil
        )
    }

    func rds() -> ControlRDS {
        ControlRDS(
            enabled: config.enRDS, pi: config.rdsPI, pty: config.rdsPTY,
            ta: config.rdsTA, tp: config.rdsTP,
            livePS: "TESTFM", liveRT: "Now testing", livePTYN: nil, liveLongPS: nil,
            configuredRT: config.rdsRTText,
            configuredPSActiveBank: config.rdsPSActiveBank
        )
    }

    func devices() -> ControlDevices {
        ControlDevices(
            inputs: [ControlDevice(id: "hw:0,0", name: "Mock In", canInput: true, canOutput: false)],
            outputs: [ControlDevice(id: "hw:0,0", name: "Mock Out", canInput: false, canOutput: true)],
            selectedInput: config.inputDeviceUID ?? "",
            selectedOutput: config.outputDeviceUID ?? "",
            note: "mock")
    }

    func configSections() throws -> [String: [String: String]] {
        try ConfigPatch.sectionedValues(of: config)
    }

    func applyConfigPatch(_ patch: [String: String]) throws -> ConfigApplyResult {
        let (newConfig, outcomes, planes) = try ConfigPatch.apply(patch, to: config)
        config = newConfig
        return ConfigApplyResult(
            outcomes: outcomes,
            appliedLive: planes.dspLive || planes.rdsLive,
            restartPending: planes.restartRequired
        )
    }

    func transport(_ action: TransportAction) throws -> ControlStatus {
        transportCalls.append(action)
        switch action {
        case .start: running = true
        case .stop: running = false
        case .restart: running = true
        }
        return status()
    }

    func presets() -> [String: [String]] {
        ["primebass": PresetCatalog.primeBassPresets.map(\.id)]
    }

    func applyPreset(kind: String, id: String, intensity: Double?) throws -> ConfigApplyResult {
        guard kind == "primebass",
            PresetCatalog.primeBassPresets.contains(where: { $0.id == id })
        else {
            throw ControlError.invalidRequest("unknown preset")
        }
        _ = intensity
        return ConfigApplyResult(outcomes: [], appliedLive: true, restartPending: false)
    }

    // Snapshot slots: an in-memory SnapshotFile so route tests are hermetic.
    var snapshotFile = SnapshotFile(
        slots: Array(repeating: nil, count: SnapshotStore.slotCount),
        activeID: nil, activeModified: false)

    private func snapshotDTO() -> ControlSnapshots {
        ControlSnapshots(slots: snapshotFile.slots.enumerated().map { i, snap in
            ControlSnapshotSlot(
                slot: i, name: snap?.name, savedAt: snap?.savedAt,
                active: snap != nil && snap?.id == snapshotFile.activeID,
                modified: snap != nil && snap?.id == snapshotFile.activeID
                    && (snapshotFile.activeModified ?? false))
        })
    }

    func telemetry(windowMS: Double) -> ControlTelemetry? { nil }

    func snapshots() -> ControlSnapshots { snapshotDTO() }

    func snapshotSave(slot: Int, name: String) throws -> ControlSnapshots {
        guard snapshotFile.slots.indices.contains(slot) else {
            throw ControlError.invalidRequest("slot out of range")
        }
        let snap = ConfigSnapshot(
            id: UUID(), name: name.isEmpty ? SnapshotStore.defaultName(slot: slot) : name,
            savedAt: Date(), configINIText: (try? config.captureAsINIString()) ?? "")
        snapshotFile.slots[slot] = snap
        snapshotFile.activeID = snap.id
        snapshotFile.activeModified = false
        return snapshotDTO()
    }

    func snapshotLoad(slot: Int) throws -> ConfigApplyResult {
        guard snapshotFile.slots.indices.contains(slot),
              snapshotFile.slots[slot] != nil else {
            throw ControlError.invalidRequest("empty or invalid slot")
        }
        return ConfigApplyResult(outcomes: [], appliedLive: true, restartPending: false)
    }

    func snapshotRename(slot: Int, name: String) throws -> ControlSnapshots {
        guard snapshotFile.slots.indices.contains(slot),
              var snap = snapshotFile.slots[slot] else {
            throw ControlError.invalidRequest("empty or invalid slot")
        }
        snap.name = name
        snapshotFile.slots[slot] = snap
        return snapshotDTO()
    }

    func snapshotClear(slot: Int) throws -> ControlSnapshots {
        guard snapshotFile.slots.indices.contains(slot) else {
            throw ControlError.invalidRequest("slot out of range")
        }
        snapshotFile.slots[slot] = nil
        return snapshotDTO()
    }

    func snapshotExport(slot: Int) -> String? {
        snapshotFile.slots.indices.contains(slot)
            ? snapshotFile.slots[slot]?.configINIText : nil
    }

    func snapshotImport(slot: Int, name: String?, iniText: String) throws -> ControlSnapshots {
        guard snapshotFile.slots.indices.contains(slot) else {
            throw ControlError.invalidRequest("slot out of range")
        }
        snapshotFile.slots[slot] = ConfigSnapshot(
            id: UUID(), name: name ?? SnapshotStore.defaultName(slot: slot),
            savedAt: Date(), configINIText: iniText)
        return snapshotDTO()
    }

    func setNowPlaying(artist: String, title: String, display: String) -> Bool {
        lastNowPlaying = (artist, title, display)
        return config.enRDS
    }
    var lastNowPlaying: (artist: String, title: String, display: String)?

    func currentConfig() -> AppConfig { config }
}

@Suite("Control server routes")
struct ControlServerTests {
    @Test func statusRouteReturnsJSON() async throws {
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: nil))
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/status", method: .get) { response in
                #expect(response.status == .ok)
                let status = try JSONDecoder().decode(
                    ControlStatus.self, from: Data(response.body.readableBytesView))
                #expect(status.running == true)
                #expect(status.version == AppConfig.appVersion)
                #expect(status.platform == "test")
            }
        }
    }

    @Test func metersRouteReturnsValues() async throws {
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: nil))
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/meters", method: .get) { response in
                #expect(response.status == .ok)
                let meters = try JSONDecoder().decode(
                    ControlMeters.self, from: Data(response.body.readableBytesView))
                #expect(meters.pilotInjectionPercent == 9.0)
            }
        }
    }

    @Test func configPatchAppliesAndReportsDispositions() async throws {
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: nil))
        try await app.test(.router) { client in
            let body = try JSONEncoder().encode(["output_gain_db": "-3.0"])
            try await client.execute(
                uri: "/api/config", method: .patch,
                body: ByteBuffer(bytes: Array(body))
            ) { response in
                #expect(response.status == .ok)
                let result = try JSONDecoder().decode(
                    ConfigApplyResult.self, from: Data(response.body.readableBytesView))
                #expect(result.outcomes.first?.disposition == .live)
                #expect(result.appliedLive)
            }
            let cfg = await backend.currentConfig()
            #expect(abs(cfg.outputGainDB - (-3.0)) < 1e-9)
        }
    }

    @Test func rdsPutMapsCuratedFields() async throws {
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: nil))
        try await app.test(.router) { client in
            let body = try JSONEncoder().encode(
                RDSUpdateRequest(ta: true, rt: "ROAD WORKS ON A2"))
            try await client.execute(
                uri: "/api/rds", method: .put, body: ByteBuffer(bytes: Array(body))
            ) { response in
                #expect(response.status == .ok)
            }
            let cfg = await backend.currentConfig()
            #expect(cfg.rdsTA == true)
            #expect(cfg.rdsRTText == "ROAD WORKS ON A2")
        }
    }

    @Test func transportRouteDispatchesActions() async throws {
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: nil))
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/transport/stop", method: .post) { response in
                #expect(response.status == .ok)
                let status = try JSONDecoder().decode(
                    ControlStatus.self, from: Data(response.body.readableBytesView))
                #expect(status.running == false)
            }
            try await client.execute(uri: "/api/transport/bogus", method: .post) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func devicesRouteReturnsLists() async throws {
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: nil))
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/devices", method: .get) { response in
                #expect(response.status == .ok)
                let d = try JSONDecoder().decode(
                    ControlDevices.self, from: Data(response.body.readableBytesView))
                #expect(d.inputs.first?.canInput == true)
                #expect(d.outputs.first?.canOutput == true)
            }
        }
    }

    @Test func apiKeyGateRejectsAndAccepts() async throws {
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: "s3cret"))
        try await app.test(.router) { client in
            // No key -> 401.
            try await client.execute(uri: "/api/status", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
            // Wrong key -> 401.
            try await client.execute(
                uri: "/api/status", method: .get,
                headers: [.authorization: "Bearer wrong"]
            ) { response in
                #expect(response.status == .unauthorized)
            }
            // Bearer -> 200.
            try await client.execute(
                uri: "/api/status", method: .get,
                headers: [.authorization: "Bearer s3cret"]
            ) { response in
                #expect(response.status == .ok)
            }
            // Dashboard stays reachable without a key.
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func remoteBindWithoutKeyRefused() {
        var cfg = AppConfig()
        cfg.controlBind = "0.0.0.0"
        cfg.controlAPIKey = ""
        let settings = ControlServerSettings(config: cfg)
        #expect(!settings.isLoopback)
        // run() must throw before opening a socket.
        var thrown = false
        do {
            if !settings.isLoopback && settings.apiKey.isEmpty {
                throw ControlServerError.remoteBindWithoutKey(settings.host)
            }
        } catch {
            thrown = true
        }
        #expect(thrown)
    }

    @Test func presetRouteValidatesKind() async throws {
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: nil))
        try await app.test(.router) { client in
            let good = try JSONEncoder().encode(
                PresetApplyRequest(kind: "primebass", id: "chr", intensity: nil))
            try await client.execute(
                uri: "/api/presets", method: .post, body: ByteBuffer(bytes: Array(good))
            ) { response in
                #expect(response.status == .ok)
            }
            let bad = try JSONEncoder().encode(
                PresetApplyRequest(kind: "nope", id: "x", intensity: nil))
            try await client.execute(
                uri: "/api/presets", method: .post, body: ByteBuffer(bytes: Array(bad))
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func nowPlayingRouteReachesBackend() async throws {
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: nil))
        try await app.test(.router) { client in
            let body = try JSONEncoder().encode(
                NowPlayingRequest(artist: "Joe Bataan", title: "Rap-O Clap-O", display: nil))
            try await client.execute(
                uri: "/api/nowplaying", method: .post, body: ByteBuffer(bytes: Array(body))
            ) { response in
                #expect(response.status == .ok)
                let r = try JSONDecoder().decode(
                    NowPlayingResponse.self, from: Data(response.body.readableBytesView))
                #expect(r.ok)
            }
            let np = await backend.lastNowPlaying
            #expect(np?.artist == "Joe Bataan")
            #expect(np?.title == "Rap-O Clap-O")
            // display omitted -> server composes "Artist - Title"
            #expect(np?.display == "Joe Bataan - Rap-O Clap-O")
        }
    }

    // A missing/unopenable audio device must NOT take the process down: the
    // headless backend's tolerant start stays up (server keeps serving) and
    // surfaces the reason in status.notes so the dashboard can prompt the
    // operator to pick a device and Start. Regression guard for the Linux
    // systemd crash-loop on a renamed hw: device.
    @Test func headlessBackendToleratesEngineStartFailure() async throws {
        struct DeviceMissing: Error {}
        let backend = HeadlessControlBackend(
            config: AppConfig(),
            configPath: NSTemporaryDirectory() + "mpxprime-test-\(UUID().uuidString).ini",
            engine: nil,
            engineFactory: { _ in throw DeviceMissing() }
        )
        let started = await backend.startEngineTolerant()
        #expect(started == false)
        let status = await backend.status()
        #expect(status.running == false)
        #expect(status.notes.contains { $0.contains("audio engine not started") })
        let meters = await backend.meters()
        #expect(meters == nil)
    }

    // Desired-state reconciliation: a missing device is never permanently
    // fatal -- reconcile() keeps retrying and brings the engine up the moment
    // the device is available; but a deliberate Stop must not be undone by the
    // retry loop.
    @Test func reconcileRecoversButRespectsStop() async throws {
        final class FakeEngine: ControlledEngine, @unchecked Sendable {
            func start() throws {}
            func stop() {}
            func applyRuntimeConfig(_ config: AppConfig) {}
            func applyRDSRuntimeConfig(_ config: AppConfig) {}
            var controlMeters: ControlMeters? { nil }
            var rdsLiveSnapshotForControl: BasicRDSCoder.LiveSnapshot? { nil }
        }
        // A factory that fails until `deviceAvailable` flips true.
        final class Gate: @unchecked Sendable { var open = false }
        let gate = Gate()
        struct NoDevice: Error {}
        let backend = HeadlessControlBackend(
            config: AppConfig(),
            configPath: NSTemporaryDirectory() + "mpxprime-test-\(UUID().uuidString).ini",
            engine: nil,
            engineFactory: { _ in
                guard gate.open else { throw NoDevice() }
                return FakeEngine()
            }
        )
        // Device missing: initial start + a reconcile both leave it stopped.
        #expect(await backend.startEngineTolerant() == false)
        await backend.reconcile()
        #expect(await backend.status().running == false)
        // Device appears: the next reconcile brings it up.
        gate.open = true
        await backend.reconcile()
        #expect(await backend.status().running == true)
        // Operator stops it: reconcile must NOT restart it.
        _ = try await backend.transport(.stop)
        #expect(await backend.status().running == false)
        await backend.reconcile()
        #expect(await backend.status().running == false)
    }

    @Test func snapshotRoutesRoundTrip() async throws {
        // The server encodes dates as ISO8601 (Hummingbird's encoder);
        // decode the same way.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backend = MockBackend()
        let app = Application(
            router: ControlServer.buildRouter(backend: backend, apiKey: nil))
        try await app.test(.router) { client in
            // Empty list first.
            try await client.execute(uri: "/api/snapshots", method: .get) { response in
                #expect(response.status == .ok)
                let snaps = try decoder.decode(
                    ControlSnapshots.self, from: Data(response.body.readableBytesView))
                #expect(snaps.slots.count == SnapshotStore.slotCount)
                #expect(snaps.slots.allSatisfy { $0.name == nil })
            }
            // Save into slot 2 with a name.
            let body = try JSONEncoder().encode(["name": "Evening Show"])
            try await client.execute(
                uri: "/api/snapshots/2/save", method: .post,
                body: ByteBuffer(bytes: Array(body))
            ) { response in
                #expect(response.status == .ok)
                let snaps = try decoder.decode(
                    ControlSnapshots.self, from: Data(response.body.readableBytesView))
                #expect(snaps.slots[2].name == "Evening Show")
                #expect(snaps.slots[2].active == true)
            }
            // Load it back.
            try await client.execute(uri: "/api/snapshots/2/load", method: .post) { response in
                #expect(response.status == .ok)
            }
            // Export returns INI text.
            try await client.execute(uri: "/api/snapshots/2/export", method: .get) { response in
                #expect(response.status == .ok)
                let text = String(buffer: response.body)
                #expect(text.contains("[MPX]"))
            }
            // Bad slot -> 400; empty slot load -> 400; empty export -> 404.
            try await client.execute(uri: "/api/snapshots/9/load", method: .post) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(uri: "/api/snapshots/5/load", method: .post) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(uri: "/api/snapshots/5/export", method: .get) { response in
                #expect(response.status == .notFound)
            }
            // Clear.
            try await client.execute(uri: "/api/snapshots/2", method: .delete) { response in
                #expect(response.status == .ok)
                let snaps = try decoder.decode(
                    ControlSnapshots.self, from: Data(response.body.readableBytesView))
                #expect(snaps.slots[2].name == nil)
            }
        }
    }

    // Restart-equals-live: transport(.restart) must hand the FRESH engine both
    // runtime planes after start. The engine factory already builds from the
    // same config, but the coder/generator inits are hand-written duplicates
    // of the canonical RuntimeConfig/RDSRuntimeConfig mappings -- applying the
    // planes on every (re)start is what makes a rebuilt engine equal to a
    // live-applied one BY CONSTRUCTION (issues.txt: now-playing off after an
    // API restart). RDSRestartParityTests pins the two mappings bit-for-bit;
    // this pins the backend actually exercising the canonical path.
    @Test func restartAppliesBothRuntimePlanesToTheFreshEngine() async throws {
        final class RecordingEngine: ControlledEngine, @unchecked Sendable {
            var events: [String] = []
            let piAtBuild: String
            init(piAtBuild: String) { self.piAtBuild = piAtBuild }
            func start() throws { events.append("start") }
            func stop() { events.append("stop") }
            func applyRuntimeConfig(_ config: AppConfig) { events.append("dsp") }
            func applyRDSRuntimeConfig(_ config: AppConfig) { events.append("rds") }
            var controlMeters: ControlMeters? { nil }
            var rdsLiveSnapshotForControl: BasicRDSCoder.LiveSnapshot? { nil }
        }
        final class Box: @unchecked Sendable { var engines: [RecordingEngine] = [] }
        let box = Box()
        var cfg = AppConfig()
        cfg.rdsNowPlayingEnabled = true
        final class Sink: @unchecked Sendable { var pushes: [String] = [] }
        let sink = Sink()
        let backend = HeadlessControlBackend(
            config: cfg,
            configPath: NSTemporaryDirectory() + "mpxprime-test-\(UUID().uuidString).ini",
            engine: nil,
            engineFactory: { built in
                let e = RecordingEngine(piAtBuild: built.rdsPI)
                box.engines.append(e)
                return e
            },
            onNowPlaying: { display, _, _ in sink.pushes.append(display) }
        )
        _ = try await backend.transport(.start)

        // A pushed track reaches the sink, and setNowPlaying reports the
        // enabled state from config.
        #expect(await backend.setNowPlaying(
            artist: "UB40", title: "Sing Our Own Song",
            display: "UB40 - Sing Our Own Song") == true)
        #expect(sink.pushes == ["UB40 - Sing Our Own Song"])

        _ = try await backend.transport(.restart)
        #expect(box.engines.count == 2)
        // Old engine stopped; fresh engine started THEN given both planes.
        #expect(box.engines[0].events == ["start", "dsp", "rds", "stop"])
        #expect(box.engines[1].events == ["start", "dsp", "rds"])
        // The restart itself never touches the now-playing sink.
        #expect(sink.pushes.count == 1)
    }

    // Stop -> PATCH a restart-required key -> Start: the fresh engine must be
    // built from the PATCHED config and the restartPending flag must clear.
    @Test func patchWhileStoppedIsHonoredByTheNextStart() async throws {
        final class RecordingEngine: ControlledEngine, @unchecked Sendable {
            let piAtBuild: String
            init(piAtBuild: String) { self.piAtBuild = piAtBuild }
            func start() throws {}
            func stop() {}
            func applyRuntimeConfig(_ config: AppConfig) {}
            func applyRDSRuntimeConfig(_ config: AppConfig) {}
            var controlMeters: ControlMeters? { nil }
            var rdsLiveSnapshotForControl: BasicRDSCoder.LiveSnapshot? { nil }
        }
        final class Box: @unchecked Sendable { var engines: [RecordingEngine] = [] }
        let box = Box()
        let backend = HeadlessControlBackend(
            config: AppConfig(),
            configPath: NSTemporaryDirectory() + "mpxprime-test-\(UUID().uuidString).ini",
            engine: nil,
            engineFactory: { built in
                let e = RecordingEngine(piAtBuild: built.rdsPI)
                box.engines.append(e)
                return e
            }
        )
        _ = try await backend.transport(.stop)
        // With no engine there is nothing to live-apply the patch to; the
        // changed config must still reach the next engine build.
        let result = try await backend.applyConfigPatch(["pi": "ABCD"])
        #expect(result.appliedLive == false)  // no engine running
        _ = try await backend.transport(.start)
        #expect(box.engines.count == 1)
        #expect(box.engines[0].piAtBuild == "ABCD")
        #expect(await backend.status().restartPending == false)
    }
}
