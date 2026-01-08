//
//  RecipeDiffService.swift
//  little-chef
//
//  Compares two recipes and generates a list of modifications (diff)
//

import Foundation

class RecipeDiffService {

    /// Compare two recipes and generate a list of modifications
    static func generateDiff(original: RecipeBase, modified: RecipeBase) -> [RecipeModification] {
        var modifications: [RecipeModification] = []

        // Compare title
        if original.title != modified.title {
            modifications.append(RecipeModification(
                id: UUID().uuidString,
                modificationType: .instructionModify, // Using as a proxy for title change
                field: "title",
                targetIndex: nil,
                oldValue: original.title,
                newValue: modified.title,
                rationale: "Title updated",
                confidence: 1.0,
                createdAt: Date()
            ))
        }

        // Compare servings
        if original.servings != modified.servings {
            modifications.append(RecipeModification(
                id: UUID().uuidString,
                modificationType: .servingsChange,
                field: "servings",
                targetIndex: nil,
                oldValue: "\(original.servings)",
                newValue: "\(modified.servings)",
                rationale: "Servings adjusted",
                confidence: 1.0,
                createdAt: Date()
            ))
        }

        // Compare ingredients using LCS-based diff
        let ingredientDiff = diffArrays(
            original: original.ingredients,
            modified: modified.ingredients
        )

        for diff in ingredientDiff {
            switch diff {
            case .add(let index, let value):
                modifications.append(RecipeModification(
                    id: UUID().uuidString,
                    modificationType: .ingredientAdd,
                    field: "ingredients",
                    targetIndex: index,
                    oldValue: nil,
                    newValue: value,
                    rationale: "Ingredient added",
                    confidence: 1.0,
                    createdAt: Date()
                ))
            case .remove(let index, let value):
                modifications.append(RecipeModification(
                    id: UUID().uuidString,
                    modificationType: .ingredientRemove,
                    field: "ingredients",
                    targetIndex: index,
                    oldValue: value,
                    newValue: nil,
                    rationale: "Ingredient removed",
                    confidence: 1.0,
                    createdAt: Date()
                ))
            case .modify(let index, let oldValue, let newValue):
                // Determine if it's a substitution or quantity change
                let modificationType: ModificationType = {
                    // Simple heuristic: if words overlap significantly, it's quantity change
                    let oldWords = Set(oldValue.lowercased().split(separator: " "))
                    let newWords = Set(newValue.lowercased().split(separator: " "))
                    let overlap = oldWords.intersection(newWords).count
                    return overlap >= 2 ? .ingredientQuantity : .ingredientSubstitute
                }()

                modifications.append(RecipeModification(
                    id: UUID().uuidString,
                    modificationType: modificationType,
                    field: "ingredients",
                    targetIndex: index,
                    oldValue: oldValue,
                    newValue: newValue,
                    rationale: modificationType == .ingredientQuantity ? "Quantity adjusted" : "Ingredient substituted",
                    confidence: 1.0,
                    createdAt: Date()
                ))
            }
        }

        // Compare instructions using LCS-based diff
        let instructionDiff = diffArrays(
            original: original.instructions,
            modified: modified.instructions
        )

        for diff in instructionDiff {
            switch diff {
            case .add(let index, let value):
                modifications.append(RecipeModification(
                    id: UUID().uuidString,
                    modificationType: .instructionAdd,
                    field: "instructions",
                    targetIndex: index,
                    oldValue: nil,
                    newValue: value,
                    rationale: "Instruction step added",
                    confidence: 1.0,
                    createdAt: Date()
                ))
            case .remove(let index, let value):
                modifications.append(RecipeModification(
                    id: UUID().uuidString,
                    modificationType: .instructionRemove,
                    field: "instructions",
                    targetIndex: index,
                    oldValue: value,
                    newValue: nil,
                    rationale: "Instruction step removed",
                    confidence: 1.0,
                    createdAt: Date()
                ))
            case .modify(let index, let oldValue, let newValue):
                modifications.append(RecipeModification(
                    id: UUID().uuidString,
                    modificationType: .instructionModify,
                    field: "instructions",
                    targetIndex: index,
                    oldValue: oldValue,
                    newValue: newValue,
                    rationale: "Instruction step modified",
                    confidence: 1.0,
                    createdAt: Date()
                ))
            }
        }

        return modifications
    }

    /// Diff two arrays using position-based algorithm
    /// - Compares items at the same index
    /// - If lengths differ, treats extra items as adds/removes
    private static func diffArrays(original: [String], modified: [String]) -> [ArrayDiff] {
        var diffs: [ArrayDiff] = []

        let minCount = min(original.count, modified.count)

        // Compare items at same positions
        for i in 0..<minCount {
            if original[i] != modified[i] {
                diffs.append(.modify(i, original[i], modified[i]))
            }
        }

        // Handle length differences
        if modified.count > original.count {
            // New items added at the end
            for i in original.count..<modified.count {
                diffs.append(.add(i, modified[i]))
            }
        } else if original.count > modified.count {
            // Items removed from the end
            for i in modified.count..<original.count {
                diffs.append(.remove(i, original[i]))
            }
        }

        return diffs
    }

}

/// Represents a change in an array
private enum ArrayDiff {
    case add(Int, String)           // index in modified, value
    case remove(Int, String)        // index in original, value
    case modify(Int, String, String) // index, old value, new value
}
