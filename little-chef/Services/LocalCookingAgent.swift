//
//  LocalCookingAgent.swift
//  little-chef
//
//  Briefs the model for a cooking session and asks it one question at a time.
//

import Foundation

/// Turns a cooking session's state into a prompt and a tool list, and runs one turn against the
/// provider the session pinned.
///
/// Holds no conversation of its own. The session's transcript is the conversation — typed turns
/// and the turns a hands-free loop on the Mac mirrored in alike — so every turn is built from
/// what the caller passes. A private copy here used to drift from it: a question typed after a
/// spoken exchange on the Mac was asked with none of that exchange in context.
@MainActor
final class LocalCookingAgent {
    private let llmService: LLMService
    private let timerManager: TimerManager
    /// The session's recipe, for the tools that edit it. Nil for a session with nothing to edit.
    private let recipeEditor: RecipeEditing?
    /// The user's shopping list, for `add_to_shopping_list`. Nil when there's none to add to.
    private let shoppingList: ShoppingListWriting?
    /// What the inventory says about the recipe, as the cook started. See `CookingPrompt.Kitchen`.
    let kitchen: CookingPrompt.Kitchen?
    /// The provider this agent was built for, pinned by the cooking session that owns it.
    /// Passed to every request so a mid-flight change to the app-wide provider can't reroute
    /// one turn of a conversation to a different backend than the rest.
    let provider: LLMProvider

    /// How many earlier messages go into each prompt. Enough for "and how long for that?" to
    /// make sense, not so many that an hour-long cook outgrows an on-device model's context.
    private let maxHistoryMessages = 20

    /// Names the cooking conversation to `LLMService`'s kept prompt cache. The same for every
    /// cook, so a prompt read ahead while the recipe was open is still there when the cook starts:
    /// the cache is reused only where the new prompt begins with exactly the tokens it holds, so
    /// a different recipe or conversation can't pick up the wrong one. See `PromptPrefixCache`.
    static let promptCacheKey = "cooking"

    /// Room for a short answer plus a tool call that records a whole recipe's worth of steps. The
    /// prompt asks for one to three sentences; this stops a model that ignores it from talking
    /// for a minute.
    private let maxReplyTokens = 512

    convenience init(
        timerManager: TimerManager, recipeEditor: RecipeEditing?, shoppingList: ShoppingListWriting?,
        kitchen: CookingPrompt.Kitchen?, provider: LLMProvider
    ) {
        self.init(llmService: .shared, timerManager: timerManager, recipeEditor: recipeEditor,
                  shoppingList: shoppingList, kitchen: kitchen, provider: provider)
    }

    init(
        llmService: LLMService, timerManager: TimerManager, recipeEditor: RecipeEditing?,
        shoppingList: ShoppingListWriting?, kitchen: CookingPrompt.Kitchen?, provider: LLMProvider
    ) {
        self.llmService = llmService
        self.timerManager = timerManager
        self.recipeEditor = recipeEditor
        self.shoppingList = shoppingList
        self.kitchen = kitchen
        self.provider = provider
    }

    // MARK: - Voice support

    /// The cooking system prompt for `recipe`, as plain text.
    ///
    /// `BigBroVoiceSession` runs its own conversation against the Mac rather than going through
    /// this agent, and takes a system prompt as a string. Exposed so the spoken assistant is
    /// briefed identically to the typed one instead of carrying a second copy of the prompt.
    func systemPrompt(for recipe: Recipe?) -> String {
        // The Mac's hands-free loop is briefed once, so it gets the timers as they stand then.
        buildSystemMessage(recipe: recipe, includingTimers: true).content
    }

    /// Reads the instructions, tools and recipe into the on-device model now, while the cook is
    /// starting, so the first question doesn't wait for them. Nothing to do on the Mac.
    func prewarm(recipe: Recipe?) async {
        guard provider == .local else { return }
        await llmService.prewarmPrompt(
            system: buildSystemMessage(recipe: recipe), tools: cookingTools(), promptCacheKey: Self.promptCacheKey)
    }

    /// The tools this agent would offer, or none if the pinned provider can't call them.
    func cookingTools() -> CookingTools? {
        llmService.capability(of: provider).toolCallingEnabled
            ? CookingTools(timerManager: timerManager, recipeEditor: recipeEditor, shoppingList: shoppingList)
            : nil
    }

    // MARK: - Asking

    /// Answers `question`, streaming the visible reply to `onChunk` as it generates.
    ///
    /// - Parameter history: the conversation before this question, oldest first.
    func reply(
        to question: String,
        recipe: Recipe?,
        history: [Message],
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        let spoken = history.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // The window moves eight messages at a time rather than one, so the conversation's start
        // — and with it the model's kept cache — stays put for eight turns at a stretch instead
        // of changing on every one once a cook passes twenty messages.
        let overflow = max(0, spoken.count - maxHistoryMessages)
        let earlier = spoken
            .dropFirst((overflow + 7) / 8 * 8)
            .map { ChatMessage(role: $0.isUser ? .user : .assistant, content: $0.content) }

        // Timers change by the second, so they ride on the question rather than in the system
        // prompt: a system prompt that changed every turn would be read from scratch every turn.
        return try await llmService.generateChatCompletionStreaming(
            messages: [buildSystemMessage(recipe: recipe)] + earlier
                + [ChatMessage(role: .user, content: question + timersNote)],
            maxTokens: maxReplyTokens,
            tools: cookingTools(),
            modelId: provider == .local ? llmService.activeOnDeviceModel?.modelId : nil,
            provider: provider,
            promptCacheKey: provider == .local ? Self.promptCacheKey : nil,
            onChunk: onChunk
        )
    }

    // MARK: - Private Methods

    private func buildSystemMessage(recipe: Recipe?, includingTimers: Bool = false) -> ChatMessage {
        let editing: CookingPrompt.Editing
        if cookingTools()?.recipeEditor == nil {
            editing = .none
        } else {
            editing = recipeEditor?.isBuildingNewRecipe == true ? .writing : .following
        }
        var prompt = CookingPrompt(provider: provider, recipe: recipe, editing: editing, kitchen: kitchen).system
        if includingTimers { prompt += timersNote }
        return ChatMessage(role: .system, content: prompt)
    }

    /// The timers as they stand, or nothing when there are none.
    private var timersNote: String { CookingPrompt.timersNote(timerManager.getAllTimers()) }
}
