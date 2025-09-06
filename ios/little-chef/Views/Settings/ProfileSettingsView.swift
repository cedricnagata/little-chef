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
    @State private var dietaryRestrictions: [String] = []
    @State private var newRestriction = ""
    @State private var isLoading = false
    @State private var showingSuccess = false
    
    // Available LLM models
    private let llmModels = [
        "gpt-5", "gpt-5-mini", "gpt-5-nano",
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"
    ]
    
    // Common dietary restrictions
    private let commonRestrictions = [
        "Vegetarian", "Vegan", "Gluten-Free", "Dairy-Free", 
        "Nut-Free", "Keto", "Paleo", "Low-Carb", "Halal", "Kosher"
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
            
            // Dietary Restrictions
            Section {
                // Current restrictions
                ForEach(dietaryRestrictions, id: \.self) { restriction in
                    HStack {
                        Text(restriction)
                        Spacer()
                        Button("Remove") {
                            dietaryRestrictions.removeAll { $0 == restriction }
                        }
                        .foregroundColor(.red)
                        .font(.caption)
                    }
                }
                
                // Add new restriction
                HStack {
                    TextField("Add dietary restriction", text: $newRestriction)
                    Button("Add") {
                        if !newRestriction.isEmpty && !dietaryRestrictions.contains(newRestriction) {
                            dietaryRestrictions.append(newRestriction)
                            newRestriction = ""
                        }
                    }
                    .disabled(newRestriction.isEmpty)
                }
                
                // Quick add common restrictions
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    ForEach(commonRestrictions, id: \.self) { restriction in
                        if !dietaryRestrictions.contains(restriction) {
                            Button(restriction) {
                                dietaryRestrictions.append(restriction)
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.1))
                            .foregroundColor(.orange)
                            .cornerRadius(16)
                        }
                    }
                }
            } header: {
                Text("Dietary Restrictions")
            } footer: {
                Text("Your dietary restrictions help the AI provide better recipe suggestions and substitutions.")
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
    }
    
    private func loadCurrentPreferences() {
        // Load current user preferences
        if let user = authManager.currentUser {
            if let preferences = user.preferences as? [String: Any] {
                selectedLLMModel = preferences["llm_model"] as? String ?? "gpt-4.1"
                measurementSystem = preferences["measurement_system"] as? String ?? "imperial"
                dietaryRestrictions = preferences["dietary_restrictions"] as? [String] ?? []
            }
        }
    }
    
    private func savePreferences() {
        isLoading = true
        
        // TODO: Implement API call to save preferences
        // For now, just simulate saving
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isLoading = false
            showingSuccess = true
            
            // Update local user preferences (this would normally come from the API response)
            if var user = authManager.currentUser {
                var preferences = user.preferences as? [String: Any] ?? [:]
                preferences["llm_model"] = selectedLLMModel
                preferences["measurement_system"] = measurementSystem
                preferences["dietary_restrictions"] = dietaryRestrictions
                
                // Note: In real implementation, this would be updated via API call
                // and the authManager would be updated with the response
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
