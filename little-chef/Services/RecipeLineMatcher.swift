//
//  RecipeLineMatcher.swift
//  little-chef
//
//  Working out which line of a recipe the assistant meant.
//

import Foundation

enum RecipeLineMatcher {

    /// Where a 1-based `position` lands, clamped. Nil, zero and anything past the end all append,
    /// because "add it at the end" is what a model means by leaving the argument off and what it
    /// means by an out-of-range guess.
    static func insertionIndex(_ position: Int?, count: Int) -> Int {
        guard let position, position >= 1 else { return count }
        return min(position - 1, count)
    }

    /// The line the model meant.
    ///
    /// It will quote the line back exactly, quote part of it, paraphrase it, or — for steps —
    /// just give the number. Matching only on an exact quote fails often enough that the
    /// assistant would look broken; matching too loosely deletes the wrong ingredient, which is
    /// worse. So: exact, then substring either way round, then the line sharing the most
    /// distinctive words, and nothing at all if that finds none.
    ///
    /// Numbers are only accepted where the UI shows them. Steps are numbered on screen, so "step
    /// 3" and "3" mean the third one. Ingredients are not, and there a bare "2" is far more
    /// likely to be the start of an amount the model truncated than a position.
    static func index(matching query: String, in lines: [String], allowingNumbers: Bool) -> Int? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, !lines.isEmpty else { return nil }

        if allowingNumbers, let number = stepNumber(needle), number >= 1, number <= lines.count {
            return number - 1
        }

        if let exact = lines.firstIndex(where: { $0.lowercased() == needle }) {
            return exact
        }
        if let overlapping = lines.firstIndex(where: {
            let line = $0.lowercased()
            return line.contains(needle) || needle.contains(line)
        }) {
            return overlapping
        }

        // Last resort: "the garlic" against "2 cloves of garlic, minced". Only on the words a
        // line is about. Any three letters used to count, and a substring was enough, so "the
        // paprika" removed the first line with "the" in it and "1 cup sugar" rewrote the flour.
        let words = distinctiveWords(in: needle)
        guard !words.isEmpty else { return nil }
        let scored = lines.enumerated().map { index, line -> (index: Int, score: Int) in
            (index, words.intersection(distinctiveWords(in: line.lowercased())).count)
        }
        // `max(by:)` returns the last of equals; the first line with the best score is the one meant.
        guard let best = scored.reversed().max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
        return best.index
    }

    /// The words that say what a line is about: no amounts, units, or words every line has.
    /// Singular, so "eggs" finds "1 egg".
    static func distinctiveWords(in text: String) -> Set<String> {
        Set(text
            .split(whereSeparator: { !$0.isLetter })
            .map { IngredientMatcher.singular(String($0)) }
            .filter { $0.count >= 3 && !commonWords.contains($0) })
    }

    private static let commonWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "over", "until", "then", "that", "this",
        "some", "any", "all", "more", "about", "your", "our", "its", "are", "was", "has", "have",
        "one", "two", "three", "four", "five", "six", "half", "step", "ingredient", "line",
        "cup", "tablespoon", "teaspoon", "tbsp", "tsp", "gram", "kilogram", "ounce", "pound", "lbs",
        "liter", "litre", "milliliter", "millilitre", "pinch", "dash", "clove", "can", "piece",
        "slice", "bunch", "minute", "hour", "second", "large", "medium", "small", "fresh",
        "add", "use", "put", "mix", "stir", "cook", "heat",
    ]

    /// "3", "step 3", "#3" → 3. Nil for anything that isn't just a step number.
    static func stepNumber(_ text: String) -> Int? {
        let digits = text.lowercased()
            .replacingOccurrences(of: "step", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(digits)
    }
}
