//
//  RecipeExtractionTests.swift
//  little-chefTests
//
//  Reading recipes out of schema.org JSON-LD and model output.
//

import Foundation
import Testing
@testable import little_chef

// MARK: - Fields

/// "4-6 servings" used to have every digit joined and come out as 46.
@Test(arguments: [
    ("4-6 servings", 4), ("Makes 12 cookies", 12), ("Serves 4 to 6", 4), ("1 loaf", 1), ("8", 8),
])
func readsServingsFromAYield(yield: String, servings: Int) {
    #expect(RecipeExtraction.servings(from: yield) == servings)
}

@Test func readsServingsInOtherShapes() {
    #expect(RecipeExtraction.servings(from: 6) == 6)
    #expect(RecipeExtraction.servings(from: ["6", "6 portions"]) == 6)
    #expect(RecipeExtraction.servings(from: "a few") == nil)
    #expect(RecipeExtraction.servings(from: nil) == nil)
}

@Test(arguments: [
    ("PT30M", 30), ("PT1H30M", 90), ("PT2H", 120), ("P1DT2H", 1560), ("PT90S", 2),
    ("1 hour 30 minutes", 90), ("45 min", 45), ("1.5 hours", 90), ("20", 20),
])
func readsDurations(text: String, minutes: Int) {
    #expect(RecipeExtraction.minutes(from: text) == minutes)
}

@Test func ignoresDurationsThatAreNothing() {
    #expect(RecipeExtraction.minutes(from: "PT0M") == nil)
    #expect(RecipeExtraction.minutes(from: "soon") == nil)
    #expect(RecipeExtraction.minutes(from: 15) == 15)
}

@Test func stripsStepNumbers() {
    #expect(RecipeExtraction.strippingStepNumber("1. Preheat the oven") == "Preheat the oven")
    #expect(RecipeExtraction.strippingStepNumber("Step 2: Mix") == "Mix")
    #expect(RecipeExtraction.strippingStepNumber("3) Bake") == "Bake")
    #expect(RecipeExtraction.strippingStepNumber("350 degrees for 20 minutes") == "350 degrees for 20 minutes")
}

// MARK: - schema.org

@Test func readsASchemaOrgRecipe() throws {
    let json = #"""
    {
      "@type": "Recipe",
      "name": "Sriracha &#x27;n Honey Wings",
      "description": "Sticky &amp; hot.",
      "recipeYield": ["4", "4 servings"],
      "prepTime": "PT15M",
      "cookTime": "PT1H",
      "recipeIngredient": ["1 kg chicken wings", "3 tbsp sriracha"],
      "recipeInstructions": [
        {"@type": ["HowToSection"], "name": "Wings", "itemListElement": [
          {"@type": "HowToStep", "text": "1. Heat the oven."},
          {"@type": "HowToStep", "text": "Bake the wings."}
        ]},
        "Toss in the sauce."
      ],
      "recipeCategory": "Appetizer",
      "recipeCuisine": ["American"]
    }
    """#
    let recipe = try RecipeExtraction.fromSchemaOrg(json: json, sourceUrl: "https://example.com")

    #expect(recipe.title == "Sriracha 'n Honey Wings")
    #expect(recipe.description == "Sticky & hot.")
    #expect(recipe.servings == 4)
    #expect(recipe.prepTime == 15)
    #expect(recipe.cookTime == 60)
    #expect(recipe.ingredients == ["1 kg chicken wings", "3 tbsp sriracha"])
    #expect(recipe.instructions == ["Heat the oven.", "Bake the wings.", "Toss in the sauce."])
    #expect(recipe.tags == ["appetizer"])
    #expect(recipe.cuisineType == "American")
    #expect(recipe.sourceUrl == "https://example.com")
}

/// Pages that put the whole method, or all the ingredients, in one string.
@Test func splitsSingleStringListsIntoLines() throws {
    let json = #"{"name": "Toast", "recipeIngredient": "2 slices bread\n1 tbsp butter", "recipeInstructions": "Toast the bread.\nButter it."}"#
    let recipe = try RecipeExtraction.fromSchemaOrg(json: json, sourceUrl: nil)
    #expect(recipe.ingredients == ["2 slices bread", "1 tbsp butter"])
    #expect(recipe.instructions == ["Toast the bread.", "Butter it."])
    #expect(recipe.servings == 4)
}

// MARK: - Model output

/// A strict decoder rejected the whole recipe over any one of these.
@Test func readsSloppyModelJSON() throws {
    let response = #"""
    Here is your recipe:
    {"title": "Pancakes", "servings": "4", "prep_time": "10 minutes", "cook_time": 15,
     "ingredients": ["1 cup flour", "1 egg",], "instructions": ["1. Mix.", "Step 2: Fry."],
     "cuisine": "American", "difficulty": "Easy",}
    """#
    let recipe = try RecipeExtraction.fromModelJSON(response)

    #expect(recipe.title == "Pancakes")
    #expect(recipe.servings == 4)
    #expect(recipe.prepTime == 10)
    #expect(recipe.cookTime == 15)
    #expect(recipe.ingredients == ["1 cup flour", "1 egg"])
    #expect(recipe.instructions == ["Mix.", "Fry."])
    #expect(recipe.tags == [])
    #expect(recipe.cuisineType == "American")
    #expect(recipe.difficulty == "easy")
}

@Test func refusesAnswersWithNoRecipeInThem() {
    #expect(throws: RecipeParserError.self) { try RecipeExtraction.fromModelJSON("Sorry, I can't help.") }
    #expect(throws: RecipeParserError.self) { try RecipeExtraction.fromModelJSON(#"{"description": "nothing"}"#) }
}

@Test func creditsTheSource() throws {
    let recipe = try RecipeExtraction.fromModelJSON(#"{"title": "Soup", "ingredients": ["water"]}"#)
    #expect(recipe.withSourceUrl("https://soup.example").sourceUrl == "https://soup.example")
    #expect(recipe.withSourceUrl(nil).sourceUrl == nil)
}

@Test func ratesHowCompleteARecipeIs() throws {
    let complete = try RecipeExtraction.fromModelJSON(
        #"{"title": "Soup", "ingredients": ["water"], "instructions": ["Boil"], "prep_time": 5, "cook_time": 10}"#
    )
    #expect(RecipeExtraction.evaluate(complete).confidence == 1)
    #expect(RecipeExtraction.evaluate(complete).warnings.isEmpty)

    let bare = try RecipeExtraction.fromModelJSON(#"{"title": "Soup"}"#)
    let (confidence, warnings) = RecipeExtraction.evaluate(bare)
    #expect(confidence < 0.5)
    #expect(warnings == ["Missing ingredients", "Missing instructions"])
}

// MARK: - HTML

@Test func cleansScrapedText() {
    #expect(HTMLText.clean("Sriracha &#x27;n honey") == "Sriracha 'n honey")
    #expect(HTMLText.clean("Salt &amp;#x27;n pepper") == "Salt 'n pepper")
    #expect(HTMLText.clean("<p>Mix</p><p>Bake</p>") == "Mix\nBake")
    #expect(HTMLText.clean("&nbsp; 1 cup&nbsp;flour ") == "1 cup flour")
    #expect(HTMLText.clean("Fish &chips; & more") == "Fish &chips; & more")
    #expect(HTMLText.clean(["<b></b>", "Keep"]) == ["Keep"])
}
