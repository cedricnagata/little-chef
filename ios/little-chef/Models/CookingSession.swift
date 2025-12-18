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
    let id: UUID

    let recipe: RecipeBase
    let commands: [Command]
    let timerStatus: [TimerStatus]
    let conversationHistory: [Message]
    let userPreferences: UserPreferencesDetailed
    let startedAt: Date

    enum CodingKeys: String, CodingKey {
        case recipe
        case commands = "commands"
        case timerStatus = "timer_status"
        case conversationHistory = "conversation_history"
        case userPreferences = "user_preferences"
        case startedAt = "started_at"
        // id is intentionally excluded from encoding/decoding
    }

    init(recipe: RecipeBase, userPreferences: UserPreferencesDetailed) {
        self.id = UUID()
        self.recipe = recipe
        self.commands = []
        self.timerStatus = []
        self.conversationHistory = []
        self.userPreferences = userPreferences
        self.startedAt = Date()
    }

    init(recipe: RecipeBase, commands: [Command], timerStatus: [TimerStatus], conversationHistory: [Message], userPreferences: UserPreferencesDetailed, startedAt: Date) {
        self.id = UUID()
        self.recipe = recipe
        self.commands = commands
        self.timerStatus = timerStatus
        self.conversationHistory = conversationHistory
        self.userPreferences = userPreferences
        self.startedAt = startedAt
    }

    // Manual Codable implementation because id is excluded from CodingKeys
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()  // Generate new ID when decoding
        self.recipe = try container.decode(RecipeBase.self, forKey: .recipe)
        self.commands = try container.decode([Command].self, forKey: .commands)
        self.timerStatus = try container.decode([TimerStatus].self, forKey: .timerStatus)
        self.conversationHistory = try container.decode([Message].self, forKey: .conversationHistory)
        self.userPreferences = try container.decode(UserPreferencesDetailed.self, forKey: .userPreferences)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recipe, forKey: .recipe)
        try container.encode(commands, forKey: .commands)
        try container.encode(timerStatus, forKey: .timerStatus)
        try container.encode(conversationHistory, forKey: .conversationHistory)
        try container.encode(userPreferences, forKey: .userPreferences)
        try container.encode(startedAt, forKey: .startedAt)
        // id is intentionally not encoded
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
    
    // Memberwise initializer
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

struct Command: Codable, Identifiable {
    let id: String
    let commandType: String
    let action: String
    let targetId: String?
    let label: String
    let parameters: [String: AnyCodable]
    let createdAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, action, label, parameters
        case commandType = "command_type"
        case targetId = "target_id"
        case createdAt = "created_at"
    }
}

// Legacy alias for backward compatibility during transition
typealias TimerCommand = Command

struct TimerStatus: Codable, Identifiable {
    let id: String
    let label: String
    let durationSeconds: Int
    let status: TimerStatusType
    let remainingSeconds: Int
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id, label, status
        case durationSeconds = "duration_seconds"
        case remainingSeconds = "remaining_seconds"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

enum TimerAction: String, Codable {
    case add, start, stop, pause, resume, remove
}

enum TimerStatusType: String, Codable {
    case pending, running, paused, completed, stopped
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
        self.voiceSettings = VoiceSettings.defaultSettings
    }
    
    init(from userPreferences: UserPreferences) {
        self.llmModel = userPreferences.llmModel
        self.measurementSystem = userPreferences.measurementSystem
        self.dietaryRestrictions = userPreferences.dietaryRestrictions
        self.voiceSettings = userPreferences.voiceSettings
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
    let audio: String?  // Base64 encoded MP3 audio (if server TTS enabled)

    enum CodingKeys: String, CodingKey {
        case response
        case updatedSession = "updated_session"
        case audio
    }
}
