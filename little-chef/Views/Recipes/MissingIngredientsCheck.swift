//
//  MissingIngredientsCheck.swift
//  little-chef
//
//  The warning before a cook when the inventory says something is missing.
//

import SwiftUI

/// A start-cooking request that's waiting on the user, because the recipe needs things the
/// inventory doesn't have.
struct MissingIngredientsCheck: Identifiable {
    let recipe: Recipe
    let availability: RecipeAvailability
    var id: UUID { recipe.id }
}

extension KitchenManager {
    /// Whether the user has started keeping an inventory: at least one item beyond the seeded
    /// staples. Until then every recipe would be "missing" everything, and warning about that
    /// before each cook would only be noise.
    var isTrackingInventory: Bool { pantry.contains { !$0.isStaple } }

    /// The check to show before cooking `recipe`, or nil to go straight ahead.
    func checkBeforeCooking(_ recipe: Recipe) -> MissingIngredientsCheck? {
        guard isTrackingInventory else { return nil }
        let result = availability(of: recipe)
        return result.canMake ? nil : MissingIngredientsCheck(recipe: recipe, availability: result)
    }
}

private struct MissingIngredientsDialog: ViewModifier {
    @Binding var check: MissingIngredientsCheck?
    let onCook: (Recipe) -> Void
    @EnvironmentObject var kitchenManager: KitchenManager

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(get: { check != nil }, set: { if !$0 { check = nil } }),
            titleVisibility: .visible,
            presenting: check
        ) { check in
            Button("Cook Anyway") { onCook(check.recipe) }
            Button("Add to Shopping List") {
                kitchenManager.addToShoppingList(check.availability.missingNames, recipeTitle: check.recipe.title)
            }
            Button("Cancel", role: .cancel) {}
        } message: { check in
            Text(message(for: check.availability))
        }
    }

    private var title: String {
        let count = check?.availability.missing.count ?? 0
        return count == 1 ? "You're missing 1 ingredient" : "You're missing \(count) ingredients"
    }

    private func message(for availability: RecipeAvailability) -> String {
        let shown = availability.missing.prefix(6).joined(separator: "\n")
        let more = availability.missing.count - 6
        return more > 0 ? "\(shown)\nand \(more) more" : shown
    }
}

extension View {
    /// Shows the missing-ingredients warning while `check` is set; `onCook` runs on Cook Anyway.
    func missingIngredientsDialog(_ check: Binding<MissingIngredientsCheck?>, onCook: @escaping (Recipe) -> Void) -> some View {
        modifier(MissingIngredientsDialog(check: check, onCook: onCook))
    }
}
