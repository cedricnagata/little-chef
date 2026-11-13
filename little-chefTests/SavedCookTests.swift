//
//  SavedCookTests.swift
//  little-chefTests
//
//  The cook in progress, kept on disk so iOS ending the app doesn't lose it.
//

import Foundation
import Testing
@testable import little_chef

struct SavedCookTests {
    private func tempStore() -> SavedCookStore {
        SavedCookStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("current-cook.json"))
    }

    private func session() -> CookingSession {
        var session = CookingSession(
            sourceRecipeID: UUID(),
            recipe: RecipeBase(title: "Soup", description: nil, servings: 4, prepTime: 10, cookTime: 30,
                               ingredients: ["1 onion", "2 cups stock"], instructions: ["Chop.", "Simmer."],
                               tags: [], sourceUrl: nil, cuisineType: nil, difficulty: nil),
            voiceSettings: .defaultSettings)
        session.recipe.ingredients.append("1 tsp salt")
        session.conversationHistory = [
            Message(id: UUID(), role: "user", content: "Can I use butter?", timestamp: Date()),
            Message(id: UUID(), role: "assistant", content: "Yes, it adds richness.", timestamp: Date()),
        ]
        return session
    }

    @Test func roundTripsTheWholeCook() throws {
        let store = tempStore()
        defer { store.clear() }
        let original = session()
        let timer = SavedTimer(id: "t1", label: "pasta", durationSeconds: 540, remainingSeconds: 300,
                               status: .paused, createdAt: Date(), startedAt: Date(), endDate: nil)
        store.save(SavedCook(session: original, provider: .local, kitchen: .init(missing: ["Stock"]), timers: [timer]))

        let cook = try #require(store.load())
        #expect(cook.session.id == original.id)
        #expect(cook.session.sourceRecipeID == original.sourceRecipeID)
        #expect(cook.session.recipe == original.recipe)
        #expect(cook.session.baselineRecipe == original.baselineRecipe)
        #expect(cook.session.conversationHistory.map(\.content) == original.conversationHistory.map(\.content))
        #expect(cook.provider == .local)
        #expect(cook.kitchen == .init(missing: ["Stock"]))
        #expect(cook.timers == [timer])
    }

    @Test func clearedCookIsGone() {
        let store = tempStore()
        store.save(SavedCook(session: session(), provider: .local, kitchen: nil, timers: []))
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func staleCookIsNotRestored() {
        let store = tempStore()
        defer { store.clear() }
        store.save(SavedCook(session: session(), provider: .local, kitchen: nil, timers: []))
        #expect(store.load(now: Date().addingTimeInterval(SavedCook.maximumAge + 1)) == nil)
        // and the stale file is removed, not read again at every launch
        #expect(store.load() == nil)
    }

    @Test func unreadableFileIsDropped() throws {
        let store = tempStore()
        defer { store.clear() }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func runningTimerKeepsCountingWhileTheAppIsGone() {
        let now = Date()
        let timer = SavedTimer(id: "t", label: "rice", durationSeconds: 600, remainingSeconds: 600,
                               status: .running, createdAt: now, startedAt: now,
                               endDate: now.addingTimeInterval(600))
        let later = timer.resumed(at: now.addingTimeInterval(240))
        #expect(later.status == .running)
        #expect(later.remainingSeconds == 360)

        let after = timer.resumed(at: now.addingTimeInterval(601))
        #expect(after.status == .ended)
        #expect(after.remainingSeconds == 0)
        #expect(after.endDate == nil)
    }

    @Test func pausedTimerIsUnchanged() {
        let timer = SavedTimer(id: "t", label: "rice", durationSeconds: 600, remainingSeconds: 200,
                               status: .paused, createdAt: Date(), startedAt: Date(), endDate: nil)
        #expect(timer.resumed(at: Date().addingTimeInterval(3600)) == timer)
    }
}
