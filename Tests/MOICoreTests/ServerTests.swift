import XCTest
@testable import MOICore

final class ServerTests: XCTestCase {
    @MainActor func testRealListenerAuthValidationAndShutdown() async throws {
        let engine = InferenceEngine()
        let server = HTTPServer(engine: engine)
        let key = "moi_" + String(repeating: "a1b2c3d4", count: 8)
        let port = UInt16.random(in: 24000...40000)
        let localOrigin = "http://127.0.0.1:\(port)"
        server.browserOrigins = { [localOrigin] }
        try server.start(port: port, key: key, modelID: "moi-test", name: "MOI unit test")
        defer { server.stop() }
        for _ in 0..<100 where !server.running { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(server.running)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func request(_ route: String, keyValue: String?, body: [String: Any]? = nil, origin: String? = nil, host: String? = nil) async throws -> (Data, Int, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(route)")!)
            if let keyValue { request.setValue("Bearer \(keyValue)", forHTTPHeaderField: "Authorization") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            if let host { request.setValue(host, forHTTPHeaderField: "Host") }
            if let body {
                request.httpMethod = "POST"; request.httpBody = APIJSON.encode(body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode, response as! HTTPURLResponse)
        }
        for path in ["/", "/v1", "/v1/"] {
            let page = try await request(path, keyValue: nil)
            XCTAssertEqual(page.1, 200)
            XCTAssertEqual(page.2.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
            XCTAssertTrue(String(decoding: page.0, as: UTF8.self).contains("Connect to MOI"))
            XCTAssertFalse(String(decoding: page.0, as: UTF8.self).contains(key))
            XCTAssertTrue(page.2.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true)
        }
        for path in ["/moi-web.js", "/moi-web.css"] {
            let asset = try await request(path, keyValue: nil)
            XCTAssertEqual(asset.1, 200)
            XCTAssertFalse(String(decoding: asset.0, as: UTF8.self).contains(key))
        }
        let missing = try await request("/health", keyValue: nil)
        XCTAssertEqual(missing.1, 401)
        let health = try await request("/health", keyValue: key)
        XCTAssertEqual(health.1, 200)
        let browser = try await request("/health", keyValue: key, origin: "https://example.invalid")
        XCTAssertEqual(browser.1, 403)
        let sameOrigin = try await request("/health", keyValue: key, origin: localOrigin)
        XCTAssertEqual(sameOrigin.1, 200)
        let sameOriginNoKey = try await request("/health", keyValue: nil, origin: localOrigin)
        XCTAssertEqual(sameOriginNoKey.1, 401)
        let wrongHost = try await request("/health", keyValue: key, origin: localOrigin, host: "other.invalid:\(port)")
        XCTAssertEqual(wrongHost.1, 403)
        let wrongPort = try await request("/health", keyValue: key, origin: "http://127.0.0.1:1")
        XCTAssertEqual(wrongPort.1, 403)
        let invitation = try XCTUnwrap(server.pairingInvitation)
        let leakedPair = try await request("/moi/pair", keyValue: invitation.code, body: [:], origin: "https://example.invalid")
        XCTAssertEqual(leakedPair.1, 403)
        let noOriginPair = try await request("/moi/pair", keyValue: invitation.code, body: [:])
        XCTAssertEqual(noOriginPair.1, 403)
        let wrongPair = try await request("/moi/pair", keyValue: "wrong", body: [:], origin: localOrigin)
        XCTAssertEqual(wrongPair.1, 401)
        let pairing = try await request("/moi/pair", keyValue: invitation.code, body: [:], origin: localOrigin)
        XCTAssertEqual(pairing.1, 200)
        XCTAssertEqual(pairing.2.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(String(decoding: pairing.0, as: UTF8.self).contains(key), "The long-lived key must never be issued to a pairing client")
        let sessionToken = try XCTUnwrap((JSONSerialization.jsonObject(with: pairing.0) as? [String: Any])?["token"] as? String)
        let pairedHealth = try await request("/health", keyValue: sessionToken)
        XCTAssertEqual(pairedHealth.1, 200, "Same-origin GETs can omit Origin")
        let replay = try await request("/moi/pair", keyValue: invitation.code, body: [:], origin: localOrigin)
        XCTAssertEqual(replay.1, 401)
        let badOriginSession = try await request("/health", keyValue: sessionToken, origin: "https://example.invalid")
        XCTAssertEqual(badOriginSession.1, 403)
        let inviteAsKey = try await request("/health", keyValue: invitation.code)
        XCTAssertEqual(inviteAsKey.1, 401)
        let chat: [String: Any] = ["model": "moi-test", "messages": [["role": "user", "content": "test"]]]
        let noEngine = try await request("/v1/chat/completions", keyValue: key, body: chat)
        XCTAssertEqual(noEngine.1, 503)
        XCTAssertFalse(server.busy, "A failed generation must release the single-request gate")
        let browserNoEngine = try await request("/v1/chat/completions", keyValue: key, body: chat, origin: localOrigin)
        XCTAssertEqual(browserNoEngine.1, 503, "The own-origin browser must reach the engine gate")
        let pairedChat = try await request("/v1/chat/completions", keyValue: sessionToken, body: chat, origin: localOrigin)
        XCTAssertEqual(pairedChat.1, 503, "Paired browser reaches the engine gate")
        let unpair = try await request("/moi/unpair", keyValue: sessionToken, body: [:], origin: localOrigin)
        XCTAssertEqual(unpair.1, 200)
        let revokedHealth = try await request("/health", keyValue: sessionToken)
        XCTAssertEqual(revokedHealth.1, 401)
        XCTAssertEqual(server.pairedBrowserCount, 0)
        let beforeReset = try XCTUnwrap(server.pairingInvitation)
        server.revokePairedBrowsers()
        let resetPair = try await request("/moi/pair", keyValue: beforeReset.code, body: [:], origin: localOrigin)
        XCTAssertEqual(resetPair.1, 401)
        server.canGenerate = { false }
        let thermal = try await request("/v1/chat/completions", keyValue: key, body: chat)
        XCTAssertEqual(thermal.1, 503)
        XCTAssertTrue(String(decoding: thermal.0, as: UTF8.self).contains("cooling"))
        _ = try await request("/private-test-value", keyValue: key)
        XCTAssertFalse(server.events.contains { $0.route.contains("private-test-value") })
        XCTAssertFalse(server.events.contains { $0.route.contains(sessionToken) || $0.route.contains(invitation.code) })
        server.stop()
        XCTAssertNil(server.pairingInvitation)
        XCTAssertEqual(server.pairedBrowserCount, 0)
        XCTAssertFalse(server.running)
        XCTAssertEqual(server.connectionCount, 0)
    }

    @MainActor func testRestartOnSamePortAfterClientConnection() async throws {
        let server = HTTPServer(engine: InferenceEngine())
        let key = "moi_" + String(repeating: "0f1e2d3c", count: 8)
        let port = UInt16.random(in: 40001...52000)
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func health() async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            return (response as! HTTPURLResponse).statusCode
        }
        func waitUntilServing(_ label: String) async throws {
            for _ in 0..<500 where !server.running { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(server.running, "\(label): server should be serving, status: \(server.status)")
        }

        try server.start(port: port, key: key, modelID: "moi-test", name: "MOI restart test")
        try await waitUntilServing("first start")
        // MOI closes each connection first, leaving a TIME_WAIT entry on the port.
        let first = try await health()
        XCTAssertEqual(first, 200)

        // Stop and restart immediately: the old listener may still be retiring; the start must be
        // deferred (not dropped) and the bind must succeed despite TIME_WAIT.
        server.stop()
        XCTAssertFalse(server.running)
        try server.start(port: port, key: key, modelID: "moi-test", name: "MOI restart test")
        XCTAssertTrue(server.isStarting || server.running)
        try await waitUntilServing("restart")
        XCTAssertNil(server.lastError)
        let second = try await health()
        XCTAssertEqual(second, 200)

        // Stopping while a start is pending cancels it.
        server.stop()
        try server.start(port: port, key: key, modelID: "moi-test", name: "MOI restart test")
        server.stop()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertFalse(server.running)
        XCTAssertFalse(server.isStarting)
    }

    func testRestartBackoff() {
        XCTAssertEqual((1...6).map { HTTPServer.restartDelaySeconds(attempt: $0) }, [1, 2, 4, 8, 8, 8])
        XCTAssertTrue(HTTPServer.isAddressInUse(.posix(.EADDRINUSE)))
        XCTAssertFalse(HTTPServer.isAddressInUse(.posix(.ECONNREFUSED)))
        XCTAssertGreaterThan(HTTPServer.maxRestartAttempts, 0)
    }
}
