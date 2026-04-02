//
//  LocalTimer.swift
//  little-chef
//
//  Created by AI Assistant on 9/13/25.
//

import Foundation
import Combine

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
        guard status != .running else { return }

        // Can start from .new or .paused
        guard status == .new || status == .paused else { return }

        status = .running
        if startedAt == nil {
            startedAt = Date()
        }

        // Create timer and add to RunLoop with common mode to ensure it runs during UI updates
        let newTimer = Foundation.Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
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
    }

    private func tick() {
        guard remainingSeconds > 0 else {
            complete()
            return
        }
        
        remainingSeconds -= 1
    }
    
    private func complete() {
        timer?.invalidate()
        timer = nil
        status = .ended
        completedAt = Date()
        remainingSeconds = 0

        // TODO: Show notification or play sound
        print("🔔 Timer completed: \(label)")
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
