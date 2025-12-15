//
//  UserPreferences.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import Foundation

// MARK: - Voice Settings Models

enum TTSProvider: String, Codable {
    case polly = "polly"
    case device = "device"
    case disabled = "disabled"
}

struct VoiceSettings: Codable, Equatable {
    let ttsProvider: TTSProvider
    let voiceId: String?
    let speechRate: Float
    let voiceIdentifier: String
    let autoSpeakResponses: Bool

    enum CodingKeys: String, CodingKey {
        case ttsProvider = "tts_provider"
        case voiceId = "voice_id"
        case speechRate = "speech_rate"
        case voiceIdentifier = "voice_identifier"
        case autoSpeakResponses = "auto_speak_responses"
    }

    static let defaultSettings = VoiceSettings(
        ttsProvider: .polly,
        voiceId: "Joanna",
        speechRate: 0.5,
        voiceIdentifier: "com.apple.ttsbundle.Samantha-compact",
        autoSpeakResponses: true
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
