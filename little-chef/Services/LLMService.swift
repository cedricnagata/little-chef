//
//  LLMService.swift
//  little-chef
//
//  On-device LLM inference using MLX with PrismML Bonsai 8B 1-bit model.
//  Follows MLXChatExample patterns: lazy load, AsyncStream generation, Memory.cacheLimit.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

@MainActor
class LLMService: ObservableObject {
    static let shared = LLMService()

    // MARK: - Published State
    @Published var isLoaded = false
    @Published var isGenerating = false
    @Published var loadError: String?
    @Published var loadProgress: Double = 0.0
    @Published var isLoadingModel = false

    // MARK: - Private State
    private var modelContainer: MLXLMCommon.ModelContainer?

    private let modelConfiguration = ModelConfiguration(
        id: "prism-ml/Bonsai-8B-mlx-1bit",
        defaultPrompt: "You are a helpful assistant."
    )

    // MARK: - Model Lifecycle

    /// Load model into memory. Called lazily on first inference, or manually from Settings.
    private func loadModel() async throws -> MLXLMCommon.ModelContainer {
        // Return cached container if already loaded
        if let container = modelContainer {
            return container
        }

        guard !isLoadingModel else {
            // Wait for in-progress load to finish
            while isLoadingModel {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let container = modelContainer { return container }
            throw LLMError.loadFailed("Model failed to load")
        }

        isLoadingModel = true
        loadProgress = 0.0
        loadError = nil

        // Cap GPU cache to 20MB (matches MLXChatExample)
        MLX.Memory.cacheLimit = 20 * 1024 * 1024

        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfiguration
            ) { progress in
                Task { @MainActor in
                    self.loadProgress = progress.fractionCompleted
                }
            }

            self.modelContainer = container
            isLoaded = true
            loadProgress = 1.0
            isLoadingModel = false
            return container
        } catch {
            loadError = error.localizedDescription
            isLoadingModel = false
            throw error
        }
    }

    /// Pre-warm: download and load model ahead of time (called from Settings).
    func preloadModel() async throws {
        _ = try await loadModel()
    }

    /// Release model and free GPU memory.
    func unloadModel() {
        modelContainer = nil
        isLoaded = false
        isLoadingModel = false
        loadProgress = 0.0
        loadError = nil
        MLX.Memory.clearCache()
    }

    // MARK: - Chat Completion

    func generateChatCompletion(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: CookingTools? = nil
    ) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }

        // Lazy load model on first use
        let container = try await loadModel()

        // Inject tool schemas into system message
        let processedMessages = injectToolSchemas(messages: messages, tools: tools)

        // Convert to Chat.Message (modern MLXLMCommon API)
        let chatMessages: [Chat.Message] = processedMessages.map { msg in
            switch msg.role {
            case .system: return .system(msg.content)
            case .user: return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            }
        }

        let userInput = UserInput(chat: chatMessages)

        // Generate using modern AsyncStream API (matches MLXChatExample exactly)
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

        // Consume stream to collect output
        var output = ""
        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                output += chunk
            case .info(_):
                break
            case .toolCall(_):
                break
            }
        }

        // Parse and execute tool calls
        let finalOutput = await processToolCalls(output: output, tools: tools)

        // Strip thinking tags
        return stripThinkingTags(from: finalOutput)
    }

    // MARK: - Model Info

    func getModelInfo() -> ModelInfo? {
        guard isLoaded else { return nil }
        return ModelInfo(
            name: "Bonsai 8B",
            parameters: "prism-ml/Bonsai-8B-mlx-1bit",
            quantization: "1-bit",
            contextLength: 8192
        )
    }

    // MARK: - Tool Calling

    private func injectToolSchemas(messages: [ChatMessage], tools: CookingTools?) -> [ChatMessage] {
        guard let tools else { return messages }

        var processed = messages
        if let sysIndex = processed.firstIndex(where: { $0.role == .system }) {
            let toolPrompt = """

            # Available Tools

            When the user explicitly asks you to set, start, pause, or delete a timer, respond with a tool call in this exact format:

            <tool_call>
            {"name": "tool_name", "arguments": {"key": "value"}}
            </tool_call>

            \(tools.toolSchemaText)

            IMPORTANT: Only use tools when the user explicitly requests timer actions. For all other questions, respond normally without tool calls.
            """
            processed[sysIndex] = ChatMessage(
                role: .system,
                content: processed[sysIndex].content + toolPrompt
            )
        }
        return processed
    }

    private func processToolCalls(output: String, tools: CookingTools?) async -> String {
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
            guard let jsonRange = Range(match.range(at: 1), in: output) else { continue }
            let jsonStr = String(output[jsonRange])

            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let toolName = json["name"] as? String,
                  let arguments = json["arguments"] as? [String: Any] else { continue }

            let toolResult = await tools.execute(toolName: toolName, arguments: arguments)

            if let fullRange = Range(match.range, in: result) {
                result.replaceSubrange(fullRange, with: toolResult)
            }
        }

        return result
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
