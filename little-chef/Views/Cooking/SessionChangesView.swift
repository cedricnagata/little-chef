//
//  SessionChangesView.swift
//  little-chef
//
//  The last thing a cooking session shows: what it changed, and whether to keep it.
//

import SwiftUI

/// Shown when ending a cook that has unsaved recipe work.
///
/// The assistant edits the session's copy of the recipe freely — that is what makes it safe to
/// let it act on "actually I used two lemons" without asking first. The price of that freedom is
/// paid here, once, on the way out: nothing it did reaches the store until the user has seen it
/// written down and said yes.
struct SessionChangesView: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var recipeManager: RecipeManager
    @Environment(\.dismiss) private var dismiss

    /// Ends the cook. Called for both answers — keeping the changes and throwing them away are
    /// both decisions, and neither leaves the user back in a session they were trying to leave.
    let onEnd: () -> Void

    @State private var title: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(initialTitle: String, onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
        _title = State(initialValue: initialTitle)
    }

    private var isBuildingNewRecipe: Bool {
        cookingSessionManager.currentSession?.isBuildingNewRecipe ?? false
    }

    private var recipe: RecipeBase? { cookingSessionManager.currentSession?.recipe }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard !isSaving else { return false }
        return isBuildingNewRecipe ? !trimmedTitle.isEmpty : true
    }

    var body: some View {
        NavigationStack {
            Form {
                if isBuildingNewRecipe {
                    nameSection
                    newRecipeSections
                } else {
                    changesSection
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.callout)
                    }
                }

                actionsSection
            }
            .navigationTitle(isBuildingNewRecipe ? "Save This Recipe?" : "Save Your Changes?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Keep Cooking") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Writing a new recipe down

    private var nameSection: some View {
        Section {
            TextField("What was it?", text: $title)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Name")
        } footer: {
            Text("You cooked this without a recipe. Give it a name and it will be saved to your recipes.")
        }
    }

    @ViewBuilder
    private var newRecipeSections: some View {
        if let recipe {
            if !recipe.ingredients.isEmpty {
                Section("Ingredients") {
                    ForEach(recipe.ingredients, id: \.self) { ingredient in
                        Text(ingredient).font(.callout)
                    }
                }
            }
            if !recipe.instructions.isEmpty {
                Section("Method") {
                    ForEach(Array(recipe.instructions.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).")
                                .font(.callout)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                            Text(step).font(.callout)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Changes to an existing recipe

    private var changesSection: some View {
        let changes = cookingSessionManager.recipeChanges
        return Section {
            ForEach(changes) { change in
                RecipeChangeRow(change: change)
            }
        } header: {
            Text(changes.count == 1 ? "1 change" : "\(changes.count) changes")
        } footer: {
            Text("Saving updates \(recipe?.displayTitle ?? "this recipe") in your recipes, on this device and every other one signed in to your iCloud account.")
        }
    }

    // MARK: - Deciding

    private var actionsSection: some View {
        Section {
            Button {
                Task { await save() }
            } label: {
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(isBuildingNewRecipe ? "Save Recipe and End" : "Save Changes and End")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(!canSave)

            Button(role: .destructive) {
                end()
            } label: {
                HStack {
                    Spacer()
                    Text("Discard and End")
                    Spacer()
                }
            }
            .disabled(isSaving)
        } footer: {
            Text(isBuildingNewRecipe
                 ? "Discarding ends the cook without keeping anything you wrote down."
                 : "Discarding ends the cook and leaves the saved recipe exactly as it was.")
        }
    }

    private func end() {
        dismiss()
        onEnd()
    }

    private func save() async {
        guard let recipeData = cookingSessionManager.recipeDataForSaving(titled: trimmedTitle) else {
            end()
            return
        }

        isSaving = true
        saveError = nil
        let saved = await recipeManager.saveSessionRecipe(
            recipeData,
            replacing: cookingSessionManager.currentSession?.sourceRecipeID
        )
        isSaving = false

        guard saved else {
            // Deliberately does not end the session. The changes only exist inside it, so tearing
            // it down on a failed write is the one way to actually lose them.
            saveError = recipeManager.errorMessage ?? "Couldn't save the recipe. Your changes are still here — try again."
            return
        }
        end()
    }
}

// MARK: - One change

private struct RecipeChangeRow: View {
    let change: RecipeChange

    private var tint: Color {
        switch change.kind {
        case .added: return .green
        case .removed: return .red
        case .changed: return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: change.kind.symbolName)
                .foregroundColor(tint)
                .font(.callout)

            VStack(alignment: .leading, spacing: 3) {
                Text(change.field)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Both lines for a rewrite, one for anything else. Seeing what a line used to say
                // is most of what makes a change reviewable — "2 cloves garlic" becoming "4
                // cloves garlic" is approved on the strength of the pair, not the new line alone.
                if let before = change.before {
                    Text(before)
                        .font(.callout)
                        .strikethrough()
                        .foregroundColor(.secondary)
                }
                if let after = change.after {
                    Text(after)
                        .font(.callout)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
