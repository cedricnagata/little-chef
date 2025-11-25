//
//  ProfileSettingsView.swift
//  little-chef
//
//  Updated for serverless - uses local PreferencesManager
//

import SwiftUI
import AVFoundation

struct ProfileSettingsView: View {
    @EnvironmentObject var preferencesManager: PreferencesManager
    @State private var selectedLLMModel = "gpt-4.1-mini"
    @State private var measurementSystem = "imperial"
    @State private var speechRate: Float = 0.5
    @State private var voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
    @State private var autoSpeakResponses = true
    @State private var elevenLabsEnabled = false
    @State private var elevenLabsVoiceName = "Rachel - calm"
    @State private var dietaryRestrictions: [String] = []
    @State private var newRestriction = ""
    @State private var showingSuccess = false

    // Available LLM models
    private let llmModels = [
        "gpt-4.1", "gpt-4.1-mini"
    ]

    // Available iOS voices (simplified list)
    private let iosVoices = [
        ("com.apple.ttsbundle.Samantha-compact", "Samantha (English US)"),
        ("com.apple.ttsbundle.Alex-compact", "Alex (English US)"),
        ("com.apple.ttsbundle.Victoria-compact", "Victoria (English US)"),
        ("com.apple.ttsbundle.Daniel-compact", "Daniel (English UK)")
    ]

    // Available ElevenLabs voices
    private let elevenLabsVoices = [
        "Rachel - calm",
        "Josh - intelligent",
        "Arnold - crisp",
        "Adam - storytelling",
        "Antoni - well-rounded",
        "Domi - nurturing",
        "Elli - emotional",
        "Freya - conversational",
        "Grace - american-southern",
        "Sam - storytelling",
        "Glinda - warm",
        "Jessica - expressive",
        "Nicole - whispering",
        "Sarah - conversational",
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
            } header: {
                Text("AI Model")
            } footer: {
                Text("Select which OpenAI model to use for cooking assistance")
            }

            // Measurement System
            Section {
                Picker("System", selection: $measurementSystem) {
                    Text("Imperial").tag("imperial")
                    Text("Metric").tag("metric")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Measurement System")
            }

            // Voice Settings
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speech Rate: \(speechRate, specifier: "%.1f")x")
                        .font(.subheadline)
                    Slider(value: $speechRate, in: 0.1...2.0, step: 0.1)
                }

                Picker("Voice", selection: $voiceIdentifier) {
                    ForEach(iosVoices, id: \.0) { voice in
                        Text(voice.1).tag(voice.0)
                    }
                }

                Toggle("Auto-speak Responses", isOn: $autoSpeakResponses)
            } header: {
                Text("iOS Native Voice")
            }

            // ElevenLabs Settings
            Section {
                Toggle("Enable ElevenLabs", isOn: $elevenLabsEnabled)

                if elevenLabsEnabled {
                    Picker("Voice", selection: $elevenLabsVoiceName) {
                        ForEach(elevenLabsVoices, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                    }
                }
            } header: {
                Text("ElevenLabs Premium TTS")
            } footer: {
                Text("When enabled, uses ElevenLabs for more natural-sounding voice synthesis")
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
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }

                HStack {
                    TextField("Add restriction", text: $newRestriction)
                    Button(action: addRestriction) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                    }
                    .disabled(newRestriction.isEmpty)
                }
            } header: {
                Text("Dietary Restrictions")
            } footer: {
                Text("e.g., vegetarian, vegan, gluten-free, dairy-free")
            }
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    savePreferences()
                }
            }
        }
        .alert("Saved", isPresented: $showingSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your preferences have been saved successfully")
        }
        .onAppear {
            loadPreferences()
        }
    }

    private func loadPreferences() {
        let prefs = preferencesManager.preferences
        selectedLLMModel = prefs.llmModel
        measurementSystem = prefs.measurementSystem
        dietaryRestrictions = prefs.dietaryRestrictions

        let voiceSettings = prefs.voiceSettings
        speechRate = voiceSettings.speechRate
        voiceIdentifier = voiceSettings.voiceIdentifier
        autoSpeakResponses = voiceSettings.autoSpeakResponses

        elevenLabsEnabled = voiceSettings.elevenlabs.enabled
        elevenLabsVoiceName = voiceSettings.elevenlabs.voiceName
    }

    private func savePreferences() {
        let elevenLabsSettings = ElevenLabsSettings(
            enabled: elevenLabsEnabled,
            voiceName: elevenLabsVoiceName
        )

        let voiceSettings = VoiceSettings(
            speechRate: speechRate,
            voiceIdentifier: voiceIdentifier,
            autoSpeakResponses: autoSpeakResponses,
            elevenlabs: elevenLabsSettings
        )

        let preferences = UserPreferences(
            llmModel: selectedLLMModel,
            measurementSystem: measurementSystem,
            dietaryRestrictions: dietaryRestrictions,
            voiceSettings: voiceSettings
        )

        preferencesManager.updatePreferences(preferences)
        showingSuccess = true
    }

    private func addRestriction() {
        let trimmed = newRestriction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !dietaryRestrictions.contains(trimmed) else { return }
        dietaryRestrictions.append(trimmed)
        newRestriction = ""
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
            .environmentObject(PreferencesManager())
    }
}
