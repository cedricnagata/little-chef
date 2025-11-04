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
    let commands: [Command]
    let timerStatus: [TimerStatus]
    var conversationHistory: [Message]
    let userPreferences: UserPreferencesDetailed
    let startedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case recipe
        case commands = "commands"
        case timerStatus = "timer_status"
        case conversationHistory = "conversation_history"
        case userPreferences = "user_preferences"
        case startedAt = "started_at"
    }
    
    init(recipe: RecipeBase, userPreferences: UserPreferencesDetailed) {
        self.recipe = recipe
        self.commands = []
        self.timerStatus = []
        self.conversationHistory = []
        self.userPreferences = userPreferences
        self.startedAt = Date()
    }
    
    init(recipe: RecipeBase, commands: [Command], timerStatus: [TimerStatus], conversationHistory: [Message], userPreferences: UserPreferencesDetailed, startedAt: Date) {
        self.recipe = recipe
        self.commands = commands
        self.timerStatus = timerStatus
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

// Helper for flexible JSON encoding/decoding
struct FlexibleValue: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else {
            throw DecodingError.typeMismatch(FlexibleValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let stringValue = value as? String {
            try container.encode(stringValue)
        } else if let intValue = value as? Int {
            try container.encode(intValue)
        } else if let doubleValue = value as? Double {
            try container.encode(doubleValue)
        } else if let boolValue = value as? Bool {
            try container.encode(boolValue)
        } else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

struct Command: Codable, Identifiable {
    let id: String
    let commandType: String
    let action: String
    let targetId: String?
    let label: String
    let parameters: [String: FlexibleValue]
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
    let voiceSettings: LocalVoiceSettings

    enum CodingKeys: String, CodingKey {
        case llmModel = "llm_model"
        case measurementSystem = "measurement_system"
        case dietaryRestrictions = "dietary_restrictions"
        case voiceSettings = "voice_settings"
    }

    init() {
        self.llmModel = "llama-3.2-3b-4bit"
        self.measurementSystem = "imperial"
        self.dietaryRestrictions = []
        self.voiceSettings = LocalVoiceSettings.defaultSettings
    }

    init(from userPreferences: LocalUserPreferences) {
        self.llmModel = "llama-3.2-3b-4bit"
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
    
    enum CodingKeys: String, CodingKey {
        case response
        case updatedSession = "updated_session"
    }
}
