import XCTest
@testable import MOICore

final class ServerTests: XCTestCase {
    @MainActor func testRealListenerAuthValidationAndShutdown() async throws {
        let engine = InferenceEngine()
        let server = HTTPServer(engine: engine)
        let key = "unit-test-" + UUID().uuidString
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
        let chat: [String: Any] = ["model": "moi-test", "messages": [["role": "user", "content": "test"]]]
        let noEngine = try await request("/v1/chat/completions", keyValue: key, body: chat)
        XCTAssertEqual(noEngine.1, 503)
        XCTAssertFalse(server.busy, "A failed generation must release the single-request gate")
        let browserNoEngine = try await request("/v1/chat/completions", keyValue: key, body: chat, origin: localOrigin)
        XCTAssertEqual(browserNoEngine.1, 503, "The own-origin browser must reach the engine gate")
        server.canGenerate = { false }
        let thermal = try await request("/v1/chat/completions", keyValue: key, body: chat)
        XCTAssertEqual(thermal.1, 503)
        XCTAssertTrue(String(decoding: thermal.0, as: UTF8.self).contains("cooling"))
        _ = try await request("/private-test-value", keyValue: key)
        XCTAssertFalse(server.events.contains { $0.route.contains("private-test-value") })
        server.stop()
        XCTAssertFalse(server.running)
        XCTAssertEqual(server.connectionCount, 0)
    }
}
