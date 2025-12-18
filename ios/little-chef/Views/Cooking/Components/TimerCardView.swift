//
//  TimerCardView.swift
//  little-chef
//
//  Extracted from CookingSessionView for better organization
//

import SwiftUI

struct TimerCardView: View {
    @ObservedObject var timer: LocalTimer
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Timer status icon
            Image(systemName: statusIcon)
                .font(.title2)
                .foregroundColor(statusColor)
                .frame(width: 24)

            // Timer info
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.label)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(timer.formattedTime)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Progress indicator
            if timer.isActive || timer.status == .completed {
                CircularProgressView(
                    progress: timer.progress,
                    color: statusColor
                )
                .frame(width: 20, height: 20)
            }

            // Controls
            HStack(spacing: 8) {
                // Manual controls (for pending timers)
                if timer.status == .pending {
                    Button(action: {
                        timer.start()
                    }) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                } else if timer.status == .running {
                    Button(action: {
                        timer.pause()
                    }) {
                        Image(systemName: "pause.circle.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                    }
                } else if timer.status == .paused {
                    Button(action: {
                        timer.resume()
                    }) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                }

                // Delete button (always available)
                Button(action: {
                    onDelete()
                }) {
                    Image(systemName: "trash.circle.fill")
                        .font(.title3)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusIcon: String {
        switch timer.status {
        case .pending:
            return "clock"
        case .running:
            return "timer"
        case .paused:
            return "pause.circle"
        case .completed:
            return "checkmark.circle.fill"
        case .stopped:
            return "stop.circle"
        }
    }

    private var statusColor: Color {
        switch timer.status {
        case .pending:
            return .gray
        case .running:
            return .green
        case .paused:
            return .orange
        case .completed:
            return .blue
        case .stopped:
            return .red
        }
    }
}
