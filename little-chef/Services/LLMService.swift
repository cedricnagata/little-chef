//
//  LLMService.swift
//  little-chef
//
//  Every model the app talks to: PrismML Bonsai on-device through MLX, or a paired Mac
//  through BigBroKit. Owns model downloads, loading and memory, and runs each request on
//  whichever backend was asked for.
//

import Foundation
import UIKit
import os
import MLX
import MLXLLM
import MLXLMCommon
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

    /// Every on-device model this device can run, largest first. The baseline
    /// ``supportedOnDeviceModel`` plus, where the memory allows, the 27B.
    ///
    /// The 27B is gated on the app's own memory limit rather than on installed RAM, and in
    /// DEBUG too. iOS caps each app well below the RAM fitted (raised by the
    /// increased-memory-limit entitlement), and an app that crosses the cap while loading ~7 GB
    /// of weights is terminated: no error, just a cook that has vanished. Measuring the limit
    /// asks the question that actually decides that. Sampled once, from `init`, before any
    /// model has taken a share of it.
    static let onDeviceModelOptions: [CookingModelChoice] = {
        guard let baseline = supportedOnDeviceModel else { return [] }
        let gib = Double(appMemoryLimit) / 1_073_741_824
        return gib >= 9 ? [.bonsai27BTernary, baseline] : [baseline]
    }()

    /// What iOS will let this process use before terminating it: what is left plus what is
    /// already in use. 0 where the call is unsupported, such as the simulator.
    private static var appMemoryLimit: UInt64 {
        let available = UInt64(os_proc_available_memory())
        guard available > 0 else { return 0 }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return available + (result == KERN_SUCCESS ? info.phys_footprint : 0)
    }

    /// The on-device model in use: the one picked in Settings if this device can run it,
    /// otherwise the baseline.
    ///
    /// The pick is kept per device in `UserDefaults`, not in the synced preferences. What a
    /// device can run and what it has downloaded are both facts about that device, and a 27B
    /// chosen on an iPad means nothing to the phone it would sync to.
    var activeOnDeviceModel: CookingModelChoice? {
        Self.onDeviceModelOptions.contains(preferredOnDeviceModel)
            ? preferredOnDeviceModel
            : Self.supportedOnDeviceModel
    }

    /// What the active provider + model can do, in production. DEBUG = always full.
    var capability: AICapability { capability(of: currentProvider) }

    /// What a named provider can do, in production. DEBUG = always full.
    ///
    /// Takes the provider rather than reading ``currentProvider`` so a cooking session can ask
    /// about the provider it pinned at start. A session that began on-device must keep
    /// reporting on-device capabilities for its whole life, even if something changes the
    /// app-wide provider underneath it.
    func capability(of provider: LLMProvider) -> AICapability {
        #if DEBUG
        return .full
        #else
        switch provider {
        case .bigBro:
            return bigBroClient.isConnected ? .full : .none
        case .local:
            guard let model = activeOnDeviceModel else { return .none }
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
            guard let model = activeOnDeviceModel else { return false }
            return isModelDownloaded(model.modelId)
        }
    }

    // MARK: - Published State
    @Published var isGenerating = false
    @Published var loadError: String?
    @Published var loadProgress: Double = 0.0
    @Published var isLoadingModel = false
    @Published var downloadedModelIds: Set<String> = []
    /// Which model ids currently hold weights in memory.
    ///
    /// Mirrors `modelContainers`, which is private and not observable. Settings needs to show
    /// whether a model is merely on disk or actually resident — those cost the user very
    /// different amounts of RAM, and until this existed there was no way to tell them apart,
    /// let alone act on the difference.
    @Published private(set) var loadedModelIds: Set<String> = []
    @Published var currentProvider: LLMProvider = .local {
        didSet { UserDefaults.standard.set(currentProvider.rawValue, forKey: Self.providerKey) }
    }
    /// The on-device model picked in Settings. Read through ``activeOnDeviceModel``, which
    /// falls back when this device can't run it.
    @Published var preferredOnDeviceModel: CookingModelChoice = .bonsai8B {
        didSet { UserDefaults.standard.set(preferredOnDeviceModel.rawValue, forKey: Self.onDeviceModelKey) }
    }

    private static let providerKey = "little-chef.llm-provider"
    private static let onDeviceModelKey = "little-chef.on-device-model"

    // MARK: - Private State
    /// Containers keyed by model ID — allows both 8B and 4B to be loaded
    private var modelContainers: [String: MLXLMCommon.ModelContainer] = [:]
    /// Which model ID is currently being loaded (to prevent double-loads)
    @Published var currentlyLoadingModelId: String?

    /// The model asked for on the Mac, by its id in BigBro's catalog.
    ///
    /// A catalog id, not an Ollama tag: BigBro runs models in-process through MLX and names
    /// them `bonsai-27b-ternary`. An id the catalog doesn't carry surfaces as a permanent
    /// missing-model warning and a request the Mac cannot serve.
    ///
    /// A Qwen3.6-architecture model, so `think: false` on the chat calls turns its reasoning
    /// off through `enable_thinking` rather than only hiding it, which is all it did for gpt-oss.
    static let bigBroModel = "bonsai-27b-ternary"

    let bigBroClient = BigBroClient(appName: "LittleChef", requiredModels: [LLMService.bigBroModel])

    private init() {
        _ = Self.onDeviceModelOptions
        if let stored = UserDefaults.standard.string(forKey: Self.onDeviceModelKey),
           let choice = CookingModelChoice(rawValue: stored) {
            preferredOnDeviceModel = choice
        }
        // The last provider chosen on this device, so a cook started before Settings has been
        // opened runs where the user asked. Settings re-reads the synced preference when it
        // appears. A device that can't run a model on-device can only be on BigBro.
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey).flatMap(LLMProvider.init(rawValue:))
        currentProvider = LLMService.deviceSupportsLocalModels ? (storedProvider ?? .local) : .bigBro
        refreshDownloadedModels()
        Self.removeLegacyDownloads()
        // Restore BigBro auto-reconnect from previous launches.
        bigBroClient.resumeAutoReconnectIfEnabled()

        // A resident 8B model is several gigabytes the system can't reclaim on its own, and iOS
        // kills the app rather than asking twice. Dropping the weights on the warning turns an
        // out-of-memory termination into a reload on the next question. Mid-generation is the
        // one time to hold on: unloading there fails the answer the user is waiting for.
        //
        // The observer is never removed because the service is a process-lifetime singleton —
        // there is no point at which it should stop listening.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.loadedModelIds.isEmpty,
                      !self.isGenerating, self.currentlyLoadingModelId == nil else { return }
                dprint("🤖 [LLM] ⚠️ Memory warning — unloading resident models")
                self.unloadModel()
            }
        }
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

    // MARK: - Model Lifecycle

    private func loadModel(modelId: String? = nil) async throws -> MLXLMCommon.ModelContainer {
        let id = modelId ?? activeOnDeviceModel?.modelId ?? CookingModelChoice.bonsai8B.modelId

        if let container = modelContainers[id] {
            dprint("🤖 [LLM] Model \(id) already loaded, returning cached container")
            return container
        }

        guard currentlyLoadingModelId != id else {
            dprint("🤖 [LLM] Model \(id) already loading, waiting...")
            // Bounded, because the alternative is unbounded: a loader that dies without
            // clearing `currentlyLoadingModelId` — cancelled, or killed mid-download — would
            // otherwise leave every later caller spinning here for the life of the process.
            let deadline = Date().addingTimeInterval(600)
            while currentlyLoadingModelId == id, Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                try Task.checkCancellation()
            }
            if let container = modelContainers[id] { return container }
            throw LLMError.loadFailed("Model failed to load")
        }

        // Unload any other model first — only one model in memory at a time
        for existingId in modelContainers.keys where existingId != id {
            dprint("🤖 [LLM] Unloading \(existingId) before loading \(id)")
            modelContainers.removeValue(forKey: existingId)
        }
        loadedModelIds = Set(modelContainers.keys)
        MLX.Memory.clearCache()

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
                from: HubDownloader(),
                using: TransformersTokenizerLoader(),
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
            self.modelContainers[id] = container
            loadedModelIds = Set(modelContainers.keys)
            loadProgress = 1.0
            isLoadingModel = false
            currentlyLoadingModelId = nil
            refreshDownloadedModels()
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

    /// The container for a model that is already on disk, refusing rather than fetching one.
    ///
    /// Asking a question must never be what starts a multi-gigabyte download. That is a
    /// decision made in Settings, behind a size warning and a cellular check, and the privacy
    /// policy promises models download only when the user chooses to.
    private func downloadedModelContainer(modelId: String?) async throws -> MLXLMCommon.ModelContainer {
        let id = modelId ?? activeOnDeviceModel?.modelId ?? CookingModelChoice.bonsai8B.modelId
        guard isModelLoaded(id) || isModelDownloaded(id) else {
            throw LLMError.modelNotDownloaded(CookingModelChoice(modelId: id)?.displayName ?? "The AI model")
        }
        return try await loadModel(modelId: id)
    }

    /// Download a model to disk cache without keeping it loaded in memory.
    func downloadModel(modelId: String) async throws {
        _ = try await loadModel(modelId: modelId)
        // Unload from memory — the files stay cached on disk
        modelContainers.removeValue(forKey: modelId)
        loadedModelIds = Set(modelContainers.keys)
        MLX.Memory.clearCache()
        refreshDownloadedModels()
        dprint("🤖 [LLM] Downloaded \(modelId) to cache, unloaded from memory")
    }

    /// Download and load a model into memory (used internally).
    func preloadModel(modelId: String? = nil) async throws {
        _ = try await loadModel(modelId: modelId)
    }

    func unloadModel(modelId: String? = nil) {
        if let modelId {
            modelContainers.removeValue(forKey: modelId)
        } else {
            modelContainers.removeAll()
        }
        loadedModelIds = Set(modelContainers.keys)
        // Only if nothing is mid-load. Unloading one model while another is downloading used to
        // clear the download's own progress state, leaving Settings showing an idle row over a
        // transfer that was still running.
        if currentlyLoadingModelId == nil {
            isLoadingModel = false
            loadProgress = 0.0
            loadError = nil
        }
        MLX.Memory.clearCache()
        dprint("🤖 [LLM] Unloaded \(modelId ?? "all models"); resident: \(loadedModelIds)")
    }

    func isModelLoaded(_ modelId: String) -> Bool {
        return modelContainers[modelId] != nil
    }

    // MARK: - On-Disk Model Cache

    /// Check if a model has been downloaded to the hub cache.
    func isModelDownloaded(_ modelId: String) -> Bool {
        HubModelStore.hasSnapshot(of: modelId)
    }

    /// Total bytes `modelId` occupies on disk, or nil if it isn't downloaded.
    ///
    /// Counts regular files only. A snapshot is a directory of symlinks into the repo's blobs,
    /// so following both would report every model at twice its size.
    func downloadedSize(of modelId: String) -> Int64? {
        guard isModelDownloaded(modelId), let directory = HubModelStore.repoDirectory(for: modelId),
              let enumerator = FileManager.default.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
              ) else { return nil }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Deletes models left where swift-transformers' `HubApi` put them before mlx-swift-lm 3.
    ///
    /// The new downloader never reads them, so each is a model the user can neither use nor see
    /// in Settings to remove. Off the main thread: it can be several gigabytes.
    private static func removeLegacyDownloads() {
        let directories = CookingModelChoice.allCases.flatMap { HubModelStore.legacyDirectories(for: $0.modelId) }
        Task.detached(priority: .utility) {
            for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
                dprint("🤖 [LLM] 🗑️ Removed legacy download \(directory.path)")
            }
        }
    }

    /// Evicts `modelId` from memory *and* removes its files from disk.
    ///
    /// The unload has to happen first and has to be unconditional: deleting the weights out
    /// from under a live `ModelContainer` frees no memory at all — the container still holds
    /// every array it mapped in — so a "delete" that skipped it would report gigabytes
    /// reclaimed while the app's footprint didn't move.
    ///
    /// - Throws: ``LLMError/generationFailed`` if a generation is in flight, and whatever
    ///   `FileManager` throws if the files can't be removed.
    func deleteModel(modelId: String) throws {
        guard !isGenerating else {
            throw LLMError.generationFailed("Can't remove a model while it's answering. Try again in a moment.")
        }
        guard currentlyLoadingModelId != modelId else {
            throw LLMError.generationFailed("Can't remove a model while it's downloading.")
        }

        unloadModel(modelId: modelId)

        if let directory = HubModelStore.repoDirectory(for: modelId),
           FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
            dprint("🤖 [LLM] 🗑️ Removed \(directory.path)")
        }

        refreshDownloadedModels()

        // Belt and braces: if the files are somehow still there, say so rather than let the UI
        // show freed space that wasn't freed.
        if isModelDownloaded(modelId) {
            throw LLMError.loadFailed("The model files are still on disk. Try again after restarting the app.")
        }
        dprint("🤖 [LLM] ✅ Deleted \(modelId)")
    }

    /// Removes every downloaded model and puts the model settings back to their defaults.
    ///
    /// Clears the whole hub cache rather than walking the known models, so a model this
    /// version no longer lists is not left behind as gigabytes nothing can see.
    ///
    /// - Throws: ``LLMError/generationFailed`` while a model is answering or downloading.
    func deleteAllModels() throws {
        guard !isGenerating, currentlyLoadingModelId == nil else {
            throw LLMError.generationFailed("Can't remove models while one is answering or downloading. Try again in a moment.")
        }
        unloadModel()

        let fm = FileManager.default
        let root = HubModelStore.rootDirectory
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try fm.removeItem(at: item)
        }
        refreshDownloadedModels()

        UserDefaults.standard.removeObject(forKey: Self.onDeviceModelKey)
        UserDefaults.standard.removeObject(forKey: Self.providerKey)
        preferredOnDeviceModel = .bonsai8B
        currentProvider = LLMService.deviceSupportsLocalModels ? .local : .bigBro
        dprint("🤖 [LLM] ✅ Deleted all models")
    }

    // MARK: - Session Warm-Up

    /// Whether ``prepareForSession(provider:)`` has anything to do.
    ///
    /// Asked before the warm-up starts so the cooking view doesn't flash a "getting ready" line
    /// over work that finishes in a millisecond — a model already resident, or a Mac that isn't
    /// connected and has nothing to warm.
    func needsWarmUp(for provider: LLMProvider) -> Bool {
        switch provider {
        case .local:
            guard let model = activeOnDeviceModel else { return false }
            return isModelDownloaded(model.modelId) && !isModelLoaded(model.modelId)
        case .bigBro:
            // No way to ask the Mac what it already has running, and `runModel` on a running
            // model is a fast no-op, so this is always worth doing when there's a Mac to do it on.
            return bigBroClient.isConnected
        }
    }

    /// Gets the backend ready to answer *before* the user asks anything.
    ///
    /// Both providers load lazily on whichever request happens to be first, which put the whole
    /// cold-start cost — several seconds of weight loading on-device, a 27B model starting on
    /// the Mac — on the user's first question, where it reads as a hung assistant rather than a
    /// model warming up. Starting it when the cook starts moves that wait to a moment the UI
    /// can label.
    ///
    /// Best-effort by design: it never downloads anything, and a failure here costs nothing
    /// beyond the cold start it was trying to avoid, so it is logged rather than surfaced.
    /// Safe to call more than once, and cancellable — ending the session drops it.
    func prepareForSession(provider: LLMProvider) async {
        switch provider {
        case .local:
            guard let model = activeOnDeviceModel else { return }
            // Downloading is a multi-gigabyte, user-consented decision made in Settings. Warming
            // up must not turn starting a cook into one.
            guard isModelDownloaded(model.modelId) else {
                dprint("🤖 [LLM] Warm-up skipped: \(model.modelId) isn't downloaded")
                return
            }
            guard !isModelLoaded(model.modelId) else { return }
            do {
                dprint("🤖 [LLM] Warming up \(model.modelId)…")
                _ = try await loadModel(modelId: model.modelId)
                dprint("🤖 [LLM] ✅ Warm-up complete")
            } catch is CancellationError {
                dprint("🤖 [LLM] Warm-up cancelled")
            } catch {
                dprint("🤖 [LLM] ⚠️ Warm-up failed: \(error.localizedDescription)")
            }

        case .bigBro:
            guard bigBroClient.isConnected else { return }
            do {
                dprint("🌐 [BigBro] Warming up \(Self.bigBroModel)…")
                try await bigBroClient.runModel(Self.bigBroModel)
                dprint("🌐 [BigBro] ✅ Warm-up complete")
            } catch {
                // Includes `modelDownloading`, which the chat path already knows how to wait
                // out. Nothing useful to do here but let the first message handle it.
                dprint("🌐 [BigBro] ⚠️ Warm-up failed: \(error.localizedDescription)")
            }
        }
    }

    /// Starts the Mac's speech models, so a hands-free loop's first spoken turn isn't the thing
    /// that pays for loading them. Same best-effort contract as ``prepareForSession(provider:)``.
    func prepareSpeechForSession(provider: LLMProvider) async {
        guard provider == .bigBro, bigBroClient.isConnected else { return }
        do {
            try await bigBroClient.runSpeech()
            dprint("🌐 [BigBro] ✅ Speech models ready")
        } catch {
            dprint("🌐 [BigBro] ⚠️ Speech warm-up failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Chat Completion

    /// One answer, whole.
    func generateChatCompletion(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: CookingTools? = nil,
        modelId: String? = nil,
        provider: LLMProvider? = nil,
        responseFormat: ResponseFormat? = nil
    ) async throws -> String {
        try await generate(
            messages: messages, temperature: temperature, maxTokens: maxTokens, tools: tools,
            modelId: modelId, provider: provider, responseFormat: responseFormat, onChunk: nil
        )
    }

    /// One answer, streamed: `onChunk` gets the visible text as it generates, and the return
    /// value is the finished reply — which can differ, since tool results and clean-up come at
    /// the end.
    func generateChatCompletionStreaming(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: CookingTools? = nil,
        modelId: String? = nil,
        provider: LLMProvider? = nil,
        responseFormat: ResponseFormat? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        try await generate(
            messages: messages, temperature: temperature, maxTokens: maxTokens, tools: tools,
            modelId: modelId, provider: provider, responseFormat: responseFormat, onChunk: onChunk
        )
    }

    private func generate(
        messages: [ChatMessage],
        temperature: Float?,
        maxTokens: Int?,
        tools: CookingTools?,
        modelId: String?,
        provider: LLMProvider?,
        responseFormat: ResponseFormat?,
        onChunk: ((String) -> Void)?
    ) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }

        if (provider ?? currentProvider) == .bigBro {
            return try await generateOnBigBro(
                messages: messages, tools: tools, temperature: temperature,
                maxTokens: maxTokens, responseFormat: responseFormat, onChunk: onChunk
            )
        }
        return try await generateOnDevice(
            messages: messages, tools: tools, temperature: temperature,
            maxTokens: maxTokens, modelId: modelId, onChunk: onChunk
        )
    }

    // MARK: - On-device

    private func generateOnDevice(
        messages: [ChatMessage],
        tools: CookingTools?,
        temperature: Float?,
        maxTokens: Int?,
        modelId: String?,
        onChunk: ((String) -> Void)?
    ) async throws -> String {
        let container = try await downloadedModelContainer(modelId: modelId)

        let userInput = UserInput(
            chat: messages.map { message -> Chat.Message in
                switch message.role {
                case .system: return .system(message.content)
                case .user: return .user(message.content)
                case .assistant: return .assistant(message.content)
                }
            },
            tools: tools?.nativeToolSpecs,
            additionalContext: templateContext(for: modelId)
        )

        let stream: AsyncStream<Generation> = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(
                maxTokens: maxTokens ?? 2048,
                temperature: temperature ?? 0.7
            )
            return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
        }

        var output = ""
        var toolCalls: [(name: String, arguments: [String: Any])] = []
        var filter = StreamingReplyFilter()
        var streamed = ""

        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                output += chunk
                if let onChunk {
                    let visible = filter.feed(chunk)
                    if !visible.isEmpty {
                        streamed += visible
                        onChunk(visible)
                    }
                }
            case .toolCall(let call):
                toolCalls.append((call.function.name, call.function.arguments.mapValues { $0.anyValue }))
            default:
                // Reasoning, completion info, rejected tool calls: none of it is the answer.
                break
            }
        }
        if let onChunk {
            let rest = filter.finish()
            if !rest.isEmpty {
                streamed += rest
                onChunk(rest)
            }
        }
        dprint("🤖 [LLM] output: '\(output.prefix(200))' | tool calls: \(toolCalls.count)")

        let reply = finishOnDeviceReply(output, toolCalls: toolCalls, tools: tools)
        // Tool results arrive at the end, after the text. Streamed too, so they are shown and
        // spoken like the rest of the answer instead of only appearing once it's over.
        if let onChunk {
            let extra = ModelReplyText.unstreamedSuffix(of: reply, after: streamed)
            if !extra.isEmpty { onChunk(extra) }
        }
        return reply
    }

    /// The reply the user gets: the model's text without its reasoning, with any tool calls run.
    ///
    /// Tool results are `forUser` throughout. Nothing on this path feeds them back to the model
    /// for another turn; they are the reply, shown on screen and read out loud.
    private func finishOnDeviceReply(
        _ output: String,
        toolCalls: [(name: String, arguments: [String: Any])],
        tools: CookingTools?
    ) -> String {
        let text = ModelReplyText.strippingThinking(output)
        guard let tools else { return text }

        if !toolCalls.isEmpty {
            let results = toolCalls.map { call -> String in
                dprint("🤖 [LLM] tool call: \(call.name) \(call.arguments)")
                return tools.execute(toolName: call.name, arguments: call.arguments).forUser
            }
            .joined(separator: "\n")
            return text.isEmpty ? results : text + "\n" + results
        }

        // Models that write tool calls as text instead of making them.
        let reply = ModelReplyText.replacingToolCalls(in: text) { name, arguments in
            tools.execute(toolName: name, arguments: arguments).forUser
        }
        // And models that describe a timer action without calling anything.
        if let action = TimerActionInference.action(for: reply) {
            _ = tools.execute(toolName: action.tool, arguments: ["name": action.timerName])
        }
        return reply
    }

    // MARK: - BigBro

    private func generateOnBigBro(
        messages: [ChatMessage],
        tools: CookingTools?,
        temperature: Float?,
        maxTokens: Int?,
        responseFormat: ResponseFormat?,
        onChunk: ((String) -> Void)?
    ) async throws -> String {
        let toolList = tools.map { bigBroTools(from: $0) } ?? []
        let options = GenerationOptions(temperature: temperature.map { Double($0) }, numPredict: maxTokens)
        let bigBroMessages = messages.map { message -> BigBroKit.Message in
            switch message.role {
            case .system: return BigBroKit.Message(role: .system, content: message.content)
            case .user: return BigBroKit.Message(role: .user, content: message.content)
            case .assistant: return BigBroKit.Message(role: .assistant, content: message.content)
            }
        }
        if !bigBroClient.missingModels.isEmpty {
            dprint("🌐 [BigBro] ⚠️ Missing models on Mac: \(bigBroClient.missingModels)")
        }

        var waitedForDownload = false
        while true {
            var output = ""
            do {
                // `responseFormat` is named by the caller, never inferred from `tools`: a cooking
                // answer asked for in JSON mode comes back as a JSON blob shown verbatim.
                for try await chunk in bigBroClient.chat(
                    bigBroMessages,
                    model: Self.bigBroModel,
                    streaming: onChunk != nil,
                    tools: toolList,
                    format: responseFormat,
                    options: options,
                    think: false
                ) {
                    output += chunk
                    if !chunk.isEmpty { onChunk?(chunk) }
                }
                return output
            } catch let BigBroError.modelDownloading(model, _) {
                guard !waitedForDownload else {
                    throw LLMError.generationFailed("Your Mac is still downloading \(model). Try again in a few minutes.")
                }
                waitedForDownload = true
                // Said once rather than as a running percentage: this streams into the chat and
                // the speech queue, and a line every few percent is a lot to read or hear.
                onChunk?("Your Mac is downloading the model first, which can take a few minutes.\n")
                try await waitForModelDownload(model)
            } catch let BigBroError.toolLoopLimit(rounds) {
                let answer = Self.answerForCappedToolLoop(output, rounds: rounds)
                // Only the part the caller hasn't already been streamed.
                if answer != output { onChunk?(String(answer.dropFirst(output.count))) }
                return answer
            }
        }
    }

    private struct SendableCookingBox: @unchecked Sendable { let tools: CookingTools }

    /// The cooking tools as BigBroKit tool definitions, for anything that talks to the Mac
    /// directly rather than through ``generateChatCompletion``.
    ///
    /// `BigBroVoiceSession` runs its own tool-calling loop against `converse`, so the
    /// hands-free path needs the same tools this service hands to `chat`. Both are now projected
    /// from ``CookingTools/toolSpecs`` rather than written out twice: the two lists had to be
    /// kept in step by hand, and a tool added to one and forgotten in the other is a capability
    /// that silently exists on-device and not over BigBro.
    func bigBroTools(from cookingTools: CookingTools) -> [BigBroTool] {
        let box = SendableCookingBox(tools: cookingTools)
        return cookingTools.toolSpecs.map { spec in
            // Captured as a plain `String` rather than reaching into `spec` from the handler,
            // which has to be sendable.
            let toolName = spec.name
            return BigBroTool(
                definition: BigBroTool.Definition(
                    name: spec.name,
                    description: spec.description,
                    parameters: BigBroTool.Definition.Parameters(
                        properties: spec.parameters.reduce(into: [:]) { properties, parameter in
                            properties[parameter.name] = .init(
                                type: parameter.type,
                                description: parameter.description
                            )
                        },
                        required: spec.requiredParameterNames
                    )
                ),
                // `forModel`: BigBroKit appends this as a `tool` message and runs another round,
                // so this is the one place that wants the resulting list.
                handler: { args in
                    await MainActor.run { box.tools.execute(toolName: toolName, arguments: args).forModel }
                }
            )
        }
    }

    /// Waits until the Mac has finished downloading `model`.
    private func waitForModelDownload(_ model: String) async throws {
        while true {
            try Task.checkCancellation()
            guard let progress = bigBroClient.modelDownloads[model] else {
                // Either not started yet or already cleared after finishing — give the Mac a
                // moment before assuming it's done.
                try await Task.sleep(nanoseconds: 250_000_000)
                if bigBroClient.modelDownloads[model] == nil { return }
                continue
            }
            if progress.done {
                if progress.success { return }
                throw LLMError.generationFailed("Model download failed: \(progress.error ?? "unknown error")")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// What to say when BigBroKit's tool loop hit `maxToolRounds` without the model answering.
    ///
    /// Not rethrown, because the turn is not lost: every tool already ran, so the recipe edits are
    /// in the session's working copy and will be offered for saving when the cook ends. Reporting
    /// a failure would put "Failed to get response" in front of someone whose recipe did change.
    /// Any text the model did produce is kept — a capped loop often has a usable half-answer in it.
    private static func answerForCappedToolLoop(_ output: String, rounds: Int) -> String {
        dprint("🌐 [BigBro] ⚠️ tool loop capped at \(rounds) rounds with no final answer")
        guard output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return output }
        return "I got caught repeating myself there, so I have stopped. "
             + "Have a look at the recipe and tell me what still needs changing."
    }

    /// The chat-template variables for the model a request will load.
    private func templateContext(for modelId: String?) -> [String: any Sendable]? {
        let id = modelId ?? activeOnDeviceModel?.modelId ?? CookingModelChoice.bonsai8B.modelId
        return CookingModelChoice(modelId: id)?.templateContext
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case modelNotDownloaded(String)
    case loadFailed(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let name):
            return "\(name) isn't downloaded yet. Download it in Settings to use the on-device assistant."
        case .loadFailed(let msg): return "Failed to load model: \(msg)"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        }
    }
}
