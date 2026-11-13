//
//  TimerViews.swift
//  little-chef
//
//  Timer cards for the cook in progress, and the sheet for adding a timer by hand.
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("e.g., Pasta, Chicken, etc.", text: $timerLabel)
                }

                Section {
                    HStack(spacing: 0) {
                        durationWheel("Minutes", unit: "min", selection: $selectedMinutes)
                        durationWheel("Seconds", unit: "sec", selection: $selectedSeconds)
                    }
                } header: {
                    Text("Duration")
                } footer: {
                    Text(formattedDuration)
                }
            }
            .scrollDismissesKeyboard(.interactively)
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

    /// One wheel with its unit beside the selected row, as the Clock app's timer draws it.
    private func durationWheel(_ title: String, unit: String, selection: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Picker(title, selection: selection) {
                ForEach(0...59, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            Text(unit)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }

    private var isValid: Bool {
        !timerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (selectedMinutes > 0 || selectedSeconds > 0)
    }

    private var totalSeconds: Int {
        selectedMinutes * 60 + selectedSeconds
    }

    private var formattedDuration: String {
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
