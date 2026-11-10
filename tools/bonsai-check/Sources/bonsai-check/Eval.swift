import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// `bonsai-check eval [model...]`: the cooking assistant's scripted test set. Each case is one
// question in a cook, asked with the app's own prompt (`CookingPrompt`) and tools, and checked
// for the tool call or answer it should produce. Every case runs `EVAL_RUNS` times (default 3,
// at the app's temperature), so a score is a rate rather than one lucky draw.
//
// `EVAL_TOOLS=merged` scores the tools the app has now, `legacy` build 65's twelve, and `both`
// (the default) one after the other, so a change to the tools or the prompt can be compared on
// the same questions.

/// One thing a reply did, whatever the tool set called it: "timer.create", "ingredients.add",
/// "steps.change", "details", "shopping.add".
struct Op: CustomStringConvertible {
    let kind: String
    /// The entries or arguments it carried, for checking what it recorded.
    let text: String
    var seconds = 0
    var description: String { "\(kind)(\(text.replacingOccurrences(of: "\n", with: " | ")))" }
}

struct Reply {
    let text: String
    let ops: [Op]
    var edits: [Op] { ops.filter { !$0.kind.hasPrefix("timer.") } }
}

struct EvalCase {
    let name: String
    var recipe: Recipe = tuscanChicken
    var editing: CookingPrompt.Editing = .following
    var kitchen: CookingPrompt.Kitchen? = .init(missing: ["Heavy cream", "Sun-dried tomatoes"])
    var history: [(String, String)] = []
    var timers: [LocalTimer] = []
    /// Needs `add_to_shopping_list`, which build 65 didn't have.
    var mergedOnly = false
    let question: String
    /// Nil when the reply passes, otherwise why it didn't.
    let check: (Reply) -> String?
}

// MARK: - Checks

func lowered(_ s: String) -> String { s.lowercased() }

func expect(_ kind: String, containing words: [String] = [], count: Int? = nil) -> (Reply) -> String? {
    { reply in
        let matching = reply.ops.filter { $0.kind == kind }
        guard !matching.isEmpty else { return "no \(kind)" }
        if let count, matching.count != count { return "\(matching.count) \(kind) calls, wanted \(count)" }
        let text = lowered(matching.map(\.text).joined(separator: "\n"))
        let missing = words.filter { !text.contains($0) }
        return missing.isEmpty ? nil : "\(kind) lacks \(missing)"
    }
}

func noEdits(_ reply: Reply) -> String? {
    reply.edits.isEmpty ? nil : "edited: \(reply.edits)"
}

func says(_ words: [String]) -> (Reply) -> String? {
    { reply in
        let text = lowered(reply.text)
        return words.contains { text.contains($0) } ? nil : "answer mentions none of \(words)"
    }
}

func all(_ checks: ((Reply) -> String?)...) -> (Reply) -> String? {
    { reply in checks.lazy.compactMap { $0(reply) }.first }
}

func short(_ reply: Reply) -> String? {
    let words = reply.text.split(whereSeparator: \.isWhitespace).count
    return words <= 70 ? nil : "\(words) words"
}

func noTimerStart(_ reply: Reply) -> String? {
    reply.ops.contains { $0.kind == "timer.start" } ? "started the timer it created" : nil
}

func timer(_ kind: String, named name: String, seconds: Int? = nil) -> (Reply) -> String? {
    { reply in
        guard let op = reply.ops.first(where: { $0.kind == kind }) else { return "no \(kind)" }
        guard lowered(op.text).contains(name) else { return "\(kind) named \(op.text)" }
        if let seconds, op.seconds != seconds { return "\(kind) for \(op.seconds)s, wanted \(seconds)s" }
        return nil
    }
}

// MARK: - Cases

let tuscanChicken = Recipe(
    id: UUID(), title: "Creamy Tuscan Chicken",
    description: "Seared chicken in a garlic, sun-dried tomato and spinach cream sauce.",
    servings: 4, prepTime: 10, cookTime: 25,
    ingredients: [
        "4 boneless chicken thighs", "1 tsp salt", "1/2 tsp black pepper", "2 tbsp olive oil",
        "4 cloves garlic, minced", "1/2 cup sun-dried tomatoes, chopped", "1 cup heavy cream",
        "1/2 cup chicken stock", "1/2 cup grated parmesan", "2 cups baby spinach", "1 tsp Italian seasoning",
    ],
    instructions: [
        "Season the chicken on both sides with the salt and pepper.",
        "Heat the olive oil in a large skillet over medium-high heat. Sear the chicken 5-6 minutes a side until golden and cooked through, then set it aside.",
        "Lower the heat to medium. Add the garlic and sun-dried tomatoes and cook for 1 minute.",
        "Pour in the cream and stock, add the Italian seasoning, and bring to a gentle simmer.",
        "Stir in the parmesan until melted, then the spinach until it wilts.",
        "Return the chicken to the pan and simmer 5 minutes, spooning the sauce over it.",
    ],
    tags: [], sourceUrl: nil, cuisineType: "Italian", difficulty: "easy", createdAt: Date(), updatedAt: Date())

func blankRecipe(ingredients: [String] = []) -> Recipe {
    Recipe(id: UUID(), title: "", description: nil, servings: 4, prepTime: nil, cookTime: nil,
           ingredients: ingredients, instructions: [], tags: [], sourceUrl: nil, cuisineType: nil,
           difficulty: nil, createdAt: Date(), updatedAt: Date())
}

func makeTimer(_ label: String, seconds: Int, _ status: TimerStatusType) -> LocalTimer {
    LocalTimer(id: UUID().uuidString, label: label, durationSeconds: seconds, remainingSeconds: seconds,
               status: status, createdAt: Date())
}

let pastaWaiting = [makeTimer("pasta", seconds: 540, .new)]
let chickenRunning = [makeTimer("chicken", seconds: 200, .running)]
let pastaCreated = [("Set a timer for the pasta, 9 minutes.", "Timer 'pasta' is set for 9 minutes. Say start when you're ready.")]

let evalCases: [EvalCase] = [
    // Questions: answered from the recipe, and nothing edited.
    EvalCase(name: "sear time", question: "How long do I sear the chicken for?",
             check: all(noEdits, says(["5", "6", "five", "six"]))),
    EvalCase(name: "what next", question: "What do I do after the spinach wilts?",
             check: all(noEdits, says(["chicken"]))),
    EvalCase(name: "swap asked", question: "Can I use half-and-half instead of heavy cream?",
             check: all(noEdits, short)),
    EvalCase(name: "spicier asked", question: "What else could I add to make it spicier?",
             check: noEdits),
    EvalCase(name: "breasts asked", question: "Is it okay to use chicken breasts instead of thighs?",
             check: all(noEdits, short)),
    EvalCase(name: "amount asked", question: "The recipe says a cup of cream. Is that a lot?",
             check: noEdits),

    // Changes the cook made: recorded.
    EvalCase(name: "swap made", question: "I'm using half-and-half instead of the heavy cream.",
             check: expect("ingredients.change", containing: ["half"])),
    EvalCase(name: "amount made", question: "I only had 2 cloves of garlic, so I used those.",
             check: expect("ingredients.change", containing: ["2"])),
    EvalCase(name: "extra", question: "I added a pinch of chili flakes with the garlic.",
             check: expect("ingredients.add", containing: ["chili"])),
    EvalCase(name: "batch", question: "I also threw in 1 tsp cumin, 1 tsp smoked paprika and a squeeze of lemon.",
             check: expect("ingredients.add", containing: ["cumin", "paprika", "lemon"], count: 1)),
    EvalCase(name: "left out", question: "I left out the parmesan.",
             check: expect("ingredients.remove", containing: ["parmesan"])),
    EvalCase(name: "step made", question: "I seared it for 8 minutes a side instead.",
             check: expect("steps.change", containing: ["8"])),
    EvalCase(name: "servings", question: "Can you scale this down to 2 servings?",
             check: expect("details", containing: ["servings=2"])),

    // Timers.
    EvalCase(name: "timer create", question: "Set a timer for the chicken, 6 minutes.",
             check: all(timer("timer.create", named: "chicken", seconds: 360), noTimerStart)),
    EvalCase(name: "timer seconds", question: "Make a 45 second timer for the garlic.",
             check: all(timer("timer.create", named: "garlic", seconds: 45), noTimerStart)),
    EvalCase(name: "timer start", history: pastaCreated, timers: pastaWaiting,
             question: "Okay, the water's boiling, go ahead and start it.",
             check: timer("timer.start", named: "pasta")),
    EvalCase(name: "timer change", timers: chickenRunning, question: "Actually make the chicken timer 8 minutes.",
             check: timer("timer.change", named: "chicken", seconds: 480)),
    EvalCase(name: "timer stop", timers: chickenRunning, question: "Hold the chicken timer while I flip it.",
             check: timer("timer.stop", named: "chicken")),
    EvalCase(name: "time left", timers: chickenRunning, question: "How much longer on the chicken?",
             check: all(noEdits, says(["3 minutes", "three minutes", "3 min", "200"]))),

    // The kitchen.
    EvalCase(name: "have everything", question: "Do I have everything I need?",
             check: all(noEdits, says(["cream", "tomato"]))),
    EvalCase(name: "shopping", mergedOnly: true, question: "Put the heavy cream on my shopping list.",
             check: all(expect("shopping.add", containing: ["cream"]),
                        { $0.ops.contains { $0.kind.hasPrefix("ingredients.") } ? "edited the recipe" : nil })),

    // A cook with no recipe: written down as it goes.
    EvalCase(name: "write ingredients", recipe: blankRecipe(), editing: .writing, kitchen: nil,
             question: "I'm making a quick stir fry with 2 chicken breasts, a red bell pepper and 3 tablespoons of soy sauce.",
             check: expect("ingredients.add", containing: ["chicken", "pepper", "soy"], count: 1)),
    EvalCase(name: "write steps",
             recipe: blankRecipe(ingredients: ["2 chicken breasts", "1 red bell pepper", "3 tbsp soy sauce"]),
             editing: .writing, kitchen: nil,
             question: "First I fried the chicken in a tablespoon of oil for 5 minutes, then added the pepper.",
             check: expect("steps.add", containing: ["chicken"])),
    EvalCase(name: "write name",
             recipe: blankRecipe(ingredients: ["2 chicken breasts", "1 red bell pepper", "3 tbsp soy sauce"]),
             editing: .writing, kitchen: nil, question: "Let's call it weeknight chicken stir fry.",
             check: expect("details", containing: ["stir fry"])),
    EvalCase(name: "write question",
             recipe: blankRecipe(ingredients: ["2 chicken breasts", "1 red bell pepper", "3 tbsp soy sauce"]),
             editing: .writing, kitchen: nil, question: "Should I add the soy sauce now or at the end?",
             check: noEdits),
]

// MARK: - Reading calls

private func text(_ value: Any?) -> String {
    if let array = value as? [Any] { return array.map { "\($0)" }.joined(separator: "\n") }
    return value.map { "\($0)" } ?? ""
}

private func int(_ value: Any?) -> Int {
    if let i = value as? Int { return i }
    if let d = value as? Double { return Int(d) }
    if let s = value as? String { return Int(s) ?? 0 }
    return 0
}

/// What one call did, in either tool set's names.
func ops(_ name: String, _ args: [String: Any]) -> [Op] {
    let seconds = int(args["minutes"]) * 60 + int(args["seconds"])
    let label = text(args["name"])
    func timerOp(_ action: String) -> [Op] { [Op(kind: "timer.\(action)", text: label, seconds: seconds)] }
    switch name {
    case "timer":
        switch text(args["action"]).lowercased() {
        case "create", "set", "add", "new", "make": return timerOp("create")
        case "start", "resume", "run": return timerOp("start")
        case "stop", "pause": return timerOp("stop")
        case "change", "update", "edit", "rename", "adjust": return timerOp("change")
        case "delete", "cancel", "remove", "clear": return timerOp("delete")
        default: return timerOp("unknown")
        }
    case "create_timer", "set_timer": return timerOp("create")
    case "start_timer": return timerOp("start")
    case "stop_timer", "pause_timer": return timerOp("stop")
    case "update_timer": return timerOp("change")
    case "delete_timer": return timerOp("delete")
    case "edit_ingredients", "edit_steps":
        let section = name == "edit_ingredients" ? "ingredients" : "steps"
        return ["change", "remove", "add"].compactMap { key in
            args[key].map { Op(kind: "\(section).\(key)", text: text($0)) }
        }
    case "add_ingredients", "add_ingredient": return [Op(kind: "ingredients.add", text: text(args["items"] ?? args["item"]))]
    case "update_ingredients", "update_ingredient": return [Op(kind: "ingredients.change", text: args.map { "\($0.value)" }.joined(separator: "\n"))]
    case "remove_ingredients", "remove_ingredient": return [Op(kind: "ingredients.remove", text: text(args["items"] ?? args["item"]))]
    case "add_steps", "add_step": return [Op(kind: "steps.add", text: text(args["steps"] ?? args["step"]))]
    case "update_steps", "update_step": return [Op(kind: "steps.change", text: args.map { "\($0.value)" }.joined(separator: "\n"))]
    case "remove_steps", "remove_step": return [Op(kind: "steps.remove", text: text(args["steps"] ?? args["step"]))]
    case "set_recipe_details":
        return [Op(kind: "details", text: args.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))]
    case "add_to_shopping_list": return [Op(kind: "shopping.add", text: text(args["items"]))]
    default: return [Op(kind: "unknown.\(name)", text: "")]
    }
}

// MARK: - Running

/// The prompt with build 65's tool names, for the legacy run: the same rules, naming the tools
/// that set had.
func legacyWording(_ prompt: String) -> String {
    prompt
        .replacingOccurrences(of: "record it with edit_ingredients or edit_steps",
                              with: "record it with update_ingredients, add_ingredients, remove_ingredients, update_steps, add_steps or remove_steps")
        .replacingOccurrences(of: "record them with edit_ingredients", with: "record them with add_ingredients")
        .replacingOccurrences(of: "record it with edit_steps", with: "record it with add_steps")
}

func runEval(ids: [String]) async -> Bool {
    let runs = ProcessInfo.processInfo.environment["EVAL_RUNS"].flatMap(Int.init) ?? 3
    let which = ProcessInfo.processInfo.environment["EVAL_TOOLS"] ?? "both"
    let toolSets = which == "both" ? ["legacy", "merged"] : [which]
    var ok = true

    for id in ids {
        print("\n=== \(id): \(evalCases.count) cases x \(runs) runs")
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: HubDownloader(), using: TransformersTokenizerLoader(), configuration: ModelConfiguration(id: id))
        } catch {
            print("LOAD FAILED: \(error)")
            ok = false
            continue
        }

        for toolSet in toolSets {
            var passed = 0, total = 0
            var seconds = 0.0
            var promptTokens: [Int] = []
            print("-- \(toolSet) tools")
            for evalCase in evalCases {
                if toolSet == "legacy" && evalCase.mergedOnly { continue }
                let specs: [CookingToolSpec]
                switch (toolSet, evalCase.editing) {
                case ("legacy", .none): specs = LegacyTools.timer
                case ("legacy", _): specs = LegacyTools.timer + LegacyTools.recipe
                case (_, .none): specs = CookingTools.timerToolSpecs
                default: specs = CookingTools.timerToolSpecs + CookingTools.recipeToolSpecs + [CookingTools.shoppingToolSpec]
                }
                var system = CookingPrompt(provider: .local, recipe: evalCase.recipe, editing: evalCase.editing,
                                           kitchen: evalCase.kitchen).system
                if toolSet == "legacy" { system = legacyWording(system) }
                var chat: [Chat.Message] = [.system(system)]
                for (user, assistant) in evalCase.history { chat += [.user(user), .assistant(assistant)] }
                chat.append(.user(evalCase.question + CookingPrompt.timersNote(evalCase.timers)))

                var wins = 0
                var failures: [String] = []
                for _ in 0..<runs {
                    let started = Date()
                    do {
                        let (reply, tokens) = try await ask(container, chat: chat, tools: specs.map(\.mlxToolSpec))
                        seconds += Date().timeIntervalSince(started)
                        promptTokens.append(tokens)
                        if let why = evalCase.check(reply) {
                            failures.append("\(why) | \(reply.ops) \(reply.text.prefix(120).replacingOccurrences(of: "\n", with: " "))")
                        } else {
                            wins += 1
                        }
                    } catch {
                        failures.append("error: \(error)")
                    }
                }
                passed += wins
                total += runs
                print(String(format: "  %@ %d/%d %@", wins == runs ? "PASS" : "MISS", wins, runs, evalCase.name))
                for failure in failures.prefix(2) { print("      \(failure)") }
            }
            let averageTokens = promptTokens.isEmpty ? 0 : promptTokens.reduce(0, +) / promptTokens.count
            print(String(format: "  %@ tools: %d/%d (%.0f%%), prompt about %d tokens, %.1fs a reply",
                         toolSet, passed, total, 100 * Double(passed) / Double(max(total, 1)), averageTokens,
                         seconds / Double(max(total, 1))))
        }
    }
    return ok
}

/// One question as the phone asks it: the app's template settings and sampling, and the tool
/// calls the app would execute — native ones, and those written out as text.
func ask(_ container: ModelContainer, chat: [Chat.Message], tools: [ToolSpec]) async throws -> (Reply, Int) {
    nonisolated(unsafe) let input = UserInput(chat: chat, tools: tools, additionalContext: ["enable_thinking": false])
    let (stream, tokens) = try await container.perform { (context: ModelContext) in
        let lmInput = try await context.processor.prepare(input: input)
        var parameters = GenerateParameters(maxTokens: 512, temperature: 0.7)
        parameters.topP = 0.8
        parameters.topK = 20
        parameters.prefill.stepSize = prefillStep
        return (try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context), lmInput.text.tokens.size)
    }
    var output = ""
    var found: [Op] = []
    for await generation in stream {
        switch generation {
        case .chunk(let chunk): output += chunk
        case .toolCall(let call): found += ops(call.function.name, call.function.arguments.mapValues { $0.anyValue })
        default: break
        }
    }
    let text = ModelReplyText.replacingToolCalls(in: ModelReplyText.strippingThinking(output)) { name, arguments in
        found += ops(name, arguments)
        return ""
    }
    return (Reply(text: text, ops: found), tokens)
}
