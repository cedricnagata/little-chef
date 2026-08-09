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
import Combine
import BigBroKit

/// Everything a hands-free session needs from the cooking session that owns it.
///
/// Passed in at start rather than reached for, because the two backends need different halves
/// of it: the on-device loop calls ``answer`` and lets the cooking session mirror the turn into
/// the transcript itself, while `BigBroVoiceSession` runs its own conversation against the Mac
/// and needs ``systemPrompt``, ``tools`` and ``history`` to be briefed the same way — with the
/// turns mirrored back through ``beginTurn`` and ``updateReply``.
@MainActor
struct VoiceSessionContext {
    /// The cooking brief — recipe, ingredients, steps, live timers.
    let systemPrompt: String
    /// Timer tools, or nil when the pinned provider can't call them.
    let tools: CookingTools?
    /// The conversation so far as (role, content) pairs, oldest first, so switching to voice
    /// continues it rather than starting over.
    let priorTurns: [(role: String, content: String)]
    /// Answers one question on the on-device path, streaming finished sentences.
    let answer: (_ question: String, _ onSentence: @escaping (String) -> Void) async -> String
    /// A spoken question was heard on the Mac path. Returns the id of the reply to update.
    let beginTurn: (_ question: String) -> UUID
    /// The Mac path's reply text changed.
    let updateReply: (_ id: UUID, _ text: String) -> Void
}

/// Voice input and output for the cooking assistant, over whichever backend the session pinned.
///
/// This is a coordinator, not an implementation. The loops live elsewhere — `BigBroVoiceSession`
/// in the kit for a paired Mac, ``LocalVoiceSession`` for on-device — and both report into the
/// one published surface below, so the cooking UI is written once.
///
/// ## One owner of the audio route at a time
///
/// The sharpest edge in this whole area, and the cause of the bugs this replaced. Two audio
/// engines must never run at once: voice processing lives in a single I/O unit and cannot work
/// alongside a second engine, and an engine left running holds the route open so the next thing
/// to play starts but never renders — buffers scheduled, no completion, a caller waiting
/// forever on audio that cannot arrive.
///
/// So every handover here is a `shutdown()`, not a `stop()`. `stop()` ends the current
/// utterance and deliberately leaves the engine up, which is right for speaking again in a
/// moment and wrong for giving the microphone to somebody else.
@MainActor
final class VoiceAssistant: NSObject, ObservableObject {

    // MARK: - Availability

    @Published private(set) var isAvailable = false
    @Published var error: String?

    // MARK: - Hands-free

    @Published private(set) var isHandsFree = false
    /// True when the running loop is gated on the wake phrase, so the UI can say which of the
    /// two hands-free modes is on without reaching into the session.
    @Published private(set) var usesWakeWord = false
    @Published private(set) var phase: VoicePhase = .idle
    @Published private(set) var level: Float = 0
    /// The level speech has to clear, on the same scale as ``level``.
    @Published private(set) var threshold: Float = 0

    // MARK: - Push-to-talk

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false

    // MARK: - Speaking

    @Published private(set) var isSpeaking = false

    // MARK: - Configuration

    private(set) var voiceSettings: LocalVoiceSettings = .defaultSettings
    /// The provider the cooking session pinned at start. Fixed for the life of that session —
    /// see `CookingSessionManager.sessionProvider`.
    private(set) var provider: LLMProvider = .local

    /// The wake phrase as the kit understands it, with its mishearing tolerance.
    var wakeWord: WakeWord { WakeWord(voiceSettings.wakePhrase) }
    /// False when the configured phrase is too short to gate on — a phrase that brief matches
    /// too much ordinary speech, and `WakeWord` refuses it rather than silently matching
    /// nothing.
    var wakeWordIsUsable: Bool { !wakeWord.isEmpty }

    // MARK: - Machinery

    private let llmService: LLMService

    /// Speaks typed replies on the Mac path. `configuresAudioSession: true` — it owns the
    /// route while it is up, and this type hands it over explicitly rather than fighting it
    /// for the category, which is what left spoken replies routed to the earpiece.
    private let bigBroPlayer = BigBroAudioPlayer()
    /// Speaks typed replies on the on-device path.
    private let speaker = OnDeviceSpeaker()

    private var bigBroSession: BigBroVoiceSession?
    private var localSession: LocalVoiceSession?
    private var sessionCancellables: Set<AnyCancellable> = []

    /// The assistant bubble the current spoken turn is streaming into, on the Mac path.
    private var spokenReplyID: UUID?

    // Typed-reply speech queue.
    private var speechSink: AsyncStream<String>.Continuation?
    private var speakerTask: Task<Void, Never>?

    // Push-to-talk recording.
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    override convenience init() {
        self.init(llmService: .shared)
    }

    init(llmService: LLMService) {
        self.llmService = llmService
        super.init()
        requestPermissions()

        // A hands-free loop on the Mac path has nothing to talk to once the Mac goes away:
        // every turn would fail, and leaving the microphone open would burn battery
        // transcribing into the void. Auto-reconnect can bring the Mac back, but not before
        // the turns in flight have already failed.
        llmService.bigBroClient.$connectionState
            .receive(on: DispatchQueue.main)
            .filter { $0 == .disconnected }
            .sink { [weak self] _ in
                guard let self, self.isHandsFree, self.provider == .bigBro else { return }
                self.stopHandsFree()
                self.error = "Lost the connection to your Mac — hands-free stopped."
            }
            .store(in: &connectionCancellables)
    }

    private var connectionCancellables: Set<AnyCancellable> = []

    // MARK: - Configuration

    func updateVoiceSettings(_ settings: LocalVoiceSettings) {
        voiceSettings = settings
        // A running loop was handed these at construction and would otherwise keep the old
        // ones until restarted.
        bigBroSession?.speaksReplies = settings.autoSpeakResponses
        bigBroSession?.voice = settings.bigBroVoice
        if usesWakeWord { bigBroSession?.wakeWord = wakeWord }
        localSession?.voiceSettings = settings
        localSession?.speaksReplies = settings.autoSpeakResponses
        if usesWakeWord { localSession?.wakeWord = wakeWord }
        // Turning speech off mid-answer should stop the answer, not let it finish.
        if !settings.autoSpeakResponses { stopSpeaking() }
    }

    /// Pins the backend for this cooking session.
    func configure(provider: LLMProvider) {
        self.provider = provider
    }

    /// Whether spoken output should go through the Mac right now.
    ///
    /// Follows the pinned provider rather than a separate preference — routing inference through
    /// the Mac means speaking through it too — but still needs a live connection: falling back to
    /// the on-device voice beats going silent when the Mac disappears mid-cook.
    private var speaksThroughMac: Bool {
        provider == .bigBro && llmService.bigBroClient.isConnected
    }

    // MARK: - Permissions

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard status == .authorized else {
                    self.error = "Speech recognition permission denied"
                    self.isAvailable = false
                    return
                }
                self.isAvailable = await AVAudioApplication.requestRecordPermission()
                if !self.isAvailable { self.error = "Microphone permission denied" }
            }
        }
    }

    // MARK: - Hands-free

    func startHandsFree(usesWakeWord wantsWakeWord: Bool, context: VoiceSessionContext) async {
        guard isAvailable, !isHandsFree else { return }
        // Refused rather than started: gated on a phrase that can never match, the loop would
        // open the microphone, hear everything and answer none of it — which looks exactly
        // like a broken microphone.
        guard !wantsWakeWord || wakeWordIsUsable else {
            error = "\"\(voiceSettings.wakePhrase)\" is too short to use as a wake word."
            return
        }
        // The Mac does the listening, the thinking and the talking on this path. Started
        // without one, the loop would open the microphone and fail every turn — which looks
        // like a broken assistant rather than a missing Mac. (DEBUG reports full capability
        // regardless of connection, so the chat UI does not gate this on our behalf.)
        guard provider != .bigBro || llmService.bigBroClient.isConnected else {
            error = "Connect to your BigBro Mac to use hands-free."
            return
        }
        error = nil

        // Handing the route over, not pausing it. Both of these leave their engines running on
        // `stop()`, and a session is about to raise its own.
        bigBroPlayer.shutdown()
        speaker.stop()
        cancelSpeechQueue()

        usesWakeWord = wantsWakeWord
        isHandsFree = true
        spokenReplyID = nil

        if provider == .bigBro {
            await startMacSession(context: context)
        } else {
            await startLocalSession(context: context)
        }
    }

    func stopHandsFree() {
        // `shutdown()` rather than `stop()`: the kit session owns an engine and a
        // `.playAndRecord` route, and leaving either up means the next thing that wants the
        // speaker gets an engine that never renders.
        bigBroSession?.shutdown()
        localSession?.stop()

        sessionCancellables.removeAll()
        bigBroSession = nil
        localSession = nil
        isHandsFree = false
        usesWakeWord = false
        phase = .idle
        level = 0
        threshold = 0
        spokenReplyID = nil
    }

    private func startMacSession(context: VoiceSessionContext) async {
        let session = BigBroVoiceSession(
            client: llmService.bigBroClient,
            model: LLMService.bigBroModel,
            tools: context.tools.map { llmService.bigBroTools(from: $0) } ?? [],
            voice: voiceSettings.bigBroVoice,
            systemPrompt: context.systemPrompt,
            speaksReplies: voiceSettings.autoSpeakResponses,
            wakeWord: usesWakeWord ? wakeWord : nil
        )
        // Carry the typed conversation across, so switching to voice continues it.
        session.setHistory(context.priorTurns.map { turn in
            turn.role == "user" ? .user(turn.content) : .assistant(turn.content)
        })
        observe(session, context: context)
        bigBroSession = session
        await session.start()
    }

    private func startLocalSession(context: VoiceSessionContext) async {
        let session = LocalVoiceSession(
            voiceSettings: voiceSettings,
            speaksReplies: voiceSettings.autoSpeakResponses,
            wakeWord: usesWakeWord ? wakeWord : nil,
            answer: context.answer
        )
        observe(session)
        localSession = session
        await session.start()
    }

    /// Cuts off the spoken answer without ending the loop.
    func stopHandsFreeSpeaking() {
        bigBroSession?.stopSpeaking()
        localSession?.stopSpeaking()
    }

    // MARK: - Mirroring

    /// Mirrors the Mac session into the cooking transcript, so spoken turns appear as messages
    /// alongside typed ones instead of in a separate world.
    private func observe(_ session: BigBroVoiceSession, context: VoiceSessionContext) {
        session.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.phase = Self.map(phase)
                // A finished turn releases the bubble. Not what starts the next pair — the
                // transcript does that — but it stops a tool that returns after the turn
                // ended from appending to a reply nobody is waiting on. Both resting phases
                // count: with no follow-up window a turn goes straight back to `.armed`
                // without passing through `.listening`.
                if self.phase.isResting { self.spokenReplyID = nil }
            }
            .store(in: &sessionCancellables)

        session.$level
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.level = $0 }
            .store(in: &sessionCancellables)

        session.$threshold
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.threshold = $0 }
            .store(in: &sessionCancellables)

        // One pair of messages per turn, keyed on the turn's own identity rather than inferred
        // from anything else. `removeDuplicates` is safe here and was not on `$transcript`:
        // asking the same thing twice is two turns with two ids, and only a re-emission of one
        // turn compares equal.
        //
        // Identity is what makes barge-in work. Cutting an answer off and asking something else
        // runs .speaking → .transcribing → .thinking with no resting phase in between, so the
        // old gate — wait for the phase to rest, then open the next pair — never opened one for
        // the interrupting question, let its answer overwrite the previous reply in the previous
        // message, and skipped the tool-loop reset below with it.
        session.$turn
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] turn in
                guard let self else { return }
                // A heard question is where a tool loop begins on this path. The Mac runs its
                // own loop against one long-lived `CookingTools`, so without this the
                // create-then-start hold set in one turn would still be blocking starts several
                // turns later.
                context.tools?.beginToolLoop()
                self.spokenReplyID = context.beginTurn(turn.question)
            }
            .store(in: &sessionCancellables)

        session.$reply
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self, let id = self.spokenReplyID else { return }
                context.updateReply(id, text)
            }
            .store(in: &sessionCancellables)

        session.$error
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] in self?.error = $0 }
            .store(in: &sessionCancellables)
    }

    /// The on-device session answers through the cooking session directly, so only the status
    /// surface needs mirroring here.
    private func observe(_ session: LocalVoiceSession) {
        session.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.phase = $0 }
            .store(in: &sessionCancellables)

        session.$level
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.level = $0 }
            .store(in: &sessionCancellables)

        session.$threshold
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.threshold = $0 }
            .store(in: &sessionCancellables)

        session.$error
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] in self?.error = $0 }
            .store(in: &sessionCancellables)
    }

    private static func map(_ phase: BigBroVoiceSession.Phase) -> VoicePhase {
        switch phase {
        case .idle:         return .idle
        case .preparing:    return .preparing
        case .armed:        return .armed
        case .listening:    return .listening
        case .transcribing: return .transcribing
        case .thinking:     return .thinking
        case .speaking:     return .speaking
        }
    }

    // MARK: - Push-to-talk

    /// Records one utterance and returns what it transcribed to, for the caller to put in the
    /// message box.
    ///
    /// Deliberately not sent: a misheard ingredient is worth catching before it becomes a
    /// question, and the transcript is the one part of a voice turn that can still be fixed.
    func toggleRecording() async -> String? {
        if isRecording {
            return await stopRecordingAndTranscribe()
        }
        await startRecording()
        return nil
    }

    private func startRecording() async {
        error = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Microphone permission denied."
            return
        }
        // Same rule as starting hands-free: whoever takes the route gets it to itself. A
        // player engine left on `.playback` while the recorder opens the input is two owners
        // of one route, and the category change knocks it over anyway.
        bigBroPlayer.shutdown()
        speaker.stop()
        cancelSpeechQueue()

        do {
            let session = AVAudioSession.sharedInstance()
            // `.defaultToSpeaker` matters: `.playAndRecord` without it routes playback to the
            // receiver, so anything spoken afterwards is barely audible unless the phone is
            // held to your ear — useless for a phone on a counter.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("littlechef-voice-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.record()

            self.recorder = recorder
            self.recordingURL = url
            isRecording = true
        } catch {
            self.error = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecordingAndTranscribe() async -> String? {
        recorder?.stop()
        recorder = nil
        isRecording = false

        guard let url = recordingURL else { return nil }
        recordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let transcript: String
            if provider == .bigBro, llmService.bigBroClient.isConnected {
                transcript = try await llmService.bigBroClient.transcribe(
                    Data(contentsOf: url), format: "m4a"
                )
            } else {
                transcript = try await Self.transcribeOnDevice(url)
            }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                error = "Didn't catch that — try again."
                return nil
            }
            return trimmed
        } catch {
            self.error = "Transcription failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Transcribes a recording with Apple's on-device recognizer.
    private static func transcribeOnDevice(_ url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw VoiceError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        return try await withCheckedThrowingContinuation { continuation in
            let settled = OnceFlag()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if settled.claim() {
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                    return
                }
                if let error, settled.claim() {
                    continuation.resume(throwing: error)
                }
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

    private enum VoiceError: LocalizedError {
        case recognizerUnavailable
        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable: return "Speech recognition is unavailable right now."
            }
        }
    }

    // MARK: - Speaking typed replies

    /// Queues one finished sentence to be spoken.
    ///
    /// Sentence at a time rather than the whole answer, so the first word arrives about a
    /// sentence into generation instead of after all of it. Utterances are strictly serialized
    /// — concurrent speech requests can finish out of order, which would shuffle the answer.
    func enqueueSentence(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Never over a running loop: it owns the microphone and the route, and speaks its own
        // answers.
        guard !isHandsFree else { return }
        if speechSink == nil { startSpeechQueue() }
        speechSink?.yield(trimmed)
    }

    /// No more sentences are coming. Playback finishes on its own.
    func finishSpeaking() {
        speechSink?.finish()
        speechSink = nil
    }

    private func startSpeechQueue() {
        let (stream, sink) = AsyncStream<String>.makeStream()
        speechSink = sink
        isSpeaking = true
        speakerTask = Task { [weak self] in
            for await sentence in stream {
                guard let self, !Task.isCancelled else { break }
                await self.speakOne(sentence)
            }
            guard let self else { return }
            self.isSpeaking = false
            self.speakerTask = nil
            // The engine stays up between utterances on purpose — restarting it per sentence
            // costs latency the user hears as a gap. It is released on handover instead, in
            // `startRecording` and `startHandsFree`.
        }
    }

    private func speakOne(_ sentence: String) async {
        if speaksThroughMac {
            do {
                try await bigBroPlayer.play(
                    llmService.bigBroClient.speak(
                        sentence,
                        voice: voiceSettings.bigBroVoice,
                        speed: macSpeed()
                    )
                )
                return
            } catch is CancellationError {
                return
            } catch {
                dprint("🔊 BigBro speech failed (\(error.localizedDescription)) — using the on-device voice")
                // Say it locally rather than dropping the sentence.
                bigBroPlayer.shutdown()
            }
        }
        await speaker.speak(
            sentence,
            voice: .resolving(voiceSettings.voiceIdentifier),
            rate: voiceSettings.speechRate
        )
    }

    /// little-chef stores an absolute `AVSpeechUtterance.rate`; the Mac takes a multiplier
    /// where 1.0 is normal speed.
    private func macSpeed() -> Double {
        Double(voiceSettings.speechRate / AVSpeechUtteranceDefaultSpeechRate)
    }

    /// Silences whatever is speaking, typed or hands-free.
    func stopSpeaking() {
        cancelSpeechQueue()
        bigBroPlayer.stop()
        speaker.stop()
        stopHandsFreeSpeaking()
        isSpeaking = false
    }

    private func cancelSpeechQueue() {
        speechSink?.finish()
        speechSink = nil
        speakerTask?.cancel()
        speakerTask = nil
    }
}
