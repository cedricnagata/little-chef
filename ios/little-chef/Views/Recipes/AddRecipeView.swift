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
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imageDataArray: [Data] = []
    
    // Parsed recipe state
    @State private var parsedRecipe: RecipeData?
    @State private var parseConfidence: Double = 0.0
    @State private var parseWarnings: [String] = []
    @State private var showingEditView = false
    @State private var isParsingRecipe = false
    @State private var showingErrorAlert = false
    @State private var errorAlertMessage = ""
    @State private var lastProcessedError: String?
    
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
                            MultiImageInputView(
                                selectedPhotos: $selectedPhotos,
                                imageDataArray: $imageDataArray
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
            .alert("Error", isPresented: $showingErrorAlert) {
                Button("OK") {
                    showingErrorAlert = false
                    errorAlertMessage = ""
                    lastProcessedError = nil
                    recipeManager.clearError()
                }
            } message: {
                Text(errorAlertMessage)
            }
            .onAppear {
                // Only clear stale error state when first appearing
                if !showingErrorAlert && !isParsingRecipe {
                    lastProcessedError = nil
                    errorAlertMessage = ""
                    recipeManager.clearError()
                }
            }
        }
        .navigationViewStyle(.stack)
    }
    
    private var canParseRecipe: Bool {
        switch selectedInputType {
        case .url:
            return !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .text:
            let trimmedText = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedText.count >= 10 && trimmedText.count <= 50000
        case .image:
            return !imageDataArray.isEmpty
        }
    }
    
    private func clearInputs() {
        urlInput = ""
        textInput = ""
        selectedPhotos = []
        imageDataArray = []
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
                if !imageDataArray.isEmpty {
                    let uiImages = imageDataArray.compactMap { UIImage(data: $0) }
                    result = await recipeManager.parseRecipeFromImages(uiImages)
                } else {
                    result = nil
                }
            }
            
            if let result = result {
                parsedRecipe = result.recipe
                parseConfidence = result.confidence
                parseWarnings = result.warnings
            } else {
                // Handle parsing failure directly here
                if let errorMessage = recipeManager.errorMessage {
                    errorAlertMessage = errorMessage
                    lastProcessedError = errorMessage
                    showingErrorAlert = true
                    // Clear the manager's error immediately so it doesn't interfere
                    recipeManager.clearError()
                }
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
    
    private var trimmedText: String {
        textInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var characterCount: Int {
        trimmedText.count
    }
    
    private var isValid: Bool {
        characterCount >= 10 && characterCount <= 50000
    }
    
    private var validationMessage: String? {
        if trimmedText.isEmpty {
            return nil
        } else if characterCount < 10 {
            return "Text must be at least 10 characters long"
        } else if characterCount > 50000 {
            return "Text must be less than 50,000 characters"
        }
        return nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recipe Text")
                    .font(.headline)
                
                Spacer()
                
                Text("\(characterCount)/50,000")
                    .font(.caption)
                    .foregroundColor(isValid || trimmedText.isEmpty ? .secondary : .red)
            }
            
            TextEditor(text: $textInput)
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(validationMessage != nil ? Color.red : Color.clear, lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Copy and paste recipe text, or type your own recipe")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let validationMessage = validationMessage {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        Text(validationMessage)
                            .foregroundColor(.red)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

// MARK: - Multi Image Input View
struct MultiImageInputView: View {
    @Binding var selectedPhotos: [PhotosPickerItem]
    @Binding var imageDataArray: [Data]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recipe Images")
                    .font(.headline)
                Spacer()
                Text("\(imageDataArray.count)/5")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 5, matching: .images) {
                if imageDataArray.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        
                        Text("Select Recipe Images")
                            .font(.headline)
                        
                        Text("Choose up to 5 photos")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 120)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                        ForEach(Array(imageDataArray.enumerated()), id: \.offset) { index, imageData in
                            if let uiImage = UIImage(data: imageData) {
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(height: 100)
                                        .clipped()
                                        .cornerRadius(8)
                                    
                                    Button(action: {
                                        removeImage(at: index)
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.white)
                                            .background(Color.black.opacity(0.7))
                                            .clipShape(Circle())
                                    }
                                    .padding(4)
                                }
                            }
                        }
                        
                        if imageDataArray.count < 5 {
                            Button(action: {}) {
                                VStack {
                                    Image(systemName: "plus")
                                        .font(.title2)
                                        .foregroundColor(.orange)
                                    Text("Add More")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(height: 100)
                                .frame(maxWidth: .infinity)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }
            .onChange(of: selectedPhotos) { _, newPhotos in
                Task {
                    var newImageData: [Data] = []
                    for photo in newPhotos {
                        if let data = try? await photo.loadTransferable(type: Data.self) {
                            newImageData.append(data)
                        }
                    }
                    imageDataArray = newImageData
                }
            }
            
            Text("Take photos or select from your library (up to 5 images)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private func removeImage(at index: Int) {
        imageDataArray.remove(at: index)
        selectedPhotos.remove(at: index)
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
