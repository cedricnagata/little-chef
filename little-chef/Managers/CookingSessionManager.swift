//
//  CookingSessionManager.swift
//  little-chef
//
//  Updated to use local LLM (LLMService) and LocalCookingAgent
//

import Foundation
import SwiftUI

@MainActor
class CookingSessionManager: ObservableObject, TimerManager {
    @Published var currentSession: CookingSession?
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastResponse: String = ""
    @Published var localTimers: [LocalTimer] = []

    /// The provider this session answers on, captured when it started.
    ///
    /// Settings are already unreachable mid-session — `MainView` swaps the whole tab bar out
    /// for the cooking view — so this cannot drift in practice. Pinning it makes that
    /// structural guarantee an enforced one rather than a coincidence of navigation: a session
    /// that began on-device keeps its on-device agent, its on-device voice loop, and its
    /// on-device capabilities for its whole life, whatever else changes the app-wide provider.
    /// Switching backends mid-session would otherwise swap the inference and the speech stack
    /// out from under a running hands-free loop.
    @Published private(set) var sessionProvider: LLMProvider = .local

    /// What the pinned provider can do — the capability the cooking UI should gate on.
    var capability: AICapability { llmService.capability(of: sessionProvider) }

    private let dataManager = LocalDataManager.shared
    private var cookingAgent: LocalCookingAgent?
    private let llmService: LLMService

    convenience init() {
        self.init(llmService: .shared)
    }

    init(llmService: LLMService) {
        self.llmService = llmService
    }

    // MARK: - Session Management

    func startCookingSession(with recipe: Recipe) async {
        let preferences = await loadLocalPreferences()
        let recipeBase = RecipeBase(from: recipe)

        currentSession = CookingSession(recipe: recipeBase, userPreferences: preferences)
        // Read once, here. Everything downstream — the agent, the voice loop, the capability
        // gate — asks this session rather than the service, so the backend is fixed for the
        // duration of the cook.
        sessionProvider = llmService.currentProvider

        error = nil
        dprint("🔵 Started new cooking session on \(sessionProvider.rawValue) (model will load on page)")
    }

    func initAgentForSession() {
        cookingAgent = LocalCookingAgent(timerManager: self, provider: sessionProvider)
        error = nil
    }

    private func loadLocalPreferences() async -> UserPreferencesDetailed {
        do {
            let prefsEntity = try dataManager.fetchPreferences()
            let localPrefs = prefsEntity.toUserPreferences()

                return UserPreferencesDetailed(from: localPrefs)
        } catch {
            dprint("⚠️ Failed to load preferences, using defaults: \(error)")
            return UserPreferencesDetailed()
        }
    }

    func endCookingSession() {
        currentSession = nil
        lastResponse = ""
        error = nil
        cookingAgent = nil
        clearAllTimers()

        dprint("🔴 Ended cooking session and reset state")
    }

    private func clearAllTimers() {
        TimerNotificationManager.shared.cancelAllNotifications()
        localTimers.forEach { $0.stopLiveActivity() }
        localTimers.removeAll()
        dprint("🗑️ Cleared all timers")
    }

    // MARK: - Agent Communication

    func sendQuery(_ query: String) async {
        guard currentSession != nil else {
            error = "No active cooking session"
            return
        }

        guard let agent = cookingAgent else {
            error = "Cooking agent not initialized"
            return
        }

        error = nil
        currentSession?.conversationHistory.append(
            Message(id: UUID(), role: "user", content: query, timestamp: Date())
        )

        isLoading = true

        do {
            let recipe = createRecipeFromSession(currentSession!)
            let conversationContext = currentSession!.conversationHistory

            let response = try await agent.processQuery(
                userMessage: query,
                recipe: recipe,
                conversationContext: conversationContext
            )

            currentSession?.conversationHistory.append(
                Message(id: UUID(), role: "assistant", content: response, timestamp: Date())
            )
            lastResponse = response

        } catch {
            self.error = "Failed to get response: \(error.localizedDescription)"
            dprint("Agent query error: \(error)")
        }

        isLoading = false
    }

    /// Streaming query — updates the assistant message progressively as chunks arrive.
    /// Calls `onSentence` each time a complete sentence is ready (for TTS).
    func sendQueryStreaming(_ query: String, onSentence: ((String) -> Void)? = nil) async {
        guard currentSession != nil else {
            error = "No active cooking session"
            return
        }

        guard let agent = cookingAgent else {
            error = "Cooking agent not initialized"
            return
        }

        error = nil
        isLoading = true

        currentSession?.conversationHistory.append(
            Message(id: UUID(), role: "user", content: query, timestamp: Date())
        )

        let assistantMessageId = UUID()
        currentSession?.conversationHistory.append(
            Message(id: assistantMessageId, role: "assistant", content: "", timestamp: Date())
        )

        var sentenceBuffer = ""

        do {
            let recipe = createRecipeFromSession(currentSession!)
            let conversationContext = currentSession!.conversationHistory

            let response = try await agent.processQueryStreaming(
                userMessage: query,
                recipe: recipe,
                conversationContext: conversationContext
            ) { [weak self] chunk in
                guard let self else { return }

                if let index = self.currentSession?.conversationHistory.firstIndex(where: { $0.id == assistantMessageId }) {
                    let current = self.currentSession?.conversationHistory[index].content ?? ""
                    self.currentSession?.conversationHistory[index] = Message(
                        id: assistantMessageId,
                        role: "assistant",
                        content: current + chunk,
                        timestamp: Date()
                    )
                }

                if let onSentence {
                    sentenceBuffer += chunk
                    // Extract complete sentences (ending with . ! or ?)
                    // Split on sentence boundaries for streaming TTS
                    while let range = sentenceBuffer.range(of: "[.!?]\\s+|[.!?]$", options: .regularExpression) {
                        let sentence = String(sentenceBuffer[sentenceBuffer.startIndex...range.lowerBound])
                        onSentence(sentence)
                        sentenceBuffer = String(sentenceBuffer[range.upperBound...])
                    }
                }
            }

            // Flush any remaining text as a final sentence
            let remainingSentence = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingSentence.isEmpty {
                onSentence?(remainingSentence)
            }

            // Update the final message content (cleaned by the agent)
            if let index = currentSession?.conversationHistory.firstIndex(where: { $0.id == assistantMessageId }) {
                currentSession?.conversationHistory[index] = Message(
                    id: assistantMessageId,
                    role: "assistant",
                    content: response,
                    timestamp: Date()
                )
            }

            lastResponse = response

        } catch {
            self.error = "Failed to get response: \(error.localizedDescription)"
            dprint("Agent query error: \(error)")

            // Remove the empty placeholder on error
            if let index = currentSession?.conversationHistory.firstIndex(where: { $0.id == assistantMessageId }) {
                currentSession?.conversationHistory.remove(at: index)
            }
        }

        isLoading = false
    }

    // MARK: - Hands-free support

    /// Everything a hands-free loop needs to answer as this cooking session would.
    ///
    /// Built here rather than in the view so the spoken assistant and the typed one are briefed
    /// from the same place — same system prompt, same timer tools, same conversation — instead
    /// of drifting into two assistants that happen to share a screen.
    func voiceContext() -> VoiceSessionContext? {
        guard let session = currentSession, let agent = cookingAgent else { return nil }
        let recipe = createRecipeFromSession(session)
        return VoiceSessionContext(
            systemPrompt: agent.systemPrompt(for: recipe),
            tools: agent.cookingTools(),
            priorTurns: session.conversationHistory.map { ($0.role, $0.content) },
            answer: { [weak self] question, onSentence in
                guard let self else { return "" }
                await self.sendQueryStreaming(question, onSentence: onSentence)
                return self.lastResponse
            },
            beginTurn: { [weak self] question in
                self?.beginSpokenTurn(question: question) ?? UUID()
            },
            updateReply: { [weak self] id, text in
                self?.updateSpokenReply(id: id, text: text)
            }
        )
    }

    /// Records a spoken question and the empty answer that will stream into it.
    ///
    /// Only the Mac path needs this: `BigBroVoiceSession` runs its own conversation against the
    /// Mac, so its turns have to be mirrored in rather than arriving through `sendQueryStreaming`.
    func beginSpokenTurn(question: String) -> UUID {
        currentSession?.conversationHistory.append(
            Message(id: UUID(), role: "user", content: question, timestamp: Date())
        )
        let replyID = UUID()
        currentSession?.conversationHistory.append(
            Message(id: replyID, role: "assistant", content: "", timestamp: Date())
        )
        return replyID
    }

    /// Updates a spoken answer by identity.
    ///
    /// By id, not index: the history changes underneath a streaming reply — a new turn, a
    /// cleared session — and an index captured when the turn started would land the text on the
    /// wrong message or on none at all.
    func updateSpokenReply(id: UUID, text: String) {
        guard let index = currentSession?.conversationHistory.firstIndex(where: { $0.id == id }) else { return }
        currentSession?.conversationHistory[index] = Message(
            id: id, role: "assistant", content: text, timestamp: Date()
        )
        lastResponse = text
    }

    private func createRecipeFromSession(_ session: CookingSession) -> Recipe {
        return Recipe(
            id: UUID(), // Temporary ID for agent context
            title: session.recipe.title,
            description: session.recipe.description,
            servings: session.recipe.servings,
            prepTime: session.recipe.prepTime,
            cookTime: session.recipe.cookTime,
            ingredients: session.recipe.ingredients,
            instructions: session.recipe.instructions,
            tags: session.recipe.tags,
            sourceUrl: session.recipe.sourceUrl,
            cuisineType: session.recipe.cuisineType,
            difficulty: session.recipe.difficulty,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - Voice Interaction Helpers

    func getLastMessage() -> String {
        guard let session = currentSession,
              let lastMessage = session.conversationHistory.last else {
            return ""
        }
        return lastMessage.content
    }

    func hasActiveSession() -> Bool {
        return currentSession != nil
    }

    func getRecipeTitle() -> String {
        return currentSession?.recipe.title ?? ""
    }

    func getConversationHistory() -> [Message] {
        return currentSession?.conversationHistory ?? []
    }

    // MARK: - Recipe Servings Management

    func updateServings(newServings: Int) {
        guard let session = currentSession else { return }

        let originalServings = session.recipe.servings
        let multiplier = Float(newServings) / Float(originalServings)

        // Create a new RecipeBase with scaled ingredients and updated servings
        let scaledRecipe = createScaledRecipe(from: session.recipe, servings: newServings)

        // Create new session with the scaled recipe
        currentSession = CookingSession(
            recipe: scaledRecipe,
            conversationHistory: session.conversationHistory,
            userPreferences: session.userPreferences,
            startedAt: session.startedAt
        )

        dprint("🔄 Updated servings from \(originalServings) to \(newServings) (multiplier: \(multiplier))")
    }

    func getCurrentServings() -> Int {
        return currentSession?.recipe.servings ?? 0
    }

    private func createScaledRecipe(from recipe: RecipeBase, servings: Int) -> RecipeBase {
        let originalServings = recipe.servings
        let multiplier = Float(servings) / Float(originalServings)

        if multiplier == 1.0 {
            return recipe
        }

        // Scale ingredients
        let scaledIngredients = recipe.ingredients.map { ingredient in
            scaleIngredient(ingredient, multiplier: multiplier)
        }

        // Create new RecipeBase with scaled data
        return RecipeBase(
            title: recipe.title,
            description: recipe.description,
            servings: servings,
            prepTime: recipe.prepTime,
            cookTime: recipe.cookTime,
            ingredients: scaledIngredients,
            instructions: recipe.instructions,
            tags: recipe.tags,
            sourceUrl: recipe.sourceUrl,
            cuisineType: recipe.cuisineType,
            difficulty: recipe.difficulty
        )
    }

    private static let ingredientRegexes: [NSRegularExpression] = [
        (try? NSRegularExpression(pattern: "([0-9]+\\.?[0-9]*\\/[0-9]+)\\s+(\\w+)", options: []))!,
        (try? NSRegularExpression(pattern: "([0-9]+\\.?[0-9]*)\\s+(\\w+)", options: []))!
    ]

    private func scaleIngredient(_ ingredient: String, multiplier: Float) -> String {
        if multiplier == 1.0 {
            return ingredient
        }

        for regex in Self.ingredientRegexes {
            if let match = regex.firstMatch(in: ingredient, options: [], range: NSRange(location: 0, length: ingredient.count)) {

                let amountRange = Range(match.range(at: 1), in: ingredient)!
                let amountStr = String(ingredient[amountRange])

                var amount: Float

                // Handle fractions like "1/2"
                if amountStr.contains("/") {
                    let parts = amountStr.split(separator: "/")
                    if parts.count == 2,
                       let numerator = Float(parts[0]),
                       let denominator = Float(parts[1]),
                       denominator != 0 {
                        amount = numerator / denominator
                    } else {
                        continue
                    }
                } else {
                    guard let parsed = Float(amountStr) else { continue }
                    amount = parsed
                }

                // Scale the amount
                let scaledAmount = amount * multiplier

                // Format the scaled amount nicely
                let scaledStr: String
                if scaledAmount == Float(Int(scaledAmount)) {
                    scaledStr = "\(Int(scaledAmount))"
                } else {
                    scaledStr = String(format: "%.2f", scaledAmount).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
                }

                // Replace in the original string
                return ingredient.replacingOccurrences(of: amountStr, with: scaledStr)
            }
        }

        // If no number pattern found, return original ingredient with note
        if multiplier != 1.0 {
            return "\(ingredient) (scale by \(String(format: "%.1f", multiplier))x)"
        }
        return ingredient
    }

    // MARK: - TimerManager Protocol Implementation

    func setTimer(name: String, durationSeconds: Int) {
        if findTimer(named: name) != nil {
            dprint("Timer '\(name)' already exists, not creating duplicate")
            return
        }
        let timerId = UUID().uuidString
        let timer = LocalTimer(
            id: timerId,
            label: name,
            durationSeconds: durationSeconds,
            remainingSeconds: durationSeconds,
            status: .new,
            createdAt: Date()
        )
        localTimers.append(timer)
        dprint("Set timer: \(name) (\(durationSeconds)s)")
        timer.start()
    }

    func startTimer(name: String) {
        if let index = findTimerIndex(named: name) {
            localTimers[index].start()
        } else {
            dprint("Timer '\(name)' not found")
        }
    }

    func pauseTimer(name: String) {
        if let index = findTimerIndex(named: name) {
            localTimers[index].pause()
        } else {
            dprint("Timer '\(name)' not found")
        }
    }

    func deleteTimer(name: String) {
        if let index = findTimerIndex(named: name) {
            localTimers[index].stopLiveActivity()
            localTimers.remove(at: index)
        } else {
            // Fallback: if only one timer exists, delete it
            if localTimers.count == 1 {
                localTimers[0].stopLiveActivity()
                localTimers.removeAll()
            }
        }
    }

    func getTimer(name: String) -> LocalTimer? {
        return findTimer(named: name)
    }

    /// Fuzzy match a timer by name — handles the model using slightly different names
    private func findTimer(named name: String) -> LocalTimer? {
        let query = name.lowercased()
        dprint("=== FIND TIMER: query='\(query)', existing timers: \(localTimers.map { "'\($0.label)'" }) ===")
        // Exact match first
        if let timer = localTimers.first(where: { $0.label.lowercased() == query }) {
            return timer
        }
        // Contains match
        if let timer = localTimers.first(where: {
            $0.label.lowercased().contains(query) || query.contains($0.label.lowercased())
        }) {
            return timer
        }
        // If only one timer, assume they mean that one
        if localTimers.count == 1 {
            return localTimers.first
        }
        return nil
    }

    private func findTimerIndex(named name: String) -> Int? {
        guard let timer = findTimer(named: name) else { return nil }
        return localTimers.firstIndex(where: { $0.id == timer.id })
    }

    func getAllTimers() -> [LocalTimer] {
        return localTimers
    }

    // MARK: - Manual Timer Management (for UI)

    func addManualTimer(label: String, durationSeconds: Int) {
        if findTimer(named: label) != nil {
            dprint("Timer '\(label)' already exists, not creating duplicate")
            return
        }
        let timerId = UUID().uuidString
        let timer = LocalTimer(
            id: timerId, label: label, durationSeconds: durationSeconds,
            remainingSeconds: durationSeconds, status: .new, createdAt: Date())
        localTimers.append(timer)
        timer.start()
    }

    func deleteManualTimer(id: String) {
        if let timerIndex = localTimers.firstIndex(where: { $0.id == id }) {
            let timer = localTimers[timerIndex]
            timer.stopLiveActivity()
            localTimers.remove(at: timerIndex)
            dprint("🗑️ Manually deleted timer: \(timer.label)")
        }
    }
}

// MARK: - Message conforms to ConversationMessage protocol

extension Message: ConversationMessage {
    var isUser: Bool {
        return role == "user"
    }
}
