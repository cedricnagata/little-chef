//
//  ToolDefinition.swift
//  little-chef
//
//  Defines available tools for the local LLM agent
//

import Foundation
import MLXLMCommon

// MARK: - Timer Manager Protocol

/// Protocol for managing timers (implemented by CookingSessionManager)
protocol TimerManager {
    func addTimer(name: String, durationMinutes: Int) throws
    func startTimer(name: String) throws
    func stopTimer(name: String) throws
    func removeTimer(name: String) throws
    func getTimer(name: String) -> LocalTimer?
}

// MARK: - Timer Tool Types

/// Timer tool input/output types
struct AddTimerInput: Codable {
    let name: String
    let minutes: Int
}

struct StartTimerInput: Codable {
    let name: String
}

struct StopTimerInput: Codable {
    let name: String
}

struct RemoveTimerInput: Codable {
    let name: String
}

struct TimerOutput: Codable {
    let success: Bool
    let message: String
}

// MARK: - Cooking Tools

/// Timer tools for cooking assistant using MLXLLM Tool format
struct CookingTools {
    let addTimer: Tool<AddTimerInput, TimerOutput>
    let startTimer: Tool<StartTimerInput, TimerOutput>
    let stopTimer: Tool<StopTimerInput, TimerOutput>
    let removeTimer: Tool<RemoveTimerInput, TimerOutput>

    init(timerManager: TimerManager) {
        // Add Timer Tool
        addTimer = Tool<AddTimerInput, TimerOutput>(
            name: "add_timer",
            description: "Creates a new cooking timer with a specified name and duration in minutes",
            parameters: [
                .required("name", type: .string, description: "Descriptive name for the timer (e.g., 'boil pasta', 'marinate chicken')"),
                .required("minutes", type: .int, description: "Duration in minutes for the timer")
            ]
        ) { input in
            do {
                try timerManager.addTimer(name: input.name, durationMinutes: input.minutes)
                return TimerOutput(success: true, message: "Timer '\(input.name)' added for \(input.minutes) minutes")
            } catch {
                return TimerOutput(success: false, message: "Failed to add timer: \(error.localizedDescription)")
            }
        }

        // Start Timer Tool
        startTimer = Tool<StartTimerInput, TimerOutput>(
            name: "start_timer",
            description: "Starts a timer that was previously created",
            parameters: [
                .required("name", type: .string, description: "Name of the timer to start")
            ]
        ) { input in
            do {
                try timerManager.startTimer(name: input.name)
                return TimerOutput(success: true, message: "Timer '\(input.name)' started")
            } catch {
                return TimerOutput(success: false, message: "Failed to start timer: \(error.localizedDescription)")
            }
        }

        // Stop Timer Tool
        stopTimer = Tool<StopTimerInput, TimerOutput>(
            name: "stop_timer",
            description: "Stops a currently running timer",
            parameters: [
                .required("name", type: .string, description: "Name of the timer to stop")
            ]
        ) { input in
            do {
                try timerManager.stopTimer(name: input.name)
                return TimerOutput(success: true, message: "Timer '\(input.name)' stopped")
            } catch {
                return TimerOutput(success: false, message: "Failed to stop timer: \(error.localizedDescription)")
            }
        }

        // Remove Timer Tool
        removeTimer = Tool<RemoveTimerInput, TimerOutput>(
            name: "remove_timer",
            description: "Removes/deletes a timer completely",
            parameters: [
                .required("name", type: .string, description: "Name of the timer to remove")
            ]
        ) { input in
            do {
                try timerManager.removeTimer(name: input.name)
                return TimerOutput(success: true, message: "Timer '\(input.name)' removed")
            } catch {
                return TimerOutput(success: false, message: "Failed to remove timer: \(error.localizedDescription)")
            }
        }
    }

    /// Get all tool schemas for passing to UserInput
    var allSchemas: [[String: Any]] {
        [addTimer.schema, startTimer.schema, stopTimer.schema, removeTimer.schema]
    }
}

