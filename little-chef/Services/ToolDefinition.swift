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

    /// Inserts at `position` counting from 1, or appends when it is nil or out of range.
    /// Returns false if that ingredient is already listed.
    @discardableResult func addIngredient(_ text: String, at position: Int?) -> Bool
    /// Returns the line that was replaced, or nil if nothing matched.
    func replaceIngredient(matching query: String, with text: String) -> String?
    /// Returns the line that was removed, or nil if nothing matched.
    func removeIngredient(matching query: String) -> String?

    @discardableResult func addStep(_ text: String, at position: Int?) -> Bool
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

    static let recipeToolSpecs: [CookingToolSpec] = [
        CookingToolSpec(
            name: "add_ingredient",
            description: "Add an ingredient to the recipe being cooked. Put the amount in the text itself, e.g. 'two cloves of garlic, minced'.",
            parameters: [
                .init(name: "item", type: "string", description: "The whole ingredient line, amount included", isRequired: true),
                .init(name: "position", type: "integer", description: "Where in the ingredient list it goes, counting from 1. Omit to put it at the end.")
            ]
        ),
        CookingToolSpec(
            name: "update_ingredient",
            description: "Rewrite an ingredient the recipe already lists — a different amount, a substitution. Give enough of the existing line to identify it.",
            parameters: [
                .init(name: "item", type: "string", description: "The ingredient as the recipe lists it now", isRequired: true),
                .init(name: "new_item", type: "string", description: "The whole replacement line, amount included", isRequired: true)
            ]
        ),
        CookingToolSpec(
            name: "remove_ingredient",
            description: "Remove an ingredient from the recipe being cooked",
            parameters: [
                .init(name: "item", type: "string", description: "The ingredient as the recipe lists it now", isRequired: true)
            ]
        ),
        CookingToolSpec(
            name: "add_step",
            description: "Add a step to the recipe's method. Write it as an instruction, e.g. 'Fry the onions until soft, about eight minutes'.",
            parameters: [
                .init(name: "text", type: "string", description: "The step, written as an instruction", isRequired: true),
                .init(name: "position", type: "integer", description: "Which step number it becomes, counting from 1. Omit to put it at the end.")
            ]
        ),
        CookingToolSpec(
            name: "update_step",
            description: "Rewrite one of the recipe's steps",
            parameters: [
                .init(name: "step", type: "string", description: "The step number, or a quote from the step as it reads now", isRequired: true),
                .init(name: "new_text", type: "string", description: "The whole replacement step", isRequired: true)
            ]
        ),
        CookingToolSpec(
            name: "remove_step",
            description: "Remove one of the recipe's steps",
            parameters: [
                .init(name: "step", type: "string", description: "The step number, or a quote from the step as it reads now", isRequired: true)
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

    /// Execute a tool by name with the given arguments
    @MainActor
    func execute(toolName: String, arguments: [String: Any]) -> String {
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

        // The recipe tools below all end in the session's working copy, never the store — see
        // `RecipeEditing`. Their results say so, because a model that thinks it just saved the
        // recipe tells the user their change is safe, and it isn't until they say so on the way
        // out.
        case "add_ingredient":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            guard let item = string(arguments["item"]) ?? string(arguments["ingredient"]) ?? string(arguments["name"]) else {
                return "Error: missing 'item'"
            }
            guard editor.addIngredient(item, at: optionalInt(arguments["position"])) else {
                return "'\(item)' is already in the ingredients — use update_ingredient to change it."
            }
            return "Added '\(item)' to the ingredients."

        case "update_ingredient":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            guard let item = string(arguments["item"]) ?? string(arguments["ingredient"]) else {
                return "Error: missing 'item'"
            }
            guard let replacement = string(arguments["new_item"]) ?? string(arguments["newItem"]) ?? string(arguments["new_text"]) else {
                return "Error: missing 'new_item'"
            }
            guard let previous = editor.replaceIngredient(matching: item, with: replacement) else {
                return "No ingredient matching '\(item)' is in this recipe. "
                     + "Use add_ingredient if it should be."
            }
            return "Changed '\(previous)' to '\(replacement)'."

        case "remove_ingredient":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            guard let item = string(arguments["item"]) ?? string(arguments["ingredient"]) ?? string(arguments["name"]) else {
                return "Error: missing 'item'"
            }
            guard let removed = editor.removeIngredient(matching: item) else {
                return "No ingredient matching '\(item)' is in this recipe."
            }
            return "Removed '\(removed)' from the ingredients."

        case "add_step":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            guard let text = string(arguments["text"]) ?? string(arguments["step"]) ?? string(arguments["instruction"]) else {
                return "Error: missing 'text'"
            }
            guard editor.addStep(text, at: optionalInt(arguments["position"])) else {
                return "That step is already in the method."
            }
            return "Added the step '\(text)'."

        case "update_step":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            guard let step = string(arguments["step"]) ?? string(arguments["text"]) else {
                return "Error: missing 'step'"
            }
            guard let replacement = string(arguments["new_text"]) ?? string(arguments["newText"]) ?? string(arguments["new_step"]) else {
                return "Error: missing 'new_text'"
            }
            guard let previous = editor.replaceStep(matching: step, with: replacement) else {
                return "No step matching '\(step)' is in this recipe. Use add_step if it should be."
            }
            return "Changed the step '\(previous)' to '\(replacement)'."

        case "remove_step":
            guard let editor = recipeEditor else { return Self.noRecipeToEdit }
            guard let step = string(arguments["step"]) ?? string(arguments["text"]) else {
                return "Error: missing 'step'"
            }
            guard let removed = editor.removeStep(matching: step) else {
                return "No step matching '\(step)' is in this recipe."
            }
            return "Removed the step '\(removed)'."

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
                return "Nothing changed — give at least one detail to set."
            }
            return applied.joined(separator: " ")

        default:
            return "Unknown tool: \(toolName)"
        }
    }

    private static let noRecipeToEdit =
        "There is no recipe open to edit in this session."

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
}
