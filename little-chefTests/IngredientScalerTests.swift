//
//  IngredientScalerTests.swift
//  little-chefTests
//
//  Rescaling ingredient amounts when the servings change.
//

import Testing
@testable import little_chef

@Test(arguments: [
    ("2 cups flour", 2.0, "4 cups flour"),
    ("1 cup milk", 0.5, "1/2 cup milk"),
    ("2 1/2 cups flour", 2.0, "5 cups flour"),
    ("1/2 tsp salt", 2.0, "1 tsp salt"),
    ("1.5 kg potatoes", 2.0, "3 kg potatoes"),
    ("½ cup sugar", 2.0, "1 cup sugar"),
    ("1½ cups stock", 2.0, "3 cups stock"),
    ("1 ½ cups stock", 2.0, "3 cups stock"),
    ("200g spaghetti", 1.5, "300g spaghetti"),
    ("3 eggs", 1.0 / 3.0, "1 eggs"),
    ("1 cup rice", 1.25, "1 1/4 cups rice"),
])
func scalesTheLeadingAmount(line: String, factor: Double, expected: String) {
    #expect(IngredientScaler.scale(line, by: factor) == expected)
}

/// The 1 is how many cans; the 14 is how big each one is.
@Test func scalesTheCountNotThePackageSize() {
    #expect(IngredientScaler.scale("1 (14 oz) can diced tomatoes", by: 2) == "2 (14 oz) can diced tomatoes")
}

/// Used to be scaled from the "1/2" alone, leaving the whole number behind.
@Test func readsMixedNumbersWhole() {
    #expect(IngredientScaler.scale("2 1/2 cups flour", by: 0.5) == "1 1/4 cups flour")
}

/// Used to replace every occurrence of the amount's digits, so "12" became "14".
@Test func leavesOtherNumbersInTheLineAlone() {
    #expect(IngredientScaler.scale("2 eggs, about 12 oz", by: 2) == "4 eggs, about 12 oz")
}

@Test func scalesBothEndsOfARange() {
    #expect(IngredientScaler.scale("2-3 cloves garlic", by: 2) == "4-6 cloves garlic")
    #expect(IngredientScaler.scale("1 to 2 tbsp oil", by: 2) == "2 to 4 tbsp oil")
}

@Test func readsNumberWords() {
    #expect(IngredientScaler.scale("two cloves of garlic, minced", by: 2) == "4 cloves of garlic, minced")
}

/// No "(scale by 2x)" note any more: it piled up every time the servings changed again.
@Test(arguments: ["Salt to taste", "Juice of a lemon", "A pinch of nutmeg", ""])
func leavesLinesWithNoLeadingAmountUnchanged(line: String) {
    #expect(IngredientScaler.scale(line, by: 2) == line)
}

/// "1-inch piece" is the size of the piece, not a count to double.
@Test func leavesSizeDescriptorsAlone() {
    #expect(IngredientScaler.scale("1-inch piece of ginger", by: 2) == "1-inch piece of ginger")
}

@Test func keepsUnitsInTheRightNumber() {
    #expect(IngredientScaler.scale("1 cup milk", by: 2) == "2 cups milk")
    #expect(IngredientScaler.scale("2 cups milk", by: 0.5) == "1 cup milk")
    #expect(IngredientScaler.scale("1 Clove garlic", by: 3) == "3 Cloves garlic")
}

@Test(arguments: [
    (2.0, "2"), (0.5, "1/2"), (1.5, "1 1/2"), (0.333, "1/3"), (2.666, "2 2/3"),
    (0.125, "1/8"), (83.25, "83"), (0.05, "0.05"), (1.99, "2"),
])
func formatsAmountsTheWayRecipesWriteThem(value: Double, expected: String) {
    #expect(IngredientScaler.format(value) == expected)
}

@Test func scalesARecipeToNewServings() {
    let recipe = RecipeBase(
        title: "Pancakes", description: nil, servings: 2, prepTime: nil, cookTime: nil,
        ingredients: ["1 cup flour", "1 egg", "Salt"], instructions: ["Mix"], tags: [],
        sourceUrl: nil, cuisineType: nil, difficulty: nil
    )
    let scaled = IngredientScaler.scaled(recipe, toServings: 4)
    #expect(scaled.servings == 4)
    #expect(scaled.ingredients == ["2 cups flour", "2 egg", "Salt"])
    #expect(scaled.instructions == recipe.instructions)
    #expect(IngredientScaler.scaled(recipe, toServings: 2) == recipe)
    #expect(IngredientScaler.scaled(recipe, toServings: 0) == recipe)
}

/// A cooking session scales its working copy and its baseline separately. The same input must
/// give the same output, or a serving change would show up as unsaved recipe edits.
@Test func scalingTheBaselineAndTheWorkingCopyCancelsOut() {
    let recipe = RecipeBase(
        title: "Soup", description: nil, servings: 4, prepTime: nil, cookTime: nil,
        ingredients: ["1 1/2 cups lentils", "2-3 carrots", "1 onion", "Salt to taste"],
        instructions: ["Simmer"], tags: [], sourceUrl: nil, cuisineType: nil, difficulty: nil
    )
    var working = recipe
    var baseline = recipe
    for servings in [6, 3, 5, 4] {
        working = IngredientScaler.scaled(working, toServings: servings)
        baseline = IngredientScaler.scaled(baseline, toServings: servings)
    }
    #expect(working == baseline)
    #expect(RecipeDiff(from: baseline, to: working).isEmpty)
}
