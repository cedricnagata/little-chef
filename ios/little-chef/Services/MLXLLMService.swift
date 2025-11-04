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

/// Service for managing local LLM inference with Llama 3.2 3B
@MainActor
class MLXLLMService: ObservableObject {
    static let shared = MLXLLMService()

    // MARK: - Published Properties
    @Published var isLoaded: Bool = false
    @Published var isGenerating: Bool = false
    @Published var loadError: String?

    // MARK: - Private Properties
    enum LoadState {
        case idle
        case loaded(ModelContainer)
    }

    private var loadState = LoadState.idle
    private let modelConfiguration = LLMRegistry.llama3_2_3B_4bit
    private let generateParameters = GenerateParameters(maxTokens: 2048, temperature: 0.7)

    // MARK: - Initialization
    private init() {}

    // MARK: - Model Management

    /// Load the model - can be called multiple times, subsequent calls return the loaded model
    func loadLocalModel() async throws -> ModelContainer {
        switch loadState {
        case .idle:
            print("📥 Loading model: \(modelConfiguration.id)")

            // Limit the buffer cache
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

            let modelContainer = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfiguration
            ) { progress in
                Task { @MainActor in
                    print("📥 Downloading: \(Int(progress.fractionCompleted * 100))%")
                }
            }

            let numParams = await modelContainer.perform { context in
                context.model.numParameters()
            }

            print("✅ Model loaded successfully. Weights: \(numParams / (1024*1024))M")
            isLoaded = true
            loadError = nil
            loadState = .loaded(modelContainer)
            return modelContainer

        case .loaded(let modelContainer):
            print("⏭️ Model already loaded, returning existing")
            return modelContainer
        }
    }

    /// Unload the model to free memory
    func unloadModel() {
        loadState = .idle
        isLoaded = false
    }

    // MARK: - Chat Completion

    /// Generate a chat completion
    func generateChatCompletion(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: [ToolDefinition]? = nil
    ) async throws -> String {
        guard isLoaded else {
            throw LLMServiceError.modelNotLoaded
        }

        isGenerating = true
        defer { isGenerating = false }

        do {
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

            // Create UserInput
            // TODO: Add tool support once we figure out the correct ToolSchema format
            let userInput = UserInput(
                chat: chatMessages,
                tools: nil
            )

            // Generate response using ModelContainer
            var output = ""
            let params = GenerateParameters(
                maxTokens: maxTokens ?? generateParameters.maxTokens,
                temperature: temperature ?? generateParameters.temperature
            )

            try await modelContainer.perform { (context: ModelContext) in
                let lmInput = try await context.processor.prepare(input: userInput)
                let stream = try MLXLMCommon.generate(
                    input: lmInput, parameters: params, context: context
                )

                for try await generation in stream {
                    if let chunk = generation.chunk {
                        output += chunk
                    }
                }
            }

            return output
        } catch {
            throw LLMServiceError.generationFailed(error)
        }
    }

    /// Stream chat completion with token-by-token output
    func streamChatCompletion(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: [ToolDefinition]? = nil,
        onToken: @escaping (String) -> Void
    ) async throws {
        guard isLoaded else {
            throw LLMServiceError.modelNotLoaded
        }

        isGenerating = true
        defer { isGenerating = false }

        do {
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

            // Create UserInput
            // TODO: Add tool support once we figure out the correct ToolSchema format
            let userInput = UserInput(
                chat: chatMessages,
                tools: nil
            )

            // Generate response with streaming
            let params = GenerateParameters(
                maxTokens: maxTokens ?? generateParameters.maxTokens,
                temperature: temperature ?? generateParameters.temperature
            )

            try await modelContainer.perform { (context: ModelContext) in
                let lmInput = try await context.processor.prepare(input: userInput)
                let stream = try MLXLMCommon.generate(
                    input: lmInput, parameters: params, context: context
                )

                for try await generation in stream {
                    if let chunk = generation.chunk {
                        Task { @MainActor in
                            onToken(chunk)
                        }
                    }
                }
            }
        } catch {
            throw LLMServiceError.generationFailed(error)
        }
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
            name: "Llama 3.2 3B Instruct 4-bit",
            parameters: "3B",
            quantization: "4-bit",
            contextLength: 8192
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