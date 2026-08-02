//
//  LLMService.swift
//  little-chef
//
//  Inference for both providers behind one API: MLX on this device, or a paired Mac through
//  BigBroKit. `chat()` is the entry point — it streams text deltas, runs tools, and keeps a
//  model's reasoning out of its answer, the same contract `BigBroClient.chat` offers.
//

import Foundation
import Combine
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import BigBroKit

/// What AI features are available given the active provider, device hardware, and
/// connection state. Production builds degrade gracefully; DEBUG is always `.full`.
enum AICapability {
    /// Cooking chat + timer tools + LLM recipe parsing + schema.org import + manual timers.
    case full
    /// Cooking chat (no tools) + schema.org import + manual timers. No LLM recipe parsing.
    case limited
    /// schema.org import + manual timers only. No LLM features.
    case none

    var llmChatEnabled: Bool { self != .none }
    var toolCallingEnabled: Bool { self == .full }
    var llmRecipeParsingEnabled: Bool { self == .full }
}

@MainActor
class LLMService: ObservableObject {
    static let shared = LLMService()

    /// The single on-device model this device's RAM can run, or nil if none.
    /// DEBUG builds always report the full-capability 8B model for testing.
    static let supportedOnDeviceModel: CookingModelChoice? = {
        #if DEBUG
        return .bonsai8B
        #else
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if gb >= 6 { return .bonsai8B }
        if gb >= 4 { return .bonsai4B }
        if gb >= 3 { return .bonsai1_7B }
        return nil
        #endif
    }()

    /// Whether the device can run any on-device model.
    static var deviceSupportsLocalModels: Bool { supportedOnDeviceModel != nil }

    // MARK: - BigBro Configuration

    /// The model a paired Mac is asked to answer with.
    ///
    /// This is BigBro's own catalog id, not an Ollama tag. The Mac no longer proxies to Ollama
    /// — it runs MLX in process — so `gpt-oss-20b` is what its catalog, its download progress
    /// and its `missingModels` all call this model. It still resolves the older `gpt-oss:20b`
    /// loosely, but naming the canonical id keeps every message keyed the way the Mac reports
    /// it: `modelDownloads["gpt-oss-20b"]` is looked up by exactly this string.
    static let bigBroModel = "gpt-oss-20b"

    /// How long the Mac's model deliberates before answering.
    ///
    /// gpt-oss always reasons — the Harmony template carries a budget, not an off switch — and
    /// `.low` is the closest thing to skipping it. Cooking questions are short and wanted while
    /// a pan is on the heat, so the shortest analysis pass is the right trade. Named outright
    /// rather than left to `think: false`, which the Mac reads as a request for speed and
    /// lowers to `.low` on our behalf: saying it here keeps the intent if that inference
    /// changes.
    static let bigBroReasoningEffort: ReasoningEffort = .low

    /// What the active provider + model can do, in production. DEBUG = always full.
    var capability: AICapability {
        #if DEBUG
        return .full
        #else
        switch currentProvider {
        case .bigBro:
            return bigBroClient.isConnected ? .full : .none
        case .local:
            guard let model = LLMService.supportedOnDeviceModel else { return .none }
            return model.isFullCapability ? .full : .limited
        }
        #endif
    }

    /// Whether an opportunistic (non-user-initiated) LLM pass can run right now without
    /// surprising the user with a first-time multi-GB on-device model download. True for
    /// BigBro (network-based, no local download) or when the on-device model the user
    /// would use is already downloaded.
    var isReadyForOpportunisticCleanup: Bool {
        switch currentProvider {
        case .bigBro:
            return true
        case .local:
            guard let model = LLMService.supportedOnDeviceModel else { return false }
            return isModelDownloaded(model.modelId)
        }
    }

    // MARK: - Published State
    @Published var isGenerating = false
    @Published var loadError: String?
    @Published var loadProgress: Double = 0.0
    @Published var isLoadingModel = false
    /// Models whose weights are on disk. Downloaded is not running — see ``runningModelIds``.
    @Published var downloadedModelIds: Set<String> = []
    /// Models whose weights are in memory right now, and therefore costing RAM. A cooking
    /// session puts one here when it opens and takes it back out when it ends.
    @Published private(set) var runningModelIds: Set<String> = []
    /// True while the Mac is materializing the model's weights ahead of the first message.
    @Published private(set) var isStartingBigBroModel = false
    @Published var currentProvider: LLMProvider = .local {
        didSet { UserDefaults.standard.set(currentProvider.rawValue, forKey: "little-chef.llm-provider") }
    }

    // MARK: - Private State
    /// Containers keyed by model ID — allows both 8B and 4B to be loaded
    private var modelContainers: [String: MLXLMCommon.ModelContainer] = [:]
    /// Which model ID is currently being loaded (to prevent double-loads)
    @Published var currentlyLoadingModelId: String?
    /// Bumped by every `stopModel`, so a load already in flight can see that it was stopped.
    private var stopGeneration = 0
    /// Set while a cooking session has the on-device model in memory on purpose.
    ///
    /// Not a lock — just the answer to "is anyone still using this?", which one-off work needs
    /// before putting the model away. See ``releaseModelIfIdle()``.
    var isModelHeldBySession = false

    let bigBroClient = BigBroClient(appName: "LittleChef", requiredModels: [LLMService.bigBroModel])

    private var cancellables: Set<AnyCancellable> = []
    private var startModelTask: Task<Void, Never>?
    /// Stamps each start attempt, so a cancelled one still sitting in `await` cannot clear the
    /// live one's state on its way out.
    private var startModelGeneration = 0
    private var didStartSpeechForConnection = false

    private init() {
        if LLMService.deviceSupportsLocalModels {
            currentProvider = .local
        } else {
            currentProvider = .bigBro
        }
        refreshDownloadedModels()
        observeBigBroConnection()
        // Restore BigBro auto-reconnect from previous launches.
        bigBroClient.resumeAutoReconnectIfEnabled()
    }

    /// Refresh which models are cached on disk.
    func refreshDownloadedModels() {
        var ids = Set<String>()
        for choice in CookingModelChoice.allCases {
            if isModelDownloaded(choice.modelId) {
                ids.insert(choice.modelId)
            }
        }
        downloadedModelIds = ids
    }

    // MARK: - BigBro Model Lifecycle

    /// Starts the Mac's model the moment there is a Mac to start it on.
    ///
    /// BigBro loads a model lazily, on whichever request happens to be first, and a cold 20B
    /// model takes several seconds to materialize. Left alone that cost lands on the user's
    /// first question; started here it overlaps with them getting to a recipe.
    private func observeBigBroConnection() {
        bigBroClient.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .connected:
                    self.runBigBroModel()
                case .disconnected:
                    self.cancelBigBroModelStart()
                    self.didStartSpeechForConnection = false
                case .reconnecting:
                    break
                }
            }
            .store(in: &cancellables)
    }

    /// Asks the Mac to put the model's weights in memory, without generating anything.
    ///
    /// Fire-and-forget by design. Every failure here is one the next request handles on its
    /// own — a model still downloading, a Mac too old to know the message, a connection that
    /// drops in between — and none is worth an error in the UI for an optimization the user
    /// never asked for.
    ///
    /// Deliberately has no stop counterpart. Models are shared by every device paired with that
    /// Mac, so stopping one on our way out would take it away from whatever else is using it;
    /// stopping belongs to whoever owns the Mac, in BigBro's own Settings.
    func runBigBroModel() {
        guard startModelTask == nil else { return }   // already starting; a second ask is redundant
        isStartingBigBroModel = true
        startModelGeneration &+= 1
        let generation = startModelGeneration
        startModelTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bigBroClient.runModel(LLMService.bigBroModel)
                dprint("🌐 [BigBro] \(LLMService.bigBroModel) running")
            } catch {
                dprint("🌐 [BigBro] run skipped: \(error.localizedDescription)")
            }
            guard self.startModelGeneration == generation else { return }
            self.isStartingBigBroModel = false
            self.startModelTask = nil
        }
    }

    private func cancelBigBroModelStart() {
        startModelGeneration &+= 1
        startModelTask?.cancel()
        startModelTask = nil
        isStartingBigBroModel = false
    }

    /// Starts the Mac's speech models — Kokoro and Parakeet — ahead of the first spoken turn.
    ///
    /// Same lazy-load problem as a language model, and worse in a voice loop: the cold load
    /// lands on the user's first words, which is exactly the moment hands-free looks broken.
    /// Once per connection is enough; a running model stays running until the Mac stops it.
    ///
    /// `BigBroVoiceSession` does this itself on `start()`, so this is for the paths that speak
    /// without a session — an answer read aloud after a typed question.
    func runBigBroSpeech() {
        guard bigBroClient.isConnected, !didStartSpeechForConnection else { return }
        didStartSpeechForConnection = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bigBroClient.runSpeech()
                dprint("🔊 [BigBro] speech models running")
            } catch {
                dprint("🔊 [BigBro] speech start skipped: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - On-Device Model Lifecycle
    //
    // Four states, the same four BigBro gives a Mac's models, and the distinctions matter for
    // the same reasons:
    //
    //   download / remove — weights on disk. Gigabytes over somebody's connection to get back,
    //                       so both are the user's decision, made in Settings.
    //   run / stop        — weights in memory. Seconds to get back and gigabytes of RAM to
    //                       hold, so the app decides: a cooking session runs the model when it
    //                       opens and stops it when it ends.
    //
    // What the app must never do is conflate them. Stopping a model to reclaim RAM is free to
    // undo; deleting one is not.

    private func loadModel(modelId: String? = nil) async throws -> MLXLMCommon.ModelContainer {
        let id = modelId ?? CookingModelChoice.bonsai8B.modelId

        if let container = modelContainers[id] {
            dprint("🤖 [LLM] Model \(id) already loaded, returning cached container")
            return container
        }

        guard currentlyLoadingModelId != id else {
            dprint("🤖 [LLM] Model \(id) already loading, waiting...")
            while currentlyLoadingModelId == id {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let container = modelContainers[id] { return container }
            throw LLMError.loadFailed("Model failed to load")
        }

        // Unload any other model first — only one model in memory at a time
        for existingId in modelContainers.keys where existingId != id {
            dprint("🤖 [LLM] Unloading \(existingId) before loading \(id)")
            modelContainers.removeValue(forKey: existingId)
        }
        refreshRunningModels()
        MLX.Memory.clearCache()

        // A load cannot be cancelled once MLX is inside it, so a stop that lands while this is
        // running is recorded rather than obeyed, and honoured on the way out. Without it,
        // ending a cooking session during the few seconds its model takes to start leaves
        // several gigabytes resident with nothing to ask.
        let stopMark = stopGeneration

        dprint("🤖 [LLM] Starting model load for \(id)...")
        currentlyLoadingModelId = id
        isLoadingModel = true
        loadProgress = 0.0
        loadError = nil

        MLX.Memory.cacheLimit = 20 * 1024 * 1024

        let config = ModelConfiguration(id: id, defaultPrompt: "You are a helpful assistant.")

        do {
            dprint("🤖 [LLM] Calling LLMModelFactory.loadContainer for \(id)...")
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            ) { progress in
                Task { @MainActor in
                    self.loadProgress = progress.fractionCompleted
                    if Int(progress.fractionCompleted * 100) % 25 == 0 {
                        dprint("🤖 [LLM] Download progress: \(Int(progress.fractionCompleted * 100))%")
                    }
                }
            }

            dprint("🤖 [LLM] ✅ Model \(id) loaded successfully")
            loadProgress = 1.0
            isLoadingModel = false
            currentlyLoadingModelId = nil
            refreshDownloadedModels()
            if stopMark == stopGeneration {
                self.modelContainers[id] = container
                refreshRunningModels()
            } else {
                // Stopped while this was loading. Whoever awaited it still gets the container
                // and can finish the request it was for; nothing holds it afterwards.
                dprint("🤖 [LLM] \(id) finished loading after a stop — not keeping it resident")
                MLX.Memory.clearCache()
            }
            return container
        } catch {
            dprint("🤖 [LLM] ❌ Model \(id) load failed: \(error)")
            dprint("🤖 [LLM] Error type: \(type(of: error))")
            loadError = error.localizedDescription
            isLoadingModel = false
            currentlyLoadingModelId = nil
            throw error
        }
    }

    /// Download a model to disk cache without keeping it loaded in memory.
    ///
    /// Downloaded and running are different states, the same way they are on a Mac: weights on
    /// disk cost only disk, weights in memory cost RAM. This pays the first cost and not the
    /// second.
    func downloadModel(modelId: String) async throws {
        _ = try await loadModel(modelId: modelId)
        // Downloading is not running. Loading is how MLX fetches the weights, so this ends up
        // holding them; drop them again rather than leaving several GB resident because
        // somebody visited Settings.
        stopModel(modelId: modelId)
        dprint("🤖 [LLM] Downloaded \(modelId) to cache, unloaded from memory")
    }

    /// Deletes a model's weights from disk.
    ///
    /// Destructive and irreversible over a multi-gigabyte re-download, which is why — exactly
    /// as on the Mac, where a client can stop a model but only the Mac's owner can remove one —
    /// this is reachable from Settings and from nowhere else. Stops the model first: freeing
    /// the memory is meaningless once the files are gone, and MLX should not be left holding a
    /// container whose weights no longer exist.
    func removeModel(modelId: String) throws {
        stopModel(modelId: modelId)
        let location = Self.modelCacheURL(modelId)
        if FileManager.default.fileExists(atPath: location.path) {
            try FileManager.default.removeItem(at: location)
        }
        refreshDownloadedModels()
        dprint("🤖 [LLM] Removed \(modelId) from disk")
    }

    /// Puts a downloaded model's weights in memory, ahead of the first message.
    ///
    /// The on-device counterpart of `BigBroClient.runModel`, and named to match it: safe to
    /// skip, safe to call twice. Unlike the Mac's, this one downloads the model if it isn't on
    /// disk — which is why the session prewarm checks first, so nothing starts a multi-gigabyte
    /// download on the user's behalf.
    func runModel(modelId: String? = nil) async throws {
        _ = try await loadModel(modelId: modelId)
    }

    /// Stops the on-device model unless a cooking session is holding it.
    ///
    /// Importing a recipe loads the model on demand and, without this, left several gigabytes
    /// resident long after the import finished — the same leak that separating running from
    /// downloading is meant to close. A session is the one thing that keeps it: it started the
    /// model deliberately and stops it when it ends.
    func releaseModelIfIdle() {
        guard currentProvider == .local, !isModelHeldBySession else { return }
        stopModel()
    }

    /// Frees the memory a model was holding, keeping its download.
    ///
    /// The opposite of `runModel`, not a delete — `nil` stops every loaded model. Unlike the
    /// Mac's, nothing else is sharing this model, so stopping it costs no one else anything.
    func stopModel(modelId: String? = nil) {
        // Counted even when nothing is loaded: the case this exists for is a stop that arrives
        // while a model is still on its way into memory.
        stopGeneration &+= 1
        if let modelId {
            guard modelContainers.removeValue(forKey: modelId) != nil else { return }
            dprint("🤖 [LLM] Stopped \(modelId)")
        } else {
            guard !modelContainers.isEmpty else { return }
            dprint("🤖 [LLM] Stopped \(modelContainers.count) model(s)")
            modelContainers.removeAll()
        }
        refreshRunningModels()
        loadProgress = 0.0
        MLX.Memory.clearCache()
    }

    /// Check if a model has been downloaded to the HuggingFace hub cache.
    func isModelDownloaded(_ modelId: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.modelCacheURL(modelId).path)
    }

    /// MLX Swift stores models at `<CachesDirectory>/models/<org>/<repo>`.
    private static func modelCacheURL(_ modelId: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("models/\(modelId)")
    }

    private func refreshRunningModels() {
        runningModelIds = Set(modelContainers.keys)
    }

    // MARK: - Chat

    /// Answers `messages` with whichever provider is active, streaming text deltas.
    ///
    /// Shaped after `BigBroClient.chat` so the two providers are one call site rather than two
    /// parallel ones:
    ///
    /// - `streaming: false` yields exactly one value — the whole answer — then finishes.
    /// - Tool calls never reach the caller. They are executed here and their results take the
    ///   model's tool-call block's place in the stream.
    /// - Reasoning never reaches the caller either. A model that thinks out loud has its trace
    ///   routed to `onThinking`, which is what keeps `<think>` blocks out of a chat bubble.
    ///
    /// - Parameters:
    ///   - model: On-device model id. Ignored by the BigBro path, which names
    ///     ``bigBroModel`` — the Mac keeps no default and will not guess one.
    ///   - format: Constrains the answer. Honoured by the Mac; the on-device path has no
    ///     grammar to constrain with and relies on the prompt saying so, which is why callers
    ///     that need JSON ask for it in both places.
    func chat(
        _ messages: [ChatMessage],
        model: String? = nil,
        streaming: Bool = true,
        tools: CookingTools? = nil,
        format: ResponseFormat? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        onThinking: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let provider = currentProvider
        return AsyncThrowingStream { continuation in
            let work = Task { @MainActor in
                self.isGenerating = true
                defer { self.isGenerating = false }
                do {
                    switch provider {
                    case .bigBro:
                        try await self.runBigBroChat(
                            messages: messages, streaming: streaming, tools: tools,
                            format: format, temperature: temperature, maxTokens: maxTokens,
                            onThinking: onThinking, into: continuation
                        )
                    case .local:
                        try await self.runLocalChat(
                            messages: messages, modelId: model, streaming: streaming,
                            tools: tools, format: format, temperature: temperature,
                            maxTokens: maxTokens, onThinking: onThinking, into: continuation
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Iterating a stream does not cancel what produces it, so without this a caller
            // that walks away — an ended session, a barge-in — leaves a model generating an
            // answer nobody will read.
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Whole-answer convenience over ``chat(_:model:streaming:tools:format:temperature:maxTokens:onThinking:)``.
    func generateChatCompletion(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: CookingTools? = nil,
        modelId: String? = nil,
        format: ResponseFormat? = nil
    ) async throws -> String {
        var output = ""
        for try await chunk in chat(
            messages, model: modelId, streaming: false, tools: tools,
            format: format, temperature: temperature, maxTokens: maxTokens
        ) {
            output += chunk
        }
        return output
    }

    /// Streaming convenience — calls `onChunk` with each delta and returns the whole answer.
    func generateChatCompletionStreaming(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: CookingTools? = nil,
        modelId: String? = nil,
        format: ResponseFormat? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        var output = ""
        for try await chunk in chat(
            messages, model: modelId, streaming: true, tools: tools,
            format: format, temperature: temperature, maxTokens: maxTokens
        ) {
            output += chunk
            if !chunk.isEmpty { onChunk(chunk) }
        }
        return output
    }

    // MARK: - On-Device Chat

    private func runLocalChat(
        messages: [ChatMessage],
        modelId: String?,
        streaming: Bool,
        tools: CookingTools?,
        format: ResponseFormat?,
        temperature: Float?,
        maxTokens: Int?,
        onThinking: (@Sendable (String) -> Void)?,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        if format != nil {
            // Said out loud rather than dropped: MLX has no response-format switch here, so a
            // caller that needs JSON has to have asked for it in the prompt as well.
            dprint("🤖 [LLM] response format is prompt-only on device")
        }

        let container = try await loadModel(modelId: modelId)

        let chatMessages: [Chat.Message] = messages.map { msg in
            switch msg.role {
            case .system: return .system(msg.content)
            case .user: return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            }
        }

        let userInput = UserInput(chat: chatMessages, tools: tools?.nativeToolSpecs)

        let stream: AsyncStream<Generation> = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(
                maxTokens: maxTokens ?? 2048,
                temperature: temperature ?? 0.7
            )
            return try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context
            )
        }

        var parser = ResponseStreamParser()
        var answer = ""
        var nativeToolCalls: [(name: String, arguments: [String: Any])] = []

        /// Text-tagged tool calls and native ones both end up here.
        func run(_ name: String, _ arguments: [String: Any]) -> String? {
            guard let tools else { return nil }
            dprint("=== TOOL CALL: \(name), args: \(arguments) ===")
            let result = tools.execute(toolName: name, arguments: arguments)
            dprint("=== TOOL RESULT: \(result) ===")
            return result
        }

        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            let delta = answer.isEmpty ? text : (answer.hasSuffix("\n") ? text : "\n" + text)
            answer += delta
            if streaming { continuation.yield(delta) }
        }

        func handle(_ piece: ResponseStreamParser.Piece) {
            switch piece {
            case .answer(let text):
                answer += text
                if streaming { continuation.yield(text) }
            case .thinking(let text):
                onThinking?(text)
            case .toolCall(let body):
                guard let call = Self.decodeToolCall(body) else {
                    dprint("🤖 [LLM] Discarding an unparseable tool call: \(body.prefix(200))")
                    return
                }
                if let result = run(call.name, call.arguments) { emit(result) }
            }
        }

        for await generation in stream {
            if Task.isCancelled { break }
            switch generation {
            case .chunk(let chunk):
                for piece in parser.consume(chunk) { handle(piece) }
            case .info:
                break
            case .toolCall(let toolCall):
                let args = toolCall.function.arguments.mapValues { $0.anyValue }
                nativeToolCalls.append((name: toolCall.function.name, arguments: args))
            @unknown default:
                break
            }
        }

        for piece in parser.finish() { handle(piece) }

        // Native tool calls arrive out of band rather than inside the text, so they are run
        // after the stream ends. Their results are appended the same way.
        for call in nativeToolCalls {
            if let result = run(call.name, call.arguments) { emit(result) }
        }

        let finalAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        dprint("=== OUTPUT: '\(finalAnswer.prefix(200))' | TOOL CALLS: \(nativeToolCalls.count) ===")
        if !streaming { continuation.yield(finalAnswer) }
    }

    /// Decodes the JSON body of a `<tool_call>` block some templates emit as plain text
    /// instead of as a native tool call.
    private static func decodeToolCall(_ body: String) -> (name: String, arguments: [String: Any])? {
        guard let data = body.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        return (name, (json["arguments"] as? [String: Any]) ?? [:])
    }

    // MARK: - BigBro Chat

    private func bigBroMessages(from messages: [ChatMessage]) -> [BigBroKit.Message] {
        messages.map { msg in
            switch msg.role {
            case .system: return BigBroKit.Message(role: .system, content: msg.content)
            case .user: return BigBroKit.Message(role: .user, content: msg.content)
            case .assistant: return BigBroKit.Message(role: .assistant, content: msg.content)
            }
        }
    }

    private func runBigBroChat(
        messages: [ChatMessage],
        streaming: Bool,
        tools: CookingTools?,
        format: ResponseFormat?,
        temperature: Float?,
        maxTokens: Int?,
        onThinking: (@Sendable (String) -> Void)?,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let toolList = tools?.bigBroTools ?? []
        let options = GenerationOptions(
            temperature: temperature.map { Double($0) },
            numPredict: maxTokens
        )

        let started = Date()
        dprint("🌐 [BigBro] chat → model=\(Self.bigBroModel) msgs=\(messages.count) tools=\(toolList.count) format=\(format == nil ? "free" : "json") temp=\(temperature ?? -1) maxTokens=\(maxTokens ?? -1) connected=\(bigBroClient.isConnected)")
        if !bigBroClient.missingModels.isEmpty {
            dprint("🌐 [BigBro] ⚠️ Missing models on Mac: \(bigBroClient.missingModels)")
        }

        var chunkCount = 0
        var attemptedDownloadWait = false
        while true {
            do {
                for try await chunk in bigBroClient.chat(
                    bigBroMessages(from: messages),
                    model: Self.bigBroModel,
                    streaming: streaming,
                    tools: toolList,
                    format: format,
                    options: options,
                    // Forward the reasoning trace only when somebody is listening for it —
                    // the effort below is what decides how much the model actually does.
                    think: onThinking != nil,
                    reasoningEffort: Self.bigBroReasoningEffort,
                    onThinking: onThinking
                ) {
                    continuation.yield(chunk)
                    chunkCount += 1
                }
                let elapsed = Date().timeIntervalSince(started)
                dprint("🌐 [BigBro] ✅ chat done in \(String(format: "%.2f", elapsed))s, chunks=\(chunkCount)")
                if !bigBroClient.modelNotes.isEmpty {
                    dprint("🌐 [BigBro] model notes: \(bigBroClient.modelNotes.joined(separator: " "))")
                }
                return
            } catch let BigBroError.modelDownloading(model, alreadyInProgress) {
                guard !attemptedDownloadWait else {
                    dprint("🌐 [BigBro] ❌ Model still downloading after one wait — bailing out")
                    throw LLMError.generationFailed("Model '\(model)' is still downloading. Please try again shortly.")
                }
                attemptedDownloadWait = true
                dprint("🌐 [BigBro] ⏳ Model '\(model)' downloading on Mac (alreadyInProgress=\(alreadyInProgress)). Waiting…")
                // Progress is reported into the answer only while streaming. Folded into a
                // single response it would land inside whatever the caller is parsing.
                if streaming {
                    continuation.yield("⏳ Downloading \(model) on your Mac…\n")
                    var lastStatus = ""
                    try await waitForModelDownload(model) { status in
                        guard status != lastStatus else { return }
                        lastStatus = status
                        continuation.yield("\(status)\n")
                    }
                    continuation.yield("✅ Model ready, generating response…\n")
                } else {
                    try await waitForModelDownload(model)
                }
                dprint("🌐 [BigBro] ✅ Model '\(model)' downloaded — retrying chat")
            } catch {
                dprint("🌐 [BigBro] ❌ chat failed after \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(error)")
                throw error
            }
        }
    }

    /// Block until the Mac finishes pulling `model`. Calls `onProgress` with a
    /// short human-readable status string each time progress changes (suitable for
    /// streaming back to the caller).
    private func waitForModelDownload(_ model: String, onProgress: ((String) -> Void)? = nil) async throws {
        var lastStatus: String? = nil
        var lastPercentBucket = -1
        while true {
            try Task.checkCancellation()
            guard let progress = bigBroClient.modelDownloads[model] else {
                // Either not yet started or already removed after completion — give the Mac
                // a brief grace period before assuming we can retry.
                try await Task.sleep(nanoseconds: 250_000_000)
                if bigBroClient.modelDownloads[model] == nil { return }
                continue
            }
            if progress.done {
                if progress.success { return }
                throw LLMError.generationFailed("Model download failed: \(progress.error ?? "unknown error")")
            }
            let bucket = Int(progress.percent * 100) / 5  // emit at 5% increments
            if progress.status != lastStatus || bucket != lastPercentBucket {
                lastStatus = progress.status
                lastPercentBucket = bucket
                let pctText = progress.bytesTotal > 0 ? " \(Int(progress.percent * 100))%" : ""
                onProgress?("⏳ Downloading \(model): \(progress.status)\(pctText)")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Model Info

    func getModelInfo(for choice: CookingModelChoice = .bonsai8B) -> ModelInfo? {
        guard modelContainers[choice.modelId] != nil else { return nil }
        return ModelInfo(
            name: choice.displayName,
            parameters: choice.modelId,
            quantization: "1-bit",
            contextLength: 8192
        )
    }
}

// MARK: - Response Stream Parser

/// Splits a raw on-device token stream into the three things it can contain.
///
/// The Mac does this for its own models before anything is sent — reasoning arrives as separate
/// `thinking` messages and tool calls as `toolCall` messages, so a caller's text stream is only
/// ever the answer. On-device the app has to do it itself, and doing it after the fact (which is
/// what stripping `<think>` from the finished string amounted to) cleaned the returned value but
/// not the stream the chat bubble was already showing: the trace appeared, then vanished when
/// the final message replaced it.
///
/// Tags can straddle chunk boundaries, so text that could still turn out to be the start of one
/// is held back until the next chunk settles it.
struct ResponseStreamParser {
    enum Piece: Equatable {
        case answer(String)
        case thinking(String)
        /// The body of a `<tool_call>` block — JSON naming a tool and its arguments. Emitted
        /// whole; a partial one is useless.
        case toolCall(String)
    }

    private enum Region {
        case answer, thinking, toolCall

        var closingTag: String? {
            switch self {
            case .answer:   return nil
            case .thinking: return "</think>"
            case .toolCall: return "</tool_call>"
            }
        }
    }

    private static let openers: [(tag: String, region: Region)] = [
        ("<think>", .thinking),
        ("<tool_call>", .toolCall),
    ]

    private var buffer = ""
    private var region: Region = .answer

    /// Consumes a raw chunk, returning whatever it made unambiguous.
    mutating func consume(_ chunk: String) -> [Piece] {
        buffer += chunk
        var pieces: [Piece] = []

        while true {
            if let closing = region.closingTag {
                guard let range = buffer.range(of: closing) else { break }
                append(String(buffer[buffer.startIndex..<range.lowerBound]), to: &pieces)
                buffer = String(buffer[range.upperBound...])
                region = .answer
                continue
            }
            // In the answer, whichever tag opens first wins — a `<think>` block can contain
            // the words of a tool call and vice versa.
            let found = Self.openers.compactMap { opener -> (range: Range<String.Index>, region: Region)? in
                buffer.range(of: opener.tag).map { (range: $0, region: opener.region) }
            }
            guard let opener = found.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else { break }
            append(String(buffer[buffer.startIndex..<opener.range.lowerBound]), to: &pieces)
            buffer = String(buffer[opener.range.upperBound...])
            region = opener.region
        }

        // A tool call is only useful whole, so nothing is emitted until it closes. Answer and
        // reasoning text streams as it arrives, minus any tail that could be a tag opening.
        if region != .toolCall {
            let held = heldBackCount()
            if held < buffer.count {
                append(String(buffer.dropLast(held)), to: &pieces)
                buffer = String(buffer.suffix(held))
            }
        }
        return pieces
    }

    /// Flushes whatever the stream ended in the middle of.
    mutating func finish() -> [Piece] {
        var pieces: [Piece] = []
        append(buffer, to: &pieces)
        buffer = ""
        region = .answer
        return pieces
    }

    private func append(_ text: String, to pieces: inout [Piece]) {
        guard !text.isEmpty else { return }
        switch region {
        case .answer:   pieces.append(.answer(text))
        case .thinking: pieces.append(.thinking(text))
        case .toolCall: pieces.append(.toolCall(text))
        }
    }

    /// How much of the buffer's tail could still be the start of a tag we are watching for.
    private func heldBackCount() -> Int {
        let markers = region.closingTag.map { [$0] } ?? Self.openers.map(\.tag)
        return markers.map { Self.partialSuffixLength(of: buffer, matching: $0) }.max() ?? 0
    }

    /// Length of the longest suffix of `text` that is a (proper) prefix of `marker`.
    private static func partialSuffixLength(of text: String, matching marker: String) -> Int {
        let maximum = min(text.count, marker.count - 1)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            if marker.hasPrefix(String(text.suffix(length))) { return length }
        }
        return 0
    }
}

// MARK: - Supporting Types

struct ChatMessage {
    enum Role {
        case system, user, assistant
    }
    let role: Role
    let content: String
}

struct ModelInfo {
    let name: String
    let parameters: String
    let quantization: String
    let contextLength: Int
}

enum LLMError: LocalizedError {
    case modelNotLoaded
    case loadFailed(String)
    case downloadFailed(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Model is not loaded."
        case .loadFailed(let msg): return "Failed to load model: \(msg)"
        case .downloadFailed(let msg): return "Failed to download model: \(msg)"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        }
    }
}
