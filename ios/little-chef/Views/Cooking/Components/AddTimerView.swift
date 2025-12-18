//
//  AddTimerView.swift
//  little-chef
//
//  Extracted from CookingSessionView for better organization
//

import SwiftUI

struct AddTimerView: View {
    let onAdd: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var timerLabel = ""
    @State private var selectedHours = 0
    @State private var selectedMinutes = 5
    @State private var selectedSeconds = 0

    private let hourOptions = Array(0...23)
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
                        // Hours picker
                        VStack {
                            Text("Hours")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Picker("Hours", selection: $selectedHours) {
                                ForEach(hourOptions, id: \.self) { hour in
                                    Text("\(hour)").tag(hour)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 70, height: 120)
                        }

                        // Minutes picker
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
                            .frame(width: 70, height: 120)
                        }

                        // Seconds picker
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
                            .frame(width: 70, height: 120)
                        }

                        Spacer()

                        // Duration preview
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
            .navigationTitle("Add Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        addTimer()
                    }
                    .disabled(!isValid)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var isValid: Bool {
        !timerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (selectedHours > 0 || selectedMinutes > 0 || selectedSeconds > 0)
    }

    private var totalMinutes: Int {
        let totalSeconds = selectedHours * 3600 + selectedMinutes * 60 + selectedSeconds
        return max(1, (totalSeconds + 59) / 60) // Round up to nearest minute, minimum 1
    }

    private var formattedDuration: String {
        let totalSeconds = selectedHours * 3600 + selectedMinutes * 60 + selectedSeconds
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        var components: [String] = []

        if hours > 0 {
            components.append("\(hours)h")
        }
        if minutes > 0 {
            components.append("\(minutes)m")
        }
        if seconds > 0 {
            components.append("\(seconds)s")
        }

        return components.isEmpty ? "0s" : components.joined(separator: " ")
    }

    private func addTimer() {
        let label = timerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        onAdd(label, totalMinutes)
        dismiss()
    }
}
