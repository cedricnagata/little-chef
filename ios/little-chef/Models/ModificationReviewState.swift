//
//  ModificationReviewState.swift
//  little-chef
//
//  Dual-recipe incremental diff state management
//  Accept = apply to oldRecipe, Reject = reverse-apply to newRecipe
//

import Foundation
import Observation

/// Action types for undo history
enum DiffAction {
    case accept(modification: RecipeModification, previousOldRecipe: RecipeBase)
    case reject(modification: RecipeModification, previousNewRecipe: RecipeBase)
    case acceptAll(previousOldRecipe: RecipeBase)
    case rejectAll(previousNewRecipe: RecipeBase)
}

/// State for dual-recipe incremental diff review
/// - oldRecipe: Starts as original, evolves as changes are accepted
/// - newRecipe: Starts as LLM target, evolves as changes are rejected
/// - Diff is always between oldRecipe and newRecipe
/// - Accept All = use newRecipe, Reject All = use oldRecipe
@Observable
class ModificationReviewState {
    // Immutable reference points
    let originalRecipe: RecipeBase
    let targetRecipe: RecipeBase

    // Evolving recipes - both converge as changes are reviewed
    var oldRecipe: RecipeBase      // Accepts move this toward newRecipe
    var newRecipe: RecipeBase      // Rejects move this toward oldRecipe
    var currentDiff: [RecipeModification]
    var actionHistory: [DiffAction]

    /// The recipe shown in the preview (oldRecipe with accepted changes)
    var workingRecipe: RecipeBase { oldRecipe }

    init(original: RecipeBase, target: RecipeBase) {
        self.originalRecipe = original
        self.targetRecipe = target
        self.oldRecipe = original    // Start with original
        self.newRecipe = target      // Start with LLM's result
        self.actionHistory = []

        // Generate initial diff from original to target
        self.currentDiff = RecipeDiffService.generateDiff(original: original, modified: target)
    }

    // MARK: - Public Actions

    /// Accept a single change - apply it to oldRecipe (old moves toward new)
    func acceptChange(_ modification: RecipeModification) {
        // Save current oldRecipe for undo
        let snapshot = oldRecipe

        // Apply modification to oldRecipe
        oldRecipe = applyModification(modification, to: oldRecipe)

        // Record action for undo
        actionHistory.append(.accept(modification: modification, previousOldRecipe: snapshot))

        // Regenerate diff between updated oldRecipe and newRecipe
        regenerateDiff()
    }

    /// Reject a single change - apply REVERSE to newRecipe (new moves toward old)
    func rejectChange(_ modification: RecipeModification) {
        // Save current newRecipe for undo
        let snapshot = newRecipe

        // Apply REVERSE modification to newRecipe
        newRecipe = applyReverseModification(modification, to: newRecipe)

        // Record action for undo
        actionHistory.append(.reject(modification: modification, previousNewRecipe: snapshot))

        // Regenerate diff between oldRecipe and updated newRecipe
        regenerateDiff()
    }

    /// Undo the last action
    func undo() {
        guard let lastAction = actionHistory.popLast() else { return }

        switch lastAction {
        case .accept(_, let previousOldRecipe):
            // Restore previous oldRecipe
            oldRecipe = previousOldRecipe

        case .reject(_, let previousNewRecipe):
            // Restore previous newRecipe
            newRecipe = previousNewRecipe

        case .acceptAll(let previousOldRecipe):
            // Restore previous oldRecipe
            oldRecipe = previousOldRecipe

        case .rejectAll(let previousNewRecipe):
            // Restore previous newRecipe
            newRecipe = previousNewRecipe
        }

        // Regenerate diff from restored state
        regenerateDiff()
    }

    /// Accept all current modifications - just use newRecipe
    func acceptAll() {
        guard !currentDiff.isEmpty else { return }

        // Save current oldRecipe for undo
        let snapshot = oldRecipe

        // Set oldRecipe to match newRecipe (all changes accepted)
        oldRecipe = newRecipe

        // Record as single action for undo
        actionHistory.append(.acceptAll(previousOldRecipe: snapshot))

        // Regenerate diff (should be empty now)
        regenerateDiff()
    }

    /// Reject all current modifications - just use oldRecipe
    func rejectAll() {
        guard !currentDiff.isEmpty else { return }

        // Save current newRecipe for undo
        let snapshot = newRecipe

        // Set newRecipe to match oldRecipe (all changes rejected)
        newRecipe = oldRecipe

        // Record as single action for undo
        actionHistory.append(.rejectAll(previousNewRecipe: snapshot))

        // Regenerate diff (should be empty now)
        regenerateDiff()
    }

    // MARK: - Private Helpers

    /// Regenerate diff from oldRecipe to newRecipe
    private func regenerateDiff() {
        currentDiff = RecipeDiffService.generateDiff(original: oldRecipe, modified: newRecipe)
    }

    /// Apply a single modification to a recipe (for accepts - moving old toward new)
    private func applyModification(_ mod: RecipeModification, to recipe: RecipeBase) -> RecipeBase {
        switch (mod.field, mod.modificationType) {
        case ("ingredients", .ingredientRemove):
            if let idx = mod.targetIndex, idx < recipe.ingredients.count {
                var newIngredients = recipe.ingredients
                newIngredients.remove(at: idx)
                return createRecipe(from: recipe, ingredients: newIngredients)
            }

        case ("ingredients", .ingredientAdd):
            if let newValue = mod.newValue {
                var newIngredients = recipe.ingredients
                if let idx = mod.targetIndex, idx <= newIngredients.count {
                    newIngredients.insert(newValue, at: idx)
                } else {
                    newIngredients.append(newValue)
                }
                return createRecipe(from: recipe, ingredients: newIngredients)
            }

        case ("ingredients", .ingredientSubstitute), ("ingredients", .ingredientQuantity):
            if let idx = mod.targetIndex, idx < recipe.ingredients.count, let newValue = mod.newValue {
                var newIngredients = recipe.ingredients
                newIngredients[idx] = newValue
                return createRecipe(from: recipe, ingredients: newIngredients)
            }

        case ("instructions", .instructionRemove):
            if let idx = mod.targetIndex, idx < recipe.instructions.count {
                var newInstructions = recipe.instructions
                newInstructions.remove(at: idx)
                return createRecipe(from: recipe, instructions: newInstructions)
            }

        case ("instructions", .instructionAdd):
            if let newValue = mod.newValue {
                var newInstructions = recipe.instructions
                if let idx = mod.targetIndex, idx <= newInstructions.count {
                    newInstructions.insert(newValue, at: idx)
                } else {
                    newInstructions.append(newValue)
                }
                return createRecipe(from: recipe, instructions: newInstructions)
            }

        case ("instructions", .instructionModify):
            if let idx = mod.targetIndex, idx < recipe.instructions.count, let newValue = mod.newValue {
                var newInstructions = recipe.instructions
                newInstructions[idx] = newValue
                return createRecipe(from: recipe, instructions: newInstructions)
            }

        case ("servings", .servingsChange):
            if let newValue = mod.newValue, let servings = Int(newValue) {
                return createRecipe(from: recipe, servings: servings)
            }

        case ("title", _):
            if let newValue = mod.newValue {
                return createRecipe(from: recipe, title: newValue)
            }

        case ("prepTime", _):
            if let newValue = mod.newValue, let time = Int(newValue) {
                return createRecipe(from: recipe, prepTime: time)
            }

        case ("cookTime", _):
            if let newValue = mod.newValue, let time = Int(newValue) {
                return createRecipe(from: recipe, cookTime: time)
            }

        default:
            break
        }

        return recipe
    }

    /// Apply the REVERSE of a modification to a recipe (for rejects - moving new toward old)
    /// - Add becomes Remove
    /// - Remove becomes Add
    /// - Substitute/Modify: swap old and new values
    private func applyReverseModification(_ mod: RecipeModification, to recipe: RecipeBase) -> RecipeBase {
        switch (mod.field, mod.modificationType) {
        // Reverse of Remove = Add (put the old value back)
        case ("ingredients", .ingredientRemove):
            if let oldValue = mod.oldValue {
                var newIngredients = recipe.ingredients
                if let idx = mod.targetIndex, idx <= newIngredients.count {
                    newIngredients.insert(oldValue, at: idx)
                } else {
                    newIngredients.append(oldValue)
                }
                return createRecipe(from: recipe, ingredients: newIngredients)
            }

        // Reverse of Add = Remove
        case ("ingredients", .ingredientAdd):
            if let idx = mod.targetIndex, idx < recipe.ingredients.count {
                var newIngredients = recipe.ingredients
                newIngredients.remove(at: idx)
                return createRecipe(from: recipe, ingredients: newIngredients)
            } else if mod.newValue != nil {
                // If no target index, try to find and remove the added value
                var newIngredients = recipe.ingredients
                if let addedValue = mod.newValue,
                   let foundIdx = newIngredients.lastIndex(of: addedValue) {
                    newIngredients.remove(at: foundIdx)
                    return createRecipe(from: recipe, ingredients: newIngredients)
                }
            }

        // Reverse of Substitute/Quantity = swap old and new
        case ("ingredients", .ingredientSubstitute), ("ingredients", .ingredientQuantity):
            if let idx = mod.targetIndex, idx < recipe.ingredients.count, let oldValue = mod.oldValue {
                var newIngredients = recipe.ingredients
                newIngredients[idx] = oldValue
                return createRecipe(from: recipe, ingredients: newIngredients)
            }

        // Reverse of Remove = Add (put the old instruction back)
        case ("instructions", .instructionRemove):
            if let oldValue = mod.oldValue {
                var newInstructions = recipe.instructions
                if let idx = mod.targetIndex, idx <= newInstructions.count {
                    newInstructions.insert(oldValue, at: idx)
                } else {
                    newInstructions.append(oldValue)
                }
                return createRecipe(from: recipe, instructions: newInstructions)
            }

        // Reverse of Add = Remove
        case ("instructions", .instructionAdd):
            if let idx = mod.targetIndex, idx < recipe.instructions.count {
                var newInstructions = recipe.instructions
                newInstructions.remove(at: idx)
                return createRecipe(from: recipe, instructions: newInstructions)
            } else if mod.newValue != nil {
                var newInstructions = recipe.instructions
                if let addedValue = mod.newValue,
                   let foundIdx = newInstructions.lastIndex(of: addedValue) {
                    newInstructions.remove(at: foundIdx)
                    return createRecipe(from: recipe, instructions: newInstructions)
                }
            }

        // Reverse of Modify = swap old and new
        case ("instructions", .instructionModify):
            if let idx = mod.targetIndex, idx < recipe.instructions.count, let oldValue = mod.oldValue {
                var newInstructions = recipe.instructions
                newInstructions[idx] = oldValue
                return createRecipe(from: recipe, instructions: newInstructions)
            }

        // Reverse of servings change = use old value
        case ("servings", .servingsChange):
            if let oldValue = mod.oldValue, let servings = Int(oldValue) {
                return createRecipe(from: recipe, servings: servings)
            }

        // Reverse of title change = use old value
        case ("title", _):
            if let oldValue = mod.oldValue {
                return createRecipe(from: recipe, title: oldValue)
            }

        // Reverse of prepTime change = use old value
        case ("prepTime", _):
            if let oldValue = mod.oldValue, let time = Int(oldValue) {
                return createRecipe(from: recipe, prepTime: time)
            }

        // Reverse of cookTime change = use old value
        case ("cookTime", _):
            if let oldValue = mod.oldValue, let time = Int(oldValue) {
                return createRecipe(from: recipe, cookTime: time)
            }

        default:
            break
        }

        return recipe
    }

    // MARK: - Recipe Creation Helpers

    private func createRecipe(
        from recipe: RecipeBase,
        title: String? = nil,
        description: String?? = nil,
        servings: Int? = nil,
        prepTime: Int? = nil,
        cookTime: Int? = nil,
        ingredients: [String]? = nil,
        instructions: [String]? = nil
    ) -> RecipeBase {
        RecipeBase(
            title: title ?? recipe.title,
            description: description ?? recipe.description,
            servings: servings ?? recipe.servings,
            prepTime: prepTime ?? recipe.prepTime,
            cookTime: cookTime ?? recipe.cookTime,
            ingredients: ingredients ?? recipe.ingredients,
            instructions: instructions ?? recipe.instructions,
            tags: recipe.tags,
            sourceUrl: recipe.sourceUrl,
            cuisineType: recipe.cuisineType,
            difficulty: recipe.difficulty
        )
    }
}
