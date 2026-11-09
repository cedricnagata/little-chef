import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// What each model is asked, mirroring the app's three uses: cooking chat, the timer and recipe
// tools, and JSON (recipe parsing, the Suggested ranking).

let system = """
    You are Little Chef, a hands-free cooking assistant. The user is cooking right now and \
    hears your answers read aloud, so answer in one to three short sentences, with no lists or \
    markdown. Use the tools to set timers and change the recipe when asked.
    """

struct Probe {
    let name: String
    let prompt: String
    let tools: Bool
    let temperature: Float
    let maxTokens: Int
    let check: (String, [String]) -> Bool
}

let probes: [Probe] = [
    Probe(name: "chat", prompt: "I'm making pancakes. Can I use oil instead of melted butter?",
          tools: false, temperature: 0.7, maxTokens: 200,
          check: { text, calls in calls.isEmpty && text.count > 20 && !text.contains("<think>") }),
    Probe(name: "timer tool", prompt: "Make a timer called pasta for 9 minutes.",
          tools: true, temperature: 0.7, maxTokens: 200,
          check: { _, calls in calls.contains { $0.hasPrefix("create_timer") } }),
    Probe(name: "recipe tool", prompt: "Swap the butter for 2 tbsp olive oil in the recipe.",
          tools: true, temperature: 0.7, maxTokens: 300,
          check: { _, calls in calls.contains { $0.hasPrefix("update_ingredients") } }),
    Probe(name: "JSON", prompt: """
        Return only a JSON object with keys "title" (string), "servings" (integer) and \
        "ingredients" (array of strings) for this recipe: Scrambled eggs for two. Whisk 4 eggs \
        with a pinch of salt, melt 1 tbsp butter, and stir over low heat until just set.
        """, tools: false, temperature: 0.2, maxTokens: 300,
          check: { text, _ in
              guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return false }
              return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) != nil
          }),
]

let toolSpecs = (CookingTools.timerToolSpecs + CookingTools.recipeToolSpecs).map(\.mlxToolSpec)

func gib(_ bytes: Int) -> String { String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }

func run(_ container: ModelContainer, messages: [Chat.Message], tools: [ToolSpec]?, temperature: Float,
         maxTokens: Int) async throws -> (text: String, calls: [String], info: GenerateCompletionInfo?) {
    let input = UserInput(chat: messages, tools: tools, additionalContext: ["enable_thinking": false])
    let stream = try await container.perform { (context: ModelContext) in
        let lmInput = try await context.processor.prepare(input: input)
        var parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
        parameters.topP = 0.8
        parameters.topK = 20
        return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
    }
    var text = "", calls: [String] = [], info: GenerateCompletionInfo?
    for await generation in stream {
        switch generation {
        case .chunk(let chunk): text += chunk
        case .toolCall(let call):
            let arguments = call.function.arguments.map { "\($0.key)=\($0.value.anyValue)" }.sorted()
            calls.append("\(call.function.name)(\(arguments.joined(separator: ", ")))")
        case .info(let completion): info = completion
        default: break
        }
    }
    return (text, calls, info)
}

let ids = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst())
    : CookingModelChoice.allCases.reversed().map(\.modelId)

var failures = 0
for id in ids {
    print("\n=== \(id)")
    MLX.Memory.cacheLimit = 20 * 1024 * 1024
    MLX.Memory.clearCache()
    MLX.Memory.peakMemory = 0
    let started = Date()
    let container: ModelContainer
    do {
        container = try await LLMModelFactory.shared.loadContainer(
            from: HubDownloader(), using: TransformersTokenizerLoader(),
            configuration: ModelConfiguration(id: id))
    } catch {
        print("LOAD FAILED: \(error)")
        failures += 1
        continue
    }
    print(String(format: "loaded in %.0fs; weights in memory %@", Date().timeIntervalSince(started),
                 gib(MLX.Memory.activeMemory)))

    for probe in probes {
        let recipe = "Recipe: Buttermilk pancakes. Ingredients: 2 cups flour; 2 tbsp sugar; 2 tsp baking powder; 2 cups buttermilk; 2 eggs; 3 tbsp butter, melted."
        let messages: [Chat.Message] = [.system(system + "\n\n" + recipe), .user(probe.prompt)]
        do {
            let result = try await run(container, messages: messages, tools: probe.tools ? toolSpecs : nil,
                                       temperature: probe.temperature, maxTokens: probe.maxTokens)
            let passed = probe.check(result.text, result.calls)
            if !passed { failures += 1 }
            let speed = result.info.map { String(format: "%.1f tok/s", $0.tokensPerSecond) } ?? "?"
            print("[\(passed ? "PASS" : "FAIL")] \(probe.name) (\(speed))")
            if !result.calls.isEmpty { print("    calls: \(result.calls.joined(separator: "; "))") }
            let shown = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shown.isEmpty { print("    text: \(shown.prefix(400))") }
        } catch {
            failures += 1
            print("[FAIL] \(probe.name): \(error)")
        }
    }

    // The context's memory: an ~8k-token prompt, as a long recipe page might be.
    let page = String(repeating: "Stir the sauce gently over a low heat, scraping the bottom of the pan so nothing catches. ", count: 450)
    MLX.Memory.peakMemory = 0
    if let result = try? await run(container, messages: [.system(system), .user(page + "\nIn one sentence, what is this text about?")],
                                   tools: nil, temperature: 0.7, maxTokens: 40) {
        let tokens = result.info?.promptTokenCount ?? 0
        print("long prompt: \(tokens) tokens, peak memory \(gib(MLX.Memory.peakMemory)), prefill \(String(format: "%.0f", result.info?.promptTokensPerSecond ?? 0)) tok/s")
    } else {
        failures += 1
        print("[FAIL] long prompt")
    }
}
print("\n\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
exit(failures == 0 ? 0 : 1)
