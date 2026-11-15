//
//  BugSweepTests.swift
//  little-chefTests
//
//  One test per bug found in the 2026-11-15 sweep, each written to fail before its fix.
//

import Foundation
import Testing
@testable import little_chef

// MARK: - Doubles

@MainActor
private final class SweepTimers: TimerManager {
    var timers: [LocalTimer] = []

    func createTimer(name: String, durationSeconds: Int) -> Bool {
        guard getTimer(name: name) == nil else { return false }
        timers.append(LocalTimer(id: UUID().uuidString, label: name, durationSeconds: durationSeconds,
                                 remainingSeconds: durationSeconds, status: .new, createdAt: Date()))
        return true
    }
    func startTimer(name: String) -> Bool {
        guard let timer = getTimer(name: name), timer.status != .running else { return false }
        timer.status = .running
        return true
    }
    func stopTimer(name: String) -> Bool {
        guard let timer = getTimer(name: name), timer.status == .running else { return false }
        timer.status = .paused
        return true
    }
    func updateTimer(name: String, newName: String?, durationSeconds: Int?) -> Bool {
        guard let timer = getTimer(name: name) else { return false }
        if let newName { timer.label = newName }
        if let durationSeconds { timer.remainingSeconds = durationSeconds }
        return true
    }
    func deleteTimer(name: String) -> Bool {
        guard let index = timers.firstIndex(where: { $0.label.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        timers.remove(at: index)
        return true
    }
    func getTimer(name: String) -> LocalTimer? {
        timers.first { $0.label.caseInsensitiveCompare(name) == .orderedSame }
    }
    func getAllTimers() -> [LocalTimer] { timers }
}

/// A recipe edited through `RecipeLineMatcher`, as the cooking session edits its own.
@MainActor
private final class SweepRecipe: RecipeEditing {
    var ingredients: [String] = []
    var steps: [String] = []
    var isBuildingNewRecipe = false
    var currentIngredients: [String] { ingredients }
    var currentSteps: [String] { steps }

    func addIngredient(_ text: String, at position: Int?) -> LineAdditionOutcome {
        ingredients.insert(text, at: RecipeLineMatcher.insertionIndex(position, count: ingredients.count))
        return .added
    }
    func replaceIngredient(matching query: String, with text: String) -> String? {
        guard let index = RecipeLineMatcher.index(matching: query, in: ingredients, allowingNumbers: false) else { return nil }
        defer { ingredients[index] = text }
        return ingredients[index]
    }
    func removeIngredient(matching query: String) -> String? {
        RecipeLineMatcher.index(matching: query, in: ingredients, allowingNumbers: false).map { ingredients.remove(at: $0) }
    }
    func addStep(_ text: String, at position: Int?) -> LineAdditionOutcome {
        steps.insert(text, at: RecipeLineMatcher.insertionIndex(position, count: steps.count))
        return .added
    }
    func replaceStep(matching query: String, with text: String) -> String? {
        guard let index = RecipeLineMatcher.index(matching: query, in: steps, allowingNumbers: true) else { return nil }
        defer { steps[index] = text }
        return steps[index]
    }
    func removeStep(matching query: String) -> String? {
        RecipeLineMatcher.index(matching: query, in: steps, allowingNumbers: true).map { steps.remove(at: $0) }
    }
    func setRecipeDetails(
        title: String?, description: String?, servings: Int?, prepTime: Int?, cookTime: Int?,
        difficulty: String?, cuisineType: String?, tags: [String]?
    ) -> [String] {
        var applied: [String] = []
        if let title { applied.append("The recipe is now called '\(title)'.") }
        if let servings { applied.append("Servings set to \(servings).") }
        return applied
    }
}

// MARK: - Scaling

/// "12-inch" is the size of the thing, not an amount: the lookahead that protects "1-inch" let
/// the regex back up to "1" and scale that.
@Test(arguments: [
    ("12-inch flour tortillas", "12-inch flour tortillas"),
    ("10-ounce can of tomatoes", "10-ounce can of tomatoes"),
    ("2.5-pound chicken", "2.5-pound chicken"),
    ("1-inch piece of ginger", "1-inch piece of ginger"),
    ("12 eggs", "24 eggs"),
    ("1.5 cups milk", "3 cups milk"),
])
func scalingLeavesSizesAlone(line: String, doubled: String) {
    #expect(IngredientScaler.scale(line, by: 2) == doubled)
}

/// An amount too small for any kitchen fraction is not "0".
@Test func scalingNeverWritesZero() {
    #expect(IngredientScaler.scale("1/8 teaspoon cayenne", by: 0.25) != "0 teaspoon cayenne")
}

// MARK: - Recipe tools

@MainActor
struct SweepToolTests {
    /// The not-saved reminder is for the model. On the phone the user's copy is the reply.
    @Test func recipeDetailsDoNotTellTheUserNothingIsSaved() {
        let tools = CookingTools(timerManager: SweepTimers(), recipeEditor: SweepRecipe())
        let outcome = tools.execute(toolName: "set_recipe_details", arguments: ["title": "Tuscan chicken"])
        #expect(outcome.forUser == "The recipe is now called 'Tuscan chicken'.")
        #expect(outcome.forModel.contains("Nothing is saved"))
    }

    /// A quoted step removed first renumbered the ones a number in the same batch meant.
    @Test func removingStepsByNumberAndQuoteTogether() {
        let recipe = SweepRecipe()
        recipe.steps = ["Chop the onion.", "Fry the onion.", "Add the stock.", "Simmer."]
        let tools = CookingTools(timerManager: SweepTimers(), recipeEditor: recipe)
        _ = tools.execute(toolName: "remove_steps", arguments: ["steps": "Chop the onion\n3"])
        #expect(recipe.steps == ["Fry the onion.", "Simmer."])
    }

    /// "the" and "cup" are not what a line is about.
    @Test func looseMatchingIgnoresFillerAndUnits() {
        let recipe = SweepRecipe()
        recipe.ingredients = ["2 cups flour", "1 tsp salt, for the pasta water", "3 eggs"]
        let tools = CookingTools(timerManager: SweepTimers(), recipeEditor: recipe)
        _ = tools.execute(toolName: "remove_ingredients", arguments: ["items": "the paprika"])
        _ = tools.execute(toolName: "update_ingredients", arguments: ["changes": "1 cup sugar -> 2 cups sugar"])
        #expect(recipe.ingredients == ["2 cups flour", "1 tsp salt, for the pasta water", "3 eggs"])
        // The words that do identify a line still find it.
        _ = tools.execute(toolName: "remove_ingredients", arguments: ["items": "the eggs"])
        #expect(recipe.ingredients == ["2 cups flour", "1 tsp salt, for the pasta water"])
    }

    @Test(arguments: [
        (["minutes": 1.5] as [String: Any], 90),
        (["minutes": "5 minutes"], 300),
        (["minutes": "2", "seconds": "30"], 150),
        (["seconds": 45], 45),
    ] as [([String: Any], Int)])
    func timerDurationsAreReadHoweverTheyAreWritten(arguments: [String: Any], seconds: Int) {
        let timers = SweepTimers()
        var arguments = arguments
        arguments["name"] = "rice"
        _ = CookingTools(timerManager: timers).execute(toolName: "create_timer", arguments: arguments)
        #expect(timers.timers.first?.durationSeconds == seconds)
    }

    @Test func renamingATimerOntoAnotherIsRefused() {
        let timers = SweepTimers()
        let tools = CookingTools(timerManager: timers)
        _ = tools.execute(toolName: "create_timer", arguments: ["name": "rice", "minutes": 10])
        _ = tools.execute(toolName: "create_timer", arguments: ["name": "pasta", "minutes": 8])
        _ = tools.execute(toolName: "update_timer", arguments: ["name": "rice", "new_name": "pasta"])
        #expect(timers.timers.map(\.label) == ["rice", "pasta"])
    }
}

// MARK: - Timer inference

/// Advice that mentions a timer is not a timer action. With one timer set, each of these
/// stopped, started or deleted it.
@Test(arguments: [
    "When the timer goes off, remove the pan from the heat.",
    "Stop stirring once the timer rings.",
    "Start the sauce while the pasta timer runs.",
    "Don't cancel the timer yet, the chicken needs longer.",
    "You could set a timer and start checking at 10 minutes.",
])
func adviceIsNotATimerAction(reply: String) {
    #expect(TimerActionInference.action(for: reply) == nil)
}

@Test func timerActionsTheModelSaysItTookAreStillInferred() {
    #expect(TimerActionInference.action(for: "I've paused the 'rice' timer.") == .init(tool: "stop_timer", timerName: "rice"))
    #expect(TimerActionInference.action(for: "Okay, the timer has been deleted.") == .init(tool: "delete_timer", timerName: "timer"))
    #expect(TimerActionInference.action(for: "Resuming the timer now.") == .init(tool: "start_timer", timerName: "timer"))
}

// MARK: - Commands

@MainActor
struct SweepCommandTests {
    private func answer(_ text: String, timers: SweepTimers) -> String? {
        CookingCommand.answer(to: text, recipe: nil, lastReply: nil, tools: CookingTools(timerManager: timers))
    }

    @Test func howMuchLongerIsLeft() {
        let timers = SweepTimers()
        _ = timers.createTimer(name: "rice", durationSeconds: 300)
        #expect(answer("How much longer is left?", timers: timers) == "The rice timer is set for 5 minutes and hasn't started.")
    }

    /// "Remove the garlic" is about the recipe, even with a garlic bread timer set.
    @Test func removingAnIngredientIsNotDeletingATimer() {
        let timers = SweepTimers()
        _ = timers.createTimer(name: "garlic bread", durationSeconds: 300)
        #expect(answer("Remove the garlic", timers: timers) == nil)
        #expect(timers.timers.count == 1)
        #expect(answer("Delete the garlic bread timer", timers: timers) != nil)
        #expect(timers.timers.isEmpty)
    }
}

// MARK: - Inventory matching

@Test func halfAndHalfIsAnIngredient() {
    let missing = IngredientMatcher.availability(of: ["1 cup half and half"], inventory: ["Milk"])
    #expect(missing.missingNames == ["Half and half"])
    #expect(IngredientMatcher.availability(of: ["1 cup half-and-half"], inventory: ["Half and half"]).canMake)
}

@Test(arguments: [
    ("Cookies", "1 cookie, crumbled"),
    ("Bay leaf", "2 bay leaves"),
    ("Pie crust", "2 pie crusts"),
    ("Chili", "2 chilies"),
])
func pluralsMatchTheirSingulars(item: String, line: String) {
    #expect(IngredientMatcher.availability(of: [line], inventory: [item]).canMake)
}

// MARK: - Import

@Test func schemaCategoriesBecomeSeparateTags() throws {
    let recipe = try RecipeExtraction.fromSchemaOrg(
        json: #"{"name": "Soup", "recipeIngredient": ["1 onion"], "recipeCategory": "Dinner, Main Course", "keywords": "easy, soup, dinner"}"#,
        sourceUrl: nil)
    #expect(recipe.tags == ["dinner", "main course", "easy", "soup"])
}

/// The clean-up pass fills what the page left out. It never rewrites what the page said.
@Test func cleanUpOnlyFillsWhatWasMissing() {
    let page = RecipeData(
        title: "Soup", description: nil, servings: 4, prepTime: nil, cookTime: 30,
        ingredients: ["1 onion", "2 carrots"], instructions: ["Chop.", "Simmer."], tags: [],
        sourceUrl: "https://example.com", cuisineType: nil, difficulty: nil)
    let model = RecipeData(
        title: "Hearty Vegetable Soup", description: "A warming soup.", servings: 6, prepTime: 10, cookTime: 45,
        ingredients: ["1 large onion, diced"], instructions: ["Chop everything."], tags: ["soup"],
        sourceUrl: nil, cuisineType: "French", difficulty: "easy")
    let merged = RecipeExtraction.filling(page, from: model)
    #expect(merged.title == "Soup")
    #expect(merged.ingredients == ["1 onion", "2 carrots"])
    #expect(merged.instructions == ["Chop.", "Simmer."])
    #expect(merged.servings == 4)
    #expect(merged.cookTime == 30)
    #expect(merged.prepTime == 10)
    #expect(merged.description == "A warming soup.")
    #expect(merged.tags == ["soup"])
    #expect(merged.cuisineType == "French")
    #expect(merged.difficulty == "easy")
    #expect(merged.sourceUrl == "https://example.com")
}

// MARK: - Found in the Simulator pass

@MainActor
struct SweepSimulatorTests {
    @Test(arguments: ["Set a 5 minute rice timer", "5 minute rice timer", "set a rice timer for 5 minutes"])
    func aTimerNamedBetweenTheDurationAndTimer(said: String) {
        let timers = SweepTimers()
        let reply = CookingCommand.answer(to: said, recipe: nil, lastReply: nil, tools: CookingTools(timerManager: timers))
        #expect(reply != nil)
        #expect(timers.timers.first?.label == "rice")
        #expect(timers.timers.first?.durationSeconds == 300)
    }
}

@Test func noSpaceIsLeftBeforeAComma() {
    #expect(HTMLText.clean("Tortilla chips <a href=\"x\"></a>, to serve") == "Tortilla chips, to serve")
}
