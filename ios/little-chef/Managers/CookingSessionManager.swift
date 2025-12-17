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
    @Published var streamingResponse: String = ""  // Real-time accumulation
    @Published var lastAudioData: Data? = nil

    private let apiService = APIService.shared
    private let preferencesManager: PreferencesManager
    private let webSocketService: WebSocketService

    // Audio chunk accumulation
    private var audioChunks: [Int: Data] = [:]
    private var currentRequestId: String?

    // Callback for when response is ready to be spoken
    var onResponseReady: ((String, Data?) -> Void)?

    init(preferencesManager: PreferencesManager = PreferencesManager()) {
        self.preferencesManager = preferencesManager
        self.webSocketService = WebSocketService()

        setupWebSocketHandlers()
    }

    // MARK: - WebSocket Setup

    private func setupWebSocketHandlers() {
        webSocketService.onToken = { [weak self] content, requestId in
            guard let self = self, requestId == self.currentRequestId else { return }
            self.streamingResponse += content
        }

        webSocketService.onAudio = { [weak self] audioData, chunkIndex, requestId in
            guard let self = self, requestId == self.currentRequestId else { return }
            self.audioChunks[chunkIndex] = audioData
        }

        webSocketService.onTool = { [weak self] status, tool, args, result, requestId in
            guard let self = self, requestId == self.currentRequestId else { return }
            print("🔧 Tool \(status): \(tool)")
        }

        webSocketService.onDone = { [weak self] response, session, commands, requestId in
            guard let self = self, requestId == self.currentRequestId else { return }

            // Preserve the current (possibly scaled) recipe instead of using backend's original
            let recipeToUse = self.currentSession?.recipe ?? session.recipe

            // Process commands
            let updatedSession = CookingSession(
                recipe: recipeToUse,  // Use local recipe (preserves scaling)
                commands: session.commands,
                timerStatus: session.timerStatus,
                conversationHistory: session.conversationHistory,
                userPreferences: session.userPreferences,
                startedAt: session.startedAt
            )

            self.processCommands(from: updatedSession)
            self.currentSession = updatedSession
            self.lastResponse = response
            self.streamingResponse = ""

            // Reassemble audio chunks
            var completeAudio: Data? = nil
            if !self.audioChunks.isEmpty {
                let sortedChunks = self.audioChunks.sorted(by: { $0.key < $1.key })
                var audioData = Data()
                for (_, chunk) in sortedChunks {
                    audioData.append(chunk)
                }
                completeAudio = audioData
                self.lastAudioData = audioData
                self.audioChunks.removeAll()
                print("🔊 Received \(sortedChunks.count) audio chunks (\(audioData.count) bytes)")
            }

            self.isLoading = false

            // Trigger callback for voice playback (after state is updated)
            self.onResponseReady?(response, completeAudio)
        }

        webSocketService.onError = { [weak self] error, requestId in
            guard let self = self, requestId == self.currentRequestId else { return }
            self.error = error.message
            self.isLoading = false
            self.streamingResponse = ""
        }
    }

    // MARK: - Session Management

    func startCookingSession(with recipe: Recipe) {
        let recipeBase = RecipeBase(from: recipe)

        // Load preferences from local PreferencesManager
        let userPreferences = UserPreferencesDetailed(from: preferencesManager.preferences)

        currentSession = CookingSession(recipe: recipeBase, userPreferences: userPreferences)
        error = nil

        // Connect WebSocket when starting session
        webSocketService.connect()

        print("🔵 Started new cooking session with model: \(userPreferences.llmModel)")

        // Send warmup query to avoid Lambda cold start on first real query
        // This query won't be added to conversation history
        if let session = currentSession {
            _ = webSocketService.sendWarmupQuery(session: session)
            print("🔥 Sent warmup query to wake up Lambda")
        }
    }

    func endCookingSession() {
        // Disconnect WebSocket
        webSocketService.disconnect()

        // Clear session data
        currentSession = nil
        lastResponse = ""
        streamingResponse = ""
        lastAudioData = nil
        error = nil
        audioChunks.removeAll()

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

    func sendQuery(_ query: String) {
        guard var session = currentSession else {
            error = "No active cooking session"
            return
        }

        guard webSocketService.isConnected else {
            error = "WebSocket not connected. Reconnecting..."
            webSocketService.connect()
            return
        }

        // Clear any previous state
        error = nil
        isLoading = true
        streamingResponse = ""
        audioChunks.removeAll()
        lastAudioData = nil

        // Update session with current timer status before sending
        let updatedSession = CookingSession(
            recipe: session.recipe,
            commands: session.commands,
            timerStatus: getTimerStatusForBackend(), // Current timer status
            conversationHistory: session.conversationHistory,
            userPreferences: session.userPreferences,
            startedAt: session.startedAt
        )

        // Send query via WebSocket and get the request ID
        currentRequestId = webSocketService.sendQuery(session: updatedSession, query: query)

        print("📤 Sent query via WebSocket: \(query.prefix(50))...")
        print("🔑 Request ID: \(currentRequestId ?? "nil")")
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
                parameters: ["duration_seconds": AnyCodable(durationSeconds)],
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
