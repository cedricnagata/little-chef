//
//  OnDeviceSpeaker.swift
//  little-chef
//
//  AVSpeechSynthesizer with an awaitable utterance.
//

import Foundation
import AVFoundation

/// Speaks one utterance at a time and lets the caller await it.
///
/// `AVSpeechSynthesizer` reports completion through a delegate, which is awkward for a queue
/// that has to speak sentences strictly in order: the drain logic ends up split between a
/// callback and whatever scheduled it, and a cancelled utterance takes a different path out
/// than a finished one. That split is what used to strand the old hands-free loop — a
/// cancelled sentence never advanced the queue, so the microphone stayed down and the
/// assistant never listened again.
///
/// Here both endings converge on resuming one continuation, so `await speak(_:)` returns
/// exactly once however the utterance ended.
@MainActor
final class OnDeviceSpeaker: NSObject {

    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Speaks `text` and returns when it has finished — or been stopped.
    func speak(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // "1 tbsp" would be read out as letters. See `SpokenText`.
        let utterance = AVSpeechUtterance(string: SpokenText.forSpeech(trimmed))
        utterance.voice = voice
        // `rate` is an absolute value on `AVSpeechUtteranceMinimumSpeechRate`...`Maximum`,
        // where `AVSpeechUtteranceDefaultSpeechRate` is normal speed — not a multiplier.
        utterance.rate = min(
            max(rate, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )

        await withCheckedContinuation { continuation in
            // A caller that starts a second utterance without awaiting the first would strand
            // the earlier continuation forever. Release it rather than leaking the await.
            if let pending = finished {
                finished = nil
                pending.resume()
            }
            finished = continuation
            synthesizer.speak(utterance)
        }
    }

    /// Stops immediately. Anything awaiting `speak` returns.
    func stop() {
        // Gated on the return value rather than on `isSpeaking`. An utterance that has been
        // handed to the synthesizer but has not started yet reports `isSpeaking == false`
        // while still being cancellable — checking the flag would skip the cancel, leave it to
        // play after the caller believed it stopped, and resume a continuation the delegate is
        // about to resume again.
        //
        // True means `didCancel` is coming and will do the resuming; false means nothing was
        // there to cancel and no delegate callback will arrive, so it falls to us.
        if !synthesizer.stopSpeaking(at: .immediate) {
            resume()
        }
    }

    private func resume() {
        guard let continuation = finished else { return }
        finished = nil
        continuation.resume()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension OnDeviceSpeaker: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume()
    }
}

// MARK: - Voice resolution

extension AVSpeechSynthesisVoice {
    /// The stored voice setting for "the best voice installed for the device's language".
    static let automaticIdentifier = ""

    /// The default before 2026-11-13: a compact voice, the lowest quality iOS has, under a legacy
    /// identifier that iOS 26 often doesn't carry at all. Read as automatic, so everyone who never
    /// chose a voice gets the best one they have instead.
    static let legacyDefaultIdentifier = "com.apple.ttsbundle.Samantha-compact"

    /// Whether a stored setting means automatic.
    static func isAutomatic(_ identifier: String) -> Bool {
        identifier == automaticIdentifier || identifier == legacyDefaultIdentifier
    }

    /// Resolves a stored voice setting to a voice.
    ///
    /// `AVSpeechSynthesisVoice(identifier:)` is failable, and assigning its nil result to an
    /// utterance makes the synthesizer fall back to the system default *silently*, which reads
    /// as "I picked a different voice and nothing changed". A voice that has gone (deleted in
    /// the Settings app) falls back to the best installed one, and says so in the log.
    static func resolving(_ identifier: String) -> AVSpeechSynthesisVoice? {
        if !isAutomatic(identifier) {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
            dprint("🔊 Voice '\(identifier)' is not installed on this device — using the best installed voice")
        }
        return bestInstalled()
    }

    /// The highest-quality installed voice for `language`: Premium, then Enhanced, then the
    /// system's own default for it. Siri's voices are not among them: iOS doesn't offer them to
    /// other apps.
    static func bestInstalled(language: String = AVSpeechSynthesisVoice.currentLanguageCode()) -> AVSpeechSynthesisVoice? {
        let systemDefault = AVSpeechSynthesisVoice(language: language)
        let base = String(language.prefix(2))
        let exact = choosable.filter { $0.language == language }
        let candidates = exact.isEmpty ? choosable.filter { $0.language.hasPrefix(base) } : exact
        let best = candidates.max { a, b in
            (a.quality.rawValue, a.identifier == systemDefault?.identifier ? 1 : 0, b.name)
                < (b.quality.rawValue, b.identifier == systemDefault?.identifier ? 1 : 0, a.name)
        }
        return best ?? systemDefault ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// The voices worth offering: installed, not a novelty voice ("Bells", "Bubbles", "Bad News"),
    /// and not the user's Personal Voice, which needs its own permission.
    static var choosable: [AVSpeechSynthesisVoice] {
        speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
    }

    /// "Premium", "Enhanced" or nil for a standard voice.
    var qualityName: String? {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return nil
        }
    }
}
