//
//  CookingSessionManager.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/12/25.
//

import Foundation
import SwiftUI

@MainActor
class CookingSessionManager: ObservableObject {
    @Published var currentSession: CookingSession?
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastResponse: String = ""
    
    private let apiService = APIService.shared
    
    // MARK: - Session Management
    
    func startCookingSession(with recipe: Recipe) {
        let recipeBase = RecipeBase(from: recipe)
        
        // Always create fresh user preferences with gpt-5-mini (not reusing old session data)
        let userPreferences = UserPreferencesDetailed()
        
        currentSession = CookingSession(recipe: recipeBase, userPreferences: userPreferences)
        error = nil
        print("🔵 Started new cooking session with model: \(userPreferences.llmModel)")
    }
    
    func endCookingSession() {
        currentSession = nil
        lastResponse = ""
        error = nil
    }
    
    // MARK: - Agent Communication
    
    func sendQuery(_ query: String) async {
        guard var session = currentSession else {
            error = "No active cooking session"
            return
        }
        
        // Clear any previous errors
        error = nil
        isLoading = true
        
        do {
            let response = try await apiService.sendAgentQuery(
                cookingSession: session,
                query: query
            )
            
            // Update the session with the response
            currentSession = response.updatedSession
            lastResponse = response.response
            
        } catch {
            self.error = "Failed to get response: \(error.localizedDescription)"
            print("Agent query error: \(error)")
        }
        
        isLoading = false
    }
    
    // MARK: - Voice Interaction Helpers
    
    func getLastMessage() -> String {
        guard let session = currentSession,
              let lastMessage = session.conversationHistory.last else {
            return ""
        }
        return lastMessage.content
    }
    
    func hasActiveSession() -> Bool {
        return currentSession != nil
    }
    
    func getRecipeTitle() -> String {
        return currentSession?.recipe.title ?? ""
    }
    
    func getConversationHistory() -> [Message] {
        return currentSession?.conversationHistory ?? []
    }
    
    // MARK: - Timer Management (Placeholder for future implementation)
    
    func addTimer(duration: TimeInterval, label: String) {
        // TODO: Implement timer functionality
        print("Timer added: \(label) for \(duration) seconds")
    }
    
    func getActiveTimers() -> [Timer] {
        return currentSession?.activeTimers ?? []
    }
}
