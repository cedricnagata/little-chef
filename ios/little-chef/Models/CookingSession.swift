//
//  CookingSession.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/12/25.
//

import Foundation

// MARK: - Cooking Session Models

struct CookingSession: Codable, Identifiable {
    // Local-only ID for SwiftUI, not sent to backend
    var id: UUID { UUID() }
    
    let recipe: RecipeBase
    let modifications: RecipeModifications
    let activeTimers: [Timer]
    let conversationHistory: [Message]
    let userPreferences: UserPreferencesDetailed
    let startedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case recipe, modifications
        case userPreferences = "user_preferences"
        case activeTimers = "active_timers"
        case conversationHistory = "conversation_history"
        case startedAt = "started_at"
    }
    
    init(recipe: RecipeBase, userPreferences: UserPreferencesDetailed) {
        self.recipe = recipe
        self.modifications = RecipeModifications()
        self.activeTimers = []
        self.conversationHistory = []
        self.userPreferences = userPreferences
        self.startedAt = Date()
    }
    
    init(recipe: RecipeBase, modifications: RecipeModifications, activeTimers: [Timer], conversationHistory: [Message], userPreferences: UserPreferencesDetailed, startedAt: Date) {
        self.recipe = recipe
        self.modifications = modifications
        self.activeTimers = activeTimers
        self.conversationHistory = conversationHistory
        self.userPreferences = userPreferences
        self.startedAt = startedAt
    }
}

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
    
    // Convert from existing Recipe model
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

struct RecipeModifications: Codable {
    let servingMultiplier: Float
    let ingredientSubstitutions: [String: String]
    let notes: [String]
    
    enum CodingKeys: String, CodingKey {
        case servingMultiplier = "serving_multiplier"
        case ingredientSubstitutions = "ingredient_substitutions"
        case notes
    }
    
    init() {
        self.servingMultiplier = 1.0
        self.ingredientSubstitutions = [:]
        self.notes = []
    }
    
    init(servingMultiplier: Float, ingredientSubstitutions: [String: String] = [:], notes: [String] = []) {
        self.servingMultiplier = servingMultiplier
        self.ingredientSubstitutions = ingredientSubstitutions
        self.notes = notes
    }
}

struct Timer: Codable, Identifiable {
    let id: UUID
    let label: String
    let durationSeconds: Int
    let remainingSeconds: Int
    let isActive: Bool
    let createdAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, label, isActive
        case durationSeconds = "duration_seconds"
        case remainingSeconds = "remaining_seconds"
        case createdAt = "created_at"
    }
}

struct Message: Codable, Identifiable {
    let id: UUID
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp: Date
}

struct UserPreferencesDetailed: Codable {
    let llmModel: String
    let measurementSystem: String
    let dietaryRestrictions: [String]
    let voiceSettings: VoiceSettings
    
    enum CodingKeys: String, CodingKey {
        case llmModel = "llm_model"
        case measurementSystem = "measurement_system"
        case dietaryRestrictions = "dietary_restrictions"
        case voiceSettings = "voice_settings"
    }
    
    init() {
        self.llmModel = "gpt-5-mini"
        self.measurementSystem = "imperial"
        self.dietaryRestrictions = []
        self.voiceSettings = VoiceSettings()
    }
}

struct VoiceSettings: Codable {
    let speechRate: Float
    let voiceIdentifier: String
    let autoSpeakResponses: Bool
    
    enum CodingKeys: String, CodingKey {
        case speechRate = "speech_rate"
        case voiceIdentifier = "voice_identifier"
        case autoSpeakResponses = "auto_speak_responses"
    }
    
    init() {
        self.speechRate = 0.5
        self.voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
        self.autoSpeakResponses = true
    }
}

// MARK: - Agent Communication Models

struct AgentQueryRequest: Codable {
    let cookingSession: CookingSession
    let query: String
    
    enum CodingKeys: String, CodingKey {
        case cookingSession = "cooking_session"
        case query
    }
}

struct AgentQueryResponse: Codable {
    let response: String
    let updatedSession: CookingSession
    let suggestedActions: [SuggestedAction]
    
    enum CodingKeys: String, CodingKey {
        case response
        case updatedSession = "updated_session"
        case suggestedActions = "suggested_actions"
    }
}

struct SuggestedAction: Codable {
    let type: String
    let description: String
}
