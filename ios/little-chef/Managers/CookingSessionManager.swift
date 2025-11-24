//
//  CookingSessionManager.swift
//  little-chef
//
//  Updated for serverless architecture with local preferences
//

import Foundation
import SwiftUI

@MainActor
class CookingSessionManager: ObservableObject {
    @Published var currentSession: CookingSession?
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastResponse: String = ""
    @Published var lastAudioData: Data? = nil  // NEW: Store audio from Lambda

    private let apiService = APIService.shared
    private let preferencesManager: PreferencesManager

    init(preferencesManager: PreferencesManager = PreferencesManager()) {
        self.preferencesManager = preferencesManager
    }

    // MARK: - Session Management

    func startCookingSession(with recipe: Recipe) {
        let recipeBase = RecipeBase(from: recipe)

        // Load preferences from local PreferencesManager
        let userPreferences = UserPreferencesDetailed(from: preferencesManager.preferences)

        currentSession = CookingSession(recipe: recipeBase, userPreferences: userPreferences)
        error = nil
        print("🔵 Started new cooking session with model: \(userPreferences.llmModel)")
    }

    func endCookingSession() {
        // Clear session data
        currentSession = nil
        lastResponse = ""
        lastAudioData = nil
        error = nil

        // Clear all timers
        clearAllTimers()

        // Reset processed command IDs for clean slate
        processedCommandIds.removeAll()

        print("🔴 Ended cooking session - all state reset")
    }

    private func clearAllTimers() {
        // Stop and remove all local timers
        for timer in localTimers {
            timer.stop()
        }
        localTimers.removeAll()
        print("🗑️ Cleared all timers")
    }

    // MARK: - Agent Communication

    func sendQuery(_ query: String) async {
        guard var session = currentSession else {
            error = "No active cooking session"
            return
        }

        // Clear any previous errors
        error = nil
        isLoading = true

        do {
            // Update session with current timer status before sending
            let updatedSession = CookingSession(
                recipe: session.recipe,
                commands: session.commands,
                timerStatus: getTimerStatusForBackend(), // Current timer status
                conversationHistory: session.conversationHistory,
                userPreferences: session.userPreferences,
                startedAt: session.startedAt
            )

            let response = try await apiService.sendAgentQuery(
                cookingSession: updatedSession,
                query: query
            )

            // Process any new commands from AI
            processCommands(from: response.updatedSession)

            // Update the session with the response
            currentSession = response.updatedSession
            lastResponse = response.response

            // Handle audio response if present (from ElevenLabs via Lambda)
            if let audioBase64 = response.audio {
                if let audioData = Data(base64Encoded: audioBase64) {
                    lastAudioData = audioData
                    print("🔊 Received audio from Lambda (\(audioData.count) bytes)")
                } else {
                    print("⚠️ Failed to decode audio from Lambda")
                    lastAudioData = nil
                }
            } else {
                lastAudioData = nil
            }

        } catch {
            self.error = "Failed to get response: \(error.localizedDescription)"
            print("Agent query error: \(error)")
        }

        isLoading = false
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
        // Examples: "2 cups flour", "1/2 teaspoon salt", "1.5 pounds chicken"
        let patterns = [
            "([0-9]+\\.?[0-9]*\\/[0-9]+)\\s+(\\w+)",  // "1/2 teaspoon"
            "([0-9]+\\.?[0-9]*)\\s+(\\w+)"           // "2 cups", "1.5 pounds"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: ingredient, options: [], range: NSRange(location: 0, length: ingredient.count)) {

                let amountRange = Range(match.range(at: 1), in: ingredient)!
                let amountStr = String(ingredient[amountRange])

                do {
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
                } catch {
                    continue
                }
            }
        }

        // If no number pattern found, return original ingredient with note
        if multiplier != 1.0 {
            return "\(ingredient) (scale by \(String(format: "%.1f", multiplier))x)"
        }
        return ingredient
    }

    // MARK: - Timer Management

    @Published var localTimers: [LocalTimer] = []

    func processCommands(from session: CookingSession) {
        // Process new commands from AI
        let newCommands = session.commands.filter { command in
            !processedCommandIds.contains(command.id)
        }

        for command in newCommands {
            // Handle timer commands
            if command.commandType == "timer" {
                switch command.action {
                case "add":
                    if let durationSeconds = command.parameters["duration_seconds"]?.value as? Int,
                       let timerId = command.targetId {
                        addLocalTimer(id: timerId, label: command.label, duration: durationSeconds)
                    }
                case "start":
                    if let timerId = command.targetId {
                        startLocalTimer(id: timerId)
                    }
                case "stop":
                    if let timerId = command.targetId {
                        stopLocalTimer(id: timerId)
                    }
                case "pause":
                    if let timerId = command.targetId {
                        pauseLocalTimer(id: timerId)
                    }
                case "resume":
                    if let timerId = command.targetId {
                        resumeLocalTimer(id: timerId)
                    }
                case "remove":
                    if let timerId = command.targetId {
                        removeLocalTimer(id: timerId)
                    }
                default:
                    print("Unknown timer action: \(command.action)")
                }
            }
            // Future: Add handling for other command types here

            processedCommandIds.insert(command.id)
        }
    }

    private var processedCommandIds = Set<String>()

    func getTimerStatusForBackend() -> [TimerStatus] {
        return localTimers.map { timer in
            TimerStatus(
                id: timer.id,
                label: timer.label,
                durationSeconds: timer.durationSeconds,
                status: timer.status,
                remainingSeconds: timer.remainingSeconds,
                createdAt: timer.createdAt,
                startedAt: timer.startedAt,
                completedAt: timer.completedAt
            )
        }
    }

    // MARK: - Local Timer Management

    private func addLocalTimer(id: String, label: String, duration: Int) {
        let timer = LocalTimer(
            id: id,
            label: label,
            durationSeconds: duration,
            remainingSeconds: duration,
            status: .pending,
            createdAt: Date()
        )
        localTimers.append(timer)
        print("🕐 Added timer: \(label) (\(duration)s)")
    }

    private func startLocalTimer(id: String) {
        if let index = localTimers.firstIndex(where: { $0.id == id }) {
            localTimers[index].start()
            print("▶️ Started timer: \(localTimers[index].label)")
        }
    }

    private func stopLocalTimer(id: String) {
        if let index = localTimers.firstIndex(where: { $0.id == id }) {
            localTimers[index].stop()
            print("⏹️ Stopped timer: \(localTimers[index].label)")
        }
    }

    private func pauseLocalTimer(id: String) {
        if let index = localTimers.firstIndex(where: { $0.id == id }) {
            localTimers[index].pause()
            print("⏸️ Paused timer: \(localTimers[index].label)")
        }
    }

    private func resumeLocalTimer(id: String) {
        if let index = localTimers.firstIndex(where: { $0.id == id }) {
            localTimers[index].resume()
            print("▶️ Resumed timer: \(localTimers[index].label)")
        }
    }

    private func removeLocalTimer(id: String) {
        localTimers.removeAll { $0.id == id }
        print("🗑️ Removed timer: \(id)")
    }

    // MARK: - Manual Timer Management (for UI)

    func addManualTimer(label: String, durationMinutes: Int) {
        let timerId = UUID().uuidString
        let durationSeconds = durationMinutes * 60

        addLocalTimer(id: timerId, label: label, duration: durationSeconds)

        // Also add to session state for AI awareness
        if var session = currentSession {
            let command = Command(
                id: UUID().uuidString,
                commandType: "timer",
                action: "add",
                targetId: timerId,
                label: label,
                parameters: ["duration_seconds": FlexibleValue(durationSeconds)],
                createdAt: Date()
            )

            var updatedCommands = session.commands
            updatedCommands.append(command)

            currentSession = CookingSession(
                recipe: session.recipe,
                commands: updatedCommands,
                timerStatus: session.timerStatus,
                conversationHistory: session.conversationHistory,
                userPreferences: session.userPreferences,
                startedAt: session.startedAt
            )
        }
    }

    func deleteManualTimer(id: String) {
        // Remove from local timers
        if let timerIndex = localTimers.firstIndex(where: { $0.id == id }) {
            let timer = localTimers[timerIndex]
            timer.stop() // Stop the timer if running
            localTimers.remove(at: timerIndex)
            print("🗑️ Manually deleted timer: \(timer.label)")
        }

        // Add remove command to session state for AI awareness
        if var session = currentSession {
            let removeCommand = Command(
                id: UUID().uuidString,
                commandType: "timer",
                action: "remove",
                targetId: id,
                label: "Manual timer removal",
                parameters: [:],
                createdAt: Date()
            )

            var updatedCommands = session.commands
            updatedCommands.append(removeCommand)

            currentSession = CookingSession(
                recipe: session.recipe,
                commands: updatedCommands,
                timerStatus: session.timerStatus,
                conversationHistory: session.conversationHistory,
                userPreferences: session.userPreferences,
                startedAt: session.startedAt
            )
        }
    }
}
