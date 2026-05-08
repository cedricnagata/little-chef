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
        content.sound = .defaultCritical
        content.userInfo = ["timerId": timerId]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
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
