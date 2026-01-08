//
//  APIService.swift
//  little-chef
//
//  HTTP API client for recipe parser endpoint
//  Cooking assistant uses WebSocket (see WebSocketService.swift)
//

import Foundation

class APIService {
    static let shared = APIService()

    private init() {}

    // MARK: - Configuration
    private let baseURL = Config.baseURL
    private let session = URLSession.shared

    private var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - Lambda Endpoints

    /// Parse recipe from URL
    /// POST /v1/parse
    func parseRecipeFromUrl(url: String) async throws -> RecipeParseResponse {
        let requestBody = RecipeParseUrlRequest(url: url)
        return try await parseRecipe(requestBody: requestBody)
    }

    /// Parse recipe from text
    /// POST /v1/parse
    func parseRecipeFromText(text: String) async throws -> RecipeParseResponse {
        let requestBody = RecipeParseTextRequest(text: text)
        return try await parseRecipe(requestBody: requestBody)
    }

    /// Parse recipe from images
    /// POST /v1/parse
    func parseRecipeFromImage(images: [String]) async throws -> RecipeParseResponse {
        let requestBody = RecipeParseImageRequest(images: images)
        return try await parseRecipe(requestBody: requestBody)
    }

    // MARK: - Private Methods

    private func parseRecipe<T: Encodable>(requestBody: T) async throws -> RecipeParseResponse {
        // Using Lambda Function URL directly - no path needed
        guard let url = URL(string: baseURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(requestBody)

        return try await performRequest(request: request, responseType: RecipeParseResponse.self)
    }

    private func performRequest<T: Decodable>(request: URLRequest, responseType: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to decode error message
            if let errorResponse = try? jsonDecoder.decode(ErrorResponse.self, from: data) {
                throw APIError.serverError(message: errorResponse.message ?? "Unknown error", statusCode: httpResponse.statusCode)
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        do {
            let decodedResponse = try jsonDecoder.decode(T.self, from: data)
            return decodedResponse
        } catch {
            throw APIError.decodingError(error)
        }
    }
}

// MARK: - Error Types

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case serverError(message: String, statusCode: Int)
    case decodingError(Error)
    case encodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .serverError(let message, let statusCode):
            return "Server error (\(statusCode)): \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .encodingError(let error):
            return "Failed to encode request: \(error.localizedDescription)"
        }
    }
}

// MARK: - Helper Models

struct ErrorResponse: Codable {
    let error: String?
    let message: String?
}
