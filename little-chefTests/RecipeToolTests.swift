//
//  RecipeToolTests.swift
//  little-chefTests
//
//  The recipe tools' argument reading and reporting, exercised through `CookingTools.execute`.
//

import Testing
@testable import little_chef

// MARK: - Doubles

/// A recipe the tools can edit, standing in for the cooking session.
@MainActor
private final class FakeRecipe: RecipeEditing {
    var ingredients: [String] = []
    var steps: [String] = []
    var isBuildingNewRecipe = true

    var currentIngredients: [String] { ingredients }
    var currentSteps: [String] { steps }

    func addIngredient(_ text: String, at position: Int?) -> LineAdditionOutcome {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .rejected }
        guard !ingredients.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) else {
            return .alreadyPresent
        }
        ingredients.insert(line, at: Self.index(position, count: ingredients.count))
        return .added
    }

    func replaceIngredient(matching query: String, with text: String) -> String? {
        guard let index = ingredients.firstIndex(where: { $0.localizedCaseInsensitiveContains(query) }) else {
            return nil
        }
        let previous = ingredients[index]
        ingredients[index] = text
        return previous
    }

    func removeIngredient(matching query: String) -> String? {
        guard let index = ingredients.firstIndex(where: { $0.localizedCaseInsensitiveContains(query) }) else {
            return nil
        }
        return ingredients.remove(at: index)
    }

    func addStep(_ text: String, at position: Int?) -> LineAdditionOutcome {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .rejected }
        guard !steps.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) else {
            return .alreadyPresent
        }
        steps.insert(line, at: Self.index(position, count: steps.count))
        return .added
    }

    func replaceStep(matching query: String, with text: String) -> String? {
        guard let index = Self.stepIndex(query, in: steps) else { return nil }
        let previous = steps[index]
        steps[index] = text
        return previous
    }

    func removeStep(matching query: String) -> String? {
        guard let index = Self.stepIndex(query, in: steps) else { return nil }
        return steps.remove(at: index)
    }

    func setRecipeDetails(
        title: String?, description: String?, servings: Int?, prepTime: Int?, cookTime: Int?,
        difficulty: String?, cuisineType: String?, tags: [String]?
    ) -> [String] {
        title.map { ["The recipe is now called '\($0)'."] } ?? []
    }

    private static func index(_ position: Int?, count: Int) -> Int {
        guard let position, position >= 1 else { return count }
        return min(position - 1, count)
    }

    /// Numbers first, then a substring — the same two ways the real editor resolves a step.
    private static func stepIndex(_ query: String, in steps: [String]) -> Int? {
        let needle = query.lowercased()
            .replacingOccurrences(of: "step", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(needle), number >= 1, number <= steps.count { return number - 1 }
        return steps.firstIndex { $0.localizedCaseInsensitiveContains(query) }
    }
}

@MainActor
private final class NoTimers: TimerManager {
    func createTimer(name: String, durationSeconds: Int) -> Bool { false }
    func startTimer(name: String) -> Bool { false }
    func stopTimer(name: String) -> Bool { false }
    func updateTimer(name: String, newName: String?, durationSeconds: Int?) -> Bool { false }
    func deleteTimer(name: String) -> Bool { false }
    func getTimer(name: String) -> LocalTimer? { nil }
    func getAllTimers() -> [LocalTimer] { [] }
}

@MainActor
private func harness() -> (CookingTools, FakeRecipe) {
    let recipe = FakeRecipe()
    return (CookingTools(timerManager: NoTimers(), recipeEditor: recipe), recipe)
}

// MARK: - Tests

@MainActor
struct RecipeToolTests {

    // MARK: Batching

    @Test func addIngredientsRecordsEveryLineInOneCall() {
        let (tools, recipe) = harness()
        let outcome = tools.execute(
            toolName: "add_ingredients",
            arguments: ["items": "two eggs\n300 grams plain flour\na splash of milk"]
        )

        #expect(recipe.ingredients == ["two eggs", "300 grams plain flour", "a splash of milk"])
        #expect(outcome.forUser.contains("two eggs"))
    }

    @Test func addIngredientsAcceptsSemicolonsAndJSONArrays() {
        let (semicolons, viaSemicolons) = harness()
        _ = semicolons.execute(toolName: "add_ingredients", arguments: ["items": "two eggs; 300 grams flour"])
        #expect(viaSemicolons.ingredients == ["two eggs", "300 grams flour"])

        let (arrays, viaArray) = harness()
        _ = arrays.execute(toolName: "add_ingredients", arguments: ["items": ["two eggs", "300 grams flour"]])
        #expect(viaArray.ingredients == ["two eggs", "300 grams flour"])
    }

    /// A comma inside one line is part of the ingredient, not a separator.
    @Test func addIngredientsDoesNotSplitOnCommas() {
        let (tools, recipe) = harness()
        _ = tools.execute(toolName: "add_ingredients", arguments: ["items": "two cloves of garlic, minced"])
        #expect(recipe.ingredients == ["two cloves of garlic, minced"])
    }

    @Test func addIngredientsStripsListMarkupButKeepsDecimals() {
        let (tools, recipe) = harness()
        _ = tools.execute(
            toolName: "add_ingredients",
            arguments: ["items": "1. two eggs\n- 300 grams flour\n1.5 litres of stock"]
        )
        #expect(recipe.ingredients == ["two eggs", "300 grams flour", "1.5 litres of stock"])
    }

    @Test func addStepsKeepsItsOwnOrderWhenGivenAPosition() {
        let (tools, recipe) = harness()
        _ = tools.execute(toolName: "add_steps", arguments: ["steps": "Boil the water\nSalt it\nServe"])
        _ = tools.execute(toolName: "add_steps", arguments: ["steps": "Chop the garlic\nFry it", "position": 2])

        #expect(recipe.steps == ["Boil the water", "Chop the garlic", "Fry it", "Salt it", "Serve"])
    }

    // MARK: Idempotence

    /// The whole point of the retry path: a batch that comes round twice must read as done, not
    /// as an error the model should try to fix.
    @Test func repeatingABatchIsNotAFailure() {
        let (tools, recipe) = harness()
        _ = tools.execute(toolName: "add_ingredients", arguments: ["items": "two eggs\n300 grams flour"])
        let again = tools.execute(toolName: "add_ingredients", arguments: ["items": "two eggs\n300 grams flour"])

        #expect(recipe.ingredients == ["two eggs", "300 grams flour"])
        #expect(again.forModel.contains("already listed"))
        #expect(!again.forModel.lowercased().contains("error"))
        #expect(!again.forModel.contains("update_ingredient"))
    }

    @Test func removingSomethingAbsentIsNotAFailure() {
        let (tools, _) = harness()
        let outcome = tools.execute(toolName: "remove_ingredients", arguments: ["items": "butter"])
        #expect(outcome.forModel.contains("nothing to remove"))
        #expect(!outcome.forModel.lowercased().contains("error"))
    }

    // MARK: Updates

    @Test func updateIngredientsReadsArrowSeparatedChanges() {
        let (tools, recipe) = harness()
        _ = tools.execute(toolName: "add_ingredients", arguments: ["items": "flour\nbutter"])
        let outcome = tools.execute(
            toolName: "update_ingredients",
            arguments: ["changes": "flour -> 300 grams bread flour\nbutter -> 50 grams salted butter"]
        )

        #expect(recipe.ingredients == ["300 grams bread flour", "50 grams salted butter"])
        #expect(outcome.forUser.contains("300 grams bread flour"))
    }

    /// The old two-argument shape, which models still reach for.
    @Test func updateIngredientsStillAcceptsTheSinglePairForm() {
        let (tools, recipe) = harness()
        _ = tools.execute(toolName: "add_ingredient", arguments: ["item": "flour"])
        _ = tools.execute(
            toolName: "update_ingredient",
            arguments: ["item": "flour", "new_item": "300 grams bread flour"]
        )
        #expect(recipe.ingredients == ["300 grams bread flour"])
    }

    @Test func aChangeWithNoArrowIsReportedRatherThanSwallowed() {
        let (tools, _) = harness()
        let outcome = tools.execute(toolName: "update_ingredients", arguments: ["changes": "more flour"])
        #expect(outcome.forModel.contains("'more flour'"))
        #expect(outcome.forModel.contains("->"))
    }

    /// Removing step 2 renumbers step 3, so a numbered batch has to run highest-first.
    @Test func removeStepsHandlesNumbersInAnyOrder() {
        let (tools, recipe) = harness()
        _ = tools.execute(toolName: "add_steps", arguments: ["steps": "One\nTwo\nThree\nFour"])
        _ = tools.execute(toolName: "remove_steps", arguments: ["steps": "2\n4"])

        #expect(recipe.steps == ["One", "Three"])
    }

    // MARK: Two audiences

    /// The resulting list is what stops a tool loop re-recording what it already recorded — and it
    /// must never reach the user, who would have it read out loud.
    @Test func onlyTheModelSeesTheResultingListAndTheNotSavedReminder() {
        let (tools, _) = harness()
        let outcome = tools.execute(toolName: "add_ingredients", arguments: ["items": "two eggs"])

        #expect(outcome.forModel.contains("Ingredients now: two eggs."))
        #expect(outcome.forModel.contains("Nothing is saved"))
        #expect(!outcome.forUser.contains("Ingredients now"))
        #expect(!outcome.forUser.contains("Nothing is saved"))
    }

    @Test func stepsAreEchoedBackNumbered() {
        let (tools, _) = harness()
        let outcome = tools.execute(toolName: "add_steps", arguments: ["steps": "Boil the water\nSalt it"])
        #expect(outcome.forModel.contains("Steps now: 1. Boil the water; 2. Salt it."))
    }

    @Test func anEmptyRecipeEchoesAsNone() {
        let (tools, _) = harness()
        let outcome = tools.execute(toolName: "remove_ingredients", arguments: ["items": "butter"])
        #expect(outcome.forModel.contains("Ingredients now: none."))
    }

    // MARK: Tool list

    /// `mlxToolSpec` and `LLMService.bigBroTools(from:)` both project this list, so a tool missing
    /// here is a capability missing from both backends.
    @Test func everyRecipeToolIsOfferedWhenThereIsARecipe() {
        let (tools, _) = harness()
        let names = Set(tools.toolSpecs.map(\.name))

        #expect(names.isSuperset(of: [
            "add_ingredients", "update_ingredients", "remove_ingredients",
            "add_steps", "update_steps", "remove_steps", "set_recipe_details",
        ]))
    }

    @Test func noRecipeMeansNoRecipeTools() {
        let tools = CookingTools(timerManager: NoTimers(), recipeEditor: nil)
        #expect(!tools.toolSpecs.contains { $0.name.contains("ingredient") })

        let outcome = tools.execute(toolName: "add_ingredients", arguments: ["items": "two eggs"])
        #expect(outcome.forUser.contains("no recipe open"))
    }
}
