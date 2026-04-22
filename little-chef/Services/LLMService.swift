//
//  LLMService.swift
//  little-chef
//
//  On-device LLM inference using MLX with PrismML Bonsai 8B 1-bit model.
//  Follows MLXChatExample patterns: lazy load, AsyncStream generation, Memory.cacheLimit.
//  Uses MLX native tool calling for timer operations.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import BigBroKit

@MainActor
class LLMService: ObservableObject {
    static let shared = LLMService()

    // MARK: - Published State
    @Published var isLoaded = false
    @Published var isGenerating = false
    @Published var loadError: String?
    @Published var loadProgress: Double = 0.0
    @Published var isLoadingModel = false
    @Published var downloadedModelIds: Set<String> = []
    @Published var currentProvider: LLMProvider = .local {
        didSet { UserDefaults.standard.set(currentProvider.rawValue, forKey: "little-chef.llm-provider") }
    }

    // MARK: - Private State
    /// Containers keyed by model ID — allows both 8B and 4B to be loaded
    private var modelContainers: [String: MLXLMCommon.ModelContainer] = [:]
    /// Which model ID is currently being loaded (to prevent double-loads)
    @Published var currentlyLoadingModelId: String?

    let bigBroClient = BigBroClient()

    private let defaultModelConfig = ModelConfiguration(
        id: "prism-ml/Bonsai-8B-mlx-1bit",
        defaultPrompt: "You are a helpful assistant."
    )

    private init() {
        // Restore provider from UserDefaults for instant sync at startup
        if let stored = UserDefaults.standard.string(forKey: "little-chef.llm-provider"),
           let restored = LLMProvider(rawValue: stored) {
            currentProvider = restored
        }
        refreshDownloadedModels()
    }

    /// Refresh which models are cached on disk.
    func refreshDownloadedModels() {
        var ids = Set<String>()
        for choice in CookingModelChoice.allCases {
            if isModelDownloaded(choice.modelId) {
                ids.insert(choice.modelId)
            }
        }
        downloadedModelIds = ids
    }

    // MARK: - Model Lifecycle

    private func loadModel(modelId: String? = nil) async throws -> MLXLMCommon.ModelContainer {
        let id = modelId ?? "prism-ml/Bonsai-8B-mlx-1bit"

        if let container = modelContainers[id] {
            print("🤖 [LLM] Model \(id) already loaded, returning cached container")
            return container
        }

        guard currentlyLoadingModelId != id else {
            print("🤖 [LLM] Model \(id) already loading, waiting...")
            while currentlyLoadingModelId == id {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let container = modelContainers[id] { return container }
            throw LLMError.loadFailed("Model failed to load")
        }

        // Unload any other model first — only one model in memory at a time
        for existingId in modelContainers.keys where existingId != id {
            print("🤖 [LLM] Unloading \(existingId) before loading \(id)")
            modelContainers.removeValue(forKey: existingId)
        }
        MLX.Memory.clearCache()

        print("🤖 [LLM] Starting model load for \(id)...")
        currentlyLoadingModelId = id
        isLoadingModel = true
        loadProgress = 0.0
        loadError = nil

        MLX.Memory.cacheLimit = 20 * 1024 * 1024

        let config = ModelConfiguration(id: id, defaultPrompt: "You are a helpful assistant.")

        do {
            print("🤖 [LLM] Calling LLMModelFactory.loadContainer for \(id)...")
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            ) { progress in
                Task { @MainActor in
                    self.loadProgress = progress.fractionCompleted
                    if Int(progress.fractionCompleted * 100) % 25 == 0 {
                        print("🤖 [LLM] Download progress: \(Int(progress.fractionCompleted * 100))%")
                    }
                }
            }

            print("🤖 [LLM] ✅ Model \(id) loaded successfully")
            self.modelContainers[id] = container
            isLoaded = true
            loadProgress = 1.0
            isLoadingModel = false
            currentlyLoadingModelId = nil
            refreshDownloadedModels()
            return container
        } catch {
            print("🤖 [LLM] ❌ Model \(id) load failed: \(error)")
            print("🤖 [LLM] Error type: \(type(of: error))")
            loadError = error.localizedDescription
            isLoadingModel = false
            currentlyLoadingModelId = nil
            throw error
        }
    }

    /// Download a model to disk cache without keeping it loaded in memory.
    func downloadModel(modelId: String) async throws {
        _ = try await loadModel(modelId: modelId)
        // Unload from memory — the files stay cached on disk
        modelContainers.removeValue(forKey: modelId)
        isLoaded = !modelContainers.isEmpty
        MLX.Memory.clearCache()
        print("🤖 [LLM] Downloaded \(modelId) to cache, unloaded from memory")
    }

    /// Download and load a model into memory (used internally).
    func preloadModel(modelId: String? = nil) async throws {
        _ = try await loadModel(modelId: modelId)
    }

    func unloadModel(modelId: String? = nil) {
        if let modelId {
            modelContainers.removeValue(forKey: modelId)
        } else {
            modelContainers.removeAll()
        }
        isLoaded = !modelContainers.isEmpty
        isLoadingModel = false
        loadProgress = 0.0
        loadError = nil
        MLX.Memory.clearCache()
    }

    func isModelLoaded(_ modelId: String) -> Bool {
        return modelContainers[modelId] != nil
    }

    /// Check if a model has been downloaded to the HuggingFace hub cache.
    func isModelDownloaded(_ modelId: String) -> Bool {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        // MLX Swift stores models at <CachesDirectory>/models/<org>/<repo>
        let modelPath = cacheDir.appendingPathComponent("models/\(modelId)")
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    // MARK: - Chat Completion

    func generateChatCompletion(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: CookingTools? = nil,
        modelId: String? = nil
    ) async throws -> String {
        if currentProvider == .bigBro {
            return try await generateBigBroChatCompletion(messages: messages, tools: tools)
        }

        isGenerating = true
        defer { isGenerating = false }

        let container = try await loadModel(modelId: modelId)

        // Convert to Chat.Message
        let chatMessages: [Chat.Message] = messages.map { msg in
            switch msg.role {
            case .system: return .system(msg.content)
            case .user: return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            }
        }

        // Build native tool specs if tools are provided
        let toolSpecs: [ToolSpec]? = tools?.nativeToolSpecs

        let userInput = UserInput(chat: chatMessages, tools: toolSpecs)

        // Generate using AsyncStream API
        let stream: AsyncStream<Generation> = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(
                maxTokens: maxTokens ?? 2048,
                temperature: temperature ?? 0.7
            )
            return try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context
            )
        }

        // Consume stream — collect text chunks and native tool calls
        var output = ""
        var nativeToolCalls: [(name: String, arguments: [String: Any])] = []

        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                output += chunk
            case .info(_):
                break
            case .toolCall(let toolCall):
                let args = toolCall.function.arguments.mapValues { $0.anyValue }
                nativeToolCalls.append((name: toolCall.function.name, arguments: args))
            @unknown default:
                break
            }
        }
        print("=== OUTPUT: '\(output.prefix(200))' | TOOL CALLS: \(nativeToolCalls.count) ===")

        // Execute native tool calls
        if !nativeToolCalls.isEmpty, let tools {
            var toolResults: [String] = []
            for call in nativeToolCalls {
                print("=== TOOL CALL: \(call.name), args: \(call.arguments) ===")
                let result = tools.execute(toolName: call.name, arguments: call.arguments)
                print("=== TOOL RESULT: \(result) ===")
                toolResults.append(result)
            }
            // Combine any text output with tool results
            let textPart = stripThinkingTags(from: output)
            let toolPart = toolResults.joined(separator: "\n")
            if textPart.isEmpty {
                return toolPart
            }
            return textPart + "\n" + toolPart
        }

        // No native tool calls — clean up text and try fallbacks
        let cleaned = stripThinkingTags(from: output)

        // Try text-based <tool_call> tags first
        let afterTextTools = processTextToolCalls(output: cleaned, tools: tools)

        // If tools are available and no tool calls were found, try to infer timer actions from the text
        if let tools, nativeToolCalls.isEmpty {
            inferTimerAction(from: afterTextTools, tools: tools)
        }

        return afterTextTools
    }

    // MARK: - Streaming Chat Completion

    /// Streaming variant — calls `onChunk` with each text fragment as it arrives.
    /// Returns the full response. If the model emits tool calls, they are executed
    /// and the result is returned (no streaming for tool responses).
    func generateChatCompletionStreaming(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: CookingTools? = nil,
        modelId: String? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        if currentProvider == .bigBro {
            return try await generateBigBroChatCompletionStreaming(messages: messages, tools: tools, onChunk: onChunk)
        }

        isGenerating = true
        defer { isGenerating = false }

        let container = try await loadModel(modelId: modelId)

        let chatMessages: [Chat.Message] = messages.map { msg in
            switch msg.role {
            case .system: return .system(msg.content)
            case .user: return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            }
        }

        let toolSpecs: [ToolSpec]? = tools?.nativeToolSpecs
        let userInput = UserInput(chat: chatMessages, tools: toolSpecs)

        let stream: AsyncStream<Generation> = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(
                maxTokens: maxTokens ?? 2048,
                temperature: temperature ?? 0.7
            )
            return try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context
            )
        }

        var output = ""
        var nativeToolCalls: [(name: String, arguments: [String: Any])] = []

        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                output += chunk
                // Stream text chunks to caller in real-time
                if !chunk.isEmpty {
                    onChunk(chunk)
                }
            case .info(_):
                break
            case .toolCall(let toolCall):
                let args = toolCall.function.arguments.mapValues { $0.anyValue }
                nativeToolCalls.append((name: toolCall.function.name, arguments: args))
            @unknown default:
                break
            }
        }

        // Execute native tool calls (not streamed — delivered as final result)
        if !nativeToolCalls.isEmpty, let tools {
            var toolResults: [String] = []
            for call in nativeToolCalls {
                let result = tools.execute(toolName: call.name, arguments: call.arguments)
                toolResults.append(result)
            }
            let textPart = stripThinkingTags(from: output)
            let toolPart = toolResults.joined(separator: "\n")
            let finalResult = textPart.isEmpty ? toolPart : textPart + "\n" + toolPart
            return finalResult
        }

        // No native tool calls — clean up text and try fallbacks
        let cleaned = stripThinkingTags(from: output)
        let afterTextTools = processTextToolCalls(output: cleaned, tools: tools)

        if let tools, nativeToolCalls.isEmpty {
            inferTimerAction(from: afterTextTools, tools: tools)
        }

        return afterTextTools
    }

    // MARK: - BigBro Chat

    private func bigBroMessages(from messages: [ChatMessage]) -> [BigBroKit.Message] {
        messages.map { msg in
            switch msg.role {
            case .system: return BigBroKit.Message(role: .system, content: msg.content)
            case .user: return BigBroKit.Message(role: .user, content: msg.content)
            case .assistant: return BigBroKit.Message(role: .assistant, content: msg.content)
            }
        }
    }

    private func generateBigBroChatCompletion(
        messages: [ChatMessage],
        tools: CookingTools? = nil
    ) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }

        // BigBro server only supports SSE streaming — collect all chunks into a full string
        var output = ""
        for try await chunk in bigBroClient.chatStream(bigBroMessages(from: messages)) {
            output += chunk
        }

        let afterTextTools = processTextToolCalls(output: output, tools: tools)
        if let tools { inferTimerAction(from: afterTextTools, tools: tools) }
        return afterTextTools
    }

    private func generateBigBroChatCompletionStreaming(
        messages: [ChatMessage],
        tools: CookingTools? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }

        var output = ""
        for try await chunk in bigBroClient.chatStream(bigBroMessages(from: messages)) {
            output += chunk
            if !chunk.isEmpty { onChunk(chunk) }
        }

        let afterTextTools = processTextToolCalls(output: output, tools: tools)
        if let tools { inferTimerAction(from: afterTextTools, tools: tools) }
        return afterTextTools
    }

    // MARK: - Model Info

    func getModelInfo(for choice: CookingModelChoice = .bonsai8B) -> ModelInfo? {
        guard modelContainers[choice.modelId] != nil else { return nil }
        return ModelInfo(
            name: choice.displayName,
            parameters: choice.modelId,
            quantization: "1-bit",
            contextLength: 8192
        )
    }

    // MARK: - Text-based Tool Call Fallback

    /// Fallback parser for models that output <tool_call> tags as text instead of native tool calls
    private func processTextToolCalls(output: String, tools: CookingTools?) -> String {
        guard let tools else { return output }

        let pattern = "<tool_call>\\s*(.+?)\\s*</tool_call>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
            return output
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)
        guard !matches.isEmpty else { return output }

        var result = output
        for match in matches.reversed() {
            guard let jsonRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }

            let jsonStr = String(result[jsonRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let toolName = json["name"] as? String,
               let arguments = json["arguments"] as? [String: Any] {
                let toolResult = tools.execute(toolName: toolName, arguments: arguments)
                result.replaceSubrange(fullRange, with: toolResult)
            } else {
                result.replaceSubrange(fullRange, with: "")
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Done!" : trimmed
    }

    // MARK: - Timer Action Inference

    /// When the model responds with text like "Timer stopped" without a tool call,
    /// infer the action and execute it.
    private func inferTimerAction(from text: String, tools: CookingTools) {
        let lower = text.lowercased()

        // Extract a quoted timer name if present, e.g. 'pasta' or "pasta"
        let namePattern = "['\"]([^'\"]+)['\"]"
        let nameRegex = try? NSRegularExpression(pattern: namePattern)
        let nameRange = NSRange(text.startIndex..., in: text)
        let timerName = nameRegex?.firstMatch(in: text, range: nameRange)
            .flatMap { Range($0.range(at: 1), in: text) }
            .map { String(text[$0]) }

        let name = timerName ?? "timer"

        if lower.contains("stop") || lower.contains("paus") {
            _ = tools.execute(toolName: "pause_timer", arguments: ["name": name])
        } else if lower.contains("delet") || lower.contains("remov") || lower.contains("cancel") {
            _ = tools.execute(toolName: "delete_timer", arguments: ["name": name])
        } else if lower.contains("start") || lower.contains("resum") {
            _ = tools.execute(toolName: "start_timer", arguments: ["name": name])
        }
    }

    // MARK: - Text Processing

    private func stripThinkingTags(from text: String) -> String {
        var result = text
        let pattern = "<think>.*?</think>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Supporting Types

struct ChatMessage {
    enum Role {
        case system, user, assistant
    }
    let role: Role
    let content: String
}

struct ModelInfo {
    let name: String
    let parameters: String
    let quantization: String
    let contextLength: Int
}

enum LLMError: LocalizedError {
    case modelNotLoaded
    case loadFailed(String)
    case downloadFailed(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Model is not loaded."
        case .loadFailed(let msg): return "Failed to load model: \(msg)"
        case .downloadFailed(let msg): return "Failed to download model: \(msg)"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        }
    }
}
