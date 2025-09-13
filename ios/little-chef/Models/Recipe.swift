//
//  Recipe.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import Foundation

// MARK: - Recipe Models
struct Recipe: Codable, Identifiable {
    let id: UUID
    let title: String
    let description: String?
    let servings: Int
    let prepTime: Int?
    let cookTime: Int?
    let ingredients: [String]
    let instructions: [String]
    let tags: [String]
    let sourceUrl: String?
    let cuisineType: String?
    let difficulty: String?
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, title, description, servings, ingredients, instructions, tags, difficulty
        case prepTime = "prep_time"
        case cookTime = "cook_time"
        case sourceUrl = "source_url"
        case cuisineType = "cuisine_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct RecipeCreate: Codable {
    let title: String
    let description: String?
    let servings: Int
    let prepTime: Int?
    let cookTime: Int?
    let ingredients: [String]
    let instructions: [String]
    let tags: [String]
    let sourceUrl: String?
    let cuisineType: String?
    let difficulty: String?
    
    enum CodingKeys: String, CodingKey {
        case title, description, servings, ingredients, instructions, tags, difficulty
        case prepTime = "prep_time"
        case cookTime = "cook_time"
        case sourceUrl = "source_url"
        case cuisineType = "cuisine_type"
    }
}

struct RecipeUpdate: Codable {
    let title: String?
    let description: String?
    let servings: Int?
    let prepTime: Int?
    let cookTime: Int?
    let ingredients: [String]?
    let instructions: [String]?
    let tags: [String]?
    let sourceUrl: String?
    let cuisineType: String?
    let difficulty: String?
    
    enum CodingKeys: String, CodingKey {
        case title, description, servings, ingredients, instructions, tags, difficulty
        case prepTime = "prep_time"
        case cookTime = "cook_time"
        case sourceUrl = "source_url"
        case cuisineType = "cuisine_type"
    }
}

struct RecipeListResponse: Codable, Identifiable {
    let id: UUID
    let recipeData: RecipeData
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id
        case recipeData = "recipe_data"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    // Convert to Recipe for easier use in UI
    var recipe: Recipe {
        return Recipe(
            id: id,
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
            difficulty: recipeData.difficulty,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct RecipeData: Codable {
    let title: String
    let description: String?
    let servings: Int
    let prepTime: Int?
    let cookTime: Int?
    let ingredients: [String]
    let instructions: [String]
    let tags: [String]
    let sourceUrl: String?
    let cuisineType: String?
    let difficulty: String?
    
    enum CodingKeys: String, CodingKey {
        case title, description, servings, ingredients, instructions, tags, difficulty
        case prepTime = "prep_time"
        case cookTime = "cook_time"
        case sourceUrl = "source_url"
        case cuisineType = "cuisine_type"
    }
}

// MARK: - Recipe Parsing Models
struct RecipeParseRequest: Codable {
    let url: String?
    let text: String?
    let image: String? // Base64 encoded image
}

struct RecipeParseUrlRequest: Codable {
    let url: String
}

struct RecipeParseTextRequest: Codable {
    let text: String
}

struct RecipeParseImageRequest: Codable {
    let images: [String] // Array of base64 encoded images
}

struct RecipeParseResponse: Codable {
    let recipe: RecipeData
    let confidence: Double
    let warnings: [String]
}

// MARK: - Recipe Input Source
enum RecipeInputType: String, CaseIterable {
    case url = "url"
    case text = "text"
    case image = "image"
    
    var displayName: String {
        switch self {
        case .url:
            return "From URL"
        case .text:
            return "From Text"
        case .image:
            return "From Image"
        }
    }
    
    var icon: String {
        switch self {
        case .url:
            return "link"
        case .text:
            return "text.cursor"
        case .image:
            return "camera"
        }
    }
}
