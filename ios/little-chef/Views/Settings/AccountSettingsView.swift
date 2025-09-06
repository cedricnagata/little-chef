//
//  AccountSettingsView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct AccountSettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var name = ""
    @State private var email = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var showingSuccess = false
    @State private var errorMessage: String?
    @State private var activeSection: ActiveSection?
    @FocusState private var focusedField: Field?
    
    enum ActiveSection {
        case name, email, password
    }
    
    enum Field {
        case name, email, currentPassword, newPassword, confirmPassword
    }
    
    var body: some View {
        Form {
            // Current Account Info
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(authManager.currentUser?.name ?? "N/A")
                        .font(.body)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Email")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(authManager.currentUser?.email ?? "N/A")
                        .font(.body)
                }
            } header: {
                Text("Current Information")
            }
            
            // Change Name Section
            Section {
                if activeSection == .name {
                    VStack(spacing: 12) {
                        TextField("Enter new name", text: $name)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .focused($focusedField, equals: .name)
                        
                        HStack {
                            Button("Cancel") {
                                activeSection = nil
                                name = ""
                                clearError()
                            }
                            .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button("Save") {
                                updateName()
                            }
                            .disabled(name.isEmpty || name == authManager.currentUser?.name)
                            .foregroundColor(.orange)
                            .fontWeight(.semibold)
                        }
                    }
                } else {
                    Button("Change Name") {
                        activeSection = .name
                        name = authManager.currentUser?.name ?? ""
                        focusedField = .name
                    }
                    .foregroundColor(.orange)
                }
            } header: {
                Text("Name")
            }
            
            // Change Email Section
            Section {
                if activeSection == .email {
                    VStack(spacing: 12) {
                        TextField("Enter new email", text: $email)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                        
                        HStack {
                            Button("Cancel") {
                                activeSection = nil
                                email = ""
                                clearError()
                            }
                            .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button("Save") {
                                updateEmail()
                            }
                            .disabled(email.isEmpty || !email.contains("@") || email == authManager.currentUser?.email)
                            .foregroundColor(.orange)
                            .fontWeight(.semibold)
                        }
                    }
                } else {
                    Button("Change Email") {
                        activeSection = .email
                        email = authManager.currentUser?.email ?? ""
                        focusedField = .email
                    }
                    .foregroundColor(.orange)
                }
            } header: {
                Text("Email Address")
            }
            
            // Change Password Section
            Section {
                if activeSection == .password {
                    VStack(spacing: 12) {
                        SecureField("Current password", text: $currentPassword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.none)
                            .focused($focusedField, equals: .currentPassword)
                        
                        SecureField("New password", text: $newPassword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.none)
                            .focused($focusedField, equals: .newPassword)
                        
                        SecureField("Confirm new password", text: $confirmPassword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.none)
                            .focused($focusedField, equals: .confirmPassword)
                        
                        if !newPassword.isEmpty && newPassword.count < 8 {
                            Text("Password must be at least 8 characters")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        if !confirmPassword.isEmpty && newPassword != confirmPassword {
                            Text("Passwords don't match")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        HStack {
                            Button("Cancel") {
                                activeSection = nil
                                currentPassword = ""
                                newPassword = ""
                                confirmPassword = ""
                                clearError()
                            }
                            .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button("Save") {
                                updatePassword()
                            }
                            .disabled(!isPasswordValid)
                            .foregroundColor(.orange)
                            .fontWeight(.semibold)
                        }
                    }
                } else {
                    Button("Change Password") {
                        activeSection = .password
                        focusedField = .currentPassword
                    }
                    .foregroundColor(.orange)
                }
            } header: {
                Text("Password")
            }
            
            // Error Message
            if let errorMessage = errorMessage {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Account Settings")
        .navigationBarTitleDisplayMode(.large)
        .disabled(isLoading)
        .overlay {
            if isLoading {
                Color.black.opacity(0.1)
                    .ignoresSafeArea()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.2)
            }
        }
        .alert("Account Updated", isPresented: $showingSuccess) {
            Button("OK") { }
        } message: {
            Text("Your account information has been updated successfully.")
        }
    }
    
    private var isPasswordValid: Bool {
        !currentPassword.isEmpty &&
        !newPassword.isEmpty &&
        newPassword.count >= 8 &&
        newPassword == confirmPassword
    }
    
    private func clearError() {
        errorMessage = nil
    }
    
    private func updateName() {
        guard !name.isEmpty else { return }
        
        isLoading = true
        clearError()
        
        // TODO: Implement API call to update name
        // For now, just simulate the update
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isLoading = false
            activeSection = nil
            showingSuccess = true
            
            // Update local user (this would normally come from the API response)
            if var user = authManager.currentUser {
                // Note: In real implementation, this would be updated via API call
                // and the authManager would be updated with the response
            }
            
            name = ""
        }
    }
    
    private func updateEmail() {
        guard !email.isEmpty, email.contains("@") else { return }
        
        isLoading = true
        clearError()
        
        // TODO: Implement API call to update email
        // For now, just simulate the update
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isLoading = false
            activeSection = nil
            showingSuccess = true
            
            // Update local user (this would normally come from the API response)
            if var user = authManager.currentUser {
                // Note: In real implementation, this would be updated via API call
                // and the authManager would be updated with the response
            }
            
            email = ""
        }
    }
    
    private func updatePassword() {
        guard isPasswordValid else { return }
        
        isLoading = true
        clearError()
        
        // TODO: Implement API call to change password
        // For now, just simulate the update
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isLoading = false
            activeSection = nil
            showingSuccess = true
            
            // Clear password fields
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
        }
    }
}

#Preview {
    NavigationView {
        AccountSettingsView()
            .environmentObject(AuthManager())
    }
}
