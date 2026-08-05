//
//  ToolDefinition.swift
//  little-chef
//
//  Timer tool definitions for the cooking assistant
//

import Foundation
import Tokenizers

// MARK: - Timer Manager Protocol

/// The timer operations the assistant can perform.
///
/// Every mutating call reports whether it found the timer, so the tool layer can tell the model
/// "no timer called that" instead of reporting a success that never happened — a lie the model
/// then repeats to a cook who is waiting on a bell that was never set.
@MainActor
protocol TimerManager {
    /// Creates a timer in the `new` state — **stopped**. Starting it is a separate action.
    /// Returns false if a timer by that name already exists.
    @discardableResult func createTimer(name: String, durationSeconds: Int) -> Bool
    @discardableResult func startTimer(name: String) -> Bool
    @discardableResult func stopTimer(name: String) -> Bool
    @discardableResult func updateTimer(name: String, newName: String?, durationSeconds: Int?) -> Bool
    @discardableResult func deleteTimer(name: String) -> Bool
    func getTimer(name: String) -> LocalTimer?
    func getAllTimers() -> [LocalTimer]
}

// MARK: - Tool loop guard

/// The timers created during the tool loop currently being executed.
///
/// Creating and starting a timer are two tools on purpose, and a model handed both will call
/// them back to back in one loop every time — which is how "set a timer for the pasta" ended up
/// counting down before the water was on. This records what the loop created so `start_timer`
/// can refuse, leaving the start for the *next* message once the cook asks for it.
///
/// A reference type because `CookingTools` is a value passed by copy into the loop.
@MainActor
final class ToolLoopGuard {
    private var createdThisLoop: Set<String> = []

    /// Nonisolated so `CookingTools` — which is built wherever a request is assembled — does not
    /// have to be main-actor isolated just to hold one. Everything that touches the set is.
    nonisolated init() {}

    /// A new user message — nothing has been created for this loop yet.
    func beginLoop() { createdThisLoop.removeAll() }

    func recordCreation(id: String) { createdThisLoop.insert(id) }

    func wasCreatedThisLoop(id: String) -> Bool { createdThisLoop.contains(id) }
}

// MARK: - Cooking Tools

struct CookingTools {
    let timerManager: TimerManager
    private let loopGuard: ToolLoopGuard

    init(timerManager: TimerManager) {
        self.timerManager = timerManager
        self.loopGuard = ToolLoopGuard()
    }

    /// Starts a fresh tool loop, releasing the create-then-start hold from the last one.
    ///
    /// Only the hands-free Mac path needs to call this: it builds one `CookingTools` when the
    /// loop starts and reuses it for every spoken turn, so without this a timer created in one
    /// turn could never be started in any later one. The typed path gets a new value per
    /// request and is already clean.
    @MainActor
    func beginToolLoop() { loopGuard.beginLoop() }

    /// Native MLX tool specs for passing to UserInput
    var nativeToolSpecs: [ToolSpec] {
        [
            [
                "type": "function",
                "function": [
                    "name": "create_timer",
                    "description": "Create a new cooking timer, stopped. This does NOT start it — the user must ask separately before you call start_timer. Provide minutes, seconds, or both (e.g. 30s → seconds:30, 1m30s → minutes:1 seconds:30).",
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
                    "description": "Start or resume an existing timer by name. Only call this when the user asks to start it, never in the same reply that created it.",
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
                    "name": "stop_timer",
                    "description": "Stop a running timer by name, keeping the time left so it can be resumed",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "Timer name to stop"] as [String: any Sendable]
                        ] as [String: any Sendable],
                        "required": ["name"]
                    ] as [String: any Sendable]
                ] as [String: any Sendable]
            ] as ToolSpec,
            [
                "type": "function",
                "function": [
                    "name": "update_timer",
                    "description": "Change an existing timer's duration, its name, or both. Give the timer's current name plus whatever is changing.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "The timer's current name"] as [String: any Sendable],
                            "new_name": ["type": "string", "description": "New label, if renaming"] as [String: any Sendable],
                            "minutes": ["type": "integer", "description": "New duration, whole minutes (omit if only renaming)"] as [String: any Sendable],
                            "seconds": ["type": "integer", "description": "New duration, additional seconds 0-59"] as [String: any Sendable]
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
        // `set_timer` and `pause_timer` are the names this tool set used to carry. Models copy
        // them out of their own training data and out of earlier turns in the transcript, and
        // the text-tool-call fallback parses whatever name it is handed, so both are mapped
        // rather than answered with "unknown tool".
        switch toolName {
        case "create_timer", "set_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            let totalSeconds = duration(from: arguments)
            guard totalSeconds > 0 else {
                return "Error: duration must be greater than 0"
            }
            guard timerManager.createTimer(name: name, durationSeconds: totalSeconds) else {
                return "A timer called '\(name)' already exists — update it instead of creating another."
            }
            if let created = timerManager.getTimer(name: name) {
                loopGuard.recordCreation(id: created.id)
            }
            return "Timer '\(name)' created for \(spoken(totalSeconds)). It is not running yet — "
                 + "tell the user it is ready and wait for them to ask before starting it."

        case "start_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            guard let timer = timerManager.getTimer(name: name) else {
                return "No timer called '\(name)' exists. Create it first."
            }
            guard !loopGuard.wasCreatedThisLoop(id: timer.id) else {
                return "Timer '\(timer.label)' was only just created, so it cannot be started yet. "
                     + "Tell the user it is set for \(spoken(timer.remainingSeconds)) and ask them "
                     + "to say when to start it."
            }
            guard timerManager.startTimer(name: name) else {
                return "Timer '\(timer.label)' is already running."
            }
            return "Timer '\(timer.label)' started with \(spoken(timer.remainingSeconds)) to go."

        case "stop_timer", "pause_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            guard let timer = timerManager.getTimer(name: name) else {
                return "No timer called '\(name)' exists."
            }
            guard timerManager.stopTimer(name: name) else {
                return "Timer '\(timer.label)' was not running."
            }
            return "Timer '\(timer.label)' stopped with \(spoken(timer.remainingSeconds)) left."

        case "update_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            guard timerManager.getTimer(name: name) != nil else {
                return "No timer called '\(name)' exists. Create it first."
            }
            let newName = string(arguments["new_name"]) ?? string(arguments["newName"])
            let totalSeconds = duration(from: arguments)
            let newDuration = totalSeconds > 0 ? totalSeconds : nil
            guard newName != nil || newDuration != nil else {
                return "Error: give 'new_name', a new duration, or both"
            }
            timerManager.updateTimer(name: name, newName: newName, durationSeconds: newDuration)
            guard let updated = timerManager.getTimer(name: newName ?? name) else {
                return "Timer updated."
            }
            var changes: [String] = []
            if newName != nil { changes.append("renamed to '\(updated.label)'") }
            if let newDuration { changes.append("set to \(spoken(newDuration))") }
            return "Timer '\(name)' \(changes.joined(separator: " and "))."

        case "delete_timer":
            guard let name = string(arguments["name"]) else {
                return "Error: missing 'name'"
            }
            guard timerManager.deleteTimer(name: name) else {
                return "No timer called '\(name)' exists."
            }
            return "Timer '\(name)' deleted."

        default:
            return "Unknown tool: \(toolName)"
        }
    }

    // MARK: - Argument coercion

    /// Tool arguments arrive from JSON, so a number the schema calls an integer can turn up as a
    /// `Double`, and a model that ignores the schema sends `"5"`.
    private func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    private func string(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func duration(from arguments: [String: Any]) -> Int {
        int(arguments["minutes"]) * 60 + int(arguments["seconds"])
    }

    /// Tool results are read back by a speech model, so durations are spelled out rather than
    /// abbreviated — see the same rule in `LocalCookingAgent`'s system prompt.
    private func spoken(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        let minutePart = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        let secondPart = "\(remainder) \(remainder == 1 ? "second" : "seconds")"
        if minutes > 0 && remainder > 0 { return "\(minutePart) and \(secondPart)" }
        if minutes > 0 { return minutePart }
        return secondPart
    }
}
