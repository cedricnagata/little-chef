//
//  RecipeEditingTests.swift
//  little-chefTests
//
//  Finding the line the assistant meant, and reporting what a cook changed.
//

import Testing
@testable import little_chef

// MARK: - Line matching

private let steps = ["Boil the water", "Salt it generously", "Cook the pasta for 10 minutes"]
private let ingredients = ["2 cloves of garlic, minced", "400g spaghetti", "1 tbsp olive oil"]

@Test func findsStepsByNumber() {
    #expect(RecipeLineMatcher.index(matching: "2", in: steps, allowingNumbers: true) == 1)
    #expect(RecipeLineMatcher.index(matching: "step 3", in: steps, allowingNumbers: true) == 2)
    #expect(RecipeLineMatcher.index(matching: "#1", in: steps, allowingNumbers: true) == 0)
    #expect(RecipeLineMatcher.index(matching: "9", in: steps, allowingNumbers: true) == nil)
}

/// Ingredients aren't numbered on screen, so "2" is more likely a truncated amount.
@Test func doesNotTreatANumberAsAnIngredientPosition() {
    #expect(RecipeLineMatcher.index(matching: "1", in: ingredients, allowingNumbers: false) == 2)
}

@Test func findsLinesByQuote() {
    #expect(RecipeLineMatcher.index(matching: "400G SPAGHETTI", in: ingredients, allowingNumbers: false) == 1)
    #expect(RecipeLineMatcher.index(matching: "olive oil", in: ingredients, allowingNumbers: false) == 2)
    #expect(RecipeLineMatcher.index(matching: "the garlic", in: ingredients, allowingNumbers: false) == 0)
    #expect(RecipeLineMatcher.index(matching: "butter", in: ingredients, allowingNumbers: false) == nil)
    #expect(RecipeLineMatcher.index(matching: "of the", in: ingredients, allowingNumbers: false) == nil)
}

@Test func clampsInsertionPositions() {
    #expect(RecipeLineMatcher.insertionIndex(nil, count: 3) == 3)
    #expect(RecipeLineMatcher.insertionIndex(0, count: 3) == 3)
    #expect(RecipeLineMatcher.insertionIndex(1, count: 3) == 0)
    #expect(RecipeLineMatcher.insertionIndex(10, count: 3) == 3)
}

// MARK: - Diff

private func recipe(ingredients: [String] = ["flour", "eggs"], steps: [String] = ["Mix", "Bake"],
                    servings: Int = 4, title: String = "Bread") -> RecipeBase {
    RecipeBase(title: title, description: nil, servings: servings, prepTime: nil, cookTime: nil,
               ingredients: ingredients, instructions: steps, tags: [], sourceUrl: nil,
               cuisineType: nil, difficulty: nil)
}

@Test func reportsNothingForTheSameRecipe() {
    #expect(RecipeDiff(from: recipe(), to: recipe()).isEmpty)
}

/// A step inserted in the middle is one addition, not every step below it rewritten.
@Test func reportsAMiddleInsertionAsOneAddition() {
    let changes = RecipeDiff(from: recipe(steps: ["Mix", "Bake", "Cool"]),
                             to: recipe(steps: ["Mix", "Rest", "Bake", "Cool"])).changes
    #expect(changes.count == 1)
    #expect(changes.first?.kind == .added)
    #expect(changes.first?.after == "Rest")
}

@Test func reportsEditsRemovalsAndDetails() {
    let changes = RecipeDiff(
        from: recipe(ingredients: ["flour", "eggs", "milk"]),
        to: recipe(ingredients: ["bread flour", "eggs"], servings: 6, title: "Loaf")
    ).changes
    let fields = changes.map(\.field)
    #expect(fields.contains("Title"))
    #expect(fields.contains("Servings"))
    #expect(changes.contains { $0.field == "Ingredient" && $0.kind == .removed && $0.before == "milk" })
    #expect(changes.contains { $0.field == "Ingredient" && $0.after == "bread flour" })
}
