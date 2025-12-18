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
    @Published var errorMessage: String?
    @Published var lastResponse: String = ""
    @Published var streamingResponse: String = ""  // Real-time accumulation
    @Published var lastAudioData: Data? = nil

    // Expose timers from TimerManager
    var localTimers: [LocalTimer] {
        timerManager.localTimers
    }

    private let apiService = APIService.shared
    private let preferencesManager: PreferencesManager
    private let webSocketService: WebSocketService
    private let timerManager: TimerManager

    // Audio chunk accumulation
    private var audioChunks: [Int: Data] = [:]
    private var currentRequestId: String?

    // Callback for when response is ready to be spoken
    var onResponseReady: ((String, Data?) -> Void)?

    init(preferencesManager: PreferencesManager, timerManager: TimerManager) {
        self.preferencesManager = preferencesManager
        self.webSocketService = WebSocketService()
        self.timerManager = timerManager

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
            self.errorMessage = error.message
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
        self.errorMessage = nil

        // Connect WebSocket when starting session
        webSocketService.connect()

        print("🔵 Started new cooking session with model: \(userPreferences.llmModel)")

        // Send warmup query after a brief delay to ensure WebSocket is connected
        // This query won't be added to conversation history
        Task {
            // Wait for WebSocket connection to establish
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            if let session = currentSession {
                _ = webSocketService.sendWarmupQuery(session: session)
                print("🔥 Sent warmup query to wake up Lambda")
            }
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
        self.errorMessage = nil
        audioChunks.removeAll()

        // Clear all timers
        clearAllTimers()

        print("🔴 Ended cooking session - all state reset")
    }

    private func clearAllTimers() {
        timerManager.clearAllTimers()
    }

    // MARK: - Agent Communication

    func sendQuery(_ query: String) {
        guard var session = currentSession else {
            self.errorMessage = "No active cooking session"
            return
        }

        guard webSocketService.isConnected else {
            self.errorMessage = "WebSocket not connected. Reconnecting..."
            webSocketService.connect()
            return
        }

        // Clear any previous state
        self.errorMessage = nil
        isLoading = true
        streamingResponse = ""
        audioChunks.removeAll()
        lastAudioData = nil

        // Update session with current timer status before sending
        let updatedSession = CookingSession(
            recipe: session.recipe,
            commands: session.commands,
            timerStatus: timerManager.getTimerStatusForBackend(), // Current timer status
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
        let scaledRecipe = RecipeScalingService.createScaledRecipe(from: session.recipe, servings: newServings)

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

    // MARK: - Timer Management

    func processCommands(from session: CookingSession) {
        // Delegate timer command processing to TimerManager
        timerManager.processTimerCommands(session.commands)

        // Future: Add handling for other command types here
    }

    // MARK: - Manual Timer Management (for UI)

    func addManualTimer(label: String, durationMinutes: Int) {
        let timerId = UUID().uuidString
        let durationSeconds = durationMinutes * 60

        timerManager.addTimer(id: timerId, label: label, duration: durationSeconds)

        // Also add to session state for AI awareness
        if let session = currentSession {
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
        timerManager.removeTimer(id: id)

        // Add remove command to session state for AI awareness
        if let session = currentSession {
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
