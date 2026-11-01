//
//  ChatMessage.swift
//  little-chef
//
//  One message of a prompt, backend-neutral. `LLMService` converts these to MLX's or
//  BigBroKit's own types.
//

import Foundation

struct ChatMessage {
    enum Role {
        case system, user, assistant
    }
    let role: Role
    let content: String
}
