//
//  RecipeManager.swift
//  little-chef
//
//  Updated to use local storage (LocalDataManager) instead of APIService
//

import Foundation
import SwiftUI
import UIKit
import Combine

@MainActor
class RecipeManager: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var parseStatus: String = ""

    private let dataManager = LocalDataManager.shared
    private let recipeParser: LocalRecipeParser
    private let llmService: LLMService

    convenience init() {
        self.init(llmService: .shared)
    }

    init(llmService: LLMService) {
        self.llmService = llmService
        self.recipeParser = LocalRecipeParser(llmService: llmService)

        // Reload recipes when remote CloudKit changes arrive
        dataManager.onRemoteChange = { [weak self] in
            Task { @MainActor in
                await self?.loadRecipes()
            }
        }
    }

    // MARK: - Recipe Management
    func loadRecipes() async {
        await withLoading {
            let recipeEntities = try self.dataManager.fetchAllRecipes()
            self.recipes = recipeEntities.map { $0.toRecipe() }
        }
    }

    func createRecipe(_ recipeData: RecipeData) async -> Bool {
        let result = await withLoading {
            let recipeEntity = try self.dataManager.createRecipe(recipeData)
            self.recipes.append(recipeEntity.toRecipe())
        }
        return result != nil
    }

    func updateRecipe(id: UUID, with recipeData: RecipeData) async -> Bool {
        let result = await withLoading {
            try self.dataManager.updateRecipe(id: id, with: recipeData)
            await self.loadRecipes()
        }
        return result != nil
    }

    func deleteRecipe(_ recipe: Recipe) async -> Bool {
        let result = await withLoading {
            try self.dataManager.deleteRecipe(id: recipe.id)
            self.recipes.removeAll { $0.id == recipe.id }
        }
        return result != nil
    }

    // MARK: - Search & Filter

    func searchRecipes(query: String) async {
        await withLoading {
            let recipeEntities = try self.dataManager.searchRecipes(query: query)
            self.recipes = recipeEntities.map { $0.toRecipe() }
        }
    }

    func fetchRecipes(byTag tag: String) async {
        await withLoading {
            let recipeEntities = try self.dataManager.fetchRecipes(byTag: tag)
            self.recipes = recipeEntities.map { $0.toRecipe() }
        }
    }
    
    // MARK: - Recipe Parsing

    private func withLoading<T>(_ work: () async throws -> T) async -> T? {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            return try await work()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Keeps the screen awake during GPU-based parsing and forwards status updates.
    private func withParsingContext<T>(_ work: @escaping () async throws -> T) async rethrows -> T {
        UIApplication.shared.isIdleTimerDisabled = true
        let observation = recipeParser.$statusMessage.receive(on: RunLoop.main).sink { [weak self] status in
            self?.parseStatus = status
        }
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            observation.cancel()
            parseStatus = ""
        }
        return try await work()
    }

    func parseRecipeFromUrl(_ url: String) async -> RecipeParseResponse? {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await withParsingContext {
                try await self.recipeParser.parseFromURL(url)
            }
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
            let response = try await withParsingContext {
                try await self.recipeParser.parseFromText(text)
            }
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
            let response = try await withParsingContext {
                try await self.recipeParser.parseFromImages(images)
            }
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
