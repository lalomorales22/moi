import XCTest
@testable import MOICore

final class ServerTests: XCTestCase {
    @MainActor func testRealListenerAuthValidationAndShutdown() async throws {
        let engine = InferenceEngine()
        let server = HTTPServer(engine: engine)
        let key = "unit-test-" + UUID().uuidString
        let port = UInt16.random(in: 24000...40000)
        try server.start(port: port, key: key, modelID: "moi-test", name: "MOI unit test")
        defer { server.stop() }
        for _ in 0..<100 where !server.running { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(server.running)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func request(_ route: String, keyValue: String?, body: [String: Any]? = nil, origin: Bool = false) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(route)")!)
            if let keyValue { request.setValue("Bearer \(keyValue)", forHTTPHeaderField: "Authorization") }
            if origin { request.setValue("https://example.invalid", forHTTPHeaderField: "Origin") }
            if let body {
                request.httpMethod = "POST"; request.httpBody = APIJSON.encode(body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode)
        }
        let missing = try await request("/health", keyValue: nil)
        XCTAssertEqual(missing.1, 401)
        let health = try await request("/health", keyValue: key)
        XCTAssertEqual(health.1, 200)
        let browser = try await request("/health", keyValue: key, origin: true)
        XCTAssertEqual(browser.1, 403)
        let chat: [String: Any] = ["model": "moi-test", "messages": [["role": "user", "content": "test"]]]
        let noEngine = try await request("/v1/chat/completions", keyValue: key, body: chat)
        XCTAssertEqual(noEngine.1, 503)
        XCTAssertFalse(server.busy, "A failed generation must release the single-request gate")
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
