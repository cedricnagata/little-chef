//
//  AuthResponse.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import Foundation

// MARK: - Authentication Response Models
struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
    let user: User
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case user
    }
}

struct TokenRefresh: Codable {
    let refreshToken: String
    
    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct PasswordChange: Codable {
    let currentPassword: String
    let newPassword: String
    
    enum CodingKeys: String, CodingKey {
        case currentPassword = "current_password"
        case newPassword = "new_password"
    }
}

// MARK: - API Error Models
struct APIError: Codable, LocalizedError {
    let detail: ErrorDetail
    
    var errorDescription: String? {
        switch detail {
        case .string(let message):
            return message
        case .validationErrors(let errors):
            // Create user-friendly validation error messages
            let userFriendlyErrors = errors.compactMap { error -> String? in
                let field = error.loc.last ?? "field"
                let message = error.msg.lowercased()
                
                if field == "email" && message.contains("email") {
                    return "Please enter a valid email address"
                } else if field == "password" && message.contains("8") {
                    return "Password must be at least 8 characters"
                } else if field == "name" && message.contains("empty") {
                    return "Name cannot be empty"
                } else if message.contains("required") {
                    return "\(field.capitalized) is required"
                } else {
                    return "Please check your \(field)"
                }
            }
            
            if userFriendlyErrors.isEmpty {
                return "Please check your information"
            } else {
                return userFriendlyErrors.joined(separator: ". ")
            }
        }
    }
}

enum ErrorDetail: Codable {
    case string(String)
    case validationErrors([ValidationError])
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let validationErrors = try? container.decode([ValidationError].self) {
            self = .validationErrors(validationErrors)
        } else {
            throw DecodingError.typeMismatch(ErrorDetail.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or array"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .validationErrors(let errors):
            try container.encode(errors)
        }
    }
}

struct ValidationError: Codable {
    let type: String
    let loc: [String]
    let msg: String
    let input: String?
}

enum AuthError: Error, LocalizedError {
    case invalidCredentials
    case networkError(String)
    case decodingError(String)
    case tokenExpired
    case userNotFound
    case serverError(Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid username or password"
        case .networkError(let message):
            return "Network error: \(message)"
        case .decodingError(let message):
            return "Data error: \(message)"
        case .tokenExpired:
            return "Session expired. Please log in again."
        case .userNotFound:
            return "User not found"
        case .serverError(let code):
            return "Server error (\(code)). Please try again."
        }
    }
}
