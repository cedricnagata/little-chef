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
    private let speechTimeoutInterval: TimeInterval = 3.0 // 3 seconds of silence
    
    
    override init() {
        super.init()
        synthesizer.delegate = self
        requestPermissions()
    }
    
    // MARK: - Permissions
    
    private func requestPermissions() {
        // Request speech recognition permission
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
                    self.setupAudioSession()
                } else {
                    self.error = "Microphone permission denied"
                    self.isAvailable = false
                }
            }
        }
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Use .mixWithOthers to allow sounds to play while recording
            // .overrideMutedMicrophoneInterruption ensures sounds play even when mic is active
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .overrideMutedMicrophoneInterruption])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = "Failed to setup audio session: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Speech Recognition
    
    func startListening() {
        guard isAvailable, !isListening else { return }
        
        // Stop any ongoing tasks
        stopListening()
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available"
            return
        }
        
        do {
            // Setup recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                error = "Unable to create recognition request"
                return
            }
            
            recognitionRequest.shouldReportPartialResults = true
            
            // Setup audio input
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }
            
            // Start recognition task
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let result = result {
                        self?.recognizedText = result.bestTranscription.formattedString
                        
                        // Auto-stop after a pause (when result is final)
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
            
            // Start audio engine
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
    }
    
    // MARK: - Text-to-Speech

    func updateVoiceSettings(_ settings: LocalVoiceSettings) {
        self.voiceSettings = settings
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }

        // Stop any current speech
        synthesizer.stopSpeaking(at: .immediate)

        // Use native iOS TTS only
        let utterance = AVSpeechUtterance(string: text)

        // Apply user preferences if available
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
        isSpeaking = false
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
        print("🔊 Playing start listening sound")
        DispatchQueue.main.async {
            // Use iOS "Begin Recording" sound - designed for voice recording start
            AudioServicesPlaySystemSound(1113) // Begin Recording sound
        }
    }
    
    private func playStopListeningSound() {
        print("🔊 Playing stop listening sound")
        DispatchQueue.main.async {
            // Use iOS "End Recording" sound - designed for voice recording stop
            AudioServicesPlaySystemSound(1114) // End Recording sound
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
    }
    
    private func startWakeWordListening() {
        guard isAvailable, !isWakeWordListening else { return }
        
        // Stop any ongoing tasks
        stopWakeWordListening()
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available for wake word detection"
            return
        }
        
        do {
            // Setup wake word recognition request
            wakeWordRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let wakeWordRequest = wakeWordRequest else {
                error = "Unable to create wake word recognition request"
                return
            }
            
            wakeWordRequest.shouldReportPartialResults = true
            
            // Setup audio input
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                wakeWordRequest.append(buffer)
            }
            
            // Start wake word recognition task
            wakeWordTask = speechRecognizer.recognitionTask(with: wakeWordRequest) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    if let result = result {
                        let transcript = result.bestTranscription.formattedString.lowercased()
                        
                        // Check for wake words
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
                        // Don't stop wake word listening on errors, just continue
                    }
                }
            }
            
            // Start audio engine if not already running
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
        
        if audioEngine.isRunning && !isListening {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        wakeWordRequest?.endAudio()
        wakeWordTask?.cancel()
        
        wakeWordRequest = nil
        wakeWordTask = nil
        isWakeWordListening = false
    }
    
    private func transitionToVoiceQuery() {
        // Stop wake word listening temporarily
        stopWakeWordListening()
        
        // Play sound to indicate we're now listening for the query
        playStartListeningSound()
        
        // Add a small delay to let the sound play before starting recording
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Start regular voice listening for the query
            self.startHandsFreeVoiceListening()
        }
    }
    
    private func startHandsFreeVoiceListening() {
        guard isAvailable, !isListening else { return }
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available"
            return
        }
        
        do {
            // Setup recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                error = "Unable to create recognition request"
                return
            }
            
            recognitionRequest.shouldReportPartialResults = true
            
            // Setup audio input
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }
            
            // Start recognition task with improved auto-send logic
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    if let result = result {
                        let newText = result.bestTranscription.formattedString
                        
                        // Check if we got new speech content
                        if newText != self.recognizedText {
                            self.recognizedText = newText
                            self.lastSpeechTime = Date()
                            self.scheduleSpeechTimeout()
                        }
                        
                        // If result is final and we have text, send immediately
                        if result.isFinal && !self.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.processSpeechResult()
                        }
                    }
                    
                    if let error = error {
                        print("Hands-free recognition error: \(error.localizedDescription)")
                        self.stopListening()
                        
                        // Resume wake word listening on error
                        if self.isHandsFreeMode {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.startWakeWordListening()
                            }
                        }
                    }
                }
            }
            
            // Start audio engine if not already running
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
        print("🎤 Speech timeout detected")
        
        if isListening && !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // We have text, so process it and play the stop sound
            processSpeechResult()
        } else {
            // No speech detected, just return to wake word listening quietly
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
        print("🎤 Processing speech result: \(query)")
        
        guard !query.isEmpty else {
            stopListening()
            if isHandsFreeMode {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startWakeWordListening()
                }
            }
            return
        }
        
        // Play sound to indicate we're stopping and sending the message
        playStopListeningSound()
        
        // Send the query
        onVoiceQueryReady?(query)
        stopListening()
        
        // Resume wake word listening after a short delay
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
            self.isSpeaking = false
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
}

