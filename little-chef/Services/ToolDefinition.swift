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
    func setTimer(name: String, durationMinutes: Int) throws
    func startTimer(name: String) throws
    func pauseTimer(name: String) throws
    func deleteTimer(name: String) throws
    func getTimer(name: String) -> LocalTimer?
    func getAllTimers() -> [LocalTimer]
}

// MARK: - Timer Tool Types

/// Timer tool input/output types
struct SetTimerInput: Codable {
    let name: String
    let minutes: Int
}

struct StartTimerInput: Codable {
    let name: String
}

struct PauseTimerInput: Codable {
    let name: String
}

struct DeleteTimerInput: Codable {
    let name: String
}

struct TimerOutput: Codable {
    let success: Bool
    let message: String
}

// MARK: - Cooking Tools

/// Timer tools for cooking assistant using MLXLLM Tool format
struct CookingTools {
    let setTimer: Tool<SetTimerInput, TimerOutput>
    let startTimer: Tool<StartTimerInput, TimerOutput>
    let pauseTimer: Tool<PauseTimerInput, TimerOutput>
    let deleteTimer: Tool<DeleteTimerInput, TimerOutput>

    init(timerManager: TimerManager) {
        // Set Timer Tool - creates and starts a timer
        setTimer = Tool<SetTimerInput, TimerOutput>(
            name: "set_timer",
            description: "Creates and starts a new cooking timer with a specified name and duration in minutes",
            parameters: [
                .required("name", type: .string, description: "Descriptive name for the timer (e.g., 'boil pasta', 'marinate chicken')"),
                .required("minutes", type: .int, description: "Duration in minutes for the timer")
            ]
        ) { input in
            do {
                try timerManager.setTimer(name: input.name, durationMinutes: input.minutes)
                return TimerOutput(success: true, message: "Timer '\(input.name)' set for \(input.minutes) minutes and started")
            } catch {
                return TimerOutput(success: false, message: "Failed to set timer: \(error.localizedDescription)")
            }
        }

        // Start Timer Tool - starts a new or paused timer
        startTimer = Tool<StartTimerInput, TimerOutput>(
            name: "start_timer",
            description: "Starts a timer that is in 'new' or 'paused' state (use this to resume paused timers)",
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

        // Pause Timer Tool
        pauseTimer = Tool<PauseTimerInput, TimerOutput>(
            name: "pause_timer",
            description: "Pauses a currently running timer (can be resumed with start_timer)",
            parameters: [
                .required("name", type: .string, description: "Name of the timer to pause")
            ]
        ) { input in
            do {
                try timerManager.pauseTimer(name: input.name)
                return TimerOutput(success: true, message: "Timer '\(input.name)' paused")
            } catch {
                return TimerOutput(success: false, message: "Failed to pause timer: \(error.localizedDescription)")
            }
        }

        // Delete Timer Tool
        deleteTimer = Tool<DeleteTimerInput, TimerOutput>(
            name: "delete_timer",
            description: "Removes/deletes a timer completely",
            parameters: [
                .required("name", type: .string, description: "Name of the timer to delete")
            ]
        ) { input in
            do {
                try timerManager.deleteTimer(name: input.name)
                return TimerOutput(success: true, message: "Timer '\(input.name)' deleted")
            } catch {
                return TimerOutput(success: false, message: "Failed to delete timer: \(error.localizedDescription)")
            }
        }
    }

    /// Get all tool schemas for passing to UserInput
    var allSchemas: [[String: Any]] {
        [setTimer.schema, startTimer.schema, pauseTimer.schema, deleteTimer.schema]
    }
}

