import XCTest
@testable import MOICore

final class InstallationTests: XCTestCase {
    func testSupportedOneTimeSetup() throws {
        for model in ["qwen3-0.6b", "gemma-3-270m"] {
            let id = UUID().uuidString.lowercased()
            let request = try InstallationRequest.parse(APIJSON.encode(["version": 1, "id": id, "modelID": model]))
            XCTAssertEqual(request.id, id)
            XCTAssertEqual(request.modelID, model)
        }
    }

    func testRejectsUnsafeOrUnsupportedSetup() {
        let id = UUID().uuidString
        for value: [String: Any] in [
            ["version": 2, "id": id, "modelID": "qwen3-0.6b"],
            ["version": 1, "id": "not-an-id", "modelID": "qwen3-0.6b"],
            ["version": 1, "id": id, "modelID": "../../file"],
            ["version": 1, "id": id, "modelID": "gemma-4-e2b"],
            ["version": 1, "id": id]
        ] { XCTAssertThrowsError(try InstallationRequest.parse(APIJSON.encode(value))) }
        XCTAssertThrowsError(try InstallationRequest.parse(Data(repeating: 32, count: 4097)))
    }
}
