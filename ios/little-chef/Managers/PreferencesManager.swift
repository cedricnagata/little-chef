//
//  PreferencesManager.swift
//  little-chef
//
//  Manages user preferences locally using Core Data
//

import Foundation
import CoreData
import Combine

class PreferencesManager: ObservableObject {
    @Published var preferences: UserPreferences

    private let context: NSManagedObjectContext
    private let preferencesEntity: UserPreferencesEntity

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        self.preferencesEntity = UserPreferencesEntity.getOrCreate(in: context)
        self.preferences = preferencesEntity.toUserPreferences() ?? UserPreferences()
    }

    // MARK: - Update Preferences

    func updatePreferences(_ newPreferences: UserPreferences) {
        preferences = newPreferences
        preferencesEntity.update(from: newPreferences)
        saveContext()
    }

    func updateLLMModel(_ model: String) {
        preferences.llm_model = model
        saveChanges()
    }

    func updateMeasurementSystem(_ system: String) {
        preferences.measurement_system = system
        saveChanges()
    }

    func updateDietaryRestrictions(_ restrictions: [String]) {
        preferences.dietary_restrictions = restrictions
        saveChanges()
    }

    func updateVoiceSettings(_ settings: VoiceSettings) {
        preferences.voice_settings = settings
        saveChanges()
    }

    func updateElevenLabsSettings(_ settings: ElevenLabsSettings) {
        preferences.voice_settings.elevenlabs = settings
        saveChanges()
    }

    // MARK: - Private Methods

    private func saveChanges() {
        preferencesEntity.update(from: preferences)
        saveContext()
    }

    private func saveContext() {
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                print("Error saving preferences: \(error)")
            }
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        preferences = UserPreferences()
        saveChanges()
    }
}
