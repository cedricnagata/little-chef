//
//  MLXLLMService.swift
//  little-chef
//
//  Service for on-device LLM inference using MLX Swift
//  Based on mlx-swift-examples MLXLLM patterns
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Model configuration for Bonsai 8B 1-bit quantized model
extension ModelConfiguration {
    static let bonsai8B_1bit = ModelConfiguration(
        id: "prism-ml/Bonsai-8B-mlx-1bit"
    )
}

/// Service for managing local LLM inference
@MainActor
class MLXLLMService: ObservableObject {
    // Shared instances for different purposes
    static let parsingService = MLXLLMService(
        modelConfiguration: LLMRegistry.llama3_2_3B_4bit,
        name: "Llama 3.2 3B (Parsing)",
        quantization: "4-bit",
        contextLength: 8192
    )
    static let cookingService = MLXLLMService(
        modelConfiguration: .bonsai8B_1bit,
        name: "Bonsai 8B (Cooking)",
        quantization: "1-bit",
        contextLength: 32768
    )

    // MARK: - Published Properties
    @Published var isLoaded: Bool = false
    @Published var isGenerating: Bool = false
    @Published var loadError: String?
    @Published var loadProgress: Double = 0.0
    @Published var isLoadingModel: Bool = false

    // MARK: - Private Properties
    enum LoadState {
        case idle
        case loaded(ModelContainer)
    }

    private var loadState = LoadState.idle
    private let modelConfiguration: ModelConfiguration
    private let modelName: String
    private let modelQuantization: String
    private let modelContextLength: Int
    private let generateParameters = GenerateParameters(maxTokens: 2048, temperature: 0.7)

    // MARK: - Initialization
    init(modelConfiguration: ModelConfiguration, name: String, quantization: String = "4-bit", contextLength: Int = 8192) {
        self.modelConfiguration = modelConfiguration
        self.modelName = name
        self.modelQuantization = quantization
        self.modelContextLength = contextLength
    }

    // MARK: - Model Management

    /// Load the model - can be called multiple times, subsequent calls return the loaded model
    func loadLocalModel() async throws -> ModelContainer {
        switch loadState {
        case .idle:
            isLoadingModel = true
            loadProgress = 0.0
            print("📥 Loading \(modelName): \(modelConfiguration.id)")

            // Limit the buffer cache
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

            // Retry logic for offline mode errors (common on first download)
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    let modelContainer = try await LLMModelFactory.shared.loadContainer(
                        configuration: modelConfiguration
                    ) { progress in
                        Task { @MainActor in
                            self.loadProgress = progress.fractionCompleted
                            print("📥 Downloading \(self.modelName): \(Int(progress.fractionCompleted * 100))%")
                        }
                    }

                    let numParams = await modelContainer.perform { context in
                        context.model.numParameters()
                    }

                    print("✅ \(modelName) loaded successfully. Weights: \(numParams / (1024*1024))M")
                    isLoaded = true
                    isLoadingModel = false
                    loadProgress = 1.0
                    loadError = nil
                    loadState = .loaded(modelContainer)
                    return modelContainer
                } catch {
                    let errorString = String(describing: error)
                    if errorString.contains("offlineModeError") || errorString.contains("Repository not available") {
                        print("⚠️ Attempt \(attempt)/3: Offline mode error, retrying in 1s...")
                        lastError = error
                        if attempt < 3 {
                            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                            continue
                        }
                    } else {
                        // For other errors, fail immediately
                        isLoadingModel = false
                        loadProgress = 0.0
                        throw error
                    }
                }
            }

            // If we exhausted all retries, throw the last error
            isLoadingModel = false
            loadProgress = 0.0
            throw lastError ?? LLMServiceError.loadFailed(NSError(domain: "MLXLLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load model after 3 attempts"]))

        case .loaded(let modelContainer):
            print("⏭️ \(modelName) already loaded, returning existing")
            return modelContainer
        }
    }

    /// Unload the model to free memory
    func unloadModel() {
        loadState = .idle
        isLoaded = false
        isLoadingModel = false
        loadProgress = 0.0
    }

    // MARK: - Chat Completion

    /// Generate a chat completion with optional cooking tools
    func generateChatCompletion(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        cookingTools: CookingTools? = nil
    ) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }

        do {
            // Load model if not already loaded (lazy loading)
            let modelContainer = try await loadLocalModel()

            // Convert messages to Chat.Message format
            var chatMessages: [Chat.Message] = []
            for msg in messages {
                switch msg.role {
                case .system:
                    chatMessages.append(.system(msg.content))
                case .user:
                    chatMessages.append(.user(msg.content))
                case .assistant:
                    chatMessages.append(.assistant(msg.content))
                }
            }

            // Create UserInput with tool schemas if available
            let userInput = UserInput(
                chat: chatMessages,
                tools: cookingTools?.allSchemas
            )

            // Debug: Log tool schemas
            if let schemas = cookingTools?.allSchemas {
                print("📋 Providing \(schemas.count) timer tool schemas to LLM")
            } else {
                print("⚠️ No tool schemas provided!")
            }

            // Generate response using ModelContainer
            var output = ""
            let params = GenerateParameters(
                maxTokens: maxTokens ?? generateParameters.maxTokens,
                temperature: temperature ?? generateParameters.temperature
            )

            try await modelContainer.perform { (context: ModelContext) -> Void in
                let lmInput = try await context.processor.prepare(input: userInput)
                let stream = try MLXLMCommon.generate(
                    input: lmInput, parameters: params, context: context
                )

                // Collect all generations
                for try await generation in stream {
                    // Collect text chunks
                    if let chunk = generation.chunk {
                        output += chunk
                    }

                    // Handle tool calls
                    if let toolCall = generation.toolCall, let cookingTools = cookingTools {
                        print("🔧 Tool call detected: \(toolCall.function.name)")
                        let toolResult = try await handleToolCall(toolCall, cookingTools: cookingTools)
                        print("🔧 Tool result: \(toolResult)")
                        output += "\n\(toolResult)\n"
                    }
                }
            }

            // Strip out thinking tags before returning
            let cleanedOutput = stripThinkingTags(from: output)
            return cleanedOutput
        } catch {
            throw LLMServiceError.generationFailed(error)
        }
    }

    /// Strip thinking tags from model output
    private func stripThinkingTags(from text: String) -> String {
        // Remove <think>...</think> tags and their contents
        var result = text

        // Use regex to remove thinking tags
        let pattern = "<think>.*?</think>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Trim whitespace and newlines that might be left over
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Handle tool calls from the LLM
    private func handleToolCall(_ toolCall: ToolCall, cookingTools: CookingTools) async throws -> String {
        print("🔧 Tool called: \(toolCall.function.name)")

        let toolResultJSON: String
        switch toolCall.function.name {
        case "set_timer":
            toolResultJSON = try await toolCall.execute(with: cookingTools.setTimer).toolResult
        case "start_timer":
            toolResultJSON = try await toolCall.execute(with: cookingTools.startTimer).toolResult
        case "pause_timer":
            toolResultJSON = try await toolCall.execute(with: cookingTools.pauseTimer).toolResult
        case "delete_timer":
            toolResultJSON = try await toolCall.execute(with: cookingTools.deleteTimer).toolResult
        default:
            return "Error: Unknown tool '\(toolCall.function.name)'"
        }

        // Parse the JSON to extract just the message
        if let data = toolResultJSON.data(using: .utf8),
           let timerOutput = try? JSONDecoder().decode(TimerOutput.self, from: data) {
            return timerOutput.message
        }

        // Fallback to raw result if parsing fails
        return toolResultJSON
    }

    // MARK: - Helper Methods

    /// Check if model is ready for inference
    func isModelReady() -> Bool {
        if case .loaded = loadState {
            return true
        }
        return false
    }

    /// Get model information
    func getModelInfo() -> ModelInfo? {
        guard isLoaded else { return nil }

        return ModelInfo(
            name: modelName,
            parameters: String(describing: modelConfiguration.id),
            quantization: modelQuantization,
            contextLength: modelContextLength
        )
    }
}

// MARK: - Supporting Types

/// Chat message for LLM input
struct ChatMessage {
    enum Role {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
}

/// Model information
struct ModelInfo {
    let name: String
    let parameters: String
    let quantization: String
    let contextLength: Int
}

// MARK: - Error Types

enum LLMServiceError: LocalizedError {
    case modelNotLoaded
    case loadFailed(Error)
    case generationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model is not loaded. Please load the model before generating."
        case .loadFailed(let error):
            return "Failed to load model: \(error.localizedDescription)"
        case .generationFailed(let error):
            return "Failed to generate response: \(error.localizedDescription)"
        }
    }
}
