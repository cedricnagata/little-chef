//
//  RecipeSuggester.swift
//  little-chef
//
//  Orders recipes by what suits the time of day and what's already in the kitchen.
//

import Foundation
import BigBroKit

/// Which meal the current time of day is for.
enum MealPeriod: String {
    case breakfast, lunch, dinner, lateNight

    init(date: Date, calendar: Calendar = .current) {
        switch calendar.component(.hour, from: date) {
        case 5..<11: self = .breakfast
        case 11..<16: self = .lunch
        case 16..<22: self = .dinner
        default: self = .lateNight
        }
    }

    var displayName: String {
        switch self {
        case .breakfast: return "breakfast"
        case .lunch: return "lunch"
        case .dinner: return "dinner"
        case .lateNight: return "a late-night snack"
        }
    }

    /// Words in a title or tag that suggest a recipe fits this meal. Only used without AI.
    fileprivate var keywords: [String] {
        switch self {
        case .breakfast:
            return ["breakfast", "brunch", "pancake", "waffle", "egg", "omelet", "omelette", "oat", "porridge",
                    "granola", "smoothie", "toast", "muffin", "scone", "bagel", "frittata", "yogurt", "crepe"]
        case .lunch:
            return ["lunch", "salad", "sandwich", "wrap", "soup", "bowl", "quesadilla", "burger", "taco"]
        case .dinner:
            return ["dinner", "main", "entree", "roast", "curry", "pasta", "stew", "casserole", "steak",
                    "chicken", "salmon", "lasagna", "risotto", "stir fry", "stir-fry", "chili"]
        case .lateNight:
            return ["snack", "dessert", "cookie", "cake", "popcorn", "dip", "toast", "noodle"]
        }
    }
}

/// The result of a ranking: recipe ids best first, and whether an AI model produced it.
struct RecipeSuggestions: Equatable {
    let order: [UUID]
    let rankedByAI: Bool
    let mealPeriod: MealPeriod
}

@MainActor
enum RecipeSuggester {

    /// Recipes beyond this many (after the deterministic pre-sort) are appended unranked. Keeps
    /// the prompt small enough for an on-device model to answer in a few seconds.
    static let maxRankedByAI = 30

    /// Ranks `recipes`, asking the AI when it is available and falling back to the deterministic
    /// order when it isn't or its answer can't be used. Never throws: a suggestion list is
    /// always better than an error in a filter.
    static func rank(
        _ recipes: [Recipe],
        availability: [UUID: RecipeAvailability],
        now: Date = Date(),
        llmService: LLMService
    ) async -> RecipeSuggestions {
        let meal = MealPeriod(date: now)
        let fallback = heuristicOrder(recipes, availability: availability, meal: meal)
        guard !recipes.isEmpty, llmService.capability.llmChatEnabled else {
            return RecipeSuggestions(order: fallback.map(\.id), rankedByAI: false, mealPeriod: meal)
        }

        let candidates = Array(fallback.prefix(maxRankedByAI))
        do {
            let response = try await llmService.generateChatCompletion(
                messages: prompt(for: candidates, availability: availability, meal: meal, now: now),
                temperature: 0.2,
                maxTokens: 300,
                responseFormat: .json
            )
            let ranked = parseOrder(response, count: candidates.count).map { candidates[$0].id }
            guard !ranked.isEmpty else {
                dprint("🍽️ [SUGGEST] AI answer had no usable order, using the fallback: \(response.prefix(200))")
                return RecipeSuggestions(order: fallback.map(\.id), rankedByAI: false, mealPeriod: meal)
            }
            // Anything the model left out keeps its fallback position after the ranked ones.
            let rest = fallback.map(\.id).filter { !ranked.contains($0) }
            return RecipeSuggestions(order: ranked + rest, rankedByAI: true, mealPeriod: meal)
        } catch {
            dprint("🍽️ [SUGGEST] AI ranking failed, using the fallback: \(error.localizedDescription)")
            return RecipeSuggestions(order: fallback.map(\.id), rankedByAI: false, mealPeriod: meal)
        }
    }

    /// Fewest missing ingredients first, then recipes whose title or tags fit the meal, then title.
    nonisolated static func heuristicOrder(_ recipes: [Recipe], availability: [UUID: RecipeAvailability], meal: MealPeriod) -> [Recipe] {
        func fitsMeal(_ recipe: Recipe) -> Bool {
            let text = ([recipe.title] + recipe.tags).joined(separator: " ").lowercased()
            return meal.keywords.contains { text.contains($0) }
        }
        return recipes.sorted { a, b in
            let missingA = availability[a.id]?.missing.count ?? a.ingredients.count
            let missingB = availability[b.id]?.missing.count ?? b.ingredients.count
            if missingA != missingB { return missingA < missingB }
            let fitA = fitsMeal(a), fitB = fitsMeal(b)
            if fitA != fitB { return fitA }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private static func prompt(
        for recipes: [Recipe],
        availability: [UUID: RecipeAvailability],
        meal: MealPeriod,
        now: Date
    ) -> [ChatMessage] {
        let time = now.formatted(.dateTime.weekday(.wide).hour().minute())
        let lines = recipes.enumerated().map { index, recipe -> String in
            var parts = [recipe.title]
            if !recipe.tags.isEmpty { parts.append("tags: \(recipe.tags.joined(separator: ", "))") }
            if let cuisine = recipe.cuisineType, !cuisine.isEmpty { parts.append("cuisine: \(cuisine)") }
            let minutes = (recipe.prepTime ?? 0) + (recipe.cookTime ?? 0)
            if minutes > 0 { parts.append("takes \(minutes) min") }
            let missing = availability[recipe.id]?.missing ?? []
            parts.append(missing.isEmpty ? "missing: nothing" : "missing: \(missing.joined(separator: "; "))")
            return "\(index + 1). " + parts.joined(separator: " | ")
        }

        let system = """
        You help a home cook choose what to make. Rank the recipes you are given, best choice first. \
        Prefer recipes that suit the meal and the time available, and that need few or no ingredients \
        the cook is missing. Reply with JSON only, in exactly this form: {"order": [3, 1, 2]}, using \
        the recipe numbers and including every number once.
        """
        let user = "It is \(time), so the cook is probably making \(meal.displayName).\n\nRecipes:\n"
            + lines.joined(separator: "\n")
        return [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)]
    }

    /// Zero-based indices from a model's `{"order": [...]}` answer, in order, deduplicated and
    /// limited to `0..<count`. Reads bare number lists too: small models drop the wrapper.
    nonisolated static func parseOrder(_ response: String, count: Int) -> [Int] {
        var numbers: [Int] = []
        if let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start < end,
           let data = String(response[start...end]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let order = object["order"] as? [Any] {
            numbers = order.compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") }
        } else {
            numbers = response
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
        }

        var seen = Set<Int>()
        return numbers
            .map { $0 - 1 }
            .filter { (0..<count).contains($0) && seen.insert($0).inserted }
    }
}
