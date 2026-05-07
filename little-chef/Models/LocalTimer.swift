//
//  LocalTimer.swift
//  little-chef
//

import Foundation
import Combine
import ActivityKit

class LocalTimer: ObservableObject, Identifiable {
    let id: String
    let label: String
    let durationSeconds: Int
    let createdAt: Date

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

    func stopLiveActivity() {
        timer?.invalidate()
        timer = nil
        TimerNotificationManager.shared.cancelNotification(for: id)
        Task {
            let state = TimerActivityAttributes.ContentState(
                endDate: nil, isPaused: false, pausedRemaining: 0)
            await liveActivity?.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
            liveActivity = nil
        }
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

        TimerNotificationManager.shared.cancelNotification(for: id)

        let finalState = TimerActivityAttributes.ContentState(
            endDate: nil, isPaused: false, pausedRemaining: 0)
        Task {
            await liveActivity?.end(
                .init(state: finalState, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(30)))
            liveActivity = nil
        }
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
