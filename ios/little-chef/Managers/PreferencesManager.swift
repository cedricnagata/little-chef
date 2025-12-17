//
//  PreferencesManager.swift
//  little-chef
//
//  Manages user preferences locally using UserDefaults
//

import Foundation
import Combine

class PreferencesManager: ObservableObject {
    @Published var preferences: UserPreferences

    private let defaults = UserDefaults.standard
    private let preferencesKey = "userPreferences"

    init() {
        // Load from UserDefaults or use defaults
        if let savedPreferences = Self.loadFromUserDefaults() {
            self.preferences = savedPreferences
        } else {
            self.preferences = UserPreferences()
            savePreferences()
        }
    }

    // MARK: - Update Preferences

    func updatePreferences(_ newPreferences: UserPreferences) {
        preferences = newPreferences
        savePreferences()
    }

    func updateLLMModel(_ model: String) {
        preferences.llmModel = model
        savePreferences()
    }

    func updateMeasurementSystem(_ system: String) {
        preferences.measurementSystem = system
        savePreferences()
    }

    func updateDietaryRestrictions(_ restrictions: [String]) {
        preferences.dietaryRestrictions = restrictions
        savePreferences()
    }

    func updateVoiceSettings(_ settings: VoiceSettings) {
        preferences.voiceSettings = settings
        savePreferences()
    }

    // MARK: - Private Methods

    private func savePreferences() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        do {
            let data = try encoder.encode(preferences)
            defaults.set(data, forKey: preferencesKey)
        } catch {
            print("Error saving preferences to UserDefaults: \(error)")
        }
    }

    private static func loadFromUserDefaults() -> UserPreferences? {
        guard let data = UserDefaults.standard.data(forKey: "userPreferences") else {
            return nil
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(UserPreferences.self, from: data)
        } catch {
            print("Error loading preferences from UserDefaults: \(error)")
            return nil
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        preferences = UserPreferences()
        savePreferences()
    }
}
