//
//  KitchenManager.swift
//  little-chef
//
//  The ingredient inventory and shopping list, and what they mean for each recipe.
//

import Foundation
import Combine

@MainActor
final class KitchenManager: ObservableObject {
    @Published private(set) var pantry: [PantryItem] = []
    @Published private(set) var shoppingList: [ShoppingItem] = []
    @Published var errorMessage: String?

    /// The last ranking for the Suggested filter, and whether one is being worked out.
    @Published private(set) var suggestions: RecipeSuggestions?
    @Published private(set) var isRankingSuggestions = false

    /// Set once this device has seeded the default staples. Per device, so a fresh install seeds
    /// before iCloud has delivered anything. A second device's seeding produces duplicates that
    /// ``LocalDataManager/fetchPantryItems()`` collapses. Cleared by Delete All Data, which
    /// brings the defaults back like the other settings.
    static let staplesSeededKey = "little-chef.staples-seeded"

    private let dataManager: LocalDataManager
    private let llmService: LLMService
    private var cancellables = Set<AnyCancellable>()

    /// What `suggestions` was ranked from. A different meal, inventory or recipe list means a
    /// new ranking; the same one reuses it rather than asking the model again.
    private var suggestionsKey: String?

    convenience init() {
        self.init(dataManager: .shared, llmService: .shared)
    }

    init(dataManager: LocalDataManager, llmService: LLMService) {
        self.dataManager = dataManager
        self.llmService = llmService

        // An import from another device, or Delete All Data. Ordinary single edits made here
        // update `pantry` and `shoppingList` directly, so they don't need this.
        dataManager.storeDidChange
            .sink { [weak self] _ in Task { @MainActor in self?.load() } }
            .store(in: &cancellables)
        load()
    }

    // MARK: - Loading

    func load() {
        do {
            seedStaplesIfNeeded()
            pantry = try dataManager.fetchPantryItems()
                .map { $0.toItem() }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            shoppingList = try dataManager.fetchShoppingItems()
                .map { $0.toItem() }
                .sorted { $0.createdAt < $1.createdAt }
        } catch {
            errorMessage = "Couldn't load your kitchen: \(error.localizedDescription)"
        }
    }

    private func seedStaplesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.staplesSeededKey) else { return }
        do {
            for name in IngredientMatcher.defaultStaples {
                try dataManager.addPantryItem(name: name, isStaple: true)
            }
            defaults.set(true, forKey: Self.staplesSeededKey)
        } catch {
            // Left unset, so the next load tries again.
            errorMessage = "Couldn't add the default staples: \(error.localizedDescription)"
        }
    }

    // MARK: - Inventory

    func addToPantry(_ name: String, isStaple: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform { _ = try self.dataManager.addPantryItem(name: trimmed, isStaple: isStaple) }
    }

    func setStaple(_ item: PantryItem, isStaple: Bool) {
        perform { try self.dataManager.updatePantryItem(id: item.id, isStaple: isStaple) }
    }

    func setNote(_ item: PantryItem, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        perform { try self.dataManager.updatePantryItem(id: item.id, note: .some(trimmed.isEmpty ? nil : trimmed)) }
    }

    func removeFromPantry(_ items: [PantryItem]) {
        perform { try self.dataManager.deletePantryItems(ids: items.map(\.id)) }
    }

    // MARK: - Shopping list

    /// Adds each name the list doesn't already have. Returns how many were new.
    @discardableResult
    func addToShoppingList(_ names: [String], recipeTitle: String? = nil) -> Int {
        var added = 0
        perform {
            for name in names {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if try self.dataManager.addShoppingItem(name: trimmed, recipeTitle: recipeTitle) { added += 1 }
            }
        }
        return added
    }

    func toggleChecked(_ item: ShoppingItem) {
        perform { try self.dataManager.setShoppingItemChecked(id: item.id, isChecked: !item.isChecked) }
    }

    func removeFromShoppingList(_ items: [ShoppingItem]) {
        perform { try self.dataManager.deleteShoppingItems(ids: items.map(\.id)) }
    }

    /// Done shopping: everything ticked off goes into the inventory and off the list.
    func moveCheckedToPantry() {
        perform { _ = try self.dataManager.moveCheckedShoppingItemsToPantry() }
    }

    var hasCheckedItems: Bool { shoppingList.contains(where: \.isChecked) }

    // MARK: - Recipes

    /// Every inventory name, staples included: what recipes are matched against.
    var inventoryNames: [String] { pantry.map(\.name) }

    func availability(of recipe: Recipe) -> RecipeAvailability {
        IngredientMatcher.availability(of: recipe.ingredients, inventory: inventoryNames)
    }

    func availability(of recipes: [Recipe]) -> [UUID: RecipeAvailability] {
        let names = inventoryNames
        return Dictionary(
            recipes.map { ($0.id, IngredientMatcher.availability(of: $0.ingredients, inventory: names)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Ranks `recipes` for the Suggested filter, reusing the last ranking when nothing it
    /// depends on has changed. `force` re-asks even then, for a manual refresh.
    func refreshSuggestions(for recipes: [Recipe], force: Bool = false) async {
        let meal = MealPeriod(date: Date())
        let key = [
            meal.rawValue,
            inventoryNames.map { $0.lowercased() }.sorted().joined(separator: "|"),
            recipes.map { "\($0.id)@\($0.updatedAt.timeIntervalSince1970)" }.sorted().joined(separator: ","),
        ].joined(separator: "#")
        guard force || key != suggestionsKey || suggestions == nil else { return }
        guard !isRankingSuggestions else { return }

        isRankingSuggestions = true
        defer { isRankingSuggestions = false }
        let ranked = await RecipeSuggester.rank(recipes, availability: availability(of: recipes), llmService: llmService)
        suggestions = ranked
        suggestionsKey = key
    }

    // MARK: - Helpers

    /// Runs a write and reloads from the store, so the published lists always match it.
    private func perform(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            errorMessage = error.localizedDescription
        }
        load()
    }
}
