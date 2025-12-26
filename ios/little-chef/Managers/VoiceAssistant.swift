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
    @Published var errorMessage: String?
    @Published var isHandsFreeMode = false
    @Published var isWakeWordListening = false
    
    // Voice preferences
    private var voiceSettings: VoiceSettings?
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // Wake word detection
    private var wakeWordRequest: SFSpeechAudioBufferRecognitionRequest?
    private var wakeWordTask: SFSpeechRecognitionTask?

    // Primary wake words (exact matches)
    private let wakeWords = ["hey littlechef", "hey little chef"]

    // Phonetically similar variants (common misrecognitions)
    private let phoneticVariants = [
        "hey little chief",
        "a little chef",
        "hey little shift",
        "hey little ship",
        "hey lil chef",
        "hey little chefs",
        "hey little chef's"
    ]

    // Sliding window size for wake word detection
    private let wakeWordWindowSize = 10
    
    // Hands-free mode callbacks
    var onWakeWordDetected: (() -> Void)?
    var onVoiceQueryReady: ((String) -> Void)?
    
    // Speech timeout handling
    private var speechTimeoutWorkItem: DispatchWorkItem?
    private var lastSpeechTime: Date?
    private let speechTimeoutInterval: TimeInterval = 2 // 1.5 seconds of silence for snappier response
    
    
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
                    self.errorMessage = "Speech recognition permission denied"
                    self.isAvailable = false
                @unknown default:
                    self.errorMessage = "Speech recognition permission unknown"
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
                    self.errorMessage = "Microphone permission denied"
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
            self.errorMessage = "Failed to setup audio session: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Speech Recognition
    
    func startListening() {
        guard isAvailable, !isListening else { return }

        // Stop any ongoing tasks
        stopListening()

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            self.errorMessage = "Speech recognizer not available"
            return
        }

        do {
            // Setup recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                self.errorMessage = "Unable to create recognition request"
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
                        self?.errorMessage = "Recognition error: \(error.localizedDescription)"
                        self?.stopListening()
                    }
                }
            }
            
            // Start audio engine
            audioEngine.prepare()
            try audioEngine.start()
            
            isListening = true
            recognizedText = ""
            self.errorMessage = nil

        } catch {
            self.errorMessage = "Failed to start listening: \(error.localizedDescription)"
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
    
    func updateVoiceSettings(_ settings: VoiceSettings) {
        self.voiceSettings = settings
    }
    
    // MARK: - TTS with optional audio data from Lambda

    /// Speak text using either provided audio data (from Lambda) or native TTS
    func speak(_ text: String, audioData: Data? = nil) {
        guard !text.isEmpty else { return }

        // Stop any current speech
        synthesizer.stopSpeaking(at: .immediate)

        // If audio data provided (from server TTS), use it
        if let audio = audioData {
            playAudio(data: audio)
        } else {
            // Use native iOS TTS
            speakWithNativeTTS(text)
        }
    }

    /// Play audio data directly (from server TTS: Polly, OpenAI, etc.)
    func playAudio(data: Data) {
        playServerTTSAudio(data: data)
    }
    
    private func speakWithNativeTTS(_ text: String) {
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
    
    // Server TTS audio playback (Polly, OpenAI TTS, etc.)
    private func playServerTTSAudio(data: Data) {
        do {
            let audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()

            isSpeaking = true
            audioPlayer.play()

            // Store the player to keep it alive during playback
            objc_setAssociatedObject(self, "currentAudioPlayer", audioPlayer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        } catch {
            print("Failed to play server TTS audio: \(error)")
            // Fallback to native TTS
            speakWithNativeTTS("Error playing audio")
        }
    }
    
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)

        // Stop server TTS audio if playing
        if let audioPlayer = objc_getAssociatedObject(self, "currentAudioPlayer") as? AVAudioPlayer {
            audioPlayer.stop()
        }

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
    
    // MARK: - Wake Word Detection Algorithms

    /// Improved wake word detection with multiple strategies
    /// - Parameters:
    ///   - transcript: The full transcript from speech recognition
    ///   - confidence: The transcription object with confidence scores
    /// - Returns: The detected wake word variant if found, nil otherwise
    private func detectWakeWord(in transcript: String, confidence: SFTranscription?) -> String? {
        let lowercased = transcript.lowercased()

        // Strategy 1: Sliding window (only check recent words to reduce false positives)
        let words = lowercased.components(separatedBy: " ")
        let recentWords = words.suffix(wakeWordWindowSize).joined(separator: " ")

        // Strategy 2: Exact matches in primary wake words
        for wakeWord in wakeWords {
            if recentWords.contains(wakeWord) {
                print("✅ Exact match: \(wakeWord)")
                return wakeWord
            }
        }

        // Strategy 3: Phonetic variants (common misrecognitions)
        for variant in phoneticVariants {
            if recentWords.contains(variant) {
                print("✅ Phonetic variant match: \(variant)")
                return variant
            }
        }

        // Strategy 4: Fuzzy matching (allows small variations)
        if let fuzzyMatch = checkFuzzyMatch(in: recentWords) {
            print("✅ Fuzzy match: \(fuzzyMatch)")
            return fuzzyMatch
        }

        return nil
    }

    /// Check for fuzzy matches using Levenshtein distance
    /// Allows 1-2 character differences to account for minor recognition errors
    private func checkFuzzyMatch(in text: String) -> String? {
        let allCandidates = wakeWords + phoneticVariants

        for candidate in allCandidates {
            let distance = levenshteinDistance(text, candidate)
            let threshold = candidate.count / 5 // Allow ~20% character differences

            if distance <= threshold {
                return candidate
            }
        }

        return nil
    }

    /// Calculate Levenshtein distance between two strings
    /// This measures how many single-character edits are needed to change one string to another
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let s1Length = s1Array.count
        let s2Length = s2Array.count

        guard s1Length > 0 else { return s2Length }
        guard s2Length > 0 else { return s1Length }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: s2Length + 1), count: s1Length + 1)

        for i in 0...s1Length {
            matrix[i][0] = i
        }

        for j in 0...s2Length {
            matrix[0][j] = j
        }

        for i in 1...s1Length {
            for j in 1...s2Length {
                let cost = s1Array[i - 1] == s2Array[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,      // deletion
                    matrix[i][j - 1] + 1,      // insertion
                    matrix[i - 1][j - 1] + cost // substitution
                )
            }
        }

        return matrix[s1Length][s2Length]
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
            self.errorMessage = "Speech recognizer not available for wake word detection"
            return
        }
        
        do {
            // Setup wake word recognition request
            wakeWordRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let wakeWordRequest = wakeWordRequest else {
                self.errorMessage = "Unable to create wake word recognition request"
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

                        // Improved wake word detection
                        if let detectedWakeWord = self.detectWakeWord(in: transcript, confidence: result.bestTranscription) {
                            print("🎤 Wake word detected: \(detectedWakeWord)")
                            self.onWakeWordDetected?()
                            self.transitionToVoiceQuery()
                            return
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
            self.errorMessage = "Failed to start wake word listening: \(error.localizedDescription)"
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
            self.errorMessage = "Speech recognizer not available"
            return
        }

        do {
            // Setup recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                self.errorMessage = "Unable to create recognition request"
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
            self.errorMessage = nil
            lastSpeechTime = Date()
            scheduleSpeechTimeout()
            
        } catch {
            self.errorMessage = "Failed to start hands-free listening: \(error.localizedDescription)"
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

// MARK: - AVAudioPlayerDelegate

extension VoiceAssistant: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            // Clear the stored audio player
            objc_setAssociatedObject(self, "currentAudioPlayer", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            objc_setAssociatedObject(self, "currentAudioPlayer", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            print("Server TTS audio decode error: \(error?.localizedDescription ?? "Unknown error")")
        }
    }
}
