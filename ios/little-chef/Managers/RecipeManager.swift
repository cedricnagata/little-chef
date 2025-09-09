//
//  RecipeManager.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import Foundation
import SwiftUI

@MainActor
class RecipeManager: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let apiService = APIService.shared
    
    // MARK: - Recipe Management
    func loadRecipes() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let recipeListResponses = try await apiService.getRecipes()
            recipes = recipeListResponses.map { $0.recipe }
        } catch {
            errorMessage = "Failed to load recipes: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    func createRecipe(_ recipe: RecipeCreate) async -> Bool {
        isLoading = true
        errorMessage = nil
        
        do {
            let newRecipe = try await apiService.createRecipe(recipe)
            recipes.append(newRecipe)
            return true
        } catch {
            errorMessage = "Failed to create recipe: \(error.localizedDescription)"
            return false
        }
        
        isLoading = false
    }
    
    func deleteRecipe(_ recipe: Recipe) async -> Bool {
        isLoading = true
        errorMessage = nil
        
        do {
            try await apiService.deleteRecipe(id: recipe.id)
            recipes.removeAll { $0.id == recipe.id }
            return true
        } catch {
            errorMessage = "Failed to delete recipe: \(error.localizedDescription)"
            return false
        }
        
        isLoading = false
    }
    
    // MARK: - Recipe Parsing
    func parseRecipeFromUrl(_ url: String) async -> RecipeParseResponse? {
        isLoading = true
        errorMessage = nil
        
        do {
            let response = try await apiService.parseRecipeFromUrl(url)
            isLoading = false
            return response
        } catch {
            errorMessage = "Failed to parse recipe from URL: \(error.localizedDescription)"
            isLoading = false
            return nil
        }
    }
    
    func parseRecipeFromText(_ text: String) async -> RecipeParseResponse? {
        isLoading = true
        errorMessage = nil
        
        do {
            let response = try await apiService.parseRecipeFromText(text)
            isLoading = false
            return response
        } catch {
            errorMessage = "Failed to parse recipe from text: \(error.localizedDescription)"
            isLoading = false
            return nil
        }
    }
    
    func parseRecipeFromImage(_ base64Image: String) async -> RecipeParseResponse? {
        isLoading = true
        errorMessage = nil
        
        do {
            let response = try await apiService.parseRecipeFromImage(base64Image)
            isLoading = false
            return response
        } catch {
            errorMessage = "Failed to parse recipe from image: \(error.localizedDescription)"
            isLoading = false
            return nil
        }
    }
    
    // MARK: - Helper Methods
    func clearError() {
        errorMessage = nil
    }
}
