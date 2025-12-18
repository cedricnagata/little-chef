//
//  RecipeScalingService.swift
//  little-chef
//
//  Extracted from CookingSessionManager for single responsibility
//

import Foundation

struct RecipeScalingService {

    // MARK: - Recipe Scaling

    static func createScaledRecipe(from recipe: RecipeBase, servings: Int) -> RecipeBase {
        let originalServings = recipe.servings
        let multiplier = Float(servings) / Float(originalServings)

        if multiplier == 1.0 {
            return recipe
        }

        // Scale ingredients
        let scaledIngredients = recipe.ingredients.map { ingredient in
            scaleIngredient(ingredient, multiplier: multiplier)
        }

        // Create new RecipeBase with scaled data
        return RecipeBase(
            title: recipe.title,
            description: recipe.description,
            servings: servings,
            prepTime: recipe.prepTime,
            cookTime: recipe.cookTime,
            ingredients: scaledIngredients,
            instructions: recipe.instructions,
            tags: recipe.tags,
            sourceUrl: recipe.sourceUrl,
            cuisineType: recipe.cuisineType,
            difficulty: recipe.difficulty
        )
    }

    // MARK: - Ingredient Scaling

    static func scaleIngredient(_ ingredient: String, multiplier: Float) -> String {
        if multiplier == 1.0 {
            return ingredient
        }

        // Common patterns for numbers in ingredients
        // Examples: "2 cups flour", "1/2 teaspoon salt", "1.5 pounds chicken"
        let patterns = [
            "([0-9]+\\.?[0-9]*\\/[0-9]+)\\s+(\\w+)",  // "1/2 teaspoon"
            "([0-9]+\\.?[0-9]*)\\s+(\\w+)"           // "2 cups", "1.5 pounds"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: ingredient, options: [], range: NSRange(location: 0, length: ingredient.count)) {

                guard let amountRange = Range(match.range(at: 1), in: ingredient) else {
                    return ingredient  // Return original if can't parse range
                }
                let amountStr = String(ingredient[amountRange])

                do {
                    var amount: Float

                    // Handle fractions like "1/2"
                    if amountStr.contains("/") {
                        let parts = amountStr.split(separator: "/")
                        if parts.count == 2,
                           let numerator = Float(parts[0]),
                           let denominator = Float(parts[1]),
                           denominator != 0 {
                            amount = numerator / denominator
                        } else {
                            continue
                        }
                    } else {
                        guard let parsed = Float(amountStr) else { continue }
                        amount = parsed
                    }

                    // Scale the amount
                    let scaledAmount = amount * multiplier

                    // Format the scaled amount nicely
                    let scaledStr: String
                    if scaledAmount == Float(Int(scaledAmount)) {
                        scaledStr = "\(Int(scaledAmount))"
                    } else {
                        scaledStr = String(format: "%.2f", scaledAmount).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
                    }

                    // Replace in the original string
                    return ingredient.replacingOccurrences(of: amountStr, with: scaledStr)
                } catch {
                    continue
                }
            }
        }

        // If no number pattern found, return original ingredient with note
        if multiplier != 1.0 {
            return "\(ingredient) (scale by \(String(format: "%.1f", multiplier))x)"
        }
        return ingredient
    }
}
