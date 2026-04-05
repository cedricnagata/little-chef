//
//  RecipeListView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct RecipeListView: View {
    @StateObject private var recipeManager = RecipeManager()
    @State private var showingAddRecipe = false
    @State private var searchText = ""

    var filteredRecipes: [Recipe] {
        if searchText.isEmpty {
            return recipeManager.recipes
        } else {
            return recipeManager.recipes.filter { recipe in
                recipe.title.localizedCaseInsensitiveContains(searchText) ||
                recipe.ingredients.joined().localizedCaseInsensitiveContains(searchText) ||
                recipe.tags.joined().localizedCaseInsensitiveContains(searchText)
            }
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
                    List {
                        ForEach(filteredRecipes) { recipe in
                            NavigationLink(destination: RecipeDetailView(recipe: recipe).environmentObject(recipeManager)) {
                                RecipeRowView(recipe: recipe)
                            }
                        }
                        .onDelete(perform: deleteRecipes)
                    }
                    .refreshable {
                        await recipeManager.loadRecipes()
                    }
                }
            }
            .navigationTitle("My Recipes")
            .searchable(text: $searchText, prompt: "Search recipes, ingredients, or tags")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddRecipe = true }) {
                        Image(systemName: "plus")
                    }
                }
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

    private func deleteRecipes(offsets: IndexSet) {
        for index in offsets {
            let recipe = filteredRecipes[index]
            Task {
                await recipeManager.deleteRecipe(recipe)
            }
        }
    }
}

// MARK: - Recipe Row

struct RecipeRowView: View {
    let recipe: Recipe

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
}
