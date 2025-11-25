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
              let data = jsonString.data(using: .utf8),
              let recipeId = id,
              let created = createdAt,
              let updated = updatedAt else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let recipeBase = try decoder.decode(RecipeBase.self, from: data)
            // Convert RecipeBase to Recipe (flat structure)
            return Recipe(
                id: recipeId,
                title: recipeBase.title,
                description: recipeBase.description,
                servings: recipeBase.servings,
                prepTime: recipeBase.prepTime,
                cookTime: recipeBase.cookTime,
                ingredients: recipeBase.ingredients,
                instructions: recipeBase.instructions,
                tags: recipeBase.tags,
                sourceUrl: recipeBase.sourceUrl,
                cuisineType: recipeBase.cuisineType,
                difficulty: recipeBase.difficulty,
                createdAt: created,
                updatedAt: updated
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
        entity.title = recipe.title
        entity.createdAt = recipe.createdAt
        entity.updatedAt = recipe.updatedAt

        // Convert Recipe to RecipeBase and encode to JSON
        let recipeBase = RecipeBase(
            title: recipe.title,
            description: recipe.description,
            servings: recipe.servings,
            prepTime: recipe.prepTime,
            cookTime: recipe.cookTime,
            ingredients: recipe.ingredients,
            instructions: recipe.instructions,
            tags: recipe.tags,
            sourceUrl: recipe.sourceUrl,
            cuisineType: recipe.cuisineType,
            difficulty: recipe.difficulty
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(recipeBase),
           let jsonString = String(data: data, encoding: .utf8) {
            entity.recipeDataJSON = jsonString
        }

        return entity
    }
}
