//
//  RecipeListView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct RecipeListView: View {
    @EnvironmentObject var recipeManager: RecipeManager
    @FocusState private var isSearchFocused: Bool
    @State private var showingAddRecipe = false
    @State private var searchText = ""
    @State private var isRefreshing = false

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
            VStack(spacing: 0) {
                // Fixed header with large title
                VStack(alignment: .leading, spacing: 8) {
                    Text("My Recipes")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.systemBackground))

                // Custom search bar positioned below title
                if !recipeManager.recipes.isEmpty {
                    SearchBar(text: $searchText, isInputFocused: _isSearchFocused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                // Main content area with pull-to-refresh
                ScrollView {
                    if recipeManager.isSyncingWithCloud || (recipeManager.isLoading && recipeManager.recipes.isEmpty && !isRefreshing) {
                        // Loading state
                        VStack {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Syncing with iCloud...")
                                .foregroundColor(.secondary)
                                .padding(.top)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 400)
                    } else if recipeManager.recipes.isEmpty {
                        // Empty state with pull-to-refresh
                        VStack(spacing: 20) {
                            Image(systemName: "book.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.orange)

                            Text("No Recipes Yet")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text("Add your first recipe to get started with LittleChef!")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)

                            Button(action: {
                                showingAddRecipe = true
                            }) {
                                HStack {
                                    Image(systemName: "plus")
                                    Text("Add Recipe")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.orange)
                                .cornerRadius(12)
                            }

                            Text("Pull down to refresh from iCloud")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 400)
                    } else {
                        // Recipe list
                        LazyVStack(spacing: 0) {
                            ForEach(filteredRecipes) { recipe in
                                NavigationLink(destination: RecipeDetailView(recipe: recipe).environmentObject(recipeManager)) {
                                    RecipeRowView(recipe: recipe)
                                        .padding(.horizontal)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task {
                                            await recipeManager.deleteRecipe(recipe)
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }

                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
                .refreshable {
                    isRefreshing = true
                    // Trigger CloudKit sync on pull-to-refresh
                    await recipeManager.triggerCloudKitSync()
                    await recipeManager.loadRecipes()
                    isRefreshing = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingAddRecipe = true
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAddRecipe) {
                AddRecipeView()
                    .environmentObject(recipeManager)
                    .interactiveDismissDisabled()
            }
            .alert("Error", isPresented: .constant(recipeManager.errorMessage != nil)) {
                Button("OK") {
                    recipeManager.clearError()
                }
            } message: {
                Text(recipeManager.errorMessage ?? "")
            }
        }
        .task {
            // Sync with iCloud only if no local recipes exist
            await recipeManager.syncIfNeeded()
        }
    }
}

struct RecipeRowView: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Title and difficulty
            HStack {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(2)

                Spacer()

                if let difficulty = recipe.difficulty {
                    DifficultyBadge(difficulty: difficulty)
                }
            }

            // Description (if available)
            if let description = recipe.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            // Tags (if available)
            if !recipe.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(recipe.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .foregroundColor(DesignSystem.Colors.primary)
                                .padding(.horizontal, DesignSystem.Spacing.sm)
                                .padding(.vertical, DesignSystem.Spacing.xs)
                                .background(DesignSystem.Colors.primaryLight)
                                .cornerRadius(DesignSystem.CornerRadius.small)
                        }

                        if recipe.tags.count > 3 {
                            Text("+\(recipe.tags.count - 3)")
                                .font(.caption2)
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
    }
}

struct DifficultyBadge: View {
    let difficulty: String
    
    var badgeColor: Color {
        switch difficulty.lowercased() {
        case "easy":
            return .green
        case "medium":
            return .orange
        case "hard":
            return .red
        default:
            return .gray
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

struct SearchBar: View {
    @Binding var text: String
    @FocusState var isInputFocused: Bool
    @State private var isEditing = false

    var body: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search recipes, ingredients, or tags", text: $text)
                    .focused($isInputFocused)
                    .onTapGesture {
                        isEditing = true
                    }
                
                if !text.isEmpty {
                    Button(action: {
                        text = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            
            if isEditing {
                Button("Cancel") {
                    isEditing = false
                    text = ""
                    isInputFocused = false
                }
                .foregroundColor(.orange)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isEditing)
        .onChange(of: isInputFocused) { focused in
            if !focused {
                isEditing = false
            }
        }
    }
}

#Preview {
    RecipeListView()
}
