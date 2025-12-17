import Foundation

// MARK: - Client → Server Messages

struct WebSocketMessage<T: Codable>: Codable {
    let action: String
    let requestId: String
    let payload: T

    enum CodingKeys: String, CodingKey {
        case action
        case requestId = "request_id"
        case payload
    }
}

struct QueryPayload: Codable {
    let cookingSession: CookingSession
    let query: String
    let warmup: Bool

    enum CodingKeys: String, CodingKey {
        case cookingSession = "cooking_session"
        case query
        case warmup
    }

    init(cookingSession: CookingSession, query: String, warmup: Bool = false) {
        self.cookingSession = cookingSession
        self.query = query
        self.warmup = warmup
    }
}

// MARK: - Server → Client Messages

struct ServerEvent: Codable {
    let type: String
    let requestId: String

    // Token event
    let content: String?

    // Tool event
    let status: String?
    let tool: String?
    let args: [String: AnyCodable]?
    let result: String?

    // Audio event
    let data: String?
    let format: String?
    let chunkIndex: Int?

    // Done event
    let response: String?
    let updatedSession: CookingSession?
    let commands: [Command]?

    // Error event
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case content
        case status
        case tool
        case args
        case result
        case data
        case format
        case chunkIndex = "chunk_index"
        case response
        case updatedSession = "updated_session"
        case commands
        case code
        case message
    }
}

// MARK: - Supporting Types

struct WebSocketError: Error, LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? {
        return "\(code): \(message)"
    }
}
