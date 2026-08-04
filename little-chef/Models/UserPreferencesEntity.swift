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
    case bonsai1_7B = "bonsai1_7b"

    var displayName: String {
        switch self {
        case .bonsai8B: return "Bonsai 8B (1-bit)"
        case .bonsai4B: return "Bonsai 4B (1-bit)"
        case .bonsai1_7B: return "Bonsai 1.7B (1-bit)"
        }
    }

    var modelId: String {
        switch self {
        case .bonsai8B: return "prism-ml/Bonsai-8B-mlx-1bit"
        case .bonsai4B: return "prism-ml/Bonsai-4B-mlx-1bit"
        case .bonsai1_7B: return "prism-ml/Bonsai-1.7B-mlx-1bit"
        }
    }

    var supportsTools: Bool {
        switch self {
        case .bonsai8B: return true
        case .bonsai4B, .bonsai1_7B: return false
        }
    }

    var approximateSize: String {
        switch self {
        case .bonsai8B: return "~3.5 GB"
        case .bonsai4B: return "~1.8 GB"
        case .bonsai1_7B: return "~0.9 GB"
        }
    }

    /// Whether this on-device model supports the full feature set (recipe parsing + timer tools).
    /// Only the 8B model is capable; smaller models run cooking chat only.
    var isFullCapability: Bool {
        self == .bonsai8B
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
    /// Route spoken output through a paired BigBro Mac instead of AVSpeechSynthesizer.
    /// Ignored unless a Mac is actually connected.
    var useBigBroSpeech: Bool = false
    /// What the assistant answers to in wake-word hands-free mode.
    var wakePhrase: String = "hey little chef"
    /// Seconds after an answer during which a follow-up needs no wake phrase. 0 disables.
    var followUpWindow: Double = 8
    /// Kokoro voice id used when speaking through the Mac. Ignored on the on-device voice,
    /// which is chosen by `voiceIdentifier` instead.
    var bigBroVoice: String = "af_heart"
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
        useBigBroSpeech: Bool = false,
        wakePhrase: String = "hey little chef",
        followUpWindow: Double = 8,
        bigBroVoice: String = "af_heart",
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
        self.useBigBroSpeech = useBigBroSpeech
        self.wakePhrase = wakePhrase
        self.followUpWindow = followUpWindow
        self.bigBroVoice = bigBroVoice
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
                autoSpeakResponses: autoSpeakResponses,
                useBigBroSpeech: useBigBroSpeech,
                wakePhrase: wakePhrase,
                followUpWindow: followUpWindow,
                bigBroVoice: bigBroVoice
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
        useBigBroSpeech: Bool? = nil,
        wakePhrase: String? = nil,
        followUpWindow: Double? = nil,
        bigBroVoice: String? = nil,
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
        if let useBigBroSpeech = useBigBroSpeech {
            self.useBigBroSpeech = useBigBroSpeech
        }
        if let wakePhrase = wakePhrase {
            self.wakePhrase = wakePhrase
        }
        if let followUpWindow = followUpWindow {
            self.followUpWindow = followUpWindow
        }
        if let bigBroVoice = bigBroVoice {
            self.bigBroVoice = bigBroVoice
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
    /// Absolute `AVSpeechUtterance.rate` on its 0.0–1.0 scale, where 0.5
    /// (`AVSpeechUtteranceDefaultSpeechRate`) is normal speed — not a multiplier. Settings
    /// displays it as a multiple of normal, so a stored 0.5 shows as "1.0x".
    let speechRate: Float
    let voiceIdentifier: String
    let autoSpeakResponses: Bool
    /// Route spoken output through a paired BigBro Mac. Falls back to `AVSpeechSynthesizer`
    /// whenever no Mac is connected, so this is a preference rather than a hard switch.
    var useBigBroSpeech: Bool = false
    /// What the assistant answers to in wake-word hands-free mode. Free text, because the
    /// whole point is that it is the user's name for it — but a phrase too short to gate on is
    /// refused by `WakeWord` rather than silently matching nothing.
    var wakePhrase: String = "hey little chef"
    /// Seconds after an answer during which a follow-up needs no wake phrase. 0 disables it.
    var followUpWindow: Double = 8
    /// Kokoro voice id for the Mac's synthesizer. Separate from `voiceIdentifier`, which names
    /// an `AVSpeechSynthesisVoice` — the two backends share no vocabulary of voices.
    var bigBroVoice: String = "af_heart"

    static let defaultSettings = LocalVoiceSettings(
        speechRate: 0.5,
        voiceIdentifier: "com.apple.ttsbundle.Samantha-compact",
        autoSpeakResponses: true,
        useBigBroSpeech: false
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
