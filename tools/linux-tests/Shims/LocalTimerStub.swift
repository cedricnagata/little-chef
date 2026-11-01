// Stand-in for LocalTimer, whose real implementation needs ActivityKit and Combine. The tool
// layer only reads these properties from it.

import Foundation

enum TimerStatusType: String, Codable {
    case new, running, paused, ended
}

final class LocalTimer: Identifiable {
    let id: String
    var label: String
    var remainingSeconds: Int
    var status: TimerStatusType

    init(id: String = UUID().uuidString, label: String, remainingSeconds: Int, status: TimerStatusType = .new) {
        self.id = id
        self.label = label
        self.remainingSeconds = remainingSeconds
        self.status = status
    }
}
