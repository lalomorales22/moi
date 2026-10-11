import XCTest
@testable import MOICore

final class APITests: XCTestCase {
    private func wire(_ extra: String = "", body: String = "{}") -> Data {
        Data("POST /v1/chat/completions HTTP/1.1\r\nHost: phone\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
    }
    func testFragmentedMultibyteRequest() throws {
        let data = wire(body: "{\"text\":\"hello 🌱\"}")
        for length in 0..<data.count { XCTAssertNil(try HTTPRequest.parse(Data(data.prefix(length)))) }
        let parsed = try XCTUnwrap(HTTPRequest.parse(data))
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(String(data: parsed.body, encoding: .utf8), "{\"text\":\"hello 🌱\"}")
    }
    func testRejectsAmbiguousFramingAndPipelines() {
        for header in ["Content-Length: 2\r\n", "Transfer-Encoding: chunked\r\n", " Content-Length: 2\r\n", "Expect: 100-continue\r\n"] {
            XCTAssertThrowsError(try HTTPRequest.parse(wire(header)))
        }
        XCTAssertThrowsError(try HTTPRequest.parse(wire() + Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n".utf8)))
    }
    func testLimitsBeforeBodyArrives() {
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 999999999\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPRequest.parse(Data(repeating: 65, count: 8193)))
    }
    func testBearerAuthentication() {
        XCTAssertTrue(APIJSON.authorized("Bearer a-private-key", key: "a-private-key"))
        XCTAssertFalse(APIJSON.authorized("Bearer a-private-kex", key: "a-private-key"))
        XCTAssertFalse(APIJSON.authorized(nil, key: "a-private-key"))
        XCTAssertFalse(APIJSON.authorized("Bearer ", key: ""))
    }
    func testValidChatAndHistory() throws {
        let request = try ChatRequest.parse(APIJSON.encode(["model": "moi", "messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": "hello"], ["role": "assistant", "content": "Hi!"], ["role": "user", "content": "what next?"]], "stream": true, "max_tokens": 64]))
        XCTAssertEqual(request.messages.count, 4)
        XCTAssertEqual(request.outputLimit, 64)
    }
    func testInvalidInputCannotReachEngine() {
        let valid: [String: Any] = ["model": "moi", "messages": [["role": "user", "content": "hello"]]]
        for patch: [String: Any] in [["max_tokens": 0], ["max_tokens": 257], ["temperature": 3], ["tools": []], ["messages": []], ["messages": [["role": "assistant", "content": "hello"]]], ["messages": [["role": "user", "content": String(repeating: "a", count: 2049)]]], ["messages": [["role": "user", "content": [["type": "image_url"]]]]]] {
            XCTAssertThrowsError(try ChatRequest.parse(APIJSON.encode(valid.merging(patch) { _, new in new })))
        }
    }
    func testTruncatedModelRejectedBeforeRuntime() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a model".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        XCTAssertThrowsError(try ModelSpec.catalog[0].verify(file: temp))
    }
}
