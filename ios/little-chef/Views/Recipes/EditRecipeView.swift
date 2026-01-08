//
//  EditRecipeView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct EditRecipeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editMode) private var editMode
    @FocusState private var isInputFocused: Bool

    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @EnvironmentObject var preferencesManager: PreferencesManager

    let originalRecipe: RecipeData
    let onSave: (RecipeCreate) -> Void

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

    // AI Edit state
    @State private var showAIEditor = false
    @State private var isProcessingAIEdit = false
    @State private var aiEditError: String?
    @State private var pendingEditResponse: RecipeEditResponse?
    @State private var showModificationReview = false
    
    init(recipe: RecipeData, onSave: @escaping (RecipeCreate) -> Void) {
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
            Form {
                // Basic Information
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
                
                // Timing
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
                
                // Ingredients
                Section {
                    ForEach(Array(ingredients.enumerated()), id: \.offset) { index, ingredient in
                        HStack {
                            TextField("Ingredient", text: Binding(
                                get: { ingredients[index] },
                                set: { ingredients[index] = $0 }
                            ))
                            
                            if editMode?.wrappedValue.isEditing == true {
                                Button(action: {
                                    ingredients.remove(at: index)
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .onMove(perform: moveIngredients)
                    .onDelete(perform: deleteIngredients)
                    
                    HStack {
                        TextField("Add ingredient...", text: $newIngredient)
                            .onSubmit {
                                addIngredient()
                            }
                        
                        Button(action: addIngredient) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                        }
                        .disabled(newIngredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Ingredients (\(ingredients.count))")
                }
                
                // Instructions
                Section {
                    ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .top) {
                            Text("\(index + 1).")
                                .foregroundColor(.secondary)
                                .frame(width: 20, alignment: .leading)
                            
                            TextField("Instruction", text: Binding(
                                get: { instructions[index] },
                                set: { instructions[index] = $0 }
                            ), axis: .vertical)
                            .lineLimit(2...5)
                            
                            if editMode?.wrappedValue.isEditing == true {
                                Button(action: {
                                    instructions.remove(at: index)
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .onMove(perform: moveInstructions)
                    .onDelete(perform: deleteInstructions)
                    
                    HStack(alignment: .top) {
                        Text("\(instructions.count + 1).")
                            .foregroundColor(.secondary)
                            .frame(width: 20, alignment: .leading)
                        
                        TextField("Add instruction...", text: $newInstruction, axis: .vertical)
                            .lineLimit(2...5)
                            .onSubmit {
                                addInstruction()
                            }
                        
                        Button(action: addInstruction) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                        }
                        .disabled(newInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Instructions (\(instructions.count))")
                }
                
                // Additional Information
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
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        dismiss()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text("Cancel")
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: {
                            showAIEditor = true
                        }) {
                            Image(systemName: "wand.and.stars")
                        }

                        EditButton()

                        Button("Save") {
                            saveRecipe()
                        }
                        .disabled(!isValid)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showAIEditor) {
            AIEditSheet(
                currentRecipe: currentRecipeBase,
                onSubmit: { instructions in
                    processAIEdit(instructions: instructions)
                }
            )
            .environmentObject(voiceAssistant)
        }
        .fullScreenCover(isPresented: $showModificationReview) {
            if let response = pendingEditResponse {
                let reviewState = ModificationReviewState(
                    original: currentRecipeBase,
                    target: response.modifiedRecipe
                )
                InlineModificationReview(
                    reviewState: reviewState,
                    onComplete: { finalRecipe in
                        applyFinalRecipe(finalRecipe)
                        showModificationReview = false
                        pendingEditResponse = nil
                    },
                    onCancel: {
                        showModificationReview = false
                        pendingEditResponse = nil
                    }
                )
            }
        }
        .alert("AI Edit Error", isPresented: Binding<Bool>(
            get: { aiEditError != nil },
            set: { if !$0 { aiEditError = nil } }
        )) {
            Button("OK") {
                aiEditError = nil
            }
        } message: {
            if let error = aiEditError {
                Text(error)
            }
        }
        .overlay {
            if isProcessingAIEdit {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Generating AI suggestions...")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .padding(32)
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                }
            }
        }
    }
    
    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !ingredients.isEmpty &&
        !instructions.isEmpty &&
        servings > 0
    }

    private var currentRecipeBase: RecipeBase {
        RecipeBase(
            title: title,
            description: description.isEmpty ? nil : description,
            servings: servings,
            prepTime: Int(prepTime),
            cookTime: Int(cookTime),
            ingredients: ingredients,
            instructions: instructions,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            sourceUrl: sourceUrl.isEmpty ? nil : sourceUrl,
            cuisineType: cuisineType.isEmpty ? nil : cuisineType,
            difficulty: difficulty.isEmpty ? nil : difficulty
        )
    }
    
    private func addIngredient() {
        let trimmed = newIngredient.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            ingredients.append(trimmed)
            newIngredient = ""
        }
    }
    
    private func deleteIngredients(offsets: IndexSet) {
        ingredients.remove(atOffsets: offsets)
    }
    
    private func moveIngredients(from source: IndexSet, to destination: Int) {
        ingredients.move(fromOffsets: source, toOffset: destination)
    }
    
    private func addInstruction() {
        let trimmed = newInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            instructions.append(trimmed)
            newInstruction = ""
        }
    }
    
    private func deleteInstructions(offsets: IndexSet) {
        instructions.remove(atOffsets: offsets)
    }
    
    private func moveInstructions(from source: IndexSet, to destination: Int) {
        instructions.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - AI Edit Methods

    private func processAIEdit(instructions editInstructions: String) {
        isProcessingAIEdit = true
        aiEditError = nil

        Task {
            do {
                let userPreferences = UserPreferencesDetailed(from: preferencesManager.preferences)

                let response = try await RecipeEditorService.shared.editRecipe(
                    recipe: currentRecipeBase,
                    instructions: editInstructions,
                    preferences: userPreferences
                )

                await MainActor.run {
                    isProcessingAIEdit = false

                    if response.modifications.isEmpty {
                        aiEditError = "No modifications were suggested. Please try rephrasing your request."
                        return
                    }

                    // Store response and show review
                    pendingEditResponse = response
                    showModificationReview = true
                }
            } catch let error as RecipeEditorError {
                await MainActor.run {
                    isProcessingAIEdit = false
                    aiEditError = error.localizedDescription
                }
            } catch {
                await MainActor.run {
                    isProcessingAIEdit = false
                    aiEditError = "Failed to process AI edit: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Apply Final Recipe (Cursor-Style)

    /// Apply the final recipe from Cursor-style incremental diff review
    private func applyFinalRecipe(_ recipe: RecipeBase) {
        title = recipe.title
        description = recipe.description ?? ""
        servings = recipe.servings
        prepTime = recipe.prepTime != nil ? "\(recipe.prepTime!)" : ""
        cookTime = recipe.cookTime != nil ? "\(recipe.cookTime!)" : ""
        ingredients = recipe.ingredients
        instructions = recipe.instructions
        tags = recipe.tags.joined(separator: ", ")
        cuisineType = recipe.cuisineType ?? ""
        difficulty = recipe.difficulty ?? ""
    }

    private func saveRecipe() {
        let cleanedIngredients = ingredients.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let cleanedInstructions = instructions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tagsList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        
        let recipe = RecipeCreate(
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
