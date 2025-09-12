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
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
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
