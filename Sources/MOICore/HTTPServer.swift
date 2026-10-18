import Foundation
import Network

public struct RequestEvent: Identifiable, Sendable {
    public let id = UUID()
    public let time = Date()
    public let peer: String
    public let route: String
    public let status: Int
}

@MainActor public final class HTTPServer {
    public var onChange: (() -> Void)?
    public var canGenerate: () -> Bool = { true }
    public var browserOrigins: () -> Set<String> = { [] }
    public private(set) var running = false
    public private(set) var busy = false
    public private(set) var completed = 0
    public private(set) var failed = 0
    public private(set) var events: [RequestEvent] = []
    public private(set) var lastGeneration: Generation?
    public private(set) var status = "Offline"
    public private(set) var lastError: String?
    public private(set) var modelID = ""
    public var peers: [String] { clients.values.map(\.peer).sorted() }
    public var connectionCount: Int { clients.count }
    nonisolated public static let maxConnections = 8
    private var listener: NWListener?
    private var clients: [UUID: HTTPClient] = [:]
    private var startedAt: Date?
    private var key = ""
    private let pairing = BrowserPairing()
    public var pairingInvitation: BrowserInvitation? { running ? pairing.invitation : nil }
    public var pairedBrowserCount: Int { pairing.sessionCount }

    public func refreshPairing() {
        guard running else { return }
        do { if try pairing.refresh() { onChange?() } }
        catch { lastError = error.localizedDescription; onChange?() }
    }
    public func revokePairedBrowsers() {
        pairing.reset()
        refreshPairing()
        onChange?()
    }
    private func isOwnBrowserOrigin(_ request: HTTPRequest) -> Bool {
        guard let origin = request.headers["origin"] else { return false }
        return browserOrigins().contains(origin) && origin == "http://\(request.headers["host"] ?? "")"
    }
    private let engine: InferenceEngine

    public init(engine: InferenceEngine) { self.engine = engine }

    /// How many times an "address in use" bind is retried, and how long to wait before each try.
    nonisolated public static let maxRestartAttempts = 5
    nonisolated public static func restartDelaySeconds(attempt: Int) -> UInt64 { UInt64(min(8, 1 << max(0, attempt - 1))) }   // 1, 2, 4, 8, 8
    nonisolated static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }

    private struct StartRequest { let port: UInt16; let key: String; let modelID: String; let name: String }
    /// Listeners that were cancelled but haven't reported `.cancelled` yet (they may still hold the port).
    private var retiring: [ObjectIdentifier: NWListener] = [:]
    /// A start requested while an old listener was still shutting down; launched once it's gone.
    private var pendingStart: StartRequest?
    private var lastStart: StartRequest?
    private var restartAttempts = 0
    private var restartTask: Task<Void, Never>?
    /// True from `start()` until the listener is ready (including deferred starts and bind retries).
    public var isStarting: Bool { !running && (pendingStart != nil || restartTask != nil || listener != nil) }

    public func start(port: UInt16, key: String, modelID: String, name: String = "MOI") throws {
        guard listener == nil, pendingStart == nil, restartTask == nil else { return }
        guard !busy else { throw MOIError(409, "Waiting for inference to stop.") }
        guard key.utf8.count >= 24, port >= 1024, NWEndpoint.Port(rawValue: port) != nil else { throw MOIError(400, "Use a key with at least 24 characters and a port from 1024 to 65535.") }
        restartAttempts = 0
        lastError = nil
        let request = StartRequest(port: port, key: key, modelID: modelID, name: name)
        if !retiring.isEmpty {
            // The previous listener is still releasing the port: start as soon as it reports cancelled.
            pendingStart = request
            status = "Starting"
            onChange?()
            return
        }
        try launch(request)
    }

    private func launch(_ request: StartRequest) throws {
        guard let endpoint = NWEndpoint.Port(rawValue: request.port) else { throw MOIError(400, "Use a port from 1024 to 65535.") }
        pairing.reset()
        try pairing.refresh()
        self.key = request.key; self.modelID = request.modelID
        lastStart = request
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        // SO_REUSEADDR: MOI closes every connection first (Connection: close), so the port keeps
        // TIME_WAIT entries for ~30 s after clients disconnect. Without reuse, restarting the
        // server in that window fails with EADDRINUSE ("Address already in use").
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: endpoint)
        listener.service = NWListener.Service(name: request.name, type: "_moi._tcp")
        self.listener = listener
        status = "Starting"
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.running = true; self.restartAttempts = 0; self.startedAt = Date(); self.status = "Serving"
                case .failed(let error): self.listenerError(error, listener: listener, failed: true)
                case .waiting(let error): self.listenerError(error, listener: listener, failed: false)
                case .cancelled:
                    // Cancelled underneath us (not via stop()/retire): don't keep showing LIVE.
                    self.listener = nil; self.running = false
                    self.status = "Offline"; self.lastError = "The listener was closed by the system. Press Start serving."
                default: break
                }
                self.onChange?()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.listener != nil, self.clients.count < Self.maxConnections else { connection.cancel(); return }
                let client = HTTPClient(connection: connection)
                self.clients[client.id] = client
                client.onClose = { [weak self, weak client] in
                    guard let self, let client else { return }
                    self.clients.removeValue(forKey: client.id); self.onChange?()
                }
                client.onRequest = { [weak self, weak client] request in
                    guard let self, let client else { return }
                    await self.route(request, client: client)
                }
                client.start(); self.onChange?()
            }
        }
        listener.start(queue: .main)
        onChange?()
    }

    private func listenerError(_ error: NWError, listener: NWListener, failed: Bool) {
        if Self.isAddressInUse(error), restartAttempts < Self.maxRestartAttempts, let request = lastStart {
            restartAttempts += 1
            let delay = Self.restartDelaySeconds(attempt: restartAttempts)
            retire(listener)
            self.listener = nil; running = false
            status = "Port \(request.port) is still in use. Retrying in \(delay) s (\(restartAttempts)/\(Self.maxRestartAttempts))…"
            restartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.restartTask = nil
                self.relaunch(request)
            }
        } else if failed {
            stop()
            status = error.localizedDescription
            lastError = Self.isAddressInUse(error)
                ? "Port \((lastStart?.port).map(String.init) ?? "") is in use by something else. Wait a minute or choose another port."
                : error.localizedDescription
        } else {
            running = false; status = error.localizedDescription
        }
    }

    /// Launches now, or once retiring listeners have released the port.
    private func relaunch(_ request: StartRequest) {
        guard listener == nil else { return }
        if !retiring.isEmpty { pendingStart = request; onChange?(); return }
        do { try launch(request) }
        catch { status = error.localizedDescription; lastError = error.localizedDescription; onChange?() }
    }

    /// Cancels a listener and keeps it until it reports `.cancelled`, so a restart never races it.
    private func retire(_ old: NWListener) {
        let id = ObjectIdentifier(old)
        retiring[id] = old
        old.newConnectionHandler = { connection in connection.cancel() }
        old.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: Task { @MainActor in self?.retired(id) }
            default: break
            }
        }
        old.cancel()
        // Safety net: never wait more than 2 s for the cancellation callback.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.retired(id)
        }
    }

    private func retired(_ id: ObjectIdentifier) {
        guard let old = retiring.removeValue(forKey: id) else { return }
        old.stateUpdateHandler = nil
        old.newConnectionHandler = nil
        if retiring.isEmpty, let request = pendingStart {
            pendingStart = nil
            relaunch(request)
        }
        onChange?()
    }

    public func stop() {
        restartTask?.cancel(); restartTask = nil
        pendingStart = nil
        restartAttempts = 0
        if let old = listener { retire(old) }
        listener = nil; running = false; status = "Offline"
        pairing.reset()
        let current = Array(clients.values)
        for client in current { client.close() }
        onChange?()
    }

    public var stats: [String: Any] {
        var values: [String: Any] = ["serving": running, "busy": busy, "model": modelID, "active_connections": connectionCount, "max_connections": Self.maxConnections,
                                  "completed_requests": completed, "failed_requests": failed, "paired_browsers": pairedBrowserCount,
                                  "uptime_seconds": running ? Int(Date().timeIntervalSince(startedAt ?? Date())) : 0]
        if let lastGeneration {
            values["last_duration_seconds"] = lastGeneration.elapsed
            if let speed = lastGeneration.tokensPerSecond, speed.isFinite { values["last_tokens_per_second"] = speed }
            values["last_output_tokens"] = lastGeneration.outputTokens
            values["last_first_token_seconds"] = lastGeneration.firstTokenSeconds
        }
        return values
    }

    private func record(_ request: HTTPRequest, client: HTTPClient, status: Int) {
        // Never retain Authorization, prompts, or responses in the activity feed.
        let knownPaths = ["/", "/v1", "/v1/", "/index.html", "/moi-web.js", "/moi-web.css", "/moi-icon.svg", "/health", "/moi/stats", "/moi/pair", "/moi/unpair", "/v1/models", "/v1/chat/completions"]
        let route = knownPaths.contains(request.path) ? request.path : "[unknown route]"
        events.insert(RequestEvent(peer: client.peer, route: request.method.prefix(8) + " " + route, status: status), at: 0)
        events = Array(events.prefix(30)); onChange?()
    }

    private func route(_ request: HTTPRequest, client: HTTPClient) async {
        var responseStatus = 200
        defer { record(request, client: client, status: responseStatus) }
        do {
            if request.method == "GET", let asset = BrowserPage.asset(for: request.path) {
                try await client.respond(200, body: asset.body, contentType: asset.contentType)
                return
            }
            if request.method == "POST", request.path == "/moi/pair" {
                guard isOwnBrowserOrigin(request) else { throw MOIError(403, "Open the pairing link in MOI's own browser page.") }
                guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else { throw MOIError(415, "Use Content-Type: application/json.") }
                let token = try pairing.exchange(request.headers["authorization"])
                try await client.respond(200, body: APIJSON.encode(["token": token, "token_type": "Bearer", "expires_in": Int(BrowserPairing.sessionLifetime), "model": modelID]))
                return
            }
            let authorization = request.headers["authorization"]
            guard APIJSON.authorized(authorization, key: key) || pairing.authorized(authorization) else { throw MOIError(401, "A valid bearer key is required.") }
            if request.headers["origin"] != nil, !isOwnBrowserOrigin(request) {
                throw MOIError(403, "Use MOI's own browser page or a server-side API client.")
            }
            switch (request.method, request.path) {
            case ("POST", "/moi/unpair"):
                pairing.revoke(authorization)
                try await client.respond(200, body: APIJSON.encode(["disconnected": true]))
            case ("GET", "/health"):
                try await client.respond(200, body: APIJSON.encode(["status": "ok", "model": modelID, "busy": busy]))
            case ("GET", "/moi/stats"):
                try await client.respond(200, body: APIJSON.encode(stats))
            case ("GET", "/v1/models"):
                try await client.respond(200, body: APIJSON.encode(["object": "list", "data": [["id": modelID, "object": "model", "created": 0, "owned_by": "moi"]]]))
            case ("POST", "/v1/chat/completions"):
                guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else { throw MOIError(415, "Use Content-Type: application/json.") }
                let chat = try ChatRequest.parse(request.body)
                guard chat.model == modelID || chat.model == "moi" else { throw MOIError(404, "This model is not loaded.") }
                guard !busy else { throw MOIError(429, "MOI handles one inference at a time. Retry shortly.") }
                guard canGenerate() else { throw MOIError(503, "The phone is cooling down. Retry later.") }
                busy = true; onChange?()
                defer { busy = false; onChange?() }
                let id = "chatcmpl-" + UUID().uuidString
                let created = Int(Date().timeIntervalSince1970)
                let streaming = chat.stream ?? false
                if streaming { try await client.beginStream() }
                let generation = try await engine.generate(chat) { chunk in
                    if streaming {
                        let data = APIJSON.encode(["id": id, "object": "chat.completion.chunk", "created": created, "model": chat.model,
                                                   "choices": [["index": 0, "delta": ["role": "assistant", "content": chunk], "finish_reason": NSNull()]]])
                        try await client.sendEvent(data)
                    }
                }
                lastGeneration = generation; completed += 1
                if streaming {
                    try await client.sendEvent(APIJSON.encode(["id": id, "object": "chat.completion.chunk", "created": created, "model": chat.model,
                                                              "choices": [["index": 0, "delta": [:], "finish_reason": generation.finishReason]]]))
                    try await client.sendEvent(Data("[DONE]".utf8))
                    client.close()
                } else {
                    var response: [String: Any] = ["id": id, "object": "chat.completion", "created": created, "model": modelID,
                                                  "choices": [["index": 0, "message": ["role": "assistant", "content": generation.text], "finish_reason": generation.finishReason]]]
                    if let input = generation.promptTokens, let output = generation.outputTokens {
                        response["usage"] = ["prompt_tokens": input, "completion_tokens": output, "total_tokens": input + output]
                    }
                    try await client.respond(200, body: APIJSON.encode(response))
                }
            default: throw MOIError(404, "Unknown route or method.")
            }
        } catch {
            failed += 1
            lastError = error.localizedDescription
            let (code, data) = APIJSON.error(error)
            responseStatus = code
            if client.streaming { try? await client.sendEvent(data); client.close() }
            else { try? await client.respond(code, body: data) }
        }
    }
}

@MainActor private final class HTTPClient {
    let id = UUID()
    let peer: String
    var onClose: (() -> Void)?
    var onRequest: ((HTTPRequest) async -> Void)?
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false
    private var timeout: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private(set) var streaming = false

    init(connection: NWConnection) { self.connection = connection; peer = String(describing: connection.endpoint) }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .failed, .cancelled: self.close()
                default: break
                }
            }
        }
        connection.start(queue: .main); deadline(seconds: 15); receive()
    }
    func close() {
        guard !closed else { return }
        closed = true; timeout?.cancel(); operation?.cancel(); connection.cancel(); onClose?()
        onClose = nil; onRequest = nil
    }
    private func deadline(seconds: UInt64) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            self?.close()
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                do {
                    if let request = try HTTPRequest.parse(self.buffer) {
                        self.buffer.removeAll(); self.deadline(seconds: 180)
                        self.operation = Task { [weak self] in
                            guard let self else { return }
                            await self.onRequest?(request)
                        }
                        // Monitor disconnects while inference is running. A peer's write-side
                        // EOF alone is allowed; extra requests on this socket are not.
                        if !done { self.monitor() }
                    } else if done || error != nil { self.close() }
                    else { self.receive() }
                } catch {
                    let (code, body) = APIJSON.error(error)
                    try? await self.respond(code, body: body)
                }
            }
        }
    }
    private func monitor() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, error in
            Task { @MainActor in
                if error != nil || !(data?.isEmpty ?? true) { self?.close() }
            }
        }
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
    func respond(_ code: Int, body: Data, contentType: String = "application/json") async throws {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 413: "Content Too Large", 415: "Unsupported Media Type", 417: "Expectation Failed", 429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        var header = "HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        if contentType.hasPrefix("text/html") {
            header += "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"
        }
        if code == 429 || code == 503 { header += "Retry-After: 5\r\n" }
        if code == 401 { header += "WWW-Authenticate: Bearer\r\n" }
        // Always free the slot, even when the peer is already gone and the send fails;
        // otherwise a dead socket held one of the 8 client slots until its 180 s deadline.
        defer { close() }
        try await send(Data((header + "\r\n").utf8) + body)
    }
    func beginStream() async throws {
        try await send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8))
        streaming = true
    }
    func sendEvent(_ data: Data) async throws { try await send(Data("data: ".utf8) + data + Data("\n\n".utf8)) }
}
