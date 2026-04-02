//
//  RecipeEntity.swift
//  little-chef
//
//  SwiftData model for local recipe storage
//

import Foundation
import SwiftData

/// SwiftData model for persisting recipes locally
@Model
final class RecipeEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var recipeDescription: String?
    var servings: Int
    var prepTime: Int?
    var cookTime: Int?
    var ingredients: [String]
    var instructions: [String]
    var tags: [String]
    var sourceUrl: String?
    var cuisineType: String?
    var difficulty: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        description: String? = nil,
        servings: Int,
        prepTime: Int? = nil,
        cookTime: Int? = nil,
        ingredients: [String],
        instructions: [String],
        tags: [String] = [],
        sourceUrl: String? = nil,
        cuisineType: String? = nil,
        difficulty: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.recipeDescription = description
        self.servings = servings
        self.prepTime = prepTime
        self.cookTime = cookTime
        self.ingredients = ingredients
        self.instructions = instructions
        self.tags = tags
        self.sourceUrl = sourceUrl
        self.cuisineType = cuisineType
        self.difficulty = difficulty
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Conversion Methods

    /// Convert to Recipe struct for UI compatibility
    func toRecipe() -> Recipe {
        return Recipe(
            id: id,
            title: title,
            description: recipeDescription,
            servings: servings,
            prepTime: prepTime,
            cookTime: cookTime,
            ingredients: ingredients,
            instructions: instructions,
            tags: tags,
            sourceUrl: sourceUrl,
            cuisineType: cuisineType,
            difficulty: difficulty,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Create from Recipe struct
    static func from(_ recipe: Recipe) -> RecipeEntity {
        return RecipeEntity(
            id: recipe.id,
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
            difficulty: recipe.difficulty,
            createdAt: recipe.createdAt,
            updatedAt: recipe.updatedAt
        )
    }

    /// Create from RecipeData (from parsing)
    static func from(_ recipeData: RecipeData) -> RecipeEntity {
        return RecipeEntity(
            title: recipeData.title,
            description: recipeData.description,
            servings: recipeData.servings,
            prepTime: recipeData.prepTime,
            cookTime: recipeData.cookTime,
            ingredients: recipeData.ingredients,
            instructions: recipeData.instructions,
            tags: recipeData.tags,
            sourceUrl: recipeData.sourceUrl,
            cuisineType: recipeData.cuisineType,
            difficulty: recipeData.difficulty
        )
    }

    /// Update from RecipeData
    func update(from recipeData: RecipeData) {
        self.title = recipeData.title
        self.recipeDescription = recipeData.description
        self.servings = recipeData.servings
        self.prepTime = recipeData.prepTime
        self.cookTime = recipeData.cookTime
        self.ingredients = recipeData.ingredients
        self.instructions = recipeData.instructions
        self.tags = recipeData.tags
        self.sourceUrl = recipeData.sourceUrl
        self.cuisineType = recipeData.cuisineType
        self.difficulty = recipeData.difficulty
        self.updatedAt = Date()
    }
}

// MARK: - Helper Extensions

extension RecipeEntity {
    /// Get total time (prep + cook) in minutes
    var totalTime: Int? {
        guard let prep = prepTime, let cook = cookTime else {
            return prepTime ?? cookTime
        }
        return prep + cook
    }

    /// Get formatted time string
    var formattedTime: String? {
        guard let total = totalTime else { return nil }

        if total < 60 {
            return "\(total) min"
        } else {
            let hours = total / 60
            let minutes = total % 60
            if minutes == 0 {
                return "\(hours) hr"
            } else {
                return "\(hours) hr \(minutes) min"
            }
        }
    }

    /// Check if recipe matches search query
    func matches(query: String) -> Bool {
        let lowercaseQuery = query.lowercased()

        return title.lowercased().contains(lowercaseQuery) ||
               recipeDescription?.lowercased().contains(lowercaseQuery) == true ||
               tags.contains(where: { $0.lowercased().contains(lowercaseQuery) }) ||
               cuisineType?.lowercased().contains(lowercaseQuery) == true ||
               ingredients.contains(where: { $0.lowercased().contains(lowercaseQuery) })
    }
}
