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
    /// The provider this agent was built for, pinned by the cooking session that owns it.
    /// Passed to every request so a mid-flight change to the app-wide provider can't reroute
    /// one turn of a conversation to a different backend than the rest.
    let provider: LLMProvider

    /// How many earlier messages go into each prompt. Enough for "and how long for that?" to
    /// make sense, not so many that an hour-long cook outgrows an on-device model's context.
    private let maxHistoryMessages = 20

    /// Names this cook's conversation to `LLMService`'s kept prompt cache. See `PromptPrefixCache`.
    private let promptCacheKey = UUID().uuidString

    convenience init(timerManager: TimerManager, recipeEditor: RecipeEditing?, provider: LLMProvider) {
        self.init(llmService: .shared, timerManager: timerManager, recipeEditor: recipeEditor, provider: provider)
    }

    init(llmService: LLMService, timerManager: TimerManager, recipeEditor: RecipeEditing?, provider: LLMProvider) {
        self.llmService = llmService
        self.timerManager = timerManager
        self.recipeEditor = recipeEditor
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
            system: buildSystemMessage(recipe: recipe), tools: cookingTools(), promptCacheKey: promptCacheKey)
    }

    /// The tools this agent would offer, or none if the pinned provider can't call them.
    func cookingTools() -> CookingTools? {
        llmService.capability(of: provider).toolCallingEnabled
            ? CookingTools(timerManager: timerManager, recipeEditor: recipeEditor)
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
            tools: cookingTools(),
            modelId: provider == .local ? llmService.activeOnDeviceModel?.modelId : nil,
            provider: provider,
            promptCacheKey: provider == .local ? promptCacheKey : nil,
            onChunk: onChunk
        )
    }

    // MARK: - Private Methods

    private func buildSystemMessage(recipe: Recipe?, includingTimers: Bool = false) -> ChatMessage {
        var prompt = "You are LittleChef, a concise and helpful cooking assistant. Answer cooking questions directly. Be brief."

        // Every token here is read again before each answer, and on a phone that wait is most of
        // the time to the first word. So each rule is here only where nothing else does its job:
        //  - The phone's voices get the text through `SpokenText`, which writes out "tbsp",
        //    "350°F" and "1/2" itself. Hands-free on the Mac speaks the Mac's own text with no
        //    such pass, so BigBro still needs the rules spelled out.
        //  - Timers: "created, not started" is in create_timer's description and its result, and
        //    `ToolLoopGuard` refuses a start in the same turn. A paragraph here repeated all three.
        if provider == .bigBro {
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
        } else {
            prompt += " Your replies are read aloud: write plain sentences, with no markdown, lists or emoji."
        }

        if cookingTools()?.recipeEditor != nil {
            prompt += recipeEditingInstructions
        }

        if let recipe = recipe {
            prompt += "\n\nRecipe: \(recipe.title.isEmpty ? "not named yet" : recipe.title)"
            if let desc = recipe.description { prompt += "\n\(desc)" }
            prompt += "\nServings: \(recipe.servings)"
            if let prep = recipe.prepTime { prompt += " | Prep: \(prep) minutes" }
            if let cook = recipe.cookTime { prompt += " | Cook: \(cook) minutes" }

            // One per line: ingredients carry commas of their own ("4 cloves garlic, minced"),
            // so a comma-joined list ran one into the next.
            if recipe.ingredients.isEmpty {
                prompt += "\n\nIngredients: none written down yet"
            } else {
                prompt += "\n\nIngredients:"
                for ingredient in recipe.ingredients {
                    prompt += "\n- \(ingredient)"
                }
            }

            if recipe.instructions.isEmpty {
                prompt += "\n\nSteps: none written down yet"
            } else {
                prompt += "\n\nSteps:"
                for (i, step) in recipe.instructions.enumerated() {
                    prompt += "\n\(i + 1). \(step)"
                }
            }
        }

        if includingTimers { prompt += timersNote }

        return ChatMessage(role: .system, content: prompt)
    }

    /// The timers as they stand, or nothing when there are none.
    private var timersNote: String {
        let timers = timerManager.getAllTimers()
        guard !timers.isEmpty else { return "" }
        var note = "\n\nActive timers:"
        for timer in timers {
            let state = timer.status == .new ? "created, not started yet" : timer.status.rawValue
            note += "\n- \(timer.label): \(state), \(SpokenDuration.text(seconds: timer.remainingSeconds)) left"
        }
        return note
    }

    /// How to use the recipe tools, which differs entirely depending on whether there is a recipe.
    ///
    /// Following one, editing it is a thing you do when told to and not otherwise: a model that
    /// rewrites the recipe every time it suggests something turns its own advice into the user's
    /// recorded method. Writing one from nothing, the opposite — the whole point of the cook is
    /// that the recipe ends up written down, and a model waiting to be asked writes nothing.
    private var recipeEditingInstructions: String {
        if recipeEditor?.isBuildingNewRecipe == true {
            return """


                This cook started without a recipe: you are writing it down as the two of you go. \
                Whenever the user names things they are using, record them with add_ingredients. \
                Whenever they describe what they did, record it with add_steps, in the order it \
                happened. Use set_recipe_details to name the dish once you know what it is, and \
                to fill in servings or times when the user mentions them. Record only what the \
                user actually says they used or did — never your own suggestions, and never a \
                whole recipe you have guessed at. Keep answering their questions as you normally \
                would; writing the recipe down happens alongside that, not instead of it.
                """ + batchingInstructions
        }

        return """


            The user may cook the recipe differently from how it reads. When they tell you they \
            changed something — a different amount, an extra ingredient, a step they skipped or \
            did another way — record it with update_ingredients, add_ingredients, \
            remove_ingredients, update_steps, add_steps or remove_steps. Only record what the \
            user actually did or asked you to change; never edit the recipe to match a \
            suggestion of your own, and never rewrite it just because they asked a question \
            about it. Nothing you record is saved — they are shown every change when the cook \
            ends and choose then whether to keep it — so do not tell them the recipe has been \
            updated or saved.
            """ + batchingInstructions
    }

    /// How to spend tool calls, which matters more than it looks.
    ///
    /// Every recipe tool takes a list, and a model that calls them one line at a time turns "eggs,
    /// flour and milk" into three round trips — three re-prefills of the whole conversation, each
    /// one another chance to lose track of what it has already recorded and start over. The
    /// snapshot note is the other half of that: the recipe printed below is taken when the user's
    /// message arrives and does not move while the tools run, so the tool results are the only
    /// honest account of the recipe mid-turn, and they say so.
    ///
    /// The rest is about reading tool results, which only the Mac's tool loop does. The phone
    /// runs every call from one reply and answers with the results, so it gets the first rule
    /// alone.
    private var batchingInstructions: String {
        guard provider == .bigBro else {
            return """


                Record everything from one message in a single call per tool, one item per line.
                """
        }
        return """


        Record everything from one message in a single call per tool: pass every ingredient to \
        one add_ingredients call, one per line, and every step to one add_steps call. Never call \
        the same tool twice in a row. Each result ends with the list as it now stands — trust \
        that over the recipe printed below, which is a snapshot from before your edits. When a \
        result says a line was already there, it is recorded and there is nothing left to do: do \
        not send it again. Once you have recorded what the user said, answer them in words.
        """
    }
}
