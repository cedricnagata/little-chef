//
//  RecipeEntity+CoreDataClass.swift
//  little-chef
//
//  Core Data entity for Recipe storage with CloudKit sync
//

import Foundation
import CoreData
import CloudKit

@objc(RecipeEntity)
public class RecipeEntity: NSManagedObject {
    // CloudKit record conversion
    func toCKRecord() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id?.uuidString ?? UUID().uuidString)
        let record = CKRecord(recordType: "Recipe", recordID: recordID)

        record["title"] = title as CKRecordValue?
        record["recipeDataJSON"] = recipeDataJSON as CKRecordValue?
        record["createdAt"] = createdAt as CKRecordValue?
        record["updatedAt"] = updatedAt as CKRecordValue?

        return record
    }

    func updateFrom(ckRecord: CKRecord) {
        title = ckRecord["title"] as? String
        recipeDataJSON = ckRecord["recipeDataJSON"] as? String
        createdAt = ckRecord["createdAt"] as? Date
        updatedAt = ckRecord["updatedAt"] as? Date
    }

    // Convert to Recipe model
    func toRecipe() -> Recipe? {
        guard let jsonString = recipeDataJSON,
              let data = jsonString.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let recipeData = try decoder.decode(RecipeBase.self, from: data)
            return Recipe(
                id: id ?? UUID(),
                recipe_data: recipeData,
                created_at: createdAt ?? Date(),
                updated_at: updatedAt ?? Date()
            )
        } catch {
            print("Failed to decode recipe: \(error)")
            return nil
        }
    }

    // Create from Recipe model
    static func create(from recipe: Recipe, in context: NSManagedObjectContext) -> RecipeEntity {
        let entity = RecipeEntity(context: context)
        entity.id = recipe.id
        entity.title = recipe.recipe_data.title
        entity.createdAt = recipe.created_at
        entity.updatedAt = recipe.updated_at

        // Encode recipe_data to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(recipe.recipe_data),
           let jsonString = String(data: data, encoding: .utf8) {
            entity.recipeDataJSON = jsonString
        }

        return entity
    }
}
