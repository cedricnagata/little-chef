//
//  little_chefApp.swift
//  little-chef
//
//  App entry point: the shared services, and the notification setup.
//

import SwiftUI
import UIKit
import UserNotifications

// MARK: - App Delegate (notification handling)

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Called when user taps a timer completion notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let timerId = response.notification.request.content.userInfo["timerId"] as? String {
            NotificationCenter.default.post(
                name: .timerNotificationTapped,
                object: nil,
                userInfo: ["timerId": timerId])
        }
        completionHandler()
    }

    // Show the banner in the foreground, but let the app make the noise.
    //
    // No `.sound` on purpose: a foreground timer is announced by `TimerAlertPlayer`, which
    // chimes repeatedly and gets heard over the hands-free audio session — asking for the
    // notification sound as well would either double it up or, more often, add nothing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

extension Notification.Name {
    static let timerNotificationTapped = Notification.Name("timerNotificationTapped")
}

// MARK: - App

@main
struct little_chefApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var llmService: LLMService
    @StateObject private var voiceAssistant: VoiceAssistant
    @StateObject private var cookingSessionManager: CookingSessionManager

    init() {
        let llm = LLMService.shared
        _llmService = StateObject(wrappedValue: llm)
        _voiceAssistant = StateObject(wrappedValue: VoiceAssistant(llmService: llm))
        _cookingSessionManager = StateObject(wrappedValue: CookingSessionManager(llmService: llm))
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(cookingSessionManager)
                .environmentObject(voiceAssistant)
                .environmentObject(llmService)
                .task {
                    _ = await TimerNotificationManager.shared.requestAuthorization()
                }
        }
    }
}
