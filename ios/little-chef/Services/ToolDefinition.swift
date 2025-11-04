//
//  ToolDefinition.swift
//  little-chef
//
//  Defines available tools for the local LLM agent
//

import Foundation

/// Represents a tool that the LLM can call
struct ToolDefinition: Codable {
    let name: String
    let description: String
    let parameters: ToolParameters

    /// Convert to JSON schema format for LLM prompt
    func toJSONSchema() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(self),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return jsonString
    }

    // TODO: Re-implement tool schema conversion once we understand the MLXLLM Tool API better
    // For now, tools are not passed to the LLM
}

/// Tool parameter schema
struct ToolParameters: Codable {
    let type: String
    let properties: [String: PropertySchema]
    let required: [String]
}

/// Property schema for tool parameters
struct PropertySchema: Codable {
    let type: String
    let description: String
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }
}

// MARK: - Predefined Tools

extension ToolDefinition {
    /// Add timer tool
    static let addTimer = ToolDefinition(
        name: "add_timer",
        description: "Creates a new cooking timer with a specified name and duration in minutes",
        parameters: ToolParameters(
            type: "object",
            properties: [
                "name": PropertySchema(
                    type: "string",
                    description: "Descriptive name for the timer (e.g., 'boil pasta', 'marinate chicken')",
                    enumValues: nil
                ),
                "minutes": PropertySchema(
                    type: "number",
                    description: "Duration in minutes for the timer",
                    enumValues: nil
                )
            ],
            required: ["name", "minutes"]
        )
    )

    /// Start timer tool
    static let startTimer = ToolDefinition(
        name: "start_timer",
        description: "Starts a timer that was previously created",
        parameters: ToolParameters(
            type: "object",
            properties: [
                "name": PropertySchema(
                    type: "string",
                    description: "Name of the timer to start",
                    enumValues: nil
                )
            ],
            required: ["name"]
        )
    )

    /// Stop timer tool
    static let stopTimer = ToolDefinition(
        name: "stop_timer",
        description: "Stops a currently running timer",
        parameters: ToolParameters(
            type: "object",
            properties: [
                "name": PropertySchema(
                    type: "string",
                    description: "Name of the timer to stop",
                    enumValues: nil
                )
            ],
            required: ["name"]
        )
    )

    /// Remove timer tool
    static let removeTimer = ToolDefinition(
        name: "remove_timer",
        description: "Removes/deletes a timer completely",
        parameters: ToolParameters(
            type: "object",
            properties: [
                "name": PropertySchema(
                    type: "string",
                    description: "Name of the timer to remove",
                    enumValues: nil
                )
            ],
            required: ["name"]
        )
    )

    /// All available tools
    static let allTools: [ToolDefinition] = [
        addTimer,
        startTimer,
        stopTimer,
        removeTimer
    ]
}

// MARK: - Tool Call Response

/// Represents a tool call made by the LLM
struct ToolCall: Codable {
    let name: String
    let arguments: [String: Any]

    enum CodingKeys: String, CodingKey {
        case name, arguments
    }

    init(name: String, arguments: [String: Any]) {
        self.name = name
        self.arguments = arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)

        // Decode arguments as flexible JSON
        let argsContainer = try container.nestedContainer(keyedBy: DynamicCodingKeys.self, forKey: .arguments)
        var args: [String: Any] = [:]

        for key in argsContainer.allKeys {
            if let stringValue = try? argsContainer.decode(String.self, forKey: key) {
                args[key.stringValue] = stringValue
            } else if let intValue = try? argsContainer.decode(Int.self, forKey: key) {
                args[key.stringValue] = intValue
            } else if let doubleValue = try? argsContainer.decode(Double.self, forKey: key) {
                args[key.stringValue] = doubleValue
            } else if let boolValue = try? argsContainer.decode(Bool.self, forKey: key) {
                args[key.stringValue] = boolValue
            }
        }

        arguments = args
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)

        var argsContainer = container.nestedContainer(keyedBy: DynamicCodingKeys.self, forKey: .arguments)

        for (key, value) in arguments {
            let codingKey = DynamicCodingKeys(stringValue: key)!

            if let stringValue = value as? String {
                try argsContainer.encode(stringValue, forKey: codingKey)
            } else if let intValue = value as? Int {
                try argsContainer.encode(intValue, forKey: codingKey)
            } else if let doubleValue = value as? Double {
                try argsContainer.encode(doubleValue, forKey: codingKey)
            } else if let boolValue = value as? Bool {
                try argsContainer.encode(boolValue, forKey: codingKey)
            }
        }
    }
}

/// Wrapper for tool call response from LLM
struct ToolCallResponse: Codable {
    let toolCall: ToolCall

    enum CodingKeys: String, CodingKey {
        case toolCall = "tool_call"
    }
}

// MARK: - Dynamic Coding Keys

struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

// MARK: - Tool Call Parser

extension String {
    /// Try to parse tool call from LLM response
    func parseToolCall() -> ToolCall? {
        // Look for JSON object in the response
        guard let jsonStart = self.firstIndex(of: "{"),
              let jsonEnd = self.lastIndex(of: "}") else {
            return nil
        }

        let jsonString = String(self[jsonStart...jsonEnd])

        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }

        // Try to parse as ToolCallResponse
        if let toolCallResponse = try? JSONDecoder().decode(ToolCallResponse.self, from: data) {
            return toolCallResponse.toolCall
        }

        // Try to parse as direct ToolCall
        if let toolCall = try? JSONDecoder().decode(ToolCall.self, from: data) {
            return toolCall
        }

        return nil
    }
}
