//
//  RecipeEditorService.swift
//  little-chef
//
//  HTTP client for AI-powered recipe editing
//

import Foundation

class RecipeEditorService {
    static let shared = RecipeEditorService()

    private init() {}

    private let session = URLSession.shared

    private var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Handle ISO8601 with various formats
            let formatters = [
                ISO8601DateFormatter(),
                {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                    return formatter
                }(),
                {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                    return formatter
                }()
            ]

            for formatter in formatters {
                if let isoFormatter = formatter as? ISO8601DateFormatter {
                    if let date = isoFormatter.date(from: dateString) {
                        return date
                    }
                } else if let dateFormatter = formatter as? DateFormatter {
                    if let date = dateFormatter.date(from: dateString) {
                        return date
                    }
                }
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string \(dateString)")
        }
        return decoder
    }

    private var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Edit a recipe with AI assistance
    func editRecipe(
        recipe: RecipeBase,
        instructions: String,
        preferences: UserPreferencesDetailed
    ) async throws -> RecipeEditResponse {
        guard let baseURL = Config.recipeEditorURL else {
            throw RecipeEditorError.invalidConfiguration
        }

        guard let url = URL(string: baseURL) else {
            throw RecipeEditorError.invalidURL
        }

        let requestBody = RecipeEditRequest(
            recipe: recipe,
            editInstructions: instructions,
            userPreferences: preferences
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(requestBody)
        request.timeoutInterval = 120  // Allow time for LLM processing

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeEditorError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to decode error response
            if let errorResponse = try? jsonDecoder.decode(ErrorResponse.self, from: data) {
                throw RecipeEditorError.serverError(
                    message: errorResponse.message ?? errorResponse.error ?? "Unknown error",
                    statusCode: httpResponse.statusCode
                )
            }
            throw RecipeEditorError.httpError(statusCode: httpResponse.statusCode)
        }

        let editResponse = try jsonDecoder.decode(RecipeEditResponse.self, from: data)
        return editResponse
    }
}

// MARK: - Error Types

enum RecipeEditorError: LocalizedError {
    case invalidConfiguration
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case serverError(message: String, statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Recipe editor service is not configured. Please check Config.swift."
        case .invalidURL:
            return "Invalid URL for recipe editor service"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "Server returned error code: \(statusCode)"
        case .serverError(let message, let statusCode):
            return "Server error (\(statusCode)): \(message)"
        }
    }
}
