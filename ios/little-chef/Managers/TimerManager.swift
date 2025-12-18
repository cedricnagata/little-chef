//
//  TimerManager.swift
//  little-chef
//
//  Extracted from CookingSessionManager for single responsibility
//

import Foundation
import SwiftUI

@MainActor
class TimerManager: ObservableObject {
    @Published var localTimers: [LocalTimer] = []

    private var processedCommandIds = Set<String>()

    // MARK: - Command Processing

    func processTimerCommands(_ commands: [Command]) {
        // Process new commands from AI
        let newCommands = commands.filter { command in
            !processedCommandIds.contains(command.id)
        }

        for command in newCommands {
            // Handle timer commands
            if command.commandType == "timer" {
                switch command.action {
                case "add":
                    if let durationSeconds = command.parameters["duration_seconds"]?.value as? Int,
                       let timerId = command.targetId {
                        addTimer(id: timerId, label: command.label, duration: durationSeconds)
                    }
                case "start":
                    if let timerId = command.targetId {
                        startTimer(id: timerId)
                    }
                case "stop":
                    if let timerId = command.targetId {
                        stopTimer(id: timerId)
                    }
                case "pause":
                    if let timerId = command.targetId {
                        pauseTimer(id: timerId)
                    }
                case "resume":
                    if let timerId = command.targetId {
                        resumeTimer(id: timerId)
                    }
                case "remove":
                    if let timerId = command.targetId {
                        removeTimer(id: timerId)
                    }
                default:
                    print("Unknown timer action: \(command.action)")
                }
            }

            processedCommandIds.insert(command.id)
        }
    }

    // MARK: - Timer Status for Backend

    func getTimerStatusForBackend() -> [TimerStatus] {
        return localTimers.map { timer in
            TimerStatus(
                id: timer.id,
                label: timer.label,
                durationSeconds: timer.durationSeconds,
                status: timer.status,
                remainingSeconds: timer.remainingSeconds,
                createdAt: timer.createdAt,
                startedAt: timer.startedAt,
                completedAt: timer.completedAt
            )
        }
    }

    // MARK: - Timer CRUD Operations

    func addTimer(id: String, label: String, duration: Int) {
        let timer = LocalTimer(
            id: id,
            label: label,
            durationSeconds: duration,
            remainingSeconds: duration,
            status: .pending,
            createdAt: Date()
        )
        localTimers.append(timer)
        print("🕐 Added timer: \(label) (\(duration)s)")
    }

    func startTimer(id: String) {
        if let index = localTimers.firstIndex(where: { $0.id == id }) {
            localTimers[index].start()
            print("▶️ Started timer: \(localTimers[index].label)")
        }
    }

    func stopTimer(id: String) {
        if let index = localTimers.firstIndex(where: { $0.id == id }) {
            localTimers[index].stop()
            print("⏹️ Stopped timer: \(localTimers[index].label)")
        }
    }

    func pauseTimer(id: String) {
        if let index = localTimers.firstIndex(where: { $0.id == id }) {
            localTimers[index].pause()
            print("⏸️ Paused timer: \(localTimers[index].label)")
        }
    }

    func resumeTimer(id: String) {
        if let index = localTimers.firstIndex(where: { $0.id == id }) {
            localTimers[index].resume()
            print("▶️ Resumed timer: \(localTimers[index].label)")
        }
    }

    func removeTimer(id: String) {
        // Stop timer before removing
        if let index = localTimers.firstIndex(where: { $0.id == id }) {
            localTimers[index].stop()
        }
        localTimers.removeAll { $0.id == id }
        print("🗑️ Removed timer: \(id)")
    }

    func clearAllTimers() {
        // Stop and remove all local timers
        for timer in localTimers {
            timer.stop()
        }
        localTimers.removeAll()
        processedCommandIds.removeAll()
        print("🗑️ Cleared all timers")
    }
}
