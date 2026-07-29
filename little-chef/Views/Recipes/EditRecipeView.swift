//
//  EditRecipeView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct EditRecipeView: View {
    @Environment(\.dismiss) private var dismiss

    let originalRecipe: RecipeData
    let onSave: (RecipeData) -> Void

    @State private var title: String
    @State private var description: String
    @State private var servings: Int
    @State private var prepTime: String
    @State private var cookTime: String
    @State private var ingredients: [String]
    @State private var instructions: [String]
    @State private var tags: String
    @State private var sourceUrl: String
    @State private var cuisineType: String
    @State private var difficulty: String

    @State private var newIngredient = ""
    @State private var newInstruction = ""


    init(recipe: RecipeData, onSave: @escaping (RecipeData) -> Void) {
        self.originalRecipe = recipe
        self.onSave = onSave

        _title = State(initialValue: recipe.title)
        _description = State(initialValue: recipe.description ?? "")
        _servings = State(initialValue: recipe.servings)
        _prepTime = State(initialValue: recipe.prepTime?.description ?? "")
        _cookTime = State(initialValue: recipe.cookTime?.description ?? "")
        _ingredients = State(initialValue: recipe.ingredients)
        _instructions = State(initialValue: recipe.instructions)
        _tags = State(initialValue: recipe.tags.joined(separator: ", "))
        _sourceUrl = State(initialValue: recipe.sourceUrl ?? "")
        _cuisineType = State(initialValue: recipe.cuisineType ?? "")
        _difficulty = State(initialValue: recipe.difficulty ?? "")
    }

    var body: some View {
        NavigationView {
            formContent
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Form Content

    private var formContent: some View {
        Form {
            basicInfoSection
            timingSection
            ingredientsSection
            instructionsSection
            additionalInfoSection
        }
        .navigationTitle("Edit Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    EditButton()
                    Button("Save") { saveRecipe() }
                        .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        Section("Basic Information") {
            TextField("Recipe Title", text: $title)

            TextField("Description (optional)", text: $description, axis: .vertical)
                .lineLimit(2...4)

            HStack {
                Text("Servings")
                Spacer()
                TextField("Servings", value: $servings, format: .number)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
            }
        }
    }

    private var timingSection: some View {
        Section("Timing") {
            HStack {
                Text("Prep Time (minutes)")
                Spacer()
                TextField("15", text: $prepTime)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
            }

            HStack {
                Text("Cook Time (minutes)")
                Spacer()
                TextField("30", text: $cookTime)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
            }
        }
    }

    private var ingredientsSection: some View {
        Section {
            ForEach($ingredients.indices, id: \.self) { index in
                HStack(alignment: .top) {
                    TextField("Ingredient", text: $ingredients[index], axis: .vertical)
                        .lineLimit(1...)

                    Button(action: {
                        withAnimation { _ = ingredients.remove(at: index) }
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onMove { source, destination in
                ingredients.move(fromOffsets: source, toOffset: destination)
            }

            HStack {
                TextField("Add ingredient...", text: $newIngredient)
                    .onSubmit { addIngredient() }

                Button(action: addIngredient) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                }
                .buttonStyle(.borderless)
                .disabled(newIngredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Ingredients (\(ingredients.count))")
        }
    }

    private var instructionsSection: some View {
        Section {
            ForEach($instructions.indices, id: \.self) { index in
                HStack(alignment: .top) {
                    Text("\(index + 1).")
                        .foregroundColor(.secondary)
                        .frame(width: 20, alignment: .leading)
                        .padding(.top, 8)

                    TextField("Instruction", text: $instructions[index], axis: .vertical)
                        .lineLimit(2...)

                    Button(action: {
                        withAnimation { _ = instructions.remove(at: index) }
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onMove { source, destination in
                instructions.move(fromOffsets: source, toOffset: destination)
            }

            HStack(alignment: .top) {
                Text("\(instructions.count + 1).")
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .leading)
                    .padding(.top, 8)

                TextField("Add instruction...", text: $newInstruction, axis: .vertical)
                    .lineLimit(2...)
                    .onSubmit { addInstruction() }

                Button(action: addInstruction) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                }
                .buttonStyle(.borderless)
                .disabled(newInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Instructions (\(instructions.count))")
        }
    }

    private var additionalInfoSection: some View {
        Section("Additional Information") {
            TextField("Tags (comma separated)", text: $tags)

            TextField("Source URL (optional)", text: $sourceUrl)
                .keyboardType(.URL)
                .autocapitalization(.none)

            TextField("Cuisine Type (optional)", text: $cuisineType)

            Picker("Difficulty", selection: $difficulty) {
                Text("Not specified").tag("")
                Text("Easy").tag("easy")
                Text("Medium").tag("medium")
                Text("Hard").tag("hard")
            }
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !ingredients.isEmpty &&
        !instructions.isEmpty &&
        servings > 0
    }

    // MARK: - Actions

    private func addIngredient() {
        let trimmed = newIngredient.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            ingredients.append(trimmed)
            newIngredient = ""
        }
    }

    private func addInstruction() {
        let trimmed = newInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            instructions.append(trimmed)
            newInstruction = ""
        }
    }

    private func saveRecipe() {
        let cleanedIngredients = ingredients.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let cleanedInstructions = instructions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tagsList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let recipe = RecipeData(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description.trimmingCharacters(in: .whitespacesAndNewlines),
            servings: servings,
            prepTime: Int(prepTime.trimmingCharacters(in: .whitespacesAndNewlines)),
            cookTime: Int(cookTime.trimmingCharacters(in: .whitespacesAndNewlines)),
            ingredients: cleanedIngredients,
            instructions: cleanedInstructions,
            tags: tagsList,
            sourceUrl: sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            cuisineType: cuisineType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cuisineType.trimmingCharacters(in: .whitespacesAndNewlines),
            difficulty: difficulty.isEmpty ? nil : difficulty
        )

        onSave(recipe)
        dismiss()
    }
}

#Preview {
    EditRecipeView(
        recipe: RecipeData(
            title: "Chocolate Chip Cookies",
            description: "Classic homemade cookies",
            servings: 24,
            prepTime: 15,
            cookTime: 12,
            ingredients: [
                "2 cups all-purpose flour",
                "1 cup butter, softened",
                "3/4 cup brown sugar"
            ],
            instructions: [
                "Preheat oven to 375°F",
                "Mix dry ingredients",
                "Cream butter and sugar"
            ],
            tags: ["dessert", "cookies"],
            sourceUrl: nil,
            cuisineType: "American",
            difficulty: "easy"
        )
    ) { _ in }
}
