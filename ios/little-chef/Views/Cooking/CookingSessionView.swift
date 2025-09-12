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
            .navigationTitle("Cook with LittleChef")
            .sheet(isPresented: $showingRecipeSelector) {
                RecipeSelectorView()
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
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with recipe info
            RecipeHeaderView()
            
            // Chat area
            ChatAreaView()
            
            // Input area
            InputAreaView(textInput: $textInput)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("End") {
                    showingEndSessionAlert = true
                }
                .foregroundColor(.red)
            }
        }
        .alert("End Cooking Session", isPresented: $showingEndSessionAlert) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) {
                cookingSessionManager.endCookingSession()
            }
        } message: {
            Text("Are you sure you want to end this cooking session?")
        }
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
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 12) {
                // Voice button
                Button(action: {
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
                        .foregroundColor(voiceAssistant.isListening ? .red : .orange)
                        .scaleEffect(voiceAssistant.isListening && isAnimating ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isAnimating)
                }
                .padding(12)
                .background(Circle().fill(Color(.systemGray6)))
                .disabled(!voiceAssistant.isAvailable || cookingSessionManager.isLoading)
                .onAppear {
                    if voiceAssistant.isListening {
                        isAnimating = true
                    }
                }
                .onChange(of: voiceAssistant.isListening) { listening in
                    isAnimating = listening
                }
                
                // Text input
                TextField("Ask about cooking...", text: $textInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
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
                        .foregroundColor(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .orange)
                }
                .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cookingSessionManager.isLoading)
            }
            .padding()
            
            // Voice recognition display
            if voiceAssistant.isListening && !voiceAssistant.recognizedText.isEmpty {
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
        }
    }
}

#Preview {
    CookingSessionView()
        .environmentObject(CookingSessionManager())
        .environmentObject(VoiceAssistant())
        .environmentObject(RecipeManager())
}
