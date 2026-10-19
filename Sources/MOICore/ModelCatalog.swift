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
    // Conservative device policy based on the physical iPhone 11 memory-limit failure (Gemma 4
    // E2B on 4 GB) and the model file sizes: the weights are memory-mapped and the GPU delegate
    // keeps its own copy, so the app needs roughly file size + 0.5-1 GB. Meeting this floor does
    // not establish compatibility on an untested phone. Every file here has each section under
    // the 2 GiB limit iOS needs to load it (Gemma 4 E4B and Qwen 3 4B do not, so they are absent).
    public var minimumDeviceMemoryGB: Int {
        switch id {
        case "qwen3-1.7b": return 4
        case "gemma-4-e2b", "smollm3-3b": return 6
        case "ministral-3-3b": return 8
        default: return 0
        }
    }
    /// Engine context (prompt + reply tokens). The small models stay at 1,024; the bigger ones
    /// get 2,048 so a client can send a few turns of history.
    public var contextTokens: Int { bytes > 900_000_000 ? 2048 : 1024 }
    /// Input byte cap for a request to this model: about two bytes per context token, which
    /// leaves room for a 256-token reply even with byte-heavy scripts.
    public var maxInputBytes: Int { contextTokens * 2 }
    public var modelCardURL: URL {
        let source = id == "gemma-3-270m" ? "litert-community/gemma-3-270m-it" : repository
        return URL(string: "https://huggingface.co/\(source)")!
    }
    public var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")! }
    public static let catalog: [ModelSpec] = [
        ModelSpec(id: "qwen3-0.6b", name: "Qwen 3 · 0.6B", summary: "345 MB · Metal · small, no account needed", repository: "litert-community/Qwen3-0.6B", revision: "a3c5d805ae362dff7f580bc25f2dfb9a5a7eaa76", filename: "Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm", bytes: 344671744, sha256: "03e7da1eb1108b50dffaa9bb52cc7bcbad2eb0c66ca990267f480c1e545d2856", gpu: true),
        ModelSpec(id: "gemma-3-270m", name: "Gemma 3 · 270M", summary: "304 MB · CPU · no account needed", repository: "72fstudio/gemma-3-270m-it", revision: "daa9f3663f4752fd1c5239f4defdaf748c1351ba", filename: "gemma3-270m-it-q8.litertlm", bytes: 304005120, sha256: "757e9119fa5bd667a2774fb470ac4afcd3190a21c677f8e69a5d6bc908abdd63", gpu: false),
        ModelSpec(id: "gemma-4-e2b", name: "Gemma 4 · E2B", summary: "2.01 GB · Metal · experimental, 6+ GB RAM only", repository: "litert-community/gemma-4-E2B-it-litert-lm", revision: "b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1", filename: "gemma-4-E2B-it-gpu.litertlm", bytes: 2008432640, sha256: "a53a59001894c58e6bdb5b9b227709f91a2e3e556baa7d85acf9c55402ba5cf5", gpu: true),
        ModelSpec(id: "qwen3-1.7b", name: "Qwen 3 · 1.7B", summary: "977 MB · Metal · 4+ GB RAM", repository: "litert-community/Qwen3-1.7B", revision: "79bf0667b32ae025b972e5fe555fe72ca6e8816c", filename: "Qwen3-1.7B_dynamic_wi4b32_afp32.litertlm", bytes: 977184032, sha256: "2a72330b504a6596d53a2c00923c57173b10f1b83e6a541213ffec08d1fc5de8", gpu: true),
        ModelSpec(id: "smollm3-3b", name: "SmolLM3 · 3B", summary: "2.00 GB · Metal · experimental, 6+ GB RAM", repository: "litert-community/SmolLM3-3B", revision: "7621a4f099a00b0518e0a6e7c5628af08ab4184e", filename: "SmolLM3-3B_q4_block32_ekv4096.litertlm", bytes: 2004633520, sha256: "bdd7eb05b6764fb5a5173bdbdd59354a26f66e4c20b040f0d3da3532071d18f6", gpu: true),
        ModelSpec(id: "ministral-3-3b", name: "Ministral 3 · 3B", summary: "2.34 GB · Metal · experimental, 8+ GB RAM", repository: "litert-community/Ministral-3-3B-Instruct-2512", revision: "f0d5ce0bf03a85e905b0590330fb69ae72784559", filename: "Ministral-3-3B-Instruct-2512_q4_block32_ekv4096.litertlm", bytes: 2342866928, sha256: "13c47bcbaf305e4337f280b27c991168b0c624a6d60e00df10f0f23ebd28ad83", gpu: true)
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
