//
//  little_chefApp.swift
//  little-chef
//
//  Updated for local-only operation (no backend authentication)
//

import SwiftUI
import SwiftData

@main
struct little_chefApp: App {
    @StateObject private var cookingSessionManager = CookingSessionManager()
    @StateObject private var voiceAssistant = VoiceAssistant()
    @StateObject private var llmService = MLXLLMService.shared

    // SwiftData container for local storage
    let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema([
                RecipeEntity.self,
                UserPreferencesEntity.self
            ])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cookingSessionManager)
                .environmentObject(voiceAssistant)
                .environmentObject(llmService)
                .modelContainer(modelContainer)
        }
    }
}
