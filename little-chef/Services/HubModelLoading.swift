//
//  HubModelLoading.swift
//  little-chef
//
//  Connects mlx-swift-lm's downloader and tokenizer protocols to Hugging Face's packages.
//
//  mlx-swift-lm 3 no longer downloads or tokenizes by itself. Its MLXHuggingFace macros
//  expand to these same few lines, but they are package macros, which `xcodebuild` refuses to
//  run in CI until someone trusts them interactively — so the bridges are written out here.
//

import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

enum HubModelError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id): return "'\(id)' is not a Hugging Face model id."
        }
    }
}

/// Fetches model snapshots into ``HubModelStore/cache``.
struct HubDownloader: MLXLMCommon.Downloader {
    private let client = HubClient(cache: HubModelStore.cache)

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw HubModelError.invalidRepositoryID(id) }
        return try await client.downloadSnapshot(
            of: repo,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}

/// Loads a swift-transformers tokenizer from a downloaded snapshot.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Where downloaded models live on disk, and how to find one.
///
/// Application Support rather than the hub's default of Caches: iOS empties Caches under
/// storage pressure, and losing a multi-gigabyte download the user consented to — to have it
/// silently fetched again the next time they ask a question — is not a cache miss. Excluded
/// from backup, because weights anyone can re-download have no business in an iCloud backup.
enum HubModelStore {
    static let cache: HubCache = {
        let fm = FileManager.default
        var root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/hub", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return HubCache(cacheDirectory: root)
    }()

    /// The directory every model is stored under. Exposed here so callers needn't import
    /// HuggingFace to read it; this target has member import visibility on.
    static var rootDirectory: URL { cache.cacheDirectory }

    /// The model's whole cache entry — blobs, snapshots and refs — or nil for a bad id.
    static func repoDirectory(for modelId: String) -> URL? {
        Repo.ID(rawValue: modelId).map { cache.repoDirectory(repo: $0, kind: .model) }
    }

    /// Whether a complete-looking snapshot of `modelId` is on disk.
    ///
    /// An interrupted download leaves the repo directory behind, so its existence proves
    /// nothing. A snapshot with a config and weights in it is what a load can actually use.
    static func hasSnapshot(of modelId: String) -> Bool {
        guard let repo = repoDirectory(for: modelId) else { return false }
        let fm = FileManager.default
        let snapshots = repo.appendingPathComponent("snapshots", isDirectory: true)
        guard let revisions = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return false }
        return revisions.contains { revision in
            let files = (try? fm.contentsOfDirectory(atPath: snapshots.appendingPathComponent(revision).path)) ?? []
            return files.contains("config.json") && files.contains { $0.hasSuffix(".safetensors") }
        }
    }

    /// Where swift-transformers' `HubApi` used to put models, before mlx-swift-lm 3.
    ///
    /// Nothing reads these any more: the new downloader keeps its own layout, so a model in one
    /// of them is gigabytes the user can't see in Settings and the app will never use.
    static func legacyDirectories(for modelId: String) -> [URL] {
        let fm = FileManager.default
        let bases: [URL] = [FileManager.SearchPathDirectory.documentDirectory, .cachesDirectory, .applicationSupportDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        return bases.flatMap { base in
            ["huggingface/models", "models"].map { base.appendingPathComponent("\($0)/\(modelId)") }
        }
    }
}
