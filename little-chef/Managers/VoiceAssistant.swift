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
                    .allowBluetooth,
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
                    .allowBluetooth,
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
                    .allowBluetooth,
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

    /// Stop audio engine and clean up all taps/tasks without changing state flags.
    private func stopAllAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        // Always remove tap to prevent 'nullptr == Tap()' crash on next installTap
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
    }

    /// Unduck other audio by deactivating then re-activating with passive config.
    /// Called after speech finishes when hands-free mode is still active.
    private func unduckAudioSession() {
        guard isAudioSessionActive else { return }
        do {
            // Deactivate first — this is what actually unducks other audio
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = false
        } catch {
            print("Unduck deactivation note: \(error.localizedDescription)")
        }
        // Re-activate for passive listening (no duck)
        activateForPassiveListening()
    }

    /// Deactivate the audio session so other audio can resume at full volume.
    private func deactivateAudioSession() {
        guard isAudioSessionActive else { return }
        // Only deactivate if we're not listening, speaking, or in hands-free mode
        guard !isListening && !isSpeaking && !isWakeWordListening else { return }

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = false
        } catch {
            // It's ok if deactivation fails — other apps may still hold the session
            print("Audio session deactivation note: \(error.localizedDescription)")
        }
    }

    // MARK: - Speech Recognition

    func startListening() {
        guard isAvailable, !isListening else { return }

        // Stop any existing audio engine activity (wake word, etc.)
        stopAllAudioEngine()

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

        cancelSpeechTimeout()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        isListening = false

        deactivateAudioSession()
    }

    // MARK: - Text-to-Speech

    func updateVoiceSettings(_ settings: LocalVoiceSettings) {
        self.voiceSettings = settings
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)

        // Activate for speaking — routes through BT and ducks music
        activateForSpeaking()

        let utterance = AVSpeechUtterance(string: text)

        if let voiceSettings = voiceSettings {
            utterance.rate = voiceSettings.speechRate
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceSettings.voiceIdentifier)
        } else {
            utterance.rate = 0.5
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        isSpeaking = true
        synthesizer.speak(utterance)
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

        // Activate for speaking if not already
        activateForSpeaking()

        let utterance = AVSpeechUtterance(string: sentence)
        if let voiceSettings = voiceSettings {
            utterance.rate = voiceSettings.speechRate
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceSettings.voiceIdentifier)
        } else {
            utterance.rate = 0.5
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        isSpeaking = true
        synthesizer.speak(utterance)
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

    func startHandsFreeMode() {
        guard isAvailable, !isHandsFreeMode else { return }

        isHandsFreeMode = true
        startWakeWordListening()
    }

    func stopHandsFreeMode() {
        isHandsFreeMode = false
        stopWakeWordListening()
        stopListening()
        cancelSpeechTimeout()
        deactivateAudioSession()
    }

    private func startWakeWordListening() {
        guard isAvailable, !isWakeWordListening else { return }

        stopWakeWordListening()

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available for wake word detection"
            return
        }

        // Passive listening — no ducking, music stays at full volume
        activateForPassiveListening()

        do {
            wakeWordRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let wakeWordRequest = wakeWordRequest else {
                error = "Unable to create wake word recognition request"
                return
            }

            wakeWordRequest.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                wakeWordRequest.append(buffer)
            }

            wakeWordTask = speechRecognizer.recognitionTask(with: wakeWordRequest) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    if let result = result {
                        let transcript = result.bestTranscription.formattedString.lowercased()

                        for wakeWord in self.wakeWords {
                            if transcript.contains(wakeWord) {
                                print("🎤 Wake word detected: \(wakeWord)")
                                self.onWakeWordDetected?()
                                self.transitionToVoiceQuery()
                                return
                            }
                        }
                    }

                    if let error = error {
                        print("Wake word recognition error: \(error.localizedDescription)")
                    }
                }
            }

            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }

            isWakeWordListening = true

        } catch {
            self.error = "Failed to start wake word listening: \(error.localizedDescription)"
        }
    }

    private func stopWakeWordListening() {
        guard isWakeWordListening else { return }

        wakeWordRequest?.endAudio()
        wakeWordTask?.cancel()
        wakeWordRequest = nil
        wakeWordTask = nil
        isWakeWordListening = false

        // Always stop engine and remove tap to prevent 'nullptr == Tap()' crash
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        deactivateAudioSession()
    }

    private func transitionToVoiceQuery() {
        stopWakeWordListening()

        playStartListeningSound()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.startHandsFreeVoiceListening()
        }
    }

    private func startHandsFreeVoiceListening() {
        guard isAvailable, !isListening else { return }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available"
            return
        }

        // Activate for recording
        activateForRecording()

        do {
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                error = "Unable to create recognition request"
                return
            }

            recognitionRequest.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    if let result = result {
                        let newText = result.bestTranscription.formattedString

                        if newText != self.recognizedText {
                            self.recognizedText = newText
                            self.lastSpeechTime = Date()
                            self.scheduleSpeechTimeout()
                        }

                        if result.isFinal && !self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.processSpeechResult()
                        }
                    }

                    if let error = error {
                        print("Hands-free recognition error: \(error.localizedDescription)")
                        self.stopListening()

                        if self.isHandsFreeMode {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.startWakeWordListening()
                            }
                        }
                    }
                }
            }

            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }

            isListening = true
            recognizedText = ""
            error = nil
            lastSpeechTime = Date()
            scheduleSpeechTimeout()

        } catch {
            self.error = "Failed to start hands-free listening: \(error.localizedDescription)"
        }
    }

    // MARK: - Speech Timeout Handling

    private func scheduleSpeechTimeout() {
        cancelSpeechTimeout()

        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.handleSpeechTimeout()
            }
        }

        speechTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + speechTimeoutInterval, execute: workItem)
    }

    private func cancelSpeechTimeout() {
        speechTimeoutWorkItem?.cancel()
        speechTimeoutWorkItem = nil
    }

    private func handleSpeechTimeout() {
        if isListening && !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processSpeechResult()
        } else {
            stopListening()
            if isHandsFreeMode {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startWakeWordListening()
                }
            }
        }
    }

    private func processSpeechResult() {
        let query = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            stopListening()
            if isHandsFreeMode {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startWakeWordListening()
                }
            }
            return
        }

        playStopListeningSound()

        onVoiceQueryReady?(query)
        stopListening()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.isHandsFreeMode {
                self.startWakeWordListening()
            }
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
                    // Switch back to passive listening (no duck) so music resumes full volume
                    self.unduckAudioSession()
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
                self.unduckAudioSession()
            } else {
                self.deactivateAudioSession()
            }
        }
    }
}
