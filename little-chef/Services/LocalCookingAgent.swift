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
    /// The provider this agent was built for, pinned by the cooking session that owns it.
    /// Passed to every request so a mid-flight change to the app-wide provider can't reroute
    /// one turn of a conversation to a different backend than the rest.
    let provider: LLMProvider

    // MARK: - State
    @Published var isProcessing = false
    private var conversationHistory: [ChatMessage] = []
    private let maxHistoryLength = 20

    // MARK: - Initialization

    convenience init(timerManager: TimerManager, provider: LLMProvider) {
        self.init(llmService: .shared, timerManager: timerManager, provider: provider)
    }

    init(llmService: LLMService, timerManager: TimerManager, provider: LLMProvider) {
        self.llmService = llmService
        self.timerManager = timerManager
        self.provider = provider
    }

    // MARK: - Voice support

    /// The cooking system prompt for `recipe`, as plain text.
    ///
    /// `BigBroVoiceSession` runs its own conversation against the Mac rather than going through
    /// this agent, and takes a system prompt as a string. Exposed so the spoken assistant is
    /// briefed identically to the typed one instead of carrying a second copy of the prompt.
    func systemPrompt(for recipe: Recipe?) -> String {
        buildSystemMessage(recipe: recipe).content
    }

    /// The timer tools this agent would offer, or none if the pinned provider can't call them.
    func cookingTools() -> CookingTools? {
        llmService.capability(of: provider).toolCallingEnabled
            ? CookingTools(timerManager: timerManager)
            : nil
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

        let response = try await llmService.generateChatCompletion(
            messages: messages,
            tools: cookingTools(),
            modelId: provider == .local ? LLMService.supportedOnDeviceModel?.modelId : nil,
            provider: provider
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

        let response = try await llmService.generateChatCompletionStreaming(
            messages: messages,
            tools: cookingTools(),
            modelId: provider == .local ? LLMService.supportedOnDeviceModel?.modelId : nil,
            provider: provider,
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

        // Everything here is read aloud by a speech model that pronounces abbreviations as
        // letters — "tsp" comes out "tee ess pee" — so they have to be spelled out in the text
        // before they ever reach it.
        prompt += """


            Your replies are spoken out loud. Never abbreviate; write every word out in full so \
            it can be read aloud:
            - teaspoon / tablespoon, not tsp / tbsp
            - cup, ounce, pound, gram, kilogram, millilitre, litre, not c / oz / lb / g / kg / ml / l
            - minutes, hours, seconds, not min / hr / sec
            - degrees Fahrenheit or degrees Celsius, not F / C / °F / °C
            - approximately, about, for example, and so on, not approx / ca. / e.g. / etc.
            Write numbers as digits ("350 degrees Fahrenheit", "2 tablespoons"), and fractions as \
            words ("one and a half cups", not "1 1/2 cups"). Use no markdown, symbols or emoji.
            """

        if cookingTools() != nil {
            // Creating and starting are two separate messages, not two calls in one turn — a
            // timer that starts the moment it is named leaves no room to correct the duration.
            prompt += """


                Timers: creating a timer and starting it are separate actions in separate replies. \
                When asked to set a timer, call create_timer only, then tell the user it is ready \
                and wait. Start it with start_timer only when they ask in a later message. Never \
                call create_timer and start_timer in the same reply. Use update_timer to change a \
                timer's duration or name, stop_timer to stop one, delete_timer to remove one.
                """
        }

        if let recipe = recipe {
            prompt += "\n\nRecipe: \(recipe.title)"
            if let desc = recipe.description { prompt += "\n\(desc)" }
            prompt += "\nServings: \(recipe.servings)"
            if let prep = recipe.prepTime { prompt += " | Prep: \(prep) minutes" }
            if let cook = recipe.cookTime { prompt += " | Cook: \(cook) minutes" }

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
                let state = timer.status == .new ? "created, not started yet" : timer.status.rawValue
                prompt += "\n- \(timer.name): \(state), \(timer.remainingMinutes) minutes left"
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
