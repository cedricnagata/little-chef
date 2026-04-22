//
//  UserPreferencesEntity.swift
//  little-chef
//
//  SwiftData model for local user preferences
//

import Foundation
import SwiftData

/// Which LLM provider to use for all inference
enum LLMProvider: String, Codable, CaseIterable {
    case local = "local"
    case bigBro = "bigbro"

    var displayName: String {
        switch self {
        case .local: return "On-Device"
        case .bigBro: return "BigBro"
        }
    }
}

/// Which on-device model to use for cooking assistance
enum CookingModelChoice: String, Codable, CaseIterable {
    case bonsai8B = "bonsai8b"
    case bonsai4B = "bonsai4b"

    var displayName: String {
        switch self {
        case .bonsai8B: return "Bonsai 8B (1-bit)"
        case .bonsai4B: return "Bonsai 4B (1-bit)"
        }
    }

    var modelId: String {
        switch self {
        case .bonsai8B: return "prism-ml/Bonsai-8B-mlx-1bit"
        case .bonsai4B: return "prism-ml/Bonsai-4B-mlx-1bit"
        }
    }

    var supportsTools: Bool {
        switch self {
        case .bonsai8B: return true
        case .bonsai4B: return false
        }
    }
}

/// SwiftData model for persisting user preferences locally
@Model
final class UserPreferencesEntity {
    var id: UUID = UUID()
    var measurementSystem: String = "imperial"
    var dietaryRestrictions: [String] = []
    var speechRate: Float = 0.5
    var voiceIdentifier: String = "com.apple.ttsbundle.Samantha-compact"
    var autoSpeakResponses: Bool = true
    var cookingModel: String = "bonsai8b"
    var llmProvider: String = "local"
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        measurementSystem: String = "imperial",
        dietaryRestrictions: [String] = [],
        speechRate: Float = 0.5,
        voiceIdentifier: String = "com.apple.ttsbundle.Samantha-compact",
        autoSpeakResponses: Bool = true,
        cookingModel: String = "bonsai8b",
        llmProvider: String = "local",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.measurementSystem = measurementSystem
        self.dietaryRestrictions = dietaryRestrictions
        self.speechRate = speechRate
        self.voiceIdentifier = voiceIdentifier
        self.autoSpeakResponses = autoSpeakResponses
        self.cookingModel = cookingModel
        self.llmProvider = llmProvider
        self.updatedAt = updatedAt
    }

    // MARK: - Conversion Methods

    /// Convert to UserPreferences struct for compatibility
    func toUserPreferences() -> LocalUserPreferences {
        return LocalUserPreferences(
            measurementSystem: measurementSystem,
            dietaryRestrictions: dietaryRestrictions,
            voiceSettings: LocalVoiceSettings(
                speechRate: speechRate,
                voiceIdentifier: voiceIdentifier,
                autoSpeakResponses: autoSpeakResponses
            ),
            cookingModel: CookingModelChoice(rawValue: cookingModel) ?? .bonsai8B,
            llmProvider: LLMProvider(rawValue: llmProvider) ?? .local
        )
    }

    /// Create default preferences
    static func createDefault() -> UserPreferencesEntity {
        return UserPreferencesEntity()
    }

    /// Update preferences
    func update(
        measurementSystem: String? = nil,
        dietaryRestrictions: [String]? = nil,
        speechRate: Float? = nil,
        voiceIdentifier: String? = nil,
        autoSpeakResponses: Bool? = nil,
        cookingModel: CookingModelChoice? = nil,
        llmProvider: LLMProvider? = nil
    ) {
        if let measurementSystem = measurementSystem {
            self.measurementSystem = measurementSystem
        }
        if let dietaryRestrictions = dietaryRestrictions {
            self.dietaryRestrictions = dietaryRestrictions
        }
        if let speechRate = speechRate {
            self.speechRate = speechRate
        }
        if let voiceIdentifier = voiceIdentifier {
            self.voiceIdentifier = voiceIdentifier
        }
        if let autoSpeakResponses = autoSpeakResponses {
            self.autoSpeakResponses = autoSpeakResponses
        }
        if let cookingModel = cookingModel {
            self.cookingModel = cookingModel.rawValue
        }
        if let llmProvider = llmProvider {
            self.llmProvider = llmProvider.rawValue
        }
        self.updatedAt = Date()
    }
}

// MARK: - Local Preferences Models (without backend dependency)

/// Local voice settings (simplified - no ElevenLabs)
struct LocalVoiceSettings: Codable, Equatable {
    let speechRate: Float
    let voiceIdentifier: String
    let autoSpeakResponses: Bool

    static let defaultSettings = LocalVoiceSettings(
        speechRate: 0.5,
        voiceIdentifier: "com.apple.ttsbundle.Samantha-compact",
        autoSpeakResponses: true
    )
}

/// Local user preferences
struct LocalUserPreferences: Codable {
    let measurementSystem: String
    let dietaryRestrictions: [String]
    let voiceSettings: LocalVoiceSettings
    let cookingModel: CookingModelChoice
    let llmProvider: LLMProvider

    static let defaultPreferences = LocalUserPreferences(
        measurementSystem: "imperial",
        dietaryRestrictions: [],
        voiceSettings: LocalVoiceSettings.defaultSettings,
        cookingModel: .bonsai8B,
        llmProvider: .local
    )
}
