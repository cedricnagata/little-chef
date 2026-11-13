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

    /// The inventory by kind, in the catalog's section order, empty sections left out.
    private var sections: [(category: IngredientCategory, items: [PantryItem])] {
        let grouped = Dictionary(grouping: kitchenManager.pantry.filter(matches)) { IngredientCatalog.category(of: $0.name) }
        return IngredientCategory.allCases.compactMap { category in
            grouped[category].map { (category, $0) }
        }
    }

    /// Common ingredients matching what's being typed that the inventory doesn't have yet.
    private var suggestions: [String] {
        IngredientCatalog.suggestions(for: newItem, excluding: kitchenManager.inventoryNames)
    }

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
                ForEach(suggestions, id: \.self) { name in
                    Button {
                        add(name)
                    } label: {
                        HStack {
                            Label(name, systemImage: "plus")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(IngredientCatalog.category(of: name).rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } footer: {
                if !suggestions.isEmpty {
                    Text("Tap a suggestion to add it, or tap + to add what you typed.")
                }
            }

            if sections.isEmpty {
                Section {
                    Text(searchText.isEmpty
                         ? "Nothing here yet. Add what's in your fridge and cupboards, and recipes will show what you can make."
                         : "No matches.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            ForEach(sections, id: \.category) { section in
                Section(section.category.rawValue) {
                    ForEach(section.items) { item in
                        row(for: item)
                    }
                    .onDelete { offsets in kitchenManager.removeFromPantry(offsets.map { section.items[$0] }) }
                }
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
        add(newItem)
    }

    private func add(_ name: String) {
        kitchenManager.addToPantry(name)
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
