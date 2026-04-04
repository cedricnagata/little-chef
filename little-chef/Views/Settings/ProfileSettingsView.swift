//
//  ProfileSettingsView.swift
//  little-chef
//

import SwiftUI
import AVFoundation

struct ProfileSettingsView: View {
    @EnvironmentObject var llmService: LLMService

    @State private var measurementSystem = "imperial"
    @State private var dietaryRestrictions: [String] = []
    @State private var speechRate: Float = 0.5
    @State private var voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
    @State private var autoSpeakResponses = true
    @State private var isLoading = false
    @State private var showingSuccess = false
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false

    private let iosVoices = [
        ("com.apple.ttsbundle.Samantha-compact", "Samantha (English US)"),
        ("com.apple.ttsbundle.Alex-compact", "Alex (English US)"),
        ("com.apple.ttsbundle.Victoria-compact", "Victoria (English US)"),
        ("com.apple.ttsbundle.Daniel-compact", "Daniel (English UK)")
    ]

    var body: some View {
        Form {
            // MARK: - AI Model
            Section {
                HStack {
                    Text("Model")
                    Spacer()
                    Text("Bonsai 8B (1-bit)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Status")
                    Spacer()
                    if llmService.isLoaded {
                        Label("Loaded", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Not Loaded", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }

                if llmService.isLoaded {
                    Button("Unload Model") {
                        llmService.unloadModel()
                    }
                    .foregroundColor(.orange)
                } else {
                    Button("Download & Load Model") {
                        Task {
                            do {
                                try await llmService.preloadModel()
                            } catch {
                                print("Failed to load model: \(error)")
                            }
                        }
                    }
                }
            } header: {
                Text("AI Model")
            } footer: {
                Text("On-device model for recipe parsing and cooking assistance. Downloads and loads automatically on first use. Pre-load here to avoid wait times.")
            }

            // MARK: - Cooking Preferences
            Section {
                Picker("Measurement System", selection: $measurementSystem) {
                    Text("Imperial (cups, oz, °F)").tag("imperial")
                    Text("Metric (ml, g, °C)").tag("metric")
                }
                .pickerStyle(SegmentedPickerStyle())
            } header: {
                Text("Measurements")
            }

            Section {
                ForEach(dietaryRestrictions, id: \.self) { restriction in
                    HStack {
                        Text(restriction)
                        Spacer()
                        Button {
                            dietaryRestrictions.removeAll { $0 == restriction }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }

                NavigationLink("Add Restriction") {
                    DietaryRestrictionPicker(selectedRestrictions: $dietaryRestrictions)
                }
            } header: {
                Text("Dietary Restrictions")
            }

            // MARK: - Voice
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speech Rate")
                    HStack {
                        Text("Slow").font(.caption)
                        Slider(value: $speechRate, in: 0.1...2.0, step: 0.1)
                        Text("Fast").font(.caption)
                    }
                    Text("\(speechRate, specifier: "%.1f")x")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Picker("Voice", selection: $voiceIdentifier) {
                    ForEach(iosVoices, id: \.0) { voice in
                        Text(voice.1).tag(voice.0)
                    }
                }
                .pickerStyle(MenuPickerStyle())

                Toggle("Auto-speak responses", isOn: $autoSpeakResponses)
            } header: {
                Text("Voice")
            }

            // MARK: - Save
            Section {
                Button {
                    savePreferences()
                } label: {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Save Preferences")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isLoading)
            }

            // MARK: - Data Management
            Section {
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete All Data")
                    }
                }
                .disabled(isDeleting)
            } footer: {
                Text("Permanently deletes all recipes and resets preferences.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadPreferences() }
        .alert("Saved", isPresented: $showingSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your preferences have been saved.")
        }
        .alert("Delete All Data", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { deleteAllData() }
        } message: {
            Text("This will permanently delete all your recipes and reset preferences. This cannot be undone.")
        }
    }

    // MARK: - Data Operations

    private func loadPreferences() {
        Task {
            do {
                let dataManager = try LocalDataManager()
                let prefsEntity = try dataManager.fetchPreferences()
                let prefs = prefsEntity.toUserPreferences()

                await MainActor.run {
                    measurementSystem = prefs.measurementSystem
                    dietaryRestrictions = prefs.dietaryRestrictions
                    speechRate = prefs.voiceSettings.speechRate
                    voiceIdentifier = prefs.voiceSettings.voiceIdentifier
                    autoSpeakResponses = prefs.voiceSettings.autoSpeakResponses
                }
            } catch {
                print("Failed to load preferences: \(error)")
            }
        }
    }

    private func savePreferences() {
        isLoading = true
        Task {
            do {
                let dataManager = try LocalDataManager()
                try dataManager.updatePreferences(
                    measurementSystem: measurementSystem,
                    dietaryRestrictions: dietaryRestrictions,
                    speechRate: speechRate,
                    voiceIdentifier: voiceIdentifier,
                    autoSpeakResponses: autoSpeakResponses
                )
                await MainActor.run {
                    isLoading = false
                    showingSuccess = true
                }
            } catch {
                print("Failed to save preferences: \(error)")
                await MainActor.run { isLoading = false }
            }
        }
    }

    private func deleteAllData() {
        isDeleting = true
        Task {
            do {
                let dataManager = try LocalDataManager()
                try dataManager.deleteAllRecipes()
                try dataManager.resetPreferences()
                await MainActor.run {
                    isDeleting = false
                    loadPreferences()
                }
            } catch {
                print("Failed to delete data: \(error)")
                await MainActor.run { isDeleting = false }
            }
        }
    }
}

// MARK: - Dietary Restriction Picker

struct DietaryRestrictionPicker: View {
    @Binding var selectedRestrictions: [String]
    @Environment(\.dismiss) private var dismiss

    private let commonRestrictions = [
        "Vegetarian", "Vegan", "Gluten-Free", "Dairy-Free",
        "Nut-Free", "Shellfish-Free", "Kosher", "Halal",
        "Low-Carb", "Keto", "Paleo"
    ]

    var body: some View {
        List {
            ForEach(commonRestrictions, id: \.self) { restriction in
                Button {
                    if !selectedRestrictions.contains(restriction) {
                        selectedRestrictions.append(restriction)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Text(restriction)
                        Spacer()
                        if selectedRestrictions.contains(restriction) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.orange)
                        }
                    }
                }
                .foregroundColor(.primary)
            }
        }
        .navigationTitle("Add Restriction")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
            .environmentObject(LLMService.shared)
    }
}
