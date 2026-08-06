//
//  EditRecipeView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

/// Review-and-edit step of the import flow.
///
/// A thin shell around ``RecipeEditorForm``: a freshly parsed recipe and a saved one need the
/// same editing affordances, and keeping two copies of the form is how they came to differ.
struct EditRecipeView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (RecipeData) -> Void

    @State private var draft: RecipeDraft

    init(recipe: RecipeData, onSave: @escaping (RecipeData) -> Void) {
        self.onSave = onSave
        _draft = State(initialValue: RecipeDraft(from: recipe))
    }

    var body: some View {
        NavigationStack {
            RecipeEditorForm(draft: $draft)
                .navigationTitle("Edit Recipe")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            onSave(draft.toRecipeData())
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(!draft.isValid)
                    }
                }
        }
    }
}

#Preview {
    EditRecipeView(
        recipe: RecipeData(
            title: "Chocolate Chip Cookies",
            description: "Classic homemade cookies",
            servings: 24,
            prepTime: 15,
            cookTime: 12,
            ingredients: [
                "2 cups all-purpose flour",
                "1 cup butter, softened",
                "3/4 cup brown sugar"
            ],
            instructions: [
                "Preheat oven to 375°F",
                "Mix dry ingredients",
                "Cream butter and sugar"
            ],
            tags: ["dessert", "cookies"],
            sourceUrl: nil,
            cuisineType: "American",
            difficulty: "easy"
        )
    ) { _ in }
}
