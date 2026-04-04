//
//  ToolDefinition.swift
//  little-chef
//
//  Timer tool definitions for the cooking assistant
//

import Foundation

// MARK: - Timer Manager Protocol

protocol TimerManager {
    func setTimer(name: String, durationMinutes: Int) throws
    func startTimer(name: String) throws
    func pauseTimer(name: String) throws
    func deleteTimer(name: String) throws
    func getTimer(name: String) -> LocalTimer?
    func getAllTimers() -> [LocalTimer]
}

// MARK: - Cooking Tools

struct CookingTools {
    let timerManager: TimerManager

    /// Text description of tool schemas for injection into system prompt
    var toolSchemaText: String {
        """
        ## set_timer
        Creates and starts a new cooking timer.
        Arguments: {"name": "<descriptive name>", "minutes": <integer>}
        Example: {"name": "set_timer", "arguments": {"name": "boil pasta", "minutes": 10}}

        ## start_timer
        Starts or resumes a paused timer.
        Arguments: {"name": "<timer name>"}
        Example: {"name": "start_timer", "arguments": {"name": "boil pasta"}}

        ## pause_timer
        Pauses a running timer.
        Arguments: {"name": "<timer name>"}
        Example: {"name": "pause_timer", "arguments": {"name": "boil pasta"}}

        ## delete_timer
        Removes a timer completely.
        Arguments: {"name": "<timer name>"}
        Example: {"name": "delete_timer", "arguments": {"name": "boil pasta"}}
        """
    }

    /// Execute a tool by name with the given arguments
    @MainActor
    func execute(toolName: String, arguments: [String: Any]) -> String {
        switch toolName {
        case "set_timer":
            guard let name = arguments["name"] as? String else {
                return "Error: missing 'name' argument"
            }
            let minutes: Int
            if let m = arguments["minutes"] as? Int {
                minutes = m
            } else if let m = arguments["minutes"] as? Double {
                minutes = Int(m)
            } else {
                return "Error: missing or invalid 'minutes' argument"
            }
            do {
                try timerManager.setTimer(name: name, durationMinutes: minutes)
                return "Timer '\(name)' set for \(minutes) minutes and started."
            } catch {
                return "Failed to set timer: \(error.localizedDescription)"
            }

        case "start_timer":
            guard let name = arguments["name"] as? String else {
                return "Error: missing 'name' argument"
            }
            do {
                try timerManager.startTimer(name: name)
                return "Timer '\(name)' started."
            } catch {
                return "Failed to start timer: \(error.localizedDescription)"
            }

        case "pause_timer":
            guard let name = arguments["name"] as? String else {
                return "Error: missing 'name' argument"
            }
            do {
                try timerManager.pauseTimer(name: name)
                return "Timer '\(name)' paused."
            } catch {
                return "Failed to pause timer: \(error.localizedDescription)"
            }

        case "delete_timer":
            guard let name = arguments["name"] as? String else {
                return "Error: missing 'name' argument"
            }
            do {
                try timerManager.deleteTimer(name: name)
                return "Timer '\(name)' deleted."
            } catch {
                return "Failed to delete timer: \(error.localizedDescription)"
            }

        default:
            return "Unknown tool: \(toolName)"
        }
    }
}
