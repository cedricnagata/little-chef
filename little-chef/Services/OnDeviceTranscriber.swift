//
//  OnDeviceTranscriber.swift
//  little-chef
//
//  Recorded speech to text with Apple's recognizer, never leaving the device.
//

import Foundation
import Speech

/// Transcribes an audio file on the device, for push-to-talk and the on-device hands-free loop.
///
/// One implementation for both. They used to carry a copy each, and the copies had drifted:
/// hands-free treated "no speech detected" as an empty transcript, while push-to-talk showed it
/// as "Transcription failed".
enum OnDeviceTranscriber {

    enum TranscriptionError: LocalizedError {
        case recognizerUnavailable
        case onDeviceRecognitionUnsupported

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognition is unavailable right now."
            case .onDeviceRecognitionUnsupported:
                return "On-device speech recognition isn't available on this device, so voice input is off. Type your question instead."
            }
        }
    }

    private static let locale = Locale(identifier: "en-US")

    /// Whether this device can recognize speech without sending it to Apple. Checked before
    /// opening the microphone, so the user isn't left talking to something that will refuse
    /// every turn.
    static var isSupported: Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    /// The text spoken in the file at `url`. Empty when nothing was said — a cough or a closing
    /// cupboard is the ordinary case in a kitchen, not an error.
    ///
    /// Refuses rather than falling back to Apple's servers: the privacy policy says audio never
    /// leaves the device in on-device mode, and a server fallback would make that untrue.
    static func transcribe(fileAt url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceRecognitionUnsupported
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true

        return try await withCheckedThrowingContinuation { continuation in
            // `recognitionTask` can call back more than once — a result and then an error, or a
            // final result after a partial. Resuming a continuation twice traps, so the first
            // call wins and the rest are dropped.
            let settled = OnceFlag()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if settled.claim() {
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                    return
                }
                if let error, settled.claim() {
                    if Self.isNoSpeechDetected(error) {
                        continuation.resume(returning: "")
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// The same, for audio already in memory, such as a WAV the microphone handed over.
    static func transcribe(_ audio: Data, fileExtension: String) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("littlechef-utterance-\(UUID().uuidString).\(fileExtension)")
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcribe(fileAt: url)
    }

    /// `kAFAssistantErrorDomain` 1110 is "no speech detected"; 203 is an empty recognition.
    private static func isNoSpeechDetected(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "kAFAssistantErrorDomain" else { return false }
        return nsError.code == 1110 || nsError.code == 203
    }

    /// Speech recognition permission, asking for it if it hasn't been decided yet.
    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// One-shot latch guarding a continuation against a callback that fires more than once.
    private final class OnceFlag: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
