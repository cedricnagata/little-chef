//
//  APIService.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
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
        
        // Custom date decoding to handle backend format with microseconds
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXX"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            // Try microseconds format with timezone
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXX"
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Try microseconds format without timezone (assume UTC)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Try standard format with timezone
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Try standard format without timezone (assume UTC)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Final fallback - try ISO8601DateFormatter
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso8601Formatter.date(from: dateString) {
                return date
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
    
    // MARK: - Authentication Endpoints
    func register(email: String, password: String, name: String) async throws -> AuthResponse {
        let userCreate = UserCreate(email: email, password: password, name: name)
        let url = URL(string: "\(baseURL)/auth/register")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(userCreate)
        
        return try await performRequest(request: request, responseType: AuthResponse.self)
    }
    
    func login(email: String, password: String) async throws -> AuthResponse {
        let userLogin = UserLogin(email: email, password: password)
        let url = URL(string: "\(baseURL)/auth/login")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(userLogin)
        
        return try await performRequest(request: request, responseType: AuthResponse.self)
    }
    
    func refreshToken(refreshToken: String) async throws -> AuthResponse {
        let tokenRefresh = TokenRefresh(refreshToken: refreshToken)
        let url = URL(string: "\(baseURL)/auth/refresh")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(tokenRefresh)
        
        return try await performRequest(request: request, responseType: AuthResponse.self)
    }
    
    func logout() async throws {
        let url = URL(string: "\(baseURL)/auth/logout")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        // Add auth header if we have a token
        if let token = KeychainService.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw AuthError.serverError(httpResponse.statusCode)
        }
    }
    
    func getCurrentUser() async throws -> User {
        let url = URL(string: "\(baseURL)/auth/me")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: request, responseType: User.self)
    }
    
    func updateProfile(name: String? = nil, email: String? = nil) async throws -> User {
        let userUpdate = UserUpdate(name: name, email: email)
        let url = URL(string: "\(baseURL)/auth/profile")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(userUpdate)
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: request, responseType: User.self)
    }
    
    func verifyPassword(currentPassword: String) async throws -> Bool {
        let passwordVerification = ["current_password": currentPassword]
        let url = URL(string: "\(baseURL)/auth/verify-password")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(passwordVerification)
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (_, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.networkError("Invalid response")
            }
            
            if httpResponse.statusCode == 200 {
                return true
            } else if httpResponse.statusCode == 400 {
                return false  // Password is incorrect
            } else {
                throw AuthError.serverError(httpResponse.statusCode)
            }
        } catch {
            if let authError = error as? AuthError {
                throw authError
            } else {
                throw AuthError.networkError(error.localizedDescription)
            }
        }
    }
    
    func changePassword(currentPassword: String, newPassword: String) async throws {
        let passwordChange = PasswordChange(currentPassword: currentPassword, newPassword: newPassword)
        let url = URL(string: "\(baseURL)/auth/change-password")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(passwordChange)
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw AuthError.serverError(httpResponse.statusCode)
        }
    }
    
    func deleteAccount() async throws {
        let url = URL(string: "\(baseURL)/auth/delete-account")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 204 else {
            throw AuthError.serverError(httpResponse.statusCode)
        }
    }
    
    // MARK: - User Management Endpoints
    func updatePreferences(_ preferences: UserPreferences) async throws -> User {
        let url = URL(string: "\(baseURL)/users/preferences")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(preferences)
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: request, responseType: User.self)
    }
    
    func getPreferences() async throws -> UserPreferences {
        let url = URL(string: "\(baseURL)/users/preferences")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: request, responseType: UserPreferences.self)
    }
    
    // MARK: - Recipe Management Endpoints
    func getRecipes() async throws -> [RecipeListResponse] {
        let url = URL(string: "\(baseURL)/recipes/")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: request, responseType: [RecipeListResponse].self)
    }
    
    func getRecipe(id: UUID) async throws -> Recipe {
        let url = URL(string: "\(baseURL)/recipes/\(id.uuidString)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: request, responseType: Recipe.self)
    }
    
    func createRecipe(_ recipe: RecipeCreate) async throws -> Recipe {
        let url = URL(string: "\(baseURL)/recipes/")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(recipe)
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: request, responseType: Recipe.self)
    }
    
    func updateRecipe(id: UUID, recipe: RecipeUpdate) async throws -> Recipe {
        let url = URL(string: "\(baseURL)/recipes/\(id.uuidString)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(recipe)
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: request, responseType: Recipe.self)
    }
    
    func deleteRecipe(id: UUID) async throws {
        let url = URL(string: "\(baseURL)/recipes/\(id.uuidString)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 204 else {
            throw AuthError.serverError(httpResponse.statusCode)
        }
    }
    
    // MARK: - Recipe Parsing Endpoints
    func parseRecipeFromUrl(_ url: String) async throws -> RecipeParseResponse {
        let request = RecipeParseUrlRequest(url: url)
        let apiUrl = URL(string: "\(baseURL)/recipes/parse/url")!
        
        var urlRequest = URLRequest(url: apiUrl)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try jsonEncoder.encode(request)
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: urlRequest, responseType: RecipeParseResponse.self)
    }
    
    func parseRecipeFromText(_ text: String) async throws -> RecipeParseResponse {
        let request = RecipeParseTextRequest(text: text)
        let url = URL(string: "\(baseURL)/recipes/parse/text")!
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try jsonEncoder.encode(request)
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: urlRequest, responseType: RecipeParseResponse.self)
    }
    
    func parseRecipeFromImage(_ base64Images: [String]) async throws -> RecipeParseResponse {
        let request = RecipeParseImageRequest(images: base64Images)
        let url = URL(string: "\(baseURL)/recipes/parse/image")!
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try jsonEncoder.encode(request)
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            throw AuthError.tokenExpired
        }
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await performRequest(request: urlRequest, responseType: RecipeParseResponse.self)
    }
    
    // MARK: - Agent Chat Endpoints
    func sendAgentQuery(cookingSession: CookingSession, query: String) async throws -> AgentQueryResponse {
        let request = AgentQueryRequest(cookingSession: cookingSession, query: query)
        let url = URL(string: "\(baseURL)/agent/chat")!
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            urlRequest.httpBody = try jsonEncoder.encode(request)
        } catch {
            print("🔴 Failed to encode agent request: \(error)")
            throw AuthError.networkError("Failed to encode request: \(error.localizedDescription)")
        }
        
        // Add auth header
        guard let token = KeychainService.shared.getAccessToken() else {
            print("🔴 No access token available for agent request")
            throw AuthError.tokenExpired
        }
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        print("🔵 Sending agent request to: \(url)")
        print("🔵 Request body size: \(urlRequest.httpBody?.count ?? 0) bytes")
        
        return try await performRequest(request: urlRequest, responseType: AgentQueryResponse.self)
    }
    
    // MARK: - Generic Request Handler
    private func performRequest<T: Codable>(request: URLRequest, responseType: T.Type) async throws -> T {
        return try await performRequestWithRetry(request: request, responseType: responseType, retryCount: 0)
    }
    
    private func performRequestWithRetry<T: Codable>(request: URLRequest, responseType: T.Type, retryCount: Int) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.networkError("Invalid response")
            }
            
            // Handle different status codes
            switch httpResponse.statusCode {
            case 200...299:
                print("🟢 Received successful response (\(httpResponse.statusCode))")
                print("🟢 Response data size: \(data.count) bytes")
                if data.isEmpty {
                    print("🔴 Response data is empty!")
                    throw AuthError.networkError("Empty response from server")
                }
                
                do {
                    return try jsonDecoder.decode(responseType, from: data)
                } catch {
                    print("🔴 Failed to decode response: \(error)")
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("🔴 Response content: \(responseString)")
                    }
                    throw AuthError.decodingError("Failed to decode response: \(error.localizedDescription)")
                }
            case 401:
                // Token expired - try to refresh if we haven't already retried
                if retryCount == 0 {
                    try await refreshTokenAndRetry()
                    
                    // Update the request with the new token
                    var updatedRequest = request
                    if let newToken = KeychainService.shared.getAccessToken() {
                        updatedRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                        return try await performRequestWithRetry(request: updatedRequest, responseType: responseType, retryCount: 1)
                    }
                }
                throw AuthError.tokenExpired
            case 404:
                throw AuthError.userNotFound
            case 400...499:
                // Try to decode API error
                if let apiError = try? jsonDecoder.decode(APIError.self, from: data) {
                    throw AuthError.networkError(apiError.errorDescription ?? "Unknown error")
                } else {
                    throw AuthError.serverError(httpResponse.statusCode)
                }
            case 500...599:
                throw AuthError.serverError(httpResponse.statusCode)
            default:
                throw AuthError.serverError(httpResponse.statusCode)
            }
        } catch let error as AuthError {
            throw error
        } catch {
            if let decodingError = error as? DecodingError {
                throw AuthError.decodingError(decodingError.localizedDescription)
            } else {
                throw AuthError.networkError(error.localizedDescription)
            }
        }
    }
    
    private func refreshTokenAndRetry() async throws {
        guard let storedRefreshToken = KeychainService.shared.getRefreshToken() else {
            throw AuthError.tokenExpired
        }
        
        // Call the refresh endpoint
        let authResponse = try await refreshToken(refreshToken: storedRefreshToken)
        
        // Save new tokens
        _ = KeychainService.shared.saveAccessToken(authResponse.accessToken)
        _ = KeychainService.shared.saveRefreshToken(authResponse.refreshToken)
    }
    
    // MARK: - TTS Methods
    
    func getElevenLabsVoices() async throws -> ElevenLabsVoicesResponse {
        guard let url = URL(string: "\(baseURL)/tts/voices") else {
            throw AuthError.networkError("Invalid URL for TTS voices endpoint")
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = KeychainService.shared.getAccessToken() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        print("🔵 Fetching ElevenLabs voices from: \(url)")
        
        return try await performRequest(request: urlRequest, responseType: ElevenLabsVoicesResponse.self)
    }
    
    func synthesizeWithElevenLabs(text: String, voiceSettings: ElevenLabsSettings) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/tts/synthesize") else {
            throw AuthError.networkError("Invalid URL for TTS synthesize endpoint")
        }
        
        let requestBody: [String: Any] = [
            "text": text,
            "voice_settings": [
                "enabled": voiceSettings.enabled,
                "voice_name": voiceSettings.voiceName
            ]
        ]
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = KeychainService.shared.getAccessToken() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        print("🔵 Synthesizing with ElevenLabs: \(text.prefix(50))...")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw AuthError.serverError(httpResponse.statusCode)
        }
        
        print("🟢 Received ElevenLabs TTS audio: \(data.count) bytes")
        return data
    }
    
    func testElevenLabsVoice(voiceName: String, testText: String = "Hello! This is a test of this voice.") async throws -> Data {
        guard let url = URL(string: "\(baseURL)/tts/test-voice") else {
            throw AuthError.networkError("Invalid URL for TTS test-voice endpoint")
        }
        
        let requestBody = [
            "voice_name": voiceName,
            "text": testText
        ]
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = KeychainService.shared.getAccessToken() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        print("🔵 Testing ElevenLabs voice: \(voiceName)")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw AuthError.serverError(httpResponse.statusCode)
        }
        
        print("🟢 Received voice test audio: \(data.count) bytes")
        return data
    }
}
