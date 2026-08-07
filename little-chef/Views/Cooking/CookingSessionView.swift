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
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var llmService: LLMService

    /// Cooking without a recipe means the assistant writes it down as you go, so it needs an
    /// assistant to write it. Without one this would be a cook that records nothing and offers
    /// to save an empty recipe at the end.
    private var canCookWithoutRecipe: Bool { llmService.capability.llmChatEnabled }

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

                Text("Follow one of your recipes, or cook from scratch and let LittleChef write it down as you go")
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

                Button(action: {
                    Task { await cookingSessionManager.startFreestyleSession() }
                }) {
                    HStack {
                        Image(systemName: "square.and.pencil")
                        Text("Cook Without a Recipe")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange.opacity(0.12))
                    .foregroundColor(.orange)
                    .cornerRadius(12)
                }
                .disabled(!canCookWithoutRecipe)

                if !canCookWithoutRecipe {
                    Text("Cooking without a recipe needs the AI assistant")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if recipeManager.recipes.isEmpty {
                    Text("No recipes yet — add one, or just start cooking")
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
    @ObservedObject private var bigBroClient = LLMService.shared.bigBroClient
    @State private var textInput = ""
    @State private var showingEndSessionAlert = false
    @State private var showingSessionChanges = false
    @State private var isRecipeExpanded = true
    @FocusState private var isTextFieldFocused: Bool

    /// When no LLM is available (no on-device model + BigBro not connected), the cooking
    /// assistant chat is hidden; manual timers remain available.
    ///
    /// Asks the session, not the service: the provider is pinned when a cook starts, so this
    /// has to describe the backend this session is actually running on.
    private var chatEnabled: Bool { cookingSessionManager.capability.llmChatEnabled }

    var body: some View {
        VStack(spacing: 0) {
            CollapsibleRecipeHeader(
                isExpanded: $isRecipeExpanded,
                onEndSession: endSession
            )

            // Belt and braces, because no single mechanism covers every way out: a tap on the
            // pane handles the empty spaces the scroll view hit-tests for itself, the
            // whole-screen catcher below handles everything outside the panes, dragging the
            // list dismisses interactively, and the input bar carries a Done key for when all
            // of that is behind the keyboard.
            if isRecipeExpanded {
                RecipeDetailsView()
                    .transition(.move(edge: .top))
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
            } else {
                ChatAreaView()
                    .transition(.move(edge: .bottom))
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
            }

            if chatEnabled, cookingSessionManager.isPreparingModel, !cookingSessionManager.isLoading {
                warmUpBanner
            }

            if chatEnabled {
                InputAreaView(textInput: $textInput, isTextFieldFocused: $isTextFieldFocused)
            } else {
                VStack(spacing: 0) {
                    Divider()
                    Label("AI assistant unavailable — add timers manually", systemImage: "wand.and.stars.inverse")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
        }
        .dismissesKeyboardOnTap()
        .ignoresSafeArea(.container, edges: .bottom)
        .animation(.easeInOut(duration: 0.3), value: isRecipeExpanded)
        .animation(.easeInOut(duration: 0.2), value: cookingSessionManager.isPreparingModel)
        .onReceive(NotificationCenter.default.publisher(for: .timerNotificationTapped)) { _ in
            isRecipeExpanded = true
        }
        .alert("End Cooking Session", isPresented: $showingEndSessionAlert) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) { finishSession() }
        } message: {
            Text("Are you sure you want to end this cooking session?")
        }
        .sheet(isPresented: $showingSessionChanges) {
            SessionChangesView(
                initialTitle: cookingSessionManager.currentSession?.recipe.title ?? "",
                onEnd: finishSession
            )
        }
        .onAppear {
            cookingSessionManager.initAgentForSession()
            // The voice stack answers on the same backend the session pinned, for the same
            // reason the agent does: switching mid-cook would swap the speech and inference
            // stack out from under a running hands-free loop.
            voiceAssistant.configure(provider: cookingSessionManager.sessionProvider)
            updateVoiceAssistantSettings()
        }
        .onDisappear {
            // Leaving the cooking screen has to give the audio route back. A loop left running
            // holds an open microphone and a `.playAndRecord` category for the rest of the
            // app's life, and the next thing that wants the speaker gets an engine that starts
            // but never renders.
            voiceAssistant.stopHandsFree()
            voiceAssistant.stopSpeaking()
        }
        .onChange(of: cookingSessionManager.currentSession?.userPreferences.voiceSettings) {
            updateVoiceAssistantSettings()
        }
    }

    /// Shown while the backend is being brought up, so the wait has a name.
    ///
    /// The cost was always there — it just used to be spent inside the first reply, where a
    /// model loading its weights is indistinguishable from an assistant that has stopped
    /// working.
    private var warmUpBanner: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(cookingSessionManager.sessionProvider == .bigBro
                     ? "Waking your Mac's model…"
                     : "Getting the on-device model ready…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .transition(.opacity)
    }

    /// Leaving a cook asks one question or the other, never both.
    ///
    /// With unsaved recipe work there is nothing to confirm — the review sheet already offers
    /// ending as one of its answers, and a plain "are you sure?" in front of it would be a
    /// confirmation for a thing the next screen is about to ask properly.
    private func endSession() {
        if cookingSessionManager.hasPendingRecipeWork {
            showingSessionChanges = true
        } else {
            showingEndSessionAlert = true
        }
    }

    private func finishSession() {
        voiceAssistant.stopHandsFree()
        voiceAssistant.stopSpeaking()
        cookingSessionManager.endCookingSession()
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
                            HStack(spacing: 5) {
                                Text(session.recipe.displayTitle)
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                // The recipe on screen has drifted from the one that is stored.
                                // Worth a mark of its own: the assistant edits quietly while you
                                // are looking at the chat, and finding out only at the exit
                                // prompt is finding out too late to remember what you agreed to.
                                if cookingSessionManager.hasPendingRecipeWork {
                                    Image(systemName: "pencil.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                        .accessibilityLabel("Unsaved recipe changes")
                                }
                            }

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

                        if session.recipe.ingredients.isEmpty {
                            Text(emptyListHint("Tell LittleChef what you're using and it will list it here."))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
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

                        if session.recipe.instructions.isEmpty {
                            Text(emptyListHint("Say what you did and LittleChef will write the method down as you go."))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
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
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showingAddTimer) {
                AddTimerView { label, seconds in
                    cookingSessionManager.addManualTimer(label: label, durationSeconds: seconds)
                }
            }
        }
    }

    /// An empty ingredient or step list means two different things and needs two different lines.
    /// Writing a recipe down, it is the starting state and says how to fill it. Following one, it
    /// is a recipe that was saved incomplete, and pointing at the assistant would be a non sequitur.
    private func emptyListHint(_ whileWriting: String) -> String {
        cookingSessionManager.isBuildingNewRecipe ? whileWriting : "Nothing listed for this recipe."
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
        .environmentObject(LLMService.shared)
}
