//
//  RecipeManager.swift
//  little-chef
//
//  The recipe list, and every write to it.
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
    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(llmService: .shared)
    }

    init(llmService: LLMService) {
        self.recipeParser = LocalRecipeParser(llmService: llmService)

        // Refetch when the store changes under us: importing a profile, or Delete All Data.
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
        let result: Void? = await withLoading {
            let recipeEntity = try self.dataManager.createRecipe(recipeData)
            // Front, not `append`. `fetchAllRecipes` sorts newest-first, so appending put a
            // just-saved recipe at the bottom of the list — below every older one — until the
            // next full reload moved it to the top.
            self.recipes.insert(recipeEntity.toRecipe(), at: 0)
        }
        return result != nil
    }

    func updateRecipe(id: UUID, with recipeData: RecipeData) async -> Bool {
        let result: Void? = await withLoading {
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
    /// list is reloaded outright rather than patched.
    func saveSessionRecipe(_ recipeData: RecipeData, replacing id: UUID?) async -> Bool {
        let result: Void? = await withLoading {
            // Falls back to creating when the target has gone (Delete All Data mid-cook, say):
            // answering an hour of edits with "recipe not found" would lose them.
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
        let result: Void? = await withLoading {
            try self.dataManager.deleteRecipe(id: recipe.id)
            self.recipes.removeAll { $0.id == recipe.id }
        }
        return result != nil
    }

    // MARK: - Helpers

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
        await parse("Failed to parse recipe from URL") { try await $0.parseFromURL(url) }
    }

    func parseRecipeFromText(_ text: String) async -> RecipeParseResponse? {
        await parse("Failed to parse recipe from text") { try await $0.parseFromText(text) }
    }

    func parseRecipeFromImages(_ images: [UIImage]) async -> RecipeParseResponse? {
        await parse("Failed to parse recipe from images") { try await $0.parseFromImages(images) }
    }

    private func parse(
        _ failure: String,
        _ work: @escaping (LocalRecipeParser) async throws -> RecipeParseResponse
    ) async -> RecipeParseResponse? {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            return try await withParsingContext { try await work(self.recipeParser) }
        } catch {
            errorMessage = "\(failure): \(error.localizedDescription)"
            return nil
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
