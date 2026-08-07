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
    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(llmService: .shared)
    }

    init(llmService: LLMService) {
        self.llmService = llmService
        self.recipeParser = LocalRecipeParser(llmService: llmService)

        // Refetch when the store changes under us — a CloudKit import from another device, or a
        // bulk delete from Settings.
        //
        // A subscription, not the old `dataManager.onRemoteChange = …` assignment. This class is
        // built twice (`MainView` and `RecipeListView` each hold their own), and assigning to a
        // single closure property meant the second one to be constructed silently replaced the
        // first: one of the two lists stopped hearing about remote creates, edits and deletes
        // entirely, and which one lost depended on view construction order.
        dataManager.storeDidChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.loadRecipes()
                }
            }
            .store(in: &cancellables)
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
            // Front, not `append`. `fetchAllRecipes` sorts newest-first, so appending put a
            // just-saved recipe at the bottom of the list — below every older one — until the
            // next full reload moved it to the top.
            self.recipes.insert(recipeEntity.toRecipe(), at: 0)
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

    /// Writes back what a cooking session changed, either onto the recipe it started from or as
    /// a new one.
    ///
    /// Lives here rather than on `CookingSessionManager` because this is the object that owns
    /// recipe writes *and* the list they have to show up in. A cook can run for an hour, so the
    /// list is reloaded outright rather than patched — plenty can have arrived from another
    /// device in the meantime.
    func saveSessionRecipe(_ recipeData: RecipeData, replacing id: UUID?) async -> Bool {
        let result = await withLoading {
            // Falls back to creating when the target has gone: the only way a recipe disappears
            // mid-cook is another device deleting it, and answering an hour of edits with
            // "recipe not found" loses them to a race the user never saw.
            let existing = try id.flatMap { try self.dataManager.fetchRecipe(id: $0) }
            if let id, existing != nil {
                try self.dataManager.updateRecipe(id: id, with: recipeData)
            } else {
                try self.dataManager.createRecipe(recipeData)
            }
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
