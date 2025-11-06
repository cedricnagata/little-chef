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
    @EnvironmentObject var parsingService: MLXLLMService
    @EnvironmentObject var cookingService: MLXLLMService
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @StateObject private var recipeManager = RecipeManager()
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
                .environmentObject(parsingService)
            
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
                .environmentObject(cookingService)
            
            // Profile Tab
            ProfileView()
                .tabItem {
                    Image(systemName: "person.fill")
                    Text("Profile")
                }
                .tag(2)
                .environmentObject(cookingSessionManager)
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
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // App Info
                    VStack(spacing: 16) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.orange)

                        Text("LittleChef")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Local AI Cooking Assistant")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    // Settings Options
                    VStack(spacing: 16) {
                        NavigationLink(destination: SettingsView()) {
                            SettingsOptionRow(
                                icon: "gear.circle.fill",
                                title: "Settings",
                                subtitle: "Preferences, voice settings, dietary restrictions"
                            )
                        }
                        .buttonStyle(PlainButtonStyle())

                        // Delete Local Data Button
                        Button(action: {
                            showingDeleteAlert = true
                        }) {
                            HStack {
                                if isDeleting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .red))
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "trash.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.red)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Delete Local Data")
                                        .foregroundColor(.red)
                                        .font(.body)
                                    Text("Permanently delete all recipes and local data")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
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
                        .disabled(isDeleting)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Profile")
        }
        .alert("Delete Local Data", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteLocalData()
            }
        } message: {
            Text("Are you sure you want to permanently delete all your recipes and local data? This action cannot be undone.")
        }
    }

    private func deleteLocalData() {
        Task {
            isDeleting = true
            // TODO: Implement local data deletion via LocalDataManager
            print("Delete local data - to be implemented")
            isDeleting = false
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
        .environmentObject(MLXLLMService.parsingService)
        .environmentObject(MLXLLMService.cookingService)
        .environmentObject(CookingSessionManager())
        .environmentObject(VoiceAssistant())
}
