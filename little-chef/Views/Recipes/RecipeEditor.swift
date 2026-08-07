//
//  RecipeEditor.swift
//  little-chef
//
//  The one recipe editing form, shared by the import flow and the recipe detail screen.
//

import SwiftUI

// MARK: - Editable line

/// One line of a recipe list — an ingredient, a step, a tag — carrying its own identity.
///
/// Identity is the whole point. The lists used to be edited as `[String]` keyed by array index
/// (`ForEach($items.indices, id: \.self)`), which tells SwiftUI that row 2 *is* position 2. Move
/// a row, or insert one above it, and every row below keeps its old view state while its text
/// shifts underneath — text fields showing the neighbour's text, the cursor landing in the wrong
/// row, and the keyboard's focus following the index rather than the line it was editing. A
/// stable id per line makes reordering and mid-list insertion work at all.
struct RecipeLine: Identifiable, Equatable {
    let id: UUID
    var text: String

    init(id: UUID = UUID(), _ text: String = "") {
        self.id = id
        self.text = text
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension Array where Element == RecipeLine {
    init(lines: [String]) { self = lines.map { RecipeLine($0) } }

    /// The non-blank lines, trimmed — what gets saved.
    var savedText: [String] {
        compactMap {
            let trimmed = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

// MARK: - Draft

/// Everything about a recipe, in the form the editor works on.
///
/// Held apart from `RecipeData` so an edit in progress is never half-applied: the draft is
/// mutated freely — blank rows, mid-edit text, tags being retyped — and only converted back to a
/// `RecipeData` on save.
struct RecipeDraft {
    var title: String
    var description: String
    var servings: Int
    var prepTime: String
    var cookTime: String
    var ingredients: [RecipeLine]
    var instructions: [RecipeLine]
    var tags: [RecipeLine]
    var sourceUrl: String
    var cuisineType: String
    var difficulty: String

    init(from recipe: RecipeData) {
        title = recipe.title
        description = recipe.description ?? ""
        servings = max(1, recipe.servings)
        prepTime = recipe.prepTime.map(String.init) ?? ""
        cookTime = recipe.cookTime.map(String.init) ?? ""
        ingredients = [RecipeLine](lines: recipe.ingredients)
        instructions = [RecipeLine](lines: recipe.instructions)
        tags = [RecipeLine](lines: recipe.tags)
        sourceUrl = recipe.sourceUrl ?? ""
        cuisineType = recipe.cuisineType ?? ""
        difficulty = recipe.difficulty ?? ""
    }

    init(from recipe: Recipe) {
        self.init(from: RecipeData(
            title: recipe.title,
            description: recipe.description,
            servings: recipe.servings,
            prepTime: recipe.prepTime,
            cookTime: recipe.cookTime,
            ingredients: recipe.ingredients,
            instructions: recipe.instructions,
            tags: recipe.tags,
            sourceUrl: recipe.sourceUrl,
            cuisineType: recipe.cuisineType,
            difficulty: recipe.difficulty
        ))
    }

    /// Blank rows are dropped rather than rejected: inserting a row and changing your mind is
    /// an ordinary thing to do, and refusing to save until it is filled in or found again would
    /// be a puzzle in a long list.
    func toRecipeData() -> RecipeData {
        func optional(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return RecipeData(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: optional(description),
            servings: servings,
            prepTime: optional(prepTime).flatMap(Int.init),
            cookTime: optional(cookTime).flatMap(Int.init),
            ingredients: ingredients.savedText,
            instructions: instructions.savedText,
            tags: tags.savedText.map { $0.lowercased() },
            sourceUrl: optional(sourceUrl),
            cuisineType: optional(cuisineType),
            difficulty: difficulty.isEmpty ? nil : difficulty
        )
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !ingredients.savedText.isEmpty
            && !instructions.savedText.isEmpty
            && servings > 0
    }
}

// MARK: - Editor form

/// The recipe editing form: every field editable, every list reorderable, and rows insertable
/// anywhere in a list rather than only at the end.
///
/// A `List` rather than a `Form` because reordering needs `onMove`, and one view rather than two
/// because the import flow and the detail screen were drifting — tags were a comma-separated
/// string in both, neither could insert a step between two others, and only one of them could
/// reorder anything.
struct RecipeEditorForm: View {
    @Binding var draft: RecipeDraft

    /// Which row owns the keyboard. Tracked so a row inserted mid-list is focused the moment it
    /// appears — an empty row that has to be hunted for and tapped is barely an insertion.
    @FocusState private var focusedLine: UUID?

    /// Reordering and text editing want opposite things from a `List` row: edit mode puts a drag
    /// grip and a delete affordance on every row, which is what reordering needs and what gets
    /// in the way of putting a cursor in a sentence. So it is a mode, off by default, with the
    /// per-row insert/delete actions available in both.
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            basicsSection
            ingredientsSection
            instructionsSection
            tagsSection
            sourceSection
        }
        .environment(\.editMode, $editMode)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(editMode.isEditing ? "Done" : "Reorder") {
                    // Leaving the keyboard up over a list that is about to sprout drag handles
                    // is the state where nothing works: the grips are behind the keyboard.
                    dismissKeyboard()
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
    }

    // MARK: Basics

    private var basicsSection: some View {
        Section("Basics") {
            TextField("Recipe title", text: $draft.title)
                .font(.headline)

            TextField("Description", text: $draft.description, axis: .vertical)
                .lineLimit(2...6)

            Stepper("Servings: \(draft.servings)", value: $draft.servings, in: 1...99)

            HStack {
                Text("Prep (minutes)")
                Spacer()
                TextField("15", text: $draft.prepTime)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
            }

            HStack {
                Text("Cook (minutes)")
                Spacer()
                TextField("30", text: $draft.cookTime)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
            }

            Picker("Difficulty", selection: $draft.difficulty) {
                Text("Not specified").tag("")
                Text("Easy").tag("easy")
                Text("Medium").tag("medium")
                Text("Hard").tag("hard")
            }

            TextField("Cuisine (e.g. Italian)", text: $draft.cuisineType)
        }
    }

    // MARK: Lists

    private var ingredientsSection: some View {
        Section {
            editableList(
                lines: $draft.ingredients,
                placeholder: "Ingredient",
                addLabel: "Add ingredient"
            ) { _ in nil }
        } header: {
            listHeader("Ingredients", count: draft.ingredients.savedText.count)
        } footer: {
            Text("Swipe a row for insert and delete. Tap Reorder to drag rows into a new order.")
        }
    }

    private var instructionsSection: some View {
        Section {
            editableList(
                lines: $draft.instructions,
                placeholder: "Describe this step",
                addLabel: "Add step",
                multiline: true
            ) { index in "\(index + 1)" }
        } header: {
            listHeader("Instructions", count: draft.instructions.savedText.count)
        }
    }

    private var tagsSection: some View {
        Section {
            editableList(
                lines: $draft.tags,
                placeholder: "Tag",
                addLabel: "Add tag",
                autocapitalization: .never
            ) { _ in nil }
        } header: {
            listHeader("Tags", count: draft.tags.savedText.count)
        } footer: {
            // Tags used to be one comma-separated text field, which meant they could not be
            // reordered, individually removed, or edited without retyping the line.
            Text("One tag per row, saved in lower case.")
        }
    }

    private var sourceSection: some View {
        Section("Source") {
            TextField("https://example.com/recipe", text: $draft.sourceUrl)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func listHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .foregroundColor(.secondary)
        }
    }

    /// A reorderable, insertable, deletable list of text rows.
    ///
    /// - Parameter marker: optional leading label for a row at a given index — the step number,
    ///   which has to be computed from position rather than stored, so it stays correct after a
    ///   move or an insertion.
    @ViewBuilder
    private func editableList(
        lines: Binding<[RecipeLine]>,
        placeholder: String,
        addLabel: String,
        multiline: Bool = false,
        autocapitalization: TextInputAutocapitalization = .sentences,
        marker: @escaping (Int) -> String?
    ) -> some View {
        ForEach(Array(lines.wrappedValue.enumerated()), id: \.element.id) { index, line in
            HStack(alignment: .top, spacing: 8) {
                if let marker = marker(index) {
                    StepMarker(text: marker)
                }

                TextField(placeholder, text: binding(for: line.id, in: lines), axis: .vertical)
                    .lineLimit(multiline ? 2... : 1...)
                    .textInputAutocapitalization(autocapitalization)
                    .focused($focusedLine, equals: line.id)
            }
            // Both gestures, because they are found in different ways: a swipe is what a user
            // reaches for on a list row, a long press is what they reach for when the row is a
            // text field they are already editing.
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    insert(after: index, in: lines)
                } label: {
                    Label("Insert below", systemImage: "text.insert")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    delete(id: line.id, in: lines)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                Button {
                    insert(at: index, in: lines)
                } label: {
                    Label("Insert above", systemImage: "arrow.up.to.line")
                }
                Button {
                    insert(after: index, in: lines)
                } label: {
                    Label("Insert below", systemImage: "arrow.down.to.line")
                }
                Button {
                    duplicate(at: index, in: lines)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Divider()
                Button(role: .destructive) {
                    delete(id: line.id, in: lines)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .onMove { source, destination in
            lines.wrappedValue.move(fromOffsets: source, toOffset: destination)
        }
        .onDelete { offsets in
            lines.wrappedValue.remove(atOffsets: offsets)
        }

        Button {
            insert(at: lines.wrappedValue.count, in: lines)
        } label: {
            Label(addLabel, systemImage: "plus.circle.fill")
                .foregroundColor(.orange)
        }
    }

    /// A binding to one line *by identity*.
    ///
    /// Not `$lines[index]`: an index-based binding written to after the array has changed
    /// underneath it — a row deleted above, a move completing — writes the text into whatever
    /// now occupies that slot.
    private func binding(for id: UUID, in lines: Binding<[RecipeLine]>) -> Binding<String> {
        Binding(
            get: { lines.wrappedValue.first(where: { $0.id == id })?.text ?? "" },
            set: { newValue in
                guard let index = lines.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
                lines.wrappedValue[index].text = newValue
            }
        )
    }

    // MARK: Row operations

    private func insert(at index: Int, in lines: Binding<[RecipeLine]>) {
        let line = RecipeLine()
        withAnimation {
            lines.wrappedValue.insert(line, at: min(max(0, index), lines.wrappedValue.count))
        }
        // Reordering and typing are mutually exclusive; inserting a row is a request to type.
        editMode = .inactive
        // Next runloop: the row's text field doesn't exist yet in this update, and focus asked
        // for before it is rendered lands nowhere — leaving an empty row to be hunted for and
        // tapped, which is barely an insertion.
        DispatchQueue.main.async { focusedLine = line.id }
    }

    private func insert(after index: Int, in lines: Binding<[RecipeLine]>) {
        insert(at: index + 1, in: lines)
    }

    private func duplicate(at index: Int, in lines: Binding<[RecipeLine]>) {
        guard lines.wrappedValue.indices.contains(index) else { return }
        let copy = RecipeLine(lines.wrappedValue[index].text)
        withAnimation { lines.wrappedValue.insert(copy, at: index + 1) }
    }

    private func delete(id: UUID, in lines: Binding<[RecipeLine]>) {
        withAnimation { lines.wrappedValue.removeAll { $0.id == id } }
    }
}

// MARK: - Step marker

private struct StepMarker: View {
    let text: String

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.orange)
                .frame(width: 22, height: 22)
            Text(text)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
        .padding(.top, 2)
    }
}
