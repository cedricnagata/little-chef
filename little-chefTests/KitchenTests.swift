//
//  KitchenTests.swift
//  little-chefTests
//
//  Ingredient matching for the inventory, and reading the model's ranking for Suggested.
//

import Foundation
import Testing
@testable import little_chef

// MARK: - Parsing

@Test(arguments: [
    ("2 cloves garlic, minced", [["garlic"]]),
    ("1 (14 oz) can diced tomatoes", [["tomatoes"]]),
    ("2 1/2 cups all-purpose flour", [["all purpose flour"]]),
    ("Salt and pepper to taste", [["salt"], ["pepper"]]),
    ("2 tbsp butter or olive oil", [["butter", "olive oil"]]),
    ("3 large eggs", [["eggs"]]),
    ("1 lb boneless skinless chicken breasts", [["chicken breasts"]]),
    ("½ tsp ground cinnamon", [["ground cinnamon"]]),
    ("200g spaghetti", [["spaghetti"]]),
])
func parsesIngredientNames(line: String, names: [[String]]) {
    #expect(IngredientMatcher.parse(line)?.names == names)
}

@Test(arguments: ["For the sauce:", "1 cup warm water", "Ice", "   "])
func skipsLinesThatAreNotIngredientsToCheck(line: String) {
    #expect(IngredientMatcher.parse(line) == nil)
}

@Test func garnishIsOptional() {
    #expect(IngredientMatcher.parse("Fresh parsley, for garnish")?.isOptional == true)
    #expect(IngredientMatcher.parse("Fresh parsley")?.isOptional == false)
}

@Test func singularizesTheWaysRecipesPluralize() {
    #expect(IngredientMatcher.singular("tomatoes") == "tomato")
    #expect(IngredientMatcher.singular("berries") == "berry")
    #expect(IngredientMatcher.singular("eggs") == "egg")
    #expect(IngredientMatcher.singular("peaches") == "peach")
    // Words that only look plural.
    #expect(IngredientMatcher.singular("asparagus") == "asparagus")
    #expect(IngredientMatcher.singular("hummus") == "hummus")
    #expect(IngredientMatcher.singular("swiss") == "swiss")
}

// MARK: - Matching

@Test func coversByWordSubsetEitherWay() {
    let tokens = IngredientMatcher.normalizedTokens(of:)
    #expect(IngredientMatcher.covers(tokens("Garlic"), tokens("garlic cloves")))
    #expect(IngredientMatcher.covers(tokens("chicken breast"), tokens("chicken")))
    #expect(IngredientMatcher.covers(tokens("Tomatoes"), tokens("tomato")))
    #expect(!IngredientMatcher.covers(tokens("black pepper"), tokens("bell pepper")))
    #expect(!IngredientMatcher.covers(tokens("All-purpose flour"), tokens("almond flour")))
}

@Test func availabilityListsWhatIsMissing() {
    let recipe = [
        "2 cloves garlic, minced",
        "1 (14 oz) can diced tomatoes",
        "Salt and pepper to taste",
        "2 tbsp butter or olive oil",
        "1 cup warm water",
        "Fresh parsley, for garnish",
        "1 red bell pepper, sliced",
        "200g spaghetti",
    ]
    let inventory = ["Garlic", "Salt", "Black pepper", "Olive oil", "Tomatoes"]

    let result = IngredientMatcher.availability(of: recipe, inventory: inventory)

    #expect(result.missing == ["1 red bell pepper, sliced", "200g spaghetti"])
    #expect(result.missingNames == ["Red bell pepper", "Spaghetti"])
    // Water and the garnish don't count; the other six do.
    #expect(result.requiredCount == 6)
    #expect(!result.canMake)
}

@Test func onlyTheMissingHalfOfACompoundLineGoesOnTheList() {
    let result = IngredientMatcher.availability(of: ["Salt and pepper to taste"], inventory: ["Salt"])
    #expect(result.missingNames == ["Pepper"])
}

@Test func anEmptyInventoryIsMissingEverythingRequired() {
    let result = IngredientMatcher.availability(of: ["2 eggs", "1 cup milk", "Water"], inventory: [])
    #expect(result.missing == ["2 eggs", "1 cup milk"])
}

@Test func sameItemIgnoresCaseAndPlurals() {
    #expect(IngredientMatcher.sameItem("Eggs", "egg"))
    #expect(IngredientMatcher.sameItem("Olive Oil", "olive oil"))
    #expect(!IngredientMatcher.sameItem("Olive oil", "Vegetable oil"))
    // Nothing to compare: never a duplicate of anything.
    #expect(!IngredientMatcher.sameItem("123", "123"))
}

// MARK: - Suggestions

@Test func readsTheOrderObject() {
    #expect(RecipeSuggester.parseOrder(#"{"order": [3, 1, 2]}"#, count: 3) == [2, 0, 1])
}

@Test func readsABareListAndDropsBadNumbers() {
    // Out of range, zero, and repeats are dropped; the rest keep their order.
    #expect(RecipeSuggester.parseOrder("2, 9, 2, 0, 1", count: 3) == [1, 0])
}

@Test func readsTheOrderObjectAmidProse() {
    let response = #"Sure! Here is the ranking: {"order": [2, 1]} Enjoy."#
    #expect(RecipeSuggester.parseOrder(response, count: 2) == [1, 0])
}

@Test(arguments: [(7, MealPeriod.breakfast), (12, .lunch), (19, .dinner), (23, .lateNight), (3, .lateNight)])
func mealPeriodFollowsTheClock(hour: Int, expected: MealPeriod) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: hour))!
    #expect(MealPeriod(date: date, calendar: calendar) == expected)
}
