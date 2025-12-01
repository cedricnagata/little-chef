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
    @EnvironmentObject var recipeManager: RecipeManager
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @EnvironmentObject var preferencesManager: PreferencesManager
    @State private var selectedTab = 0
    
    var body: some View {
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
            ProfileView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
                .tag(2)
                .environmentObject(cookingSessionManager)
                .environmentObject(preferencesManager)
        }
        .accentColor(.orange)
        .environment(\.selectedTab, $selectedTab)
        .onAppear {
            Task {
                await recipeManager.loadRecipes()
            }
        }
    }
}

// MARK: - Profile View

struct ProfileView: View {
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var preferencesManager: PreferencesManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // App Icon
                    VStack(spacing: 16) {
                        Image(systemName: "fork.knife.circle.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.orange)

                        Text("LittleChef")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Hands-Free Cooking Assistant")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    // Settings Options
                    VStack(spacing: 16) {
                        NavigationLink(destination: ProfileSettingsView()
                            .environmentObject(cookingSessionManager)
                            .environmentObject(preferencesManager)) {
                            SettingsOptionRow(
                                icon: "gearshape.fill",
                                title: "Preferences",
                                subtitle: "LLM model, voice settings, ElevenLabs, dietary restrictions"
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct SettingsOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

#Preview {
    MainView()
}
