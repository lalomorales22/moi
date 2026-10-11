import Foundation
import MOICore

@main struct MOIHost {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3, let spec = ModelSpec.catalog.first(where: { $0.id == args[1] }),
              let key = ProcessInfo.processInfo.environment["MOI_API_KEY"], key.count >= 24 else {
            print("Usage: MOI_API_KEY=<24+ character key> swift run moi-host <qwen3-0.6b|gemma-3-270m|gemma-4-e2b> <model.litertlm> [port]")
            return
        }
        let engine = InferenceEngine()
        print("Loading \(spec.name) on this Mac for development validation…")
        try await engine.load(spec: spec, file: URL(fileURLWithPath: args[2]))
        let server = HTTPServer(engine: engine)
        let port = args.count > 3 ? UInt16(args[3]) ?? 8081 : 8081
        try server.start(port: port, key: key, modelID: spec.id, name: "MOI development Mac")
        print("MOI development host listening on port \(port). This is not an iPhone benchmark.")
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
        server.stop()
    }
}
