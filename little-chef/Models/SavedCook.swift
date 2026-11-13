//
//  SavedCook.swift
//  little-chef
//
//  The cook in progress, kept on disk so it survives iOS ending the app in the background.
//  Foundation only, so the Linux tests cover it.
//

import Foundation

/// Everything needed to put a cook back on screen after a relaunch.
///
/// iOS ends a backgrounded app whenever it needs the memory, with no warning and nothing run.
/// With a model loaded LittleChef is the largest thing on the phone, so leaving it for the camera
/// or a browser while cooking was enough: on an iPhone 14 Pro the cook, its conversation and its
/// timers were gone on return (2026-11-12). The model is not part of it; it loads again.
struct SavedCook: Codable {
    var session: CookingSession
    var provider: LLMProvider
    var kitchen: CookingPrompt.Kitchen?
    var timers: [SavedTimer]
    var savedAt = Date()

    /// A cook older than this is not restored: it was abandoned, not interrupted.
    static let maximumAge: TimeInterval = 12 * 60 * 60
}

/// A timer as it stood when the cook was saved.
struct SavedTimer: Codable, Equatable {
    var id: String
    var label: String
    var durationSeconds: Int
    var remainingSeconds: Int
    var status: TimerStatusType
    var createdAt: Date
    var startedAt: Date?
    /// When a running timer reaches zero. Nil unless it was running.
    var endDate: Date?

    /// The timer as it should be now: a running one keeps counting while the app is gone, and
    /// one whose end has passed has finished.
    func resumed(at now: Date = Date()) -> SavedTimer {
        guard status == .running, let endDate else { return self }
        var timer = self
        let remaining = Int(endDate.timeIntervalSince(now).rounded(.up))
        if remaining <= 0 {
            timer.status = .ended
            timer.remainingSeconds = 0
            timer.endDate = nil
        } else {
            timer.remainingSeconds = remaining
        }
        return timer
    }
}

/// Where the cook in progress is kept: one JSON file, written on every change worth keeping and
/// removed when the cook ends.
struct SavedCookStore {
    var url: URL

    static let standard = SavedCookStore(
        url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("current-cook.json"))

    func save(_ cook: SavedCook) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cook).write(to: url, options: .atomic)
        } catch {
            dprint("⚠️ Couldn't save the cook in progress: \(error)")
        }
    }

    /// The saved cook, if there is one recent enough to resume. An unreadable or stale file is
    /// removed rather than tried again at every launch.
    func load(now: Date = Date()) -> SavedCook? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cook = try? JSONDecoder().decode(SavedCook.self, from: data),
              now.timeIntervalSince(cook.savedAt) < SavedCook.maximumAge else {
            clear()
            return nil
        }
        return cook
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
