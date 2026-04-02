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
