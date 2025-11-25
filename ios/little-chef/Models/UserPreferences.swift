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

// MARK: - AnyCodable for flexible JSON handling
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map { $0.value }
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues { $0.value }
        } else {
            throw DecodingError.typeMismatch(AnyCodable.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let arrayValue as [Any]:
            try container.encode(arrayValue.map { AnyCodable($0) })
        case let dictValue as [String: Any]:
            try container.encode(dictValue.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}
