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

    init(llmService: MLXLLMService = .cookingService, timerManager: TimerManager) {
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

        // Create cooking tools (timer tools only)
        let cookingTools = CookingTools(timerManager: timerManager)

        // Generate response - LLM will decide which tools to use
        let response = try await llmService.generateChatCompletion(
            messages: messages,
            cookingTools: cookingTools
        )

        // Tool calls are now handled automatically within generateChatCompletion
        // Just add to history and return response
        conversationHistory.append(ChatMessage(role: .user, content: userMessage))
        conversationHistory.append(ChatMessage(role: .assistant, content: response))

        // Trim history if needed
        if conversationHistory.count > maxHistoryLength {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryLength))
        }

        return response
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
        You are LittleChef, a friendly and helpful AI cooking assistant.

        IMPORTANT: You have timer management tools available. Use them ONLY when the user explicitly asks to:
        - Set/create a timer: "set a timer for 10 minutes", "create a timer for the marinade"
        - Start a timer: "start the timer", "start the pasta timer"
        - Stop a timer: "stop the timer", "pause the chicken timer"
        - Remove a timer: "delete the timer", "remove the pasta timer"

        For ALL other requests (cooking questions, recipe advice, techniques, measurements, etc.):
        - Answer directly and conversationally
        - Do NOT use tools
        - Examples: "how much salt?", "what temperature?", "how long to cook?", "can I substitute?"

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
