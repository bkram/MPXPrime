import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

// The remote-control HTTP server: REST API under /api/* plus the embedded
// single-page dashboard at /. Runs identically in headless mode (macOS +
// Linux, owned by main.swift) and GUI mode (owned by the view model); all
// engine/config work goes through a ControlBackend.
//
// Security model: binding to loopback (the default) needs no key. Binding
// to any other interface REFUSES to start unless control_api_key is set;
// with a key configured, every /api request must carry it (Authorization:
// Bearer <key> or X-API-Key: <key>). TLS is a reverse-proxy concern --
// documented in the manual, not implemented here.

struct ControlServerSettings: Sendable {
    var host: String
    var port: Int
    var apiKey: String

    init(config: AppConfig) {
        host = config.controlBind
        port = config.controlPort
        apiKey = config.controlAPIKey
    }

    var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }
}

enum ControlServerError: Error, CustomStringConvertible {
    case remoteBindWithoutKey(String)

    var description: String {
        switch self {
        case .remoteBindWithoutKey(let host):
            return "control server: refusing to bind '\(host)' without an API key. "
                + "Set control_api_key in [CONTROL], or bind 127.0.0.1."
        }
    }
}

// Codable DTOs become JSON responses via the request context's encoder.
extension ControlStatus: ResponseEncodable {}
extension ControlMeters: ResponseEncodable {}
extension ControlRDS: ResponseEncodable {}
extension ConfigApplyResult: ResponseEncodable {}
extension ConfigKeyOutcome: ResponseEncodable {}

/// Curated RDS update payload (PUT /api/rds). All fields optional; only the
/// supplied ones change. `ps` writes bank A (the primary PS text).
struct RDSUpdateRequest: Codable, Sendable {
    var enabled: Bool?
    var pi: String?
    var pty: Int?
    var ta: Bool?
    var tp: Bool?
    var ps: String?
    var rt: String?

    var asConfigPatch: [String: String] {
        var patch: [String: String] = [:]
        if let enabled { patch["en_rds"] = enabled ? "True" : "False" }
        if let pi { patch["pi"] = pi }
        if let pty { patch["pty"] = String(pty) }
        if let ta { patch["ta"] = ta ? "True" : "False" }
        if let tp { patch["tp"] = tp ? "True" : "False" }
        if let ps { patch["ps_a"] = ps }
        if let rt { patch["rt_text"] = rt }
        return patch
    }
}

struct PresetApplyRequest: Codable, Sendable {
    var kind: String
    var id: String
    var intensity: Double?
}

/// Constant-time equality so the key check does not leak length/prefix
/// timing. Compares fixed-position bytes over the longer length.
private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let ab = Array(a.utf8)
    let bb = Array(b.utf8)
    var diff = ab.count ^ bb.count
    let n = max(ab.count, bb.count)
    for i in 0..<n {
        let x = i < ab.count ? ab[i] : 0
        let y = i < bb.count ? bb[i] : 0
        diff |= Int(x ^ y)
    }
    return diff == 0
}

/// Rejects /api requests without the configured key. The dashboard page
/// itself stays reachable (it prompts for the key and stores it locally).
struct APIKeyMiddleware<Context: RequestContext>: RouterMiddleware {
    let apiKey: String

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard request.uri.path.hasPrefix("/api") else {
            return try await next(request, context)
        }
        var presented: String?
        if let auth = request.headers[.authorization],
            auth.lowercased().hasPrefix("bearer ") {
            presented = String(auth.dropFirst("bearer ".count))
                .trimmingCharacters(in: .whitespaces)
        } else if let name = HTTPField.Name("X-API-Key") {
            presented = request.headers[name]
        }
        guard let presented, constantTimeEquals(presented, apiKey) else {
            throw HTTPError(.unauthorized, message: "missing or invalid API key")
        }
        return try await next(request, context)
    }
}

enum ControlServer {
    /// Build the router; separated from run() so tests can drive it via
    /// hummingbird-testing without opening sockets.
    static func buildRouter(
        backend: some ControlBackend, apiKey: String?
    ) -> Router<BasicRequestContext> {
        let router = Router()
        if let apiKey, !apiKey.isEmpty {
            router.add(middleware: APIKeyMiddleware(apiKey: apiKey))
        }

        router.get("/api/status") { _, _ in
            await backend.status()
        }

        router.get("/api/meters") { _, _ -> ControlMeters in
            guard let meters = await backend.meters() else {
                throw HTTPError(.serviceUnavailable, message: "engine not running")
            }
            return meters
        }

        router.get("/api/rds") { _, _ in
            await backend.rds()
        }

        router.put("/api/rds") { request, context -> ConfigApplyResult in
            let update = try await request.decode(as: RDSUpdateRequest.self, context: context)
            let patch = update.asConfigPatch
            guard !patch.isEmpty else {
                throw HTTPError(.badRequest, message: "no RDS fields supplied")
            }
            return try await backend.applyConfigPatch(patch)
        }

        router.get("/api/config") { _, _ -> Response in
            let sections = try await backend.configSections()
            let data = try JSONEncoder().encode(sections)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.patch("/api/config") { request, context -> ConfigApplyResult in
            let patch = try await request.decode(
                as: [String: String].self, context: context)
            guard !patch.isEmpty else {
                throw HTTPError(.badRequest, message: "empty patch")
            }
            return try await backend.applyConfigPatch(patch)
        }

        router.get("/api/presets") { _, _ -> Response in
            let presets = await backend.presets()
            let data = try JSONEncoder().encode(presets)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.post("/api/presets") { request, context -> ConfigApplyResult in
            let body = try await request.decode(as: PresetApplyRequest.self, context: context)
            do {
                return try await backend.applyPreset(
                    kind: body.kind, id: body.id, intensity: body.intensity)
            } catch let error as ControlError {
                throw HTTPError(.badRequest, message: String(describing: error))
            }
        }

        router.post("/api/transport/:action") { _, context -> ControlStatus in
            guard let raw = context.parameters.get("action"),
                let action = TransportAction(rawValue: raw)
            else {
                throw HTTPError(.badRequest, message: "action must be start|stop|restart")
            }
            do {
                return try await backend.transport(action)
            } catch let error as ControlError {
                throw HTTPError(.internalServerError, message: String(describing: error))
            }
        }

        let dashboard = Self.dashboardHTML()
        router.get("/") { _, _ -> Response in
            Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: dashboard))
            )
        }
        return router
    }

    /// Validate settings and run the server until the task is cancelled.
    static func run(
        backend: some ControlBackend, settings: ControlServerSettings
    ) async throws {
        if !settings.isLoopback && settings.apiKey.isEmpty {
            throw ControlServerError.remoteBindWithoutKey(settings.host)
        }
        let router = buildRouter(
            backend: backend,
            apiKey: settings.apiKey.isEmpty ? nil : settings.apiKey
        )
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(settings.host, port: settings.port),
                serverName: "MPXPrimeControl"
            )
        )
        try await app.runService()
    }

    /// The embedded dashboard (SPM resource; falls back to a stub if the
    /// bundle is missing so the API never goes down with the UI).
    static func dashboardHTML() -> String {
        if let url = Bundle.module.url(
            forResource: "WebUI/index", withExtension: "html"),
            let html = try? String(contentsOf: url, encoding: .utf8) {
            return html
        }
        return "<!doctype html><title>MPX Prime</title><p>Dashboard resource missing; the REST API is available under /api/."
    }
}
