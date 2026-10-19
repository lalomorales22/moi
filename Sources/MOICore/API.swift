import Foundation

public struct ChatMessage: Codable, Sendable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public struct ChatRequest: Decodable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let stream: Bool?
    public let max_tokens: Int?
    public let temperature: Double?
    public let top_p: Double?
    public var outputLimit: Int { max_tokens ?? 128 }

    /// `maxInputBytes` defaults to the 2,048-byte starter cap (the LAN server always uses it);
    /// an in-process client that knows the loaded model passes `ModelSpec.maxInputBytes`.
    public static func parse(_ body: Data, maxInputBytes: Int = 2048) throws -> ChatRequest {
        guard let raw = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw MOIError(400, "Expected a JSON object.")
        }
        let supported: Set<String> = ["model", "messages", "stream", "max_tokens", "temperature", "top_p"]
        let extra = Set(raw.keys).subtracting(supported)
        guard extra.isEmpty else { throw MOIError(400, "Unsupported fields: \(extra.sorted().joined(separator: ", ")). MOI supports text chat only.") }
        let request: ChatRequest
        do { request = try JSONDecoder().decode(ChatRequest.self, from: body) }
        catch { throw MOIError(400, "Expected model, text messages, and correctly typed generation settings.") }
        guard !request.model.isEmpty, !request.messages.isEmpty, request.messages.count <= 32 else {
            throw MOIError(400, "Provide a model and between 1 and 32 messages.")
        }
        guard (1...256).contains(request.outputLimit) else { throw MOIError(400, "max_tokens must be 1–256.") }
        guard (0...2).contains(request.temperature ?? 0.7) else { throw MOIError(400, "temperature must be 0–2.") }
        guard (0.05...1).contains(request.top_p ?? 0.9) else { throw MOIError(400, "top_p must be 0.05–1.") }
        // A conservative byte cap leaves room for output in our 1,024-token context,
        // including byte-heavy scripts. The runtime remains the authority on token fit.
        let cap = min(max(maxInputBytes, 256), 8192)
        guard request.messages.reduce(0, { $0 + $1.content.utf8.count }) <= cap else {
            throw MOIError(413, cap == 2048 ? "Message text exceeds MOI's 2,048-byte starter limit." : "Message text exceeds this model's \(cap)-byte limit.")
        }
        var expected = "user"
        for (index, message) in request.messages.enumerated() {
            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MOIError(400, "Messages cannot be empty.")
            }
            if index == 0 && message.role == "system" { continue }
            guard message.role == expected else { throw MOIError(400, "Use an optional first system message, then alternating user and assistant messages.") }
            expected = expected == "user" ? "assistant" : "user"
        }
        guard request.messages.last?.role == "user" else { throw MOIError(400, "The final message must be from the user.") }
        return request
    }
}

public enum APIJSON {
    public static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
    public static func error(_ error: Error) -> (Int, Data) {
        let error = error as? MOIError ?? MOIError(500, "Inference failed. See the phone for details.")
        return (error.status, encode(["error": ["message": error.message, "type": "moi_error", "code": error.status]]))
    }
    public static func authorized(_ value: String?, key: String) -> Bool {
        let expected = Array("Bearer \(key)".utf8)
        let actual = Array((value ?? "").utf8)
        guard !key.isEmpty, actual.count == expected.count else { return false }
        return zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 8192 { throw MOIError(431, "Request headers are too large.") }
            return nil
        }
        guard boundary.lowerBound <= 8192 else { throw MOIError(431, "Request headers are too large.") }
        guard let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw MOIError(400, "Invalid HTTP headers.") }
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/") else { throw MOIError(400, "Expected HTTP/1.1 origin-form request.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw MOIError(400, "Invalid header.") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[name] == nil else { throw MOIError(400, "Duplicate or invalid header.") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] != nil else { throw MOIError(400, "Host header required.") }
        guard headers["transfer-encoding"] == nil else { throw MOIError(400, "Chunked request bodies are unsupported; send Content-Length.") }
        guard headers["expect"] == nil else { throw MOIError(417, "Expect is unsupported.") }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(rawLength), length >= 0 else { throw MOIError(400, "Invalid Content-Length.") }
        guard length <= 16384 else { throw MOIError(413, "Request body exceeds 16 KB.") }
        let end = boundary.upperBound + length
        if data.count < end { return nil }
        guard data.count == end else { throw MOIError(400, "Pipelined requests are unsupported.") }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(data[boundary.upperBound..<end]))
    }
}
