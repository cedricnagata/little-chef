//
//  ToolDefinition.swift
//  little-chef
//
//  Timer tool definitions for the cooking assistant
//

import Foundation
import Tokenizers
import BigBroKit

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

// MARK: - Tool Definition

/// One timer tool, described once and encoded for whichever provider is answering.
///
/// The two providers want the same tool in different shapes — MLX takes a `ToolSpec`
/// dictionary, BigBroKit takes a `BigBroTool.Definition` — and writing each by hand let them
/// drift: the Mac was offered a `set_timer` that could only count whole minutes while the
/// on-device model could also count seconds, so "give it 30 seconds" set a timer for nothing
/// whenever a Mac was answering. Both encodings are now derived from this.
struct CookingToolDefinition: Sendable {
    struct Parameter: Sendable {
        let name: String
        let type: String
        let description: String
        var required: Bool = false
    }

    let name: String
    let description: String
    let parameters: [Parameter]

    private var requiredParameters: [String] {
        parameters.filter(\.required).map(\.name)
    }

    /// The shape `MLXLMCommon.UserInput` wants.
    var toolSpec: ToolSpec {
        var properties: [String: any Sendable] = [:]
        for parameter in parameters {
            properties[parameter.name] = [
                "type": parameter.type,
                "description": parameter.description,
            ] as [String: any Sendable]
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": requiredParameters,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ] as ToolSpec
    }

    /// The shape BigBroKit's agentic loop wants.
    var bigBroDefinition: BigBroTool.Definition {
        BigBroTool.Definition(
            name: name,
            description: description,
            parameters: BigBroTool.Definition.Parameters(
                properties: Dictionary(uniqueKeysWithValues: parameters.map { parameter in
                    (parameter.name, BigBroTool.Definition.Parameters.Property(
                        type: parameter.type,
                        description: parameter.description
                    ))
                }),
                required: requiredParameters
            )
        )
    }
}

/// `CookingTools` reaches the timer manager, which is `@MainActor`, so it cannot be `Sendable`
/// itself. The handlers hop back to the main actor before touching it.
private struct SendableCookingBox: @unchecked Sendable {
    let tools: CookingTools
}

// MARK: - Cooking Tools

struct CookingTools {
    let timerManager: TimerManager

    /// Every tool the cooking assistant can call, in the order they are offered to the model.
    static let definitions: [CookingToolDefinition] = [
        CookingToolDefinition(
            name: "set_timer",
            description: "Set a new cooking timer with a name and duration. Provide minutes, seconds, or both (e.g. 30s → seconds:30, 1m30s → minutes:1 seconds:30).",
            parameters: [
                .init(name: "name", type: "string", description: "Timer label e.g. pasta, chicken", required: true),
                .init(name: "minutes", type: "integer", description: "Whole minutes (omit or 0 if under a minute)"),
                .init(name: "seconds", type: "integer", description: "Additional seconds 0-59"),
            ]
        ),
        CookingToolDefinition(
            name: "start_timer",
            description: "Start or resume an existing timer by name",
            parameters: [
                .init(name: "name", type: "string", description: "Timer name to start", required: true),
            ]
        ),
        CookingToolDefinition(
            name: "pause_timer",
            description: "Pause a running timer by name",
            parameters: [
                .init(name: "name", type: "string", description: "Timer name to pause", required: true),
            ]
        ),
        CookingToolDefinition(
            name: "delete_timer",
            description: "Delete a timer by name",
            parameters: [
                .init(name: "name", type: "string", description: "Timer name to delete", required: true),
            ]
        ),
    ]

    /// Native MLX tool specs for passing to UserInput
    var nativeToolSpecs: [ToolSpec] {
        Self.definitions.map(\.toolSpec)
    }

    /// The same tools for a paired Mac. BigBroKit runs the tool loop on this device, so the
    /// handlers are the same `execute` the on-device path calls.
    var bigBroTools: [BigBroTool] {
        let box = SendableCookingBox(tools: self)
        return Self.definitions.map { definition in
            BigBroTool(definition: definition.bigBroDefinition) { arguments in
                await MainActor.run { box.tools.execute(toolName: definition.name, arguments: arguments) }
            }
        }
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
