//
//  ProfileSettingsView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI
import AVFoundation

struct ProfileSettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @State private var selectedLLMModel = "gpt-4.1"
    @State private var measurementSystem = "imperial"
    @State private var speechRate: Float = 0.5
    @State private var voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
    @State private var autoSpeakResponses = true
    @State private var elevenLabsEnabled = false
    @State private var elevenLabsVoiceName = "Rachel - calm"
    @State private var availableVoices: [ElevenLabsVoice] = []
    @State private var isLoadingVoices = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isLoading = false
    @State private var showingSuccess = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    // Available LLM models
    private let llmModels = [
        "gpt-5", "gpt-5-mini", "gpt-5-nano",
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"
    ]
    
    // Available iOS voices (simplified list)
    private let iosVoices = [
        ("com.apple.ttsbundle.Samantha-compact", "Samantha (English US)"),
        ("com.apple.ttsbundle.Alex-compact", "Alex (English US)"),
        ("com.apple.ttsbundle.Victoria-compact", "Victoria (English US)"),
        ("com.apple.ttsbundle.Daniel-compact", "Daniel (English UK)")
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
                Text("iOS Voice Settings")
            } footer: {
                Text("Configure the built-in iOS text-to-speech settings for voice responses.")
            }
            
            // ElevenLabs Settings
            Section {
                Toggle("Enable ElevenLabs TTS", isOn: $elevenLabsEnabled)
                    .onChange(of: elevenLabsEnabled) { enabled in
                        if enabled && availableVoices.isEmpty {
                            loadElevenLabsVoices()
                        }
                    }
                
                if elevenLabsEnabled {
                    if isLoadingVoices {
                        HStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                                .scaleEffect(0.8)
                            Text("Loading voices...")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("Voice", selection: $elevenLabsVoiceName) {
                            ForEach(availableVoices) { voice in
                                Text(voice.voiceName).tag(voice.voiceName)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        
                        if !availableVoices.isEmpty {
                            Button("Test Voice") {
                                testSelectedVoice()
                            }
                            .buttonStyle(BorderedButtonStyle())
                            .tint(.orange)
                        }
                    }
                }
            } header: {
                Text("ElevenLabs Voice Synthesis")
            } footer: {
                Text("ElevenLabs provides high-quality AI-generated voices using the latest eleven_flash_v2_5 model. Select a voice and test it before saving.")
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
                
                // Load voice settings
                let voiceSettings = preferences.voiceSettings
                speechRate = voiceSettings.speechRate
                voiceIdentifier = voiceSettings.voiceIdentifier
                autoSpeakResponses = voiceSettings.autoSpeakResponses
                
                // Load ElevenLabs settings
                let elevenLabs = voiceSettings.elevenlabs
                elevenLabsEnabled = elevenLabs.enabled
                elevenLabsVoiceName = elevenLabs.voiceName
            }
        } catch {
            print("Failed to load preferences from backend: \(error)")
            
            // Fallback to default values
            await MainActor.run {
                selectedLLMModel = "gpt-4.1"
                measurementSystem = "imperial"
                speechRate = 0.5
                voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
                autoSpeakResponses = true
                elevenLabsEnabled = false
                elevenLabsVoiceName = "Rachel - calm"
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
        
        // Create ElevenLabs settings
        let elevenLabsSettings = ElevenLabsSettings(
            enabled: elevenLabsEnabled,
            voiceName: elevenLabsVoiceName
        )
        
        // Create voice settings
        let voiceSettings = VoiceSettings(
            speechRate: speechRate,
            voiceIdentifier: voiceIdentifier,
            autoSpeakResponses: autoSpeakResponses,
            elevenlabs: elevenLabsSettings
        )
        
        // Create UserPreferences object
        let preferences = UserPreferences(
            llmModel: selectedLLMModel,
            measurementSystem: measurementSystem,
            dietaryRestrictions: [], // Empty for now - feature not implemented
            voiceSettings: voiceSettings
        )
        
        do {
            // Call the API directly to update preferences
            let _ = try await APIService.shared.updatePreferences(preferences)
            
            // If there's an active cooking session, update its preferences too
            await cookingSessionManager.updateSessionPreferences()
            
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
    
    private func loadElevenLabsVoices() {
        Task {
            await MainActor.run {
                isLoadingVoices = true
            }
            
            do {
                let voicesResponse = try await APIService.shared.getElevenLabsVoices()
                
                await MainActor.run {
                    availableVoices = voicesResponse.voices
                    isLoadingVoices = false
                    
                    // Set default voice if current selection is not available
                    if !availableVoices.contains(where: { $0.voiceName == elevenLabsVoiceName }) {
                        if let firstVoice = availableVoices.first {
                            elevenLabsVoiceName = firstVoice.voiceName
                        }
                    }
                }
            } catch {
                print("Failed to load ElevenLabs voices: \(error)")
                
                await MainActor.run {
                    isLoadingVoices = false
                    errorMessage = "Failed to load voices. Please try again."
                    showingError = true
                }
            }
        }
    }
    
    private func testSelectedVoice() {
        Task {
            do {
                let audioData = try await APIService.shared.testElevenLabsVoice(voiceName: elevenLabsVoiceName)
                
                // Play the audio using AVAudioPlayer
                await MainActor.run {
                    playTestAudio(data: audioData)
                }
            } catch {
                print("Failed to test voice: \(error)")
                
                await MainActor.run {
                    errorMessage = "Failed to test voice. Please try again."
                    showingError = true
                }
            }
        }
    }
    
    private func playTestAudio(data: Data) {
        print("Playing test audio: \(data.count) bytes")
        
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            print("Failed to play test audio: \(error)")
            errorMessage = "Failed to play test audio."
            showingError = true
        }
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
            .environmentObject(AuthManager())
    }
}
