import Foundation
import CryptoKit

public struct ModelSpec: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let repository: String
    public let revision: String
    public let filename: String
    public let bytes: Int64
    public let sha256: String
    public let gpu: Bool
    // Conservative device policy based on the physical iPhone 11 memory-limit failure.
    // Meeting this floor does not establish compatibility on an untested phone.
    public var minimumDeviceMemoryGB: Int { id == "gemma-4-e2b" ? 6 : 0 }
    public var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")! }
    public static let catalog: [ModelSpec] = [
        ModelSpec(id: "qwen3-0.6b", name: "Qwen 3 · 0.6B", summary: "345 MB · Metal · small, no account needed", repository: "litert-community/Qwen3-0.6B", revision: "a3c5d805ae362dff7f580bc25f2dfb9a5a7eaa76", filename: "Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm", bytes: 344671744, sha256: "03e7da1eb1108b50dffaa9bb52cc7bcbad2eb0c66ca990267f480c1e545d2856", gpu: true),
        ModelSpec(id: "gemma-3-270m", name: "Gemma 3 · 270M", summary: "304 MB · CPU · optional gated download", repository: "litert-community/gemma-3-270m-it", revision: "9d2093270fb5aa49a986b49b5779d763dde7b630", filename: "gemma3-270m-it-q8.litertlm", bytes: 304005120, sha256: "757e9119fa5bd667a2774fb470ac4afcd3190a21c677f8e69a5d6bc908abdd63", gpu: false),
        ModelSpec(id: "gemma-4-e2b", name: "Gemma 4 · E2B", summary: "2.01 GB · Metal · experimental, 6+ GB RAM only", repository: "litert-community/gemma-4-E2B-it-litert-lm", revision: "b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1", filename: "gemma-4-E2B-it-gpu.litertlm", bytes: 2008432640, sha256: "a53a59001894c58e6bdb5b9b227709f91a2e3e556baa7d85acf9c55402ba5cf5", gpu: true)
    ]

    public func verify(file: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size == bytes else { throw MOIError(400, "Model file is incomplete; download it again.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw MOIError(400, "Model checksum did not match. File was not loaded.") }
    }
}

public struct MOIError: Error, LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}
