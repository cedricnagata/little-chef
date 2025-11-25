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
    @State private var showingEditSheet = false
    @EnvironmentObject var recipeManager: RecipeManager
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.selectedTab) private var selectedTab
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 12) {
                    Text(recipe.title)
                        .font(.title)
                        .fontWeight(.bold)
                    
                    if let description = recipe.description {
                        Text(description)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    
                    // Recipe info grid
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                        if let prepTime = recipe.prepTime {
                            InfoCard(title: "Prep Time", value: "\(prepTime) min", icon: "clock")
                        }
                        
                        if let cookTime = recipe.cookTime {
                            InfoCard(title: "Cook Time", value: "\(cookTime) min", icon: "flame")
                        }
                        
                        InfoCard(title: "Servings", value: "\(recipe.servings)", icon: "person.2")
                        
                        if let difficulty = recipe.difficulty {
                            InfoCard(title: "Difficulty", value: difficulty.capitalized, icon: "star")
                        }
                    }
                    
                    // Tags
                    if !recipe.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recipe.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.orange.opacity(0.15))
                                        .cornerRadius(12)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.horizontal, -16)
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
                        
                        Text("\(recipe.ingredients.count) items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { index, ingredient in
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .fill(Color.orange.opacity(0.2))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 6)
                                
                                Text(ingredient)
                                    .font(.body)
                                
                                Spacer()
                            }
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
                        
                        Text("\(recipe.instructions.count) steps")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(recipe.instructions.enumerated()), id: \.offset) { index, instruction in
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
                
                // Source URL (if available)
                if let sourceUrl = recipe.sourceUrl, !sourceUrl.isEmpty {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Link(destination: URL(string: sourceUrl) ?? URL(string: "https://example.com")!) {
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
                    .padding(.horizontal)
                }
                
                Spacer(minLength: 20)
            }
        }
        .navigationTitle("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: {
                        // TODO: Share recipe
                    }) {
                        Label("Share Recipe", systemImage: "square.and.arrow.up")
                    }
                    
                    Button(action: {
                        startCookingSession()
                    }) {
                        Label("Start Cooking", systemImage: "flame")
                    }
                    
                    Divider()
                    
                    Button(action: {
                        showingEditSheet = true
                    }) {
                        Label("Edit Recipe", systemImage: "pencil")
                    }
                    
                    Button(role: .destructive, action: {
                        showingDeleteAlert = true
                    }) {
                        Label("Delete Recipe", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    let success = await recipeManager.deleteRecipe(recipe)
                    if success {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(recipe.title)'? This action cannot be undone.")
        }
        .sheet(isPresented: $showingEditSheet) {
            EditRecipeView(
                recipe: RecipeData(
                    title: recipe.title,
                    description: recipe.description,
                    servings: recipe.servings,
                    prepTime: recipe.prepTime,
                    cookTime: recipe.cookTime,
                    ingredients: recipe.ingredients,
                    instructions: recipe.instructions,
                    tags: recipe.tags,
                    sourceUrl: recipe.sourceUrl,
                    cuisineType: recipe.cuisineType,
                    difficulty: recipe.difficulty
                ),
                onSave: { updatedRecipe in
                    Task {
                        await updateRecipe(updatedRecipe)
                    }
                }
            )
        }
    }
    
    private func startCookingSession() {
        // Start the cooking session with this recipe
        cookingSessionManager.startCookingSession(with: recipe)
        
        // Dismiss the current view
        dismiss()
        
        // Switch to the Cook tab (tab index 1)
        selectedTab.wrappedValue = 1
    }
    
    private func updateRecipe(_ updatedRecipe: RecipeCreate) async {
        // Convert RecipeCreate to RecipeBase
        let recipeBase = RecipeBase(
            title: updatedRecipe.title,
            description: updatedRecipe.description,
            servings: updatedRecipe.servings,
            prepTime: updatedRecipe.prepTime,
            cookTime: updatedRecipe.cookTime,
            ingredients: updatedRecipe.ingredients,
            instructions: updatedRecipe.instructions,
            tags: updatedRecipe.tags,
            sourceUrl: updatedRecipe.sourceUrl,
            cuisineType: updatedRecipe.cuisineType,
            difficulty: updatedRecipe.difficulty
        )

        let success = await recipeManager.updateRecipe(id: recipe.id, with: recipeBase)
        if !success {
            // Handle error - could show an alert
            print("Failed to update recipe: \(recipeManager.errorMessage ?? "Unknown error")")
        }
    }
}

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

#Preview {
    NavigationStack {
        RecipeDetailView(recipe: Recipe(
            id: UUID(),
            title: "Chocolate Chip Cookies",
            description: "Classic homemade chocolate chip cookies that are crispy on the outside and chewy on the inside.",
            servings: 24,
            prepTime: 15,
            cookTime: 12,
            ingredients: [
                "2 cups all-purpose flour",
                "1 cup butter, softened",
                "3/4 cup brown sugar",
                "1/2 cup white sugar",
                "2 large eggs",
                "2 tsp vanilla extract",
                "1 cup chocolate chips"
            ],
            instructions: [
                "Preheat oven to 375°F (190°C).",
                "In a medium bowl, whisk together flour, baking soda, and salt.",
                "In a large bowl, cream together butter and both sugars until light and fluffy.",
                "Beat in eggs one at a time, then vanilla.",
                "Gradually mix in flour mixture until just combined.",
                "Stir in chocolate chips.",
                "Drop rounded tablespoons of dough onto ungreased baking sheets.",
                "Bake for 9-11 minutes until golden brown.",
                "Cool on baking sheet for 5 minutes before transferring to wire rack."
            ],
            tags: ["dessert", "cookies", "chocolate"],
            sourceUrl: "https://example.com/cookies",
            cuisineType: "American",
            difficulty: "easy",
            createdAt: Date(),
            updatedAt: Date()
        ))
    }
    .environmentObject(RecipeManager())
}
