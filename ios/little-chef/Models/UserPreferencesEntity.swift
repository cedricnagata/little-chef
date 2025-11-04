//
//  UserPreferencesEntity.swift
//  little-chef
//
//  SwiftData model for local user preferences
//

import Foundation
import SwiftData

/// SwiftData model for persisting user preferences locally
@Model
final class UserPreferencesEntity {
    @Attribute(.unique) var id: UUID
    var measurementSystem: String
    var dietaryRestrictions: [String]
    var speechRate: Float
    var voiceIdentifier: String
    var autoSpeakResponses: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        measurementSystem: String = "imperial",
        dietaryRestrictions: [String] = [],
        speechRate: Float = 0.5,
        voiceIdentifier: String = "com.apple.ttsbundle.Samantha-compact",
        autoSpeakResponses: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.measurementSystem = measurementSystem
        self.dietaryRestrictions = dietaryRestrictions
        self.speechRate = speechRate
        self.voiceIdentifier = voiceIdentifier
        self.autoSpeakResponses = autoSpeakResponses
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
            )
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
        autoSpeakResponses: Bool? = nil
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

/// Local user preferences (no LLM model selection - fixed to Llama 3.2)
struct LocalUserPreferences: Codable {
    let measurementSystem: String
    let dietaryRestrictions: [String]
    let voiceSettings: LocalVoiceSettings

    static let defaultPreferences = LocalUserPreferences(
        measurementSystem: "imperial",
        dietaryRestrictions: [],
        voiceSettings: LocalVoiceSettings.defaultSettings
    )
}
