//
//  CookingSessionManager.swift
//  little-chef
//
//  Updated to use local LLM (MLXLLMService) and LocalCookingAgent
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

    private var dataManager: LocalDataManager
    private var cookingAgent: LocalCookingAgent?
    private let cookingService: MLXLLMService

    init(cookingService: MLXLLMService = .cookingService) {
        self.cookingService = cookingService
        do {
            dataManager = try LocalDataManager()
        } catch {
            fatalError("Failed to initialize LocalDataManager: \(error)")
        }
    }

    // MARK: - Session Management

    func startCookingSession(with recipe: Recipe) async {
        // Load user preferences from local storage
        let preferences = await loadLocalPreferences()
        let recipeBase = RecipeBase(from: recipe)

        // Create session immediately (navigation will happen)
        currentSession = CookingSession(recipe: recipeBase, userPreferences: preferences)

        error = nil
        print("🔵 Started new cooking session locally (model will load on page)")
    }

    func loadModelForSession() async {
        do {
            // Load cooking model into memory after navigating to session page
            print("🔵 Loading cooking model for session...")
            _ = try await cookingService.loadLocalModel()
            print("✅ Cooking model loaded")

            // Initialize cooking agent with timer manager (uses Qwen model by default)
            cookingAgent = LocalCookingAgent(timerManager: self)

            error = nil
        } catch {
            self.error = "Failed to load cooking model: \(error.localizedDescription)"
            print("❌ Failed to load cooking model: \(error)")
        }
    }

    private func loadLocalPreferences() async -> UserPreferencesDetailed {
        do {
            let prefsEntity = try dataManager.fetchPreferences()
            let localPrefs = prefsEntity.toUserPreferences()

            // Convert to UserPreferencesDetailed
            return UserPreferencesDetailed(from: localPrefs)
        } catch {
            print("⚠️ Failed to load preferences, using defaults: \(error)")
            return UserPreferencesDetailed()
        }
    }

    func endCookingSession() {
        // Clear session data
        currentSession = nil
        lastResponse = ""
        error = nil
        cookingAgent = nil

        // Clear all timers
        clearAllTimers()

        // Unload cooking model from memory when ending session
        cookingService.unloadModel()

        print("🔴 Ended cooking session, unloaded model, and reset state")
    }

    private func clearAllTimers() {
        localTimers.removeAll()
        print("🗑️ Cleared all timers")
    }

    // MARK: - Agent Communication

    func sendQuery(_ query: String) async {
        guard let session = currentSession else {
            error = "No active cooking session"
            return
        }

        guard let agent = cookingAgent else {
            error = "Cooking agent not initialized"
            return
        }

        // Clear any previous errors
        error = nil
        isLoading = true

        do {
            // Convert session to Recipe for agent
            let recipe = createRecipeFromSession(session)

            // Convert conversation history
            let conversationContext = session.conversationHistory

            // Process query with agent
            let response = try await agent.processQuery(
                userMessage: query,
                recipe: recipe,
                conversationContext: conversationContext
            )

            // Add to conversation history
            var updatedSession = session
            updatedSession.conversationHistory.append(
                Message(
                    id: UUID(),
                    role: "user",
                    content: query,
                    timestamp: Date()
                )
            )
            updatedSession.conversationHistory.append(
                Message(
                    id: UUID(),
                    role: "assistant",
                    content: response,
                    timestamp: Date()
                )
            )

            currentSession = updatedSession
            lastResponse = response

        } catch {
            self.error = "Failed to get response: \(error.localizedDescription)"
            print("Agent query error: \(error)")
        }

        isLoading = false
    }

    /// Stream response for real-time feedback
    func sendQueryStreaming(_ query: String, onToken: @escaping (String) -> Void) async {
        guard let session = currentSession else {
            error = "No active cooking session"
            return
        }

        guard let agent = cookingAgent else {
            error = "Cooking agent not initialized"
            return
        }

        // Clear any previous errors
        error = nil
        isLoading = true

        // Add user message to history
        var updatedSession = session
        updatedSession.conversationHistory.append(
            Message(
                id: UUID(),
                role: "user",
                content: query,
                timestamp: Date()
            )
        )

        do {
            // Convert session to Recipe for agent
            let recipe = createRecipeFromSession(session)

            // Convert conversation history
            let conversationContext = session.conversationHistory

            // Process query (no streaming - get full response)
            let fullResponse = try await agent.processQuery(
                userMessage: query,
                recipe: recipe,
                conversationContext: conversationContext
            )

            // Send full response via onToken callback
            onToken(fullResponse)

            // Add assistant response to history
            updatedSession.conversationHistory.append(
                Message(
                    id: UUID(),
                    role: "assistant",
                    content: fullResponse,
                    timestamp: Date()
                )
            )

            currentSession = updatedSession
            lastResponse = fullResponse

        } catch {
            self.error = "Failed to get response: \(error.localizedDescription)"
            print("Agent query error: \(error)")
        }

        isLoading = false
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
            commands: session.commands,
            timerStatus: session.timerStatus,
            conversationHistory: session.conversationHistory,
            userPreferences: session.userPreferences,
            startedAt: session.startedAt
        )

        print("🔄 Updated servings from \(originalServings) to \(newServings) (multiplier: \(multiplier))")
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

    private func scaleIngredient(_ ingredient: String, multiplier: Float) -> String {
        if multiplier == 1.0 {
            return ingredient
        }

        // Common patterns for numbers in ingredients
        let patterns = [
            "([0-9]+\\.?[0-9]*\\/[0-9]+)\\s+(\\w+)",  // "1/2 teaspoon"
            "([0-9]+\\.?[0-9]*)\\s+(\\w+)"           // "2 cups", "1.5 pounds"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: ingredient, options: [], range: NSRange(location: 0, length: ingredient.count)) {

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

    func setTimer(name: String, durationMinutes: Int) {
        // Check if timer with this name already exists
        if localTimers.contains(where: { $0.label == name }) {
            print("⚠️ Timer '\(name)' already exists, not creating duplicate")
            return
        }

        let timerId = UUID().uuidString
        let durationSeconds = durationMinutes * 60

        let timer = LocalTimer(
            id: timerId,
            label: name,
            durationSeconds: durationSeconds,
            remainingSeconds: durationSeconds,
            status: .new,
            createdAt: Date()
        )
        localTimers.append(timer)
        print("🕐 Set timer: \(name) (\(durationMinutes)min)")

        // Automatically start the timer - dispatch to next RunLoop cycle
        DispatchQueue.main.async {
            timer.start()
            print("▶️ Timer started automatically")
        }
    }

    func startTimer(name: String) {
        if let index = localTimers.firstIndex(where: { $0.label == name }) {
            // Dispatch to next RunLoop cycle to ensure proper timing
            DispatchQueue.main.async { [weak self] in
                self?.localTimers[index].start()
                print("▶️ Started timer: \(name)")
            }
        } else {
            print("⚠️ Timer '\(name)' not found, cannot start")
        }
    }

    func pauseTimer(name: String) {
        if let index = localTimers.firstIndex(where: { $0.label == name }) {
            localTimers[index].pause()
            print("⏸️ Paused timer: \(name)")
        } else {
            print("⚠️ Timer '\(name)' not found, cannot pause")
        }
    }

    func deleteTimer(name: String) {
        localTimers.removeAll { $0.label == name }
        print("🗑️ Deleted timer: \(name)")
    }

    func getTimer(name: String) -> LocalTimer? {
        return localTimers.first { $0.label == name }
    }

    func getAllTimers() -> [LocalTimer] {
        return localTimers
    }

    // MARK: - Manual Timer Management (for UI)

    func addManualTimer(label: String, durationMinutes: Int) {
        setTimer(name: label, durationMinutes: durationMinutes)
    }

    func deleteManualTimer(id: String) {
        if let timerIndex = localTimers.firstIndex(where: { $0.id == id }) {
            let timer = localTimers[timerIndex]
            localTimers.remove(at: timerIndex)
            print("🗑️ Manually deleted timer: \(timer.label)")
        }
    }
}

// MARK: - Message conforms to ConversationMessage protocol

extension Message: ConversationMessage {
    var isUser: Bool {
        return role == "user"
    }
}
