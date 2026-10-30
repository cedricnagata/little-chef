//
//  RecipeDetailView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct RecipeDetailView: View {
    let recipe: Recipe
    @State private var showingDeleteAlert = false
    @State private var isEditing = false
    @EnvironmentObject var recipeManager: RecipeManager
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var kitchenManager: KitchenManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.selectedTab) private var selectedTab

    /// The edit in progress. Nil unless editing, so there is no stale half-edit to accidentally
    /// save and no second copy of the recipe's fields to keep in step with `RecipeData`.
    @State private var draft: RecipeDraft?

    /// Set while the missing-ingredients warning is up, before a cook starts.
    @State private var missingCheck: MissingIngredientsCheck?
    /// How many items the last "add missing" put on the shopping list, for the confirmation line.
    @State private var addedToShoppingList: Int?

    /// What this recipe needs that the inventory doesn't have. Nil until the user keeps an
    /// inventory, so a recipe isn't shown as missing everything before they've started.
    private var availability: RecipeAvailability? {
        kitchenManager.isTrackingInventory ? kitchenManager.availability(of: currentRecipe) : nil
    }

    /// The recipe as the store currently has it.
    ///
    /// `recipe` is the copy this screen was pushed with, and it never changes. Saving an edit
    /// rewrites the store and reloads the list, so reading the display off the passed-in value
    /// meant the screen you saved from went on showing the recipe you had just replaced until
    /// you navigated away and back.
    private var currentRecipe: Recipe {
        recipeManager.recipes.first { $0.id == recipe.id } ?? recipe
    }

    var body: some View {
        Group {
            if isEditing, draft != nil {
                RecipeEditorForm(draft: Binding(
                    get: { draft ?? RecipeDraft(from: currentRecipe) },
                    set: { draft = $0 }
                ))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        displayContent
                    }
                }
            }
        }
        .navigationTitle("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { cancelEdit() }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditing {
                    Button("Save") { saveEdit() }
                        .fontWeight(.semibold)
                        .disabled(draft?.isValid != true)
                } else {
                    Menu {
                        Button(action: { startCookingSession() }) {
                            Label("Start Cooking", systemImage: "flame.fill")
                        }
                        Button(action: { startEditing() }) {
                            Label("Edit Recipe", systemImage: "pencil")
                        }
                        Button(role: .destructive, action: { showingDeleteAlert = true }) {
                            Label("Delete Recipe", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .missingIngredientsDialog($missingCheck) { _ in beginCooking() }
        .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    let success = await recipeManager.deleteRecipe(recipe)
                    if success { dismiss() }
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(currentRecipe.title)'? This action cannot be undone.")
        }
    }

    // MARK: - Display Content (read-only)

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                Text(currentRecipe.title)
                    .font(.title)
                    .fontWeight(.bold)

                if let description = currentRecipe.description {
                    Text(description)
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                    if let prepTime = currentRecipe.prepTime {
                        InfoCard(title: "Prep Time", value: "\(prepTime) min", icon: "clock")
                    }
                    if let cookTime = currentRecipe.cookTime {
                        InfoCard(title: "Cook Time", value: "\(cookTime) min", icon: "flame")
                    }
                    InfoCard(title: "Servings", value: "\(currentRecipe.servings)", icon: "person.2")
                    if let difficulty = currentRecipe.difficulty {
                        InfoCard(title: "Difficulty", value: difficulty.capitalized, icon: "star")
                    }
                }

                if !currentRecipe.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(currentRecipe.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.15))
                                    .cornerRadius(12)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)

            Divider()

            // Ingredients
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Ingredients")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(currentRecipe.ingredients.count) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                let availability = self.availability
                let missingLines = Set(availability?.missing ?? [])
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(currentRecipe.ingredients.enumerated()), id: \.offset) { _, ingredient in
                        HStack(alignment: .top, spacing: 12) {
                            if availability == nil {
                                Circle()
                                    .fill(Color.orange.opacity(0.2))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 6)
                            } else if missingLines.contains(ingredient) {
                                Image(systemName: "cart")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .padding(.top, 3)
                                    .accessibilityLabel("Missing")
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                    .padding(.top, 3)
                                    .accessibilityLabel("In your kitchen")
                            }
                            Text(ingredient)
                                .font(.body)
                            Spacer()
                        }
                    }
                }

                if let availability, !availability.canMake {
                    Button {
                        addedToShoppingList = kitchenManager.addToShoppingList(
                            availability.missingNames, recipeTitle: currentRecipe.title)
                    } label: {
                        Label("Add \(availability.missingNames.count) missing to shopping list", systemImage: "cart.badge.plus")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    if let added = addedToShoppingList {
                        Text(added == 0 ? "Already on your shopping list." : "Added \(added) to your shopping list.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            Divider()

            // Instructions
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Instructions")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(currentRecipe.instructions.count) steps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(currentRecipe.instructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 24, height: 24)
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }
                            Text(instruction)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Source URL
            if let sourceUrl = currentRecipe.sourceUrl, !sourceUrl.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Source")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let url = URL(string: sourceUrl) {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "link")
                                Text("View Original Recipe")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .foregroundColor(.orange)
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer(minLength: 20)
        }
    }

    // MARK: - Editing

    private func startEditing() {
        draft = RecipeDraft(from: currentRecipe)
        withAnimation { isEditing = true }
    }

    private func cancelEdit() {
        dismissKeyboard()
        draft = nil
        withAnimation { isEditing = false }
    }

    private func saveEdit() {
        guard let updated = draft?.toRecipeData() else { return }
        dismissKeyboard()
        Task {
            await updateRecipe(updated)
            draft = nil
            withAnimation { isEditing = false }
        }
    }

    private func startCookingSession() {
        if let check = kitchenManager.checkBeforeCooking(currentRecipe) {
            missingCheck = check
        } else {
            beginCooking()
        }
    }

    private func beginCooking() {
        Task { await cookingSessionManager.startCookingSession(with: currentRecipe) }
        dismiss()
        selectedTab.wrappedValue = 1
    }

    private func updateRecipe(_ updatedRecipe: RecipeData) async {
        let success = await recipeManager.updateRecipe(id: recipe.id, with: updatedRecipe)
        if !success {
            dprint("Failed to update recipe: \(recipeManager.errorMessage ?? "Unknown error")")
        }
    }
}

// MARK: - Info Card

struct InfoCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.orange)
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

