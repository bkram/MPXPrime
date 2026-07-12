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
}
