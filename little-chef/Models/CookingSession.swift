//
//  CookingSession.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/12/25.
//

import Foundation

// MARK: - Cooking Session

struct CookingSession: Codable, Identifiable {
    var id: UUID { UUID() }

    let recipe: RecipeBase
    var conversationHistory: [Message]
    let userPreferences: UserPreferencesDetailed
    let startedAt: Date

    enum CodingKeys: String, CodingKey {
        case recipe
        case conversationHistory = "conversation_history"
        case userPreferences = "user_preferences"
        case startedAt = "started_at"
    }

    init(recipe: RecipeBase, userPreferences: UserPreferencesDetailed) {
        self.recipe = recipe
        self.conversationHistory = []
        self.userPreferences = userPreferences
        self.startedAt = Date()
    }

    init(recipe: RecipeBase, conversationHistory: [Message], userPreferences: UserPreferencesDetailed, startedAt: Date) {
        self.recipe = recipe
        self.conversationHistory = conversationHistory
        self.userPreferences = userPreferences
        self.startedAt = startedAt
    }
}

// MARK: - Recipe Base

struct RecipeBase: Codable {
    let title: String
    let description: String?
    let servings: Int
    let prepTime: Int?
    let cookTime: Int?
    let ingredients: [String]
    let instructions: [String]
    let tags: [String]
    let sourceUrl: String?
    let cuisineType: String?
    let difficulty: String?

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
}

// MARK: - Timer Status Type

enum TimerStatusType: String, Codable {
    case new, running, paused, ended
}

// MARK: - Message

struct Message: Codable, Identifiable {
    let id: UUID
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp: Date
}

// MARK: - User Preferences

struct UserPreferencesDetailed: Codable {
    let llmModel: String
    let measurementSystem: String
    let dietaryRestrictions: [String]
    let voiceSettings: LocalVoiceSettings

    enum CodingKeys: String, CodingKey {
        case llmModel = "llm_model"
        case measurementSystem = "measurement_system"
        case dietaryRestrictions = "dietary_restrictions"
        case voiceSettings = "voice_settings"
    }

    init() {
        self.llmModel = "bonsai-8b-1bit"
        self.measurementSystem = "imperial"
        self.dietaryRestrictions = []
        self.voiceSettings = LocalVoiceSettings.defaultSettings
    }

    init(from userPreferences: LocalUserPreferences) {
        self.llmModel = "bonsai-8b-1bit"
        self.measurementSystem = userPreferences.measurementSystem
        self.dietaryRestrictions = userPreferences.dietaryRestrictions
        self.voiceSettings = userPreferences.voiceSettings
    }
}
