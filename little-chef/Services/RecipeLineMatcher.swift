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

        // Last resort: "the garlic" against "2 cloves of garlic, minced". Short words are
        // dropped so that "the" and "of" can't carry a match on their own.
        let words = needle
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 3 }
        guard !words.isEmpty else { return nil }

        let scored = lines.enumerated().map { index, line -> (index: Int, score: Int) in
            let haystack = line.lowercased()
            return (index, words.filter { haystack.contains($0) }.count)
        }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
        return best.index
    }

    /// "3", "step 3", "#3" → 3. Nil for anything that isn't just a step number.
    static func stepNumber(_ text: String) -> Int? {
        let digits = text.lowercased()
            .replacingOccurrences(of: "step", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(digits)
    }
}
