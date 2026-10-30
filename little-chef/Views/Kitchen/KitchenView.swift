//
//  KitchenView.swift
//  little-chef
//
//  The Kitchen tab: what's in, and what to buy.
//

import SwiftUI

struct KitchenView: View {
    @EnvironmentObject var kitchenManager: KitchenManager

    enum Pane: String, CaseIterable, Identifiable {
        case inventory = "Inventory"
        case shopping = "Shopping List"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .inventory

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $pane) {
                    ForEach(Pane.allCases) { pane in
                        if pane == .shopping, !kitchenManager.shoppingList.isEmpty {
                            Text("\(pane.rawValue) (\(kitchenManager.shoppingList.count))").tag(pane)
                        } else {
                            Text(pane.rawValue).tag(pane)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch pane {
                case .inventory: InventoryView()
                case .shopping: ShoppingListView()
                }
            }
            .navigationTitle("Kitchen")
            .alert("Error", isPresented: Binding(
                get: { kitchenManager.errorMessage != nil },
                set: { if !$0 { kitchenManager.errorMessage = nil } }
            )) {
                Button("OK") { kitchenManager.errorMessage = nil }
            } message: {
                Text(kitchenManager.errorMessage ?? "")
            }
        }
    }
}

// MARK: - Inventory

struct InventoryView: View {
    @EnvironmentObject var kitchenManager: KitchenManager
    @State private var newItem = ""
    @State private var searchText = ""
    @State private var editingNote: PantryItem?
    @State private var noteDraft = ""
    @FocusState private var addFieldFocused: Bool

    private func matches(_ item: PantryItem) -> Bool {
        searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText)
    }

    private var ingredients: [PantryItem] { kitchenManager.pantry.filter { !$0.isStaple && matches($0) } }
    private var staples: [PantryItem] { kitchenManager.pantry.filter { $0.isStaple && matches($0) } }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add an ingredient you have", text: $newItem)
                        .focused($addFieldFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    .tint(.orange)
                }
            }

            Section {
                if ingredients.isEmpty {
                    Text(searchText.isEmpty
                         ? "Nothing here yet. Add what's in your fridge and cupboards, and recipes will show what you can make."
                         : "No matches.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ForEach(ingredients) { item in
                    row(for: item)
                        .swipeActions(edge: .leading) {
                            Button("Staple") { kitchenManager.setStaple(item, isStaple: true) }
                                .tint(.blue)
                        }
                }
                .onDelete { offsets in kitchenManager.removeFromPantry(offsets.map { ingredients[$0] }) }
            } header: {
                Text("Ingredients")
            }

            Section {
                ForEach(staples) { item in
                    row(for: item)
                        .swipeActions(edge: .leading) {
                            Button("Not a staple") { kitchenManager.setStaple(item, isStaple: false) }
                                .tint(.gray)
                        }
                }
                .onDelete { offsets in kitchenManager.removeFromPantry(offsets.map { staples[$0] }) }
            } header: {
                Text("Staples")
            } footer: {
                Text("Staples count as always on hand. Swipe right on an ingredient to make it a staple, or left to remove it.")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search inventory")
        .alert("Note", isPresented: Binding(get: { editingNote != nil }, set: { if !$0 { editingNote = nil } })) {
            TextField("e.g. half a bag", text: $noteDraft)
            Button("Save") {
                if let item = editingNote { kitchenManager.setNote(item, note: noteDraft) }
                editingNote = nil
            }
            Button("Cancel", role: .cancel) { editingNote = nil }
        } message: {
            Text(editingNote?.name ?? "")
        }
    }

    private func row(for item: PantryItem) -> some View {
        Button {
            noteDraft = item.note ?? ""
            editingNote = item
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundColor(.primary)
                if let note = item.note {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func add() {
        kitchenManager.addToPantry(newItem)
        newItem = ""
        addFieldFocused = true
    }
}

// MARK: - Shopping list

struct ShoppingListView: View {
    @EnvironmentObject var kitchenManager: KitchenManager
    @State private var newItem = ""
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add to the list", text: $newItem)
                        .focused($addFieldFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    .tint(.orange)
                }
            }

            Section {
                if kitchenManager.shoppingList.isEmpty {
                    Text("Your list is empty. Add items here, or add a recipe's missing ingredients from the recipe.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ForEach(kitchenManager.shoppingList) { item in
                    Button {
                        kitchenManager.toggleChecked(item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(item.isChecked ? .orange : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .strikethrough(item.isChecked)
                                    .foregroundColor(item.isChecked ? .secondary : .primary)
                                if let recipe = item.recipeTitle {
                                    Text("For \(recipe)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .onDelete { offsets in kitchenManager.removeFromShoppingList(offsets.map { kitchenManager.shoppingList[$0] }) }
            } footer: {
                if !kitchenManager.shoppingList.isEmpty {
                    Text("Tick items off as you shop, then tap Done Shopping to move them into your inventory.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if kitchenManager.hasCheckedItems {
                Button {
                    kitchenManager.moveCheckedToPantry()
                } label: {
                    Label("Done Shopping", systemImage: "cart.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding()
            }
        }
    }

    private func add() {
        kitchenManager.addToShoppingList([newItem])
        newItem = ""
        addFieldFocused = true
    }
}
