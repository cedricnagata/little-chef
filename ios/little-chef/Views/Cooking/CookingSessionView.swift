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
    @State private var textInput = ""
    @State private var showingEndSessionAlert = false
    @State private var selectedTab: CookingTab = .recipe
    @FocusState private var isInputFocused: Bool

    enum CookingTab: String, CaseIterable {
        case recipe = "Recipe"
        case chat = "Chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented control
            Picker("View", selection: $selectedTab) {
                ForEach(CookingTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
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
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    showingEndSessionAlert = true
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundColor(.red)
                }
            }
        }
        .alert("End Cooking Session", isPresented: $showingEndSessionAlert) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) {
                // Reset voice assistant state
                voiceAssistant.stopHandsFreeMode()
                // Reset session state
                cookingSessionManager.endCookingSession()
            }
        } message: {
            Text("Are you sure you want to end this cooking session?")
        }
        .onAppear {
            // Update voice assistant settings when view appears
            updateVoiceAssistantSettings()
        }
        .onChange(of: cookingSessionManager.currentSession?.userPreferences.voiceSettings) { _ in
            // Update voice assistant settings when voice preferences change
            updateVoiceAssistantSettings()
        }
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
    
    var body: some View {
        if let session = cookingSessionManager.currentSession {
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
                        
                        // Recipe info
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
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
                    
                    Divider()
                    
                    // Timers Section
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
                AddTimerView { label, minutes in
                    cookingSessionManager.addManualTimer(label: label, durationMinutes: minutes)
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
                    }
                    
                    // Loading indicator
                    if cookingSessionManager.isLoading {
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
                    if voiceAssistant.isListening {
                        voiceAssistant.stopListening()
                        if voiceAssistant.hasRecognizedText() {
                            sendVoiceQuery()
                        }
                    } else {
                        voiceAssistant.startListening()
                    }
                }) {
                    Image(systemName: voiceAssistant.isListening ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundColor(voiceAssistant.isListening ? DesignSystem.Colors.error : DesignSystem.Colors.primary)
                        .scaleEffect(voiceAssistant.isListening && isAnimating ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isAnimating)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(Circle().fill(DesignSystem.Colors.backgroundSecondary))
                .disabled(!voiceAssistant.isAvailable || cookingSessionManager.isLoading || voiceAssistant.isHandsFreeMode)
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
            if let error = cookingSessionManager.error {
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
                            cookingSessionManager.error = nil
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

            // Auto-speak response if enabled
            if let session = cookingSessionManager.currentSession,
               session.userPreferences.voiceSettings.autoSpeakResponses,
               !cookingSessionManager.lastResponse.isEmpty {
                voiceAssistant.speak(cookingSessionManager.lastResponse)
            }
        }
    }
    
    private func sendVoiceQuery() {
        let query = voiceAssistant.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        
        voiceAssistant.clearRecognizedText()
        
        Task {
            await cookingSessionManager.sendQuery(query)
            
            // Auto-speak response for voice queries
            if !cookingSessionManager.lastResponse.isEmpty {
                voiceAssistant.speak(cookingSessionManager.lastResponse)
            }
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
                
                // Auto-speak response for hands-free queries
                if let response = cookingSessionManager?.lastResponse, !response.isEmpty {
                    voiceAssistant?.speak(response)
                }
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
        VStack(spacing: 4) {
            Image(systemName: "person.2")
                .font(.caption)
                .foregroundColor(.orange)
            
            // Stepper controls for servings
            HStack(spacing: 4) {
                // Decrease button
                Button(action: {
                    if currentServings > 1 {
                        onServingsChange(currentServings - 1)
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption)
                        .foregroundColor(currentServings > 1 ? .orange : .gray)
                }
                .disabled(currentServings <= 1)
                
                // Current servings display
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
                
                // Increase button
                Button(action: {
                    if currentServings < 50 {
                        onServingsChange(currentServings + 1)
                    }
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

// MARK: - Timer Card View

struct TimerCardView: View {
    @ObservedObject var timer: LocalTimer
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Timer status icon
            Image(systemName: statusIcon)
                .font(.title2)
                .foregroundColor(statusColor)
                .frame(width: 24)
            
            // Timer info
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(timer.formattedTime)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Progress indicator
            if timer.isActive || timer.status == .completed {
                CircularProgressView(
                    progress: timer.progress,
                    color: statusColor
                )
                .frame(width: 20, height: 20)
            }
            
            // Controls
            HStack(spacing: 8) {
                // Manual controls (for pending timers)
                if timer.status == .pending {
                    Button(action: {
                        timer.start()
                    }) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                } else if timer.status == .running {
                    Button(action: {
                        timer.pause()
                    }) {
                        Image(systemName: "pause.circle.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                    }
                } else if timer.status == .paused {
                    Button(action: {
                        timer.resume()
                    }) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                }
                
                // Delete button (always available)
                Button(action: {
                    onDelete()
                }) {
                    Image(systemName: "trash.circle.fill")
                        .font(.title3)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var statusIcon: String {
        switch timer.status {
        case .pending:
            return "clock"
        case .running:
            return "timer"
        case .paused:
            return "pause.circle"
        case .completed:
            return "checkmark.circle.fill"
        case .stopped:
            return "stop.circle"
        }
    }
    
    private var statusColor: Color {
        switch timer.status {
        case .pending:
            return .gray
        case .running:
            return .green
        case .paused:
            return .orange
        case .completed:
            return .blue
        case .stopped:
            return .red
        }
    }
}

// MARK: - Circular Progress View

struct CircularProgressView: View {
    let progress: Double
    let color: Color
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.3), lineWidth: 2)
            
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Add Timer View

struct AddTimerView: View {
    let onAdd: (String, Int) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var timerLabel = ""
    @State private var selectedMinutes = 5
    @State private var selectedSeconds = 0
    
    private let minuteOptions = Array(0...59)
    private let secondOptions = Array(0...59)
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Timer Label")
                        .font(.headline)
                    
                    TextField("e.g., Pasta, Chicken, etc.", text: $timerLabel)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duration")
                        .font(.headline)
                    
                    HStack {
                        // Minutes picker
                        VStack {
                            Text("Minutes")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Picker("Minutes", selection: $selectedMinutes) {
                                ForEach(minuteOptions, id: \.self) { minute in
                                    Text("\(minute)").tag(minute)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 80, height: 120)
                        }
                        
                        // Seconds picker
                        VStack {
                            Text("Seconds")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Picker("Seconds", selection: $selectedSeconds) {
                                ForEach(secondOptions, id: \.self) { second in
                                    Text("\(second)").tag(second)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 80, height: 120)
                        }
                        
                        Spacer()
                        
                        // Duration preview
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Duration")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(formattedDuration)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Add Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        addTimer()
                    }
                    .disabled(!isValid)
                    .fontWeight(.semibold)
                }
            }
        }
    }
    
    private var isValid: Bool {
        !timerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (selectedMinutes > 0 || selectedSeconds > 0)
    }
    
    private var totalMinutes: Int {
        let totalSeconds = selectedMinutes * 60 + selectedSeconds
        return max(1, (totalSeconds + 59) / 60) // Round up to nearest minute, minimum 1
    }
    
    private var formattedDuration: String {
        let totalSeconds = selectedMinutes * 60 + selectedSeconds
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        
        if minutes > 0 && seconds > 0 {
            return "\(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }
    
    private func addTimer() {
        let label = timerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        onAdd(label, totalMinutes)
        dismiss()
    }
}

#Preview {
    CookingSessionView()
        .environmentObject(CookingSessionManager())
        .environmentObject(VoiceAssistant())
        .environmentObject(RecipeManager())
}
