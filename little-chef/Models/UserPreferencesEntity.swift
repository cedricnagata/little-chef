//
//  UserPreferencesEntity.swift
//  little-chef
//
//  The stored form of the user's preferences. Everything else reads them as
//  `LocalUserPreferences`; see Preferences.swift.
//

import Foundation
import SwiftData

/// The user's preferences as SwiftData stores them.
///
/// One row in principle. Stores from the builds that synced through iCloud can hold more, which
/// is why `LocalDataManager.fetchPreferences()` collapses duplicates.
@Model
final class UserPreferencesEntity {
    var id: UUID = UUID()
    var speechRate: Float = 0.5
    /// Empty for automatic. Stores from before 2026-11-13 hold the old Samantha default, which
    /// reads as automatic too (`AVSpeechSynthesisVoice.isAutomatic`).
    var voiceIdentifier: String = ""
    var autoSpeakResponses: Bool = true
    /// What the assistant answers to in wake-word hands-free mode.
    var wakePhrase: String = "hey little chef"
    /// Kokoro voice id used when speaking through the Mac. Ignored on the on-device voice,
    /// which is chosen by `voiceIdentifier` instead.
    var bigBroVoice: String = "af_heart"
    var llmProvider: String = "local"
    var updatedAt: Date = Date()

    // No longer read or written. Kept so existing stores open without a migration. The
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
