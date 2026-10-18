import Foundation
import LiteRTLM

public struct Generation: Sendable {
    public let text: String
    public let promptTokens: Int?
    public let outputTokens: Int?
    public let tokensPerSecond: Double?
    public let firstTokenSeconds: Double?
    public let elapsed: Double
    public let finishReason: String
}

public actor InferenceEngine {
    private var engine: Engine?
    private var active: Conversation?
    private var busy = false
    private var loadedID: String?
    public init() {}

    public func load(spec: ModelSpec, file: URL) async throws {
        guard !busy else { throw MOIError(409, "The engine is busy.") }
        busy = true
        defer { busy = false }
        engine = nil
        loadedID = nil
        try spec.verify(file: file)
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MOI/\(spec.id)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let config = try EngineConfig(modelPath: file.path, backend: spec.gpu ? .gpu : .cpu(threadCount: 2), maxNumTokens: 1024, cacheDir: cache.path)
        let candidate = Engine(engineConfig: config)
        try await candidate.initialize()
        try Task.checkCancellation()
        engine = candidate
        loadedID = spec.id
    }

    public func unload() throws {
        guard !busy else { throw MOIError(409, "Wait for the current operation before unloading.") }
        active = nil; engine = nil; loadedID = nil
    }

    public func cancel() { try? active?.cancel() }

    public func generate(_ request: ChatRequest, onChunk: @escaping @Sendable (String) async throws -> Void) async throws -> Generation {
        guard !busy else { throw MOIError(429, "MOI is handling another request. Try again shortly.") }
        guard let engine, let loadedID else { throw MOIError(503, "Load a model on the phone first.") }
        guard request.model == loadedID || request.model == "moi" else { throw MOIError(404, "Requested model is not loaded. See /v1/models.") }
        busy = true
        defer { active = nil; busy = false }
        let system = request.messages.first?.role == "system" ? request.messages.first?.content : nil
        let history = request.messages.dropLast().filter { $0.role != "system" }.map { Message($0.content, role: $0.role == "assistant" ? .model : .user) }
        let config = ConversationConfig(
            systemMessage: system.map { Message($0, role: .system) }, initialMessages: history,
            // LiteRT-LM's sampler seed defaults to 0, which made every request with the same
            // prompt sample the same tokens. A fresh seed per request restores real sampling.
            samplerConfig: try SamplerConfig(topK: 40, topP: 0.9, temperature: Float(request.temperature ?? 0.7),
                                             seed: Int.random(in: 1...Int(Int32.max))),
            thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0), automaticToolCalling: false)
        // Small models (Gemma 3 270M, Qwen 3 0.6B) easily loop on one phrase. A mild penalty on
        // tokens they already generated, plus a ban on repeating any 5-token run within a reply,
        // keeps answers varied without disturbing short structured lines.
        let repetition = RepetitionPenaltyConfig(repetitionPenalty: 1.1, windowSize: 64)
        let noRepeat = NoRepeatNgramConfig(noRepeatNgramSize: 5, windowSize: 256)
        let conversation = try await engine.createConversation(with: config)
        active = conversation
        let start = Date()
        var text = ""
        var first: Double?
        return try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                for try await chunk in conversation.sendMessageStream(Message(request.messages.last!.content),
                                                                      repetitionPenaltyConfig: repetition,
                                                                      noRepeatNgramConfig: noRepeat,
                                                                      maxOutputTokens: request.outputLimit) {
                    try Task.checkCancellation()
                    let value = chunk.toString
                    if !value.isEmpty {
                        if first == nil { first = Date().timeIntervalSince(start) }
                        text += value
                        try await onChunk(value)
                    }
                }
                try Task.checkCancellation()
            } catch { try? conversation.cancel(); throw error }
            let benchmark = try? conversation.getBenchmarkInfo()
            return Generation(text: text, promptTokens: benchmark?.lastPrefillTokenCount, outputTokens: benchmark?.lastDecodeTokenCount,
                              tokensPerSecond: benchmark?.lastDecodeTokensPerSecond, firstTokenSeconds: first,
                              elapsed: Date().timeIntervalSince(start), finishReason: (benchmark?.lastDecodeTokenCount ?? 0) >= request.outputLimit ? "length" : "stop")
        }, onCancel: { try? conversation.cancel() })
    }
}
