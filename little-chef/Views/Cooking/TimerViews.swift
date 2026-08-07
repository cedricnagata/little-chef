//
//  TimerViews.swift
//  little-chef
//

import SwiftUI

// MARK: - Timer Card

struct TimerCardView: View {
    @ObservedObject var timer: LocalTimer
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title2)
                .foregroundColor(statusColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(timer.label)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(timer.formattedTime)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if timer.isActive || timer.status == .ended {
                CircularProgressView(
                    progress: timer.progress,
                    color: statusColor
                )
                .frame(width: 20, height: 20)
            }

            HStack(spacing: 8) {
                if timer.status == .new {
                    Button(action: { timer.start() }) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                } else if timer.status == .running {
                    Button(action: { timer.pause() }) {
                        Image(systemName: "pause.circle.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                    }
                } else if timer.status == .paused {
                    Button(action: { timer.start() }) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                }

                Button(action: { onDelete() }) {
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
        case .new: return "clock"
        case .running: return "timer"
        case .paused: return "pause.circle"
        case .ended: return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch timer.status {
        case .new: return .gray
        case .running: return .green
        case .paused: return .orange
        case .ended: return .blue
        }
    }
}

// MARK: - Circular Progress

struct CircularProgressView: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.3), lineWidth: 2)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Add Timer Sheet

struct AddTimerView: View {
    let onAdd: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var timerLabel = ""
    @State private var selectedMinutes = 5
    @State private var selectedSeconds = 0

    private let minuteOptions = Array(0...59)
    private let secondOptions = Array(0...59)

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Timer Label")
                        .font(.headline)

                    TextField("e.g., Pasta, Chicken, etc.", text: $timerLabel)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Duration")
                        .font(.headline)

                    HStack {
                        VStack {
                            Text("Minutes")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Picker("Minutes", selection: $selectedMinutes) {
                                ForEach(minuteOptions, id: \.self) { minute in
                                    Text("\(minute)").tag(minute)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 80, height: 120)
                        }

                        VStack {
                            Text("Seconds")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Picker("Seconds", selection: $selectedSeconds) {
                                ForEach(secondOptions, id: \.self) { second in
                                    Text("\(second)").tag(second)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 80, height: 120)
                        }

                        Spacer()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Duration")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(formattedDuration)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            // The duration pickers sit right under the label field, and a keyboard covering
            // them is a sheet with no visible way forward.
            .dismissesKeyboardOnTap()
            .navigationTitle("Add Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { addTimer() }
                        .disabled(!isValid)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var isValid: Bool {
        !timerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (selectedMinutes > 0 || selectedSeconds > 0)
    }

    private var totalSeconds: Int {
        selectedMinutes * 60 + selectedSeconds
    }

    private var formattedDuration: String {
        let totalSeconds = selectedMinutes * 60 + selectedSeconds
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 && seconds > 0 {
            return "\(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }

    private func addTimer() {
        dismissKeyboard()
        let label = timerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        onAdd(label, totalSeconds)
        dismiss()
    }
}
