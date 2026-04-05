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
                CookingSessionView()
            } else {
                mainTabView
            }
        }
        .environmentObject(recipeManager)
        .environment(\.selectedTab, $selectedTab)
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            RecipeListView()
                .tabItem {
                    Label("Recipes", systemImage: "book.fill")
                }
                .tag(0)

            CookingSessionView()
                .tabItem {
                    Label("Cook", systemImage: "flame.fill")
                }
                .tag(1)

            NavigationStack {
                ProfileSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(2)
        }
        .accentColor(.orange)
    }
}

#Preview {
    MainView()
        .environmentObject(LLMService.shared)
        .environmentObject(CookingSessionManager())
        .environmentObject(VoiceAssistant())
}
