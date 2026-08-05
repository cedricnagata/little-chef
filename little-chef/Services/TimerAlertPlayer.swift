//
//  TimerAlertPlayer.swift
//  little-chef
//

import AudioToolbox
import UIKit

/// The in-app half of a timer going off.
///
/// A local notification covers a timer that ends while the app is in the background, but it is
/// unreliable as the *only* alert while the app is open: hands-free cooking holds a
/// `.playAndRecord` audio session, and a notification sound arriving over one is routinely
/// swallowed. So when the app is foreground the notification is presented silently (see
/// `AppDelegate.userNotificationCenter(_:willPresent:)`) and this plays the alert instead —
/// where it can chime more than once, which is what a phone on a counter across the kitchen
/// actually needs.
@MainActor
final class TimerAlertPlayer {
    static let shared = TimerAlertPlayer()
    private init() {}

    /// The system "alarm" alert. A numeric id because `AudioServicesPlayAlertSound` takes one
    /// and the constants Apple exposes cover vibration only; 1005 has been this tone for the
    /// life of the platform.
    private static let alertSoundID: SystemSoundID = 1005

    private static let chimeCount = 3
    private static let chimeGap: Duration = .milliseconds(900)

    private var chimeTask: Task<Void, Never>?

    /// Chimes and vibrates a few times for a finished timer.
    func fire() {
        // A second timer landing on top of the first restarts the pattern rather than
        // interleaving two of them into noise.
        chimeTask?.cancel()

        let haptics = UINotificationFeedbackGenerator()
        haptics.prepare()

        chimeTask = Task { [weak self] in
            for chime in 0..<Self.chimeCount {
                if chime > 0 {
                    try? await Task.sleep(for: Self.chimeGap)
                    if Task.isCancelled { return }
                }
                AudioServicesPlayAlertSound(Self.alertSoundID)
                haptics.notificationOccurred(.success)
            }
            self?.chimeTask = nil
        }
    }

    /// Cuts the alert short — the timer was dismissed or the session ended.
    func stop() {
        chimeTask?.cancel()
        chimeTask = nil
    }
}
