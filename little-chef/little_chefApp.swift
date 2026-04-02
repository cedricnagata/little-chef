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
    @StateObject private var parsingService = MLXLLMService.parsingService
    @StateObject private var cookingService = MLXLLMService.cookingService
    @StateObject private var voiceAssistant = VoiceAssistant()

    // Initialize CookingSessionManager with the cooking service instance
    @StateObject private var cookingSessionManager: CookingSessionManager

    // SwiftData container for local storage
    let modelContainer: ModelContainer

    init() {
        // Initialize services first
        let cooking = MLXLLMService.cookingService
        _cookingService = StateObject(wrappedValue: cooking)
        _parsingService = StateObject(wrappedValue: MLXLLMService.parsingService)
        _voiceAssistant = StateObject(wrappedValue: VoiceAssistant())

        // Initialize CookingSessionManager with the same cooking service instance
        _cookingSessionManager = StateObject(wrappedValue: CookingSessionManager(cookingService: cooking))

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
                .environmentObject(parsingService)
                .environmentObject(cookingService)
                .modelContainer(modelContainer)
        }
    }
}
