//
//  UserPreferencesEntity+CoreDataClass.swift
//  little-chef
//
//  Core Data entity for User Preferences storage
//

import Foundation
import CoreData

@objc(UserPreferencesEntity)
public class UserPreferencesEntity: NSManagedObject {
    // Convert to UserPreferences model
    func toUserPreferences() -> UserPreferences? {
        guard let jsonString = preferencesJSON,
              let data = jsonString.data(using: .utf8) else {
            return UserPreferences()  // Return default if no preferences stored
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(UserPreferences.self, from: data)
        } catch {
            print("Failed to decode user preferences: \(error)")
            return UserPreferences()  // Return default on error
        }
    }

    // Update from UserPreferences model
    func update(from preferences: UserPreferences) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        if let data = try? encoder.encode(preferences),
           let jsonString = String(data: data, encoding: .utf8) {
            self.preferencesJSON = jsonString
            self.updatedAt = Date()
        }
    }

    // Create or update singleton preferences
    static func getOrCreate(in context: NSManagedObjectContext) -> UserPreferencesEntity {
        let request: NSFetchRequest<UserPreferencesEntity> = UserPreferencesEntity.fetchRequest()
        request.fetchLimit = 1

        do {
            if let existing = try context.fetch(request).first {
                return existing
            }
        } catch {
            print("Error fetching preferences: \(error)")
        }

        // Create new preferences entity
        let entity = UserPreferencesEntity(context: context)
        entity.id = UUID()
        entity.createdAt = Date()
        entity.updatedAt = Date()

        // Set default preferences
        entity.update(from: UserPreferences())

        return entity
    }
}
