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

    // Recipe modification tracking
    @Published var pendingModifications: [RecipeModification] = []
    @Published var originalRecipe: RecipeBase? = nil
    @Published var originalRecipeId: UUID? = nil  // Track for saving
    @Published var showModificationReview = false
    @Published var recipeWasModified = false  // Track if recipe was edited during session
    @Published var modificationSummary: String? = nil  // Summary of what changed

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
                print("🔊 Assembled \(sortedChunks.count) audio chunks → \(audioData.count) bytes total")
                self.audioChunks.removeAll()
            } else {
                print("⚠️ No audio chunks received - will fall back to native TTS")
                print("   Response length: \(response.count) characters")
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

        // Store original recipe and ID for modification tracking
        self.originalRecipe = recipeBase
        self.originalRecipeId = recipe.id
        self.pendingModifications = []
        self.recipeWasModified = false
        self.modificationSummary = nil

        // Load preferences from local PreferencesManager
        let userPreferences = UserPreferencesDetailed(from: preferencesManager.preferences)

        currentSession = CookingSession(recipe: recipeBase, userPreferences: userPreferences)
        self.errorMessage = nil

        // Connect WebSocket when starting session
        webSocketService.connect()

        print("🔵 Started new cooking session with model: \(userPreferences.llmModel)")
        print("📝 Stored original recipe for modification tracking")

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
        // Check if there are pending modifications
        if !pendingModifications.isEmpty {
            print("📝 Found \(pendingModifications.count) pending modifications - showing review screen")
            showModificationReview = true
            return  // Don't clear state yet - wait for user review
        }

        // No modifications, proceed with normal cleanup
        finalizeSessionEnd()
    }

    private func finalizeSessionEnd() {
        // Disconnect WebSocket
        webSocketService.disconnect()

        // Clear session data
        currentSession = nil
        lastResponse = ""
        streamingResponse = ""
        lastAudioData = nil
        self.errorMessage = nil
        audioChunks.removeAll()

        // Clear modification tracking
        pendingModifications = []
        originalRecipe = nil
        originalRecipeId = nil

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
        print("🔊 Cleared audio chunks, starting new query: \(query.prefix(50))...")

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

    // MARK: - Command Processing

    func processCommands(from session: CookingSession) {
        // Process timer commands
        let timerCommands = session.commands.filter { $0.isTimerCommand }
        timerManager.processTimerCommands(timerCommands)

        // Check if recipe was modified
        let recipeModifiedCommands = session.commands.filter { $0.isRecipeModified }
        if !recipeModifiedCommands.isEmpty {
            recipeWasModified = true
            // Get the latest modification summary
            if let latestModification = recipeModifiedCommands.last {
                modificationSummary = latestModification.parameters["summary"]?.value as? String ?? latestModification.label
            }
        }

        // Process recipe modification commands (legacy granular modifications)
        let modificationCommands = session.commands.filter { $0.isRecipeModification }
        processRecipeModifications(modificationCommands)
    }

    private func processRecipeModifications(_ commands: [Command]) {
        guard let original = originalRecipe else { return }

        for command in commands {
            // Convert command parameters to RecipeModification
            if let modification = createModificationFromCommand(command) {
                // Add to pending modifications if not already present
                if !pendingModifications.contains(where: { $0.id == modification.id }) {
                    pendingModifications.append(modification)
                    print("📝 Added recipe modification: \(modification.displayTitle)")
                }

                // Apply modification to current session recipe immediately
                if let session = currentSession {
                    let modifiedRecipe = applyModificationToRecipe(modification, recipe: session.recipe)
                    currentSession = CookingSession(
                        recipe: modifiedRecipe,
                        commands: session.commands,
                        timerStatus: session.timerStatus,
                        conversationHistory: session.conversationHistory,
                        userPreferences: session.userPreferences,
                        startedAt: session.startedAt
                    )
                }
            }
        }
    }

    private func createModificationFromCommand(_ command: Command) -> RecipeModification? {
        guard command.isRecipeModification else { return nil }

        // Extract modification data from command parameters
        guard let modificationTypeStr = command.parameters["modification_type"]?.value as? String,
              let modificationType = ModificationType(rawValue: modificationTypeStr),
              let field = command.parameters["field"]?.value as? String,
              let rationale = command.parameters["rationale"]?.value as? String else {
            print("⚠️ Invalid modification command parameters")
            return nil
        }

        let targetIndex = command.parameters["target_index"]?.value as? Int
        let oldValue = command.parameters["old_value"]?.value as? String
        let newValue = command.parameters["new_value"]?.value as? String

        return RecipeModification(
            id: command.targetId ?? command.id,
            modificationType: modificationType,
            field: field,
            targetIndex: targetIndex,
            oldValue: oldValue,
            newValue: newValue,
            rationale: rationale,
            confidence: 1.0,  // From cooking assistant, assume high confidence
            createdAt: Date()
        )
    }

    // TODO: This method is disabled pending cooking session modifications refactor
    // The cooking session modification flow needs to be updated to use the new Cursor-style
    // incremental diff approach. For now, recipe modifications during cooking are not supported.
    private func applyModificationToRecipe(_ modification: RecipeModification, recipe: RecipeBase) -> RecipeBase {
        // Temporarily disabled - return original recipe unchanged
        print("⚠️ applyModificationToRecipe is disabled - needs refactor for Cursor-style approach")
        return recipe
    }

    // MARK: - Modification Review

    // TODO: This method is disabled pending cooking session modifications refactor
    func dismissModificationReview(saveModifications: Bool, selectedIds: Set<String>) {
        // Temporarily disabled
        print("⚠️ dismissModificationReview is disabled - needs refactor for Cursor-style approach")

        if saveModifications && !selectedIds.isEmpty, let recipeId = originalRecipeId, let original = originalRecipe {
            // Build recipe with only selected modifications
            let selectedMods = pendingModifications.filter { selectedIds.contains($0.id) }
            // Old code removed - needs refactor
            let finalRecipe = original // Use original for now

            // Post notification to save modified recipe
            NotificationCenter.default.post(
                name: .saveModifiedRecipe,
                object: nil,
                userInfo: ["recipeId": recipeId, "recipe": finalRecipe]
            )

            print("💾 Saved \(selectedIds.count) modifications to recipe")
        }

        // Clean up and finalize session end
        showModificationReview = false
        finalizeSessionEnd()
    }

    // MARK: - Timer Management

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

// MARK: - Notification Names

extension Notification.Name {
    static let saveModifiedRecipe = Notification.Name("saveModifiedRecipe")
}
