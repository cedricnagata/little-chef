//
//  ModelDownloadPlanTests.swift
//  little-chefTests
//
//  What a background model download fetches, and how its files are filed into the Hub cache.
//

import Foundation
import Testing
@testable import little_chef

struct ModelDownloadPlanTests {
    private let commit = "0123456789abcdef0123456789abcdef01234567"

    private func layout() -> ModelDownloadLayout {
        ModelDownloadLayout(repoDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("models--org--model"))
    }

    private func plan() -> ModelDownloadPlan {
        ModelDownloadPlan(modelId: "org/model", commit: commit, files: [
            .init(path: "config.json", etag: "aaa1", size: 3),
            .init(path: "model.safetensors", etag: "bbb2", size: 5),
            .init(path: "nested/chat_template.jinja", etag: "ccc3", size: 2),
        ])
    }

    /// A finished download, as the session hands it over: a temporary file of the right size.
    private func downloaded(_ bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test func fetchesOnlyWhatTheLoaderReads() {
        #expect(ModelDownloadPlan.wants("config.json"))
        #expect(ModelDownloadPlan.wants("model-00001-of-00002.safetensors"))
        #expect(ModelDownloadPlan.wants("chat_template.jinja"))
        #expect(!ModelDownloadPlan.wants("README.md"))
        #expect(!ModelDownloadPlan.wants(".gitattributes"))
    }

    @Test func refusesPathsOutsideTheSnapshot() {
        #expect(ModelDownloadPlan.isSafe("tokenizer.json"))
        #expect(ModelDownloadPlan.isSafe("nested/file.json"))
        #expect(!ModelDownloadPlan.isSafe("../escape.json"))
        #expect(!ModelDownloadPlan.isSafe("/etc/passwd"))
        #expect(!ModelDownloadPlan.isSafe("a//b.json"))
        #expect(!ModelDownloadPlan.isSafe(""))
        #expect(ModelDownloadPlan.isSafeEtag("4f2a9c"))
        #expect(!ModelDownloadPlan.isSafeEtag("../x"))
        #expect(!ModelDownloadPlan.isSafeEtag(""))
    }

    @Test func planSurvivesARelaunch() throws {
        let layout = layout()
        defer { try? FileManager.default.removeItem(at: layout.repoDirectory.deletingLastPathComponent()) }
        try layout.savePlan(plan())
        #expect(layout.loadPlan() == plan())
        layout.removePlan()
        #expect(layout.loadPlan() == nil)
    }

    @Test func countsOnlyCompleteFiles() throws {
        let layout = layout()
        defer { try? FileManager.default.removeItem(at: layout.repoDirectory.deletingLastPathComponent()) }
        let plan = plan()
        try layout.store(try downloaded(3), as: plan.files[0])
        // A blob of the wrong size is not the file.
        try layout.store(try downloaded(4), as: plan.files[1])
        #expect(layout.missingFiles(of: plan).map(\.path) == ["model.safetensors", "nested/chat_template.jinja"])
        #expect(layout.downloadedBytes(of: plan) == 3)
        #expect(plan.totalBytes == 10)
    }

    @Test func noSnapshotUntilEveryFileIsIn() throws {
        let layout = layout()
        defer { try? FileManager.default.removeItem(at: layout.repoDirectory.deletingLastPathComponent()) }
        let plan = plan()
        try layout.savePlan(plan)
        try layout.store(try downloaded(3), as: plan.files[0])
        let snapshots = layout.repoDirectory.appendingPathComponent("snapshots")
        #expect(!FileManager.default.fileExists(atPath: snapshots.path))
    }

    @Test func finishedDownloadIsAHubSnapshot() throws {
        let layout = layout()
        defer { try? FileManager.default.removeItem(at: layout.repoDirectory.deletingLastPathComponent()) }
        let plan = plan()
        try layout.savePlan(plan)
        for file in plan.files { try layout.store(try downloaded(Int(file.size)), as: file) }
        #expect(layout.missingFiles(of: plan).isEmpty)

        try layout.finish(plan)
        let snapshot = layout.repoDirectory.appendingPathComponent("snapshots/\(commit)")
        for file in plan.files {
            let link = snapshot.appendingPathComponent(file.path)
            // Each entry resolves to its blob, through a link that stays relative.
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            #expect(!target.hasPrefix("/"))
            let data = try Data(contentsOf: link)
            #expect(Int64(data.count) == file.size)
            #expect(link.resolvingSymlinksInPath().path == layout.blobURL(for: file).resolvingSymlinksInPath().path)
        }
        let ref = try String(contentsOf: layout.repoDirectory.appendingPathComponent("refs/main"), encoding: .utf8)
        #expect(ref == commit)
        #expect(layout.loadPlan() == nil)
    }
}
