//
//  InputAreaView.swift
//  little-chef
//

import SwiftUI
import BigBroKit

struct InputAreaView: View {
    @Binding var textInput: String
    @FocusState.Binding var isTextFieldFocused: Bool
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant
    @State private var isAnimating = false

    private var voiceSettings: LocalVoiceSettings? {
        cookingSessionManager.currentSession?.userPreferences.voiceSettings
    }

    /// Whether the paired Mac should run the whole spoken loop rather than the device.
    private var usesBigBroVoice: Bool {
        cookingSessionManager.canUseBigBroVoice(voiceSettings)
    }

    private var handsFreeActive: Bool {
        voiceAssistant.isHandsFreeMode || cookingSessionManager.isHandsFreeActive
    }

    /// The Mac's loop owns the microphone and the transcript for as long as it runs, so typing
    /// and push-to-talk are both out of bounds — a typed message mid-turn would interleave with
    /// a spoken one and leave the two histories describing different conversations.
    private var voiceOwnsInput: Bool {
        cookingSessionManager.isHandsFreeActive
    }

    private var isSpeaking: Bool {
        voiceAssistant.isSpeaking || cookingSessionManager.voicePhase == .speaking
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                // Hands-free mode toggle
                Button(action: {
                    isTextFieldFocused = false
                    toggleHandsFree()
                }) {
                    Image(systemName: handsFreeActive ? "ear.fill" : "ear")
                        .font(.title2)
                        .foregroundColor(handsFreeActive ? .green : .orange)
                        .scaleEffect(voiceAssistant.isWakeWordListening && isAnimating ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isAnimating)
                }
                .padding(12)
                .background(Circle().fill(handsFreeActive ? Color.green.opacity(0.2) : Color(.systemGray6)))
                // Ending a running loop stays available mid-answer — a spoken turn sets
                // `isLoading`, and disabling the only way out of it would trap the user in it.
                .disabled(!handsFreeActive && (!handsFreeAvailable || cookingSessionManager.isLoading))

                // Stop speaking button (replaces mic when speaking)
                if isSpeaking {
                    Button(action: {
                        voiceAssistant.stopSpeaking()
                        cookingSessionManager.stopSpeakingReply()
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
                    .disabled(!voiceAssistant.isAvailable || cookingSessionManager.isLoading || voiceOwnsInput)
                }

                // Text input
                TextField(voiceOwnsInput ? "Listening…" : "Ask about cooking...", text: $textInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isTextFieldFocused)
                    .submitLabel(.send)
                    .disabled(cookingSessionManager.isLoading || voiceOwnsInput)
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
                .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cookingSessionManager.isLoading || voiceOwnsInput)
            }
            .padding()

            // Hands-free status — the Mac's loop reports a phase, the on-device one a pair of
            // booleans, and they are different enough to be worth showing differently.
            if cookingSessionManager.isHandsFreeActive {
                BigBroVoiceStatusBar(
                    phase: cookingSessionManager.voicePhase,
                    level: cookingSessionManager.voiceLevel,
                    threshold: cookingSessionManager.voiceThreshold,
                    wakePhrase: CookingSessionManager.wakeWord.phrase,
                    onEnd: { cookingSessionManager.stopHandsFreeVoice() }
                )
            } else if voiceAssistant.isHandsFreeMode {
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

    /// The Mac's loop needs no on-device speech permission; the fallback does.
    private var handsFreeAvailable: Bool {
        usesBigBroVoice || voiceAssistant.isAvailable
    }

    private func toggleHandsFree() {
        if cookingSessionManager.isHandsFreeActive {
            cookingSessionManager.stopHandsFreeVoice()
        } else if voiceAssistant.isHandsFreeMode {
            voiceAssistant.stopHandsFreeMode()
        } else if usesBigBroVoice {
            voiceAssistant.stopSpeaking()   // the session brings its own player; don't share the route
            let speaks = voiceSettings?.autoSpeakResponses ?? true
            Task { await cookingSessionManager.startHandsFreeVoice(speaksReplies: speaks) }
        } else {
            startHandsFreeMode()
        }
    }

    private func sendTextQuery() {
        let query = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        voiceAssistant.stopSpeaking()
        textInput = ""
        isTextFieldFocused = false

        let shouldSpeak = voiceSettings?.autoSpeakResponses == true

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
        if let voiceSettings {
            voiceAssistant.updateVoiceSettings(voiceSettings)
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

// MARK: - BigBro Voice Status

/// What the Mac's loop is doing, and a live input level so it is obvious the microphone is
/// hearing something.
///
/// `armed` and `listening` are drawn differently on purpose: the microphone is open in both,
/// but only one of them is the user's turn, and a bar that conflates them is unusable.
private struct BigBroVoiceStatusBar: View {
    let phase: BigBroVoiceSession.Phase
    let level: Float
    let threshold: Float
    let wakePhrase: String
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(tint)

                Text(label)
                    .font(.caption)
                    .foregroundColor(tint)

                // Shown while armed too: a meter that vanishes when the assistant is merely
                // waiting for its name reads as a microphone that has stopped working.
                if phase == .listening || phase == .armed {
                    VoiceLevelMeter(level: level, threshold: threshold)
                }

                Spacer()

                Button("End", action: onEnd)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(tint.opacity(0.1))
    }

    private var label: String {
        switch phase {
        case .idle:         return "Voice off"
        case .preparing:    return "Getting ready…"
        case .armed:        return "Say \"\(wakePhrase)\""
        case .listening:    return "Listening — no need to say it again"
        case .transcribing: return "Heard you…"
        case .thinking:     return "Thinking"
        case .speaking:     return "Speaking — talk to interrupt"
        }
    }

    private var icon: String {
        switch phase {
        case .idle:         return "waveform.slash"
        case .preparing:    return "hourglass"
        case .armed:        return "ear.badge.waveform"
        case .listening:    return "ear.fill"
        case .transcribing: return "waveform"
        case .thinking:     return "brain"
        case .speaking:     return "speaker.wave.2.fill"
        }
    }

    private var tint: Color {
        switch phase {
        case .listening: return .green
        case .speaking:  return .blue
        case .idle:      return .secondary
        // Not green: armed is the state where talking does nothing, and colouring it the same
        // as "go ahead" is the one thing this bar exists to prevent.
        case .armed:     return .secondary
        default:         return .orange
        }
    }
}

/// Input level with the bar it has to clear marked on it.
///
/// The tick is what makes "it isn't hearing me" answerable: a meter that never moves means the
/// microphone is delivering nothing, one that moves but stays under the tick means it is
/// delivering plenty and the threshold sits above it. Opposite fixes, identical without it.
private struct VoiceLevelMeter: View {
    let level: Float
    let threshold: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > threshold ? Color.green : Color.secondary)
                    .frame(width: geo.size.width * CGFloat(clamped(level)))
                Rectangle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 1)
                    .offset(x: geo.size.width * CGFloat(clamped(threshold)))
            }
        }
        .frame(width: 60, height: 4)
        .animation(.linear(duration: 0.05), value: level)
    }

    private func clamped(_ value: Float) -> Float { max(0, min(1, value)) }
}
