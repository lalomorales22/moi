import Foundation

/// A one-time, non-secret request placed in the app's Documents folder over USB.
public struct InstallationRequest: Decodable, Sendable {
    public let version: Int
    public let id: String
    public let modelID: String

    public static func parse(_ data: Data) throws -> InstallationRequest {
        guard data.count <= 4096 else { throw MOIError(400, "Installer request is too large. Rerun setup from the Mac.") }
        let request = try JSONDecoder().decode(InstallationRequest.self, from: data)
        guard request.version == 1, UUID(uuidString: request.id) != nil,
              ["qwen3-0.6b", "gemma-3-270m"].contains(request.modelID) else {
            throw MOIError(400, "Unsupported installer request. Rerun setup from the Mac with Qwen 3 or Gemma 3.")
        }
        return request
    }
}
