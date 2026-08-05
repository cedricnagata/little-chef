//
//  TimerNotificationManager.swift
//  little-chef
//

import UserNotifications
import Foundation

final class TimerNotificationManager {
    static let shared = TimerNotificationManager()
    private init() {}

    func requestAuthorization() async -> Bool {
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func scheduleCompletion(for timerId: String, label: String, fireDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Timer Complete"
        content.body = "\(label) is done!"
        // `.default`, not `.defaultCritical`: a critical sound needs the Critical Alerts
        // entitlement, which this app does not have and which Apple grants by request only.
        // Asking for one without it is not louder — it is silent.
        content.sound = .default
        content.userInfo = ["timerId": timerId]

        // Interval rather than calendar components: the countdown is an interval, and matching
        // on second-granularity date components means a timer scheduled a hair past its second
        // waits for the next match — or, for a duration under a second, never fires at all.
        let interval = max(1, fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: timerId, content: content, trigger: trigger)

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [timerId])
        UNUserNotificationCenter.current().add(request) { error in
            if let error { dprint("Timer notification schedule error: \(error)") }
        }
    }

    func cancelNotification(for timerId: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [timerId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [timerId])
    }

    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
