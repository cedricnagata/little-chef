//
//  LocalVoiceSession.swift
//  little-chef
//
//  The on-device half of hands-free cooking: listen, transcribe, answer, speak, repeat,
//  without a Mac anywhere in the loop.
//

import Foundation
import AVFoundation
import Speech
import Combine
import BigBroKit

// MARK: - Phase

/// What a hands-free loop is doing, in the terms the cooking UI renders.
///
/// Both backends report into this one type — `BigBroVoiceSession.Phase` is mapped onto it by
/// `VoiceAssistant` — so the status bar, the level meter and the mic button are written once
/// and don't care which of the two is running.
enum VoicePhase: Equatable {
    case idle
    /// Getting the microphone and (on the Mac path) the speech models ready.
    case preparing
    /// Wake-word mode: the microphone is open, but nothing is being answered until the
    /// assistant hears its name.
    ///
    /// Deliberately distinct from ``listening``. The microphone is open in both, but only one
    /// of them is the user's turn, and a UI that renders them the same is unusable.
    case armed
    /// Taking anything said as a question.
    case listening
    /// An utterance has been captured and is being turned into text.
    case transcribing
    /// The model is generating, tool calls included.
    case thinking
    /// Speaking the answer.
    case speaking

    /// True in the two states where the user may simply talk.
    var isResting: Bool { self == .listening || self == .armed }
}

// MARK: - Session

/// A hands-free spoken conversation that never leaves the device.
///
/// The on-device counterpart to `BigBroVoiceSession`, and deliberately the same shape: energy
/// endpointing from `BigBroMicrophone`, wake-phrase matching from `WakeWord`, the same phase
/// machine, the same follow-up window. What changes is only who does the work — Apple's
/// on-device recognizer instead of Parakeet on the Mac, `AVSpeechSynthesizer` instead of
/// Kokoro, and an answer supplied by the caller instead of `converse`.
///
/// Reusing the kit's microphone and wake word rather than reimplementing them is the point.
/// The endpointer decides when a turn ended from signal energy, with a preroll so the opening
/// consonant survives; the previous implementation gated on a three-second silence timer over a
/// continuously-running `SFSpeechRecognizer` and matched its wake phrase with `contains`, which
/// missed every mishearing of it.
///
/// ## Half-duplex, on purpose
///
/// Capture stops for the whole answer and restarts afterwards, so the microphone never hears
/// the synthesizer. `BigBroVoiceSession` can leave it open — and so support barge-in — because
/// capture and playback share one `AVAudioEngine` with voice processing enabled, which gives
/// the echo canceller a reference signal. `AVSpeechSynthesizer` renders to the audio session
/// directly and is not in anybody's engine, so there is nothing to cancel against here: left
/// listening, the endpointer would hear the assistant, treat it as the user talking, and the
/// loop would interrupt itself in a cycle that never settles.
///
/// The cost is that talking over an on-device answer does nothing. ``stopSpeaking()`` is the
/// way out, and the UI offers it as a button.
@MainActor
final class LocalVoiceSession: NSObject, ObservableObject {

    // MARK: Published state

    @Published private(set) var phase: VoicePhase = .idle
    /// The most recent thing the user was heard to say.
    @Published private(set) var transcript = ""
    /// The current answer, accumulating as it generates.
    @Published private(set) var reply = ""
    /// Set when a turn fails; cleared at the start of the next one.
    @Published private(set) var error: String?
    /// Smoothed 0...1 input level, mirrored from the microphone for meters.
    @Published private(set) var level: Float = 0
    /// The level speech has to clear, on the same scale — draw it on the meter.
    @Published private(set) var threshold: Float = 0

    // MARK: Configuration

    /// When set, only utterances addressed by this phrase are answered.
    ///
    /// The phrase is the *only* way in. Every request opens with it, including the one after
    /// an answer — the loop re-arms as soon as it stops speaking rather than staying open for
    /// a follow-up. The single exception is being called by name with nothing after it, which
    /// opens the microphone briefly for the request that was promised; see ``summonWindow``.
    var wakeWord: WakeWord?
    /// Whether answers are spoken aloud. Off still runs the loop — talk to it, read the reply.
    var speaksReplies: Bool
    /// Voice and rate for the synthesizer. Re-read per utterance, so a change in Settings
    /// applies without restarting the session.
    var voiceSettings: LocalVoiceSettings

    /// Answers one question, streaming finished sentences to `onSentence` as they arrive and
    /// returning the whole reply.
    ///
    /// Injected rather than called directly so this type owns the microphone and the voice but
    /// not the model: the cooking session already knows how to run a query, mirror it into the
    /// transcript, and execute timer tools, and duplicating that here would give the spoken
    /// assistant a second, subtly different brain.
    private let generateAnswer: (_ question: String, _ onSentence: @escaping (String) -> Void) async -> String

    /// How long a session called by name with nothing after it waits for the request.
    ///
    /// Deliberately not configurable, and short. This is the only state in wake-word mode
    /// where speech is taken without the phrase, so how long it lasts is exactly how long the
    /// wake word is not doing its job; a false wake nobody follows up costs this much open
    /// microphone and no more.
    private static let summonWindow: TimeInterval = 8

    // MARK: Machinery

    private let microphone: BigBroMicrophone
    private let speaker = OnDeviceSpeaker()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private var loopTask: Task<Void, Never>?
    private var rearmTask: Task<Void, Never>?
    /// When an outstanding summons stops being honoured, or nil if there isn't one.
    private var summonedUntil: ContinuousClock.Instant?
    /// True once speech has begun inside the window, holding it open until that speech is
    /// dealt with. See ``summoned``.
    private var summonHeld = false
    private var cancellables: Set<AnyCancellable> = []

    /// Whether the next utterance may be taken as a request without the wake phrase.
    ///
    /// Deliberately measured against when speech *started*, not when its transcript came back.
    /// A request lands seconds after the summons that invited it — the endpointer waits out
    /// `hangoverDuration` before closing the utterance and the recognizer then has to run — so
    /// a deadline checked on arrival expires under exactly the request it was opened for, and
    /// does it more the longer the sentence.
    private var summoned: Bool {
        if summonHeld { return true }
        guard let summonedUntil else { return false }
        return .now < summonedUntil
    }

    init(
        voiceSettings: LocalVoiceSettings,
        speaksReplies: Bool,
        wakeWord: WakeWord?,
        tuning: BigBroMicrophone.Tuning = BigBroMicrophone.Tuning(),
        answer: @escaping (_ question: String, _ onSentence: @escaping (String) -> Void) async -> String
    ) {
        self.voiceSettings = voiceSettings
        self.speaksReplies = speaksReplies
        self.wakeWord = wakeWord
        self.generateAnswer = answer
        // A private engine, and `configuresAudioSession: false` because this type owns the
        // session for both directions. Sharing an engine with playback is what `BigBroVoiceSession`
        // does to get echo cancellation, and buys nothing here — the synthesizer isn't in an
        // engine, and capture is stopped whenever it speaks.
        self.microphone = BigBroMicrophone(tuning: tuning, configuresAudioSession: false)
        super.init()

        microphone.$level
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.level = $0 }
            .store(in: &cancellables)

        microphone.$threshold
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.threshold = $0 }
            .store(in: &cancellables)

        // The leading edge of speech. An utterance is only emitted once the user stops
        // talking, which is too late for an open summons — that is about when they began
        // answering, not when their sentence finally finished transcribing.
        microphone.$isSpeaking
            .receive(on: DispatchQueue.main)
            .filter { $0 }
            .sink { [weak self] _ in self?.holdSummon() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Opens the microphone and starts the loop. Returns as soon as it is running.
    func start() async {
        guard phase == .idle else { return }
        error = nil
        phase = .preparing

        // Both permissions before the audio session is touched. Configuring `.playAndRecord`
        // reaches for an input the app may not be allowed to open yet, and the failure that
        // produces is a silent microphone rather than an error.
        guard await Self.requestSpeechAuthorization() else {
            error = "Speech recognition permission is off — turn it on in Settings."
            phase = .idle
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Microphone permission is off — turn it on in Settings."
            phase = .idle
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition is unavailable on this device."
            phase = .idle
            return
        }

        do {
            try configureAudioSession()
        } catch {
            self.error = "Could not start listening: \(error.localizedDescription)"
            phase = .idle
            return
        }

        guard phase == .preparing else { return }   // stopped while we were asking
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    /// Ends the session. Safe to call at any time, including mid-turn.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        clearSummon()
        microphone.stop()
        cancelSpeech()
        releaseAudioSession()
        phase = .idle
        level = 0
        threshold = 0
    }

    /// Cuts off the spoken answer without ending the turn or the session.
    ///
    /// The reply stays on screen and the loop returns to listening as it would have anyway.
    /// This is the on-device stand-in for barge-in, which half-duplex capture rules out.
    func stopSpeaking() {
        cancelSpeech()
    }

    /// Endpointing thresholds, adjustable while the loop runs.
    var tuning: BigBroMicrophone.Tuning {
        get { microphone.tuning }
        set { microphone.tuning = newValue }
    }

    /// Where the loop sits between turns: waiting for its name, or for anything at all.
    private var restingPhase: VoicePhase { wakeWord == nil ? .listening : .armed }

    // MARK: - Loop

    private func runLoop() async {
        // Announced before the first utterance rather than after the first completed turn:
        // `utterances()` yields nothing until somebody speaks, and a session that shows
        // "Getting ready…" for as long as the kitchen stays quiet reads as one that never
        // started.
        phase = restingPhase

        while !Task.isCancelled {
            var heardSomething = false
            do {
                for try await utterance in microphone.utterances() {
                    if Task.isCancelled { return }
                    heardSomething = true
                    // A turn that spoke stopped capture on its way out, ending this stream.
                    // Break and open a fresh one rather than draining a dead one.
                    if await runTurn(utterance) { break }
                    if Task.isCancelled { return }
                }
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
                phase = .idle
                return
            }
            if Task.isCancelled { return }
            // A stream that ended without yielding anything means capture stopped for a reason
            // this loop didn't ask for — an interruption, a route change, an engine that would
            // not start. Reopening is the right recovery, but doing it immediately would spin
            // at full speed for as long as the cause persists.
            if !heardSomething {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Handles one captured utterance. Returns true if capture was stopped and must be reopened.
    private func runTurn(_ audio: Data) async -> Bool {
        // Read before the first await. `summoned` is held from the leading edge of this
        // utterance's speech, so it stays true across a transcription that outlives the
        // window — but a turn that clears the summons must not see its own stale copy.
        let wasSummoned = summoned

        error = nil
        phase = .transcribing

        let heard: String
        do {
            heard = try await transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // A single utterance failing to transcribe is the common case in a kitchen — a
            // pan, a tap, somebody laughing — not a session-ending fault.
            dprint("🎤 [local] transcription failed: \(error.localizedDescription)")
            rest()
            return false
        }
        guard !Task.isCancelled else { return false }

        // A cough, a pan, a passing conversation. Transcribing to nothing is the common case
        // in a kitchen, not an error — and it does not spend a summons, since the request it
        // was waiting for has still not been spoken.
        guard !heard.isEmpty else {
            rest()
            return false
        }

        switch address(heard, summoned: wasSummoned) {
        case .notForUs:
            // Deliberately silent. Armed in an occupied kitchen, most of what this hears is
            // somebody else's conversation, and reporting each one would be the noise.
            phase = .armed
            return false

        case .summoned:
            // Called by name with nothing after it. Answering the name would be a non-sequitur;
            // take the next thing said as the request instead.
            //
            // `transcript` deliberately not set — it means "what the user asked", and the
            // caller mirrors it into the chat as a user message. Publishing the wake phrase
            // there posts "hey little chef" as a question and leaves a bubble waiting on an
            // answer nobody requested.
            summon()
            return false

        case .request(let request):
            clearSummon()
            transcript = request
            reply = ""
            let spoke = await answer(request)
            // Straight back to waiting for its name, which is the whole point of the phrase:
            // the loop stops speaking and immediately stops listening for anything else.
            rest()
            return spoke
        }
    }

    /// Generates an answer and speaks it. Returns true if capture was stopped to do so.
    private func answer(_ request: String) async -> Bool {
        phase = .thinking

        // Half-duplex: the microphone goes down for the whole answer, not just the speaking.
        // Generation can take seconds on-device, and anything said into that gap would be
        // captured, queued, and answered after the reply the user is still waiting for.
        let willSpeak = speaksReplies
        if willSpeak { microphone.stop() }

        // Sentences are spoken strictly in order, one utterance at a time, while the next is
        // still generating — so the first word arrives about a sentence in rather than after
        // the whole answer.
        let (sentences, enqueue) = AsyncStream<String>.makeStream()
        let speaker = Task { [weak self] in
            for await sentence in sentences {
                guard let self, !Task.isCancelled else { return }
                if self.phase != .speaking { self.phase = .speaking }
                await self.speak(sentence)
            }
        }

        let spoken = await generateAnswer(request) { [weak self] sentence in
            guard let self, self.speaksReplies else { return }
            enqueue.yield(sentence)
        }
        reply = spoken

        enqueue.finish()
        await speaker.value

        return willSpeak
    }

    // MARK: - Addressing

    private enum Address {
        case request(String)
        case summoned
        case notForUs
    }

    private func address(_ heard: String, summoned: Bool) -> Address {
        guard let wakeWord, !wakeWord.isEmpty else { return .request(heard) }
        if let match = wakeWord.match(heard) {
            return match.request.isEmpty ? .summoned : .request(match.request)
        }
        // No name in it. That is only a request if the session was called by name and asked
        // nothing — the request it was promised. Otherwise it is somebody else's sentence.
        return summoned ? .request(heard) : .notForUs
    }

    // MARK: - Summons

    /// Takes the next utterance as a request without the phrase, briefly.
    private func summon() {
        summonHeld = false
        summonedUntil = .now.advanced(by: .seconds(Self.summonWindow))
        phase = .listening

        // Drives the phase only — ``summoned`` is answered by the deadline itself, so this
        // firing late, or being cancelled, cannot leave the microphone open a moment longer
        // than the window says.
        rearmTask?.cancel()
        rearmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.summonWindow))
            guard !Task.isCancelled, let self, !self.summonHeld else { return }
            // Only if nothing has moved on since. A turn that started inside the window owns
            // the phase, and stamping `.armed` over `.thinking` would misreport it.
            if self.phase == .listening { self.phase = .armed }
        }
    }

    /// Holds an open summons until the speech now under way has been dealt with.
    ///
    /// The window governs when the user has to *start* answering, which is the only part of it
    /// they can judge. How long they then talk for, and how long transcription takes, are not
    /// theirs to control and must not decide whether they were heard.
    private func holdSummon() {
        guard summonedUntil != nil, summoned else { return }
        summonHeld = true
    }

    private func clearSummon() {
        rearmTask?.cancel()
        rearmTask = nil
        summonedUntil = nil
        summonHeld = false
    }

    /// Returns to rest after an utterance that produced no turn.
    ///
    /// An outstanding summons survives an utterance that turned out to be nothing, because the
    /// request it is waiting for has still not been spoken.
    private func rest() {
        // The hold, though, is spent: it belonged to the utterance just dealt with. Dropping
        // it puts the original deadline back in charge, so a cough two seconds into the window
        // cannot extend it, and a cough after the window has passed ends it.
        summonHeld = false
        phase = summoned ? .listening : restingPhase
    }

    // MARK: - Transcription

    /// Turns one captured utterance into text, on-device.
    ///
    /// File-based rather than streaming because the microphone has already decided where the
    /// utterance ends. `SFSpeechURLRecognitionRequest` wants a URL, and `BigBroMicrophone`
    /// hands over a self-contained 16 kHz WAV, so the round trip through the temporary
    /// directory is the whole adaptation.
    private func transcribe(_ wav: Data) async throws -> String {
        guard let recognizer, recognizer.isAvailable else {
            throw LocalVoiceError.recognizerUnavailable
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("littlechef-utterance-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // Keep audio on the device, per the privacy policy. The on-device recognizer is
        // available for en-US on every device this app supports.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            // `recognitionTask` can call back more than once — a result and then an error, or
            // a final result after a partial. Resuming a continuation twice traps, so the
            // first call wins and the rest are dropped.
            let settled = Settled()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if settled.claim() {
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                    return
                }
                if let error {
                    // "No speech detected" is what a cough or a closing cupboard transcribes
                    // to. It is the ordinary outcome in a kitchen, not a failure worth
                    // surfacing, so it comes back as an empty transcript like any other
                    // utterance with nothing in it.
                    if settled.claim() {
                        if Self.isNoSpeechDetected(error) {
                            continuation.resume(returning: "")
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    /// One-shot latch guarding a continuation against a callback that fires more than once.
    private final class Settled: @unchecked Sendable {
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

    /// `kAFAssistantErrorDomain` 1110 is "no speech detected"; 203 is an empty recognition.
    private static func isNoSpeechDetected(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "kAFAssistantErrorDomain" else { return false }
        return nsError.code == 1110 || nsError.code == 203
    }

    private static func requestSpeechAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Speech

    /// Speaks one sentence and returns when it has finished — or been cut off.
    private func speak(_ text: String) async {
        await speaker.speak(
            text,
            voice: .resolving(voiceSettings.voiceIdentifier),
            rate: voiceSettings.speechRate
        )
    }

    private func cancelSpeech() {
        speaker.stop()
    }

    // MARK: - Audio session

    /// One category for both directions, configured once.
    ///
    /// `.default` rather than a chat mode: a chat mode is only worth asking for alongside
    /// `setVoiceProcessingEnabled(true)` on an engine that carries both streams, and per Apple
    /// an app that sets one without the other gets *less* processing, not more — no echo
    /// cancellation, no gain correction, and a deliberately quieter output. Half-duplex
    /// capture needs none of it.
    ///
    /// `.defaultToSpeaker` is load-bearing: `.playAndRecord` without it routes playback to the
    /// earpiece, which is inaudible for a phone sitting on a counter.
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
        )
        try session.setActive(true)
    }

    /// Hands the route back, so whatever plays next picks its own category instead of
    /// inheriting a recording session.
    private func releaseAudioSession() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    private enum LocalVoiceError: LocalizedError {
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable: return "Speech recognition is unavailable right now."
            }
        }
    }
}
