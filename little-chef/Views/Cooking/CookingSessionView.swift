//
//  CookingSessionView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/12/25.
//

import SwiftUI

struct CookingSessionView: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @EnvironmentObject var recipeManager: RecipeManager
    @State private var showingRecipeSelector = false

    var body: some View {
        NavigationStack {
            ZStack {
                if cookingSessionManager.hasActiveSession() {
                    ActiveCookingView()
                } else {
                    StartCookingView(showingRecipeSelector: $showingRecipeSelector)
                        .navigationTitle("Cook with LittleChef")
                }
            }
            .sheet(isPresented: $showingRecipeSelector) {
                RecipeSelectorView()
            }
            .task {
                await recipeManager.loadRecipes()
            }
        }
    }
}

// MARK: - Start Cooking View

struct StartCookingView: View {
    @Binding var showingRecipeSelector: Bool
    @EnvironmentObject var recipeManager: RecipeManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.orange)

                Text("Start Cooking")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Select a recipe to begin cooking with AI assistance")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 16) {
                Button(action: {
                    showingRecipeSelector = true
                }) {
                    HStack {
                        Image(systemName: "book.fill")
                        Text("Choose Recipe")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(recipeManager.recipes.isEmpty)

                if recipeManager.recipes.isEmpty {
                    Text("Add recipes first to start cooking")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 50)
        }
    }
}

// MARK: - Active Cooking View

struct ActiveCookingView: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @State private var textInput = ""
    @State private var showingEndSessionAlert = false
    @State private var isRecipeExpanded = true
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            CollapsibleRecipeHeader(
                isExpanded: $isRecipeExpanded,
                onEndSession: { showingEndSessionAlert = true }
            )
            .onTapGesture { isTextFieldFocused = false }

            if isRecipeExpanded {
                RecipeDetailsView()
                    .transition(.move(edge: .top))
                    .contentShape(Rectangle())
                    .onTapGesture { isTextFieldFocused = false }
            } else {
                ChatAreaView()
                    .transition(.move(edge: .bottom))
                    .contentShape(Rectangle())
                    .onTapGesture { isTextFieldFocused = false }
            }

            InputAreaView(textInput: $textInput, isTextFieldFocused: $isTextFieldFocused)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .animation(.easeInOut(duration: 0.3), value: isRecipeExpanded)
        .onReceive(NotificationCenter.default.publisher(for: .timerNotificationTapped)) { _ in
            isRecipeExpanded = true
        }
        .alert("End Cooking Session", isPresented: $showingEndSessionAlert) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) {
                voiceAssistant.stopHandsFreeMode()
                cookingSessionManager.endCookingSession()
            }
        } message: {
            Text("Are you sure you want to end this cooking session?")
        }
        .onAppear {
            cookingSessionManager.initAgentForSession()
            updateVoiceAssistantSettings()
        }
        .onChange(of: cookingSessionManager.currentSession?.userPreferences.voiceSettings) {
            updateVoiceAssistantSettings()
        }
    }

    private func updateVoiceAssistantSettings() {
        if let session = cookingSessionManager.currentSession {
            voiceAssistant.updateVoiceSettings(session.userPreferences.voiceSettings)
        }
    }
}

// MARK: - Collapsible Recipe Header

struct CollapsibleRecipeHeader: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @Binding var isExpanded: Bool
    let onEndSession: () -> Void

    var body: some View {
        if let session = cookingSessionManager.currentSession {
            HStack(spacing: 0) {
                Button(action: onEndSession) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .foregroundColor(.orange)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 8) {
                        Spacer()

                        VStack(alignment: .center, spacing: 4) {
                            Text(session.recipe.title)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            if !isExpanded {
                                HStack(spacing: 12) {
                                    if let prepTime = session.recipe.prepTime {
                                        Label("\(prepTime)m", systemImage: "clock")
                                            .font(.caption)
                                    }
                                    if let cookTime = session.recipe.cookTime {
                                        Label("\(cookTime)m", systemImage: "flame")
                                            .font(.caption)
                                    }
                                    Label("\(session.recipe.servings)", systemImage: "person.2")
                                        .font(.caption)
                                }
                                .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.title3)
                            .foregroundColor(.orange)
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(Color(.systemGray6))

            Divider()
        }
    }
}

// MARK: - Recipe Details View

struct RecipeDetailsView: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @State private var showingAddTimer = false

    var body: some View {
        if let session = cookingSessionManager.currentSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Centered metadata row at the top
                    InlineRecipeMetadata(
                        prepTime: session.recipe.prepTime,
                        cookTime: session.recipe.cookTime,
                        originalServings: session.recipe.servings,
                        currentServings: cookingSessionManager.getCurrentServings(),
                        difficulty: session.recipe.difficulty,
                        onServingsChange: { newServings in
                            cookingSessionManager.updateServings(newServings: newServings)
                        }
                    )
                    .frame(maxWidth: .infinity)

                    if let description = session.recipe.description {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Timers
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Timers")
                                .font(.headline)
                                .fontWeight(.semibold)
                            Spacer()
                            Button(action: { showingAddTimer = true }) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.orange)
                            }
                        }

                        if cookingSessionManager.localTimers.isEmpty {
                            Text("No timers yet. Add one above or ask the AI!")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(cookingSessionManager.localTimers) { timer in
                                    TimerCardView(
                                        timer: timer,
                                        onDelete: {
                                            cookingSessionManager.deleteManualTimer(id: timer.id)
                                        }
                                    )
                                }
                            }
                        }
                    }

                    Divider()

                    // Ingredients
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Ingredients")
                                .font(.headline)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(session.recipe.ingredients.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(session.recipe.ingredients.indices, id: \.self) { idx in
                                let ingredient = session.recipe.ingredients[idx]
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Color.orange.opacity(0.3))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 6)
                                    Text(ingredient)
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                            }
                        }
                    }

                    Divider()

                    // Instructions
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Instructions")
                                .font(.headline)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(session.recipe.instructions.count) steps")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(session.recipe.instructions.enumerated()), id: \.offset) { index, instruction in
                                HStack(alignment: .top, spacing: 8) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.orange)
                                            .frame(width: 18, height: 18)
                                        Text("\(index + 1)")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                    }
                                    Text(instruction)
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                            }
                        }
                    }

                    Spacer(minLength: 20)
                }
                .padding()
            }
            .sheet(isPresented: $showingAddTimer) {
                AddTimerView { label, seconds in
                    cookingSessionManager.addManualTimer(label: label, durationSeconds: seconds)
                }
            }
        }
    }
}

// MARK: - Inline Recipe Metadata

struct InlineRecipeMetadata: View {
    let prepTime: Int?
    let cookTime: Int?
    let originalServings: Int
    let currentServings: Int
    let difficulty: String?
    let onServingsChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let prepTime {
                MetaChip(icon: "clock", text: "Prep \(prepTime)m")
            }
            if let cookTime {
                MetaChip(icon: "flame", text: "Cook \(cookTime)m")
            }
            InlineServingsControl(
                originalServings: originalServings,
                currentServings: currentServings,
                onServingsChange: onServingsChange
            )
            if let difficulty {
                MetaChip(icon: "star", text: difficulty.capitalized)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

private struct MetaChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.orange)
            Text(text)
        }
    }
}

private struct InlineServingsControl: View {
    let originalServings: Int
    let currentServings: Int
    let onServingsChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2")
                .font(.caption2)
                .foregroundColor(.orange)
            Button(action: {
                if currentServings > 1 { onServingsChange(currentServings - 1) }
            }) {
                Image(systemName: "minus.circle.fill")
                    .font(.caption)
                    .foregroundColor(currentServings > 1 ? .orange : .gray)
            }
            .disabled(currentServings <= 1)
            .buttonStyle(.plain)

            Text("\(currentServings)")
                .fontWeight(.semibold)
                .foregroundColor(currentServings != originalServings ? .orange : .primary)
                .monospacedDigit()
                .frame(minWidth: 18)

            Button(action: {
                if currentServings < 50 { onServingsChange(currentServings + 1) }
            }) {
                Image(systemName: "plus.circle.fill")
                    .font(.caption)
                    .foregroundColor(currentServings < 50 ? .orange : .gray)
            }
            .disabled(currentServings >= 50)
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Compact Info Card

struct CompactInfoCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.orange)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
}

// MARK: - Editable Servings Card

struct EditableServingsCard: View {
    let originalServings: Int
    let currentServings: Int
    let onServingsChange: (Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "person.2")
                .font(.caption)
                .foregroundColor(.orange)

            HStack(spacing: 4) {
                Button(action: {
                    if currentServings > 1 { onServingsChange(currentServings - 1) }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption)
                        .foregroundColor(currentServings > 1 ? .orange : .gray)
                }
                .disabled(currentServings <= 1)

                VStack(spacing: 1) {
                    Text("\(currentServings)")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .frame(minWidth: 30)

                    if currentServings != originalServings {
                        Text("(was \(originalServings))")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }

                Button(action: {
                    if currentServings < 50 { onServingsChange(currentServings + 1) }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.caption)
                        .foregroundColor(currentServings < 50 ? .orange : .gray)
                }
                .disabled(currentServings >= 50)
            }

            Text("Serves")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(currentServings != originalServings ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Recipe Selector View

struct RecipeSelectorView: View {
    @EnvironmentObject var recipeManager: RecipeManager
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(recipeManager.recipes) { recipe in
                Button(action: {
                    Task { await cookingSessionManager.startCookingSession(with: recipe) }
                    dismiss()
                }) {
                    RecipeRowView(recipe: recipe)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .navigationTitle("Choose Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await recipeManager.loadRecipes()
            }
        }
    }
}

#Preview {
    CookingSessionView()
        .environmentObject(CookingSessionManager())
        .environmentObject(VoiceAssistant())
        .environmentObject(RecipeManager())
}
