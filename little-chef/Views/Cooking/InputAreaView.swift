//
//  InputAreaView.swift
//  little-chef
//

import SwiftUI

struct InputAreaView: View {
    @Binding var textInput: String
    @FocusState.Binding var isTextFieldFocused: Bool
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                // Hands-free mode toggle
                Button(action: {
                    isTextFieldFocused = false
                    if voiceAssistant.isHandsFreeMode {
                        voiceAssistant.stopHandsFreeMode()
                    } else {
                        startHandsFreeMode()
                    }
                }) {
                    Image(systemName: voiceAssistant.isHandsFreeMode ? "ear.fill" : "ear")
                        .font(.title2)
                        .foregroundColor(voiceAssistant.isHandsFreeMode ? .green : .orange)
                        .scaleEffect(voiceAssistant.isWakeWordListening && isAnimating ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isAnimating)
                }
                .padding(12)
                .background(Circle().fill(voiceAssistant.isHandsFreeMode ? Color.green.opacity(0.2) : Color(.systemGray6)))
                .disabled(!voiceAssistant.isAvailable || cookingSessionManager.isLoading)

                // Stop speaking button (replaces mic when speaking)
                if voiceAssistant.isSpeaking {
                    Button(action: {
                        voiceAssistant.stopSpeaking()
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                    .padding(12)
                    .background(Circle().fill(Color.red.opacity(0.15)))
                } else {
                    // Voice button
                    Button(action: {
                        isTextFieldFocused = false
                        voiceAssistant.stopSpeaking()
                        if voiceAssistant.isListening {
                            voiceAssistant.stopListening()
                            if voiceAssistant.hasRecognizedText() {
                                sendVoiceQuery()
                            }
                        } else {
                            voiceAssistant.startListening()
                        }
                    }) {
                        Image(systemName: voiceAssistant.isListening ? "mic.fill" : "mic")
                            .font(.title2)
                            .foregroundColor(voiceAssistant.isListening ? .red : .orange)
                            .scaleEffect(voiceAssistant.isListening && isAnimating ? 1.2 : 1.0)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isAnimating)
                    }
                    .padding(12)
                    .background(Circle().fill(Color(.systemGray6)))
                    .disabled(!voiceAssistant.isAvailable || cookingSessionManager.isLoading)
                }

                // Text input
                TextField("Ask about cooking...", text: $textInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isTextFieldFocused)
                    .submitLabel(.send)
                    .disabled(cookingSessionManager.isLoading)
                    .onSubmit {
                        sendTextQuery()
                    }
                    .onAppear {
                        if voiceAssistant.isListening {
                            isAnimating = true
                        }
                    }
                    .onChange(of: voiceAssistant.isListening) { _, newValue in
                        isAnimating = newValue
                    }
                    .onChange(of: voiceAssistant.isWakeWordListening) { _, newValue in
                        isAnimating = newValue
                    }

                // Send button
                Button(action: {
                    sendTextQuery()
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .orange)
                }
                .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cookingSessionManager.isLoading)
            }
            .padding()

            // Hands-free mode status
            if voiceAssistant.isHandsFreeMode {
                VStack {
                    Divider()
                    HStack {
                        Image(systemName: voiceAssistant.isWakeWordListening ? "ear.fill" : "waveform")
                            .foregroundColor(.green)

                        if voiceAssistant.isListening {
                            Text("Listening: \(voiceAssistant.recognizedText.isEmpty ? "Speak now..." : voiceAssistant.recognizedText)")
                                .foregroundColor(.primary)
                        } else if voiceAssistant.isWakeWordListening {
                            Text("Say \"Hey LittleChef\" to start...")
                                .foregroundColor(.secondary)
                        } else {
                            Text("Hands-free mode active")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color.green.opacity(0.1))
            }

            // Voice recognition display (for manual mode)
            else if voiceAssistant.isListening && !voiceAssistant.recognizedText.isEmpty {
                VStack {
                    Divider()
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundColor(.orange)
                        Text(voiceAssistant.recognizedText)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemGray6))
            }

            // Error display
            if let error = cookingSessionManager.error {
                VStack {
                    Divider()
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                        Spacer()
                        Button("Dismiss") {
                            cookingSessionManager.error = nil
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemGray6))
            }
        }
    }

    private func sendTextQuery() {
        let query = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        voiceAssistant.stopSpeaking()
        textInput = ""
        isTextFieldFocused = false

        let shouldSpeak = cookingSessionManager.currentSession?.userPreferences.voiceSettings.autoSpeakResponses == true

        Task {
            await cookingSessionManager.sendQueryStreaming(query) { sentence in
                if shouldSpeak {
                    voiceAssistant.enqueueSentence(sentence)
                }
            }
            if shouldSpeak {
                voiceAssistant.flushSentenceQueue()
            }
        }
    }

    private func sendVoiceQuery() {
        let query = voiceAssistant.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        voiceAssistant.stopSpeaking()
        voiceAssistant.clearRecognizedText()

        Task {
            await cookingSessionManager.sendQueryStreaming(query) { sentence in
                voiceAssistant.enqueueSentence(sentence)
            }
            voiceAssistant.flushSentenceQueue()
        }
    }

    private func startHandsFreeMode() {
        if let session = cookingSessionManager.currentSession {
            voiceAssistant.updateVoiceSettings(session.userPreferences.voiceSettings)
        }

        voiceAssistant.onWakeWordDetected = { [weak voiceAssistant] in
            voiceAssistant?.stopSpeaking()
        }

        voiceAssistant.onVoiceQueryReady = { [weak cookingSessionManager, weak voiceAssistant] query in
            Task {
                await cookingSessionManager?.sendQueryStreaming(query) { sentence in
                    voiceAssistant?.enqueueSentence(sentence)
                }
                voiceAssistant?.flushSentenceQueue()
            }
        }

        voiceAssistant.startHandsFreeMode()
    }
}
