//
//  ToolDefinition.swift
//  little-chef
//
//  Timer and recipe tool definitions for the cooking assistant
//

import Foundation
import Tokenizers

// MARK: - Timer Manager Protocol

/// The timer operations the assistant can perform.
///
/// Every mutating call reports whether it found the timer, so the tool layer can tell the model
/// "no timer called that" instead of reporting a success that never happened — a lie the model
/// then repeats to a cook who is waiting on a bell that was never set.
@MainActor
protocol TimerManager {
    /// Creates a timer in the `new` state — **stopped**. Starting it is a separate action.
    /// Returns false if a timer by that name already exists.
    @discardableResult func createTimer(name: String, durationSeconds: Int) -> Bool
    @discardableResult func startTimer(name: String) -> Bool
    @discardableResult func stopTimer(name: String) -> Bool
    @discardableResult func updateTimer(name: String, newName: String?, durationSeconds: Int?) -> Bool
    @discardableResult func deleteTimer(name: String) -> Bool
    func getTimer(name: String) -> LocalTimer?
    func getAllTimers() -> [LocalTimer]
}

// MARK: - Recipe Editing Protocol

/// What happened to one line an add was asked to record.
///
/// A duplicate is deliberately not a failure. The assistant records as the cook talks, so the
/// same ingredient gets named again three turns later — and once a tool loop retries a batch,
/// the lines it already recorded come back round a second time. Answering those with an error
/// tells the model its work didn't land, and a model that believes that tries again: which is
/// how one message turned into an endless run of `add_ingredient` calls. The line is already
/// there, the recipe is already right, and that is worth saying plainly rather than refusing.
enum LineAdditionOutcome {
    case added
    /// Already listed, so nothing changed — and nothing needed to.
    case alreadyPresent
    /// Nothing usable in the text, or no session to write to.
    case rejected
}

/// The edits the assistant can make to the recipe being cooked.
///
/// Everything here writes to the session's working copy only. Nothing reaches the store until
/// the cook ends and the user approves the changes, which is what makes it safe to let a model
/// rewrite a recipe on the strength of "actually I used two lemons".
///
/// Like ``TimerManager``, every call reports what it did rather than assuming it worked: the
/// model addresses lines by quoting them back, and a quote that matches nothing has to come back
/// as "I couldn't find that" rather than a cheerful confirmation of an edit that never landed.
@MainActor
protocol RecipeEditing {
    /// Whether this cook is writing a recipe from nothing rather than following an existing one.
    var isBuildingNewRecipe: Bool { get }

    /// The ingredient lines as they stand right now, for the tool results to report back.
    ///
    /// The recipe in the system prompt is a snapshot taken when the user's message arrived, so
    /// from the second tool call of a turn onwards it is out of date — it still says "none
    /// written down yet" while three ingredients have been recorded. The tool result is the only
    /// thing that can correct that mid-turn, so it carries the list.
    var currentIngredients: [String] { get }
    var currentSteps: [String] { get }

    /// Inserts at `position` counting from 1, or appends when it is nil or out of range.
    @discardableResult func addIngredient(_ text: String, at position: Int?) -> LineAdditionOutcome
    /// Returns the line that was replaced, or nil if nothing matched.
    func replaceIngredient(matching query: String, with text: String) -> String?
    /// Returns the line that was removed, or nil if nothing matched.
    func removeIngredient(matching query: String) -> String?

    @discardableResult func addStep(_ text: String, at position: Int?) -> LineAdditionOutcome
    /// `query` may be a step number or a quote from the step itself.
    func replaceStep(matching query: String, with text: String) -> String?
    func removeStep(matching query: String) -> String?

    /// Applies whichever details were supplied. Returns one plain-language line per field that
    /// actually moved, so the tool result can tell the model what it managed to change.
    func setRecipeDetails(
        title: String?,
        description: String?,
        servings: Int?,
        prepTime: Int?,
        cookTime: Int?,
        difficulty: String?,
        cuisineType: String?,
        tags: [String]?
    ) -> [String]
}

// MARK: - Tool specs

/// One tool, in the one place both backends read it from.
///
/// MLX wants a nested dictionary and the Mac wants a typed definition, and each used to be
/// written out by hand in a different file. Two hand-maintained copies of the same tool set is
/// how the assistant ends up able to edit a recipe on-device and not over BigBro — a difference
/// nobody would think to test for, in a feature whose whole point is that it works while your
/// hands are covered in flour.
struct CookingToolSpec: Sendable {
    struct Parameter: Sendable {
        let name: String
        let type: String
        let description: String
        var isRequired = false
    }

    let name: String
    let description: String
    let parameters: [Parameter]

    var requiredParameterNames: [String] { parameters.filter(\.isRequired).map(\.name) }

    /// The MLX form: a plain nested dictionary handed to `UserInput`.
    var mlxToolSpec: ToolSpec {
        var properties: [String: any Sendable] = [:]
        for parameter in parameters {
            properties[parameter.name] = [
                "type": parameter.type,
                "description": parameter.description
            ] as [String: any Sendable]
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": requiredParameterNames
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        ] as ToolSpec
    }
}

// MARK: - Tool loop guard

/// The timers created during the tool loop currently being executed.
///
/// Creating and starting a timer are two tools on purpose, and a model handed both will call
/// them back to back in one loop every time — which is how "set a timer for the pasta" ended up
/// counting down before the water was on. This records what the loop created so `start_timer`
/// can refuse, leaving the start for the *next* message once the cook asks for it.
///
/// A reference type because `CookingTools` is a value passed by copy into the loop.
@MainActor
final class ToolLoopGuard {
    private var createdThisLoop: Set<String> = []

    /// Nonisolated so `CookingTools` — which is built wherever a request is assembled — does not
    /// have to be main-actor isolated just to hold one. Everything that touches the set is.
    nonisolated init() {}

    /// A new user message — nothing has been created for this loop yet.
    func beginLoop() { createdThisLoop.removeAll() }

    func recordCreation(id: String) { createdThisLoop.insert(id) }

    func wasCreatedThisLoop(id: String) -> Bool { createdThisLoop.contains(id) }
}

// MARK: - Cooking Tools

struct CookingTools {
    let timerManager: TimerManager
    /// The session's recipe, when this cook has one to edit. Nil leaves the recipe tools off the
    /// list entirely rather than offering tools that would answer every call with a refusal.
    let recipeEditor: RecipeEditing?
    private let loopGuard: ToolLoopGuard

    init(timerManager: TimerManager, recipeEditor: RecipeEditing? = nil) {
        self.timerManager = timerManager
        self.recipeEditor = recipeEditor
        self.loopGuard = ToolLoopGuard()
    }

    /// Starts a fresh tool loop, releasing the create-then-start hold from the last one.
    ///
    /// Only the hands-free Mac path needs to call this: it builds one `CookingTools` when the
    /// loop starts and reuses it for every spoken turn, so without this a timer created in one
    /// turn could never be started in any later one. The typed path gets a new value per
    /// request and is already clean.
    @MainActor
    func beginToolLoop() { loopGuard.beginLoop() }

    /// Every tool this session offers, backend-agnostic.
    var toolSpecs: [CookingToolSpec] {
        recipeEditor == nil ? Self.timerToolSpecs : Self.timerToolSpecs + Self.recipeToolSpecs
    }

    /// Native MLX tool specs for passing to UserInput
    var nativeToolSpecs: [ToolSpec] { toolSpecs.map(\.mlxToolSpec) }

    // MARK: - Timer tools

    static let timerToolSpecs: [CookingToolSpec] = [
        CookingToolSpec(
            name: "create_timer",
            description: "Create a new cooking timer, stopped. This does NOT start it — the user must ask separately before you call start_timer. Provide minutes, seconds, or both (e.g. 30s → seconds:30, 1m30s → minutes:1 seconds:30).",
            parameters: [
                .init(name: "name", type: "string", description: "Timer label e.g. pasta, chicken", isRequired: true),
                .init(name: "minutes", type: "integer", description: "Whole minutes (omit or 0 if under a minute)"),
                .init(name: "seconds", type: "integer", description: "Additional seconds 0-59")
            ]
        ),
        CookingToolSpec(
            name: "start_timer",
            description: "Start or resume an existing timer by name. Only call this when the user asks to start it, never in the same reply that created it.",
            parameters: [
                .init(name: "name", type: "string", description: "Timer name to start", isRequired: true)
            ]
        ),
        CookingToolSpec(
            name: "stop_timer",
            description: "Stop a running timer by name, keeping the time left so it can be resumed",
            parameters: [
                .init(name: "name", type: "string", description: "Timer name to stop", isRequired: true)
            ]
        ),
        CookingToolSpec(
            name: "update_timer",
            description: "Change an existing timer's duration, its name, or both. Give the timer's current name plus whatever is changing.",
            parameters: [
                .init(name: "name", type: "string", description: "The timer's current name", isRequired: true),
                .init(name: "new_name", type: "string", description: "New label, if renaming"),
                .init(name: "minutes", type: "integer", description: "New duration, whole minutes (omit if only renaming)"),
                .init(name: "seconds", type: "integer", description: "New duration, additional seconds 0-59")
            ]
        ),
        CookingToolSpec(
            name: "delete_timer",
            description: "Delete a timer by name",
            parameters: [
                .init(name: "name", type: "string", description: "Timer name to delete", isRequired: true)
            ]
        ),
    ]

    // MARK: - Recipe tools

    /// The recipe tools, one per kind of edit and each taking a *list*.
    ///
    /// Batched rather than one line per call, and that is the whole point of the shape. A cook
    /// says "I used two eggs, some flour and a splash of milk" in one breath, and a per-line tool
    /// answers that with three round trips — three full re-prefills of the conversation, each one
    /// another chance for a small model to lose the thread of what it has already recorded. One
    /// call records the lot.
    ///
    /// Split by section rather than collapsed into a single `edit_recipe`, for two reasons. A
    /// whole-recipe tool makes the model re-emit every untouched line to change one of them,
    /// which `RecipeDiff` then reports as the user having edited all of them — its own paraphrase
    /// presented back as their changes. And a malformed batch of steps would take the ingredient
    /// edits down with it; separate calls fail separately.
    ///
    /// The lists are `string` rather than `array` because the schema both backends project from
    /// ``CookingToolSpec`` is flat — `BigBroTool.Definition.Parameters.Property` is a `type` and a
    /// `description` and nothing else, so there is no `items` to describe an array with. One line
    /// per entry travels fine through both, and ``CookingTools/lines(from:keys:)`` reads a real
    /// JSON array too, for the models that send one anyway.
    static let recipeToolSpecs: [CookingToolSpec] = [
        CookingToolSpec(
            name: "add_ingredients",
            description: "Record one or more ingredients in the recipe being cooked. Pass every ingredient at once, one per line, with the amount in the line itself — 'two cloves of garlic, minced\ntwo eggs\n300 grams plain flour'. Never call this once per ingredient.",
            parameters: [
                .init(name: "items", type: "string", description: "The ingredient lines, one per line, each including its amount", isRequired: true),
                .init(name: "position", type: "integer", description: "Where the first of them goes in the list, counting from 1. Omit to add them at the end.")
            ]
        ),
        CookingToolSpec(
            name: "update_ingredients",
            description: "Rewrite ingredients the recipe already lists — a different amount, a substitution. One change per line, written as 'the line as it reads now -> the whole replacement line'. Pass every change at once.",
            parameters: [
                .init(name: "changes", type: "string", description: "One change per line, as 'existing ingredient -> replacement ingredient, amount included'", isRequired: true)
            ]
        ),
        CookingToolSpec(
            name: "remove_ingredients",
            description: "Remove one or more ingredients from the recipe being cooked. One per line, quoted as the recipe lists them.",
            parameters: [
                .init(name: "items", type: "string", description: "The ingredients to remove, one per line", isRequired: true)
            ]
        ),
        CookingToolSpec(
            name: "add_steps",
            description: "Record one or more steps in the recipe's method, in the order they happened. One step per line, each written as an instruction — 'Fry the onions until soft, about eight minutes\nAdd the garlic and cook for one minute'. Never call this once per step.",
            parameters: [
                .init(name: "steps", type: "string", description: "The steps, one per line, each written as an instruction", isRequired: true),
                .init(name: "position", type: "integer", description: "Which step number the first of them becomes, counting from 1. Omit to add them at the end.")
            ]
        ),
        CookingToolSpec(
            name: "update_steps",
            description: "Rewrite steps the recipe already has. One change per line, written as 'step number or a quote from it -> the whole replacement step'. Pass every change at once.",
            parameters: [
                .init(name: "changes", type: "string", description: "One change per line, as 'step number or quote -> the whole replacement step'", isRequired: true)
            ]
        ),
        CookingToolSpec(
            name: "remove_steps",
            description: "Remove one or more of the recipe's steps. One per line, given as a step number or a quote from the step.",
            parameters: [
                .init(name: "steps", type: "string", description: "The steps to remove, one per line, each a number or a quote", isRequired: true)
            ]
        ),
        CookingToolSpec(
            name: "set_recipe_details",
            description: "Set the recipe's name or any of its details. Pass only what is changing. Servings states what the recipe yields; when the user asks to cook a different amount, this rescales the ingredients to match.",
            parameters: [
                .init(name: "title", type: "string", description: "What the dish is called"),
                .init(name: "description", type: "string", description: "A sentence describing the dish"),
                .init(name: "servings", type: "integer", description: "How many people it serves"),
                .init(name: "prep_minutes", type: "integer", description: "Preparation time in whole minutes"),
                .init(name: "cook_minutes", type: "integer", description: "Cooking time in whole minutes"),
                .init(name: "difficulty", type: "string", description: "One of easy, medium, hard"),
                .init(name: "cuisine", type: "string", description: "Cuisine, e.g. Italian, Thai"),
                .init(name: "tags", type: "string", description: "Tags separated by commas, e.g. 'weeknight, vegetarian'")
            ]
        ),
    ]

    /// What a tool call produced, told twice — because a tool result has two possible audiences
    /// and they want different things.
    ///
    /// Fed back into a tool loop, the result is the model's only accurate view of the recipe
    /// mid-turn, so it carries the resulting list. But not every caller feeds it back: the
    /// on-device path executes tool calls and returns the results *as the reply*, and the
    /// `<tool_call>` text fallback splices them into the answer — where an enumerated ingredient
    /// list would be printed on screen and read out loud by the speech model. So the state echo
    /// goes only to the model, and which audience a call site is serving is a decision the
    /// compiler makes it state.
    struct ToolOutcome {
        /// Sent back as the tool result. Ends with the section as it now stands.
        let forModel: String
        /// Safe to show or speak: what happened, and nothing else.
        let forUser: String

        init(_ both: String) {
            forModel = both
            forUser = both
        }

        init(forModel: String, forUser: String) {
            self.forModel = forModel
            self.forUser = forUser
        }
    }

    /// Execute a tool by name with the given arguments
    @MainActor
    func execute(toolName: String, arguments: [String: Any]) -> ToolOutcome {
        if let outcome = executeRecipeTool(toolName: toolName, arguments: arguments) {
            return outcome
        }
        return ToolOutcome(executeTimerTool(toolName: toolName, arguments: arguments))
    }

    @MainActor
    private func executeTimerTool(toolName: String, arguments: [String: Any]) -> String {
        // `set_timer` and `pause_timer` are the names this tool set used to carry. Models copy
        // them out of their own training data and out of earlier turns in the transcript, and
        // the text-tool-call fallback parses whatever name it is handed, so both are mapped
        // rather than answered with "unknown tool".
        switch toolName {
        case "create_timer", "set_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            let totalSeconds = duration(from: arguments)
            guard totalSeconds > 0 else {
                return "Error: duration must be greater than 0"
            }
            guard timerManager.createTimer(name: name, durationSeconds: totalSeconds) else {
                return "A timer called '\(name)' already exists — update it instead of creating another."
            }
            if let created = timerManager.getTimer(name: name) {
                loopGuard.recordCreation(id: created.id)
            }
            return "Timer '\(name)' created for \(spoken(totalSeconds)). It is not running yet — "
                 + "tell the user it is ready and wait for them to ask before starting it."

        case "start_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            guard let timer = timerManager.getTimer(name: name) else {
                return "No timer called '\(name)' exists. Create it first."
            }
            guard !loopGuard.wasCreatedThisLoop(id: timer.id) else {
                return "Timer '\(timer.label)' was only just created, so it cannot be started yet. "
                     + "Tell the user it is set for \(spoken(timer.remainingSeconds)) and ask them "
                     + "to say when to start it."
            }
            guard timerManager.startTimer(name: name) else {
                return "Timer '\(timer.label)' is already running."
            }
            return "Timer '\(timer.label)' started with \(spoken(timer.remainingSeconds)) to go."

        case "stop_timer", "pause_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            guard let timer = timerManager.getTimer(name: name) else {
                return "No timer called '\(name)' exists."
            }
            guard timerManager.stopTimer(name: name) else {
                return "Timer '\(timer.label)' was not running."
            }
            return "Timer '\(timer.label)' stopped with \(spoken(timer.remainingSeconds)) left."

        case "update_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            guard timerManager.getTimer(name: name) != nil else {
                return "No timer called '\(name)' exists. Create it first."
            }
            let newName = string(arguments["new_name"]) ?? string(arguments["newName"])
            let totalSeconds = duration(from: arguments)
            let newDuration = totalSeconds > 0 ? totalSeconds : nil
            guard newName != nil || newDuration != nil else {
                return "Error: give 'new_name', a new duration, or both"
            }
            timerManager.updateTimer(name: name, newName: newName, durationSeconds: newDuration)
            guard let updated = timerManager.getTimer(name: newName ?? name) else {
                return "Timer updated."
            }
            var changes: [String] = []
            if newName != nil { changes.append("renamed to '\(updated.label)'") }
            if let newDuration { changes.append("set to \(spoken(newDuration))") }
            return "Timer '\(name)' \(changes.joined(separator: " and "))."

        case "delete_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            guard timerManager.deleteTimer(name: name) else {
                return "No timer called '\(name)' exists."
            }
            return "Timer '\(name)' deleted."

        default:
            return "Unknown tool: \(toolName)"
        }
    }

    /// The recipe tools, or nil when `toolName` is not one of them.
    ///
    /// These all end in the session's working copy and never the store — see ``RecipeEditing``. The
    /// results say so to the model, because one that thinks it just saved tells the user their
    /// change is safe, and it isn't until they say so on the way out.
    ///
    /// The singular tool names are the ones this set used to carry, kept for the same reason
    /// `set_timer` is: models copy tool names out of their training data and out of earlier turns
    /// of the transcript, and the text-tool-call fallback in `LLMService` executes whatever name it
    /// parses. A singular call is just a batch of one.
    @MainActor
    private func executeRecipeTool(toolName: String, arguments: [String: Any]) -> ToolOutcome? {
        switch toolName {
        case "add_ingredients", "add_ingredient":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            let items = lines(from: arguments, keys: ["items", "item", "ingredients", "ingredient", "name"])
            guard !items.isEmpty else { return ToolOutcome("Error: missing 'items'") }

            var added: [String] = []
            var alreadyThere: [String] = []
            // Walked forward so a batch given a position keeps its own order rather than
            // stacking up reversed at the insertion point.
            var position = optionalInt(arguments["position"])
            for item in items {
                switch editor.addIngredient(item, at: position) {
                case .added:
                    added.append(item)
                    position = position.map { $0 + 1 }
                case .alreadyPresent:
                    alreadyThere.append(item)
                case .rejected:
                    continue
                }
            }

            var sentences: [String] = []
            if !added.isEmpty { sentences.append("Added \(Self.quoted(added)) to the ingredients.") }
            if !alreadyThere.isEmpty {
                sentences.append("\(Self.quoted(alreadyThere)) \(alreadyThere.count == 1 ? "was" : "were") already listed, so nothing needed doing there.")
            }
            if sentences.isEmpty { sentences.append("Nothing was recorded — no ingredient text came through.") }
            return Self.recipeOutcome(
                sentences,
                state: Self.currentList("Ingredients", editor.currentIngredients, numbered: false),
                changed: !added.isEmpty
            )

        case "update_ingredients", "update_ingredient":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            let requested = changes(
                from: arguments,
                listKeys: ["changes", "updates", "items", "ingredients"],
                fromKeys: ["item", "ingredient", "old", "from"],
                toKeys: ["new_item", "newItem", "new_text", "newText", "new", "to"]
            )
            guard !requested.pairs.isEmpty || !requested.unparsed.isEmpty else {
                return ToolOutcome("Error: missing 'changes'")
            }

            var changed: [String] = []
            var unmatched: [String] = []
            for change in requested.pairs {
                if let previous = editor.replaceIngredient(matching: change.from, with: change.to) {
                    changed.append("'\(previous)' to '\(change.to)'")
                } else {
                    unmatched.append(change.from)
                }
            }

            var sentences: [String] = []
            if !changed.isEmpty { sentences.append("Changed \(changed.joined(separator: ", and ")).") }
            if !unmatched.isEmpty {
                sentences.append("No ingredient matched \(Self.quoted(unmatched)) — use add_ingredients if \(unmatched.count == 1 ? "it" : "they") should be listed.")
            }
            if !requested.unparsed.isEmpty {
                sentences.append("\(Self.quoted(requested.unparsed)) had no replacement in \(requested.unparsed.count == 1 ? "it" : "them") — write each change as 'existing line -> replacement line'.")
            }
            return Self.recipeOutcome(
                sentences,
                state: Self.currentList("Ingredients", editor.currentIngredients, numbered: false),
                changed: !changed.isEmpty
            )

        case "remove_ingredients", "remove_ingredient":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            let items = lines(from: arguments, keys: ["items", "item", "ingredients", "ingredient", "name"])
            guard !items.isEmpty else { return ToolOutcome("Error: missing 'items'") }

            var removed: [String] = []
            var unmatched: [String] = []
            for item in items {
                if let line = editor.removeIngredient(matching: item) {
                    removed.append(line)
                } else {
                    unmatched.append(item)
                }
            }

            var sentences: [String] = []
            if !removed.isEmpty { sentences.append("Removed \(Self.quoted(removed)) from the ingredients.") }
            if !unmatched.isEmpty {
                // Not an error, for the same reason a duplicate add isn't: whatever the model
                // was aiming at is not in the recipe, which is the state it was asking for.
                sentences.append("\(Self.quoted(unmatched)) \(unmatched.count == 1 ? "was" : "were") not listed, so there was nothing to remove.")
            }
            return Self.recipeOutcome(
                sentences,
                state: Self.currentList("Ingredients", editor.currentIngredients, numbered: false),
                changed: !removed.isEmpty
            )

        case "add_steps", "add_step":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            let steps = lines(from: arguments, keys: ["steps", "step", "items", "text", "instruction", "instructions"])
            guard !steps.isEmpty else { return ToolOutcome("Error: missing 'steps'") }

            var added: [String] = []
            var alreadyThere: [String] = []
            var position = optionalInt(arguments["position"])
            for step in steps {
                switch editor.addStep(step, at: position) {
                case .added:
                    added.append(step)
                    position = position.map { $0 + 1 }
                case .alreadyPresent:
                    alreadyThere.append(step)
                case .rejected:
                    continue
                }
            }

            var sentences: [String] = []
            if !added.isEmpty { sentences.append("Added \(added.count == 1 ? "the step" : "the steps") \(Self.quoted(added)).") }
            if !alreadyThere.isEmpty {
                sentences.append("\(Self.quoted(alreadyThere)) \(alreadyThere.count == 1 ? "was" : "were") already in the method, so nothing needed doing there.")
            }
            if sentences.isEmpty { sentences.append("Nothing was recorded — no step text came through.") }
            return Self.recipeOutcome(
                sentences,
                state: Self.currentList("Steps", editor.currentSteps, numbered: true),
                changed: !added.isEmpty
            )

        case "update_steps", "update_step":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            let requested = changes(
                from: arguments,
                listKeys: ["changes", "updates", "steps", "items"],
                fromKeys: ["step", "text", "old", "from"],
                toKeys: ["new_text", "newText", "new_step", "newStep", "new", "to"]
            )
            guard !requested.pairs.isEmpty || !requested.unparsed.isEmpty else {
                return ToolOutcome("Error: missing 'changes'")
            }

            var changed: [String] = []
            var unmatched: [String] = []
            for change in requested.pairs {
                if let previous = editor.replaceStep(matching: change.from, with: change.to) {
                    changed.append("'\(previous)' to '\(change.to)'")
                } else {
                    unmatched.append(change.from)
                }
            }

            var sentences: [String] = []
            if !changed.isEmpty { sentences.append("Changed \(changed.joined(separator: ", and ")).") }
            if !unmatched.isEmpty {
                sentences.append("No step matched \(Self.quoted(unmatched)) — use add_steps if \(unmatched.count == 1 ? "it" : "they") should be in the method.")
            }
            if !requested.unparsed.isEmpty {
                sentences.append("\(Self.quoted(requested.unparsed)) had no replacement in \(requested.unparsed.count == 1 ? "it" : "them") — write each change as 'step number or quote -> replacement step'.")
            }
            return Self.recipeOutcome(
                sentences,
                state: Self.currentList("Steps", editor.currentSteps, numbered: true),
                changed: !changed.isEmpty
            )

        case "remove_steps", "remove_step":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            let steps = lines(from: arguments, keys: ["steps", "step", "items", "text"])
            guard !steps.isEmpty else { return ToolOutcome("Error: missing 'steps'") }

            // Highest position first: removing step 2 renumbers step 3, so a batch given as
            // numbers and applied in order would take out the wrong lines after the first.
            var removed: [String] = []
            var unmatched: [String] = []
            for step in Self.numberedLast(steps) {
                if let line = editor.removeStep(matching: step) {
                    removed.append(line)
                } else {
                    unmatched.append(step)
                }
            }

            var sentences: [String] = []
            if !removed.isEmpty { sentences.append("Removed \(removed.count == 1 ? "the step" : "the steps") \(Self.quoted(removed)).") }
            if !unmatched.isEmpty {
                sentences.append("No step matched \(Self.quoted(unmatched)), so there was nothing to remove there.")
            }
            return Self.recipeOutcome(
                sentences,
                state: Self.currentList("Steps", editor.currentSteps, numbered: true),
                changed: !removed.isEmpty
            )

        case "set_recipe_details":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            let tags = string(arguments["tags"]).map { raw in
                raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            }
            let applied = editor.setRecipeDetails(
                title: string(arguments["title"]) ?? string(arguments["name"]),
                description: string(arguments["description"]),
                servings: optionalInt(arguments["servings"]),
                prepTime: optionalInt(arguments["prep_minutes"]) ?? optionalInt(arguments["prepMinutes"]) ?? optionalInt(arguments["prep_time"]),
                cookTime: optionalInt(arguments["cook_minutes"]) ?? optionalInt(arguments["cookMinutes"]) ?? optionalInt(arguments["cook_time"]),
                difficulty: string(arguments["difficulty"]),
                cuisineType: string(arguments["cuisine"]) ?? string(arguments["cuisine_type"]),
                tags: tags
            )
            guard !applied.isEmpty else {
                return ToolOutcome("Nothing changed — give at least one detail to set.")
            }
            // `setRecipeDetails` already ends its report with the not-saved reminder.
            return ToolOutcome(applied.joined(separator: " "))

        default:
            return nil
        }
    }

    private static let noRecipeToEdit =
        ToolOutcome("There is no recipe open to edit in this session.")

    // MARK: - Argument coercion

    /// Tool arguments arrive from JSON, so a number the schema calls an integer can turn up as a
    /// `Double`, and a model that ignores the schema sends `"5"`.
    private func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    /// Like ``int(_:)`` but keeps the difference between "zero" and "not given".
    ///
    /// Timer durations can collapse the two — a zero-second timer is refused anyway — but a
    /// recipe detail cannot: `set_recipe_details` has to tell an omitted prep time apart from a
    /// prep time of nothing, and `position` has to tell "put it at the end" apart from "put it
    /// first".
    private func optionalInt(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private func string(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func duration(from arguments: [String: Any]) -> Int {
        int(arguments["minutes"]) * 60 + int(arguments["seconds"])
    }

    /// Tool results are read back by a speech model, so durations are spelled out rather than
    /// abbreviated — see the same rule in `LocalCookingAgent`'s system prompt.
    private func spoken(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        let minutePart = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        let secondPart = "\(remainder) \(remainder == 1 ? "second" : "seconds")"
        if minutes > 0 && remainder > 0 { return "\(minutePart) and \(secondPart)" }
        if minutes > 0 { return minutePart }
        return secondPart
    }

    // MARK: - List arguments

    private static let bulletRegex = try? NSRegularExpression(
        pattern: "^\\s*(?:[-*•\u{2022}]|\\d+[.)])\\s+"
    )

    /// The entries of a list argument, from whichever of `keys` the model actually used.
    ///
    /// Declared as one string in the schema — see ``recipeToolSpecs`` for why there is no array
    /// type to declare — so the entries arrive newline-separated. Semicolons are accepted too,
    /// because a model told "one per line" inside a JSON string argument will sometimes reach for
    /// the separator that needs no escaping. A real JSON array is read as well: the schema says
    /// string, and models send arrays anyway.
    ///
    /// Commas are deliberately *not* separators. "two cloves of garlic, minced" is one ingredient,
    /// and splitting it would put 'minced' in the recipe as an ingredient of its own.
    private func lines(from arguments: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            guard let value = arguments[key] else { continue }

            if let array = value as? [Any] {
                let entries = array.compactMap { string($0).map(Self.strippingBullet) }.filter { !$0.isEmpty }
                if !entries.isEmpty { return entries }
            }

            if let text = string(value) {
                let entries = text
                    .split(whereSeparator: { $0 == "\n" || $0 == ";" })
                    .map { Self.strippingBullet(String($0)) }
                    .filter { !$0.isEmpty }
                if !entries.isEmpty { return entries }
            }
        }
        return []
    }

    /// A list marker a model wrote as prose — "1. ", "- ", "• " — is markup, not part of the line.
    ///
    /// The digit form requires the space after the dot, so "1.5 litres of stock" survives intact.
    private static func strippingBullet(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = bulletRegex else { return trimmed }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let matched = Range(match.range, in: trimmed)
        else { return trimmed }
        return String(trimmed[matched.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One requested rewrite: the line to find, and what it becomes.
    struct RequestedChange {
        let from: String
        let to: String
    }

    /// What an update tool was asked to change, and what it couldn't make sense of.
    ///
    /// Unparsed entries are carried rather than dropped so the result can name them. A change the
    /// model wrote without an arrow, answered with silence, is a change it believes it made.
    struct RequestedChanges {
        let pairs: [RequestedChange]
        let unparsed: [String]
    }

    /// The arrows a model uses to mean "becomes". Longest first: `->` matches inside `-->`, and
    /// finding it there would leave a stray dash on the end of the line being looked for.
    private static let changeArrows = ["-->", "->", "=>", "→"]

    /// Reads the batch form ("existing -> replacement", one per line), the old two-argument form,
    /// and a JSON array of objects, since a model that ignores the schema tends to reach for one
    /// of the other two.
    private func changes(
        from arguments: [String: Any],
        listKeys: [String],
        fromKeys: [String],
        toKeys: [String]
    ) -> RequestedChanges {
        // The two-argument form first: a model that sent both fields meant exactly one change,
        // and the same words may well also appear in a `changes` string it padded the call with.
        if let source = fromKeys.compactMap({ string(arguments[$0]) }).first,
           let target = toKeys.compactMap({ string(arguments[$0]) }).first {
            return RequestedChanges(pairs: [RequestedChange(from: source, to: target)], unparsed: [])
        }

        for key in listKeys {
            guard let value = arguments[key] else { continue }

            if let array = value as? [Any] {
                var pairs: [RequestedChange] = []
                var unparsed: [String] = []
                for element in array {
                    if let object = element as? [String: Any],
                       let source = fromKeys.compactMap({ string(object[$0]) }).first,
                       let target = toKeys.compactMap({ string(object[$0]) }).first {
                        pairs.append(RequestedChange(from: source, to: target))
                    } else if let line = string(element) {
                        Self.appendChange(from: line, to: &pairs, unparsed: &unparsed)
                    }
                }
                if !pairs.isEmpty || !unparsed.isEmpty {
                    return RequestedChanges(pairs: pairs, unparsed: unparsed)
                }
            }

            if let text = string(value) {
                var pairs: [RequestedChange] = []
                var unparsed: [String] = []
                for line in text.split(whereSeparator: { $0 == "\n" }) {
                    Self.appendChange(from: Self.strippingBullet(String(line)), to: &pairs, unparsed: &unparsed)
                }
                if !pairs.isEmpty || !unparsed.isEmpty {
                    return RequestedChanges(pairs: pairs, unparsed: unparsed)
                }
            }
        }

        return RequestedChanges(pairs: [], unparsed: [])
    }

    private static func appendChange(
        from line: String,
        to pairs: inout [RequestedChange],
        unparsed: inout [String]
    ) {
        guard !line.isEmpty else { return }
        for arrow in changeArrows {
            guard let range = line.range(of: arrow) else { continue }
            let source = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty && !target.isEmpty {
                pairs.append(RequestedChange(from: source, to: target))
            } else {
                unparsed.append(line)
            }
            return
        }
        unparsed.append(line)
    }

    // MARK: - Reporting

    private static let notSavedYet =
        "Nothing is saved until the user chooses to keep it at the end of the cook."

    /// One recipe edit's result, told to both audiences.
    ///
    /// The user hears what happened. The model gets that plus the resulting list, and — when
    /// something actually moved — the reminder that none of it is saved, which it needs and the
    /// user must not be told, since the answer to "is my change safe" is still no.
    private static func recipeOutcome(_ sentences: [String], state: String, changed: Bool) -> ToolOutcome {
        let spoken = sentences.joined(separator: " ")
        var forModel = [spoken, state]
        if changed { forModel.append(notSavedYet) }
        return ToolOutcome(forModel: forModel.joined(separator: " "), forUser: spoken)
    }

    private static func quoted(_ items: [String]) -> String {
        let quoted = items.map { "'\($0)'" }
        guard quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
    }

    /// The section as it now stands, appended to every recipe tool result.
    ///
    /// This is what keeps a tool loop from arguing with itself. The recipe in the system prompt is
    /// a snapshot from when the user's message arrived, so mid-turn it still says "none written
    /// down yet" while the model has already recorded three ingredients — and a model reading that
    /// contradiction records them again. Whatever else a result says, it ends with the truth.
    private static func currentList(_ label: String, _ lines: [String], numbered: Bool) -> String {
        guard !lines.isEmpty else { return "\(label) now: none." }
        let body = numbered
            ? lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; ")
            : lines.joined(separator: "; ")
        return "\(label) now: \(body)."
    }

    /// The entries reordered so that anything written as a bare position comes last, highest
    /// first. Removing step 2 renumbers everything below it, so a batch of numbers applied in the
    /// order given takes out the wrong lines after the first one. Quotes are unaffected by
    /// renumbering and keep their order.
    private static func numberedLast(_ entries: [String]) -> [String] {
        func position(_ entry: String) -> Int? {
            let digits = entry.lowercased()
                .replacingOccurrences(of: "step", with: "")
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(digits)
        }
        let quotes = entries.filter { position($0) == nil }
        let numbers = entries.filter { position($0) != nil }
            .sorted { (position($0) ?? 0) > (position($1) ?? 0) }
        return quotes + numbers
    }
}
