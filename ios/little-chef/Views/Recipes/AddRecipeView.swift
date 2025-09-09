//
//  AddRecipeView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI
import PhotosUI

struct AddRecipeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recipeManager: RecipeManager
    
    @State private var selectedInputType: RecipeInputType = .url
    @State private var urlInput = ""
    @State private var textInput = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    
    // Parsed recipe state
    @State private var parsedRecipe: RecipeData?
    @State private var parseConfidence: Double = 0.0
    @State private var parseWarnings: [String] = []
    @State private var showingEditView = false
    @State private var isParsingRecipe = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.orange)
                        
                        Text("Add New Recipe")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Choose how you'd like to add your recipe")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top)
                    
                    // Input type selector
                    VStack(spacing: 16) {
                        Text("Recipe Source")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                            ForEach(RecipeInputType.allCases, id: \.self) { inputType in
                                InputTypeCard(
                                    inputType: inputType,
                                    isSelected: selectedInputType == inputType
                                ) {
                                    selectedInputType = inputType
                                    clearInputs()
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Input area based on selected type
                    VStack(spacing: 16) {
                        switch selectedInputType {
                        case .url:
                            URLInputView(urlInput: $urlInput)
                        case .text:
                            TextInputView(textInput: $textInput)
                        case .image:
                            ImageInputView(
                                selectedPhoto: $selectedPhoto,
                                imageData: $imageData
                            )
                        }
                    }
                    .padding(.horizontal)
                    
                        // Parse button
                        Button(action: parseRecipe) {
                            HStack {
                                if isParsingRecipe {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                }
                                Text(isParsingRecipe ? "Parsing Recipe..." : "Parse Recipe")
                            }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canParseRecipe ? Color.orange : Color.gray)
                        .cornerRadius(12)
                    }
                    .disabled(!canParseRecipe || isParsingRecipe)
                    .padding(.horizontal)
                    
                    // Show parsed recipe if available
                    if let recipe = parsedRecipe {
                        ParsedRecipePreview(
                            recipe: recipe,
                            confidence: parseConfidence,
                            warnings: parseWarnings
                        ) {
                            showingEditView = true
                        }
                        .padding(.horizontal)
                    }
                    
                    Spacer(minLength: 20)
                }
            }
            .navigationTitle("Add Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingEditView) {
                if let recipe = parsedRecipe {
                    EditRecipeView(recipe: recipe) { finalRecipe in
                        Task {
                            let success = await recipeManager.createRecipe(finalRecipe)
                            if success {
                                dismiss()
                            }
                        }
                    }
                }
            }
            .alert("Error", isPresented: .constant(recipeManager.errorMessage != nil)) {
                Button("OK") {
                    recipeManager.clearError()
                }
            } message: {
                Text(recipeManager.errorMessage ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }
    
    private var canParseRecipe: Bool {
        switch selectedInputType {
        case .url:
            return !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .text:
            return !textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image:
            return imageData != nil
        }
    }
    
    private func clearInputs() {
        urlInput = ""
        textInput = ""
        selectedPhoto = nil
        imageData = nil
        parsedRecipe = nil
        parseWarnings = []
        parseConfidence = 0.0
    }
    
    private func parseRecipe() {
        Task {
            isParsingRecipe = true
            
            let result: RecipeParseResponse?
            
            switch selectedInputType {
            case .url:
                result = await recipeManager.parseRecipeFromUrl(urlInput.trimmingCharacters(in: .whitespacesAndNewlines))
            case .text:
                result = await recipeManager.parseRecipeFromText(textInput.trimmingCharacters(in: .whitespacesAndNewlines))
            case .image:
                if let imageData = imageData {
                    let base64Image = imageData.base64EncodedString()
                    result = await recipeManager.parseRecipeFromImage(base64Image)
                } else {
                    result = nil
                }
            }
            
            if let result = result {
                parsedRecipe = result.recipe
                parseConfidence = result.confidence
                parseWarnings = result.warnings
            }
            
            isParsingRecipe = false
        }
    }
}

// MARK: - Input Type Card
struct InputTypeCard: View {
    let inputType: RecipeInputType
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: inputType.icon)
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : .orange)
                
                Text(inputType.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(isSelected ? .white : .primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isSelected ? Color.orange : Color(.systemGray6))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - URL Input View
struct URLInputView: View {
    @Binding var urlInput: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recipe URL")
                .font(.headline)
            
            TextField("https://example.com/recipe", text: $urlInput)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.URL)
                .autocapitalization(.none)
            
            Text("Paste a link from your favorite recipe website")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Text Input View
struct TextInputView: View {
    @Binding var textInput: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recipe Text")
                .font(.headline)
            
            TextEditor(text: $textInput)
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            
            Text("Copy and paste recipe text, or type your own recipe")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Image Input View
struct ImageInputView: View {
    @Binding var selectedPhoto: PhotosPickerItem?
    @Binding var imageData: Data?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recipe Image")
                .font(.headline)
            
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                VStack(spacing: 12) {
                    if let imageData = imageData, let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 200)
                            .cornerRadius(8)
                    } else {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        
                        Text("Select Recipe Image")
                            .font(.headline)
                        
                        Text("Choose a photo of the recipe")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 120)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
            .onChange(of: selectedPhoto) { _, newValue in
                if let newValue = newValue {
                    Task {
                        if let data = try? await newValue.loadTransferable(type: Data.self) {
                            imageData = data
                        }
                    }
                }
            }
            
            Text("Take a photo or select from your library")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Parsed Recipe Preview
struct ParsedRecipePreview: View {
    let recipe: RecipeData
    let confidence: Double
    let warnings: [String]
    let onEdit: () -> Void
    
    var confidenceColor: Color {
        if confidence >= 0.8 { return .green }
        else if confidence >= 0.6 { return .orange }
        else { return .red }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recipe Parsed!")
                        .font(.headline)
                        .foregroundColor(.green)
                    
                    HStack {
                        Text("Confidence:")
                        Text("\(Int(confidence * 100))%")
                            .fontWeight(.semibold)
                            .foregroundColor(confidenceColor)
                    }
                    .font(.caption)
                }
                
                Spacer()
                
                Button(action: onEdit) {
                    HStack {
                        Image(systemName: "pencil")
                        Text("Edit & Save")
                    }
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange)
                    .cornerRadius(8)
                }
            }
            
            // Recipe preview
            VStack(alignment: .leading, spacing: 12) {
                Text(recipe.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                
                if let description = recipe.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                HStack {
                    if let prepTime = recipe.prepTime {
                        Label("\(prepTime)m prep", systemImage: "clock")
                    }
                    if let cookTime = recipe.cookTime {
                        Label("\(cookTime)m cook", systemImage: "flame")
                    }
                    Spacer()
                    Label("\(recipe.servings) servings", systemImage: "person.2")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                
                Text("\(recipe.ingredients.count) ingredients • \(recipe.instructions.count) steps")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Warnings (if any)
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Parsing Notes", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                    
                    ForEach(warnings.prefix(3), id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

#Preview {
    AddRecipeView()
        .environmentObject(RecipeManager())
}
