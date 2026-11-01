//
//  UserPreferencesEntity.swift
//  little-chef
//
//  The stored, iCloud-synced form of the user's preferences. Everything else reads them as
//  `LocalUserPreferences`; see Preferences.swift.
//

import Foundation
import SwiftData

/// The user's preferences as SwiftData stores them, mirrored to iCloud.
///
/// One row per user in principle; CloudKit can't enforce that, which is why
/// `LocalDataManager.fetchPreferences()` collapses duplicates.
@Model
final class UserPreferencesEntity {
    var id: UUID = UUID()
    var speechRate: Float = 0.5
    var voiceIdentifier: String = "com.apple.ttsbundle.Samantha-compact"
    var autoSpeakResponses: Bool = true
    /// What the assistant answers to in wake-word hands-free mode.
    var wakePhrase: String = "hey little chef"
    /// Kokoro voice id used when speaking through the Mac. Ignored on the on-device voice,
    /// which is chosen by `voiceIdentifier` instead.
    var bigBroVoice: String = "af_heart"
    var llmProvider: String = "local"
    var updatedAt: Date = Date()

    // No longer read or written. Kept because they are fields of a mirrored model: removing
    // them changes the CloudKit schema for every installed copy, for no benefit. The
    // on-device model is now a per-device choice (`LLMService.preferredOnDeviceModel`), and
    // speaking through the Mac follows the provider.
    var measurementSystem: String = "imperial"
    var dietaryRestrictions: [String] = []
    var useBigBroSpeech: Bool = false
    var cookingModel: String = "bonsai8b"

    init() {}

    func toUserPreferences() -> LocalUserPreferences {
        LocalUserPreferences(
            voiceSettings: LocalVoiceSettings(
                speechRate: speechRate,
                voiceIdentifier: voiceIdentifier,
                autoSpeakResponses: autoSpeakResponses,
                wakePhrase: wakePhrase,
                bigBroVoice: bigBroVoice
            ),
            llmProvider: LLMProvider(rawValue: llmProvider) ?? .local
        )
    }

    func update(voiceSettings: LocalVoiceSettings, llmProvider: LLMProvider) {
        speechRate = voiceSettings.speechRate
        voiceIdentifier = voiceSettings.voiceIdentifier
        autoSpeakResponses = voiceSettings.autoSpeakResponses
        wakePhrase = voiceSettings.wakePhrase
        bigBroVoice = voiceSettings.bigBroVoice
        self.llmProvider = llmProvider.rawValue
        updatedAt = Date()
    }
}
