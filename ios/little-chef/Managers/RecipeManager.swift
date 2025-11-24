//
//  RecipeManager.swift
//  little-chef
//
//  Manages recipes using Core Data with CloudKit sync
//  No backend CRUD - all data stored locally
//

import Foundation
import SwiftUI
import CoreData

@MainActor
class RecipeManager: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let apiService = APIService.shared
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }

    // MARK: - Recipe Management (Core Data)

    func loadRecipes() async {
        isLoading = true
        errorMessage = nil

        do {
            let request: NSFetchRequest<RecipeEntity> = RecipeEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \RecipeEntity.updatedAt, ascending: false)]

            let entities = try context.fetch(request)
            recipes = entities.compactMap { $0.toRecipe() }
        } catch {
            errorMessage = "Failed to load recipes: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func createRecipe(_ recipeBase: RecipeBase) async -> Bool {
        isLoading = true
        errorMessage = nil

        do {
            let recipe = Recipe(
                id: UUID(),
                recipe_data: recipeBase,
                created_at: Date(),
                updated_at: Date()
            )

            _ = RecipeEntity.create(from: recipe, in: context)

            try context.save()

            // Reload recipes to include the new one
            await loadRecipes()

            isLoading = false
            return true
        } catch {
            errorMessage = "Failed to create recipe: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    func updateRecipe(id: UUID, with recipeBase: RecipeBase) async -> Bool {
        isLoading = true
        errorMessage = nil

        do {
            let request: NSFetchRequest<RecipeEntity> = RecipeEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                errorMessage = "Recipe not found"
                isLoading = false
                return false
            }

            // Update entity
            entity.title = recipeBase.title
            entity.updatedAt = Date()

            // Encode recipe_data to JSON
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(recipeBase),
               let jsonString = String(data: data, encoding: .utf8) {
                entity.recipeDataJSON = jsonString
            }

            try context.save()

            // Reload recipes
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
            let request: NSFetchRequest<RecipeEntity> = RecipeEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", recipe.id as CVarArg)
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                errorMessage = "Recipe not found"
                isLoading = false
                return false
            }

            context.delete(entity)
            try context.save()

            // Remove from local array
            recipes.removeAll { $0.id == recipe.id }

            isLoading = false
            return true
        } catch {
            errorMessage = "Failed to delete recipe: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    // MARK: - Recipe Parsing (Lambda API)

    func parseRecipeFromUrl(_ url: String) async -> RecipeParseResponse? {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await apiService.parseRecipeFromUrl(url: url)
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
            let response = try await apiService.parseRecipeFromText(text: text)
            isLoading = false
            return response
        } catch {
            errorMessage = "Failed to parse recipe from text: \(error.localizedDescription)"
            isLoading = false
            return nil
        }
    }

    func parseRecipeFromImages(_ base64Images: [String]) async -> RecipeParseResponse? {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await apiService.parseRecipeFromImage(images: base64Images)
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

    func searchRecipes(query: String) -> [Recipe] {
        guard !query.isEmpty else { return recipes }

        return recipes.filter { recipe in
            recipe.recipe_data.title.localizedCaseInsensitiveContains(query) ||
            recipe.recipe_data.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
            recipe.recipe_data.cuisine_type?.localizedCaseInsensitiveContains(query) ?? false
        }
    }
}
