//
//  LocalDataManager.swift
//  little-chef
//
//  Manages local data persistence using SwiftData
//

import Foundation
import OSLog
import SwiftData

/// Whether the store backing this session is mirroring to CloudKit.
enum CloudSyncStatus: Equatable {
    /// The store is backed by CloudKit. Whether records have actually landed also depends on
    /// network reachability and the signed-in iCloud account, but the mirroring is wired up.
    case syncing

    /// CloudKit mirroring could not be set up, so this device is on a local-only store:
    /// nothing written here reaches iCloud, and nothing survives deleting the app.
    case localOnly(reason: String)

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
}

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

    /// Release builds need this. `dprint` compiles to nothing outside DEBUG, which is precisely
    /// why a silent fall back to a local-only store went unnoticed through TestFlight.
    private static let log = Logger(subsystem: "NagataInc.little-chef", category: "persistence")

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    /// Whether this session is mirroring to CloudKit, and why not when it isn't.
    ///
    /// Decided once at launch: the container is built with either a CloudKit-backed
    /// configuration or a local-only one, and it cannot change store mid-session.
    @Published private(set) var cloudSyncStatus: CloudSyncStatus = .syncing

    /// Called when remote CloudKit changes arrive (e.g. from another device)
    var onRemoteChange: (() -> Void)?

    // MARK: - Initialization

    private init() throws {
        let schema = Schema([
            RecipeEntity.self,
            UserPreferencesEntity.self
        ])

        let cloudConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.com.littlechef.app")
        )

        // Built into locals and assigned in one go at the end: `cloudSyncStatus` is `@Published`,
        // and touching a property wrapper mid-init is `self` used before every stored property
        // has a value.
        let container: ModelContainer
        let status: CloudSyncStatus

        do {
            container = try ModelContainer(for: schema, configurations: [cloudConfiguration])
            status = .syncing
            Self.log.notice("Store opened with CloudKit mirroring (iCloud.com.littlechef.app)")
        } catch {
            // CloudKit can be unavailable at runtime (no iCloud account signed in,
            // restricted iCloud, provisioning/entitlement issues during review, etc.).
            // Fall back to a local-only store so the app still launches and works
            // rather than crashing on first run.
            //
            // This branch is a silent data-loss trap — writes look like they worked and then
            // die with the app — so it is recorded rather than shrugged off, and surfaced in
            // Settings. Log at `error` so it shows up in a device console without a debugger.
            Self.log.error(
                "CloudKit-backed ModelContainer failed; falling back to a LOCAL-ONLY store. Recipes saved on this device will not reach iCloud and will not survive reinstalling. Error: \(error.localizedDescription, privacy: .public)")
            status = .localOnly(reason: error.localizedDescription)
            let localConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false
            )
            container = try ModelContainer(for: schema, configurations: [localConfiguration])
        }

        modelContainer = container
        // `mainContext`, not a freshly built `ModelContext`. Tidy-up, not part of the sync fix —
        // mirroring happens below the context — but a hand-rolled context is a second context
        // over the same container with autosave off, and this manager is `@MainActor` anyway.
        // Using the container's own main context means one context and a save-on-tick backstop
        // behind the explicit `save()` calls.
        modelContext = container.mainContext
        cloudSyncStatus = status

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
        useBigBroSpeech: Bool? = nil,
        wakePhrase: String? = nil,
        bigBroVoice: String? = nil,
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
            useBigBroSpeech: useBigBroSpeech,
            wakePhrase: wakePhrase,
            bigBroVoice: bigBroVoice,
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
        preferences.useBigBroSpeech = false
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
