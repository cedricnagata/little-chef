//
//  ProfileSettingsView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct ProfileSettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var selectedLLMModel = "gpt-4.1"
    @State private var measurementSystem = "imperial"
    @State private var isLoading = false
    @State private var showingSuccess = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    // Available LLM models
    private let llmModels = [
        "gpt-5", "gpt-5-mini", "gpt-5-nano",
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"
    ]
    
    
    var body: some View {
        Form {
            // LLM Model Selection
            Section {
                Picker("LLM Model", selection: $selectedLLMModel) {
                    ForEach(llmModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            } header: {
                Text("AI Assistant")
            } footer: {
                Text("Choose which AI model to use for cooking assistance. GPT-5 models offer the latest capabilities.")
            }
            
            // Measurement System
            Section {
                Picker("Measurement System", selection: $measurementSystem) {
                    Text("Imperial (cups, oz, °F)").tag("imperial")
                    Text("Metric (ml, g, °C)").tag("metric")
                }
                .pickerStyle(SegmentedPickerStyle())
            } header: {
                Text("Measurements")
            }
            
            
            // Save Button
            Section {
                Button(action: savePreferences) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        }
                        Text("Save Preferences")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(isLoading)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Profile Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            loadCurrentPreferences()
        }
        .alert("Settings Saved", isPresented: $showingSuccess) {
            Button("OK") { }
        } message: {
            Text("Your preferences have been updated successfully.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }
    
    private func loadCurrentPreferences() {
        // Load preferences from backend to get the latest values
        Task {
            await loadPreferencesFromBackend()
        }
    }
    
    private func loadPreferencesFromBackend() async {
        guard authManager.isAuthenticated else { return }
        
        do {
            let preferences = try await APIService.shared.getPreferences()
            
            await MainActor.run {
                selectedLLMModel = preferences.llmModel
                measurementSystem = preferences.measurementSystem
            }
        } catch {
            print("Failed to load preferences from backend: \(error)")
            
            // Fallback to local user preferences if backend fails
            await MainActor.run {
                if let user = authManager.currentUser {
                    if let localPreferences = user.preferences as? [String: Any] {
                        selectedLLMModel = localPreferences["llm_model"] as? String ?? "gpt-4.1"
                        measurementSystem = localPreferences["measurement_system"] as? String ?? "imperial"
                    }
                }
            }
        }
    }
    
    private func savePreferences() {
        Task {
            await savePreferencesToBackend()
        }
    }
    
    private func savePreferencesToBackend() async {
        await MainActor.run {
            isLoading = true
            errorMessage = ""
        }
        
        // Create UserPreferences object
        let preferences = UserPreferences(
            llmModel: selectedLLMModel,
            measurementSystem: measurementSystem,
            dietaryRestrictions: [], // Empty for now - feature not implemented
            voiceSettings: [:] // Empty for now
        )
        
        do {
            // Call the AuthManager which will handle the API call and update the current user
            await authManager.updatePreferences(preferences)
            
            await MainActor.run {
                isLoading = false
                showingSuccess = true
            }
            
        } catch {
            print("Failed to save preferences: \(error)")
            
            await MainActor.run {
                isLoading = false
                errorMessage = "Failed to save preferences. Please try again."
                showingError = true
            }
        }
    }
}

#Preview {
    NavigationView {
        ProfileSettingsView()
            .environmentObject(AuthManager())
    }
}
