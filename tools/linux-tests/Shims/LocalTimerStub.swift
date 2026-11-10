// Stand-in for LocalTimer, whose real implementation needs ActivityKit and Combine. The tool
// layer only reads these properties from it.

import Foundation

enum TimerStatusType: String, Codable {
    case new, running, paused, ended
}

final class LocalTimer: Identifiable {
    let id: String
    var label: String
    var durationSeconds: Int
    var remainingSeconds: Int
    var status: TimerStatusType
    let createdAt: Date

    // The app's initializer exactly, with no defaults, so a call that builds here builds in Xcode.
    init(id: String, label: String, durationSeconds: Int, remainingSeconds: Int, status: TimerStatusType, createdAt: Date) {
        self.id = id
        self.label = label
        self.durationSeconds = durationSeconds
        self.remainingSeconds = remainingSeconds
        self.status = status
        self.createdAt = createdAt
    }
}
