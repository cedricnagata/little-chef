//
//  RecipeEntity+CoreDataProperties.swift
//  little-chef
//
//  Core Data properties for RecipeEntity
//

import Foundation
import CoreData

extension RecipeEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<RecipeEntity> {
        return NSFetchRequest<RecipeEntity>(entityName: "RecipeEntity")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var title: String?
    @NSManaged public var recipeDataJSON: String?  // Store entire RecipeBase as JSON
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var cloudKitRecordID: String?  // For CloudKit sync tracking
}

extension RecipeEntity : Identifiable {

}
