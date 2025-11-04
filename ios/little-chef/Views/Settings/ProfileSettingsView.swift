//
//  ProfileSettingsView.swift
//  little-chef
//
//  Simplified for local-only operation (no LLM selection, no ElevenLabs)
//

import SwiftUI
import AVFoundation

struct ProfileSettingsView: View {
    @State private var measurementSystem = "imperial"
    @State private var dietaryRestrictions: [String] = []
    @State private var speechRate: Float = 0.5
    @State private var voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
    @State private var autoSpeakResponses = true
    @State private var isLoading = false
    @State private var showingSuccess = false

    // Available iOS voices
    private let iosVoices = [
        ("com.apple.ttsbundle.Samantha-compact", "Samantha (English US)"),
        ("com.apple.ttsbundle.Alex-compact", "Alex (English US)"),
        ("com.apple.ttsbundle.Victoria-compact", "Victoria (English US)"),
        ("com.apple.ttsbundle.Daniel-compact", "Daniel (English UK)")
    ]

    var body: some View {
        Form {
            // AI Model Info (Read-only)
            Section {
                HStack {
                    Text("AI Model")
                    Spacer()
                    Text("Llama 3.2 3B")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("AI Assistant")
            } footer: {
                Text("Using local on-device Llama 3.2 3B model for privacy and offline capability.")
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
                ForEach(dietaryRestrictions, id: \.self) { restriction in
                    HStack {
                        Text(restriction)
                        Spacer()
                        Button(action: {
                            dietaryRestrictions.removeAll { $0 == restriction }
                        }) {
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
            } footer: {
                Text("Specify any dietary restrictions or preferences.")
            }

            // Voice Settings
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speech Rate")
                    HStack {
                        Text("Slow")
                            .font(.caption)
                        Slider(value: $speechRate, in: 0.1...2.0, step: 0.1)
                        Text("Fast")
                            .font(.caption)
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
                Text("Voice Settings")
            } footer: {
                Text("Configure text-to-speech settings for voice responses.")
            }

            // Save Button
            Section {
                Button(action: {
                    savePreferences()
                }) {
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
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            loadPreferences()
        }
        .alert("Saved", isPresented: $showingSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your preferences have been saved successfully.")
        }
    }

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
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Dietary Restriction Picker

struct DietaryRestrictionPicker: View {
    @Binding var selectedRestrictions: [String]
    @Environment(\.dismiss) private var dismiss

    private let commonRestrictions = [
        "Vegetarian",
        "Vegan",
        "Gluten-Free",
        "Dairy-Free",
        "Nut-Free",
        "Shellfish-Free",
        "Kosher",
        "Halal",
        "Low-Carb",
        "Keto",
        "Paleo"
    ]

    var body: some View {
        List {
            ForEach(commonRestrictions, id: \.self) { restriction in
                Button(action: {
                    if !selectedRestrictions.contains(restriction) {
                        selectedRestrictions.append(restriction)
                        dismiss()
                    }
                }) {
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
    }
}
