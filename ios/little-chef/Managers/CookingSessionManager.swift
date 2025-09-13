//
//  CookingSessionManager.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/12/25.
//

import Foundation
import SwiftUI

@MainActor
class CookingSessionManager: ObservableObject {
    @Published var currentSession: CookingSession?
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastResponse: String = ""
    
    private let apiService = APIService.shared
    
    // MARK: - Session Management
    
    func startCookingSession(with recipe: Recipe) {
        let recipeBase = RecipeBase(from: recipe)
        
        // Always create fresh user preferences with gpt-5-mini (not reusing old session data)
        let userPreferences = UserPreferencesDetailed()
        
        currentSession = CookingSession(recipe: recipeBase, userPreferences: userPreferences)
        error = nil
        print("🔵 Started new cooking session with model: \(userPreferences.llmModel)")
    }
    
    func endCookingSession() {
        currentSession = nil
        lastResponse = ""
        error = nil
    }
    
    // MARK: - Agent Communication
    
    func sendQuery(_ query: String) async {
        guard var session = currentSession else {
            error = "No active cooking session"
            return
        }
        
        // Clear any previous errors
        error = nil
        isLoading = true
        
        do {
            let response = try await apiService.sendAgentQuery(
                cookingSession: session,
                query: query
            )
            
            // Update the session with the response
            currentSession = response.updatedSession
            lastResponse = response.response
            
        } catch {
            self.error = "Failed to get response: \(error.localizedDescription)"
            print("Agent query error: \(error)")
        }
        
        isLoading = false
    }
    
    // MARK: - Voice Interaction Helpers
    
    func getLastMessage() -> String {
        guard let session = currentSession,
              let lastMessage = session.conversationHistory.last else {
            return ""
        }
        return lastMessage.content
    }
    
    func hasActiveSession() -> Bool {
        return currentSession != nil
    }
    
    func getRecipeTitle() -> String {
        return currentSession?.recipe.title ?? ""
    }
    
    func getConversationHistory() -> [Message] {
        return currentSession?.conversationHistory ?? []
    }
    
    // MARK: - Recipe Modifications
    
    func updateServings(newServings: Int) {
        guard var session = currentSession else { return }
        
        let originalServings = session.recipe.servings
        let multiplier = Float(newServings) / Float(originalServings)
        
        // Update the modifications in the session
        var modifications = session.modifications
        modifications = RecipeModifications(
            servingMultiplier: multiplier,
            ingredientSubstitutions: modifications.ingredientSubstitutions,
            notes: modifications.notes
        )
        
        // Create new session with updated modifications
        currentSession = CookingSession(
            recipe: session.recipe,
            modifications: modifications,
            activeTimers: session.activeTimers,
            conversationHistory: session.conversationHistory,
            userPreferences: session.userPreferences,
            startedAt: session.startedAt
        )
        
        print("🔄 Updated servings from \(originalServings) to \(newServings) (multiplier: \(multiplier))")
    }
    
    func getCurrentServings() -> Int {
        guard let session = currentSession else { return 0 }
        return Int(Float(session.recipe.servings) * session.modifications.servingMultiplier)
    }
    
    func getServingMultiplier() -> Float {
        return currentSession?.modifications.servingMultiplier ?? 1.0
    }
    
    func getScaledIngredients() -> [String] {
        guard let session = currentSession else { return [] }
        
        let multiplier = session.modifications.servingMultiplier
        if multiplier == 1.0 {
            return session.recipe.ingredients
        }
        
        return session.recipe.ingredients.map { ingredient in
            scaleIngredient(ingredient, multiplier: multiplier)
        }
    }
    
    private func scaleIngredient(_ ingredient: String, multiplier: Float) -> String {
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
                
                let amountRange = Range(match.range(at: 1), in: ingredient)!
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
    
    // MARK: - Timer Management (Placeholder for future implementation)
    
    func addTimer(duration: TimeInterval, label: String) {
        // TODO: Implement timer functionality
        print("Timer added: \(label) for \(duration) seconds")
    }
    
    func getActiveTimers() -> [Timer] {
        return currentSession?.activeTimers ?? []
    }
}
