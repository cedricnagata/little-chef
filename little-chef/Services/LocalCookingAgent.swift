//
//  LocalCookingAgent.swift
//  little-chef
//
//  Local cooking agent that orchestrates LLM + tool calling
//

import Foundation

/// Local agent for handling cooking assistant interactions
@MainActor
class LocalCookingAgent: ObservableObject {
    // MARK: - Dependencies
    private let llmService: LLMService
    private let timerManager: TimerManager

    // MARK: - State
    @Published var isProcessing = false
    private var conversationHistory: [ChatMessage] = []
    private let maxHistoryLength = 20

    // MARK: - Initialization

    convenience init(timerManager: TimerManager) {
        self.init(llmService: .shared, timerManager: timerManager)
    }

    init(llmService: LLMService, timerManager: TimerManager) {
        self.llmService = llmService
        self.timerManager = timerManager
    }

    // MARK: - Public Methods

    func processQuery(
        userMessage: String,
        recipe: Recipe?,
        conversationContext: [Message]
    ) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        let systemMessage = buildSystemMessage(recipe: recipe)
        let userChatMessage = ChatMessage(role: .user, content: userMessage)

        var messages: [ChatMessage] = [systemMessage] + conversationHistory + [userChatMessage]

        if messages.count > maxHistoryLength {
            messages = [systemMessage] + Array(messages.suffix(maxHistoryLength - 1))
        }

        let cookingTools: CookingTools? = llmService.capability.toolCallingEnabled
            ? CookingTools(timerManager: timerManager)
            : nil

        let response = try await llmService.generateChatCompletion(
            messages: messages,
            tools: cookingTools,
            modelId: llmService.currentProvider == .local ? LLMService.supportedOnDeviceModel?.modelId : nil
        )

        conversationHistory.append(ChatMessage(role: .user, content: userMessage))
        conversationHistory.append(ChatMessage(role: .assistant, content: response))

        if conversationHistory.count > maxHistoryLength {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryLength))
        }

        return response
    }

    /// Streaming variant — calls `onChunk` with each text fragment as it arrives.
    func processQueryStreaming(
        userMessage: String,
        recipe: Recipe?,
        conversationContext: [Message],
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        let systemMessage = buildSystemMessage(recipe: recipe)
        let userChatMessage = ChatMessage(role: .user, content: userMessage)

        var messages: [ChatMessage] = [systemMessage] + conversationHistory + [userChatMessage]

        if messages.count > maxHistoryLength {
            messages = [systemMessage] + Array(messages.suffix(maxHistoryLength - 1))
        }

        let cookingTools: CookingTools? = llmService.capability.toolCallingEnabled
            ? CookingTools(timerManager: timerManager)
            : nil

        let response = try await llmService.generateChatCompletionStreaming(
            messages: messages,
            tools: cookingTools,
            modelId: llmService.currentProvider == .local ? LLMService.supportedOnDeviceModel?.modelId : nil,
            onChunk: onChunk
        )

        conversationHistory.append(ChatMessage(role: .user, content: userMessage))
        conversationHistory.append(ChatMessage(role: .assistant, content: response))

        if conversationHistory.count > maxHistoryLength {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryLength))
        }

        return response
    }

    func clearHistory() {
        conversationHistory.removeAll()
    }

    func reset() {
        conversationHistory.removeAll()
        isProcessing = false
    }

    // MARK: - Private Methods

    private func buildSystemMessage(recipe: Recipe?) -> ChatMessage {
        var prompt = "You are LittleChef, a concise and helpful cooking assistant. Answer cooking questions directly. Be brief."

        if let recipe = recipe {
            prompt += "\n\nRecipe: \(recipe.title)"
            if let desc = recipe.description { prompt += "\n\(desc)" }
            prompt += "\nServings: \(recipe.servings)"
            if let prep = recipe.prepTime { prompt += " | Prep: \(prep)min" }
            if let cook = recipe.cookTime { prompt += " | Cook: \(cook)min" }

            prompt += "\n\nIngredients: \(recipe.ingredients.joined(separator: ", "))"

            prompt += "\n\nSteps:"
            for (i, step) in recipe.instructions.enumerated() {
                prompt += "\n\(i + 1). \(step)"
            }
        }

        let activeTimers = timerManager.getAllTimers()
        if !activeTimers.isEmpty {
            prompt += "\n\nActive timers:"
            for timer in activeTimers {
                prompt += "\n- \(timer.name): \(timer.status.rawValue), \(timer.remainingMinutes)min left"
            }
        }

        return ChatMessage(role: .system, content: prompt)
    }
}

// MARK: - ConversationMessage Protocol

protocol ConversationMessage {
    var content: String { get }
    var isUser: Bool { get }
}
