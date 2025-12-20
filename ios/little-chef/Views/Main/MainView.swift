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
    @State private var showingImportSheet = false
    @State private var recipeToImport: RecipeBase?
    @State private var importErrorMessage: String?
    @StateObject private var exportManager = RecipeExportManager()

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
            NavigationStack {
                ProfileSettingsView()
                    .environmentObject(cookingSessionManager)
                    .environmentObject(preferencesManager)
            }
            .tabItem {
                Image(systemName: "gearshape.fill")
                Text("Settings")
            }
            .tag(2)
        }
        .accentColor(.orange)
        .environment(\.selectedTab, $selectedTab)
        .onAppear {
            Task {
                await recipeManager.loadRecipes()
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            if let recipe = recipeToImport {
                ImportRecipeView(
                    recipeBase: recipe,
                    onImport: {
                        await importRecipe(recipe)
                    },
                    onCancel: {
                        showingImportSheet = false
                        recipeToImport = nil
                    }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importRecipe)) { notification in
            guard let url = notification.object as? URL else { return }
            handleRecipeImport(from: url)
        }
        .alert("Import Error", isPresented: .init(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("OK") {
                importErrorMessage = nil
            }
        } message: {
            Text(importErrorMessage ?? "Failed to import recipe")
        }
    }

    private func handleRecipeImport(from url: URL) {
        // Request access to security-scoped resource (needed for files from external sources)
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let recipe = try exportManager.importRecipe(from: url)
            recipeToImport = recipe
            showingImportSheet = true
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func importRecipe(_ recipe: RecipeBase) async -> Bool {
        // RecipeManager.createRecipe already reloads recipes after creation
        return await recipeManager.createRecipe(recipe)
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
                                subtitle: "LLM model, voice settings, TTS provider, dietary restrictions"
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
