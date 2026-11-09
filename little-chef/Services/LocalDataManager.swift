//
//  LocalDataManager.swift
//  little-chef
//
//  The SwiftData store: recipes, preferences, inventory and shopping list, on this device only.
//  Export Profile and Import Profile move it between devices. See CLAUDE.md, "Storage".
//

import Combine
import Foundation
import OSLog
import SwiftData

/// The app's SwiftData store, kept on the device. Nothing in it leaves the device except in a
/// profile the user exports.
@MainActor
class LocalDataManager: ObservableObject {
    static let shared: LocalDataManager = {
        do {
            return try LocalDataManager()
        } catch {
            fatalError("Failed to initialize LocalDataManager: \(error)")
        }
    }()

    /// Release builds need this: `dprint` compiles to nothing outside DEBUG.
    private static let log = Logger(subsystem: "NagataInc.little-chef", category: "persistence")

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    /// Fires when the store changed underneath whatever you last read out of it: Delete All Data,
    /// or importing a profile.
    ///
    /// A subject rather than a closure property because there is more than one subscriber —
    /// `RecipeManager` and `KitchenManager` — and a single `var onRemoteChange` silently kept
    /// only the last one assigned.
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

        #if DEBUG
        let screenshots = ScreenshotFixtures.isActive
        #else
        let screenshots = false
        #endif

        // `.none` spelled out. The default, `.automatic`, mirrors to CloudKit whenever the app
        // carries an iCloud entitlement, and this store must never start doing that again
        // because someone ticked a capability in Xcode.
        //
        // The screenshots get sample content in memory, never the Simulator's own store.
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: screenshots,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])

        modelContainer = container
        // The container's own main context: one context, with a save-on-tick backstop behind the
        // explicit `save()` calls, and this manager is `@MainActor` anyway.
        modelContext = container.mainContext

        #if DEBUG
        if screenshots { seedScreenshotContent() }
        #endif
    }

    #if DEBUG
    /// Fills the in-memory store for the screenshots. Recipes are listed newest first, so they
    /// go in last to first.
    private func seedScreenshotContent() {
        do {
            for recipe in ScreenshotFixtures.recipes.reversed() { try createRecipe(recipe) }
            for item in ScreenshotFixtures.pantry { _ = try addPantryItem(name: item.name, isStaple: item.isStaple) }
            for item in ScreenshotFixtures.shoppingList {
                _ = try addShoppingItem(name: item.name, recipeTitle: item.recipeTitle)
            }
        } catch {
            Self.log.error("Seeding the screenshot content failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

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

    /// Create a new recipe
    @discardableResult
    func createRecipe(_ recipeData: RecipeData) throws -> RecipeEntity {
        let recipe = RecipeEntity.from(recipeData)
        modelContext.insert(recipe)
        try modelContext.save()
        return recipe
    }

    /// Update an existing recipe
    func updateRecipe(id: UUID, with recipeData: RecipeData) throws {
        guard let recipe = try fetchRecipe(id: id) else {
            throw LocalDataError.recipeNotFound(id)
        }

        recipe.update(from: recipeData)
        try modelContext.save()
    }

    /// Delete a recipe. Idempotent: the caller wanted it gone, and if it already is, that is
    /// not an error to show anyone.
    func deleteRecipe(id: UUID) throws {
        guard let recipe = try fetchRecipe(id: id) else { return }

        modelContext.delete(recipe)
        try modelContext.save()
    }

    /// Deletes every recipe, preference, inventory and shopping-list row.
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

    /// The inventory, with any duplicate names collapsed: the oldest row wins, ties broken on
    /// `id`.
    ///
    /// Nothing written now makes duplicates — adding and importing both match by name — but a
    /// store from the builds that synced through iCloud can hold them: two devices each seeded
    /// the staples before either had the other's.
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

    func updatePantryItem(id: UUID, note: String?? = nil, isStaple: Bool? = nil) throws {
        let descriptor = FetchDescriptor<PantryItemEntity>(predicate: #Predicate { $0.id == id })
        guard let item = try modelContext.fetch(descriptor).first else { return }
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

    /// The user's preferences, created with the defaults if there are none.
    ///
    /// One row, but a store from the builds that synced through iCloud can hold several: every
    /// device inserted its own defaults before the other's arrived. Picking `.first` of an
    /// unsorted fetch read as settings that revert on their own, so the most recently updated
    /// row wins, ties broken on `id`, and the rest are deleted.
    func fetchPreferences() throws -> UserPreferencesEntity {
        let preferences = try modelContext.fetch(FetchDescriptor<UserPreferencesEntity>())
            // Sorted here rather than in the descriptor: the tie-break is `UUID`, which isn't
            // `Comparable` and so can't be a `SortDescriptor` key path.
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }

        guard let winner = preferences.first else {
            let defaultPrefs = UserPreferencesEntity()
            modelContext.insert(defaultPrefs)
            try modelContext.save()
            return defaultPrefs
        }

        if preferences.count > 1 {
            Self.log.notice("Collapsing \(preferences.count - 1) duplicate preference rows")
            for duplicate in preferences.dropFirst() {
                modelContext.delete(duplicate)
            }
            try modelContext.save()
        }

        return winner
    }

    func updatePreferences(voiceSettings: LocalVoiceSettings, llmProvider: LLMProvider) throws {
        try fetchPreferences().update(voiceSettings: voiceSettings, llmProvider: llmProvider)
        try modelContext.save()
    }

    // MARK: - Profile export and import

    /// Everything in the store, as a profile file holds it. See ``ProfileBackup``.
    func exportProfile(onDeviceModel: CookingModelChoice?) throws -> ProfileBackup {
        let preferences = try fetchPreferences().toUserPreferences()
        return ProfileBackup(
            exportedAt: Date(),
            recipes: try fetchAllRecipes().map { $0.toRecipe() },
            pantry: try fetchPantryItems().map {
                .init(name: $0.name, note: $0.note, isStaple: $0.isStaple, createdAt: $0.createdAt)
            },
            shoppingList: try fetchShoppingItems().map {
                .init(name: $0.name, note: $0.note, isChecked: $0.isChecked,
                      recipeTitle: $0.recipeTitle, createdAt: $0.createdAt)
            },
            settings: .init(
                voiceSettings: preferences.voiceSettings,
                llmProvider: preferences.llmProvider,
                onDeviceModel: onDeviceModel
            )
        )
    }

    /// Merges a profile into the store, in one save, as ``ProfileBackup/importPlan`` describes.
    /// Recipes keep the ids and dates they were exported with, so importing the same file again
    /// adds nothing.
    @discardableResult
    func importProfile(_ backup: ProfileBackup) throws -> ProfileImportSummary {
        let recipes = try fetchAllRecipes()
        let plan = backup.importPlan(
            existingRecipes: Dictionary(recipes.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: max),
            existingPantryNames: try fetchPantryItems().map(\.name),
            existingShoppingNames: try fetchShoppingItems().map(\.name)
        )

        for recipe in plan.recipesToAdd {
            modelContext.insert(RecipeEntity(
                id: recipe.id, title: recipe.title, description: recipe.description,
                servings: recipe.servings, prepTime: recipe.prepTime, cookTime: recipe.cookTime,
                ingredients: recipe.ingredients, instructions: recipe.instructions, tags: recipe.tags,
                sourceUrl: recipe.sourceUrl, cuisineType: recipe.cuisineType, difficulty: recipe.difficulty,
                createdAt: recipe.createdAt, updatedAt: recipe.updatedAt
            ))
        }
        for recipe in plan.recipesToUpdate {
            guard let entity = recipes.first(where: { $0.id == recipe.id }) else { continue }
            entity.update(from: RecipeData(
                title: recipe.title, description: recipe.description, servings: recipe.servings,
                prepTime: recipe.prepTime, cookTime: recipe.cookTime, ingredients: recipe.ingredients,
                instructions: recipe.instructions, tags: recipe.tags, sourceUrl: recipe.sourceUrl,
                cuisineType: recipe.cuisineType, difficulty: recipe.difficulty
            ))
            // The file's date, not now: it is the same edit, made elsewhere.
            entity.updatedAt = recipe.updatedAt
        }
        for item in plan.pantryToAdd {
            let entity = PantryItemEntity(name: item.name, note: item.note, isStaple: item.isStaple)
            entity.createdAt = item.createdAt
            modelContext.insert(entity)
        }
        for item in plan.shoppingToAdd {
            let entity = ShoppingItemEntity(name: item.name, note: item.note, recipeTitle: item.recipeTitle)
            entity.isChecked = item.isChecked
            entity.createdAt = item.createdAt
            modelContext.insert(entity)
        }
        try fetchPreferences().update(
            voiceSettings: backup.settings.voiceSettings,
            llmProvider: backup.settings.llmProvider
        )

        try modelContext.save()
        Self.log.notice("Imported a profile: \(plan.recipesToAdd.count) recipes added, \(plan.recipesToUpdate.count) updated, \(plan.pantryToAdd.count) inventory and \(plan.shoppingToAdd.count) shopping items added")
        storeDidChange.send()

        return ProfileImportSummary(
            recipesAdded: plan.recipesToAdd.count,
            recipesUpdated: plan.recipesToUpdate.count,
            pantryAdded: plan.pantryToAdd.count,
            shoppingAdded: plan.shoppingToAdd.count
        )
    }
}

// MARK: - Error Types

enum LocalDataError: LocalizedError {
    case recipeNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .recipeNotFound:
            return "That recipe isn't in your collection any more."
        }
    }
}
