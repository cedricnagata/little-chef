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
    func setTimer(name: String, durationSeconds: Int)
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
                    "description": "Set a new cooking timer with a name and duration. Provide minutes, seconds, or both (e.g. 30s → seconds:30, 1m30s → minutes:1 seconds:30).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "Timer label e.g. pasta, chicken"] as [String: any Sendable],
                            "minutes": ["type": "integer", "description": "Whole minutes (omit or 0 if under a minute)"] as [String: any Sendable],
                            "seconds": ["type": "integer", "description": "Additional seconds 0-59"] as [String: any Sendable]
                        ] as [String: any Sendable],
                        "required": ["name"]
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
            func toInt(_ v: Any?) -> Int {
                if let i = v as? Int { return i }
                if let d = v as? Double { return Int(d) }
                return 0
            }
            let minutes = toInt(arguments["minutes"])
            let seconds = toInt(arguments["seconds"])
            let totalSeconds = minutes * 60 + seconds
            guard totalSeconds > 0 else {
                return "Error: duration must be greater than 0"
            }
            timerManager.setTimer(name: name, durationSeconds: totalSeconds)
            let label = minutes > 0 && seconds > 0 ? "\(minutes)m \(seconds)s"
                      : minutes > 0 ? "\(minutes)m" : "\(seconds)s"
            return "Timer '\(name)' set for \(label)."

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
