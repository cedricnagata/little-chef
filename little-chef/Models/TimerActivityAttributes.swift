//
//  TimerActivityAttributes.swift
//  little-chef
//
//  What a timer's Live Activity shows. Compiled into both the app, which starts and updates the
//  activity, and the TimerWidget extension, which draws it. The app picks it up from its synced
//  folder; the widget target lists it explicitly in its Sources phase.
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
