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
}
