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
    @Published var isSyncingWithCloud = false
    @Published var errorMessage: String?

    private let apiService = APIService.shared
    private let context: NSManagedObjectContext
    private var hasPerformedInitialSync = false

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        setupCloudKitNotifications()
        // Initial load handled by view's .task to ensure proper loading state
    }

    // MARK: - CloudKit Notifications

    private func setupCloudKitNotifications() {
        // Listen for remote changes from CloudKit
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("📥 CloudKit remote change notification received")
            Task { @MainActor in
                await self?.loadRecipes()
            }
        }
    }

    // MARK: - CloudKit Sync

    /// Syncs with CloudKit only if local storage is empty (first time use)
    func syncIfNeeded() async {
        guard !hasPerformedInitialSync else { return }
        hasPerformedInitialSync = true

        // First, load local recipes
        await loadRecipes()

        // Only sync with iCloud if we have no local recipes
        if recipes.isEmpty {
            print("📱 No local recipes found, syncing with iCloud...")
            print("🔄 Setting isSyncingWithCloud = true for CloudKit sync")
            isSyncingWithCloud = true

            await triggerCloudKitSync()

            // Wait a moment for CloudKit to process
            print("⏳ Waiting for CloudKit to sync...")
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            print("🔄 Loading recipes after CloudKit sync...")
            await loadRecipes()

            isSyncingWithCloud = false
            print("✅ Finished CloudKit sync, isSyncingWithCloud = \(isSyncingWithCloud)")
        } else {
            print("📱 Local recipes found (\(recipes.count)), skipping initial sync")
        }
    }

    func triggerCloudKitSync() async {
        print("🔄 Triggering CloudKit sync...")

        guard let container = context.persistentStoreCoordinator?.persistentStores.first else {
            print("❌ No persistent store found")
            return
        }

        // Check if CloudKit is configured
        guard let cloudKitContainer = PersistenceController.shared.container as? NSPersistentCloudKitContainer else {
            print("❌ Not using CloudKit container")
            return
        }

        do {
            // Try to initialize CloudKit schema if needed
            try await cloudKitContainer.initializeCloudKitSchema()
            print("✅ CloudKit schema initialized")
        } catch {
            print("⚠️ CloudKit schema initialization: \(error.localizedDescription)")
        }

        // Force a save to trigger sync
        if context.hasChanges {
            do {
                try context.save()
                print("✅ Context saved to trigger sync")
            } catch {
                print("❌ Failed to save context: \(error)")
            }
        }

        print("✅ CloudKit sync triggered - data will sync in background")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
                title: recipeBase.title,
                description: recipeBase.description,
                servings: recipeBase.servings,
                prepTime: recipeBase.prepTime,
                cookTime: recipeBase.cookTime,
                ingredients: recipeBase.ingredients,
                instructions: recipeBase.instructions,
                tags: recipeBase.tags,
                sourceUrl: recipeBase.sourceUrl,
                cuisineType: recipeBase.cuisineType,
                difficulty: recipeBase.difficulty,
                createdAt: Date(),
                updatedAt: Date()
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
            recipe.title.localizedCaseInsensitiveContains(query) ||
            recipe.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
            recipe.cuisineType?.localizedCaseInsensitiveContains(query) ?? false
        }
    }
}
