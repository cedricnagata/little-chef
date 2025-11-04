//
//  RecipeManager.swift
//  little-chef
//
//  Updated to use local storage (LocalDataManager) instead of APIService
//

import Foundation
import SwiftUI

@MainActor
class RecipeManager: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var dataManager: LocalDataManager
    private let recipeParser = LocalRecipeParser()

    init() {
        do {
            dataManager = try LocalDataManager()
        } catch {
            fatalError("Failed to initialize LocalDataManager: \(error)")
        }
    }

    // MARK: - Recipe Management
    func loadRecipes() async {
        isLoading = true
        errorMessage = nil

        do {
            let recipeEntities = try dataManager.fetchAllRecipes()
            recipes = recipeEntities.map { $0.toRecipe() }
        } catch {
            errorMessage = "Failed to load recipes: \(error.localizedDescription)"
        }

        isLoading = false
    }
    
    func createRecipe(_ recipeData: RecipeData) async -> Bool {
        isLoading = true
        errorMessage = nil

        do {
            let recipeEntity = try dataManager.createRecipe(recipeData)
            recipes.append(recipeEntity.toRecipe())
            isLoading = false
            return true
        } catch {
            errorMessage = "Failed to create recipe: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    func updateRecipe(id: UUID, with recipeData: RecipeData) async -> Bool {
        isLoading = true
        errorMessage = nil

        do {
            try dataManager.updateRecipe(id: id, with: recipeData)
            // Reload recipes to get updated version
            await loadRecipes()
            isLoading = false
            return true
        } catch {
            errorMessage = "Failed to update recipe: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    func deleteRecipe(_ recipe: Recipe) async -> Bool {
        isLoading = true
        errorMessage = nil

        do {
            try dataManager.deleteRecipe(id: recipe.id)
            recipes.removeAll { $0.id == recipe.id }
            isLoading = false
            return true
        } catch {
            errorMessage = "Failed to delete recipe: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    // MARK: - Search & Filter

    func searchRecipes(query: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let recipeEntities = try dataManager.searchRecipes(query: query)
            recipes = recipeEntities.map { $0.toRecipe() }
        } catch {
            errorMessage = "Failed to search recipes: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func fetchRecipes(byTag tag: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let recipeEntities = try dataManager.fetchRecipes(byTag: tag)
            recipes = recipeEntities.map { $0.toRecipe() }
        } catch {
            errorMessage = "Failed to fetch recipes by tag: \(error.localizedDescription)"
        }

        isLoading = false
    }
    
    // MARK: - Recipe Parsing

    func parseRecipeFromUrl(_ url: String) async -> RecipeParseResponse? {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await recipeParser.parseFromURL(url)
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
            let response = try await recipeParser.parseFromText(text)
            isLoading = false
            return response
        } catch {
            errorMessage = "Failed to parse recipe from text: \(error.localizedDescription)"
            isLoading = false
            return nil
        }
    }

    func parseRecipeFromImages(_ images: [UIImage]) async -> RecipeParseResponse? {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await recipeParser.parseFromImages(images)
            isLoading = false
            return response
        } catch {
            errorMessage = "Failed to parse recipe from images: \(error.localizedDescription)"
            isLoading = false
            return nil
        }
    }
    
    // MARK: - Helper Methods
    func clearError() {
        errorMessage = nil
    }
}
