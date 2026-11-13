//
//  LeftoversView.swift
//  little-chef
//
//  After a cook: which of the inventory items it used are still in the kitchen.
//

import SwiftUI

/// Shown as a cook ends when the recipe drew on the inventory.
///
/// Without it the inventory only ever grew: a cook used up the last eggs and the recipes went on
/// saying you could make an omelette. Each item starts as still there, because most cooks use
/// some of a thing rather than all of it, so only what ran out needs a tap.
struct LeftoversView: View {
    @EnvironmentObject var kitchenManager: KitchenManager
    @Environment(\.dismiss) private var dismiss

    let items: [PantryItem]
    let recipeTitle: String
    /// Ends the cook. Called for Skip and Done alike.
    let onDone: () -> Void

    @State private var usedUp: Set<UUID> = []
    @State private var addToShoppingList = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(items) { item in
                        Toggle(item.name, isOn: Binding(
                            get: { !usedUp.contains(item.id) },
                            set: { stillHave in
                                if stillHave { usedUp.remove(item.id) } else { usedUp.insert(item.id) }
                            }
                        ))
                    }
                } header: {
                    Text("Still in your kitchen")
                } footer: {
                    Text("Turn off anything you used up, and it comes off your inventory.")
                }

                if !usedUp.isEmpty {
                    Section {
                        Toggle("Add used-up items to the shopping list", isOn: $addToShoppingList)
                    }
                }
            }
            .navigationTitle("What's Left?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { finish(applying: false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish(applying: true) }
                        .fontWeight(.semibold)
                }
            }
            // Swiping it away would end the cook without saying which answer that was.
            .interactiveDismissDisabled()
        }
    }

    private func finish(applying: Bool) {
        if applying {
            let gone = items.filter { usedUp.contains($0.id) }
            if !gone.isEmpty {
                kitchenManager.removeFromPantry(gone)
                if addToShoppingList {
                    kitchenManager.addToShoppingList(gone.map(\.name), recipeTitle: recipeTitle)
                }
            }
        }
        dismiss()
        onDone()
    }
}
