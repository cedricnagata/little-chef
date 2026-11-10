//
//  LegacyTools.swift
//  bonsai-check
//
//  Build 65's twelve cooking tools, word for word, so `bonsai-check eval` can score the same
//  questions against them and against the merged five the app has now. Delete once the
//  comparison has nothing left to say (CLAUDE.md, "The cooking tools").
//

enum LegacyTools {
    static let timer: [CookingToolSpec] = [
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

    static let recipe: [CookingToolSpec] = [
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
}
