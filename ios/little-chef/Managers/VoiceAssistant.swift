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

@MainActor
class VoiceAssistant: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var recognizedText = ""
    @Published var isSpeaking = false
    @Published var isAvailable = false
    @Published var error: String?
    @Published var isHandsFreeMode = false
    @Published var isWakeWordListening = false
    
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
    private let speechTimeoutInterval: TimeInterval = 4.0 // 4 seconds of silence
    
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
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
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
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
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
    
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        
        // Stop any current speech
        synthesizer.stopSpeaking(at: .immediate)
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        
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
        
        // Start regular voice listening for the query
        startHandsFreeVoiceListening()
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
            processSpeechResult()
        } else {
            // No speech detected, just return to wake word listening
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

extension VoiceAssistant: AVSpeechSynthesizerDelegate {
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
