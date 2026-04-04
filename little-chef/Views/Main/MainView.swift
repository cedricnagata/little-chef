//
//  MainView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

// MARK: - Tab Selection Environment Key
struct TabSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<Int> = .constant(0)
}

extension EnvironmentValues {
    var selectedTab: Binding<Int> {
        get { self[TabSelectionKey.self] }
        set { self[TabSelectionKey.self] = newValue }
    }
}

struct MainView: View {
    @EnvironmentObject var llmService: LLMService
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @StateObject private var recipeManager = RecipeManager()
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if cookingSessionManager.currentSession != nil {
                // Show cooking session without TabView
                CookingSessionView()
                    .environmentObject(recipeManager)
                    .environmentObject(cookingSessionManager)
                    .environmentObject(voiceAssistant)
            } else {
                // Show normal TabView when not in cooking session
                mainTabView
            }
        }
        .onAppear {
            Task {
                await recipeManager.loadRecipes()
            }
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            // Recipes Tab
            RecipeListView()
                .tabItem {
                    Image(systemName: "book.fill")
                    Text("Recipes")
                }
                .tag(0)
                .environmentObject(recipeManager)
                .environmentObject(cookingSessionManager)
                .environmentObject(llmService)
            
            // Cooking Tab
            CookingSessionView()
                .tabItem {
                    Image(systemName: "flame.fill")
                    Text("Cook")
                }
                .tag(1)
                .environmentObject(recipeManager)
                .environmentObject(cookingSessionManager)
                .environmentObject(voiceAssistant)
            
            // Settings Tab
            SettingsTab()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
                .tag(2)
        }
        .accentColor(.orange)
        .environment(\.selectedTab, $selectedTab)
    }
}

// MARK: - Settings Tab

struct SettingsTab: View {
    var body: some View {
        NavigationStack {
            ProfileSettingsView()
        }
    }
}

#Preview {
    MainView()
        .environmentObject(LLMService.shared)
        .environmentObject(CookingSessionManager())
        .environmentObject(VoiceAssistant())
}
