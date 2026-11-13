//
//  ModelDownloader.swift
//  little-chef
//
//  Downloads on-device models with a background URLSession, so a download carries on while
//  the user is in another app, and after iOS has ended LittleChef.
//
//  The Hub's own downloader can't do this: `HubClient` replaces a background session with an
//  ordinary one (swift-huggingface #99), and an ordinary session's transfers stop when iOS
//  suspends the app, a few seconds after it leaves the screen. That was a multi-gigabyte download
//  failing with "the network connection was lost" whenever the user switched away (2026-11-13).
//  So the Hub is asked only what to fetch; the files come down here and are filed into the same
//  cache, where the loader finds them without fetching anything.
//

import Foundation
import HuggingFace
import UIKit
import UserNotifications

@MainActor
final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    /// The model downloading now, or nil.
    @Published private(set) var modelId: String?
    @Published private(set) var progress: Double = 0
    /// Why the last download stopped. Cleared when one starts.
    @Published private(set) var error: String?

    /// Told when a model has finished, so the service can show it as downloaded.
    var onFinished: (@MainActor (String) -> Void)?

    /// iOS's completion handler for a relaunch that delivered this session's events. Called once
    /// every event is handled, which lets iOS snapshot the app and suspend it again.
    var backgroundEventsCompletion: (() -> Void)?

    private static let sessionIdentifier = "\(Bundle.main.bundleIdentifier ?? "little-chef").model-download"
    /// How often a file that failed mid-transfer is picked up again before the download gives up.
    private static let retryLimit = 3

    private let delegate = SessionDelegate()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Started by the user, behind the size and cellular warnings in Settings: run it now,
        // on whatever connection they agreed to.
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    private var plan: ModelDownloadPlan?
    private var layout: ModelDownloadLayout?
    /// Bytes already in finished blobs, and bytes received so far by each running task.
    private var finishedBytes: Int64 = 0
    private var runningBytes: [Int: Int64] = [:]
    private var retries: [String: Int] = [:]

    private init() {
        delegate.owner = self
    }

    // MARK: - Starting and resuming

    /// Starts downloading `modelId`, or picks up where an earlier attempt stopped: files already
    /// in the cache aren't fetched again.
    func start(modelId: String) async {
        guard self.modelId == nil else { return }
        self.modelId = modelId
        progress = 0
        error = nil
        retries = [:]
        do {
            guard let layout = Self.layout(for: modelId) else {
                throw HubModelError.invalidRepositoryID(modelId)
            }
            let plan = try await Self.makePlan(for: modelId)
            try layout.savePlan(plan)
            dprint("📥 [Download] \(modelId) at \(plan.commit.prefix(8)): \(plan.files.count) files, \(plan.totalBytes) bytes")
            await run(plan, in: layout)
        } catch {
            fail("Couldn't start the download: \(error.localizedDescription)")
        }
    }

    /// Reconnects to a download still running from an earlier launch, and restarts the files of
    /// one that was interrupted (a force-quit cancels a background session's transfers). Call
    /// at launch: it also creates the session, which iOS needs before it delivers its events.
    func resume() {
        _ = session
        guard modelId == nil else { return }
        for choice in CookingModelChoice.allCases {
            guard let layout = Self.layout(for: choice.modelId), let plan = layout.loadPlan() else { continue }
            dprint("📥 [Download] Resuming \(choice.modelId)")
            modelId = choice.modelId
            Task { await run(plan, in: layout) }
            return
        }
    }

    /// Stops any download and forgets it. Files already fetched stay until the model is deleted.
    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
        layout?.removePlan()
        reset()
    }

    private func run(_ plan: ModelDownloadPlan, in layout: ModelDownloadLayout) async {
        self.plan = plan
        self.layout = layout
        finishedBytes = layout.downloadedBytes(of: plan)
        runningBytes = [:]

        let tasks = await session.allTasks.compactMap { $0 as? URLSessionDownloadTask }
        var running = Set<String>()
        for task in tasks {
            guard let tag = TaskTag.parse(task.taskDescription), tag.modelId == plan.modelId,
                  task.state == .running || task.state == .suspended else { continue }
            running.insert(tag.path)
            runningBytes[task.taskIdentifier] = task.countOfBytesReceived
            task.resume()
        }
        let missing = layout.missingFiles(of: plan)
        for file in missing where !running.contains(file.path) {
            enqueue(file, of: plan)
        }
        updateProgress()
        if missing.isEmpty { finish() }
    }

    private func enqueue(_ file: ModelDownloadPlan.File, of plan: ModelDownloadPlan, resumeData: Data? = nil) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            let url = URL(string: "https://huggingface.co")!
                .appending(path: plan.modelId)
                .appending(path: "resolve")
                .appending(component: plan.commit)
                .appending(path: file.path)
            task = session.downloadTask(with: url)
        }
        task.taskDescription = TaskTag.make(modelId: plan.modelId, path: file.path)
        task.countOfBytesClientExpectsToReceive = file.size
        task.resume()
    }

    // MARK: - Session events

    fileprivate func received(_ bytes: Int64, task: Int) {
        guard plan != nil else { return }
        runningBytes[task] = bytes
        updateProgress()
    }

    fileprivate func completed(task: Int, path: String, modelId: String, error: Error?) {
        guard let plan, plan.modelId == modelId, let layout else { return }
        runningBytes[task] = nil
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled, nsError.domain == NSURLErrorDomain,
               nsError.userInfo[NSURLSessionDownloadTaskResumeData] == nil { return }
            let attempts = retries[path, default: 0] + 1
            retries[path] = attempts
            guard attempts <= Self.retryLimit, let file = plan.files.first(where: { $0.path == path }) else {
                dprint("📥 [Download] ❌ \(path): \(error)")
                Task { await stop(because: "The download stopped: \(error.localizedDescription) Tap Download to carry on from where it got to.") }
                return
            }
            dprint("📥 [Download] Retrying \(path) (\(attempts)): \(error.localizedDescription)")
            enqueue(file, of: plan, resumeData: nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
            return
        }
        finishedBytes = layout.downloadedBytes(of: plan)
        updateProgress()
        if layout.missingFiles(of: plan).isEmpty { finish() }
    }

    fileprivate func finishedEvents() {
        backgroundEventsCompletion?()
        backgroundEventsCompletion = nil
    }

    // MARK: - Finishing

    private func finish() {
        guard let plan, let layout else { return }
        do {
            try layout.finish(plan)
        } catch {
            fail("The model downloaded but couldn't be saved: \(error.localizedDescription)")
            return
        }
        dprint("📥 [Download] ✅ \(plan.modelId)")
        let modelId = plan.modelId
        reset()
        onFinished?(modelId)
        if UIApplication.shared.applicationState != .active {
            Self.announce(modelId)
        }
    }

    private func stop(because message: String) async {
        for task in await session.allTasks { task.cancel() }
        fail(message)
    }

    private func fail(_ message: String) {
        reset()
        error = message
    }

    private func reset() {
        plan = nil
        layout = nil
        modelId = nil
        progress = 0
        finishedBytes = 0
        runningBytes = [:]
    }

    private func updateProgress() {
        guard let plan, plan.totalBytes > 0 else { return }
        let done = finishedBytes + runningBytes.values.reduce(0, +)
        let fraction = min(1, Double(done) / Double(plan.totalBytes))
        // Published at most every tenth of a percent, so a gigabyte doesn't redraw Settings
        // a hundred thousand times.
        if Int(fraction * 1000) != Int(progress * 1000) { progress = fraction }
    }

    /// A notification when the model finishes while the user is elsewhere. Says nothing when
    /// notifications aren't allowed.
    private static func announce(_ modelId: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(CookingModelChoice(modelId: modelId)?.displayName ?? "The AI model") is ready"
        content.body = "The on-device assistant has finished downloading."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "model-download-\(modelId)", content: content, trigger: nil))
    }

    // MARK: - Plan

    nonisolated static func layout(for modelId: String) -> ModelDownloadLayout? {
        HubModelStore.repoDirectory(for: modelId).map(ModelDownloadLayout.init(repoDirectory:))
    }

    /// Asks the Hub which commit is current and which of its files the loader reads.
    private static func makePlan(for modelId: String) async throws -> ModelDownloadPlan {
        guard let repo = Repo.ID(rawValue: modelId) else { throw HubModelError.invalidRepositoryID(modelId) }
        let client = HubClient(cache: HubModelStore.cache)
        guard let commit = try await client.getModel(repo).sha, ModelDownloadPlan.isSafeEtag(commit) else {
            throw DownloadError.notAModel(modelId)
        }
        let files = try await client.listFiles(in: repo, revision: commit, recursive: true).compactMap { entry -> ModelDownloadPlan.File? in
            guard entry.type == .file, ModelDownloadPlan.wants(entry.path), ModelDownloadPlan.isSafe(entry.path),
                  let etag = entry.lfs?.oid ?? entry.oid, ModelDownloadPlan.isSafeEtag(etag),
                  let size = entry.effectiveSize else { return nil }
            return ModelDownloadPlan.File(path: entry.path, etag: etag, size: Int64(size))
        }
        guard files.contains(where: { $0.path == "config.json" }),
              files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw DownloadError.notAModel(modelId)
        }
        return ModelDownloadPlan(modelId: modelId, commit: commit, files: files)
    }
}

/// Which model and file a task is fetching, kept in its `taskDescription`, which a background
/// session hands back after a relaunch.
private enum TaskTag {
    static func make(modelId: String, path: String) -> String { "\(modelId)\n\(path)" }

    static func parse(_ description: String?) -> (modelId: String, path: String)? {
        guard let description, let split = description.firstIndex(of: "\n") else { return nil }
        return (String(description[..<split]), String(description[description.index(after: split)...]))
    }
}

/// The session's delegate. Called on the session's own queue, and does the one thing that can't
/// wait for the main actor itself: moving a finished file, which is deleted when
/// `didFinishDownloadingTo` returns.
private final class SessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: ModelDownloader?

    private let lock = NSLock()
    /// Why a finished file couldn't be kept, by task, until its completion reports it.
    private var storeErrors: [Int: Error] = [:]
    private var lastReport: [Int: Date] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = TaskTag.parse(downloadTask.taskDescription) else { return }
        let (modelId, path) = tag
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw DownloadError.status(status) }
            guard let layout = ModelDownloader.layout(for: modelId), let plan = layout.loadPlan(),
                  let file = plan.files.first(where: { $0.path == path }) else { throw DownloadError.noPlan }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value
            guard size == file.size else { throw DownloadError.size(expected: file.size, got: size ?? -1) }
            try layout.store(location, as: file)
        } catch {
            lock.withLock { storeErrors[downloadTask.taskIdentifier] = error }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        let now = Date()
        let due = lock.withLock { () -> Bool in
            guard now.timeIntervalSince(lastReport[id] ?? .distantPast) > 0.25 else { return false }
            lastReport[id] = now
            return true
        }
        guard due else { return }
        Task { @MainActor [weak owner] in owner?.received(totalBytesWritten, task: id) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let tag = TaskTag.parse(task.taskDescription) else { return }
        let (modelId, path) = tag
        let id = task.taskIdentifier
        let failure = lock.withLock { () -> Error? in
            lastReport[id] = nil
            return storeErrors.removeValue(forKey: id) ?? error
        }
        Task { @MainActor [weak owner] in owner?.completed(task: id, path: path, modelId: modelId, error: failure) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak owner] in owner?.finishedEvents() }
    }
}

private enum DownloadError: LocalizedError {
    case status(Int)
    case noPlan
    case size(expected: Int64, got: Int64)
    case notAModel(String)

    var errorDescription: String? {
        switch self {
        case .status(let code): return "The server answered \(code)."
        case .noPlan: return "The download's record was missing."
        case .size(let expected, let got): return "A file arrived with \(got) of its \(expected) bytes."
        case .notAModel(let id): return "Hugging Face has no complete model at \(id)."
        }
    }
}
