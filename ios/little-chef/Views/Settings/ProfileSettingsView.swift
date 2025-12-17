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
    @State private var ttsProvider: TTSProvider = .polly
    @State private var pollyVoice = "Joanna"
    @State private var speechRate: Float = 0.5
    @State private var voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
    @State private var autoSpeakResponses = true

    // Available LLM models
    private let llmModels = [
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"
    ]

    // Available TTS providers
    private let ttsProviders: [(TTSProvider, String)] = [
        (.polly, "AWS Polly (Server)"),
        (.device, "iOS Native")
    ]

    // Available Polly voices
    private let pollyVoices = [
        "Joanna",    // US English, Female, Neural
        "Matthew",   // US English, Male, Neural
        "Salli",     // US English, Female, Neural
        "Kendra",    // US English, Female, Neural
        "Kimberly",  // US English, Female, Neural
        "Ivy",       // US English, Female, Neural
        "Joey",      // US English, Male, Neural
        "Justin",    // US English, Male, Neural
        "Amy",       // British English, Female, Neural
        "Emma"       // British English, Female, Neural
    ]

    // Available iOS voices (simplified list)
    private let iosVoices = [
        ("com.apple.ttsbundle.Samantha-compact", "Samantha (English US)"),
        ("com.apple.ttsbundle.Alex-compact", "Alex (English US)"),
        ("com.apple.ttsbundle.Victoria-compact", "Victoria (English US)"),
        ("com.apple.ttsbundle.Daniel-compact", "Daniel (English UK)")
    ]

    // Legacy - kept for compatibility
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
                Toggle("Auto-speak Responses", isOn: $autoSpeakResponses)

                // Only show TTS options if auto-speak is enabled
                if autoSpeakResponses {
                    Picker("TTS Provider", selection: $ttsProvider) {
                        ForEach(ttsProviders, id: \.0) { provider, label in
                            Text(label).tag(provider)
                        }
                    }

                    // Show Polly voice selection when Polly is selected
                    if ttsProvider == .polly {
                        Picker("Polly Voice", selection: $pollyVoice) {
                            ForEach(pollyVoices, id: \.self) { voice in
                                Text(voice).tag(voice)
                            }
                        }
                    }

                    // Show iOS voice selection when device is selected
                    if ttsProvider == .device {
                        Picker("iOS Voice", selection: $voiceIdentifier) {
                            ForEach(iosVoices, id: \.0) { identifier, label in
                                Text(label).tag(identifier)
                            }
                        }

                        Slider(value: Binding(
                            get: { Double(speechRate) },
                            set: { speechRate = Float($0) }
                        ), in: 0.5...2.0, step: 0.1)

                        Text("Speech Rate: \(String(format: "%.1f", speechRate))x")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Voice Settings")
            } footer: {
                if !autoSpeakResponses {
                    Text("Enable auto-speak to have responses read aloud while cooking")
                } else if ttsProvider == .polly {
                    Text("AWS Polly provides natural-sounding neural voices from the cloud")
                } else {
                    Text("Uses your device's built-in text-to-speech")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadPreferences()
        }
        .onChange(of: selectedLLMModel) { _, _ in
            savePreferences()
        }
        .onChange(of: measurementSystem) { _, _ in
            savePreferences()
        }
        .onChange(of: ttsProvider) { _, _ in
            savePreferences()
        }
        .onChange(of: pollyVoice) { _, _ in
            savePreferences()
        }
        .onChange(of: speechRate) { _, _ in
            savePreferences()
        }
        .onChange(of: voiceIdentifier) { _, _ in
            savePreferences()
        }
        .onChange(of: autoSpeakResponses) { _, _ in
            savePreferences()
        }
    }

    private func loadPreferences() {
        let prefs = preferencesManager.preferences
        selectedLLMModel = prefs.llmModel
        measurementSystem = prefs.measurementSystem

        let voiceSettings = prefs.voiceSettings
        ttsProvider = voiceSettings.ttsProvider
        pollyVoice = voiceSettings.voiceId ?? "Joanna"
        speechRate = voiceSettings.speechRate
        voiceIdentifier = voiceSettings.voiceIdentifier
        autoSpeakResponses = voiceSettings.autoSpeakResponses
    }

    private func savePreferences() {
        let voiceSettings = VoiceSettings(
            ttsProvider: ttsProvider,
            voiceId: ttsProvider == .polly ? pollyVoice : nil,
            speechRate: speechRate,
            voiceIdentifier: voiceIdentifier,
            autoSpeakResponses: autoSpeakResponses
        )

        let preferences = UserPreferences(
            llmModel: selectedLLMModel,
            measurementSystem: measurementSystem,
            dietaryRestrictions: [], // Keep empty array for backward compatibility
            voiceSettings: voiceSettings
        )

        preferencesManager.updatePreferences(preferences)
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
            .environmentObject(PreferencesManager())
    }
}
