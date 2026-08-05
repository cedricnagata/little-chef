//
//  TimerWidgetBundle.swift
//  TimerWidget
//
//  Created by Cedric Nagata on 5/7/26.
//

import WidgetKit
import SwiftUI

/// This extension exists for one thing: the Live Activity that shows a running cooking timer on
/// the Lock Screen and in the Dynamic Island.
///
/// A Live Activity is only rendered if its `ActivityConfiguration` is registered here — the
/// widget declaring it is not enough. It was missing from this list, so every
/// `Activity.request` in `LocalTimer.start()` had nothing to draw with, and failed into the
/// `try?` that swallows it. Timers counted down inside the app and nowhere else.
@main
struct TimerWidgetBundle: WidgetBundle {
    var body: some Widget {
        TimerLiveActivityWidget()
    }
}
