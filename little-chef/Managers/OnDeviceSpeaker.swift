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

        let utterance = AVSpeechUtterance(string: trimmed)
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
    /// Resolves a stored voice identifier, falling back explicitly when it is not installed.
    ///
    /// `AVSpeechSynthesisVoice(identifier:)` is failable, and assigning its nil result to an
    /// utterance makes the synthesizer fall back to the system default *silently* — which
    /// reads as "I picked a different voice and nothing changed". Logging the miss makes the
    /// cause visible.
    static func resolving(_ identifier: String) -> AVSpeechSynthesisVoice? {
        if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        dprint("🔊 Voice '\(identifier)' is not installed on this device — using the default")
        return AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
