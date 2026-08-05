//
//  LocalTimer.swift
//  little-chef
//

import Foundation
import Combine
import ActivityKit

class LocalTimer: ObservableObject, Identifiable {
    let id: String
    let createdAt: Date

    /// Both are settable so `update()` can re-target a timer in place — the identity a card,
    /// a notification and a Live Activity are all keyed on is ``id``, not the label.
    @Published var label: String
    @Published private(set) var durationSeconds: Int

    @Published var remainingSeconds: Int
    @Published var status: TimerStatusType
    @Published var startedAt: Date?
    @Published var completedAt: Date?

    // Convenience properties for compatibility
    var name: String { label }
    var isRunning: Bool { status == .running }
    var remainingMinutes: Int { remainingSeconds / 60 }

    private var timer: Foundation.Timer?
    private var endDate: Date?
    private var liveActivity: Activity<TimerActivityAttributes>?

    init(id: String, label: String, durationSeconds: Int, remainingSeconds: Int, status: TimerStatusType, createdAt: Date) {
        self.id = id
        self.label = label
        self.durationSeconds = durationSeconds
        self.remainingSeconds = remainingSeconds
        self.status = status
        self.createdAt = createdAt
    }

    // MARK: - Timer Control

    func start() {
        guard status == .new || status == .paused else { return }

        status = .running
        if startedAt == nil {
            startedAt = Date()
        }

        endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))

        // Schedule OS notification — fires even when app is killed or phone is locked
        TimerNotificationManager.shared.scheduleCompletion(for: id, label: label, fireDate: endDate!)

        // Start or resume the Live Activity on Lock Screen / Dynamic Island
        let state = TimerActivityAttributes.ContentState(
            endDate: endDate, isPaused: false, pausedRemaining: 0)
        if liveActivity == nil {
            let attributes = TimerActivityAttributes(timerId: id, label: label, totalSeconds: durationSeconds)
            liveActivity = try? Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: endDate))
        } else {
            Task { await liveActivity?.update(.init(state: state, staleDate: endDate)) }
        }

        // UI tick — 0.5s interval, recalculates from endDate so display snaps to correct time
        // after the app returns from the background without needing a separate observer
        let newTimer = Foundation.Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func pause() {
        guard status == .running else { return }

        status = .paused
        timer?.invalidate()
        timer = nil

        if let end = endDate {
            remainingSeconds = max(0, Int(end.timeIntervalSinceNow))
        }
        endDate = nil

        TimerNotificationManager.shared.cancelNotification(for: id)

        let state = TimerActivityAttributes.ContentState(
            endDate: nil, isPaused: true, pausedRemaining: remainingSeconds)
        Task { await liveActivity?.update(.init(state: state, staleDate: nil)) }
    }

    /// Re-target an existing timer: a new label, a new duration, or both.
    ///
    /// A running timer keeps running, restarted against the new duration — the alternative is
    /// silently leaving it counting down to the old one. An ended timer becomes startable again,
    /// since "make that fifteen minutes instead" after the bell means run it for fifteen.
    func update(label newLabel: String? = nil, durationSeconds newDuration: Int? = nil) {
        guard newLabel != nil || newDuration != nil else { return }

        let wasRunning = status == .running
        if wasRunning { pause() }

        if let newLabel { label = newLabel }
        if let newDuration {
            durationSeconds = newDuration
            remainingSeconds = newDuration
            if status == .ended {
                status = .new
                startedAt = nil
                completedAt = nil
            }
        }

        // The label and the total live in the Live Activity's *attributes*, which ActivityKit
        // will not let us change — only the content state. So the old one is ended and `start()`
        // requests a fresh one rather than updating a card that still says "pasta, 10:00".
        endLiveActivity()

        if wasRunning { start() }
    }

    /// Tears the timer down — it is being deleted, or the session that owned it ended.
    func stopLiveActivity() {
        timer?.invalidate()
        timer = nil
        TimerNotificationManager.shared.cancelNotification(for: id)
        // Dismissing a timer that is mid-chime silences it.
        Task { @MainActor in TimerAlertPlayer.shared.stop() }
        endLiveActivity()
    }

    /// Ends the Live Activity and drops it synchronously.
    ///
    /// Clearing `liveActivity` before awaiting matters: `end()` is async, and anything that
    /// starts the timer again in the meantime would find the property still populated and
    /// update the dying activity instead of requesting a new one.
    private func endLiveActivity(dismissAfter: Date? = nil) {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        let state = TimerActivityAttributes.ContentState(
            endDate: nil, isPaused: false, pausedRemaining: 0)
        let policy: ActivityUIDismissalPolicy = dismissAfter.map { .after($0) } ?? .immediate
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: policy) }
    }

    private func tick() {
        guard let end = endDate else { return }
        let remaining = end.timeIntervalSinceNow
        if remaining <= 0 {
            complete()
        } else {
            remainingSeconds = Int(remaining)
        }
    }

    private func complete() {
        timer?.invalidate()
        timer = nil
        status = .ended
        completedAt = Date()
        remainingSeconds = 0
        endDate = nil

        // Deliberately *not* cancelling the completion notification here. This runs the moment
        // the countdown reaches zero — the same moment the notification is due — so cancelling
        // it raced with its own delivery and, in the foreground, pulled the banner back off the
        // screen right after it appeared. That race is why a finished timer went by in silence.
        //
        // The audible alert is ours to play while the app is open, because a notification sound
        // over the hands-free audio session usually never reaches the speaker.
        Task { @MainActor in TimerAlertPlayer.shared.fire() }

        // Left on screen for a moment — a finished timer that vanishes instantly is one you
        // can miss entirely if you were looking at the pan.
        endLiveActivity(dismissAfter: Date().addingTimeInterval(30))
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Computed Properties

    var formattedTime: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var isActive: Bool {
        return status == .running || status == .paused
    }

    var progress: Double {
        let elapsed = durationSeconds - remainingSeconds
        return Double(elapsed) / Double(durationSeconds)
    }
}
