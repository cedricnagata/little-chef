//
//  little_chefApp.swift
//  little-chef
//
//  Local-only operation with on-device Bonsai 8B model
//

import SwiftUI
import SwiftData
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

    // Show banner + play sound even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    static let timerNotificationTapped = Notification.Name("timerNotificationTapped")
}

// MARK: - App

@main
struct little_chefApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var llmService = LLMService.shared
    @StateObject private var voiceAssistant = VoiceAssistant()
    @StateObject private var cookingSessionManager: CookingSessionManager

    // SwiftData container for local storage
    let dataModelContainer: SwiftData.ModelContainer

    init() {
        let llm = LLMService.shared
        _llmService = StateObject(wrappedValue: llm)
        _voiceAssistant = StateObject(wrappedValue: VoiceAssistant())
        _cookingSessionManager = StateObject(wrappedValue: CookingSessionManager(llmService: llm))

        do {
            let schema = Schema([
                RecipeEntity.self,
                UserPreferencesEntity.self
            ])
            let swiftDataConfig = SwiftData.ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            dataModelContainer = try SwiftData.ModelContainer(for: schema, configurations: [swiftDataConfig])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cookingSessionManager)
                .environmentObject(voiceAssistant)
                .environmentObject(llmService)
                .modelContainer(dataModelContainer)
                .task {
                    await TimerNotificationManager.shared.requestAuthorization()
                }
        }
    }
}
