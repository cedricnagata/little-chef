//
//  LocalCookingAgent.swift
//  little-chef
//
//  Local cooking agent that orchestrates LLM + tool calling
//

import Foundation

/// Local agent for handling cooking assistant interactions
@MainActor
class LocalCookingAgent: ObservableObject {
    // MARK: - Dependencies
    private let llmService: LLMService
    private let timerManager: TimerManager
    /// The session's recipe, for the tools that edit it. Nil for a session with nothing to edit.
    private let recipeEditor: RecipeEditing?
    /// The provider this agent was built for, pinned by the cooking session that owns it.
    /// Passed to every request so a mid-flight change to the app-wide provider can't reroute
    /// one turn of a conversation to a different backend than the rest.
    let provider: LLMProvider

    // MARK: - State
    @Published var isProcessing = false
    private var conversationHistory: [ChatMessage] = []
    private let maxHistoryLength = 20

    // MARK: - Initialization

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
        buildSystemMessage(recipe: recipe).content
    }

    /// The tools this agent would offer, or none if the pinned provider can't call them.
    func cookingTools() -> CookingTools? {
        llmService.capability(of: provider).toolCallingEnabled
            ? CookingTools(timerManager: timerManager, recipeEditor: recipeEditor)
            : nil
    }

    // MARK: - Public Methods

    func processQuery(
        userMessage: String,
        recipe: Recipe?,
        conversationContext: [Message]
    ) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        let systemMessage = buildSystemMessage(recipe: recipe)
        let userChatMessage = ChatMessage(role: .user, content: userMessage)

        var messages: [ChatMessage] = [systemMessage] + conversationHistory + [userChatMessage]

        if messages.count > maxHistoryLength {
            messages = [systemMessage] + Array(messages.suffix(maxHistoryLength - 1))
        }

        let response = try await llmService.generateChatCompletion(
            messages: messages,
            tools: cookingTools(),
            modelId: provider == .local ? LLMService.supportedOnDeviceModel?.modelId : nil,
            provider: provider
        )

        conversationHistory.append(ChatMessage(role: .user, content: userMessage))
        conversationHistory.append(ChatMessage(role: .assistant, content: response))

        if conversationHistory.count > maxHistoryLength {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryLength))
        }

        return response
    }

    /// Streaming variant — calls `onChunk` with each text fragment as it arrives.
    func processQueryStreaming(
        userMessage: String,
        recipe: Recipe?,
        conversationContext: [Message],
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        let systemMessage = buildSystemMessage(recipe: recipe)
        let userChatMessage = ChatMessage(role: .user, content: userMessage)

        var messages: [ChatMessage] = [systemMessage] + conversationHistory + [userChatMessage]

        if messages.count > maxHistoryLength {
            messages = [systemMessage] + Array(messages.suffix(maxHistoryLength - 1))
        }

        let response = try await llmService.generateChatCompletionStreaming(
            messages: messages,
            tools: cookingTools(),
            modelId: provider == .local ? LLMService.supportedOnDeviceModel?.modelId : nil,
            provider: provider,
            onChunk: onChunk
        )

        conversationHistory.append(ChatMessage(role: .user, content: userMessage))
        conversationHistory.append(ChatMessage(role: .assistant, content: response))

        if conversationHistory.count > maxHistoryLength {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryLength))
        }

        return response
    }

    func clearHistory() {
        conversationHistory.removeAll()
    }

    func reset() {
        conversationHistory.removeAll()
        isProcessing = false
    }

    // MARK: - Private Methods

    private func buildSystemMessage(recipe: Recipe?) -> ChatMessage {
        var prompt = "You are LittleChef, a concise and helpful cooking assistant. Answer cooking questions directly. Be brief."

        // Everything here is read aloud by a speech model that pronounces abbreviations as
        // letters — "tsp" comes out "tee ess pee" — so they have to be spelled out in the text
        // before they ever reach it.
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

        if cookingTools() != nil {
            // Creating and starting are two separate messages, not two calls in one turn — a
            // timer that starts the moment it is named leaves no room to correct the duration.
            prompt += """


                Timers: creating a timer and starting it are separate actions in separate replies. \
                When asked to set a timer, call create_timer only, then tell the user it is ready \
                and wait. Start it with start_timer only when they ask in a later message. Never \
                call create_timer and start_timer in the same reply. Use update_timer to change a \
                timer's duration or name, stop_timer to stop one, delete_timer to remove one.
                """
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

            prompt += recipe.ingredients.isEmpty
                ? "\n\nIngredients: none written down yet"
                : "\n\nIngredients: \(recipe.ingredients.joined(separator: ", "))"

            if recipe.instructions.isEmpty {
                prompt += "\n\nSteps: none written down yet"
            } else {
                prompt += "\n\nSteps:"
                for (i, step) in recipe.instructions.enumerated() {
                    prompt += "\n\(i + 1). \(step)"
                }
            }
        }

        let activeTimers = timerManager.getAllTimers()
        if !activeTimers.isEmpty {
            prompt += "\n\nActive timers:"
            for timer in activeTimers {
                let state = timer.status == .new ? "created, not started yet" : timer.status.rawValue
                prompt += "\n- \(timer.name): \(state), \(timer.remainingMinutes) minutes left"
            }
        }

        return ChatMessage(role: .system, content: prompt)
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
    private var batchingInstructions: String {
        """


        Record everything from one message in a single call per tool: pass every ingredient to \
        one add_ingredients call, one per line, and every step to one add_steps call. Never call \
        the same tool twice in a row. Each result ends with the list as it now stands — trust \
        that over the recipe printed below, which is a snapshot from before your edits. When a \
        result says a line was already there, it is recorded and there is nothing left to do: do \
        not send it again. Once you have recorded what the user said, answer them in words.
        """
    }
}

// MARK: - ConversationMessage Protocol

protocol ConversationMessage {
    var content: String { get }
    var isUser: Bool { get }
}
