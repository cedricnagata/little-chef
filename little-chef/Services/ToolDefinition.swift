//
//  ToolDefinition.swift
//  little-chef
//
//  Timer tool definitions for the cooking assistant
//

import Foundation
import Tokenizers

// MARK: - Timer Manager Protocol

@MainActor
protocol TimerManager {
    func setTimer(name: String, durationMinutes: Int)
    func startTimer(name: String)
    func pauseTimer(name: String)
    func deleteTimer(name: String)
    func getTimer(name: String) -> LocalTimer?
    func getAllTimers() -> [LocalTimer]
}

// MARK: - Cooking Tools

struct CookingTools {
    let timerManager: TimerManager

    /// Native MLX tool specs for passing to UserInput
    var nativeToolSpecs: [ToolSpec] {
        [
            [
                "type": "function",
                "function": [
                    "name": "set_timer",
                    "description": "Set a new cooking timer with a name and duration in minutes",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "Timer label e.g. pasta, chicken"] as [String: any Sendable],
                            "minutes": ["type": "integer", "description": "Duration in minutes"] as [String: any Sendable]
                        ] as [String: any Sendable],
                        "required": ["name", "minutes"]
                    ] as [String: any Sendable]
                ] as [String: any Sendable]
            ] as ToolSpec,
            [
                "type": "function",
                "function": [
                    "name": "start_timer",
                    "description": "Start an existing timer by name",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "Timer name to start"] as [String: any Sendable]
                        ] as [String: any Sendable],
                        "required": ["name"]
                    ] as [String: any Sendable]
                ] as [String: any Sendable]
            ] as ToolSpec,
            [
                "type": "function",
                "function": [
                    "name": "pause_timer",
                    "description": "Pause a running timer by name",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "Timer name to pause"] as [String: any Sendable]
                        ] as [String: any Sendable],
                        "required": ["name"]
                    ] as [String: any Sendable]
                ] as [String: any Sendable]
            ] as ToolSpec,
            [
                "type": "function",
                "function": [
                    "name": "delete_timer",
                    "description": "Delete a timer by name",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "Timer name to delete"] as [String: any Sendable]
                        ] as [String: any Sendable],
                        "required": ["name"]
                    ] as [String: any Sendable]
                ] as [String: any Sendable]
            ] as ToolSpec,
        ]
    }

    /// Execute a tool by name with the given arguments
    @MainActor
    func execute(toolName: String, arguments: [String: Any]) -> String {
        switch toolName {
        case "set_timer":
            guard let name = arguments["name"] as? String else {
                return "Error: missing 'name'"
            }
            let minutes: Int
            if let m = arguments["minutes"] as? Int {
                minutes = m
            } else if let m = arguments["minutes"] as? Double {
                minutes = Int(m)
            } else {
                return "Error: missing 'minutes'"
            }
            timerManager.setTimer(name: name, durationMinutes: minutes)
            return "Timer '\(name)' set for \(minutes) minutes."

        case "start_timer":
            guard let name = arguments["name"] as? String else {
                return "Error: missing 'name'"
            }
            timerManager.startTimer(name: name)
            return "Timer '\(name)' started."

        case "pause_timer":
            guard let name = arguments["name"] as? String else {
                return "Error: missing 'name'"
            }
            timerManager.pauseTimer(name: name)
            return "Timer '\(name)' paused."

        case "delete_timer":
            guard let name = arguments["name"] as? String else {
                return "Error: missing 'name'"
            }
            timerManager.deleteTimer(name: name)
            return "Timer '\(name)' deleted."

        default:
            return "Unknown tool: \(toolName)"
        }
    }
}
