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
    private let baseURL = "http://127.0.0.1:8000"
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
            
            // Try the microseconds format first
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Fallback to standard ISO8601
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
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
    
    // MARK: - Generic Request Handler
    private func performRequest<T: Codable>(request: URLRequest, responseType: T.Type) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.networkError("Invalid response")
            }
            
            // Handle different status codes
            switch httpResponse.statusCode {
            case 200...299:
                return try jsonDecoder.decode(responseType, from: data)
            case 401:
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
}
