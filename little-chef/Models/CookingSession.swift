//
//  CookingSession.swift
//  little-chef
//
//  A cook in progress: the recipe being cooked, the conversation about it, and the
//  baseline that saving would be measured against.
//

import Foundation

// MARK: - Cooking Session

struct CookingSession: Codable, Identifiable {
    var id = UUID()

    /// The stored recipe this cook started from, or nil when it started without one and the
    /// recipe is being written as the cook goes.
    ///
    /// Also the answer to "save or save as": a cook that began from a recipe writes back to it,
    /// a cook that began from nothing becomes a new one.
    let sourceRecipeID: UUID?

    /// The recipe as it currently stands — what the pane shows, what the assistant is briefed on
    /// each turn, and what gets written back if the user keeps their changes.
    var recipe: RecipeBase

    /// The same recipe as saving it would be a no-op against, at the servings now on screen.
    ///
    /// The yardstick for "has anything actually changed", and it moves with the servings stepper
    /// on purpose. Scaling rewrites every ingredient line, so a baseline frozen at the starting
    /// servings would read a serving nudge as a dozen edited ingredients and put a save prompt in
    /// front of someone who changed nothing. Both sides go through the same arithmetic, so a pure
    /// scale cancels out, while an edit made either side of one still stands out.
    var baselineRecipe: RecipeBase

    var conversationHistory: [Message]
    /// The voice settings in force when the cook started. Settings pushes later changes to the
    /// voice assistant directly, so this is only the starting point.
    let voiceSettings: LocalVoiceSettings
    /// What the recipe served when the cook started, so the servings control can show when it
    /// has been changed. `recipe` and `baselineRecipe` both move with the control, so neither
    /// can answer that.
    let startingServings: Int
    let startedAt: Date

    /// Whether this cook is writing a recipe rather than following one.
    var isBuildingNewRecipe: Bool { sourceRecipeID == nil }

    enum CodingKeys: String, CodingKey {
        case id, recipe
        case sourceRecipeID = "source_recipe_id"
        case baselineRecipe = "baseline_recipe"
        case conversationHistory = "conversation_history"
        case voiceSettings = "voice_settings"
        case startingServings = "starting_servings"
        case startedAt = "started_at"
    }

    init(sourceRecipeID: UUID?, recipe: RecipeBase, voiceSettings: LocalVoiceSettings) {
        self.sourceRecipeID = sourceRecipeID
        self.recipe = recipe
        self.baselineRecipe = recipe
        self.conversationHistory = []
        self.voiceSettings = voiceSettings
        self.startingServings = recipe.servings
        self.startedAt = Date()
    }
}

// MARK: - Recipe Base

/// A recipe as a cooking session holds it.
///
/// Fields are `var` because the session's copy is edited in place while the cook runs — by the
/// servings stepper, and by the assistant's recipe tools. Nothing here reaches the store until
/// the user ends the session and says to keep it.
struct RecipeBase: Codable, Equatable {
    var title: String
    var description: String?
    var servings: Int
    var prepTime: Int?
    var cookTime: Int?
    var ingredients: [String]
    var instructions: [String]
    var tags: [String]
    var sourceUrl: String?
    var cuisineType: String?
    var difficulty: String?

    enum CodingKeys: String, CodingKey {
        case title, description, servings, ingredients, instructions, tags, difficulty
        case prepTime = "prep_time"
        case cookTime = "cook_time"
        case sourceUrl = "source_url"
        case cuisineType = "cuisine_type"
    }

    init(title: String, description: String?, servings: Int, prepTime: Int?, cookTime: Int?, ingredients: [String], instructions: [String], tags: [String], sourceUrl: String?, cuisineType: String?, difficulty: String?) {
        self.title = title
        self.description = description
        self.servings = servings
        self.prepTime = prepTime
        self.cookTime = cookTime
        self.ingredients = ingredients
        self.instructions = instructions
        self.tags = tags
        self.sourceUrl = sourceUrl
        self.cuisineType = cuisineType
        self.difficulty = difficulty
    }

    init(from recipe: Recipe) {
        self.title = recipe.title
        self.description = recipe.description
        self.servings = recipe.servings
        self.prepTime = recipe.prepTime
        self.cookTime = recipe.cookTime
        self.ingredients = recipe.ingredients
        self.instructions = recipe.instructions
        self.tags = recipe.tags
        self.sourceUrl = recipe.sourceUrl
        self.cuisineType = recipe.cuisineType
        self.difficulty = recipe.difficulty
    }

    /// A blank recipe, for a cook that starts without one.
    static func blank() -> RecipeBase {
        RecipeBase(
            title: "",
            description: nil,
            servings: 4,
            prepTime: nil,
            cookTime: nil,
            ingredients: [],
            instructions: [],
            tags: [],
            sourceUrl: nil,
            cuisineType: nil,
            difficulty: nil
        )
    }

    /// What to put in the header before the recipe has a name of its own.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Recipe" : trimmed
    }

    /// Whether anything has been written down yet. A blank recipe is not worth offering to save.
    var hasContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !ingredients.isEmpty
            || !instructions.isEmpty
    }

    /// The form the store takes. `title` is overridable because a recipe written during a cook is
    /// named on the way out, in the sheet that offers to save it.
    func toRecipeData(overridingTitle newTitle: String? = nil) -> RecipeData {
        RecipeData(
            title: (newTitle ?? title).trimmingCharacters(in: .whitespacesAndNewlines),
            description: description,
            servings: servings,
            prepTime: prepTime,
            cookTime: cookTime,
            ingredients: ingredients,
            instructions: instructions,
            tags: tags,
            sourceUrl: sourceUrl,
            cuisineType: cuisineType,
            difficulty: difficulty
        )
    }
}

// MARK: - Message

/// One turn of the cooking conversation, as the transcript shows it.
struct Message: Codable, Identifiable {
    let id: UUID
    /// "user" or "assistant".
    let role: String
    let content: String
    let timestamp: Date

    var isUser: Bool { role == "user" }
}
