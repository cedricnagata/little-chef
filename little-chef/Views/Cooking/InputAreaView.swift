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

    /// True while voice input owns the input bar. Typing and sending are blocked so a
    /// transcript can't land mid-edit, and a typed question can't interleave with a spoken one.
    private var voiceBusy: Bool {
        voiceAssistant.isRecording || voiceAssistant.isTranscribing || voiceAssistant.isHandsFree
    }

    private var canSend: Bool {
        !textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cookingSessionManager.isLoading
            && !voiceBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                HandsFreeButton(textInputFocused: $isTextFieldFocused)
                MicButton(textInput: $textInput, textInputFocused: $isTextFieldFocused)

                TextField("Ask about cooking...", text: $textInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isTextFieldFocused)
                    .submitLabel(.send)
                    .disabled(cookingSessionManager.isLoading || voiceBusy)
                    .onSubmit { sendTextQuery() }

                Button(action: sendTextQuery) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(canSend ? .orange : .gray)
                }
                .disabled(!canSend)
            }
            .padding()

            if voiceAssistant.isHandsFree {
                VoiceStatusBar()
            }

            if let voiceError = voiceAssistant.error {
                bannerRow(
                    icon: "exclamationmark.triangle",
                    tint: .orange,
                    text: voiceError,
                    dismiss: { voiceAssistant.error = nil }
                )
            }

            if let error = cookingSessionManager.error {
                bannerRow(
                    icon: "exclamationmark.triangle",
                    tint: .red,
                    text: error,
                    dismiss: { cookingSessionManager.error = nil }
                )
            }
        }
    }

    private func bannerRow(icon: String, tint: Color, text: String, dismiss: @escaping () -> Void) -> some View {
        VStack {
            Divider()
            HStack {
                Image(systemName: icon)
                    .foregroundColor(tint)
                Text(text)
                    .foregroundColor(tint)
                    .font(.caption)
                Spacer()
                Button("Dismiss", action: dismiss)
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGray6))
    }

    private func sendTextQuery() {
        let query = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        voiceAssistant.stopSpeaking()
        textInput = ""
        isTextFieldFocused = false

        let shouldSpeak = voiceAssistant.voiceSettings.autoSpeakResponses

        Task {
            await cookingSessionManager.sendQueryStreaming(query) { sentence in
                if shouldSpeak { voiceAssistant.enqueueSentence(sentence) }
            }
            if shouldSpeak { voiceAssistant.finishSpeaking() }
        }
    }
}

// MARK: - Hands-free button

/// Starts and stops the hands-free loop.
///
/// A menu rather than a plain toggle, because there are two modes and the choice belongs at the
/// moment of starting one: whether the assistant should answer everything it hears or only what
/// is addressed to it depends on who else is in the kitchen, not on a setting made earlier.
/// Running, it is a single tap to end — the state it is in is not a choice.
private struct HandsFreeButton: View {
    @FocusState.Binding var textInputFocused: Bool
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant

    private var enabled: Bool {
        voiceAssistant.isAvailable && !cookingSessionManager.isLoading
            && !voiceAssistant.isRecording && !voiceAssistant.isTranscribing
    }

    var body: some View {
        Group {
            if voiceAssistant.isHandsFree {
                Button { voiceAssistant.stopHandsFree() } label: { icon }
            } else {
                Menu {
                    Button {
                        start(usesWakeWord: false)
                    } label: {
                        Label("Hands-free", systemImage: "waveform")
                    }
                    Button {
                        start(usesWakeWord: true)
                    } label: {
                        Label("Wait for \"\(voiceAssistant.voiceSettings.wakePhrase)\"",
                              systemImage: "ear.badge.waveform")
                    }
                    .disabled(!voiceAssistant.wakeWordIsUsable)
                } label: {
                    icon
                }
                .disabled(!enabled)
            }
        }
        .padding(12)
        .background(
            Circle().fill(voiceAssistant.isHandsFree
                          ? Color.green.opacity(0.2)
                          : Color(.systemGray6))
        )
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundColor(voiceAssistant.isHandsFree ? .green : (enabled ? .orange : .gray))
    }

    private var symbol: String {
        guard voiceAssistant.isHandsFree else { return "ear" }
        return voiceAssistant.usesWakeWord ? "ear.badge.waveform" : "waveform.circle.fill"
    }

    private func start(usesWakeWord: Bool) {
        textInputFocused = false
        guard let context = cookingSessionManager.voiceContext() else { return }
        Task {
            await voiceAssistant.startHandsFree(usesWakeWord: usesWakeWord, context: context)
        }
    }
}

// MARK: - Mic button

/// Push-to-talk dictation into the message box.
///
/// Distinct from the hands-free button next to it: this records one utterance and puts what it
/// heard in the text field, where a misheard ingredient can be corrected before it becomes a
/// question. Hands-free runs the whole conversation without touching the phone.
private struct MicButton: View {
    @Binding var textInput: String
    @FocusState.Binding var textInputFocused: Bool
    @EnvironmentObject var cookingSessionManager: CookingSessionManager
    @EnvironmentObject var voiceAssistant: VoiceAssistant

    /// Stop while recording *or* speaking: in both states the useful action is to end what is
    /// happening, and starting a recording over the assistant's own voice would just record it.
    private var isStopping: Bool { voiceAssistant.isRecording || voiceAssistant.isSpeaking }

    private var enabled: Bool {
        // Hands-free already owns the microphone and the audio session. Recording over it would
        // reset the category out from under a running loop, taking its echo cancellation with
        // it, and open a second recorder on an input it has already tapped.
        !voiceAssistant.isHandsFree
            && !voiceAssistant.isTranscribing
            && (voiceAssistant.isAvailable || isStopping)
            && !cookingSessionManager.isLoading
    }

    var body: some View {
        Button(action: tapped) {
            if voiceAssistant.isTranscribing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: isStopping ? "stop.circle.fill" : "mic")
                    .font(.title2)
                    .foregroundColor(isStopping ? .red : (enabled ? .orange : .gray))
            }
        }
        .padding(12)
        .background(Circle().fill(isStopping ? Color.red.opacity(0.15) : Color(.systemGray6)))
        .disabled(!enabled)
    }

    private func tapped() {
        textInputFocused = false
        if voiceAssistant.isSpeaking && !voiceAssistant.isRecording {
            // Stop the answer rather than record over it. There is no echo cancellation on
            // this path — it is push-to-talk, not the hands-free loop.
            voiceAssistant.stopSpeaking()
            return
        }
        Task {
            guard let transcript = await voiceAssistant.toggleRecording() else { return }
            textInput = textInput.isEmpty ? transcript : "\(textInput) \(transcript)"
        }
    }
}

// MARK: - Voice status bar

/// What the loop is doing, plus a live input level.
///
/// The hardest part of a hands-free UI is knowing whether it is your turn, which is why armed
/// and listening are worded and coloured differently rather than both reading as "on".
private struct VoiceStatusBar: View {
    @EnvironmentObject var voiceAssistant: VoiceAssistant

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                    .font(.system(size: 14))

                Text(label)
                    .font(.caption.bold())
                    .foregroundColor(tint)
                    .lineLimit(1)

                // Shown while armed too. The microphone is open in both states, and a meter
                // that vanishes when the assistant is merely waiting for its name reads as a
                // microphone that has stopped working.
                if voiceAssistant.phase.isResting {
                    LevelMeter(level: voiceAssistant.level, threshold: voiceAssistant.threshold)
                }

                Spacer()

                if voiceAssistant.phase == .speaking {
                    Button("Stop") { voiceAssistant.stopHandsFreeSpeaking() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }

                Button("End") { voiceAssistant.stopHandsFree() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(tint.opacity(0.1))
    }

    private var label: String {
        switch voiceAssistant.phase {
        case .idle:         return "Voice off"
        case .preparing:    return "Getting ready…"
        case .armed:        return "Say \"\(voiceAssistant.voiceSettings.wakePhrase)\""
        // In wake-word mode this state is only reached by being called by name and asked
        // nothing, and it lapses. Saying "go ahead" is the difference between the user asking
        // their question now and waiting for a prompt that is already expiring.
        case .listening:    return voiceAssistant.usesWakeWord
            ? "Go ahead"
            : "Listening"
        case .transcribing: return "Heard you…"
        case .thinking:     return "Thinking"
        case .speaking:     return "Speaking"
        }
    }

    private var icon: String {
        switch voiceAssistant.phase {
        case .idle:         return "waveform.slash"
        case .preparing:    return "hourglass"
        case .armed:        return "ear.badge.waveform"
        case .listening:    return "ear"
        case .transcribing: return "waveform"
        case .thinking:     return "brain"
        case .speaking:     return "speaker.wave.2.fill"
        }
    }

    private var tint: Color {
        switch voiceAssistant.phase {
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

/// Input level, with the bar it has to clear marked on it.
///
/// The threshold tick is what makes "it isn't hearing me" answerable: a meter that never moves
/// means the microphone is delivering nothing, and one that moves but stays under the tick
/// means it is delivering plenty and the threshold has drifted above it. Those want opposite
/// fixes and look identical without the tick.
private struct LevelMeter: View {
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
