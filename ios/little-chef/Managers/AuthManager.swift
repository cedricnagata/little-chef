//
//  AuthManager.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import Foundation
import SwiftUI

@MainActor
class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let apiService = APIService.shared
    private let keychainService = KeychainService.shared
    
    init() {
        checkAuthenticationStatus()
    }
    
    // MARK: - Authentication Methods
    func register(email: String, password: String, name: String) async {
        isLoading = true
        errorMessage = nil
        
        do {
            let authResponse = try await apiService.register(email: email, password: password, name: name)
            
            // Save tokens
            _ = keychainService.saveAccessToken(authResponse.accessToken)
            _ = keychainService.saveRefreshToken(authResponse.refreshToken)
            
            // Update state
            currentUser = authResponse.user
            isAuthenticated = true
            
        } catch {
            // Handle registration-specific errors with clear messaging
            print("Registration error: \(error)")
            if let authError = error as? AuthError {
                switch authError {
                case .networkError(let message) where message.contains("already exists"):
                    errorMessage = "Registration failed. Email already taken."
                case .networkError(let message):
                    errorMessage = parseUserFriendlyError(message, action: "Registration")
                case .decodingError(let message):
                    errorMessage = "Registration failed. Please try again."
                case .serverError(400):
                    errorMessage = "Registration failed. Please check your information."
                case .serverError(let code):
                    errorMessage = "Registration failed. Server error (\(code))."
                default:
                    errorMessage = "Registration failed. Please try again."
                }
            } else {
                errorMessage = "Registration failed. Please check your connection and try again."
            }
        }
        
        isLoading = false
    }
    
    func login(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        
        do {
            let authResponse = try await apiService.login(email: email, password: password)
            
            // Save tokens
            _ = keychainService.saveAccessToken(authResponse.accessToken)
            _ = keychainService.saveRefreshToken(authResponse.refreshToken)
            
            // Update state
            currentUser = authResponse.user
            isAuthenticated = true
            
        } catch {
            // Handle login-specific errors with clear messaging
            print("Login error: \(error)")
            if let authError = error as? AuthError {
                switch authError {
                case .invalidCredentials, .networkError("Incorrect email or password"):
                    errorMessage = "Sign in failed. Please check your email and password."
                case .networkError(let message):
                    errorMessage = parseUserFriendlyError(message, action: "Sign in")
                case .decodingError(let message):
                    errorMessage = "Sign in failed. Please try again."
                case .serverError(401):
                    errorMessage = "Sign in failed. Invalid credentials."
                case .serverError(let code):
                    errorMessage = "Sign in failed. Server error (\(code))."
                default:
                    errorMessage = "Sign in failed. Please try again."
                }
            } else {
                errorMessage = "Sign in failed. Please check your connection and try again."
            }
        }
        
        isLoading = false
    }
    
    func logout() async {
        isLoading = true
        
        do {
            try await apiService.logout()
        } catch {
            // Continue with logout even if API call fails
            print("Logout API call failed: \(error)")
        }
        
        // Clear local state regardless of API response
        _ = keychainService.deleteTokens()
        currentUser = nil
        isAuthenticated = false
        errorMessage = nil
        
        isLoading = false
    }
    
    func refreshTokenIfNeeded() async {
        guard let refreshToken = keychainService.getRefreshToken() else {
            await logout()
            return
        }
        
        do {
            let authResponse = try await apiService.refreshToken(refreshToken: refreshToken)
            
            // Save new tokens
            _ = keychainService.saveAccessToken(authResponse.accessToken)
            _ = keychainService.saveRefreshToken(authResponse.refreshToken)
            
            // Update user data
            currentUser = authResponse.user
            isAuthenticated = true
            
        } catch {
            // Refresh failed, log out user
            await logout()
        }
    }
    
    func updateProfile(name: String? = nil, email: String? = nil) async -> Bool {
        isLoading = true
        errorMessage = nil
        
        do {
            let updatedUser = try await apiService.updateProfile(name: name, email: email)
            currentUser = updatedUser
            isLoading = false
            return true
        } catch {
            handleAuthError(error)
            isLoading = false
            return false
        }
    }
    
    func verifyPassword(currentPassword: String) async -> Bool {
        do {
            return try await apiService.verifyPassword(currentPassword: currentPassword)
        } catch {
            handleAuthError(error)
            return false
        }
    }
    
    func changePassword(currentPassword: String, newPassword: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        
        do {
            try await apiService.changePassword(currentPassword: currentPassword, newPassword: newPassword)
            isLoading = false
            return true
        } catch {
            handleAuthError(error)
            isLoading = false
            return false
        }
    }
    
    // MARK: - User Management
    func updatePreferences(_ preferences: UserPreferences) async {
        guard isAuthenticated else { return }
        
        do {
            let updatedUser = try await apiService.updatePreferences(preferences)
            currentUser = updatedUser
        } catch {
            if let authError = error as? AuthError, case .tokenExpired = authError {
                await refreshTokenIfNeeded()
            } else {
                handleAuthError(error)
            }
        }
    }
    
    func loadCurrentUser() async {
        guard isAuthenticated else { return }
        
        do {
            let user = try await apiService.getCurrentUser()
            currentUser = user
        } catch {
            if let authError = error as? AuthError, case .tokenExpired = authError {
                await refreshTokenIfNeeded()
            } else {
                handleAuthError(error)
            }
        }
    }
    
    // MARK: - Helper Methods
    private func checkAuthenticationStatus() {
        // Check if we have stored tokens
        if keychainService.getAccessToken() != nil {
            isAuthenticated = true
            
            // Load current user in background
            Task {
                await loadCurrentUser()
            }
        }
    }
    
    private func handleAuthError(_ error: Error) {
        if let authError = error as? AuthError {
            errorMessage = authError.localizedDescription
            
            // Handle token expiration
            if case .tokenExpired = authError {
                Task {
                    await refreshTokenIfNeeded()
                }
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }
    
    func clearError() {
        errorMessage = nil
    }
    
    // MARK: - Error Message Parsing
    private func parseUserFriendlyError(_ message: String, action: String) -> String {
        let lowercaseMessage = message.lowercased()
        
        // Check for already user-friendly messages from our improved APIError
        if message.contains("Please enter a valid email address") {
            return "\(action) failed. Please enter a valid email address."
        }
        
        if message.contains("Password must be at least 8 characters") {
            return "\(action) failed. Password must be at least 8 characters."
        }
        
        if message.contains("Name cannot be empty") {
            return "\(action) failed. Name cannot be empty."
        }
        
        if message.contains("Please check your") {
            return "\(action) failed. \(message)"
        }
        
        // Handle raw validation error messages
        if lowercaseMessage.contains("email") && lowercaseMessage.contains("@-sign") {
            return "\(action) failed. Please enter a valid email address."
        }
        
        if lowercaseMessage.contains("email") && lowercaseMessage.contains("valid email") {
            return "\(action) failed. Please enter a valid email address."
        }
        
        if lowercaseMessage.contains("password") && lowercaseMessage.contains("8 characters") {
            return "\(action) failed. Password must be at least 8 characters."
        }
        
        if lowercaseMessage.contains("name") && lowercaseMessage.contains("empty") {
            return "\(action) failed. Name cannot be empty."
        }
        
        // Handle common field errors with body. prefix
        if message.contains("body.email") {
            return "\(action) failed. Please enter a valid email address."
        }
        
        if message.contains("body.password") {
            return "\(action) failed. Please check your password requirements."
        }
        
        if message.contains("body.name") {
            return "\(action) failed. Please enter your name."
        }
        
        // If it's a technical error, provide a generic friendly message
        if message.contains("body.") || message.contains("loc") || message.contains("msg") || 
           message.contains("type") || message.contains("input") || message.contains("ctx") {
            return "\(action) failed. Please check your information and try again."
        }
        
        // Clean up any remaining technical language
        let cleanMessage = message
            .replacingOccurrences(of: "value is not a valid", with: "Please enter a valid")
            .replacingOccurrences(of: "String should have at least", with: "Must have at least")
        
        return "\(action) failed. \(cleanMessage)"
    }
    
    // MARK: - Account Management
    func deleteAccount() async -> Bool {
        isLoading = true
        errorMessage = nil
        
        do {
            try await apiService.deleteAccount()
            
            // Clear tokens and logout
            _ = keychainService.deleteTokens()
            
            currentUser = nil
            isAuthenticated = false
            isLoading = false
            
            return true
        } catch {
            handleAuthError(error)
            isLoading = false
            return false
        }
    }
}
