//
//  RecipeModification.swift
//  little-chef
//
//  Models for recipe modification tracking and editing
//

import Foundation

// MARK: - Recipe Modification Models

/// Granular recipe modification with details for user review
struct RecipeModification: Codable, Identifiable {
    let id: String
    let modificationType: ModificationType
    let field: String
    let targetIndex: Int?
    let oldValue: String?
    let newValue: String?
    let rationale: String
    let confidence: Double
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case modificationType = "modification_type"
        case field
        case targetIndex = "target_index"
        case oldValue = "old_value"
        case newValue = "new_value"
        case rationale
        case confidence
        case createdAt = "created_at"
    }

    /// Display title for UI
    var displayTitle: String {
        switch modificationType {
        case .ingredientSubstitute:
            return "Substitute: \(oldValue ?? "") → \(newValue ?? "")"
        case .ingredientQuantity:
            return "Adjust quantity: \(oldValue ?? "") → \(newValue ?? "")"
        case .ingredientAdd:
            return "Add ingredient: \(newValue ?? "")"
        case .ingredientRemove:
            return "Remove: \(oldValue ?? "")"
        case .instructionModify:
            return "Modify step \((targetIndex ?? 0) + 1)"
        case .instructionAdd:
            return "Add instruction step"
        case .instructionRemove:
            return "Remove step \((targetIndex ?? 0) + 1)"
        case .servingsChange:
            return "Change servings: \(oldValue ?? "") → \(newValue ?? "")"
        case .timingChange:
            return "Update timing"
        }
    }

    /// Icon for UI display
    var icon: String {
        switch modificationType {
        case .ingredientSubstitute, .ingredientQuantity:
            return "arrow.left.arrow.right"
        case .ingredientAdd:
            return "plus.circle.fill"
        case .ingredientRemove:
            return "minus.circle.fill"
        case .instructionModify, .instructionAdd, .instructionRemove:
            return "list.number"
        case .servingsChange:
            return "person.2.fill"
        case .timingChange:
            return "clock.fill"
        }
    }
}

/// Type of recipe modification
enum ModificationType: String, Codable {
    case ingredientSubstitute = "ingredient_substitute"
    case ingredientQuantity = "ingredient_quantity"
    case ingredientAdd = "ingredient_add"
    case ingredientRemove = "ingredient_remove"
    case instructionModify = "instruction_modify"
    case instructionAdd = "instruction_add"
    case instructionRemove = "instruction_remove"
    case servingsChange = "servings_change"
    case timingChange = "timing_change"
}

// MARK: - Recipe Edit Request/Response

/// Request for AI-powered recipe editing
struct RecipeEditRequest: Codable {
    let recipe: RecipeBase
    let editInstructions: String
    let userPreferences: UserPreferencesDetailed

    enum CodingKeys: String, CodingKey {
        case recipe
        case editInstructions = "edit_instructions"
        case userPreferences = "user_preferences"
    }
}

/// Response from recipe editing service
struct RecipeEditResponse: Codable {
    let modifications: [RecipeModification] // Generated client-side from diff
    let modifiedRecipe: RecipeBase
    let overallConfidence: Double
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case modifications
        case modifiedRecipe = "modified_recipe"
        case overallConfidence = "overall_confidence"
        case warnings
    }

    // Custom init for creating response with client-generated modifications
    init(modifications: [RecipeModification], modifiedRecipe: RecipeBase, overallConfidence: Double, warnings: [String]) {
        self.modifications = modifications
        self.modifiedRecipe = modifiedRecipe
        self.overallConfidence = overallConfidence
        self.warnings = warnings
    }

    // Decoder that handles optional modifications from backend
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modifications = (try? container.decode([RecipeModification].self, forKey: .modifications)) ?? []
        self.modifiedRecipe = try container.decode(RecipeBase.self, forKey: .modifiedRecipe)
        self.overallConfidence = try container.decode(Double.self, forKey: .overallConfidence)
        self.warnings = try container.decode([String].self, forKey: .warnings)
    }
}
