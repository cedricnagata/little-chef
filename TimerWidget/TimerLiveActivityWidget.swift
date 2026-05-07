//
//  TimerLiveActivityWidget.swift
//  TimerWidget
//

import WidgetKit
import SwiftUI
import ActivityKit

struct TimerLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LockScreenTimerView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.label, systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerCountdownText(state: context.state)
                        .font(.title2.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isPaused {
                        Text("Paused")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                TimerCountdownText(state: context.state)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Reusable countdown text

struct TimerCountdownText: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        if state.isPaused {
            let m = state.pausedRemaining / 60
            let s = state.pausedRemaining % 60
            Text(String(format: "%d:%02d", m, s))
        } else if let end = state.endDate {
            // Text(timerInterval:) auto-counts down — no app updates needed
            Text(timerInterval: Date.now...end, countsDown: true)
        } else {
            Text("0:00")
        }
    }
}

// MARK: - Lock Screen / StandBy view

struct LockScreenTimerView: View {
    let attributes: TimerActivityAttributes
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("little chef", systemImage: "fork.knife")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(attributes.label)
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                TimerCountdownText(state: state)
                    .font(.title.monospacedDigit().bold())
                    .multilineTextAlignment(.trailing)
                if state.isPaused {
                    Text("Paused")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
    }
}
