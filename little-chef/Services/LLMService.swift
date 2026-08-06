//
//  LLMService.swift
//  little-chef
//
//  On-device LLM inference using MLX with PrismML Bonsai 8B 1-bit model.
//  Follows MLXChatExample patterns: lazy load, AsyncStream generation, Memory.cacheLimit.
//  Uses MLX native tool calling for timer operations.
//

import Foundation
import UIKit
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
    @Published var isLoaded = false
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
        didSet { UserDefaults.standard.set(currentProvider.rawValue, forKey: "little-chef.llm-provider") }
    }

    // MARK: - Private State
    /// Containers keyed by model ID — allows both 8B and 4B to be loaded
    private var modelContainers: [String: MLXLMCommon.ModelContainer] = [:]
    /// Which model ID is currently being loaded (to prevent double-loads)
    @Published var currentlyLoadingModelId: String?

    /// The model asked for on the Mac, by its id in BigBro's catalog.
    ///
    /// A catalog id, not an Ollama tag: BigBro runs models in-process through MLX and names
    /// them `gpt-oss-20b`. The old `gpt-oss:20b` spelling is left over from its Ollama-proxy
    /// days and matches nothing, which surfaces as a permanent missing-model warning and a
    /// request the Mac cannot serve.
    static let bigBroModel = "gpt-oss-20b"

    let bigBroClient = BigBroClient(appName: "LittleChef", requiredModels: [LLMService.bigBroModel])

    private let defaultModelConfig = ModelConfiguration(
        id: "prism-ml/Bonsai-8B-mlx-1bit",
        defaultPrompt: "You are a helpful assistant."
    )

    private init() {
        if LLMService.deviceSupportsLocalModels {
            currentProvider = .local
        } else {
            currentProvider = .bigBro
        }
        refreshDownloadedModels()
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
        let id = modelId ?? CookingModelChoice.bonsai8B.modelId

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
            isLoaded = true
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

    /// Download a model to disk cache without keeping it loaded in memory.
    func downloadModel(modelId: String) async throws {
        _ = try await loadModel(modelId: modelId)
        // Unload from memory — the files stay cached on disk
        modelContainers.removeValue(forKey: modelId)
        loadedModelIds = Set(modelContainers.keys)
        isLoaded = !modelContainers.isEmpty
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
        isLoaded = !modelContainers.isEmpty
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

    /// Where a downloaded model's files could be sitting.
    ///
    /// More than one candidate on purpose. The weights are written by `HubApi`, whose
    /// `downloadBase` has moved between releases of swift-transformers and can be overridden by
    /// whatever constructs it — so hard-coding one path is how "Downloaded" stayed unticked
    /// under a model that was fully on disk, and how a delete could silently free nothing.
    /// Every layout the hub has used is checked, and a delete removes all of them.
    private static func candidateModelDirectories(for modelId: String) -> [URL] {
        let fm = FileManager.default
        let searchPaths: [FileManager.SearchPathDirectory] = [
            .documentDirectory, .cachesDirectory, .applicationSupportDirectory,
        ]
        let bases: [URL] = searchPaths.compactMap { fm.urls(for: $0, in: .userDomainMask).first }

        return bases.flatMap { base in
            ["huggingface/models", "models"].map { base.appendingPathComponent("\($0)/\(modelId)") }
        }
    }

    /// The directories that actually exist for `modelId` and hold a usable download.
    private static func existingModelDirectories(for modelId: String) -> [URL] {
        candidateModelDirectories(for: modelId).filter { url in
            // A bare directory isn't a download: an interrupted fetch leaves the folder behind
            // with nothing in it, and reporting that as "Downloaded" sends the next request
            // straight into a load that has to re-fetch everything anyway.
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                return false
            }
            return !contents.isEmpty
        }
    }

    /// Check if a model has been downloaded to the HuggingFace hub cache.
    func isModelDownloaded(_ modelId: String) -> Bool {
        !Self.existingModelDirectories(for: modelId).isEmpty
    }

    /// Total bytes `modelId` occupies on disk, or nil if it isn't downloaded.
    func downloadedSize(of modelId: String) -> Int64? {
        let directories = Self.existingModelDirectories(for: modelId)
        guard !directories.isEmpty else { return nil }

        var total: Int64 = 0
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
                total += Int64(size)
            }
        }
        return total
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

        let directories = Self.existingModelDirectories(for: modelId)
        for directory in directories {
            try FileManager.default.removeItem(at: directory)
            dprint("🤖 [LLM] 🗑️ Removed \(directory.path)")
        }

        refreshDownloadedModels()

        // Belt and braces: if the files are somehow still there, say so rather than let the UI
        // show freed space that wasn't freed.
        if isModelDownloaded(modelId) {
            throw LLMError.loadFailed("The model files are still on disk. Try again after restarting the app.")
        }
        dprint("🤖 [LLM] ✅ Deleted \(modelId) (\(directories.count) director\(directories.count == 1 ? "y" : "ies"))")
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
            guard let model = LLMService.supportedOnDeviceModel else { return false }
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
    /// cold-start cost — several seconds of weight loading on-device, a 20B model starting on
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
            guard let model = LLMService.supportedOnDeviceModel else { return }
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

    func generateChatCompletion(
        messages: [ChatMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        tools: CookingTools? = nil,
        modelId: String? = nil,
        provider: LLMProvider? = nil,
        responseFormat: ResponseFormat? = nil
    ) async throws -> String {
        if (provider ?? currentProvider) == .bigBro {
            return try await generateBigBroChatCompletion(
                messages: messages, tools: tools, temperature: temperature,
                maxTokens: maxTokens, responseFormat: responseFormat
            )
        }

        isGenerating = true
        defer { isGenerating = false }

        let container = try await loadModel(modelId: modelId)

        // Convert to Chat.Message
        let chatMessages: [Chat.Message] = messages.map { msg in
            switch msg.role {
            case .system: return .system(msg.content)
            case .user: return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            }
        }

        // Build native tool specs if tools are provided
        let toolSpecs: [ToolSpec]? = tools?.nativeToolSpecs

        let userInput = UserInput(chat: chatMessages, tools: toolSpecs)

        // Generate using AsyncStream API
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

        // Consume stream — collect text chunks and native tool calls
        var output = ""
        var nativeToolCalls: [(name: String, arguments: [String: Any])] = []

        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                output += chunk
            case .info(_):
                break
            case .toolCall(let toolCall):
                let args = toolCall.function.arguments.mapValues { $0.anyValue }
                nativeToolCalls.append((name: toolCall.function.name, arguments: args))
            @unknown default:
                break
            }
        }
        dprint("=== OUTPUT: '\(output.prefix(200))' | TOOL CALLS: \(nativeToolCalls.count) ===")

        // Execute native tool calls
        if !nativeToolCalls.isEmpty, let tools {
            var toolResults: [String] = []
            for call in nativeToolCalls {
                dprint("=== TOOL CALL: \(call.name), args: \(call.arguments) ===")
                let result = tools.execute(toolName: call.name, arguments: call.arguments)
                dprint("=== TOOL RESULT: \(result) ===")
                toolResults.append(result)
            }
            // Combine any text output with tool results
            let textPart = stripThinkingTags(from: output)
            let toolPart = toolResults.joined(separator: "\n")
            if textPart.isEmpty {
                return toolPart
            }
            return textPart + "\n" + toolPart
        }

        // No native tool calls — clean up text and try fallbacks
        let cleaned = stripThinkingTags(from: output)

        // Try text-based <tool_call> tags first
        let afterTextTools = processTextToolCalls(output: cleaned, tools: tools)

        // If tools are available and no tool calls were found, try to infer timer actions from the text
        if let tools, nativeToolCalls.isEmpty {
            inferTimerAction(from: afterTextTools, tools: tools)
        }

        return afterTextTools
    }

    // MARK: - Streaming Chat Completion

    /// Streaming variant — calls `onChunk` with each text fragment as it arrives.
    /// Returns the full response. If the model emits tool calls, they are executed
    /// and the result is returned (no streaming for tool responses).
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
        if (provider ?? currentProvider) == .bigBro {
            return try await generateBigBroChatCompletionStreaming(
                messages: messages, tools: tools, temperature: temperature,
                maxTokens: maxTokens, responseFormat: responseFormat, onChunk: onChunk
            )
        }

        isGenerating = true
        defer { isGenerating = false }

        let container = try await loadModel(modelId: modelId)

        let chatMessages: [Chat.Message] = messages.map { msg in
            switch msg.role {
            case .system: return .system(msg.content)
            case .user: return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            }
        }

        let toolSpecs: [ToolSpec]? = tools?.nativeToolSpecs
        let userInput = UserInput(chat: chatMessages, tools: toolSpecs)

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

        var output = ""
        var nativeToolCalls: [(name: String, arguments: [String: Any])] = []

        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                output += chunk
                // Stream text chunks to caller in real-time
                if !chunk.isEmpty {
                    onChunk(chunk)
                }
            case .info(_):
                break
            case .toolCall(let toolCall):
                let args = toolCall.function.arguments.mapValues { $0.anyValue }
                nativeToolCalls.append((name: toolCall.function.name, arguments: args))
            @unknown default:
                break
            }
        }

        // Execute native tool calls (not streamed — delivered as final result)
        if !nativeToolCalls.isEmpty, let tools {
            var toolResults: [String] = []
            for call in nativeToolCalls {
                let result = tools.execute(toolName: call.name, arguments: call.arguments)
                toolResults.append(result)
            }
            let textPart = stripThinkingTags(from: output)
            let toolPart = toolResults.joined(separator: "\n")
            let finalResult = textPart.isEmpty ? toolPart : textPart + "\n" + toolPart
            return finalResult
        }

        // No native tool calls — clean up text and try fallbacks
        let cleaned = stripThinkingTags(from: output)
        let afterTextTools = processTextToolCalls(output: cleaned, tools: tools)

        if let tools, nativeToolCalls.isEmpty {
            inferTimerAction(from: afterTextTools, tools: tools)
        }

        return afterTextTools
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

    private struct SendableCookingBox: @unchecked Sendable { let tools: CookingTools }

    /// The cooking tools as BigBroKit tool definitions, for anything that talks to the Mac
    /// directly rather than through ``generateChatCompletion``.
    ///
    /// `BigBroVoiceSession` runs its own tool-calling loop against `converse`, so the
    /// hands-free path needs the same five timer tools this service hands to `chat`. Built
    /// here rather than duplicated there so the two can't drift.
    func bigBroTools(from cookingTools: CookingTools) -> [BigBroTool] {
        let box = SendableCookingBox(tools: cookingTools)
        return [
            BigBroTool(
                definition: BigBroTool.Definition(
                    name: "create_timer",
                    description: "Create a new cooking timer, stopped. This does NOT start it — the user must ask separately before you call start_timer.",
                    parameters: BigBroTool.Definition.Parameters(
                        properties: [
                            "name": .init(type: "string", description: "Timer label e.g. pasta, chicken"),
                            "minutes": .init(type: "integer", description: "Whole minutes (omit or 0 if under a minute)"),
                            "seconds": .init(type: "integer", description: "Additional seconds 0-59")
                        ],
                        required: ["name"]
                    )
                ),
                handler: { args in await MainActor.run { box.tools.execute(toolName: "create_timer", arguments: args) } }
            ),
            BigBroTool(
                definition: BigBroTool.Definition(
                    name: "start_timer",
                    description: "Start or resume an existing timer by name. Only when the user asks to start it, never in the same reply that created it.",
                    parameters: BigBroTool.Definition.Parameters(
                        properties: ["name": .init(type: "string", description: "Timer name to start")],
                        required: ["name"]
                    )
                ),
                handler: { args in await MainActor.run { box.tools.execute(toolName: "start_timer", arguments: args) } }
            ),
            BigBroTool(
                definition: BigBroTool.Definition(
                    name: "stop_timer",
                    description: "Stop a running timer by name, keeping the time left so it can be resumed",
                    parameters: BigBroTool.Definition.Parameters(
                        properties: ["name": .init(type: "string", description: "Timer name to stop")],
                        required: ["name"]
                    )
                ),
                handler: { args in await MainActor.run { box.tools.execute(toolName: "stop_timer", arguments: args) } }
            ),
            BigBroTool(
                definition: BigBroTool.Definition(
                    name: "update_timer",
                    description: "Change an existing timer's duration, its name, or both",
                    parameters: BigBroTool.Definition.Parameters(
                        properties: [
                            "name": .init(type: "string", description: "The timer's current name"),
                            "new_name": .init(type: "string", description: "New label, if renaming"),
                            "minutes": .init(type: "integer", description: "New duration, whole minutes"),
                            "seconds": .init(type: "integer", description: "New duration, additional seconds 0-59")
                        ],
                        required: ["name"]
                    )
                ),
                handler: { args in await MainActor.run { box.tools.execute(toolName: "update_timer", arguments: args) } }
            ),
            BigBroTool(
                definition: BigBroTool.Definition(
                    name: "delete_timer",
                    description: "Delete a timer by name",
                    parameters: BigBroTool.Definition.Parameters(
                        properties: ["name": .init(type: "string", description: "Timer name to delete")],
                        required: ["name"]
                    )
                ),
                handler: { args in await MainActor.run { box.tools.execute(toolName: "delete_timer", arguments: args) } }
            ),
        ]
    }

    /// Block until the Mac finishes pulling `model`. Calls `onProgress` with a
    /// short human-readable status string each time progress changes (suitable for
    /// streaming back through `onChunk`).
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

    private func generateBigBroChatCompletion(
        messages: [ChatMessage],
        tools: CookingTools? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        responseFormat: ResponseFormat? = nil
    ) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }

        let toolList = tools.map { bigBroTools(from: $0) } ?? []
        let options = GenerationOptions(
            temperature: temperature.map { Double($0) },
            numPredict: maxTokens
        )
        // Named by the caller, not inferred from `tools`. Deducing "no tools ⇒ wants JSON" was
        // right for the recipe parser and wrong for everything else: a cooking answer asked for
        // in JSON mode comes back as a JSON blob and is shown to the user verbatim.
        let format = responseFormat

        let started = Date()
        dprint("🌐 [BigBro] chat → model=\(Self.bigBroModel) msgs=\(messages.count) tools=\(toolList.count) format=\(format == nil ? "free" : "json") temp=\(temperature ?? -1) maxTokens=\(maxTokens ?? -1) connected=\(bigBroClient.isConnected)")
        if !bigBroClient.missingModels.isEmpty {
            dprint("🌐 [BigBro] ⚠️ Missing models on Mac: \(bigBroClient.missingModels)")
        }

        var output = ""
        var chunkCount = 0
        var attemptedDownloadWait = false
        chatLoop: while true {
            do {
                for try await chunk in bigBroClient.chat(
                    bigBroMessages(from: messages),
                    model: Self.bigBroModel,
                    streaming: false,
                    tools: toolList,
                    format: format,
                    options: options,
                    think: false
                ) {
                    output += chunk
                    chunkCount += 1
                }
                break chatLoop
            } catch let BigBroError.modelDownloading(model, alreadyInProgress) {
                guard !attemptedDownloadWait else {
                    dprint("🌐 [BigBro] ❌ Model still downloading after one wait — bailing out")
                    throw LLMError.generationFailed("Model '\(model)' is still downloading. Please try again shortly.")
                }
                attemptedDownloadWait = true
                dprint("🌐 [BigBro] ⏳ Model '\(model)' downloading on Mac (alreadyInProgress=\(alreadyInProgress)). Waiting…")
                try await waitForModelDownload(model)
                dprint("🌐 [BigBro] ✅ Model '\(model)' downloaded — retrying chat")
            } catch {
                dprint("🌐 [BigBro] ❌ chat failed after \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(error)")
                throw error
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        dprint("🌐 [BigBro] ✅ chat done in \(String(format: "%.2f", elapsed))s, chunks=\(chunkCount), \(output.count) chars")
        if output.isEmpty {
            dprint("🌐 [BigBro] ⚠️ Empty response from model")
        } else {
            dprint("🌐 [BigBro] response preview: \(output.prefix(300))")
        }
        return output
    }

    private func generateBigBroChatCompletionStreaming(
        messages: [ChatMessage],
        tools: CookingTools? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        responseFormat: ResponseFormat? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }

        let toolList = tools.map { bigBroTools(from: $0) } ?? []
        let options = GenerationOptions(
            temperature: temperature.map { Double($0) },
            numPredict: maxTokens
        )
        let format = responseFormat

        var output = ""
        var attemptedDownloadWait = false
        chatLoop: while true {
            do {
                for try await chunk in bigBroClient.chat(
                    bigBroMessages(from: messages),
                    model: Self.bigBroModel,
                    streaming: true,
                    tools: toolList,
                    format: format,
                    options: options,
                    think: false
                ) {
                    output += chunk
                    if !chunk.isEmpty { onChunk(chunk) }
                }
                break chatLoop
            } catch let BigBroError.modelDownloading(model, alreadyInProgress) {
                guard !attemptedDownloadWait else {
                    throw LLMError.generationFailed("Model '\(model)' is still downloading. Please try again shortly.")
                }
                attemptedDownloadWait = true
                dprint("🌐 [BigBro] ⏳ Model '\(model)' downloading (alreadyInProgress=\(alreadyInProgress))")
                onChunk("⏳ Downloading \(model) on your Mac…\n")
                var lastBucket = -1
                try await waitForModelDownload(model) { status in
                    // Replace previous status line — caller streams will append, so just emit
                    // a new line with the latest status.
                    let bucket = (status as NSString).hash
                    if bucket != lastBucket {
                        lastBucket = bucket
                        onChunk("\(status)\n")
                    }
                }
                onChunk("✅ Model ready, generating response…\n")
            } catch {
                throw error
            }
        }
        return output
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

    // MARK: - Text-based Tool Call Fallback

    private static let textToolCallRegex = try? NSRegularExpression(
        pattern: "<tool_call>\\s*(.+?)\\s*</tool_call>",
        options: .dotMatchesLineSeparators
    )
    private static let timerNameRegex = try? NSRegularExpression(pattern: "['\"]([^'\"]+)['\"]")
    private static let thinkTagRegex = try? NSRegularExpression(
        pattern: "<think>.*?</think>",
        options: .dotMatchesLineSeparators
    )

    /// Fallback parser for models that output <tool_call> tags as text instead of native tool calls
    private func processTextToolCalls(output: String, tools: CookingTools?) -> String {
        guard let tools else { return output }

        guard let regex = Self.textToolCallRegex else {
            return output
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)
        guard !matches.isEmpty else { return output }

        var result = output
        for match in matches.reversed() {
            guard let jsonRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }

            let jsonStr = String(result[jsonRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let toolName = json["name"] as? String,
               let arguments = json["arguments"] as? [String: Any] {
                let toolResult = tools.execute(toolName: toolName, arguments: arguments)
                result.replaceSubrange(fullRange, with: toolResult)
            } else {
                result.replaceSubrange(fullRange, with: "")
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Done!" : trimmed
    }

    // MARK: - Timer Action Inference

    /// When the model responds with text like "Timer stopped" without a tool call,
    /// infer the action and execute it.
    private func inferTimerAction(from text: String, tools: CookingTools) {
        let lower = text.lowercased()

        let nameRange = NSRange(text.startIndex..., in: text)
        let timerName = Self.timerNameRegex?.firstMatch(in: text, range: nameRange)
            .flatMap { Range($0.range(at: 1), in: text) }
            .map { String(text[$0]) }

        let name = timerName ?? "timer"

        // A reply that announces a new timer is describing something already done, and it very
        // often mentions starting in the same breath ("…say start when you're ready"). Inferring
        // from that is how a freshly created timer began counting down on its own.
        if lower.contains("creat") || lower.contains("set for") { return }

        if lower.contains("stop") || lower.contains("paus") {
            _ = tools.execute(toolName: "stop_timer", arguments: ["name": name])
        } else if lower.contains("delet") || lower.contains("remov") || lower.contains("cancel") {
            _ = tools.execute(toolName: "delete_timer", arguments: ["name": name])
        } else if lower.contains("start") || lower.contains("resum") {
            _ = tools.execute(toolName: "start_timer", arguments: ["name": name])
        }
    }

    // MARK: - Text Processing

    private func stripThinkingTags(from text: String) -> String {
        var result = text
        if let regex = Self.thinkTagRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
