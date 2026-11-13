//
//  LLMService.swift
//  little-chef
//
//  Every model the app talks to: PrismML Bonsai on-device through MLX, or a paired Mac
//  through BigBroKit. Owns model downloads, loading and memory, and runs each request on
//  whichever backend was asked for.
//

import Combine
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

    /// The largest everyday model this device can run, or nil if none. DEBUG builds always
    /// report the full-capability 9B, so every feature can be exercised on any device.
    ///
    /// Chosen by the app's measured memory limit, not installed RAM. iOS terminates an app at
    /// its own limit, well below the RAM fitted, and `physicalMemory` can read a little under
    /// the nominal size, which put devices a tier down under the old `>= 6` GiB check.
    /// Each model's ``CookingModelChoice/memoryNeeded`` is its own footprint plus the app's.
    static let supportedOnDeviceModel: CookingModelChoice? = {
        #if DEBUG
        return .bonsai2_9B
        #else
        let gib = Double(appMemoryLimit) / 1_073_741_824
        return [CookingModelChoice.bonsai2_9B, .bonsai2_4B, .bonsai2_2B].first { gib >= $0.memoryNeeded }
        #endif
    }()

    /// Whether the device can run any on-device model.
    static var deviceSupportsLocalModels: Bool { supportedOnDeviceModel != nil }

    /// Every on-device model this device can run, largest first. The baseline
    /// ``supportedOnDeviceModel`` plus, where the memory allows, the 27B.
    ///
    /// The 27B is offered alongside the baseline rather than replacing it, and is gated on the
    /// measured limit in DEBUG too: an app that crosses the limit while loading ~7 GB of weights
    /// is terminated, with no error, just a cook that has vanished. Sampled once, from `init`,
    /// before any model has taken a share of it.
    static let onDeviceModelOptions: [CookingModelChoice] = {
        guard let baseline = supportedOnDeviceModel else { return [] }
        let gib = Double(appMemoryLimit) / 1_073_741_824
        return gib >= CookingModelChoice.bonsai2_27B.memoryNeeded ? [.bonsai2_27B, baseline] : [baseline]
    }()

    /// What iOS will let this process use before terminating it: what is left plus what is
    /// already in use. 0 where the call is unsupported, such as the simulator.
    private static var appMemoryLimit: UInt64 {
        let available = UInt64(os_proc_available_memory())
        guard available > 0 else { return 0 }
        return available + footprint
    }

    /// The memory iOS counts against this process: what it compares with the limit.
    private static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func gib(_ bytes: UInt64) -> String {
        String(format: "%.2f GiB", Double(bytes) / 1_073_741_824)
    }

    /// The limit, the footprint and what is left, for device logs. The limit is otherwise only
    /// inferred from the size at which iOS terminated the app.
    private static func logMemory(_ when: String) {
        let available = UInt64(os_proc_available_memory())
        dprint("🤖 [LLM] Memory \(when): footprint \(gib(footprint)), available \(gib(available)), limit \(gib(available + footprint))")
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

    /// What the active provider + model can do right now.
    var capability: AICapability { capability(of: currentProvider) }

    /// What a named provider can do right now. Always full in the Simulator, which has no model.
    ///
    /// Takes the provider rather than reading ``currentProvider`` so a cooking session can ask
    /// about the provider it pinned at start. A session that began on-device must keep
    /// reporting on-device capabilities for its whole life, even if something changes the
    /// app-wide provider underneath it.
    ///
    /// On-device, nothing until the model is downloaded. Reporting what the device *could* run
    /// let a new install start a cook, type a question, and only then be told there was no model.
    func capability(of provider: LLMProvider) -> AICapability {
        #if DEBUG && targetEnvironment(simulator)
        return .full
        #else
        switch provider {
        case .bigBro:
            return bigBroClient.isConnected ? .full : .none
        case .local:
            guard let model = activeOnDeviceModel, isReady(model) else { return .none }
            return model.isFullCapability ? .full : .limited
        }
        #endif
    }

    /// On disk or in memory. Published state only, so views that ask redraw when a download
    /// finishes, and a download in progress doesn't count until it has.
    private func isReady(_ model: CookingModelChoice) -> Bool {
        downloadedModelIds.contains(model.modelId) || loadedModelIds.contains(model.modelId)
    }

    /// Why the assistant can't answer on `provider`, said the way the user puts it right. Nil
    /// when it can.
    func unavailableReason(of provider: LLMProvider) -> String? {
        guard capability(of: provider) == .none else { return nil }
        switch provider {
        case .bigBro:
            return "Connect to your Mac in Settings to use the AI assistant."
        case .local:
            guard let model = activeOnDeviceModel else {
                return "This device can't run the AI assistant itself. Pair a Mac in Settings to use it."
            }
            if downloadingModelId == model.modelId {
                return "The AI model is downloading (\(Int(downloadProgress * 100))%). The assistant is ready when it finishes."
            }
            if currentlyLoadingModelId == model.modelId {
                return "The AI model is downloading (\(Int(loadProgress * 100))%). The assistant is ready when it finishes."
            }
            return "Download the AI model in Settings to use the assistant."
        }
    }

    var unavailableReason: String? { unavailableReason(of: currentProvider) }

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
    /// The model ``ModelDownloader`` is fetching, its progress, and why the last one stopped.
    /// Mirrored here so the views that watch this service redraw as it goes.
    @Published private(set) var downloadingModelId: String?
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadError: String?
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
    @Published var preferredOnDeviceModel: CookingModelChoice = .bonsai2_9B {
        didSet { UserDefaults.standard.set(preferredOnDeviceModel.rawValue, forKey: Self.onDeviceModelKey) }
    }

    private static let providerKey = "little-chef.llm-provider"
    private static let onDeviceModelKey = "little-chef.on-device-model"

    // MARK: - Private State
    /// Containers keyed by model ID, so more than one model can be resident at once
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
        Self.logMemory("at launch")
        if let stored = UserDefaults.standard.string(forKey: Self.onDeviceModelKey),
           let choice = CookingModelChoice(storedValue: stored) {
            preferredOnDeviceModel = choice
        }
        // The last provider chosen on this device, so a cook started before Settings has been
        // opened runs where the user asked. Settings re-reads the synced preference when it
        // appears. A device that can't run a model on-device can only be on BigBro.
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey).flatMap(LLMProvider.init(rawValue:))
        currentProvider = LLMService.deviceSupportsLocalModels ? (storedProvider ?? .local) : .bigBro
        refreshDownloadedModels()
        Self.removeLegacyDownloads()
        let downloader = ModelDownloader.shared
        downloader.$modelId.assign(to: &$downloadingModelId)
        downloader.$progress.assign(to: &$downloadProgress)
        downloader.$error.assign(to: &$downloadError)
        downloader.onFinished = { [weak self] _ in self?.refreshDownloadedModels() }
        downloader.resume()
        // Restore BigBro auto-reconnect from previous launches.
        bigBroClient.resumeAutoReconnectIfEnabled()

        // A memory warning drops the model only when this app is itself close to its limit.
        // It used to drop it on every warning, and on a 6 GB iPhone a warning comes every few
        // minutes of a cook whatever the app does: the 9B was unloaded between questions, and
        // the next one waited 30-40 s to load it and read the whole prompt again (Release build,
        // iPhone 14 Pro, 2026-11-13). The warning is about the device, and iOS ends background
        // apps first; what puts this one at risk is its own headroom. Mid-generation and
        // mid-load it holds on regardless: unloading there fails the answer being waited for.
        //
        // The observer is never removed because the service is a process-lifetime singleton —
        // there is no point at which it should stop listening.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lastMemoryWarning = Date()
                guard let self, !self.loadedModelIds.isEmpty,
                      !self.isGenerating, self.currentlyLoadingModelId == nil else { return }
                MLX.Memory.clearCache()
                let available = UInt64(os_proc_available_memory())
                let unload = available > 0 && available < Self.memoryWarningUnloadHeadroom
                Self.perfLog.notice("memory warning: footprint \(Self.gib(Self.footprint), privacy: .public), available \(Self.gib(available), privacy: .public), \(unload ? "unloading" : "keeping", privacy: .public) the model")
                dprint("🤖 [LLM] ⚠️ Memory warning — \(unload ? "unloading resident models" : "keeping the model"), \(Self.gib(available)) available")
                if unload { self.unloadModel() }
            }
        }
    }

    /// Below this much headroom a memory warning unloads the model. A reply's prefill peaks
    /// 0.3-0.9 GiB above the weights (the 9B: 2.36 GiB of weights, 3.22 GiB at an 8.6k-token
    /// prompt), so less than this left could not answer a long question anyway.
    private static let memoryWarningUnloadHeadroom: UInt64 = 768 * 1024 * 1024

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
        let id = modelId ?? activeOnDeviceModel?.modelId ?? CookingModelChoice.bonsai2_9B.modelId

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
        if modelContainers.keys.contains(where: { $0 != id }) { promptPrefixCache.reset() }
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

        do {
            try await waitForMemory(toLoad: id)
        } catch {
            loadError = error.localizedDescription
            isLoadingModel = false
            currentlyLoadingModelId = nil
            throw error
        }

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
            Self.logMemory("after loading \(id)")
            Self.perfLog.notice("loaded \(id, privacy: .public): footprint \(Self.gib(Self.footprint), privacy: .public)")
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

    /// When iOS last warned that memory is low. See ``waitForMemory(toLoad:)``.
    private var lastMemoryWarning: Date?

    /// How long after a memory warning a load waits. The warning means the whole device is
    /// short, and other apps are still being terminated to make room: on an iPhone 14 Pro a
    /// reload started right after the warning had unloaded the 9B was itself terminated.
    private static let memoryWarningSettleTime: TimeInterval = 5

    /// How long a load waits for this process's allowance to cover the model before giving up.
    private static let memoryWaitLimit: TimeInterval = 10

    /// Wait until loading `id` should fit, or throw ``LLMError/notEnoughMemory``.
    ///
    /// iOS terminates an app that crosses its limit with no error and no second chance, so a
    /// cook whose model can't fit right now is better told so than ended. The model's
    /// ``CookingModelChoice/memoryNeeded`` includes the rest of the app, which the footprint
    /// already counts, so what has to be available is that less ``CookingModelChoice/appAllowance``.
    private func waitForMemory(toLoad id: String) async throws {
        guard let model = CookingModelChoice(modelId: id), os_proc_available_memory() > 0 else { return }
        if let warned = lastMemoryWarning {
            let settle = Self.memoryWarningSettleTime - Date().timeIntervalSince(warned)
            if settle > 0 {
                dprint("🤖 [LLM] Memory warning \(String(format: "%.1f", Self.memoryWarningSettleTime - settle))s ago — waiting before loading \(id)")
                try await Task.sleep(for: .seconds(settle))
            }
        }
        let needed = UInt64((model.memoryNeeded - CookingModelChoice.appAllowance) * 1_073_741_824)
        let deadline = Date().addingTimeInterval(Self.memoryWaitLimit)
        while UInt64(os_proc_available_memory()) < needed {
            guard Date() < deadline else {
                Self.logMemory("refusing to load \(id), which needs \(Self.gib(needed))")
                throw LLMError.notEnoughMemory(model.displayName)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The container for a model that is already on disk, refusing rather than fetching one.
    ///
    /// Asking a question must never be what starts a multi-gigabyte download. That is a
    /// decision made in Settings, behind a size warning and a cellular check, and the privacy
    /// policy promises models download only when the user chooses to.
    private func downloadedModelContainer(modelId: String?) async throws -> MLXLMCommon.ModelContainer {
        let id = modelId ?? activeOnDeviceModel?.modelId ?? CookingModelChoice.bonsai2_9B.modelId
        guard isModelLoaded(id) || isModelDownloaded(id) else {
            throw LLMError.modelNotDownloaded(CookingModelChoice(modelId: id)?.displayName ?? "The AI model")
        }
        return try await loadModel(modelId: id)
    }

    /// Starts downloading a model to the disk cache, in the background (see ``ModelDownloader``).
    /// Returns once the download is under way; ``downloadingModelId`` and ``downloadProgress``
    /// follow it, and ``downloadedModelIds`` gains the model when it lands.
    ///
    /// It used to load the model, which downloaded it as a side effect: over a session iOS stops
    /// when the app leaves the screen, and into memory the user hadn't asked to spend yet.
    func downloadModel(modelId: String) async {
        await ModelDownloader.shared.start(modelId: modelId)
    }

    /// Download and load a model into memory (used internally).
    func preloadModel(modelId: String? = nil) async throws {
        _ = try await loadModel(modelId: modelId)
    }

    func unloadModel(modelId: String? = nil) {
        if !modelContainers.isEmpty { Self.perfLog.notice("unloading \(modelId ?? "every model", privacy: .public)") }
        let unloadedSomething: Bool
        if let modelId {
            unloadedSomething = modelContainers.removeValue(forKey: modelId) != nil
        } else {
            unloadedSomething = !modelContainers.isEmpty
            modelContainers.removeAll()
        }
        loadedModelIds = Set(modelContainers.keys)
        // Its arrays are the model's memory too, and belong to a model no longer loaded.
        promptPrefixCache.reset()
        // Only if nothing is mid-load. Unloading one model while another is downloading used to
        // clear the download's own progress state, leaving Settings showing an idle row over a
        // transfer that was still running.
        if currentlyLoadingModelId == nil {
            isLoadingModel = false
            loadProgress = 0.0
            loadError = nil
        }
        // Only after a model was in memory. With none ever loaded, MLX builds its Metal device here
        // for nothing, and on the Simulator that aborts (in `Device::Device()`), which made Delete
        // All Data crash before it had deleted anything.
        if unloadedSomething { MLX.Memory.clearCache() }
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

    /// Deletes models nothing loads any more: the first Bonsai family (replaced by Bonsai 2),
    /// and anything left where swift-transformers' `HubApi` put models before mlx-swift-lm 3.
    ///
    /// Each is a model the user can neither use nor see in Settings to remove. Off the main
    /// thread: it can be several gigabytes.
    private static func removeLegacyDownloads() {
        let ids = CookingModelChoice.allCases.map(\.modelId) + CookingModelChoice.retiredModelIds
        let directories = ids.flatMap { HubModelStore.legacyDirectories(for: $0) }
            + CookingModelChoice.retiredModelIds.compactMap { HubModelStore.repoDirectory(for: $0) }
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
        guard currentlyLoadingModelId != modelId, downloadingModelId != modelId else {
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
        guard !isGenerating, currentlyLoadingModelId == nil, downloadingModelId == nil else {
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
        preferredOnDeviceModel = .bonsai2_9B
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
            modelId: modelId, provider: provider, responseFormat: responseFormat,
            promptCacheKey: nil, onChunk: nil
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
        promptCacheKey: String? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        try await generate(
            messages: messages, temperature: temperature, maxTokens: maxTokens, tools: tools,
            modelId: modelId, provider: provider, responseFormat: responseFormat,
            promptCacheKey: promptCacheKey, onChunk: onChunk
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
        promptCacheKey: String?,
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
            maxTokens: maxTokens, modelId: modelId, promptCacheKey: promptCacheKey, onChunk: onChunk
        )
    }

    // MARK: - On-device

    private func generateOnDevice(
        messages: [ChatMessage],
        tools: CookingTools?,
        temperature: Float?,
        maxTokens: Int?,
        modelId: String?,
        promptCacheKey: String?,
        onChunk: ((String) -> Void)?
    ) async throws -> String {
        let asked = Date()
        let container = try await downloadedModelContainer(modelId: modelId)
        let loaded = Date()

        let toolSpecs = tools?.nativeToolSpecs
        let additionalContext = templateContext(for: modelId)
        let prefixCache = promptPrefixCache
        // A cooking conversation keeps what the model has already read between questions; see
        // `PromptPrefixCache`. Everything else is read from the start, and leaves it alone.
        let cacheKey = messages.last?.role == .user
            ? promptCacheKey.map { "\($0)|\(modelId ?? activeOnDeviceModel?.modelId ?? "")" }
            : nil

        let reuse = ReuseCount()
        let stream: AsyncStream<Generation> = try await container.perform { (context: ModelContext) in
            // Built here rather than captured: MLX's chat types aren't Sendable, `ChatMessage` is.
            let chat = Self.chatMessages(messages)
            let userInput = UserInput(chat: chat, tools: toolSpecs, additionalContext: additionalContext)
            let lmInput = try await context.processor.prepare(input: userInput)
            var parameters = GenerateParameters(
                maxTokens: maxTokens ?? 2048,
                temperature: temperature ?? 0.7
            )
            // PrismML's non-thinking settings for Bonsai 2, less its presence penalty: 1.5 over
            // the last 64 tokens would fight the repeated keys and quotes of the JSON that recipe
            // parsing and the Suggested ranking ask for.
            parameters.topP = 0.8
            parameters.topK = 20
            // The prompt is read 128 tokens at a time rather than mlx-swift-lm's 512. Measured on
            // the Mac at an 8.6k-token prompt, that cuts peak memory by 0.6 to 0.8 GiB for 5–10%
            // slower prefill, and `memoryNeeded` assumes it.
            parameters.prefill.stepSize = 128

            guard let cacheKey else {
                return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
            }
            let prompt = lmInput.text.tokens.asArray(Int.self)
            let placeholder = UserInput(
                chat: chat.dropLast() + [.user(PromptPrefixCache.placeholderQuestion)],
                tools: toolSpecs, additionalContext: additionalContext)
            let placeholderPrompt = try await context.processor.prepare(input: placeholder).text.tokens.asArray(Int.self)
            let prepared = try prefixCache.prepare(
                prompt: prompt,
                boundary: PromptPrefixCache.boundary(prompt: prompt, placeholderPrompt: placeholderPrompt),
                key: cacheKey, model: context.model, parameters: parameters)
            dprint("🤖 [LLM] prompt \(prompt.count) tokens, \(prefixCache.lastReusedTokenCount) already read, \(prepared.suffix.count) after the settled part")
            reuse.set(prompt: prompt.count, reused: prefixCache.lastReusedTokenCount)
            return try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(prepared.suffix.map(Int32.init))),
                cache: prepared.cache, parameters: parameters, context: context, tools: toolSpecs)
        }

        let prepared = Date()
        var firstToken: Date?
        var info: GenerateCompletionInfo?
        var output = ""
        var toolCalls: [(name: String, arguments: [String: Any])] = []
        var filter = StreamingReplyFilter()
        var streamed = ""

        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                if firstToken == nil { firstToken = Date() }
                output += chunk
                if let onChunk {
                    let visible = filter.feed(chunk)
                    if !visible.isEmpty {
                        streamed += visible
                        onChunk(visible)
                    }
                }
            case .toolCall(let call):
                if firstToken == nil { firstToken = Date() }
                toolCalls.append((call.function.name, call.function.arguments.mapValues { $0.anyValue }))
            case .info(let completion):
                info = completion
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
        Self.logTiming(asked: asked, loaded: loaded, prepared: prepared, firstToken: firstToken,
                       info: info, reuse: reuse, footprint: Self.footprint)

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

    /// The app's messages as mlx-swift-lm's.
    private nonisolated static func chatMessages(_ messages: [ChatMessage]) -> [Chat.Message] {
        messages.map { message -> Chat.Message in
            switch message.role {
            case .system: return .system(message.content)
            case .user: return .user(message.content)
            case .assistant: return .assistant(message.content)
            }
        }
    }

    /// Where an on-device reply's time went, in the unified log so a Release build reports it
    /// too (Console, or `log collect` from a device). Numbers only, never the conversation.
    private static let perfLog = Logger(subsystem: "NagataInc.little-chef", category: "llm-timing")

    private static func logTiming(
        asked: Date, loaded: Date, prepared: Date, firstToken: Date?,
        info: GenerateCompletionInfo?, reuse: ReuseCount, footprint: UInt64
    ) {
        func s(_ t: TimeInterval) -> String { String(format: "%.2f", t) }
        let counts = reuse.get()
        let first = firstToken.map { s($0.timeIntervalSince(asked)) } ?? "-"
        let line = "reply: load \(s(loaded.timeIntervalSince(asked)))s, settled part \(s(prepared.timeIntervalSince(loaded)))s "
            + "(prompt \(counts.prompt), kept \(counts.reused)), first token \(first)s, "
            + "rest of prompt \(info.map { String(format: "%.0f", $0.promptTokensPerSecond) } ?? "-") tok/s, "
            + "decode \(info.map { String(format: "%.1f", $0.tokensPerSecond) } ?? "-") tok/s over \(info?.generationTokenCount ?? 0) tokens, "
            + "footprint \(gib(footprint)), thermal \(ProcessInfo.processInfo.thermalState.rawValue)"
        perfLog.notice("\(line, privacy: .public)")
        dprint("🤖 [LLM] \(line)")
    }

    /// What the cooking assistant has already read, kept between questions. One at a time: a
    /// new cook, another model or an unload starts it over. See `PromptPrefixCache`.
    private let promptPrefixCache = PromptPrefixCache()

    /// Reads a cook's system prompt and tools into the kept cache now, while the cook is
    /// starting, so the first question reads only itself.
    ///
    /// Only for a model already in memory or on disk, like every on-device request: this must
    /// never be what starts a download.
    func prewarmPrompt(system: ChatMessage, tools: CookingTools?, promptCacheKey: String) async {
        guard let model = activeOnDeviceModel else { return }
        do {
            let container = try await downloadedModelContainer(modelId: model.modelId)
            let toolSpecs = tools?.nativeToolSpecs
            let additionalContext = model.templateContext
            let prefixCache = promptPrefixCache
            let queued = Date()
            let read = try await container.perform { (context: ModelContext) -> (waited: TimeInterval, read: TimeInterval) in
                // Timed from here, not from the call: a read-ahead that waited behind another
                // one for the container read nothing itself, and would otherwise log the wait.
                let started = Date()
                let chat = Self.chatMessages([system])
                func tokens(_ question: String) async throws -> [Int] {
                    try await context.processor.prepare(input: UserInput(
                        chat: chat + [.user(question)], tools: toolSpecs, additionalContext: additionalContext
                    )).text.tokens.asArray(Int.self)
                }
                // Two stand-in questions: where their renders part is where any real one begins.
                let prompt = try await tokens("?")
                let placeholderPrompt = try await tokens(PromptPrefixCache.placeholderQuestion)
                var parameters = GenerateParameters()
                parameters.prefill.stepSize = 128
                _ = try prefixCache.prepare(
                    prompt: prompt,
                    boundary: PromptPrefixCache.boundary(prompt: prompt, placeholderPrompt: placeholderPrompt),
                    key: "\(promptCacheKey)|\(model.modelId)", model: context.model, parameters: parameters)
                return (started.timeIntervalSince(queued), Date().timeIntervalSince(started))
            }
            dprint("🤖 [LLM] Read the cook's prompt ahead in \(String(format: "%.1f", read.read))s (\(prefixCache.lastReusedTokenCount) tokens already read, \(String(format: "%.1f", read.waited))s waiting)")
        } catch {
            dprint("🤖 [LLM] ⚠️ Couldn't read the cook's prompt ahead: \(error.localizedDescription)")
        }
    }

    /// The chat-template variables for the model a request will load.
    private func templateContext(for modelId: String?) -> [String: any Sendable]? {
        let id = modelId ?? activeOnDeviceModel?.modelId ?? CookingModelChoice.bonsai2_9B.modelId
        return CookingModelChoice(modelId: id)?.templateContext
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case modelNotDownloaded(String)
    case loadFailed(String)
    case generationFailed(String)
    case notEnoughMemory(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let name):
            return "\(name) isn't downloaded yet. Download it in Settings to use the on-device assistant."
        case .loadFailed(let msg): return "Failed to load model: \(msg)"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        case .notEnoughMemory(let name):
            return "There isn't enough free memory to load \(name) right now. Close other apps and ask again."
        }
    }
}

/// The prompt's size and how much of it was kept, carried out of `container.perform`.
private final class ReuseCount: @unchecked Sendable {
    private let lock = NSLock()
    private var prompt = 0
    private var reused = 0
    func set(prompt: Int, reused: Int) { lock.withLock { self.prompt = prompt; self.reused = reused } }
    func get() -> (prompt: Int, reused: Int) { lock.withLock { (prompt, reused) } }
}
