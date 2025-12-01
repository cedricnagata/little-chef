//
//  UserPreferences.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import Foundation

// MARK: - Voice Settings Models
struct ElevenLabsSettings: Codable, Equatable {
    let enabled: Bool
    let voiceName: String
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case voiceName = "voice_name"
    }
    
    static let defaultSettings = ElevenLabsSettings(
        enabled: false,
        voiceName: "Rachel - calm"
    )
}

struct VoiceSettings: Codable, Equatable {
    let speechRate: Float
    let voiceIdentifier: String
    let autoSpeakResponses: Bool
    let elevenlabs: ElevenLabsSettings
    
    enum CodingKeys: String, CodingKey {
        case speechRate = "speech_rate"
        case voiceIdentifier = "voice_identifier"
        case autoSpeakResponses = "auto_speak_responses"
        case elevenlabs
    }
    
    static let defaultSettings = VoiceSettings(
        speechRate: 0.5,
        voiceIdentifier: "com.apple.ttsbundle.Samantha-compact",
        autoSpeakResponses: true,
        elevenlabs: ElevenLabsSettings.defaultSettings
    )
}

struct UserPreferences: Codable {
    var llmModel: String
    var measurementSystem: String
    var dietaryRestrictions: [String]
    var voiceSettings: VoiceSettings

    enum CodingKeys: String, CodingKey {
        case llmModel = "llm_model"
        case measurementSystem = "measurement_system"
        case dietaryRestrictions = "dietary_restrictions"
        case voiceSettings = "voice_settings"
    }

    init() {
        self.llmModel = "gpt-4.1-mini"
        self.measurementSystem = "imperial"
        self.dietaryRestrictions = []
        self.voiceSettings = VoiceSettings.defaultSettings
    }

    init(llmModel: String, measurementSystem: String, dietaryRestrictions: [String], voiceSettings: VoiceSettings) {
        self.llmModel = llmModel
        self.measurementSystem = measurementSystem
        self.dietaryRestrictions = dietaryRestrictions
        self.voiceSettings = voiceSettings
    }

    static let defaultPreferences = UserPreferences(
        llmModel: "gpt-4.1-mini",
        measurementSystem: "imperial",
        dietaryRestrictions: [],
        voiceSettings: VoiceSettings.defaultSettings
    )
}
