//
//  LocalCookingAgent.swift
//  little-chef
//
//  Local cooking agent that orchestrates LLM + tool calling
//  Replaces the backend LangGraph agent
//

import Foundation

/// Local agent for handling cooking assistant interactions
@MainActor
class LocalCookingAgent: ObservableObject {
    // MARK: - Dependencies
    private let llmService: MLXLLMService
    private let timerManager: TimerManager

    // MARK: - State
    @Published var isProcessing = false
    private var conversationHistory: [ChatMessage] = []

    // Maximum conversation history to maintain
    private let maxHistoryLength = 20

    // MARK: - Initialization

    init(llmService: MLXLLMService = .shared, timerManager: TimerManager) {
        self.llmService = llmService
        self.timerManager = timerManager
    }

    // MARK: - Public Methods

    /// Process a user query and return the assistant's response
    func processQuery(
        userMessage: String,
        recipe: Recipe?,
        conversationContext: [Message]
    ) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        // Build system message with context
        let systemMessage = buildSystemMessage(recipe: recipe, conversationContext: conversationContext)

        // Add user message
        let userChatMessage = ChatMessage(role: .user, content: userMessage)

        // Build messages array
        var messages: [ChatMessage] = [systemMessage] + conversationHistory + [userChatMessage]

        // Limit conversation history
        if messages.count > maxHistoryLength {
            messages = [systemMessage] + Array(messages.suffix(maxHistoryLength - 1))
        }

        // Generate response with tools
        let response = try await llmService.generateChatCompletion(
            messages: messages,
            tools: ToolDefinition.allTools
        )

        // Check if response contains a tool call
        if let toolCall = response.parseToolCall() {
            // Execute the tool
            let toolResult = ToolExecutor.execute(toolCall, timerManager: timerManager)

            // Add tool execution to history
            conversationHistory.append(ChatMessage(role: .user, content: userMessage))
            conversationHistory.append(ChatMessage(role: .assistant, content: response))

            // Generate follow-up response acknowledging tool execution
            let toolResultMessage = ChatMessage(
                role: .user,
                content: "Tool execution result: \(toolResult.message)"
            )

            let followUpMessages = [systemMessage] + conversationHistory + [toolResultMessage]

            let followUpResponse = try await llmService.generateChatCompletion(
                messages: followUpMessages,
                tools: nil // No tools for follow-up to avoid loops
            )

            // Update history
            conversationHistory.append(ChatMessage(role: .assistant, content: followUpResponse))

            // Trim history if needed
            if conversationHistory.count > maxHistoryLength {
                conversationHistory = Array(conversationHistory.suffix(maxHistoryLength))
            }

            return followUpResponse

        } else {
            // No tool call, just add to history and return response
            conversationHistory.append(ChatMessage(role: .user, content: userMessage))
            conversationHistory.append(ChatMessage(role: .assistant, content: response))

            // Trim history if needed
            if conversationHistory.count > maxHistoryLength {
                conversationHistory = Array(conversationHistory.suffix(maxHistoryLength))
            }

            return response
        }
    }

    /// Process query with streaming response
    func processQueryStreaming(
        userMessage: String,
        recipe: Recipe?,
        conversationContext: [Message],
        onToken: @escaping (String) -> Void
    ) async throws {
        isProcessing = true
        defer { isProcessing = false }

        // Build system message with context
        let systemMessage = buildSystemMessage(recipe: recipe, conversationContext: conversationContext)

        // Add user message
        let userChatMessage = ChatMessage(role: .user, content: userMessage)

        // Build messages array
        var messages: [ChatMessage] = [systemMessage] + conversationHistory + [userChatMessage]

        // Limit conversation history
        if messages.count > maxHistoryLength {
            messages = [systemMessage] + Array(messages.suffix(maxHistoryLength - 1))
        }

        // Accumulate response for tool call detection
        var fullResponse = ""

        // Stream response
        try await llmService.streamChatCompletion(
            messages: messages,
            tools: ToolDefinition.allTools
        ) { token in
            fullResponse += token
            onToken(token)
        }

        // Check if response contains a tool call
        if let toolCall = fullResponse.parseToolCall() {
            // Execute the tool
            let toolResult = ToolExecutor.execute(toolCall, timerManager: timerManager)

            // Notify about tool execution
            onToken("\n\n[\(toolResult.message)]")

            // Update history
            conversationHistory.append(ChatMessage(role: .user, content: userMessage))
            conversationHistory.append(ChatMessage(role: .assistant, content: fullResponse))

            // Trim history if needed
            if conversationHistory.count > maxHistoryLength {
                conversationHistory = Array(conversationHistory.suffix(maxHistoryLength))
            }

        } else {
            // No tool call, just update history
            conversationHistory.append(ChatMessage(role: .user, content: userMessage))
            conversationHistory.append(ChatMessage(role: .assistant, content: fullResponse))

            // Trim history if needed
            if conversationHistory.count > maxHistoryLength {
                conversationHistory = Array(conversationHistory.suffix(maxHistoryLength))
            }
        }
    }

    /// Clear conversation history
    func clearHistory() {
        conversationHistory.removeAll()
    }

    /// Reset the agent state
    func reset() {
        conversationHistory.removeAll()
        isProcessing = false
    }

    // MARK: - Private Methods

    private func buildSystemMessage(recipe: Recipe?, conversationContext: [Message]) -> ChatMessage {
        var systemPrompt = """
        You are LittleChef, a friendly and helpful AI cooking assistant. You help users cook recipes by:
        - Answering questions about recipes, ingredients, and cooking techniques
        - Managing cooking timers
        - Providing step-by-step guidance
        - Offering substitution suggestions
        - Scaling recipe quantities

        You have access to timer management tools. When users ask about timers, use the appropriate tool.

        Be concise, friendly, and practical. Focus on helping the user cook successfully.
        """

        // Add recipe context if available
        if let recipe = recipe {
            systemPrompt += "\n\nCurrent Recipe: \(recipe.title)"

            if let description = recipe.description {
                systemPrompt += "\nDescription: \(description)"
            }

            systemPrompt += "\nServings: \(recipe.servings)"

            if let prepTime = recipe.prepTime {
                systemPrompt += "\nPrep Time: \(prepTime) minutes"
            }

            if let cookTime = recipe.cookTime {
                systemPrompt += "\nCook Time: \(cookTime) minutes"
            }

            systemPrompt += "\n\nIngredients:"
            for (index, ingredient) in recipe.ingredients.enumerated() {
                systemPrompt += "\n\(index + 1). \(ingredient)"
            }

            systemPrompt += "\n\nInstructions:"
            for (index, instruction) in recipe.instructions.enumerated() {
                systemPrompt += "\n\(index + 1). \(instruction)"
            }
        }

        // Add active timers context
        let activeTimers = getActiveTimers()
        if !activeTimers.isEmpty {
            systemPrompt += "\n\nActive Timers:"
            for timer in activeTimers {
                let status = timer.isRunning ? "Running" : "Stopped"
                systemPrompt += "\n- \(timer.name): \(status), \(timer.remainingMinutes) min remaining"
            }
        }

        // Add recent conversation context
        if !conversationContext.isEmpty {
            systemPrompt += "\n\nRecent conversation:"
            for message in conversationContext.suffix(5) {
                let role = message.isUser ? "User" : "Assistant"
                systemPrompt += "\n\(role): \(message.content)"
            }
        }

        return ChatMessage(role: .system, content: systemPrompt)
    }

    private func getActiveTimers() -> [LocalTimer] {
        // This would need to be implemented by the TimerManager
        // For now, return empty array
        return []
    }
}

// MARK: - ConversationMessage Protocol

/// Protocol for conversation messages
protocol ConversationMessage {
    var content: String { get }
    var isUser: Bool { get }
}
