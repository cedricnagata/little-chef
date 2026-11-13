//
//  ModelDownloadPlan.swift
//  little-chef
//
//  What a model download fetches, and how the finished files are filed into the Hugging Face
//  cache layout the model loader reads. Foundation only, so the Linux tests cover it.
//

import Foundation

/// One model download: the commit it is pinned to and every file it needs.
///
/// Written to disk when the download starts, because the download outlives the app: a background
/// session keeps transferring after iOS suspends or ends LittleChef, and the relaunch that hears
/// about a finished file has nothing else to tell it where that file belongs.
struct ModelDownloadPlan: Codable, Equatable {
    struct File: Codable, Equatable {
        /// The file's path in the repository.
        var path: String
        /// What the cache names its blob: the LFS SHA-256 for a weights file, the git blob id
        /// otherwise, as the Hub's own downloader does.
        var etag: String
        var size: Int64
    }

    var modelId: String
    var commit: String
    var files: [File]

    /// What the model loader reads (mlx-swift-lm's `modelDownloadPatterns`).
    static let patterns = ["*.safetensors", "*.json", "*.jinja"]

    static func wants(_ path: String) -> Bool {
        patterns.contains { fnmatch($0, path, 0) == 0 }
    }

    /// A repository path that stays inside the snapshot: no absolute paths, no `..`.
    static func isSafe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/")
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// A blob name that is one plain path component.
    static func isSafeEtag(_ etag: String) -> Bool {
        !etag.isEmpty && etag.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// The plan's place in one model's cache directory (`models--org--name`), and the files it fills.
///
/// The layout is the Hub cache's own: `blobs/<etag>` holds each file, `snapshots/<commit>/<path>`
/// is a relative symlink to it, and `refs/main` names the commit. The snapshot is only made once
/// every blob is in, so a half-finished download never looks like a model
/// (``HubModelStore/hasSnapshot(of:)`` reads the snapshot directory).
struct ModelDownloadLayout {
    var repoDirectory: URL

    var planURL: URL { repoDirectory.appendingPathComponent("littlechef-download.json") }
    var blobsDirectory: URL { repoDirectory.appendingPathComponent("blobs", isDirectory: true) }

    func blobURL(for file: ModelDownloadPlan.File) -> URL {
        blobsDirectory.appendingPathComponent(file.etag)
    }

    func hasBlob(for file: ModelDownloadPlan.File) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: blobURL(for: file).path)[.size]) as? NSNumber
        return size?.int64Value == file.size
    }

    func savePlan(_ plan: ModelDownloadPlan) throws {
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
    }

    func loadPlan() -> ModelDownloadPlan? {
        (try? Data(contentsOf: planURL)).flatMap { try? JSONDecoder().decode(ModelDownloadPlan.self, from: $0) }
    }

    func removePlan() {
        try? FileManager.default.removeItem(at: planURL)
    }

    /// Moves a downloaded file into its blob. Synchronous, because a download task's file is
    /// deleted as soon as its delegate callback returns.
    func store(_ downloaded: URL, as file: ModelDownloadPlan.File) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        let blob = blobURL(for: file)
        try? fm.removeItem(at: blob)
        try fm.moveItem(at: downloaded, to: blob)
    }

    func missingFiles(of plan: ModelDownloadPlan) -> [ModelDownloadPlan.File] {
        plan.files.filter { !hasBlob(for: $0) }
    }

    func downloadedBytes(of plan: ModelDownloadPlan) -> Int64 {
        plan.files.filter(hasBlob).reduce(0) { $0 + $1.size }
    }

    /// Links every file into the plan's snapshot and points `refs/main` at it. Call once
    /// ``missingFiles(of:)`` is empty.
    func finish(_ plan: ModelDownloadPlan) throws {
        let fm = FileManager.default
        let snapshot = repoDirectory.appendingPathComponent("snapshots/\(plan.commit)", isDirectory: true)
        for file in plan.files {
            let link = snapshot.appendingPathComponent(file.path)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: link)
            // From snapshots/<commit>/<path> back up to the repository directory.
            let depth = file.path.split(separator: "/").count + 1
            let target = String(repeating: "../", count: depth) + "blobs/" + file.etag
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        let refs = repoDirectory.appendingPathComponent("refs", isDirectory: true)
        try fm.createDirectory(at: refs, withIntermediateDirectories: true)
        try plan.commit.write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        removePlan()
    }
}
