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
    @State private var textInput = ""
    @State private var isAnimating = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                if cookingSessionManager.hasActiveSession() {
                    ActiveCookingView()
                } else {
                    StartCookingView(showingRecipeSelector: $showingRecipeSelector)
                }
            }
            .navigationTitle(cookingSessionManager.hasActiveSession() ? "" : "Cook with LittleChef")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(cookingSessionManager.hasActiveSession() ? .hidden : .visible, for: .tabBar)
            .sheet(isPresented: $showingRecipeSelector) {
                RecipeSelectorView()
            }
            .sheet(isPresented: $cookingSessionManager.showModificationReview) {
                if let originalRecipe = cookingSessionManager.originalRecipe,
                   let currentRecipe = cookingSessionManager.currentSession?.recipe,
                   let originalRecipeId = cookingSessionManager.originalRecipeId {
                    // TODO: Update cooking session modification flow to use new Cursor-style approach
                    let reviewState = ModificationReviewState(
                        original: originalRecipe,
                        target: currentRecipe
                    )
                    InlineModificationReview(
                        reviewState: reviewState,
                        onComplete: { finalRecipe in
                            // TODO: Implement proper cooking session recipe update
                            print("⚠️ Cooking session modifications not yet implemented with Cursor-style approach")
                            cookingSessionManager.showModificationReview = false
                        },
                        onCancel: {
                            cookingSessionManager.showModificationReview = false
                        }
                    )
                }
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
            
            // Icon and title
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
            
            // Action buttons
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
    @EnvironmentObject var recipeManager: RecipeManager
    @State private var textInput = ""
    @State private var showingEndSessionDialog = false
    @State private var selectedTab: CookingTab = .recipe
    @FocusState private var isInputFocused: Bool

    enum CookingTab: String, CaseIterable {
        case recipe = "Recipe"
        case chat = "Chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with end session button and segmented control
            HStack(spacing: 12) {
                // End session button
                Button(action: {
                    showingEndSessionDialog = true
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.red)
                }

                // Segmented control
                Picker("View", selection: $selectedTab) {
                    ForEach(CookingTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding()

            Divider()

            // Main content area
            ZStack {
                if selectedTab == .recipe {
                    RecipeDetailsView()
                } else {
                    ChatAreaView()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Dismiss keyboard when tapping on content
                isInputFocused = false
            }

            // Input area - always visible
            InputAreaView(textInput: $textInput, isInputFocused: _isInputFocused)
        }
        .alert("End Cooking Session", isPresented: $showingEndSessionDialog) {
            if cookingSessionManager.recipeWasModified {
                // Recipe was modified - show first option
                Button("Save as New Recipe") {
                    saveModifiedRecipe(asNew: true)
                }
                Button("Overwrite Original") {
                    saveModifiedRecipe(asNew: false)
                }
                Button("Discard Changes", role: .destructive) {
                    endSessionWithoutSaving()
                }
                Button("Cancel", role: .cancel) { }
            } else {
                // No modifications - simple end session
                Button("End Session", role: .destructive) {
                    endSessionWithoutSaving()
                }
                Button("Cancel", role: .cancel) { }
            }
        } message: {
            if cookingSessionManager.recipeWasModified {
                Text("Your recipe was modified during this cooking session. How would you like to save it?")
            } else {
                Text("Are you sure you want to end this cooking session?")
            }
        }
        .onAppear {
            // Update voice assistant settings when view appears
            updateVoiceAssistantSettings()

            // Set up callback for auto-speaking responses
            cookingSessionManager.onResponseReady = { [weak voiceAssistant] response, audioData in
                guard let session = cookingSessionManager.currentSession,
                      session.userPreferences.voiceSettings.autoSpeakResponses else {
                    return
                }
                voiceAssistant?.speak(response, audioData: audioData)
            }
        }
        .onChange(of: cookingSessionManager.currentSession?.userPreferences.voiceSettings) { _ in
            // Update voice assistant settings when voice preferences change
            updateVoiceAssistantSettings()
        }
    }

    private func saveModifiedRecipe(asNew: Bool) {
        guard let session = cookingSessionManager.currentSession else {
            endSessionWithoutSaving()
            return
        }

        Task {
            let recipeToSave = session.recipe  // RecipeBase

            if asNew {
                // Save as new recipe
                _ = await recipeManager.createRecipe(recipeToSave)
            } else {
                // Overwrite original recipe
                if let originalId = cookingSessionManager.originalRecipeId {
                    _ = await recipeManager.updateRecipe(id: originalId, with: recipeToSave)
                } else {
                    // Fallback to save as new if no original ID
                    _ = await recipeManager.createRecipe(recipeToSave)
                }
            }

            // End session after saving
            endSessionWithoutSaving()
        }
    }

    private func endSessionWithoutSaving() {
        // Reset voice assistant state
        voiceAssistant.stopHandsFreeMode()
        // Reset session state
        cookingSessionManager.endCookingSession()
    }

    private func updateVoiceAssistantSettings() {
        // Update voice settings from the current session
        if let session = cookingSessionManager.currentSession {
            voiceAssistant.updateVoiceSettings(session.userPreferences.voiceSettings)
            print("🔄 Updated VoiceAssistant with current session preferences")
        }
    }
}

// MARK: - Recipe Details View (for side-by-side layout)

struct RecipeDetailsView: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @State private var showingAddTimer = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    var body: some View {
        if let session = cookingSessionManager.currentSession {
            GeometryReader { geometry in
                let isLandscape = geometry.size.width > geometry.size.height

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Recipe title and basic info
                        VStack(alignment: .leading, spacing: 12) {
                            Text(session.recipe.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.leading)

                            if let description = session.recipe.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            // Recipe info - single line for compact display
                            HStack(spacing: 8) {
                                if let prepTime = session.recipe.prepTime {
                                    CompactInfoCard(title: "Prep", value: "\(prepTime)m", icon: "clock")
                                }

                                if let cookTime = session.recipe.cookTime {
                                    CompactInfoCard(title: "Cook", value: "\(cookTime)m", icon: "flame")
                                }

                                EditableServingsCard(
                                    originalServings: session.recipe.servings,
                                    currentServings: cookingSessionManager.getCurrentServings(),
                                    onServingsChange: { newServings in
                                        cookingSessionManager.updateServings(newServings: newServings)
                                    }
                                )

                                if let difficulty = session.recipe.difficulty {
                                    CompactInfoCard(title: "Level", value: difficulty.capitalized, icon: "star")
                                }
                            }
                        }

                        Divider()

                        // Timers Section (moved above ingredients)
                        TimersSection(showingAddTimer: $showingAddTimer)

                        Divider()

                        // Ingredients and Instructions - side by side in landscape
                        if isLandscape {
                            HStack(alignment: .top, spacing: 16) {
                                IngredientsSection()
                                    .frame(maxWidth: .infinity)

                                Divider()

                                InstructionsSection()
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            // Portrait mode - stacked layout
                            IngredientsSection()

                            Divider()

                            InstructionsSection()
                        }

                        Spacer(minLength: 20)
                    }
                    .padding()
                }
            }
            .sheet(isPresented: $showingAddTimer) {
                AddTimerView { label, minutes in
                    cookingSessionManager.addManualTimer(label: label, durationMinutes: minutes)
                }
            }
        }
    }
}

// MARK: - Timers Section

struct TimersSection: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @Binding var showingAddTimer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Timers")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: {
                    showingAddTimer = true
                }) {
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
    }
}

// MARK: - Ingredients Section

struct IngredientsSection: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager

    var body: some View {
        if let session = cookingSessionManager.currentSession {
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
                    ForEach(Array(session.recipe.ingredients.enumerated()), id: \.offset) { index, ingredient in
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
        }
    }
}

// MARK: - Instructions Section

struct InstructionsSection: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager

    var body: some View {
        if let session = cookingSessionManager.currentSession {
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
        }
    }
}

// MARK: - Compact Info Card (for recipe details view)

struct CompactInfoCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption)
                    .fontWeight(.semibold)

                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color(.systemGray6))
        .cornerRadius(6)
    }
}

// MARK: - Recipe Header View

struct RecipeHeaderView: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    
    var body: some View {
        if let session = cookingSessionManager.currentSession {
            VStack(spacing: 8) {
                Text(session.recipe.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                
                HStack(spacing: 16) {
                    if let prepTime = session.recipe.prepTime {
                        Label("\(prepTime) min prep", systemImage: "clock")
                            .font(.caption)
                    }
                    
                    if let cookTime = session.recipe.cookTime {
                        Label("\(cookTime) min cook", systemImage: "flame")
                            .font(.caption)
                    }
                    
                    Label("\(session.recipe.servings) servings", systemImage: "person.2")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

// MARK: - Chat Area View

struct ChatAreaView: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if cookingSessionManager.getConversationHistory().isEmpty {
                        // Welcome message
                        VStack(spacing: 16) {
                            Image("littlechef")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 60, height: 60)
                            
                            Text("LittleChef is Ready!")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("Ask me anything about cooking this recipe! You can ask about ingredients, techniques, timing, or substitutions.")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .padding(.vertical, 40)
                    } else {
                        // Conversation history
                        ForEach(cookingSessionManager.getConversationHistory()) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }

                        // Streaming response (real-time)
                        if cookingSessionManager.isLoading && !cookingSessionManager.streamingResponse.isEmpty {
                            StreamingMessageView(text: cookingSessionManager.streamingResponse)
                        }
                    }

                    // Loading indicator (before any response text arrives)
                    if cookingSessionManager.isLoading && cookingSessionManager.streamingResponse.isEmpty {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Thinking...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                }
                .padding()
            }
            .onChange(of: cookingSessionManager.getConversationHistory().count) { _ in
                // Scroll to bottom when new message is added
                if let lastMessage = cookingSessionManager.getConversationHistory().last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Message Bubble View

struct MessageBubbleView: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.content)
                        .padding(12)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(16)
                        .containerRelativeFrame(.horizontal) { width, _ in
                            min(width * 0.8, 300)
                        }
                    
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.content)
                        .padding(12)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(16)
                        .containerRelativeFrame(.horizontal) { width, _ in
                            min(width * 0.8, 300)
                        }
                    
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Streaming Message View

struct StreamingMessageView: View {
    let text: String

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(text)
                        .padding(12)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: min(width * 0.8, 300), alignment: .leading)

                    // Typing indicator
                    HStack(spacing: 3) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 4, height: 4)
                                .opacity(0.6)
                                .animation(
                                    Animation.easeInOut(duration: 0.6)
                                        .repeatForever()
                                        .delay(Double(index) * 0.2),
                                    value: text
                                )
                        }
                    }
                    .padding(.top, 12)

                    Spacer()
                }

                Text("Typing...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Input Area View

struct InputAreaView: View {
    @Binding var textInput: String
    @FocusState var isInputFocused: Bool
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: DesignSystem.Spacing.lg) {
                // Hands-free mode toggle
                Button(action: {
                    isInputFocused = false
                    if voiceAssistant.isHandsFreeMode {
                        voiceAssistant.stopHandsFreeMode()
                    } else {
                        startHandsFreeMode()
                    }
                }) {
                    Image(systemName: voiceAssistant.isHandsFreeMode ? "ear.fill" : "ear")
                        .font(.title2)
                        .foregroundColor(voiceAssistant.isHandsFreeMode ? DesignSystem.Colors.success : DesignSystem.Colors.primary)
                        .scaleEffect(voiceAssistant.isWakeWordListening && isAnimating ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isAnimating)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(Circle().fill(voiceAssistant.isHandsFreeMode ? DesignSystem.Colors.successLight : DesignSystem.Colors.backgroundSecondary))
                .disabled(!voiceAssistant.isAvailable || cookingSessionManager.isLoading)

                // Voice button
                Button(action: {
                    isInputFocused = false

                    // If audio is playing, stop it
                    if voiceAssistant.isSpeaking {
                        voiceAssistant.stopSpeaking()
                        return
                    }

                    // Normal voice recording flow
                    if voiceAssistant.isListening {
                        voiceAssistant.stopListening()
                        if voiceAssistant.hasRecognizedText() {
                            sendVoiceQuery()
                        }
                    } else {
                        voiceAssistant.startListening()
                    }
                }) {
                    // Show stop icon when audio is playing
                    let iconName = voiceAssistant.isSpeaking ? "stop.fill" : (voiceAssistant.isListening ? "mic.fill" : "mic")
                    let color = voiceAssistant.isSpeaking ? Color.red : (voiceAssistant.isListening ? DesignSystem.Colors.error : DesignSystem.Colors.primary)

                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundColor(color)
                        .scaleEffect(voiceAssistant.isListening && isAnimating ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isAnimating)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(Circle().fill(DesignSystem.Colors.backgroundSecondary))
                .disabled(!voiceAssistant.isAvailable || cookingSessionManager.isLoading || (voiceAssistant.isHandsFreeMode && !voiceAssistant.isSpeaking))
                .onAppear {
                    if voiceAssistant.isListening {
                        isAnimating = true
                    }
                }
                .onChange(of: voiceAssistant.isListening) { listening in
                    isAnimating = listening
                }
                .onChange(of: voiceAssistant.isWakeWordListening) { listening in
                    isAnimating = listening
                }

                // Text input
                TextField("Ask about cooking...", text: $textInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isInputFocused)
                    .disabled(cookingSessionManager.isLoading)
                    .onSubmit {
                        sendTextQuery()
                    }

                // Send button
                Button(action: {
                    sendTextQuery()
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : DesignSystem.Colors.primary)
                }
                .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cookingSessionManager.isLoading)
            }
            .padding()
            
            // Hands-free mode status
            if voiceAssistant.isHandsFreeMode {
                VStack {
                    Divider()
                    HStack {
                        Image(systemName: voiceAssistant.isWakeWordListening ? "ear.fill" : "waveform")
                            .foregroundColor(.green)
                        
                        if voiceAssistant.isListening {
                            Text("Listening: \(voiceAssistant.recognizedText.isEmpty ? "Speak now..." : voiceAssistant.recognizedText)")
                                .foregroundColor(.primary)
                        } else if voiceAssistant.isWakeWordListening {
                            Text("Say \"Hey LittleChef\" to start...")
                                .foregroundColor(.secondary)
                        } else {
                            Text("Hands-free mode active")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color.green.opacity(0.1))
            }
            
            // Voice recognition display (for manual mode)
            else if voiceAssistant.isListening && !voiceAssistant.recognizedText.isEmpty {
                VStack {
                    Divider()
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundColor(.orange)
                        Text(voiceAssistant.recognizedText)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemGray6))
            }
            
            // Error display
            if let error = cookingSessionManager.errorMessage {
                VStack {
                    Divider()
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                        Spacer()
                        Button("Dismiss") {
                            cookingSessionManager.errorMessage = nil
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemGray6))
            }
        }
    }
    
    private func sendTextQuery() {
        let query = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        textInput = ""
        isInputFocused = false // Dismiss keyboard

        Task {
            await cookingSessionManager.sendQuery(query)
            // Audio playback now handled by onResponseReady callback
        }
    }
    
    private func sendVoiceQuery() {
        let query = voiceAssistant.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        
        voiceAssistant.clearRecognizedText()
        
        Task {
            await cookingSessionManager.sendQuery(query)
            // Audio playback now handled by onResponseReady callback
        }
    }
    
    private func startHandsFreeMode() {
        // Update voice settings from the current session
        if let session = cookingSessionManager.currentSession {
            voiceAssistant.updateVoiceSettings(session.userPreferences.voiceSettings)
            print("🔄 Updated VoiceAssistant with current session preferences")
        }
        
        // Set up callbacks
        voiceAssistant.onWakeWordDetected = {
            print("🎤 Wake word detected - transitioning to listening")
        }
        
        voiceAssistant.onVoiceQueryReady = { [weak cookingSessionManager, weak voiceAssistant] query in
            print("🎤 Voice query ready: \(query)")
            
            Task {
                await cookingSessionManager?.sendQuery(query)
                // Audio playback now handled by onResponseReady callback
            }
        }
        
        voiceAssistant.startHandsFreeMode()
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
                    cookingSessionManager.startCookingSession(with: recipe)
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
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await recipeManager.loadRecipes()
            }
        }
    }
}

// MARK: - Editable Servings Card

struct EditableServingsCard: View {
    let originalServings: Int
    let currentServings: Int
    let onServingsChange: (Int) -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2")
                .font(.caption2)
                .foregroundColor(.orange)

            // Stepper controls for servings
            HStack(spacing: 2) {
                // Decrease button
                Button(action: {
                    if currentServings > 1 {
                        onServingsChange(currentServings - 1)
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption2)
                        .foregroundColor(currentServings > 1 ? .orange : .gray)
                }
                .disabled(currentServings <= 1)

                // Current servings display
                VStack(alignment: .center, spacing: 1) {
                    Text("\(currentServings)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text("Serves")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Increase button
                Button(action: {
                    if currentServings < 50 {
                        onServingsChange(currentServings + 1)
                    }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.caption2)
                        .foregroundColor(currentServings < 50 ? .orange : .gray)
                }
                .disabled(currentServings >= 50)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color(.systemGray6))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(currentServings != originalServings ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }
}


#Preview {
    CookingSessionView()
        .environmentObject(CookingSessionManager(preferencesManager: PreferencesManager(), timerManager: TimerManager()))
        .environmentObject(VoiceAssistant())
        .environmentObject(RecipeManager())
}
