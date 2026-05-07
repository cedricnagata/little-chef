//
//  TimerActivityAttributes.swift
//  little-chef
//
//  Shared between the main app target and the TimerWidget extension.
//  Add this file to both targets in Xcode's file inspector.
//

#if canImport(ActivityKit)
import ActivityKit
import Foundation

struct TimerActivityAttributes: ActivityAttributes {
    // Static content — set at start, does not change
    let timerId: String
    let label: String
    let totalSeconds: Int

    // Dynamic content — updated on pause/resume/end
    struct ContentState: Codable, Hashable {
        var endDate: Date?        // nil when paused or ended
        var isPaused: Bool
        var pausedRemaining: Int  // seconds remaining when paused (0 otherwise)
    }
}
#endif
