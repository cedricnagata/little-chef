//
//  RecipeListView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct RecipeListView: View {
    /// `MainView`'s manager, not one of its own.
    ///
    /// This used to be a `@StateObject`, which meant two `RecipeManager`s over one store: this
    /// one, and the one `MainView` hands to the cooking tab. Two independent `recipes` arrays,
    /// so adding a recipe here left the cooking tab's recipe picker showing the old list until
    /// it happened to refetch. One store, one manager.
    @EnvironmentObject var recipeManager: RecipeManager
    @EnvironmentObject var kitchenManager: KitchenManager
    @State private var showingAddRecipe = false
    @State private var searchText = ""
    @State private var filter: RecipeFilter = .all

    enum RecipeFilter: String, CaseIterable, Identifiable {
        case all = "All Recipes"
        case canMake = "Can Make Now"
        case almost = "Missing a Few"
        case suggested = "Suggested"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .canMake: return "checkmark.circle"
            case .almost: return "cart"
            case .suggested: return "sparkles"
            }
        }
    }

    /// Worked out once per render for every recipe, rather than once per row.
    private var availability: [UUID: RecipeAvailability] {
        kitchenManager.availability(of: recipeManager.recipes)
    }

    private func filteredRecipes(_ availability: [UUID: RecipeAvailability]) -> [Recipe] {
        let searched = searchText.isEmpty ? recipeManager.recipes : recipeManager.recipes.filter { recipe in
            recipe.title.localizedCaseInsensitiveContains(searchText) ||
            recipe.ingredients.joined().localizedCaseInsensitiveContains(searchText) ||
            recipe.tags.joined().localizedCaseInsensitiveContains(searchText)
        }
        func missing(_ recipe: Recipe) -> Int { availability[recipe.id]?.missing.count ?? .max }

        // Before the user keeps an inventory, "can make" would mean "needs only staples".
        if filter == .canMake || filter == .almost, !kitchenManager.isTrackingInventory { return [] }

        switch filter {
        case .all:
            return searched
        case .canMake:
            return searched.filter { missing($0) == 0 }
        case .almost:
            return searched
                .filter { (1...IngredientMatcher.almostThreshold).contains(missing($0)) }
                .sorted { missing($0) < missing($1) }
        case .suggested:
            guard let order = kitchenManager.suggestions?.order else { return searched }
            let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return searched.sorted { (position[$0.id] ?? .max) < (position[$1.id] ?? .max) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if recipeManager.isLoading && recipeManager.recipes.isEmpty {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading your recipes...")
                            .foregroundColor(.secondary)
                            .padding(.top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if recipeManager.recipes.isEmpty {
                    ContentUnavailableView {
                        Label("No Recipes Yet", systemImage: "book.fill")
                    } description: {
                        Text("Add your first recipe to get started with LittleChef!")
                    } actions: {
                        Button(action: { showingAddRecipe = true }) {
                            Text("Add Recipe")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                } else {
                    let availability = self.availability
                    let recipes = filteredRecipes(availability)
                    List {
                        filterHeader

                        if recipes.isEmpty, filter != .all {
                            emptyFilterMessage
                        }

                        ForEach(recipes) { recipe in
                            NavigationLink(destination: RecipeDetailView(recipe: recipe).environmentObject(recipeManager)) {
                                RecipeRowView(
                                    recipe: recipe,
                                    availability: kitchenManager.isTrackingInventory ? availability[recipe.id] : nil
                                )
                            }
                        }
                        .onDelete { offsets in deleteRecipes(offsets.map { recipes[$0] }) }
                    }
                    .refreshable {
                        await recipeManager.loadRecipes()
                        if filter == .suggested { await kitchenManager.refreshSuggestions(for: recipeManager.recipes, force: true) }
                    }
                }
            }
            .navigationTitle("My Recipes")
            .searchable(text: $searchText, prompt: "Search recipes, ingredients, or tags")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(RecipeFilter.allCases) { option in
                                Label(option.rawValue, systemImage: option.icon).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: filter == .all
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter recipes")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddRecipe = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            // Re-run when the inventory or recipe list changes too. `refreshSuggestions` keeps the
            // last ranking when nothing it depends on has, so this asks the model only when needed.
            .task(id: "\(filter.rawValue)|\(kitchenManager.pantry.count)|\(recipeManager.recipes.count)") {
                if filter == .suggested { await kitchenManager.refreshSuggestions(for: recipeManager.recipes) }
            }
            .sheet(isPresented: $showingAddRecipe) {
                AddRecipeView()
                    .environmentObject(recipeManager)
            }
            .alert("Error", isPresented: .constant(recipeManager.errorMessage != nil)) {
                Button("OK") { recipeManager.clearError() }
            } message: {
                Text(recipeManager.errorMessage ?? "")
            }
        }
        .task {
            await recipeManager.loadRecipes()
        }
    }

    private func deleteRecipes(_ recipes: [Recipe]) {
        for recipe in recipes {
            Task {
                await recipeManager.deleteRecipe(recipe)
            }
        }
    }

    // MARK: - Filter UI

    /// Says which filter is on, and for Suggested, what it was ranked for and how.
    @ViewBuilder
    private var filterHeader: some View {
        if filter == .suggested {
            HStack(spacing: 8) {
                if kitchenManager.isRankingSuggestions {
                    ProgressView()
                    Text("Finding the best recipes for \(MealPeriod(date: Date()).displayName)…")
                } else if let suggestions = kitchenManager.suggestions {
                    Image(systemName: "sparkles").foregroundColor(.orange)
                    Text(suggestions.rankedByAI
                         ? "Suggested for \(suggestions.mealPeriod.displayName)"
                         : "Suggested for \(suggestions.mealPeriod.displayName), by what you have (AI unavailable)")
                    Spacer()
                    Button {
                        Task { await kitchenManager.refreshSuggestions(for: recipeManager.recipes, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Re-rank suggestions")
                }
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        } else if filter != .all {
            Label(filter.rawValue, systemImage: filter.icon)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var emptyFilterMessage: some View {
        if !kitchenManager.isTrackingInventory {
            Text("Add the ingredients you have in the Kitchen tab, and this shows what you can make with them.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        } else if filter == .canMake {
            Text("Nothing you can make with just what's in your kitchen. Try Missing a Few.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        } else if filter == .almost {
            Text("No recipes are only one or two ingredients away.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Recipe Row

struct RecipeRowView: View {
    let recipe: Recipe
    /// Shown as "You have everything" or "Missing 2" when the user keeps an inventory.
    var availability: RecipeAvailability? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(2)

                Spacer()

                if let difficulty = recipe.difficulty {
                    DifficultyBadge(difficulty: difficulty)
                }
            }

            if let description = recipe.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack {
                if let prepTime = recipe.prepTime {
                    Label("\(prepTime)m prep", systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let cookTime = recipe.cookTime {
                    Label("\(cookTime)m cook", systemImage: "flame")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Label("\(recipe.servings) servings", systemImage: "person.2")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let availability {
                if availability.canMake {
                    Label("You have everything", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Label("Missing \(availability.missing.count)", systemImage: "cart")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if !recipe.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(recipe.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(8)
                    }

                    if recipe.tags.count > 3 {
                        Text("+\(recipe.tags.count - 3)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Difficulty Badge

struct DifficultyBadge: View {
    let difficulty: String

    var badgeColor: Color {
        switch difficulty.lowercased() {
        case "easy": return .green
        case "medium": return .orange
        case "hard": return .red
        default: return .gray
        }
    }

    var body: some View {
        Text(difficulty.capitalized)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor)
            .cornerRadius(6)
    }
}

#Preview {
    RecipeListView()
        .environmentObject(RecipeManager())
        .environmentObject(KitchenManager())
}
