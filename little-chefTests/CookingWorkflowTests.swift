//
//  CookingWorkflowTests.swift
//  little-chefTests
//
//  The cooking assistant's merged tools, its prompt, and the commands answered without a model.
//

import Foundation
import Testing
@testable import little_chef

// MARK: - Doubles

@MainActor
private final class Timers: TimerManager {
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

@MainActor
private final class Lines: RecipeEditing {
    var ingredients: [String] = []
    var steps: [String] = []
    var isBuildingNewRecipe = false
    var currentIngredients: [String] { ingredients }
    var currentSteps: [String] { steps }

    func addIngredient(_ text: String, at position: Int?) -> LineAdditionOutcome {
        guard !ingredients.contains(text) else { return .alreadyPresent }
        ingredients.insert(text, at: min(max((position ?? Int.max) - 1, 0), ingredients.count))
        return .added
    }
    func replaceIngredient(matching query: String, with text: String) -> String? {
        guard let i = ingredients.firstIndex(where: { $0.localizedCaseInsensitiveContains(query) }) else { return nil }
        defer { ingredients[i] = text }
        return ingredients[i]
    }
    func removeIngredient(matching query: String) -> String? {
        guard let i = ingredients.firstIndex(where: { $0.localizedCaseInsensitiveContains(query) }) else { return nil }
        return ingredients.remove(at: i)
    }
    func addStep(_ text: String, at position: Int?) -> LineAdditionOutcome {
        steps.insert(text, at: min(max((position ?? Int.max) - 1, 0), steps.count))
        return .added
    }
    func replaceStep(matching query: String, with text: String) -> String? {
        guard let n = Int(query), steps.indices.contains(n - 1) else { return nil }
        defer { steps[n - 1] = text }
        return steps[n - 1]
    }
    func removeStep(matching query: String) -> String? {
        guard let n = Int(query), steps.indices.contains(n - 1) else { return nil }
        return steps.remove(at: n - 1)
    }
    func setRecipeDetails(title: String?, description: String?, servings: Int?, prepTime: Int?, cookTime: Int?,
                          difficulty: String?, cuisineType: String?, tags: [String]?) -> [String] { [] }
}

@MainActor
private final class Shopping: ShoppingListWriting {
    var items: [String] = []
    func addShoppingItems(_ names: [String]) -> [String] {
        let new = names.filter { !items.contains($0) }
        items += new
        return new
    }
}

private let recipe = Recipe(
    id: UUID(), title: "Tuscan chicken", description: nil, servings: 4, prepTime: 10, cookTime: 25,
    ingredients: ["4 chicken thighs", "1 tsp salt", "1/2 tsp black pepper", "1 cup heavy cream", "4 cloves garlic, minced"],
    instructions: ["Season the chicken.", "Sear it 5 minutes a side.", "Add the cream and simmer."],
    tags: [], sourceUrl: nil, cuisineType: nil, difficulty: nil, createdAt: Date(), updatedAt: Date())

// MARK: - Merged tools

@MainActor
struct MergedToolTests {
    @Test func timerActionsRunTheToolsTheyReplaced() {
        let timers = Timers()
        let tools = CookingTools(timerManager: timers)

        let created = tools.execute(toolName: "timer", arguments: ["action": "create", "name": "pasta", "minutes": 9])
        #expect(created.forUser.contains("set for 9 minutes"))
        #expect(timers.timers.first?.status == .new)

        // Same loop: a start right after the create is refused, as with start_timer.
        _ = tools.execute(toolName: "timer", arguments: ["action": "start", "name": "pasta"])
        #expect(timers.timers.first?.status == .new)

        _ = tools.execute(toolName: "timer", arguments: ["action": "change", "name": "pasta", "minutes": 12])
        #expect(timers.timers.first?.remainingSeconds == 720)
        _ = tools.execute(toolName: "timer", arguments: ["action": "delete", "name": "pasta"])
        #expect(timers.timers.isEmpty)

        #expect(tools.execute(toolName: "timer", arguments: ["action": "explode", "name": "x"]).forUser.contains("must be"))
    }

    @Test func editIngredientsChangesRemovesAndAddsInOneCall() {
        let lines = Lines()
        lines.ingredients = ["2 tbsp butter", "1 onion", "salt"]
        let tools = CookingTools(timerManager: Timers(), recipeEditor: lines)

        let outcome = tools.execute(toolName: "edit_ingredients", arguments: [
            "change": "2 tbsp butter -> 2 tbsp olive oil", "remove": "salt", "add": "1 tsp cumin\n1 tsp paprika",
        ])
        #expect(lines.ingredients == ["2 tbsp olive oil", "1 onion", "1 tsp cumin", "1 tsp paprika"])
        // The list once, at the end, and only for the model.
        #expect(outcome.forModel.components(separatedBy: "Ingredients now").count == 2)
        #expect(outcome.forModel.contains("Nothing is saved"))
        #expect(!outcome.forUser.contains("Ingredients now"))
    }

    /// Step numbers mean what they meant in the recipe the model was shown, so changes and
    /// removals run before additions.
    @Test func editStepsUsesTheNumbersAsShown() {
        let lines = Lines()
        lines.steps = ["One", "Two", "Three"]
        let tools = CookingTools(timerManager: Timers(), recipeEditor: lines)

        _ = tools.execute(toolName: "edit_steps", arguments: ["change": "3 -> Three, longer", "add": "Zero", "position": 1])
        #expect(lines.steps == ["Zero", "One", "Two", "Three, longer"])
    }

    @Test func theOldActionAndItemsShapeStillWorks() {
        let lines = Lines()
        let tools = CookingTools(timerManager: Timers(), recipeEditor: lines)
        _ = tools.execute(toolName: "edit_ingredients", arguments: ["action": "add", "items": "two eggs"])
        #expect(lines.ingredients == ["two eggs"])
        #expect(tools.execute(toolName: "edit_ingredients", arguments: [:]).forUser.contains("add, change or remove"))
    }

    @Test func shoppingListToolIsOfferedOnlyWithAList() {
        #expect(!CookingTools(timerManager: Timers()).toolSpecs.contains { $0.name == "add_to_shopping_list" })

        let shopping = Shopping()
        shopping.items = ["cream"]
        let tools = CookingTools(timerManager: Timers(), shoppingList: shopping)
        #expect(tools.toolSpecs.map(\.name) == ["timer", "add_to_shopping_list"])

        let outcome = tools.execute(toolName: "add_to_shopping_list", arguments: ["items": "shallots\ncream"])
        #expect(shopping.items == ["cream", "shallots"])
        #expect(outcome.forUser == "Added shallots to your shopping list. cream was already on it.")
    }
}

// MARK: - Prompt

struct CookingPromptTests {
    @Test func theKitchenLineSaysWhatIsMissing() {
        let missing = CookingPrompt(provider: .local, recipe: recipe, editing: .following,
                                    kitchen: .init(missing: ["Heavy cream", "Garlic"])).system
        #expect(missing.contains("Kitchen: the user's inventory doesn't have Heavy cream and Garlic. It has everything else."))

        let all = CookingPrompt(provider: .local, recipe: recipe, editing: .following, kitchen: .init(missing: [])).system
        #expect(all.contains("inventory has every ingredient"))

        let none = CookingPrompt(provider: .local, recipe: recipe, editing: .following, kitchen: nil).system
        #expect(!none.contains("Kitchen:"))
    }

    @Test func thePromptNamesOnlyTheToolsThatExist() {
        for editing in [CookingPrompt.Editing.following, .writing] {
            let prompt = CookingPrompt(provider: .bigBro, recipe: recipe, editing: editing, kitchen: nil).system
            for old in ["add_ingredients", "update_ingredients", "remove_ingredients", "add_steps", "update_steps", "remove_steps"] {
                #expect(!prompt.contains(old))
            }
            #expect(prompt.contains("edit_ingredients"))
        }
        #expect(!CookingPrompt(provider: .local, recipe: recipe, editing: .none, kitchen: nil).system.contains("edit_"))
    }

    @Test func repliesAreAskedToBeShort() {
        #expect(CookingPrompt(provider: .local, recipe: nil, editing: .none, kitchen: nil).system
            .contains("one to three short sentences"))
    }
}

// MARK: - Commands without the model

@MainActor
struct CookingCommandTests {
    private func answer(_ text: String, timers: Timers? = nil, lastReply: String? = nil) -> String? {
        CookingCommand.answer(to: text, recipe: recipe, lastReply: lastReply, tools: CookingTools(timerManager: timers ?? Timers()))
    }

    private func timers(_ pairs: (String, TimerStatusType)...) -> Timers {
        let timers = Timers()
        timers.timers = pairs.map {
            LocalTimer(id: UUID().uuidString, label: $0.0, durationSeconds: 270, remainingSeconds: 270,
                       status: $0.1, createdAt: Date())
        }
        return timers
    }

    @Test func createsTimersStopped() {
        for said in ["Set a timer for 9 minutes for the pasta.", "Set a 9 minute timer for the pasta",
                     "set the pasta timer for 9 minutes", "Can you set a timer for the pasta for nine minutes please?",
                     "9 minute timer for pasta"] {
            let timers = Timers()
            #expect(answer(said, timers: timers) == "Timer 'pasta' is set for 9 minutes. Say start when you're ready.", "\(said)")
            #expect(timers.timers.first?.status == .new)
        }
        let unnamed = Timers()
        #expect(answer("set a timer for a minute and a half", timers: unnamed) != nil)
        #expect(unnamed.timers.first?.remainingSeconds == 90)
    }

    @Test func durations() {
        #expect(CookingCommand.duration(from: "5 minutes") == 300)
        #expect(CookingCommand.duration(from: "1 and a half hours") == 5400)
        #expect(CookingCommand.duration(from: "2 minutes and 30 seconds") == 150)
        #expect(CookingCommand.duration(from: "half an hour") == 1800)
        #expect(CookingCommand.duration(from: "twenty five minutes") == 1500)
        #expect(CookingCommand.duration(from: "1.5 minutes") == 90)
        #expect(CookingCommand.duration(from: "5 minutes for the pasta") == nil)
        #expect(CookingCommand.duration(from: "the pasta") == nil)
    }

    @Test func startsTheOneTimerThatIsWaiting() {
        let waiting = timers(("pasta", .new))
        #expect(answer("Start", timers: waiting)?.contains("started") == true)
        #expect(waiting.timers.first?.status == .running)

        let named = timers(("pasta", .new), ("rice", .new))
        #expect(answer("start the rice timer", timers: named)?.contains("'rice' started") == true)
        // Two waiting and no name: the model decides.
        #expect(answer("start the timer", timers: timers(("pasta", .new), ("rice", .new))) == nil)
    }

    @Test func stopAndCancelNeedATimerNamedOrMentioned() {
        #expect(answer("stop", timers: timers(("pasta", .running))) == nil)
        #expect(answer("cancel", timers: timers(("pasta", .running))) == nil)
        #expect(answer("pause the timer", timers: timers(("pasta", .running)))?.contains("stopped") == true)
        let deleting = timers(("pasta", .running))
        #expect(answer("cancel the pasta timer", timers: deleting) == "Timer 'pasta' deleted.")
        #expect(deleting.timers.isEmpty)
    }

    @Test func timeLeft() {
        let running = timers(("pasta", .running), ("rice", .paused))
        #expect(answer("How long is left on the pasta?", timers: running) == "The pasta timer has 4 minutes and 30 seconds left.")
        #expect(answer("how much time is left", timers: running)
            == "The pasta timer has 4 minutes and 30 seconds left. The rice timer is paused with 4 minutes and 30 seconds left.")
        // No timers: maybe a question about the recipe.
        #expect(answer("how much time is left") == nil)
    }

    @Test func questionsAboutCookingGoToTheModel() {
        let chicken = timers(("chicken", .running))
        for said in ["How long do I sear the chicken?", "Can I use half-and-half instead of cream?",
                     "start the sauce", "remove the garlic", "What's next?", "how much cream should I add to thicken it",
                     "Stop the chicken from sticking", "set a timer"] {
            #expect(answer(said, timers: chicken) == nil, "\(said)")
        }
    }

    @Test func repeatAndSteps() {
        #expect(answer("Say that again", lastReply: "Sear it for 5 minutes.") == "Sear it for 5 minutes.")
        #expect(answer("repeat that") == nil)
        #expect(answer("What's step 2?") == "Step 2: Sear it 5 minutes a side.")
        #expect(answer("read me the last step") == "Step 3: Add the cream and simmer.")
        #expect(answer("step nine") == "The recipe has 3 steps.")
    }

    @Test func amounts() {
        #expect(answer("How much salt do I need?") == "The recipe calls for 1 tsp salt.")
        #expect(answer("how much pepper") == "The recipe calls for 1/2 tsp black pepper.")
        #expect(answer("how many cloves of garlic") == "The recipe calls for 4 cloves garlic, minced.")
        #expect(answer("how much butter") == nil)
    }
}
