//
//  little_chefApp.swift
//  little-chef
//
//  Local-only operation with on-device Bonsai 8B model
//

import SwiftUI
import SwiftData

@main
struct little_chefApp: App {
    @StateObject private var llmService = LLMService.shared
    @StateObject private var voiceAssistant = VoiceAssistant()
    @StateObject private var cookingSessionManager: CookingSessionManager

    // SwiftData container for local storage
    let dataModelContainer: SwiftData.ModelContainer

    init() {
        let llm = LLMService.shared
        _llmService = StateObject(wrappedValue: llm)
        _voiceAssistant = StateObject(wrappedValue: VoiceAssistant())
        _cookingSessionManager = StateObject(wrappedValue: CookingSessionManager(llmService: llm))

        do {
            let schema = Schema([
                RecipeEntity.self,
                UserPreferencesEntity.self
            ])
            let swiftDataConfig = SwiftData.ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            dataModelContainer = try SwiftData.ModelContainer(for: schema, configurations: [swiftDataConfig])
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
                .modelContainer(dataModelContainer)
        }
    }
}
