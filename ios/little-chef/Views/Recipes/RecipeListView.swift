//
//  RecipeListView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct RecipeListView: View {
    @EnvironmentObject var recipeManager: RecipeManager
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
            VStack(spacing: 0) {
                // Custom search bar positioned below title
                if !recipeManager.recipes.isEmpty {
                    SearchBar(text: $searchText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                
                // Main content area
                Group {
                    if recipeManager.isLoading && recipeManager.recipes.isEmpty {
                        // Loading state
                        VStack {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Loading your recipes...")
                                .foregroundColor(.secondary)
                                .padding(.top)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if recipeManager.recipes.isEmpty {
                        // Empty state
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
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Recipe list
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
            }
            .navigationTitle("My Recipes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingAddRecipe = true
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddRecipe) {
                AddRecipeView()
                    .environmentObject(recipeManager)
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

struct RecipeRowView: View {
    let recipe: Recipe
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            // Time and servings info
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
            
            // Tags (if available)
            if !recipe.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
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
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.vertical, 4)
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
    @State private var isEditing = false
    
    var body: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search recipes, ingredients, or tags", text: $text)
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
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .foregroundColor(.orange)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isEditing)
    }
}

#Preview {
    RecipeListView()
}
