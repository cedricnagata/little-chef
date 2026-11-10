//
//  CookingSessionManager.swift
//  little-chef
//
//  The cook in progress: its recipe, its conversation, its timers, and the edits the
//  assistant makes along the way.
//

import Foundation
import SwiftUI

@MainActor
class CookingSessionManager: ObservableObject, TimerManager {
    @Published var currentSession: CookingSession?
    @Published var isLoading = false
    @Published var error: String?
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

    /// The inventory and shopping list. Set by `MainView`, which owns it; nil in previews, where a
    /// cook has no kitchen to look at and no shopping list to add to.
    weak var kitchen: KitchenManager?

    /// What the inventory said about this cook's recipe when it started. See `CookingPrompt.Kitchen`.
    private var kitchenNote: CookingPrompt.Kitchen?

    /// The in-flight warm-up, held so ending the session can cancel it. Without this, leaving a
    /// cook immediately after starting one leaves a multi-second model load running against a
    /// session that no longer exists.
    private var warmUpTask: Task<Void, Never>?

    /// Reading the cook's prompt into the on-device model ahead of the first question. See
    /// `LocalCookingAgent.prewarm(recipe:)`.
    private var promptPrewarmTask: Task<Void, Never>?

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
        begin(
            CookingSession(
                sourceRecipeID: recipe.id,
                recipe: RecipeBase(from: recipe),
                voiceSettings: storedVoiceSettings()
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
        begin(
            CookingSession(
                sourceRecipeID: nil,
                recipe: .blank(),
                voiceSettings: storedVoiceSettings()
            )
        )
    }

    private func begin(_ session: CookingSession) {
        currentSession = session
        kitchenNote = kitchenNote(for: createRecipeFromSession(session))
        // Read once, here. Everything downstream — the agent, the voice loop, the capability
        // gate — asks this session rather than the service, so the backend is fixed for the
        // duration of the cook.
        sessionProvider = llmService.currentProvider

        error = nil
        startWarmUp()
        #if DEBUG
        if ScreenshotFixtures.isActive { stageScreenshotConversation() }
        #endif
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
            prewarmPrompt()
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
            self.prewarmPrompt()
        }
    }

    #if DEBUG
    /// The conversation and running timer the App Store's cooking screenshot shows. The Simulator
    /// runs no model, so the replies are written out rather than generated.
    private func stageScreenshotConversation() {
        // 9:39 today, two minutes before the 9:41 the screenshots' status bar shows.
        let start = Calendar.current.date(bySettingHour: 9, minute: 39, second: 0, of: Date()) ?? Date()
        currentSession?.conversationHistory = ScreenshotFixtures.conversation.enumerated().map { i, turn in
            Message(id: UUID(), role: turn.role, content: turn.text, timestamp: start.addingTimeInterval(Double(i) * 15))
        }
        if createTimer(name: ScreenshotFixtures.timer.name, durationSeconds: ScreenshotFixtures.timer.seconds) {
            _ = startTimer(name: ScreenshotFixtures.timer.name)
        }
    }
    #endif

    /// Once the model is up and the agent exists — whichever comes second — reads the cook's
    /// instructions, tools and recipe in, so the first question reads only itself.
    private func prewarmPrompt() {
        guard let agent = cookingAgent, let session = currentSession else { return }
        let recipe = createRecipeFromSession(session)
        promptPrewarmTask?.cancel()
        promptPrewarmTask = Task { await agent.prewarm(recipe: recipe) }
    }

    func initAgentForSession() {
        cookingAgent = makeAgent(provider: sessionProvider, kitchen: kitchenNote)
        if hasWarmedUp && !isPreparingModel { prewarmPrompt() }
        error = nil
        // The cook can be resumed onto this screen without going back through
        // `startCookingSession` — a warm-up that already finished is a no-op, one that never
        // ran gets its chance here.
        if !hasWarmedUp { startWarmUp() }
    }

    private func makeAgent(provider: LLMProvider, kitchen kitchenNote: CookingPrompt.Kitchen?) -> LocalCookingAgent {
        LocalCookingAgent(
            timerManager: self, recipeEditor: self, shoppingList: kitchen == nil ? nil : self,
            kitchen: kitchenNote, provider: provider)
    }

    /// What the inventory says about `recipe`, or nil when the user keeps no inventory.
    private func kitchenNote(for recipe: Recipe) -> CookingPrompt.Kitchen? {
        guard let kitchen, kitchen.isTrackingInventory else { return nil }
        return CookingPrompt.Kitchen(missing: kitchen.availability(of: recipe).missingNames)
    }

    /// Loads the on-device model and reads the cooking prompt for `recipe` in while its page is
    /// open, so starting the cook has nothing left to read and the first question reads only
    /// itself. Called from the recipe page.
    ///
    /// Waits a moment first, and a page closed during that wait reads nothing, so scrolling
    /// through recipes doesn't start a read for each one. Once started it runs to the end even if
    /// the page closes, because closing it is usually the cook starting, which wants exactly this.
    /// Does nothing during a cook, on BigBro, or for a model that isn't downloaded. The prompt is
    /// the one the cook will build — same instructions, recipe and kitchen line — and the cook
    /// finds it in `PromptPrefixCache`, which reuses only an exact match.
    func readAhead(for recipe: Recipe) async {
        guard currentSession == nil, llmService.currentProvider == .local else { return }
        do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
        guard currentSession == nil else { return }
        let kitchenNote = kitchenNote(for: recipe)
        Task { [weak self] in
            guard let self else { return }
            await self.llmService.prepareForSession(provider: .local)
            // A cook of another recipe started meanwhile: its own read-ahead is the one wanted.
            if let session = self.currentSession, session.sourceRecipeID != recipe.id { return }
            await self.makeAgent(provider: .local, kitchen: kitchenNote).prewarm(recipe: Self.recipeAsCooked(recipe))
        }
    }

    private func storedVoiceSettings() -> LocalVoiceSettings {
        do {
            return try dataManager.fetchPreferences().toUserPreferences().voiceSettings
        } catch {
            dprint("⚠️ Failed to load preferences, using defaults: \(error)")
            return .defaultSettings
        }
    }

    func endCookingSession() {
        kitchenNote = nil
        warmUpTask?.cancel()
        warmUpTask = nil
        promptPrewarmTask?.cancel()
        promptPrewarmTask = nil
        hasWarmedUp = false
        isPreparingModel = false
        currentSession = nil
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

    /// Asks the assistant `query`, streaming the reply into the transcript as it arrives.
    ///
    /// Calls `onSentence` with each complete sentence, for speaking. Returns the finished reply,
    /// or nil if the turn failed — in which case ``error`` says why.
    @discardableResult
    func sendQueryStreaming(_ query: String, onSentence: ((String) -> Void)? = nil) async -> String? {
        guard let session = currentSession else {
            error = "No active cooking session"
            return nil
        }
        guard let agent = cookingAgent else {
            error = "Cooking agent not initialized"
            return nil
        }

        error = nil
        isLoading = true
        defer { isLoading = false }

        // Read before this turn is added to it: the agent is given the conversation so far,
        // then the question.
        let history = session.conversationHistory
        let recipe = createRecipeFromSession(session)

        // "Start the timer", "how long is left", "repeat that": answered at once, without the
        // model. The turn still goes into the conversation, so the model sees it later.
        let lastReply = history.last { !$0.isUser && !$0.content.isEmpty }?.content
        if let answer = CookingCommand.answer(
            to: query, recipe: recipe, lastReply: lastReply, tools: CookingTools(timerManager: self)
        ) {
            dprint("⚡️ Answered without the model: \(query)")
            currentSession?.conversationHistory.append(
                Message(id: UUID(), role: "user", content: query, timestamp: Date()))
            currentSession?.conversationHistory.append(
                Message(id: UUID(), role: "assistant", content: answer, timestamp: Date()))
            if let onSentence {
                var sentences = SentenceSplitter()
                sentences.append(answer).forEach(onSentence)
                if let rest = sentences.flush() { onSentence(rest) }
            }
            return answer
        }

        currentSession?.conversationHistory.append(
            Message(id: UUID(), role: "user", content: query, timestamp: Date())
        )
        let replyID = UUID()
        currentSession?.conversationHistory.append(
            Message(id: replyID, role: "assistant", content: "", timestamp: Date())
        )

        var sentences = SentenceSplitter()
        do {
            let response = try await agent.reply(to: query, recipe: recipe, history: history) { [weak self] chunk in
                guard let self else { return }
                self.appendToMessage(replyID, chunk)
                if let onSentence {
                    sentences.append(chunk).forEach(onSentence)
                }
            }
            if let rest = sentences.flush() { onSentence?(rest) }

            // The finished reply replaces what streamed: tool results and clean-up happen at the
            // end, so the two can differ.
            replaceMessage(replyID, with: response)
            return response
        } catch {
            self.error = "Failed to get response: \(error.localizedDescription)"
            dprint("Agent query error: \(error)")
            currentSession?.conversationHistory.removeAll { $0.id == replyID }
            return nil
        }
    }

    private func appendToMessage(_ id: UUID, _ text: String) {
        guard let index = currentSession?.conversationHistory.firstIndex(where: { $0.id == id }),
              let message = currentSession?.conversationHistory[index] else { return }
        currentSession?.conversationHistory[index] = Message(
            id: id, role: message.role, content: message.content + text, timestamp: message.timestamp
        )
    }

    private func replaceMessage(_ id: UUID, with text: String) {
        guard let index = currentSession?.conversationHistory.firstIndex(where: { $0.id == id }),
              let message = currentSession?.conversationHistory[index] else { return }
        currentSession?.conversationHistory[index] = Message(
            id: id, role: message.role, content: text, timestamp: message.timestamp
        )
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
                await self?.sendQueryStreaming(question, onSentence: onSentence) ?? ""
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
        replaceMessage(id, with: text)
    }

    private func createRecipeFromSession(_ session: CookingSession) -> Recipe {
        Self.recipe(from: session.recipe, id: session.sourceRecipeID ?? session.id)
    }

    /// `recipe` as a cook of it hands it to the assistant, for reading its prompt in ahead.
    private static func recipeAsCooked(_ recipe: Recipe) -> Recipe {
        Self.recipe(from: RecipeBase(from: recipe), id: recipe.id)
    }

    private static func recipe(from base: RecipeBase, id: UUID) -> Recipe {
        Recipe(
            id: id,
            title: base.title,
            description: base.description,
            servings: base.servings,
            prepTime: base.prepTime,
            cookTime: base.cookTime,
            ingredients: base.ingredients,
            instructions: base.instructions,
            tags: base.tags,
            sourceUrl: base.sourceUrl,
            cuisineType: base.cuisineType,
            difficulty: base.difficulty,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    var conversationHistory: [Message] { currentSession?.conversationHistory ?? [] }

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

        currentSession?.recipe = IngredientScaler.scaled(session.recipe, toServings: newServings)
        currentSession?.baselineRecipe = IngredientScaler.scaled(session.baselineRecipe, toServings: newServings)

        dprint("🔄 Updated servings from \(originalServings) to \(newServings)")
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

    /// Falls back to the only timer when the name matches nothing, through `findTimer` — which
    /// is why `TimerActionInference` only ever acts on replies that mention a timer.
    @discardableResult
    func deleteTimer(name: String) -> Bool {
        guard let index = findTimerIndex(named: name) else { return false }
        localTimers[index].stopLiveActivity()
        localTimers.remove(at: index)
        return true
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
    /// Same rule as the assistant's `timer` tool: creating a timer and running it are two
    /// decisions, and a timer that starts the moment it is added gives no chance to fix a
    /// mistyped duration.
    ///
    /// A label already in use gets a number rather than being refused: the assistant has to be
    /// told about a duplicate, but someone tapping Add has asked for a second timer and should
    /// get one, not a sheet that closes having done nothing.
    func addManualTimer(label: String, durationSeconds: Int) {
        var name = label
        var suffix = 2
        while localTimers.contains(where: { $0.label.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(label) \(suffix)"
            suffix += 1
        }
        createTimer(name: name, durationSeconds: durationSeconds)
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
        currentSession?.recipe.ingredients.insert(line, at: RecipeLineMatcher.insertionIndex(position, count: recipe.ingredients.count))
        return .added
    }

    func replaceIngredient(matching query: String, with text: String) -> String? {
        guard let recipe = currentSession?.recipe,
              let index = RecipeLineMatcher.index(matching: query, in: recipe.ingredients, allowingNumbers: false)
        else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let previous = recipe.ingredients[index]
        currentSession?.recipe.ingredients[index] = line
        return previous
    }

    func removeIngredient(matching query: String) -> String? {
        guard let recipe = currentSession?.recipe,
              let index = RecipeLineMatcher.index(matching: query, in: recipe.ingredients, allowingNumbers: false)
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
        currentSession?.recipe.instructions.insert(line, at: RecipeLineMatcher.insertionIndex(position, count: recipe.instructions.count))
        return .added
    }

    func replaceStep(matching query: String, with text: String) -> String? {
        guard let recipe = currentSession?.recipe,
              let index = RecipeLineMatcher.index(matching: query, in: recipe.instructions, allowingNumbers: true)
        else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let previous = recipe.instructions[index]
        currentSession?.recipe.instructions[index] = line
        return previous
    }

    func removeStep(matching query: String) -> String? {
        guard let recipe = currentSession?.recipe,
              let index = RecipeLineMatcher.index(matching: query, in: recipe.instructions, allowingNumbers: true)
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
}

// MARK: - Shopping list

/// `add_to_shopping_list`, onto the kitchen's list, labelled with the recipe being cooked.
extension CookingSessionManager: ShoppingListWriting {
    func addShoppingItems(_ names: [String]) -> [String] {
        guard let kitchen else { return [] }
        let title = currentSession?.recipe.title
        let recipeTitle = title?.isEmpty == false ? title : nil
        return names.filter { kitchen.addToShoppingList([$0], recipeTitle: recipeTitle) == 1 }
    }
}
