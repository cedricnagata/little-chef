//
//  RecipeDetailView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct RecipeDetailView: View {
    let recipe: Recipe
    @State private var showingDeleteAlert = false
    @State private var isEditing = false
    @EnvironmentObject var recipeManager: RecipeManager
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.selectedTab) private var selectedTab

    // Editable state
    @State private var editTitle: String = ""
    @State private var editDescription: String = ""
    @State private var editServings: Int = 4
    @State private var editPrepTime: String = ""
    @State private var editCookTime: String = ""
    @State private var editIngredients: [String] = []
    @State private var editInstructions: [String] = []
    @State private var editTags: String = ""
    @State private var editSourceUrl: String = ""
    @State private var editCuisineType: String = ""
    @State private var editDifficulty: String = ""
    @State private var newIngredient: String = ""
    @State private var newInstruction: String = ""


    var body: some View {
        Group {
            if isEditing {
                editingContent
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        displayContent
                    }
                }
            }
        }
        .navigationTitle("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditing {
                    Button("Save") { saveEdit() }
                        .fontWeight(.semibold)
                        .disabled(!isEditValid)
                } else {
                    Menu {
                        Button(action: { startCookingSession() }) {
                            Label("Start Cooking", systemImage: "flame.fill")
                        }
                        Button(action: { startEditing() }) {
                            Label("Edit Recipe", systemImage: "pencil")
                        }
                        Button(role: .destructive, action: { showingDeleteAlert = true }) {
                            Label("Delete Recipe", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    let success = await recipeManager.deleteRecipe(recipe)
                    if success { dismiss() }
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(recipe.title)'? This action cannot be undone.")
        }
    }

    // MARK: - Display Content (read-only)

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                Text(recipe.title)
                    .font(.title)
                    .fontWeight(.bold)

                if let description = recipe.description {
                    Text(description)
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                    if let prepTime = recipe.prepTime {
                        InfoCard(title: "Prep Time", value: "\(prepTime) min", icon: "clock")
                    }
                    if let cookTime = recipe.cookTime {
                        InfoCard(title: "Cook Time", value: "\(cookTime) min", icon: "flame")
                    }
                    InfoCard(title: "Servings", value: "\(recipe.servings)", icon: "person.2")
                    if let difficulty = recipe.difficulty {
                        InfoCard(title: "Difficulty", value: difficulty.capitalized, icon: "star")
                    }
                }

                if !recipe.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recipe.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.15))
                                    .cornerRadius(12)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)

            Divider()

            // Ingredients
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Ingredients")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(recipe.ingredients.count) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, ingredient in
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(Color.orange.opacity(0.2))
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)
                            Text(ingredient)
                                .font(.body)
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal)

            Divider()

            // Instructions
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Instructions")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(recipe.instructions.count) steps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(recipe.instructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 24, height: 24)
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }
                            Text(instruction)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Source URL
            if let sourceUrl = recipe.sourceUrl, !sourceUrl.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Source")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let url = URL(string: sourceUrl) {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "link")
                                Text("View Original Recipe")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .foregroundColor(.orange)
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer(minLength: 20)
        }
    }

    // MARK: - Editing Content (inline, List-based for onMove support)

    private var editingContent: some View {
        List {
            // Basic Info
            Section("Basic Information") {
                TextField("Recipe Title", text: $editTitle)

                TextField("Description (optional)", text: $editDescription, axis: .vertical)
                    .lineLimit(2...4)

                HStack {
                    Text("Servings")
                    Spacer()
                    Button(action: { if editServings > 1 { editServings -= 1 } }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(editServings > 1 ? .orange : .gray)
                    }
                    .buttonStyle(.borderless)
                    Text("\(editServings)")
                        .frame(minWidth: 28)
                    Button(action: { if editServings < 99 { editServings += 1 } }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Text("Prep (min)")
                    Spacer()
                    TextField("15", text: $editPrepTime)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }

                HStack {
                    Text("Cook (min)")
                    Spacer()
                    TextField("30", text: $editCookTime)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }

                Picker("Difficulty", selection: $editDifficulty) {
                    Text("Not specified").tag("")
                    Text("Easy").tag("easy")
                    Text("Medium").tag("medium")
                    Text("Hard").tag("hard")
                }
            }

            // Ingredients
            Section(header: Text("Ingredients (\(editIngredients.count))")) {
                ForEach($editIngredients.indices, id: \.self) { index in
                    TextField("Ingredient", text: $editIngredients[index], axis: .vertical)
                        .lineLimit(1...)
                }
                .onMove { editIngredients.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { editIngredients.remove(atOffsets: $0) }

                HStack {
                    TextField("Add ingredient...", text: $newIngredient)
                        .onSubmit { addIngredient() }
                    Button(action: addIngredient) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(newIngredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .green)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newIngredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            // Instructions
            Section(header: Text("Instructions (\(editInstructions.count))")) {
                ForEach($editInstructions.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 22, height: 22)
                            Text("\(index + 1)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        .padding(.top, 2)
                        TextField("Instruction", text: $editInstructions[index], axis: .vertical)
                            .lineLimit(2...)
                    }
                }
                .onMove { editInstructions.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { editInstructions.remove(atOffsets: $0) }

                HStack(alignment: .top, spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 22, height: 22)
                        Text("\(editInstructions.count + 1)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                    TextField("Add instruction...", text: $newInstruction, axis: .vertical)
                        .lineLimit(2...)
                        .onSubmit { addInstruction() }
                    Button(action: addInstruction) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(newInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .green)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            // Additional Info
            Section("Additional Information") {
                TextField("Tags (comma separated)", text: $editTags)

                TextField("Source URL (optional)", text: $editSourceUrl)
                    .keyboardType(.URL)
                    .autocapitalization(.none)

                TextField("Cuisine Type (optional)", text: $editCuisineType)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Validation

    private var isEditValid: Bool {
        !editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !editIngredients.isEmpty &&
        !editInstructions.isEmpty &&
        editServings > 0
    }

    // MARK: - Actions

    private func startEditing() {
        editTitle = recipe.title
        editDescription = recipe.description ?? ""
        editServings = recipe.servings
        editPrepTime = recipe.prepTime.map { String($0) } ?? ""
        editCookTime = recipe.cookTime.map { String($0) } ?? ""
        editIngredients = recipe.ingredients
        editInstructions = recipe.instructions
        editTags = recipe.tags.joined(separator: ", ")
        editSourceUrl = recipe.sourceUrl ?? ""
        editCuisineType = recipe.cuisineType ?? ""
        editDifficulty = recipe.difficulty ?? ""
        newIngredient = ""
        newInstruction = ""
        withAnimation { isEditing = true }
    }

    private func saveEdit() {
        let cleanedIngredients = editIngredients.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let cleanedInstructions = editInstructions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tagsList = editTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let updatedRecipe = RecipeData(
            title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            description: editDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            servings: editServings,
            prepTime: Int(editPrepTime.trimmingCharacters(in: .whitespacesAndNewlines)),
            cookTime: Int(editCookTime.trimmingCharacters(in: .whitespacesAndNewlines)),
            ingredients: cleanedIngredients,
            instructions: cleanedInstructions,
            tags: tagsList,
            sourceUrl: editSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            cuisineType: editCuisineType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editCuisineType.trimmingCharacters(in: .whitespacesAndNewlines),
            difficulty: editDifficulty.isEmpty ? nil : editDifficulty
        )

        Task {
            await updateRecipe(updatedRecipe)
            withAnimation { isEditing = false }
        }
    }

    private func addIngredient() {
        let trimmed = newIngredient.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            editIngredients.append(trimmed)
            newIngredient = ""
        }
    }

    private func addInstruction() {
        let trimmed = newInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            editInstructions.append(trimmed)
            newInstruction = ""
        }
    }


    private func startCookingSession() {
        Task { await cookingSessionManager.startCookingSession(with: recipe) }
        dismiss()
        selectedTab.wrappedValue = 1
    }

    private func updateRecipe(_ updatedRecipe: RecipeData) async {
        let success = await recipeManager.updateRecipe(id: recipe.id, with: updatedRecipe)
        if !success {
            dprint("Failed to update recipe: \(recipeManager.errorMessage ?? "Unknown error")")
        }
    }
}

// MARK: - Info Card

struct InfoCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.orange)
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

