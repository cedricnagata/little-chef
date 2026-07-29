//
//  VoiceAssistant.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/12/25.
//

import Foundation
import Speech
import AVFoundation
import SwiftUI
import AudioToolbox

@MainActor
class VoiceAssistant: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var recognizedText = ""
    @Published var isSpeaking = false
    @Published var isAvailable = false
    @Published var error: String?
    @Published var isHandsFreeMode = false
    @Published var isWakeWordListening = false

    // Voice preferences
    private var voiceSettings: LocalVoiceSettings?

    // Sentence queue for streaming TTS
    private var sentenceQueue: [String] = []
    private var isSpeakingFromQueue = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Wake word detection
    private var wakeWordRequest: SFSpeechAudioBufferRecognitionRequest?
    private var wakeWordTask: SFSpeechRecognitionTask?
    private let wakeWords = ["hey littlechef", "hey little chef"]

    // Hands-free mode callbacks
    var onWakeWordDetected: (() -> Void)?
    var onVoiceQueryReady: ((String) -> Void)?

    // Speech timeout handling
    private var speechTimeoutWorkItem: DispatchWorkItem?
    private var lastSpeechTime: Date?
    private let speechTimeoutInterval: TimeInterval = 3.0

    // Track whether we activated the audio session
    private var isAudioSessionActive = false


    override init() {
        super.init()
        synthesizer.delegate = self
        requestPermissions()
    }

    // MARK: - Permissions

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self.requestMicrophonePermission()
                case .denied, .restricted, .notDetermined:
                    self.error = "Speech recognition permission denied"
                    self.isAvailable = false
                @unknown default:
                    self.error = "Speech recognition permission unknown"
                    self.isAvailable = false
                }
            }
        }
    }

    private func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    self.isAvailable = true
                } else {
                    self.error = "Microphone permission denied"
                    self.isAvailable = false
                }
            }
        }
    }

    // MARK: - Audio Session Management

    /// Activate audio session for passive listening (wake word).
    /// Mixes with other audio at full volume — no ducking.
    private func activateForPassiveListening() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [
                    .allowBluetoothHFP,
                    .allowBluetoothA2DP,
                    .mixWithOthers
                ]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = true
        } catch {
            self.error = "Failed to activate audio session: \(error.localizedDescription)"
        }
    }

    /// Activate audio session for active recording (user speaking).
    /// Ducks other audio so the mic can pick up speech clearly.
    private func activateForRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [
                    .allowBluetoothHFP,
                    .allowBluetoothA2DP,
                    .mixWithOthers,
                    .duckOthers
                ]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = true
        } catch {
            self.error = "Failed to activate audio session: \(error.localizedDescription)"
        }
    }

    /// Activate audio session for speech output (TTS).
    /// Ducks other audio while speaking. Deactivates first to force iOS to re-evaluate
    /// the ducking option when switching from a non-ducking session.
    private func activateForSpeaking() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Deactivate first so the new category + options take effect
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [
                    .allowBluetoothHFP,
                    .allowBluetoothA2DP,
                    .mixWithOthers,
                    .duckOthers,
                    .defaultToSpeaker
                ]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = true
        } catch {
            self.error = "Failed to activate audio session for speech: \(error.localizedDescription)"
        }
    }

    // MARK: - Audio Engine Cleanup

    /// Nuclear cleanup — stops engine, removes tap, cancels all recognition tasks.
    /// Call this before starting any new audio activity to guarantee a clean state.
    private func tearDownAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        wakeWordRequest?.endAudio()
        wakeWordTask?.cancel()
        wakeWordRequest = nil
        wakeWordTask = nil

        isWakeWordListening = false
        isListening = false
    }

    /// Deactivate the audio session so other audio can resume at full volume.
    private func deactivateAudioSession() {
        guard isAudioSessionActive else { return }
        guard !isListening && !isSpeaking && !isWakeWordListening else { return }

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = false
        } catch {
            dprint("Audio session deactivation note: \(error.localizedDescription)")
        }
    }

    /// Force-deactivate the session regardless of state (used between mode transitions).
    private func forceDeactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = false
        } catch {
            dprint("Force deactivation note: \(error.localizedDescription)")
        }
    }

    // MARK: - Speech Recognition

    func startListening() {
        guard isAvailable, !isListening else { return }

        playStartListeningSound()
        tearDownAudioEngine()

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available"
            return
        }

        activateForRecording()

        do {
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                error = "Unable to create recognition request"
                return
            }

            recognitionRequest.shouldReportPartialResults = true
            // Keep all audio on-device to honor the privacy policy ("audio is never
            // sent to any server"). Supported on all target devices/locales.
            if speechRecognizer.supportsOnDeviceRecognition {
                recognitionRequest.requiresOnDeviceRecognition = true
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let result = result {
                        self?.recognizedText = result.bestTranscription.formattedString

                        if result.isFinal {
                            self?.stopListening()
                        }
                    }

                    if let error = error {
                        self?.error = "Recognition error: \(error.localizedDescription)"
                        self?.stopListening()
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()

            isListening = true
            recognizedText = ""
            error = nil

        } catch {
            self.error = "Failed to start listening: \(error.localizedDescription)"
        }
    }

    func stopListening() {
        guard isListening else { return }

        playStopListeningSound()
        cancelSpeechTimeout()
        tearDownAudioEngine()
        deactivateAudioSession()
    }

    // MARK: - Text-to-Speech

    func updateVoiceSettings(_ settings: LocalVoiceSettings) {
        self.voiceSettings = settings
    }

    /// `AVSpeechUtterance.rate` is an absolute scale from `AVSpeechUtteranceMinimumSpeechRate`
    /// to `AVSpeechUtteranceMaximumSpeechRate`, where `AVSpeechUtteranceDefaultSpeechRate`
    /// (0.5) is normal speed — not a multiplier. Settings stores that absolute value and
    /// presents it as a multiple of the default; see `ProfileSettingsView`.
    private func clampedRate(_ rate: Float) -> Float {
        min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// Resolves the configured voice, falling back explicitly when it is not installed.
    ///
    /// `AVSpeechSynthesisVoice(identifier:)` is failable. Assigning its nil result straight to
    /// `utterance.voice` makes the synthesizer fall back to the system default *silently*,
    /// which reads as "I picked a different voice and nothing changed". Logging the miss makes
    /// the cause visible.
    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        if let identifier = voiceSettings?.voiceIdentifier {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                return voice
            }
            dprint("🔊 Voice '\(identifier)' is not installed on this device — using the default")
        }
        return AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func configuredUtterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = clampedRate(voiceSettings?.speechRate ?? AVSpeechUtteranceDefaultSpeechRate)
        utterance.voice = resolvedVoice()
        return utterance
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)
        activateForSpeaking()

        isSpeaking = true
        synthesizer.speak(configuredUtterance(for: text))
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        sentenceQueue.removeAll()
        isSpeakingFromQueue = false
        isSpeaking = false
        deactivateAudioSession()
    }

    // MARK: - Streaming TTS (sentence queue)

    func enqueueSentence(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sentenceQueue.append(trimmed)
        speakNextInQueue()
    }

    func flushSentenceQueue() {
        if !isSpeakingFromQueue {
            speakNextInQueue()
        }
    }

    private func speakNextInQueue() {
        guard !sentenceQueue.isEmpty, !isSpeakingFromQueue else { return }
        isSpeakingFromQueue = true

        let sentence = sentenceQueue.removeFirst()
        activateForSpeaking()

        isSpeaking = true
        synthesizer.speak(configuredUtterance(for: sentence))
    }

    // MARK: - Convenience Methods

    func isReady() -> Bool {
        return isAvailable && !isListening && !isSpeaking
    }

    func hasRecognizedText() -> Bool {
        return !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearRecognizedText() {
        recognizedText = ""
    }

    // MARK: - Audio Feedback

    private func playStartListeningSound() {
        DispatchQueue.main.async {
            AudioServicesPlaySystemSound(1113)
        }
    }

    private func playStopListeningSound() {
        DispatchQueue.main.async {
            AudioServicesPlaySystemSound(1114)
        }
    }

    // MARK: - Hands-Free Mode
    //
    // Flow: startWakeWordListening → (wake word detected) → transitionToVoiceQuery
    //       → (user speaks, timeout) → processSpeechResult → onVoiceQueryReady
    //       → (TTS plays) → didFinish → resumeHandsFreeListening
    //
    // Every transition goes through tearDownAudioEngine() first to guarantee clean state.

    func startHandsFreeMode() {
        guard isAvailable, !isHandsFreeMode else { return }
        isHandsFreeMode = true
        startWakeWordListening()
    }

    func stopHandsFreeMode() {
        isHandsFreeMode = false
        synthesizer.stopSpeaking(at: .immediate)
        sentenceQueue.removeAll()
        isSpeakingFromQueue = false
        isSpeaking = false
        cancelSpeechTimeout()
        tearDownAudioEngine()
        forceDeactivateAudioSession()
    }

    /// Restart wake word listening from any state. Safe to call at any time.
    func resumeHandsFreeListening() {
        guard isHandsFreeMode else { return }
        dprint("🎤 [HF] resumeHandsFreeListening")
        tearDownAudioEngine()
        forceDeactivateAudioSession()

        // Brief delay to let audio system settle after TTS / recording
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isHandsFreeMode, !self.isSpeaking else { return }
            self.startWakeWordListening()
        }
    }

    private func startWakeWordListening() {
        guard isAvailable, isHandsFreeMode, !isWakeWordListening else { return }
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available for wake word detection"
            return
        }

        // Always start from clean state
        tearDownAudioEngine()
        activateForPassiveListening()

        do {
            wakeWordRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let wakeWordRequest = wakeWordRequest else { return }
            wakeWordRequest.shouldReportPartialResults = true
            // Wake-word audio also stays on-device (see privacy policy).
            if speechRecognizer.supportsOnDeviceRecognition {
                wakeWordRequest.requiresOnDeviceRecognition = true
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                wakeWordRequest.append(buffer)
            }

            wakeWordTask = speechRecognizer.recognitionTask(with: wakeWordRequest) { [weak self] result, taskError in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Ignore callbacks if we already left wake word mode
                    guard self.isWakeWordListening else { return }

                    if let result = result {
                        let transcript = result.bestTranscription.formattedString.lowercased()
                        for wakeWord in self.wakeWords {
                            if transcript.contains(wakeWord) {
                                dprint("🎤 [HF] Wake word detected!")
                                self.onWakeWordDetected?()
                                self.transitionToVoiceQuery()
                                return
                            }
                        }
                    }

                    if let taskError = taskError {
                        dprint("🎤 [HF] Wake word task error: \(taskError.localizedDescription)")
                        // Recognition timed out — restart if still in hands-free
                        self.isWakeWordListening = false
                        if self.isHandsFreeMode && !self.isSpeaking {
                            self.resumeHandsFreeListening()
                        }
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isWakeWordListening = true
            dprint("🎤 [HF] Wake word listening active")

        } catch {
            dprint("🎤 [HF] Failed to start wake word: \(error)")
            self.error = "Failed to start wake word listening: \(error.localizedDescription)"
        }
    }

    private func transitionToVoiceQuery() {
        dprint("🎤 [HF] Transitioning to voice query")
        // Fully tear down wake word before starting voice recording
        tearDownAudioEngine()
        playStartListeningSound()

        guard isAvailable, let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available"
            resumeHandsFreeListening()
            return
        }

        activateForRecording()

        do {
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true
            // Hands-free voice queries stay on-device (see privacy policy).
            if speechRecognizer.supportsOnDeviceRecognition {
                recognitionRequest.requiresOnDeviceRecognition = true
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, taskError in
                DispatchQueue.main.async {
                    guard let self, self.isListening else { return }

                    if let result = result {
                        let newText = result.bestTranscription.formattedString
                        if newText != self.recognizedText {
                            self.recognizedText = newText
                            self.lastSpeechTime = Date()
                            self.scheduleSpeechTimeout()
                        }
                        if result.isFinal && !self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.finishVoiceQuery()
                        }
                    }

                    if let taskError = taskError {
                        dprint("🎤 [HF] Voice query error: \(taskError.localizedDescription)")
                        self.tearDownAudioEngine()
                        self.cancelSpeechTimeout()
                        self.resumeHandsFreeListening()
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            recognizedText = ""
            error = nil
            lastSpeechTime = Date()
            scheduleSpeechTimeout()

        } catch {
            self.error = "Failed to start voice query: \(error.localizedDescription)"
            resumeHandsFreeListening()
        }
    }

    /// User finished speaking — send the query, then TTS delegate will call resumeHandsFreeListening.
    private func finishVoiceQuery() {
        guard isListening else { return }
        let query = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSpeechTimeout()
        playStopListeningSound()
        tearDownAudioEngine()

        guard !query.isEmpty else {
            resumeHandsFreeListening()
            return
        }

        dprint("🎤 [HF] Query: \(query)")
        onVoiceQueryReady?(query)

        // Safety fallback: if TTS never plays (error, empty response), restart after timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self else { return }
            if self.isHandsFreeMode && !self.isWakeWordListening && !self.isListening && !self.isSpeaking {
                dprint("🎤 [HF] Safety fallback: restarting wake word")
                self.resumeHandsFreeListening()
            }
        }
    }

    // MARK: - Speech Timeout Handling

    private func scheduleSpeechTimeout() {
        cancelSpeechTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleSpeechTimeout()
        }
        speechTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + speechTimeoutInterval, execute: workItem)
    }

    private func cancelSpeechTimeout() {
        speechTimeoutWorkItem?.cancel()
        speechTimeoutWorkItem = nil
    }

    private func handleSpeechTimeout() {
        guard isListening else { return }
        if !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishVoiceQuery()
        } else {
            // No speech detected — go back to wake word
            tearDownAudioEngine()
            resumeHandsFreeListening()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceAssistant: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeakingFromQueue = false
            if self.sentenceQueue.isEmpty {
                self.isSpeaking = false
                if self.isHandsFreeMode {
                    dprint("🎤 [HF] TTS finished, resuming wake word")
                    self.resumeHandsFreeListening()
                } else {
                    self.deactivateAudioSession()
                }
            } else {
                self.speakNextInQueue()
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeakingFromQueue = false
            self.sentenceQueue.removeAll()
            self.isSpeaking = false
            if self.isHandsFreeMode {
                dprint("🎤 [HF] TTS cancelled, resuming wake word")
                self.resumeHandsFreeListening()
            } else {
                self.deactivateAudioSession()
            }
        }
    }
}
