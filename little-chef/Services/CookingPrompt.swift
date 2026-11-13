//
//  CookingPrompt.swift
//  little-chef
//
//  What the cooking assistant is told: its instructions, the recipe, the kitchen, the timers.
//  Foundation only, so the app, the Linux tests and tools/bonsai-check all build the same prompt.
//

import Foundation

/// The system prompt for one cook, and the note that rides on each question.
///
/// Every token here is read before the first answer of a cook (and on a phone that read is most
/// of the wait), so each rule is here only where nothing else does its job:
///  - The phone's voices get the text through `SpokenText`, which writes out "tbsp", "350°F" and
///    "1/2" itself. Hands-free on the Mac speaks the Mac's own text with no such pass, so BigBro
///    still gets the rules spelled out.
///  - Timers: "created, not started" is in create_timer's description and its result, and
///    `ToolLoopGuard` refuses a start in the same turn.
struct CookingPrompt {
    /// What the assistant may do to the recipe.
    enum Editing {
        /// No recipe tools: nothing to edit, or a model that can't call tools.
        case none
        /// Following a recipe: record what the user changes, and nothing else.
        case following
        /// A cook that started without a recipe: write it down as the user goes.
        case writing
    }

    /// What the inventory says about the recipe, worked out by `IngredientMatcher` when the cook
    /// starts. Nil when the user keeps no inventory, so the assistant doesn't claim they have
    /// nothing.
    struct Kitchen: Equatable {
        /// What the recipe needs and the inventory doesn't list, as names to shop for.
        var missing: [String]
    }

    var provider: LLMProvider
    var recipe: Recipe?
    var editing: Editing
    var kitchen: Kitchen?

    var system: String {
        // Short answers are most of a quick reply on a phone: each sentence is generated, then
        // read out, while the cook waits with their hands full.
        var prompt = "You are LittleChef, a cooking assistant. The user is cooking right now. "
            + "Answer in one to three short sentences unless they ask for more detail."
            // Both on-device models answered "can I use olive oil instead of the cream?" with
            // "yes, I'll record that", and called milk for cream a plain yes (eval, 2026-11-13).
            + " When they ask whether a swap or change would work, answer as an experienced cook:"
            + " say honestly whether it works and how it changes the dish, and steer them off a bad idea."

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

        prompt += editingInstructions

        if let recipe {
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
                for ingredient in recipe.ingredients { prompt += "\n- \(ingredient)" }
            }

            if recipe.instructions.isEmpty {
                prompt += "\n\nSteps: none written down yet"
            } else {
                prompt += "\n\nSteps:"
                for (i, step) in recipe.instructions.enumerated() { prompt += "\n\(i + 1). \(step)" }
            }
        }

        if let kitchen, let recipe, !recipe.ingredients.isEmpty {
            prompt += kitchen.missing.isEmpty
                ? "\n\nKitchen: the user's inventory has every ingredient."
                : "\n\nKitchen: the user's inventory doesn't have \(Self.list(kitchen.missing)). It has everything else."
        }

        return prompt
    }

    /// The timers as they stand, or nothing when there are none.
    ///
    /// Rides on the question rather than in the system prompt: timers change by the second, and a
    /// system prompt that changed every turn would be read from scratch every turn.
    static func timersNote(_ timers: [LocalTimer]) -> String {
        guard !timers.isEmpty else { return "" }
        var note = "\n\nActive timers:"
        for timer in timers {
            let state = timer.status == .new ? "created, not started yet" : timer.status.rawValue
            note += "\n- \(timer.label): \(state), \(SpokenDuration.text(seconds: timer.remainingSeconds)) left"
        }
        return note
    }

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// How to use the recipe tools, which differs entirely depending on whether there is a recipe.
    ///
    /// Following one, editing it is a thing you do when told to and not otherwise: a model that
    /// rewrites the recipe every time it suggests something turns its own advice into the user's
    /// recorded method. Writing one from nothing, the opposite — the whole point of the cook is
    /// that the recipe ends up written down, and a model waiting to be asked writes nothing.
    private var editingInstructions: String {
        switch editing {
        case .none:
            return ""
        case .writing:
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
        case .following:
            return """


                The user may cook the recipe differently from how it reads. When they tell you they \
                changed something — a different amount, an extra ingredient, a step they skipped or \
                did another way — record it with update_ingredients, add_ingredients, \
                remove_ingredients, update_steps, add_steps or remove_steps. Only record what the \
                user actually did or asked you to change; never edit the recipe to match a \
                suggestion of your own, and never edit it because they asked a question about it, \
                such as whether a swap would work. \
                Nothing you record is saved — they are shown every change when the cook ends and \
                choose then whether to keep it — so do not tell them the recipe has been updated \
                or saved.
                """ + batchingInstructions
        }
    }

    /// How to spend tool calls, which matters more than it looks.
    ///
    /// The recipe tools take lists, and a model that calls them one line at a time turns "eggs,
    /// flour and milk" into three round trips on the Mac, each another chance to lose track of
    /// what it has already recorded. The rest is about reading tool results, which only the
    /// Mac's tool loop does: the phone runs every call from one reply and answers with the
    /// results, so it gets the first rule alone.
    private var batchingInstructions: String {
        guard provider == .bigBro else {
            return "\n\nRecord everything from one message in a single call per tool, one item per line."
        }
        return """


            Record everything from one message in a single call per tool: every ingredient in one \
            add_ingredients call, one per line, and every step in one add_steps call. Never call \
            the same tool twice in a row. Each result ends with the list as it now stands — trust \
            that over the recipe printed below, which is a snapshot from before your edits. When a \
            result says a line was already there, it is recorded and there is nothing left to do: \
            do not send it again. Once you have recorded what the user said, answer them in words.
            """
    }
}
