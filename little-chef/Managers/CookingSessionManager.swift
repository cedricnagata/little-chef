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

    /// True while the backend is being brought up for this session, before any question is asked.
    ///
    /// Drives the "getting ready" line in the cooking view. Purely informational — the input bar
    /// stays live, because a question typed during warm-up simply waits on the same load.
    @Published private(set) var isPreparingModel = false

    /// What the pinned provider can do — the capability the cooking UI should gate on.
    var capability: AICapability { llmService.capability(of: sessionProvider) }

    private let dataManager = LocalDataManager.shared
    private var cookingAgent: LocalCookingAgent?
    private let llmService: LLMService

    /// The in-flight warm-up, held so ending the session can cancel it. Without this, leaving a
    /// cook immediately after starting one leaves a multi-second model load running against a
    /// session that no longer exists.
    private var warmUpTask: Task<Void, Never>?

    /// Whether this session has already asked for a warm-up — tracked separately from
    /// `warmUpTask`, which is nil both before a warm-up and when there was nothing to warm.
    private var hasWarmedUp = false

    convenience init() {
        self.init(llmService: .shared)
    }

    init(llmService: LLMService) {
        self.llmService = llmService
    }

    // MARK: - Session Management

    func startCookingSession(with recipe: Recipe) async {
        let preferences = await loadLocalPreferences()
        begin(
            CookingSession(
                sourceRecipeID: recipe.id,
                recipe: RecipeBase(from: recipe),
                userPreferences: preferences
            )
        )
    }

    /// Starts a cook with nothing to follow, writing the recipe down as it goes.
    ///
    /// The recipe is blank rather than absent so that everything downstream — the pane, the
    /// system prompt, the servings control, the save-on-exit flow — is the same code either way.
    /// The difference between the two kinds of cook lives in `sourceRecipeID` being nil, which is
    /// also exactly the question the end of the session has to answer: update that recipe, or
    /// make a new one.
    func startFreestyleSession() async {
        let preferences = await loadLocalPreferences()
        begin(
            CookingSession(
                sourceRecipeID: nil,
                recipe: .blank(),
                userPreferences: preferences
            )
        )
    }

    private func begin(_ session: CookingSession) {
        currentSession = session
        // Read once, here. Everything downstream — the agent, the voice loop, the capability
        // gate — asks this session rather than the service, so the backend is fixed for the
        // duration of the cook.
        sessionProvider = llmService.currentProvider

        error = nil
        startWarmUp()
        dprint("🔵 Started new cooking session on \(sessionProvider.rawValue)")
    }

    /// Brings the pinned backend up now rather than on the first question.
    ///
    /// Starting a cook is the last moment before the assistant is expected to answer, and it is
    /// a moment the user is already waiting through — so the cold start belongs here, labelled,
    /// rather than hiding inside the first reply and looking like a model that never responded.
    private func startWarmUp() {
        warmUpTask?.cancel()
        warmUpTask = nil
        hasWarmedUp = true
        let provider = sessionProvider
        guard llmService.needsWarmUp(for: provider) else {
            isPreparingModel = false
            return
        }
        isPreparingModel = true
        warmUpTask = Task { [weak self] in
            guard let self else { return }
            await self.llmService.prepareForSession(provider: provider)
            // Speech is loaded lazily on the Mac too, and hands-free is one tap away from here.
            await self.llmService.prepareSpeechForSession(provider: provider)
            guard !Task.isCancelled else { return }
            self.isPreparingModel = false
        }
    }

    func initAgentForSession() {
        cookingAgent = LocalCookingAgent(timerManager: self, recipeEditor: self, provider: sessionProvider)
        error = nil
        // The cook can be resumed onto this screen without going back through
        // `startCookingSession` — a warm-up that already finished is a no-op, one that never
        // ran gets its chance here.
        if !hasWarmedUp { startWarmUp() }
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
        warmUpTask?.cancel()
        warmUpTask = nil
        hasWarmedUp = false
        isPreparingModel = false
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
            id: session.sourceRecipeID ?? session.id,
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

    /// Rescales the cook to a different number of servings.
    ///
    /// Scales the baseline alongside the working copy. Both start identical and go through the
    /// same arithmetic, so scaling on its own leaves them identical too — which is what stops a
    /// nudge of the servings stepper from presenting a dozen rewritten ingredient lines as
    /// unsaved changes on the way out. Anything the user or the assistant actually edited still
    /// differs, before the scale or after it.
    func updateServings(newServings: Int) {
        guard let session = currentSession, newServings > 0 else { return }

        let originalServings = session.recipe.servings
        guard originalServings > 0, newServings != originalServings else { return }

        currentSession?.recipe = createScaledRecipe(from: session.recipe, servings: newServings)
        currentSession?.baselineRecipe = createScaledRecipe(from: session.baselineRecipe, servings: newServings)

        dprint("🔄 Updated servings from \(originalServings) to \(newServings)")
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

    /// Creates a timer and leaves it stopped.
    ///
    /// Deliberately does not start it: the assistant creates and starts timers with two separate
    /// tools, and a create that quietly started would make the second one meaningless.
    @discardableResult
    func createTimer(name: String, durationSeconds: Int) -> Bool {
        // Exact match, not `findTimer` — its fuzzy fallbacks are there to *resolve* a name the
        // model half-remembered, and one of them answers "the only timer" to any query at all.
        // Reused for the duplicate check, that made the first timer of a cook block every one
        // after it as a duplicate of itself.
        if localTimers.contains(where: { $0.label.caseInsensitiveCompare(name) == .orderedSame }) {
            dprint("Timer '\(name)' already exists, not creating duplicate")
            return false
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
        dprint("Created timer: \(name) (\(durationSeconds)s), stopped")
        return true
    }

    @discardableResult
    func startTimer(name: String) -> Bool {
        guard let index = findTimerIndex(named: name) else {
            dprint("Timer '\(name)' not found")
            return false
        }
        guard localTimers[index].status != .running else { return false }
        localTimers[index].start()
        return true
    }

    @discardableResult
    func stopTimer(name: String) -> Bool {
        guard let index = findTimerIndex(named: name) else {
            dprint("Timer '\(name)' not found")
            return false
        }
        guard localTimers[index].status == .running else { return false }
        localTimers[index].pause()
        return true
    }

    @discardableResult
    func updateTimer(name: String, newName: String?, durationSeconds: Int?) -> Bool {
        guard let index = findTimerIndex(named: name) else {
            dprint("Timer '\(name)' not found")
            return false
        }
        localTimers[index].update(label: newName, durationSeconds: durationSeconds)
        return true
    }

    @discardableResult
    func deleteTimer(name: String) -> Bool {
        if let index = findTimerIndex(named: name) {
            localTimers[index].stopLiveActivity()
            localTimers.remove(at: index)
            return true
        }
        // Fallback: if only one timer exists, delete it
        if localTimers.count == 1 {
            localTimers[0].stopLiveActivity()
            localTimers.removeAll()
            return true
        }
        return false
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

    /// Adds a timer from the UI, stopped — the card's play button starts it.
    ///
    /// Same rule as the assistant's `create_timer`: creating a timer and running it are two
    /// decisions, and a timer that starts the moment it is added gives no chance to fix a
    /// mistyped duration.
    func addManualTimer(label: String, durationSeconds: Int) {
        createTimer(name: label, durationSeconds: durationSeconds)
    }

    func deleteManualTimer(id: String) {
        if let timerIndex = localTimers.firstIndex(where: { $0.id == id }) {
            let timer = localTimers[timerIndex]
            timer.stopLiveActivity()
            localTimers.remove(at: timerIndex)
            dprint("🗑️ Manually deleted timer: \(timer.label)")
        }
    }

    // MARK: - Unsaved recipe work

    /// What the assistant has changed about this recipe, against the recipe as it is stored.
    ///
    /// Empty for a cook that started without a recipe: there is nothing to compare against, and
    /// a list of edits is the wrong way to show someone a recipe they have not seen written down
    /// yet. That case is `isBuildingNewRecipe` and shows the recipe itself instead.
    var recipeChanges: [RecipeChange] {
        guard let session = currentSession, !session.isBuildingNewRecipe else { return [] }
        return RecipeDiff(from: session.baselineRecipe, to: session.recipe).changes
    }

    /// Whether ending the cook now would throw away work the user might want.
    ///
    /// A plain inequality rather than `!recipeChanges.isEmpty`, and the difference matters: this
    /// is read from the header's body, which re-renders on every streamed token of a reply, and
    /// `RecipeDiff` runs a quadratic table over two lists to get there. `RecipeDiff` covers every
    /// field of `RecipeBase`, so the two answers are the same answer.
    var hasPendingRecipeWork: Bool {
        guard let session = currentSession else { return false }
        return session.isBuildingNewRecipe
            ? session.recipe.hasContent
            : session.recipe != session.baselineRecipe
    }

    /// The recipe as it would be stored, with `title` filled in by whoever is saving it.
    func recipeDataForSaving(titled title: String) -> RecipeData? {
        currentSession?.recipe.toRecipeData(overridingTitle: title)
    }
}

// MARK: - Recipe editing

/// The assistant's edits to the recipe being cooked.
///
/// Every one of these writes to `currentSession.recipe` and stops there. The store is not
/// touched until the cook ends and the user approves what changed, which is the only reason it
/// is safe to let a model rewrite someone's recipe on the strength of a sentence it half heard
/// over a running extractor fan.
extension CookingSessionManager: RecipeEditing {
    var isBuildingNewRecipe: Bool { currentSession?.isBuildingNewRecipe ?? false }

    var currentIngredients: [String] { currentSession?.recipe.ingredients ?? [] }
    var currentSteps: [String] { currentSession?.recipe.instructions ?? [] }

    // MARK: Ingredients

    func addIngredient(_ text: String, at position: Int?) -> LineAdditionOutcome {
        guard let recipe = currentSession?.recipe else { return .rejected }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .rejected }
        // Not appended a second time: a model recording as the cook talks will name the same
        // ingredient again three turns later, and a recipe that lists garlic twice reads as a
        // mistake the user has to go and find. Reported as `alreadyPresent` rather than a
        // failure, though — see `LineAdditionOutcome`.
        guard !recipe.ingredients.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) else {
            return .alreadyPresent
        }
        currentSession?.recipe.ingredients.insert(line, at: Self.insertionIndex(position, count: recipe.ingredients.count))
        return .added
    }

    func replaceIngredient(matching query: String, with text: String) -> String? {
        guard let recipe = currentSession?.recipe,
              let index = Self.indexOfLine(matching: query, in: recipe.ingredients, allowingNumbers: false)
        else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let previous = recipe.ingredients[index]
        currentSession?.recipe.ingredients[index] = line
        return previous
    }

    func removeIngredient(matching query: String) -> String? {
        guard let recipe = currentSession?.recipe,
              let index = Self.indexOfLine(matching: query, in: recipe.ingredients, allowingNumbers: false)
        else { return nil }
        return currentSession?.recipe.ingredients.remove(at: index)
    }

    // MARK: Steps

    func addStep(_ text: String, at position: Int?) -> LineAdditionOutcome {
        guard let recipe = currentSession?.recipe else { return .rejected }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .rejected }
        guard !recipe.instructions.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) else {
            return .alreadyPresent
        }
        currentSession?.recipe.instructions.insert(line, at: Self.insertionIndex(position, count: recipe.instructions.count))
        return .added
    }

    func replaceStep(matching query: String, with text: String) -> String? {
        guard let recipe = currentSession?.recipe,
              let index = Self.indexOfLine(matching: query, in: recipe.instructions, allowingNumbers: true)
        else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let previous = recipe.instructions[index]
        currentSession?.recipe.instructions[index] = line
        return previous
    }

    func removeStep(matching query: String) -> String? {
        guard let recipe = currentSession?.recipe,
              let index = Self.indexOfLine(matching: query, in: recipe.instructions, allowingNumbers: true)
        else { return nil }
        return currentSession?.recipe.instructions.remove(at: index)
    }

    // MARK: Details

    func setRecipeDetails(
        title: String?,
        description: String?,
        servings: Int?,
        prepTime: Int?,
        cookTime: Int?,
        difficulty: String?,
        cuisineType: String?,
        tags: [String]?
    ) -> [String] {
        guard currentSession != nil else { return [] }
        var applied: [String] = []

        if let title = nonEmpty(title) {
            currentSession?.recipe.title = title
            applied.append("The recipe is now called '\(title)'.")
        }
        if let description = nonEmpty(description) {
            currentSession?.recipe.description = description
            applied.append("Description set.")
        }
        if let servings, servings > 0, servings != currentSession?.recipe.servings {
            // Two different meanings of the same field, and which one applies is not a judgement
            // call. Following a recipe, changing the servings is the thing the stepper does —
            // cook more of it — so it goes through the same scaling, or the ingredient amounts
            // would silently stop matching the yield. Writing a recipe down, the amounts are
            // whatever the user said they used, and rescaling them would corrupt the only record
            // of what actually went in the pan.
            if isBuildingNewRecipe {
                currentSession?.recipe.servings = servings
            } else {
                updateServings(newServings: servings)
            }
            applied.append("Servings set to \(servings).")
        }
        if let prepTime, prepTime > 0 {
            currentSession?.recipe.prepTime = prepTime
            applied.append("Preparation time set to \(prepTime) minutes.")
        }
        if let cookTime, cookTime > 0 {
            currentSession?.recipe.cookTime = cookTime
            applied.append("Cooking time set to \(cookTime) minutes.")
        }
        if let difficulty = nonEmpty(difficulty) {
            currentSession?.recipe.difficulty = difficulty.lowercased()
            applied.append("Difficulty set to \(difficulty.lowercased()).")
        }
        if let cuisineType = nonEmpty(cuisineType) {
            currentSession?.recipe.cuisineType = cuisineType
            applied.append("Cuisine set to \(cuisineType).")
        }
        if let tags, !tags.isEmpty {
            currentSession?.recipe.tags = tags
            applied.append("Tags set to \(tags.joined(separator: ", ")).")
        }

        if !applied.isEmpty {
            applied.append("Nothing is saved until the user chooses to keep it at the end of the cook.")
        }
        return applied
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: Resolving what the model meant

    /// Where a 1-based `position` lands, clamped. Nil, zero and anything past the end all append,
    /// because "add it at the end" is what a model means by leaving the argument off and what it
    /// means by an out-of-range guess.
    private static func insertionIndex(_ position: Int?, count: Int) -> Int {
        guard let position, position >= 1 else { return count }
        return min(position - 1, count)
    }

    /// The line the model meant.
    ///
    /// It will quote the line back exactly, quote part of it, paraphrase it, or — for steps —
    /// just give the number. Matching only on an exact quote fails often enough that the
    /// assistant would look broken; matching too loosely deletes the wrong ingredient, which is
    /// worse. So: exact, then substring either way round, then the line sharing the most
    /// distinctive words, and nothing at all if that finds none.
    ///
    /// Numbers are only accepted where the UI shows them. Steps are numbered on screen, so "step
    /// 3" and "3" mean the third one. Ingredients are not, and there a bare "2" is far more
    /// likely to be the start of an amount the model truncated than a position.
    private static func indexOfLine(matching query: String, in lines: [String], allowingNumbers: Bool) -> Int? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, !lines.isEmpty else { return nil }

        if allowingNumbers {
            let digits = needle
                .replacingOccurrences(of: "step", with: "")
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int(digits), number >= 1, number <= lines.count {
                return number - 1
            }
        }

        if let exact = lines.firstIndex(where: { $0.lowercased() == needle }) {
            return exact
        }
        if let overlapping = lines.firstIndex(where: {
            let line = $0.lowercased()
            return line.contains(needle) || needle.contains(line)
        }) {
            return overlapping
        }

        // Last resort: "the garlic" against "2 cloves of garlic, minced". Short words are
        // dropped so that "the" and "of" can't carry a match on their own.
        let words = needle
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 3 }
        guard !words.isEmpty else { return nil }

        let scored = lines.enumerated().map { index, line -> (index: Int, score: Int) in
            let haystack = line.lowercased()
            return (index, words.filter { haystack.contains($0) }.count)
        }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
        return best.index
    }
}

// MARK: - Message conforms to ConversationMessage protocol

extension Message: ConversationMessage {
    var isUser: Bool {
        return role == "user"
    }
}
