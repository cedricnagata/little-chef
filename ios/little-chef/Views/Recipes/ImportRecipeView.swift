//
//  ImportRecipeView.swift
//  little-chef
//
//  Recipe import preview view
//

import SwiftUI

struct ImportRecipeView: View {
    let recipeBase: RecipeBase
    let onImport: () async -> Bool
    let onCancel: () -> Void

    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showSuccess = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    // Header
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Import Recipe")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Review the recipe before importing")
                            .font(.subheadline)
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }
                    .padding(.horizontal)

                    Divider()

                    // Recipe Preview
                    RecipePreviewContent(recipe: recipeBase)
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .disabled(isImporting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task {
                            await importRecipe()
                        }
                    }
                    .disabled(isImporting)
                }
            }
            .alert("Import Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") {
                    errorMessage = nil
                    onCancel()
                }
            } message: {
                Text(errorMessage ?? "Failed to import recipe")
            }
            .alert("Recipe Imported", isPresented: $showSuccess) {
                Button("OK") {
                    onCancel()
                }
            } message: {
                Text("\(recipeBase.title) has been added to your recipes.")
            }
        }
    }

    private func importRecipe() async {
        isImporting = true
        let success = await onImport()
        isImporting = false

        if success {
            showSuccess = true
        } else {
            errorMessage = "Failed to import recipe"
        }
    }
}

// MARK: - Recipe Preview Content
struct RecipePreviewContent: View {
    let recipe: RecipeBase

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Title and description
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(recipe.title)
                    .font(.title2)
                    .fontWeight(.bold)

                if let description = recipe.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }
            .padding(.horizontal)

            // Recipe info grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: DesignSystem.Spacing.md) {
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
            .padding(.horizontal)

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
            }

            Divider()

            // Ingredients
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    Text("Ingredients")
                        .sectionHeader()
                        .font(.title3)

                    Spacer()

                    Text("\(recipe.ingredients.count) items")
                        .captionText()
                }

                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { index, ingredient in
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                            Circle()
                                .fill(DesignSystem.Colors.primaryMedium)
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)

                            Text(ingredient)
                                .bodyText()

                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal)

            Divider()

            // Instructions
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    Text("Instructions")
                        .sectionHeader()
                        .font(.title3)

                    Spacer()

                    Text("\(recipe.instructions.count) steps")
                        .captionText()
                }

                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ForEach(Array(recipe.instructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                            ZStack {
                                Circle()
                                    .fill(DesignSystem.Colors.primary)
                                    .frame(width: 24, height: 24)

                                Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }

                            Text(instruction)
                                .bodyText()
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
                        .font(.title3)
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
        }
    }
}
