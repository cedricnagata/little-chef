//
//  UserPreferencesEntity+CoreDataProperties.swift
//  little-chef
//
//  Core Data properties for UserPreferencesEntity
//

import Foundation
import CoreData

extension UserPreferencesEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<UserPreferencesEntity> {
        return NSFetchRequest<UserPreferencesEntity>(entityName: "UserPreferencesEntity")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var preferencesJSON: String?  // Store entire UserPreferences as JSON
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
}

extension UserPreferencesEntity : Identifiable {

}
