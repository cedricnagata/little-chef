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
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .name)
                        
                        VStack(spacing: 16) {
                            Button("Save Changes") {
                                // Immediately capture the current name value
                                let nameToUpdate = name
                                
                                guard !nameToUpdate.isEmpty else {
                                    return
                                }
                                
                                updateNameWith(nameToUpdate)
                            }
                            .disabled(name.isEmpty || name == authManager.currentUser?.name)
                            .foregroundColor(.white)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(name.isEmpty || name == authManager.currentUser?.name ? Color.gray : Color.orange)
                            .cornerRadius(12)
                            
                            Button("Cancel") {
                                activeSection = nil
                                name = ""
                                clearError()
                            }
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
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
                        
                        if !email.isEmpty && !isValidEmail(email) {
                            Text("Please enter a valid email address")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        VStack(spacing: 16) {
                            Button("Save Changes") {
                                // Immediately capture the current email value
                                let emailToUpdate = email
                                
                                guard !emailToUpdate.isEmpty, isValidEmail(emailToUpdate) else {
                                    return
                                }
                                
                                updateEmailWith(emailToUpdate)
                            }
                            .disabled(email.isEmpty || !isValidEmail(email) || email == authManager.currentUser?.email)
                            .foregroundColor(.white)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(email.isEmpty || !isValidEmail(email) || email == authManager.currentUser?.email ? Color.gray : Color.orange)
                            .cornerRadius(12)
                            
                            Button("Cancel") {
                                activeSection = nil
                                email = ""
                                clearError()
                            }
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
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
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .currentPassword)
                        
                        SecureField("New password", text: $newPassword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.newPassword)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .newPassword)
                        
                        SecureField("Confirm new password", text: $confirmPassword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.newPassword)
                            .autocorrectionDisabled()
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
                        
                        VStack(spacing: 16) {
                            Button("Change Password") {
                                // Immediately capture the current password values
                                let currentPwd = currentPassword
                                let newPwd = newPassword
                                
                                guard isPasswordValid else {
                                    return
                                }
                                
                                updatePasswordWith(currentPwd, newPwd)
                            }
                            .disabled(!isPasswordValid)
                            .foregroundColor(.white)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(isPasswordValid ? Color.orange : Color.gray)
                            .cornerRadius(12)
                            
                            Button("Cancel") {
                                activeSection = nil
                                currentPassword = ""
                                newPassword = ""
                                confirmPassword = ""
                                clearError()
                            }
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
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
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format:"SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    private func clearError() {
        errorMessage = nil
    }
    
    private func updateName() {
        updateNameWith(name)
    }
    
    private func updateNameWith(_ nameToUpdate: String) {
        guard !nameToUpdate.isEmpty else { 
            return 
        }
        
        isLoading = true
        clearError()
        
        Task {
            let success = await authManager.updateProfile(name: nameToUpdate)
            
            await MainActor.run {
                isLoading = false
                
                if success {
                    activeSection = nil
                    showingSuccess = true
                    name = ""
                } else {
                    errorMessage = authManager.errorMessage ?? "Failed to update name"
                }
            }
        }
    }
    
    private func updateEmail() {
        updateEmailWith(email)
    }
    
    private func updateEmailWith(_ emailToUpdate: String) {
        guard !emailToUpdate.isEmpty, isValidEmail(emailToUpdate) else { 
            return 
        }
        
        isLoading = true
        clearError()
        
        Task {
            let success = await authManager.updateProfile(email: emailToUpdate)
            
            await MainActor.run {
                isLoading = false
                
                if success {
                    activeSection = nil
                    showingSuccess = true
                    email = ""
                } else {
                    errorMessage = authManager.errorMessage ?? "Failed to update email"
                }
            }
        }
    }
    
    private func updatePassword() {
        updatePasswordWith(currentPassword, newPassword)
    }
    
    private func updatePasswordWith(_ currentPwd: String, _ newPwd: String) {
        guard !currentPwd.isEmpty && !newPwd.isEmpty && newPwd.count >= 8 && newPwd == confirmPassword else { 
            return 
        }
        
        isLoading = true
        clearError()
        
        Task {
            // Step 1: Verify the current password first
            let isCurrentPasswordValid = await authManager.verifyPassword(currentPassword: currentPwd)
            
            if !isCurrentPasswordValid {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Current password is incorrect"
                }
                return
            }
            
            // Step 2: Change the password
            let success = await authManager.changePassword(
                currentPassword: currentPwd,
                newPassword: newPwd
            )
            
            await MainActor.run {
                isLoading = false
                
                if success {
                    activeSection = nil
                    showingSuccess = true
                    // Clear password fields
                    currentPassword = ""
                    newPassword = ""
                    confirmPassword = ""
                } else {
                    errorMessage = authManager.errorMessage ?? "Failed to change password"
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        AccountSettingsView()
            .environmentObject(AuthManager())
    }
}
