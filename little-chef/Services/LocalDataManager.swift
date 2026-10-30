//
//  LocalDataManager.swift
//  little-chef
//
//  Manages local data persistence using SwiftData
//

import Combine
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

    /// Fires when the store changed underneath whatever you last read out of it: a CloudKit
    /// import from another device, or a bulk local write that no per-screen cache saw.
    ///
    /// A subject rather than the `onRemoteChange` closure this replaces. That was a single
    /// property, and `RecipeManager` — which is instantiated twice, once in `MainView` and once
    /// in `RecipeListView` — assigned it in `init`. The second one to be built silently
    /// overwrote the first, so exactly one of the two ever heard about a remote change and the
    /// other showed a recipe list that no longer matched the store. Every subscriber gets this.
    ///
    /// Deliberately not sent for ordinary single-record writes: the caller that made the change
    /// already updated its own state, and `ProfileSettingsView` writes a preference on every
    /// `onChange`, so echoing those back would put it in a save/load loop with itself.
    let storeDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Initialization

    private init() throws {
        let schema = Schema([
            RecipeEntity.self,
            UserPreferencesEntity.self,
            PantryItemEntity.self,
            ShoppingItemEntity.self
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
                self?.storeDidChange.send()
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

    /// Delete a recipe.
    ///
    /// Idempotent, because with two devices "it isn't there" is a normal outcome rather than an
    /// error: the other device deleted it and the import landed between this screen rendering
    /// and the user confirming. The caller wanted it gone and it is gone — raising
    /// `recipeNotFound` here only put "Recipe with ID <uuid> not found" in front of someone who
    /// had just successfully deleted a recipe.
    func deleteRecipe(id: UUID) throws {
        guard let recipe = try fetchRecipe(id: id) else { return }

        modelContext.delete(recipe)
        try modelContext.save()
    }

    /// Delete multiple recipes
    func deleteRecipes(ids: [UUID]) throws {
        let descriptor = FetchDescriptor<RecipeEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let recipes = try modelContext.fetch(descriptor)
        guard !recipes.isEmpty else { return }
        recipes.forEach { modelContext.delete($0) }
        try modelContext.save()
        storeDidChange.send()
    }

    /// Deletes every recipe and preference row.
    ///
    /// Row by row through the context rather than a batch delete, so the deletions go through
    /// the same path CloudKit mirroring exports from: the user's iCloud copy and their other
    /// devices empty too. That is what "delete all my data" has to mean while sync is on —
    /// otherwise the next import would quietly put everything back.
    func deleteAllData() throws {
        for recipe in try modelContext.fetch(FetchDescriptor<RecipeEntity>()) {
            modelContext.delete(recipe)
        }
        for preferences in try modelContext.fetch(FetchDescriptor<UserPreferencesEntity>()) {
            modelContext.delete(preferences)
        }
        for item in try modelContext.fetch(FetchDescriptor<PantryItemEntity>()) {
            modelContext.delete(item)
        }
        for item in try modelContext.fetch(FetchDescriptor<ShoppingItemEntity>()) {
            modelContext.delete(item)
        }
        try modelContext.save()
        Self.log.notice("Deleted all recipes, preferences, inventory and shopping list at the user's request")
        // So the default staples come back, as the default settings do.
        UserDefaults.standard.removeObject(forKey: KitchenManager.staplesSeededKey)
        storeDidChange.send()
    }

    // MARK: - Kitchen Operations

    /// The inventory, with any duplicate names collapsed.
    ///
    /// Duplicates arrive the same way preference rows do: two devices each seed the default
    /// staples before either has imported the other's, or the same item is added on both. The
    /// oldest row wins, ties broken on `id`, so every device deletes the same losers and the
    /// store converges instead of each device keeping its own copy.
    func fetchPantryItems() throws -> [PantryItemEntity] {
        let items = try modelContext.fetch(FetchDescriptor<PantryItemEntity>())
        return try collapseDuplicates(items, name: \.name, createdAt: \.createdAt, id: \.id)
    }

    /// Adds `name` to the inventory, or returns the item already there under the same name.
    @discardableResult
    func addPantryItem(name: String, note: String? = nil, isStaple: Bool = false) throws -> PantryItemEntity {
        if let existing = try fetchPantryItems().first(where: { IngredientMatcher.sameItem($0.name, name) }) {
            return existing
        }
        let item = PantryItemEntity(name: name, note: note, isStaple: isStaple)
        modelContext.insert(item)
        try modelContext.save()
        return item
    }

    func updatePantryItem(id: UUID, name: String? = nil, note: String?? = nil, isStaple: Bool? = nil) throws {
        let descriptor = FetchDescriptor<PantryItemEntity>(predicate: #Predicate { $0.id == id })
        guard let item = try modelContext.fetch(descriptor).first else { return }
        if let name { item.name = name }
        if let note { item.note = note }
        if let isStaple { item.isStaple = isStaple }
        item.updatedAt = Date()
        try modelContext.save()
    }

    /// Idempotent for the same reason ``deleteRecipe(id:)`` is.
    func deletePantryItems(ids: [UUID]) throws {
        let descriptor = FetchDescriptor<PantryItemEntity>(predicate: #Predicate { ids.contains($0.id) })
        let items = try modelContext.fetch(descriptor)
        guard !items.isEmpty else { return }
        items.forEach { modelContext.delete($0) }
        try modelContext.save()
    }

    /// The shopping list, with duplicate names collapsed as ``fetchPantryItems()`` does.
    func fetchShoppingItems() throws -> [ShoppingItemEntity] {
        let items = try modelContext.fetch(FetchDescriptor<ShoppingItemEntity>())
        return try collapseDuplicates(items, name: \.name, createdAt: \.createdAt, id: \.id)
    }

    /// Adds `name` to the shopping list unless it's already on it. Returns whether it was added.
    @discardableResult
    func addShoppingItem(name: String, note: String? = nil, recipeTitle: String? = nil) throws -> Bool {
        if try fetchShoppingItems().contains(where: { IngredientMatcher.sameItem($0.name, name) }) {
            return false
        }
        modelContext.insert(ShoppingItemEntity(name: name, note: note, recipeTitle: recipeTitle))
        try modelContext.save()
        return true
    }

    func setShoppingItemChecked(id: UUID, isChecked: Bool) throws {
        let descriptor = FetchDescriptor<ShoppingItemEntity>(predicate: #Predicate { $0.id == id })
        guard let item = try modelContext.fetch(descriptor).first else { return }
        item.isChecked = isChecked
        item.updatedAt = Date()
        try modelContext.save()
    }

    func deleteShoppingItems(ids: [UUID]) throws {
        let descriptor = FetchDescriptor<ShoppingItemEntity>(predicate: #Predicate { ids.contains($0.id) })
        let items = try modelContext.fetch(descriptor)
        guard !items.isEmpty else { return }
        items.forEach { modelContext.delete($0) }
        try modelContext.save()
    }

    /// Moves every checked shopping item into the inventory, in one save. Returns how many moved.
    @discardableResult
    func moveCheckedShoppingItemsToPantry() throws -> Int {
        let checked = try fetchShoppingItems().filter(\.isChecked)
        guard !checked.isEmpty else { return 0 }
        let pantry = try fetchPantryItems()
        for item in checked {
            if !pantry.contains(where: { IngredientMatcher.sameItem($0.name, item.name) }) {
                modelContext.insert(PantryItemEntity(name: item.name, note: item.note))
            }
            modelContext.delete(item)
        }
        try modelContext.save()
        return checked.count
    }

    /// Keeps the oldest row of each name and deletes the rest.
    private func collapseDuplicates<T: PersistentModel>(
        _ items: [T],
        name: KeyPath<T, String>,
        createdAt: KeyPath<T, Date>,
        id: KeyPath<T, UUID>
    ) throws -> [T] {
        let ordered = items.sorted {
            ($0[keyPath: createdAt], $0[keyPath: id].uuidString) < ($1[keyPath: createdAt], $1[keyPath: id].uuidString)
        }
        var kept: [T] = []
        var losers: [T] = []
        for item in ordered {
            if kept.contains(where: { IngredientMatcher.sameItem($0[keyPath: name], item[keyPath: name]) }) {
                losers.append(item)
            } else {
                kept.append(item)
            }
        }
        if !losers.isEmpty {
            Self.log.notice("Collapsing \(losers.count) duplicate \(String(describing: T.self)) rows")
            losers.forEach { modelContext.delete($0) }
            try modelContext.save()
        }
        return kept
    }

    // MARK: - User Preferences Operations

    /// Fetch user preferences (creates default if none exist)
    ///
    /// Preferences are meant to be a single row, and CloudKit gives no way to say so —
    /// `@Attribute(.unique)` is rejected outright on a mirrored model. So duplicates are a
    /// question of when, not if: every fresh device calls this before its first import lands,
    /// finds nothing, and inserts its own defaults. Two devices, two rows, both synced.
    ///
    /// The old `preferences.first` on an unsorted fetch then picked between them arbitrarily,
    /// which reads as settings that revert on their own — a saved speech rate showing up as the
    /// default on the next launch, and back again after that.
    ///
    /// So collapse them here instead. The winner is the most recently updated row, ties broken
    /// on `id` so the choice is total rather than merely mostly-ordered; every device sees the
    /// same set once synced, computes the same winner, and deletes the same losers, so this
    /// converges rather than each device fighting for its own copy.
    func fetchPreferences() throws -> UserPreferencesEntity {
        let preferences = try modelContext.fetch(FetchDescriptor<UserPreferencesEntity>())
            // Sorted here rather than in the descriptor: the tie-break is `UUID`, which isn't
            // `Comparable` and so can't be a `SortDescriptor` key path.
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }

        guard let winner = preferences.first else {
            let defaultPrefs = UserPreferencesEntity.createDefault()
            modelContext.insert(defaultPrefs)
            try modelContext.save()
            return defaultPrefs
        }

        if preferences.count > 1 {
            Self.log.notice("Collapsing \(preferences.count - 1) duplicate preference rows merged in from another device")
            for duplicate in preferences.dropFirst() {
                modelContext.delete(duplicate)
            }
            try modelContext.save()
        }

        return winner
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
