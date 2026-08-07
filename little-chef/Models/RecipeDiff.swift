//
//  RecipeDiff.swift
//  little-chef
//
//  What changed about a recipe during a cooking session.
//

import Foundation

// MARK: - One change

struct RecipeChange: Identifiable {
    enum Kind {
        case added, removed, changed

        var symbolName: String {
            switch self {
            case .added: return "plus.circle.fill"
            case .removed: return "minus.circle.fill"
            case .changed: return "pencil.circle.fill"
            }
        }
    }

    let id = UUID()
    /// Which part of the recipe moved — "Ingredient", "Step", "Servings".
    let field: String
    let kind: Kind
    let before: String?
    let after: String?
}

// MARK: - The diff

/// The difference between the recipe a cook started with and the one it ended with.
///
/// Computed from the two recipes rather than accumulated as the edits happen. A running log
/// would be longer than the truth: adding an ingredient and then removing it again is two log
/// entries and no change at all, and that is precisely the list the user is being asked to
/// approve. Recomputing also means an edit made through some path that forgot to log it can
/// still never be saved silently.
struct RecipeDiff {
    let changes: [RecipeChange]

    var isEmpty: Bool { changes.isEmpty }

    init(from baseline: RecipeBase, to current: RecipeBase) {
        var changes: [RecipeChange] = []

        changes += Self.scalarChange("Title", from: baseline.title, to: current.title)
        changes += Self.scalarChange("Description", from: baseline.description, to: current.description)
        changes += Self.scalarChange("Servings", from: String(baseline.servings), to: String(current.servings))
        changes += Self.scalarChange("Prep time", from: Self.minutes(baseline.prepTime), to: Self.minutes(current.prepTime))
        changes += Self.scalarChange("Cook time", from: Self.minutes(baseline.cookTime), to: Self.minutes(current.cookTime))
        changes += Self.scalarChange("Difficulty", from: baseline.difficulty, to: current.difficulty)
        changes += Self.scalarChange("Cuisine", from: baseline.cuisineType, to: current.cuisineType)
        // Nothing in a cooking session sets this today. It is diffed anyway so that every field
        // of `RecipeBase` is accounted for, which is what lets `hasPendingRecipeWork` take the
        // cheap `!=` shortcut and still agree with the list this produces.
        changes += Self.scalarChange("Source", from: baseline.sourceUrl, to: current.sourceUrl)
        changes += Self.listChanges("Ingredient", from: baseline.ingredients, to: current.ingredients)
        changes += Self.listChanges("Step", from: baseline.instructions, to: current.instructions)
        changes += Self.listChanges("Tag", from: baseline.tags, to: current.tags)

        self.changes = changes
    }

    // MARK: - Single-valued fields

    private static func minutes(_ value: Int?) -> String? {
        value.map { "\($0) min" }
    }

    private static func scalarChange(_ field: String, from before: String?, to after: String?) -> [RecipeChange] {
        let old = normalised(before)
        let new = normalised(after)
        guard old != new else { return [] }

        let kind: RecipeChange.Kind
        switch (old, new) {
        case (nil, _): kind = .added
        case (_, nil): kind = .removed
        default: kind = .changed
        }
        return [RecipeChange(field: field, kind: kind, before: old, after: new)]
    }

    private static func normalised(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Lists

    private enum LineEdit {
        case keep
        case removed(String)
        case inserted(String)
    }

    private static func listChanges(_ field: String, from before: [String], to after: [String]) -> [RecipeChange] {
        var changes: [RecipeChange] = []
        let edits = lineEdits(from: before, to: after)
        var index = 0

        while index < edits.count {
            // A removal immediately followed by an insertion is one line being rewritten, not two
            // separate edits. Reporting "removed: 2 cloves garlic" next to "added: 4 cloves
            // garlic" makes a one-word correction look like the recipe was gutted.
            var removed: [String] = []
            while index < edits.count, case .removed(let text) = edits[index] {
                removed.append(text)
                index += 1
            }
            var inserted: [String] = []
            while index < edits.count, case .inserted(let text) = edits[index] {
                inserted.append(text)
                index += 1
            }

            for offset in 0..<max(removed.count, inserted.count) {
                let old = offset < removed.count ? removed[offset] : nil
                let new = offset < inserted.count ? inserted[offset] : nil
                switch (old, new) {
                case let (old?, new?):
                    changes.append(RecipeChange(field: field, kind: .changed, before: old, after: new))
                case let (old?, nil):
                    changes.append(RecipeChange(field: field, kind: .removed, before: old, after: nil))
                case let (nil, new?):
                    changes.append(RecipeChange(field: field, kind: .added, before: nil, after: new))
                case (nil, nil):
                    break
                }
            }

            // Neither loop consumed anything, so this is a kept line. Nothing to report.
            if removed.isEmpty && inserted.isEmpty { index += 1 }
        }

        return changes
    }

    /// A longest-common-subsequence diff of two lists of lines.
    ///
    /// Worth the dynamic-programming table rather than comparing position by position: the
    /// assistant can insert a step in the middle, and a positional compare would report that as
    /// every step from there down having been rewritten — an accurate save prompt describing a
    /// change nobody made. Recipes run to tens of lines, so the quadratic table costs nothing.
    private static func lineEdits(from before: [String], to after: [String]) -> [LineEdit] {
        let beforeCount = before.count
        let afterCount = after.count

        // common[i][j] = length of the longest common subsequence of before[i...] and after[j...]
        var common = Array(
            repeating: Array(repeating: 0, count: afterCount + 1),
            count: beforeCount + 1
        )
        for i in stride(from: beforeCount - 1, through: 0, by: -1) {
            for j in stride(from: afterCount - 1, through: 0, by: -1) {
                common[i][j] = before[i] == after[j]
                    ? common[i + 1][j + 1] + 1
                    : max(common[i + 1][j], common[i][j + 1])
            }
        }

        var edits: [LineEdit] = []
        var i = 0
        var j = 0
        while i < beforeCount && j < afterCount {
            if before[i] == after[j] {
                edits.append(.keep)
                i += 1
                j += 1
            } else if common[i + 1][j] >= common[i][j + 1] {
                edits.append(.removed(before[i]))
                i += 1
            } else {
                edits.append(.inserted(after[j]))
                j += 1
            }
        }
        while i < beforeCount {
            edits.append(.removed(before[i]))
            i += 1
        }
        while j < afterCount {
            edits.append(.inserted(after[j]))
            j += 1
        }
        return edits
    }
}
