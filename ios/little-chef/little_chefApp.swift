//
//  little_chefApp.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

@main
struct little_chefApp: App {
    @StateObject private var recipeManager = RecipeManager()
    @StateObject private var preferencesManager = PreferencesManager()
    @StateObject private var cookingSessionManager: CookingSessionManager
    @StateObject private var voiceAssistant = VoiceAssistant()

    init() {
        let prefs = PreferencesManager()
        let timers = TimerManager()
        _preferencesManager = StateObject(wrappedValue: prefs)
        _cookingSessionManager = StateObject(wrappedValue: CookingSessionManager(preferencesManager: prefs, timerManager: timers))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recipeManager)
                .environmentObject(cookingSessionManager)
                .environmentObject(voiceAssistant)
                .environmentObject(preferencesManager)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        // Check if it's a .littlechef file
        guard url.pathExtension == "littlechef" else { return }

        // Post notification to trigger import flow
        NotificationCenter.default.post(
            name: .importRecipe,
            object: url
        )
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let importRecipe = Notification.Name("importRecipe")
}
