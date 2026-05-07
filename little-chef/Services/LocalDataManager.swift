//
//  LocalDataManager.swift
//  little-chef
//
//  Manages local data persistence using SwiftData
//

import Foundation
import SwiftData

/// Manages local data persistence for recipes and user preferences.
/// Both sync to the user's private iCloud database via SwiftData + CloudKit.
@MainActor
class LocalDataManager: ObservableObject {
    static let shared: LocalDataManager = {
        do {
            return try LocalDataManager()
        } catch {
            fatalError("Failed to initialize LocalDataManager: \(error)")
        }
    }()

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    /// Called when remote CloudKit changes arrive (e.g. from another device)
    var onRemoteChange: (() -> Void)?

    // MARK: - Initialization

    private init() throws {
        let schema = Schema([
            RecipeEntity.self,
            UserPreferencesEntity.self
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.com.littlechef.app")
        )

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            modelContext = ModelContext(modelContainer)
        } catch {
            print("Failed to create ModelContainer: \(error)")
            throw error
        }

        // Reload when a remote CloudKit change arrives from another device
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onRemoteChange?()
            }
        }
    }

    // MARK: - Recipe Operations

    /// Fetch all recipes
    func fetchAllRecipes() throws -> [RecipeEntity] {
        let descriptor = FetchDescriptor<RecipeEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    /// Fetch a specific recipe by ID
    func fetchRecipe(id: UUID) throws -> RecipeEntity? {
        let descriptor = FetchDescriptor<RecipeEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    /// Search recipes by query
    func searchRecipes(query: String) throws -> [RecipeEntity] {
        // Fetch all recipes and filter in memory for complex matching
        let allRecipes = try fetchAllRecipes()

        guard !query.isEmpty else {
            return allRecipes
        }

        return allRecipes.filter { $0.matches(query: query) }
    }

    /// Fetch recipes by tag
    func fetchRecipes(byTag tag: String) throws -> [RecipeEntity] {
        let allRecipes = try fetchAllRecipes()
        return allRecipes.filter { $0.tags.contains(tag) }
    }

    /// Fetch all unique tags
    func fetchAllTags() throws -> [String] {
        let allRecipes = try fetchAllRecipes()
        let allTags = allRecipes.flatMap { $0.tags }
        return Array(Set(allTags)).sorted()
    }

    /// Create a new recipe
    @discardableResult
    func createRecipe(_ recipeData: RecipeData) throws -> RecipeEntity {
        let recipe = RecipeEntity.from(recipeData)
        modelContext.insert(recipe)
        try modelContext.save()
        return recipe
    }

    /// Create a recipe from existing Recipe struct
    @discardableResult
    func createRecipe(from recipe: Recipe) throws -> RecipeEntity {
        let entity = RecipeEntity.from(recipe)
        modelContext.insert(entity)
        try modelContext.save()
        return entity
    }

    /// Update an existing recipe
    func updateRecipe(id: UUID, with recipeData: RecipeData) throws {
        guard let recipe = try fetchRecipe(id: id) else {
            throw LocalDataError.recipeNotFound(id)
        }

        recipe.update(from: recipeData)
        try modelContext.save()
    }

    /// Update specific recipe fields
    func updateRecipe(
        id: UUID,
        title: String? = nil,
        description: String? = nil,
        servings: Int? = nil,
        prepTime: Int? = nil,
        cookTime: Int? = nil,
        ingredients: [String]? = nil,
        instructions: [String]? = nil,
        tags: [String]? = nil,
        sourceUrl: String? = nil,
        cuisineType: String? = nil,
        difficulty: String? = nil
    ) throws {
        guard let recipe = try fetchRecipe(id: id) else {
            throw LocalDataError.recipeNotFound(id)
        }

        if let title = title { recipe.title = title }
        if let description = description { recipe.recipeDescription = description }
        if let servings = servings { recipe.servings = servings }
        if let prepTime = prepTime { recipe.prepTime = prepTime }
        if let cookTime = cookTime { recipe.cookTime = cookTime }
        if let ingredients = ingredients { recipe.ingredients = ingredients }
        if let instructions = instructions { recipe.instructions = instructions }
        if let tags = tags { recipe.tags = tags }
        if let sourceUrl = sourceUrl { recipe.sourceUrl = sourceUrl }
        if let cuisineType = cuisineType { recipe.cuisineType = cuisineType }
        if let difficulty = difficulty { recipe.difficulty = difficulty }

        recipe.updatedAt = Date()
        try modelContext.save()
    }

    /// Delete a recipe
    func deleteRecipe(id: UUID) throws {
        guard let recipe = try fetchRecipe(id: id) else {
            throw LocalDataError.recipeNotFound(id)
        }

        modelContext.delete(recipe)
        try modelContext.save()
    }

    /// Delete multiple recipes
    func deleteRecipes(ids: [UUID]) throws {
        let descriptor = FetchDescriptor<RecipeEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let recipes = try modelContext.fetch(descriptor)
        recipes.forEach { modelContext.delete($0) }
        try modelContext.save()
    }

    /// Delete all recipes
    func deleteAllRecipes() throws {
        let allRecipes = try fetchAllRecipes()
        for recipe in allRecipes {
            modelContext.delete(recipe)
        }
        try modelContext.save()
    }

    // MARK: - User Preferences Operations

    /// Fetch user preferences (creates default if none exist)
    func fetchPreferences() throws -> UserPreferencesEntity {
        let descriptor = FetchDescriptor<UserPreferencesEntity>()
        let preferences = try modelContext.fetch(descriptor)

        if let existing = preferences.first {
            return existing
        } else {
            // Create default preferences
            let defaultPrefs = UserPreferencesEntity.createDefault()
            modelContext.insert(defaultPrefs)
            try modelContext.save()
            return defaultPrefs
        }
    }

    /// Update user preferences
    func updatePreferences(
        measurementSystem: String? = nil,
        dietaryRestrictions: [String]? = nil,
        speechRate: Float? = nil,
        voiceIdentifier: String? = nil,
        autoSpeakResponses: Bool? = nil,
        cookingModel: CookingModelChoice? = nil,
        llmProvider: LLMProvider? = nil
    ) throws {
        let preferences = try fetchPreferences()

        preferences.update(
            measurementSystem: measurementSystem,
            dietaryRestrictions: dietaryRestrictions,
            speechRate: speechRate,
            voiceIdentifier: voiceIdentifier,
            autoSpeakResponses: autoSpeakResponses,
            cookingModel: cookingModel,
            llmProvider: llmProvider
        )

        try modelContext.save()
    }

    /// Reset preferences to defaults
    func resetPreferences() throws {
        let preferences = try fetchPreferences()

        preferences.measurementSystem = "imperial"
        preferences.dietaryRestrictions = []
        preferences.speechRate = 0.5
        preferences.voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
        preferences.autoSpeakResponses = true
        preferences.cookingModel = CookingModelChoice.bonsai8B.rawValue
        preferences.updatedAt = Date()

        try modelContext.save()
    }

    // MARK: - Statistics

    /// Get total recipe count
    func getRecipeCount() throws -> Int {
        return try modelContext.fetchCount(FetchDescriptor<RecipeEntity>())
    }

    /// Get recipes grouped by cuisine type
    func getRecipesByCuisine() throws -> [String: Int] {
        try groupRecipes(by: \.cuisineType)
    }

    /// Get recipes grouped by difficulty
    func getRecipesByDifficulty() throws -> [String: Int] {
        try groupRecipes(by: \.difficulty)
    }

    private func groupRecipes(by keyPath: KeyPath<RecipeEntity, String?>) throws -> [String: Int] {
        let allRecipes = try fetchAllRecipes()
        return allRecipes.reduce(into: [:]) { counts, recipe in
            counts[recipe[keyPath: keyPath] ?? "Unknown", default: 0] += 1
        }
    }
}

// MARK: - Error Types

enum LocalDataError: LocalizedError {
    case recipeNotFound(UUID)
    case preferencesNotFound
    case saveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .recipeNotFound(let id):
            return "Recipe with ID \(id) not found"
        case .preferencesNotFound:
            return "User preferences not found"
        case .saveFailed(let error):
            return "Failed to save data: \(error.localizedDescription)"
        }
    }
}
