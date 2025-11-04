//
//  ToolExecutor.swift
//  little-chef
//
//  Executes tool calls from the LLM agent
//

import Foundation

/// Result of a tool execution
struct ToolExecutionResult {
    let success: Bool
    let message: String
    let data: [String: Any]?
}

/// Executes tool calls and returns results
class ToolExecutor {
    /// Execute a tool call
    static func execute(_ toolCall: ToolCall, timerManager: TimerManager) -> ToolExecutionResult {
        switch toolCall.name {
        case "add_timer":
            return executeAddTimer(arguments: toolCall.arguments, timerManager: timerManager)

        case "start_timer":
            return executeStartTimer(arguments: toolCall.arguments, timerManager: timerManager)

        case "stop_timer":
            return executeStopTimer(arguments: toolCall.arguments, timerManager: timerManager)

        case "remove_timer":
            return executeRemoveTimer(arguments: toolCall.arguments, timerManager: timerManager)

        default:
            return ToolExecutionResult(
                success: false,
                message: "Unknown tool: \(toolCall.name)",
                data: nil
            )
        }
    }

    // MARK: - Tool Implementations

    private static func executeAddTimer(arguments: [String: Any], timerManager: TimerManager) -> ToolExecutionResult {
        guard let name = arguments["name"] as? String else {
            return ToolExecutionResult(
                success: false,
                message: "Missing or invalid 'name' parameter",
                data: nil
            )
        }

        // Handle both Int and Double for minutes
        let minutes: Int
        if let intMinutes = arguments["minutes"] as? Int {
            minutes = intMinutes
        } else if let doubleMinutes = arguments["minutes"] as? Double {
            minutes = Int(doubleMinutes)
        } else {
            return ToolExecutionResult(
                success: false,
                message: "Missing or invalid 'minutes' parameter",
                data: nil
            )
        }

        // Add the timer
        timerManager.addTimer(name: name, durationMinutes: minutes)

        return ToolExecutionResult(
            success: true,
            message: "Added timer '\(name)' for \(minutes) minute\(minutes == 1 ? "" : "s")",
            data: ["name": name, "minutes": minutes]
        )
    }

    private static func executeStartTimer(arguments: [String: Any], timerManager: TimerManager) -> ToolExecutionResult {
        guard let name = arguments["name"] as? String else {
            return ToolExecutionResult(
                success: false,
                message: "Missing or invalid 'name' parameter",
                data: nil
            )
        }

        // Check if timer exists
        guard timerManager.getTimer(name: name) != nil else {
            return ToolExecutionResult(
                success: false,
                message: "Timer '\(name)' not found",
                data: nil
            )
        }

        // Start the timer
        timerManager.startTimer(name: name)

        return ToolExecutionResult(
            success: true,
            message: "Started timer '\(name)'",
            data: ["name": name]
        )
    }

    private static func executeStopTimer(arguments: [String: Any], timerManager: TimerManager) -> ToolExecutionResult {
        guard let name = arguments["name"] as? String else {
            return ToolExecutionResult(
                success: false,
                message: "Missing or invalid 'name' parameter",
                data: nil
            )
        }

        // Check if timer exists
        guard timerManager.getTimer(name: name) != nil else {
            return ToolExecutionResult(
                success: false,
                message: "Timer '\(name)' not found",
                data: nil
            )
        }

        // Stop the timer
        timerManager.stopTimer(name: name)

        return ToolExecutionResult(
            success: true,
            message: "Stopped timer '\(name)'",
            data: ["name": name]
        )
    }

    private static func executeRemoveTimer(arguments: [String: Any], timerManager: TimerManager) -> ToolExecutionResult {
        guard let name = arguments["name"] as? String else {
            return ToolExecutionResult(
                success: false,
                message: "Missing or invalid 'name' parameter",
                data: nil
            )
        }

        // Check if timer exists
        guard timerManager.getTimer(name: name) != nil else {
            return ToolExecutionResult(
                success: false,
                message: "Timer '\(name)' not found",
                data: nil
            )
        }

        // Remove the timer
        timerManager.removeTimer(name: name)

        return ToolExecutionResult(
            success: true,
            message: "Removed timer '\(name)'",
            data: ["name": name]
        )
    }
}

// MARK: - Timer Manager Protocol

/// Protocol for managing timers (to be implemented by CookingSessionManager)
protocol TimerManager {
    func addTimer(name: String, durationMinutes: Int)
    func startTimer(name: String)
    func stopTimer(name: String)
    func removeTimer(name: String)
    func getTimer(name: String) -> LocalTimer?
}
