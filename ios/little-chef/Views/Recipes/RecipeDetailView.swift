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
    @StateObject private var exportManager = RecipeExportManager()
    @State private var exportedFileURL: URL?
    @State private var exportErrorMessage: String?
    @EnvironmentObject var recipeManager: RecipeManager
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @EnvironmentObject var preferencesManager: PreferencesManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.selectedTab) private var selectedTab

    // Edit mode state
    @State private var isEditing = false
    @State private var editedTitle: String = ""
    @State private var editedDescription: String = ""
    @State private var editedServings: Int = 0
    @State private var editedPrepTime: String = ""
    @State private var editedCookTime: String = ""
    @State private var editedIngredients: [String] = []
    @State private var editedInstructions: [String] = []
    @State private var editedTags: String = ""
    @State private var editedSourceUrl: String = ""
    @State private var editedCuisineType: String = ""
    @State private var editedDifficulty: String = ""

    // AI Edit state
    @State private var showAIEditor = false
    @State private var isProcessingAIEdit = false
    @State private var aiEditError: String?
    @State private var pendingEditResponse: RecipeEditResponse?
    @State private var showModificationReview = false

    // Edit mode helpers
    @State private var newIngredient = ""
    @State private var newInstruction = ""

    var body: some View {
        contentWithModifiers
    }

    private var contentWithModifiers: some View {
        contentWithAlertsAndDialogs
            .sheet(isPresented: $showAIEditor) {
                aiEditorSheet
            }
            .fullScreenCover(isPresented: $showModificationReview) {
                modificationReviewFullScreen
            }
            .overlay {
                aiEditOverlay
            }
            .sheet(item: .init(
                get: { exportedFileURL.map { ShareSheetItem(url: $0) } },
                set: { exportedFileURL = $0?.url }
            )) { item in
                ShareSheet(items: [item.url])
            }
    }

    private var contentWithAlertsAndDialogs: some View {
        contentWithNavigation
            .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
                deleteAlert
            } message: {
                Text("Are you sure you want to delete '\(recipe.title)'? This action cannot be undone.")
            }
            .alert("AI Edit Error", isPresented: Binding<Bool>(
                get: { aiEditError != nil },
                set: { if !$0 { aiEditError = nil } }
            )) {
                aiErrorAlert
            } message: {
                aiErrorMessage
            }
            .alert("Export Error", isPresented: .init(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                exportErrorAlert
            } message: {
                exportErrorMessageText
            }
    }

    private var contentWithNavigation: some View {
        mainContent
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isEditing)
            .toolbar {
                toolbarContent
            }
    }

    @ViewBuilder
    private var deleteAlert: some View {
        Button("Delete", role: .destructive) {
            Task {
                await deleteRecipe()
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var aiEditorSheet: some View {
        AIEditSheet(
            currentRecipe: currentRecipeBase,
            onSubmit: { instructions in
                processAIEdit(instructions: instructions)
            }
        )
        .environmentObject(voiceAssistant)
    }

    @ViewBuilder
    private var aiErrorAlert: some View {
        Button("OK") {
            aiEditError = nil
        }
    }

    @ViewBuilder
    private var aiErrorMessage: some View {
        if let error = aiEditError {
            Text(error)
        }
    }

    @ViewBuilder
    private var exportErrorAlert: some View {
        Button("OK") {
            exportErrorMessage = nil
        }
    }

    @ViewBuilder
    private var exportErrorMessageText: some View {
        if let error = exportErrorMessage {
            Text(error)
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                // Header
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    if isEditing {
                        TextField("Recipe Title", text: $editedTitle)
                            .font(.title)
                            .fontWeight(.bold)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    } else {
                        Text(recipe.title)
                            .font(.title)
                            .fontWeight(.bold)
                    }

                    if isEditing {
                        TextEditor(text: $editedDescription)
                            .frame(minHeight: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                    } else if let description = recipe.description {
                        Text(description)
                            .font(.body)
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }

                    // Recipe info grid
                    if isEditing {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Prep Time (min)")
                                    .font(.caption)
                                Spacer()
                                TextField("15", text: $editedPrepTime)
                                    .keyboardType(.numberPad)
                                    .frame(width: 80)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }

                            HStack {
                                Text("Cook Time (min)")
                                    .font(.caption)
                                Spacer()
                                TextField("30", text: $editedCookTime)
                                    .keyboardType(.numberPad)
                                    .frame(width: 80)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }

                            HStack {
                                Text("Servings")
                                    .font(.caption)
                                Spacer()
                                Stepper("\(editedServings)", value: $editedServings, in: 1...100)
                            }

                            HStack {
                                Text("Difficulty")
                                    .font(.caption)
                                Spacer()
                                Picker("", selection: $editedDifficulty) {
                                    Text("Not specified").tag("")
                                    Text("Easy").tag("easy")
                                    Text("Medium").tag("medium")
                                    Text("Hard").tag("hard")
                                }
                                .pickerStyle(.menu)
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: DesignSystem.Spacing.md) {
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
                    }
                    
                    // Tags
                    if isEditing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tags (comma separated)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("dessert, cookies, chocolate", text: $editedTags)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                        }
                    } else if !recipe.tags.isEmpty {
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
                            .padding(.horizontal)
                        }
                        .padding(.horizontal, -16)
                    }
                }
                .padding(.horizontal)
                
                Divider()
                
                // Ingredients
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack {
                        Text("Ingredients")
                            .sectionHeader()
                            .font(.title2)

                        Spacer()

                        Text(isEditing ? "\(editedIngredients.count) items" : "\(recipe.ingredients.count) items")
                            .captionText()
                    }

                    if isEditing {
                        List {
                            ForEach(editedIngredients.indices, id: \.self) { index in
                                TextField("Ingredient", text: Binding(
                                    get: { editedIngredients[index] },
                                    set: { editedIngredients[index] = $0 }
                                ))
                                .textFieldStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
                            }
                            .onMove(perform: moveIngredients)
                            .onDelete(perform: deleteIngredients)

                            HStack {
                                TextField("Add ingredient...", text: $newIngredient)
                                    .textFieldStyle(.plain)
                                    .onSubmit {
                                        addIngredient()
                                    }

                                Button(action: addIngredient) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.green)
                                }
                                .disabled(newIngredient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        }
                        .listStyle(.plain)
                        .frame(height: CGFloat(editedIngredients.count + 1) * 44)
                        .environment(\.editMode, .constant(.active))
                    } else {
                        LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                            ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { index, ingredient in
                                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                                    Circle()
                                        .fill(DesignSystem.Colors.primaryMedium)
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 6)

                                    Text(ingredient)
                                        .bodyText()

                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                
                Divider()
                
                // Instructions
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack {
                        Text("Instructions")
                            .sectionHeader()
                            .font(.title2)

                        Spacer()

                        Text(isEditing ? "\(editedInstructions.count) steps" : "\(recipe.instructions.count) steps")
                            .captionText()
                    }

                    if isEditing {
                        List {
                            ForEach(editedInstructions.indices, id: \.self) { index in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(index + 1).")
                                        .foregroundColor(.secondary)
                                        .frame(width: 30, alignment: .leading)

                                    TextField("Instruction", text: Binding(
                                        get: { editedInstructions[index] },
                                        set: { editedInstructions[index] = $0 }
                                    ), axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .lineLimit(2...5)
                                }
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
                            }
                            .onMove(perform: moveInstructions)
                            .onDelete(perform: deleteInstructions)

                            HStack(alignment: .top) {
                                Text("\(editedInstructions.count + 1).")
                                    .foregroundColor(.secondary)
                                    .frame(width: 30, alignment: .leading)

                                TextField("Add instruction...", text: $newInstruction, axis: .vertical)
                                    .textFieldStyle(.plain)
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
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        }
                        .listStyle(.plain)
                        .frame(height: CGFloat(editedInstructions.count + 1) * 60)
                        .environment(\.editMode, .constant(.active))
                    } else {
                        LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                            ForEach(Array(recipe.instructions.enumerated()), id: \.offset) { index, instruction in
                                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                                    ZStack {
                                        Circle()
                                            .fill(DesignSystem.Colors.primary)
                                            .frame(width: 24, height: 24)

                                        Text("\(index + 1)")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                    }

                                    Text(instruction)
                                        .bodyText()
                                        .fixedSize(horizontal: false, vertical: true)

                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                
                // Source URL (if available)
                if let sourceUrl = recipe.sourceUrl, !sourceUrl.isEmpty {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Link(destination: URL(string: sourceUrl) ?? URL(string: "https://example.com")!) {
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
                    .padding(.horizontal)
                }
                
                Spacer(minLength: 20)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if isEditing {
                Button("Cancel") {
                    cancelEditing()
                }
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            if isEditing {
                HStack(spacing: 12) {
                    Button(action: {
                        showAIEditor = true
                    }) {
                        Image(systemName: "wand.and.stars")
                    }

                    Menu {
                        Button("Overwrite Existing Recipe") {
                            Task { await saveChanges(asNewRecipe: false) }
                        }
                        Button("Save as New Recipe") {
                            Task { await saveChanges(asNewRecipe: true) }
                        }
                    } label: {
                        Text("Save")
                            .fontWeight(.semibold)
                    }
                }
            } else {
                Menu {
                    Button(action: {
                        Task {
                            await shareRecipe()
                        }
                    }) {
                        Label("Share Recipe", systemImage: "square.and.arrow.up")
                    }

                    Button(action: {
                        startCookingSession()
                    }) {
                        Label("Start Cooking", systemImage: "flame")
                    }

                    Divider()

                    Button(action: {
                        enterEditMode()
                    }) {
                        Label("Edit Recipe", systemImage: "pencil")
                    }

                    Button(role: .destructive, action: {
                        showingDeleteAlert = true
                    }) {
                        Label("Delete Recipe", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var modificationReviewFullScreen: some View {
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

    @ViewBuilder
    private var aiEditOverlay: some View {
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

    private func deleteRecipe() async {
        await recipeManager.deleteRecipe(recipe)
    }

    private func startCookingSession() {
        // Start the cooking session with this recipe
        cookingSessionManager.startCookingSession(with: recipe)
        
        // Dismiss the current view
        dismiss()
        
        // Switch to the Cook tab (tab index 1)
        selectedTab.wrappedValue = 1
    }
    
    private func shareRecipe() async {
        do {
            let fileURL = try exportManager.exportRecipe(recipe)
            exportedFileURL = fileURL
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func updateRecipe(_ updatedRecipe: RecipeCreate) async {
        // Convert RecipeCreate to RecipeBase
        let recipeBase = RecipeBase(
            title: updatedRecipe.title,
            description: updatedRecipe.description,
            servings: updatedRecipe.servings,
            prepTime: updatedRecipe.prepTime,
            cookTime: updatedRecipe.cookTime,
            ingredients: updatedRecipe.ingredients,
            instructions: updatedRecipe.instructions,
            tags: updatedRecipe.tags,
            sourceUrl: updatedRecipe.sourceUrl,
            cuisineType: updatedRecipe.cuisineType,
            difficulty: updatedRecipe.difficulty
        )

        await recipeManager.updateRecipe(id: recipe.id, with: recipeBase)
    }

    // MARK: - Edit Mode Methods

    private func enterEditMode() {
        editedTitle = recipe.title
        editedDescription = recipe.description ?? ""
        editedServings = recipe.servings
        editedPrepTime = recipe.prepTime.map { "\($0)" } ?? ""
        editedCookTime = recipe.cookTime.map { "\($0)" } ?? ""
        editedIngredients = recipe.ingredients
        editedInstructions = recipe.instructions
        editedTags = recipe.tags.joined(separator: ", ")
        editedSourceUrl = recipe.sourceUrl ?? ""
        editedCuisineType = recipe.cuisineType ?? ""
        editedDifficulty = recipe.difficulty ?? ""
        newIngredient = ""
        newInstruction = ""
        isEditing = true
    }

    private func addIngredient() {
        let trimmed = newIngredient.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            editedIngredients.append(trimmed)
            newIngredient = ""
        }
    }

    private func moveIngredients(from source: IndexSet, to destination: Int) {
        editedIngredients.move(fromOffsets: source, toOffset: destination)
    }

    private func deleteIngredients(at offsets: IndexSet) {
        editedIngredients.remove(atOffsets: offsets)
    }

    private func addInstruction() {
        let trimmed = newInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            editedInstructions.append(trimmed)
            newInstruction = ""
        }
    }

    private func moveInstructions(from source: IndexSet, to destination: Int) {
        editedInstructions.move(fromOffsets: source, toOffset: destination)
    }

    private func deleteInstructions(at offsets: IndexSet) {
        editedInstructions.remove(atOffsets: offsets)
    }

    private func cancelEditing() {
        isEditing = false
        // Clear any pending AI edits
        pendingEditResponse = nil
        showModificationReview = false
    }

    private func saveChanges(asNewRecipe: Bool) async {
        let cleanedIngredients = editedIngredients.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let cleanedInstructions = editedInstructions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tagsList = editedTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let recipeBase = RecipeBase(
            title: editedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            description: editedDescription.isEmpty ? nil : editedDescription,
            servings: editedServings,
            prepTime: Int(editedPrepTime),
            cookTime: Int(editedCookTime),
            ingredients: cleanedIngredients,
            instructions: cleanedInstructions,
            tags: tagsList,
            sourceUrl: editedSourceUrl.isEmpty ? nil : editedSourceUrl,
            cuisineType: editedCuisineType.isEmpty ? nil : editedCuisineType,
            difficulty: editedDifficulty.isEmpty ? nil : editedDifficulty
        )

        let success: Bool
        if asNewRecipe {
            success = await recipeManager.createRecipe(recipeBase)
        } else {
            success = await recipeManager.updateRecipe(id: recipe.id, with: recipeBase)
        }

        if success {
            isEditing = false
            if asNewRecipe {
                // Navigate back to recipe list when saving as new
                dismiss()
            }
        }
    }

    private var currentRecipeBase: RecipeBase {
        if isEditing {
            return RecipeBase(
                title: editedTitle,
                description: editedDescription.isEmpty ? nil : editedDescription,
                servings: editedServings,
                prepTime: Int(editedPrepTime),
                cookTime: Int(editedCookTime),
                ingredients: editedIngredients,
                instructions: editedInstructions,
                tags: editedTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                sourceUrl: editedSourceUrl.isEmpty ? nil : editedSourceUrl,
                cuisineType: editedCuisineType.isEmpty ? nil : editedCuisineType,
                difficulty: editedDifficulty.isEmpty ? nil : editedDifficulty
            )
        } else {
            return RecipeBase(
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
            )
        }
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

                    // Generate diff between original and modified recipes
                    let modifications = RecipeDiffService.generateDiff(
                        original: currentRecipeBase,
                        modified: response.modifiedRecipe
                    )

                    if modifications.isEmpty {
                        aiEditError = "No changes were made. The recipe may already match your request."
                        return
                    }

                    // Create a response with modifications for the UI
                    let responseWithModifications = RecipeEditResponse(
                        modifications: modifications,
                        modifiedRecipe: response.modifiedRecipe,
                        overallConfidence: response.overallConfidence,
                        warnings: response.warnings
                    )

                    // Store response and show review
                    pendingEditResponse = responseWithModifications
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
        editedTitle = recipe.title
        editedDescription = recipe.description ?? ""
        editedServings = recipe.servings
        editedPrepTime = recipe.prepTime != nil ? "\(recipe.prepTime!)" : ""
        editedCookTime = recipe.cookTime != nil ? "\(recipe.cookTime!)" : ""
        editedIngredients = recipe.ingredients
        editedInstructions = recipe.instructions
        editedTags = recipe.tags.joined(separator: ", ")
        editedCuisineType = recipe.cuisineType ?? ""
        editedDifficulty = recipe.difficulty ?? ""
    }
}

// Helper struct for sheet presentation
struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

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

#Preview {
    NavigationStack {
        RecipeDetailView(recipe: Recipe(
            id: UUID(),
            title: "Chocolate Chip Cookies",
            description: "Classic homemade chocolate chip cookies that are crispy on the outside and chewy on the inside.",
            servings: 24,
            prepTime: 15,
            cookTime: 12,
            ingredients: [
                "2 cups all-purpose flour",
                "1 cup butter, softened",
                "3/4 cup brown sugar",
                "1/2 cup white sugar",
                "2 large eggs",
                "2 tsp vanilla extract",
                "1 cup chocolate chips"
            ],
            instructions: [
                "Preheat oven to 375°F (190°C).",
                "In a medium bowl, whisk together flour, baking soda, and salt.",
                "In a large bowl, cream together butter and both sugars until light and fluffy.",
                "Beat in eggs one at a time, then vanilla.",
                "Gradually mix in flour mixture until just combined.",
                "Stir in chocolate chips.",
                "Drop rounded tablespoons of dough onto ungreased baking sheets.",
                "Bake for 9-11 minutes until golden brown.",
                "Cool on baking sheet for 5 minutes before transferring to wire rack."
            ],
            tags: ["dessert", "cookies", "chocolate"],
            sourceUrl: "https://example.com/cookies",
            cuisineType: "American",
            difficulty: "easy",
            createdAt: Date(),
            updatedAt: Date()
        ))
    }
    .environmentObject(RecipeManager())
}
