//
//  RegisterView.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

struct RegisterView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var name = ""
    @FocusState private var focusedField: Field?
    
    enum Field {
        case name, email, password, confirmPassword
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    
                    Text("Create Account")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Join LittleChef today")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
                
                // Registration Form
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Full Name")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        TextField("Enter your full name", text: $name)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .name)
                            .onSubmit {
                                focusedField = .email
                            }
                            .onChange(of: name) { _ in
                                authManager.clearError()
                            }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Email")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        TextField("Enter your email", text: $email)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .focused($focusedField, equals: .email)
                            .onSubmit {
                                focusedField = .password
                            }
                            .onChange(of: email) { _ in
                                authManager.clearError()
                            }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        SecureField("Create a password", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.newPassword)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .password)
                            .onSubmit {
                                focusedField = .confirmPassword
                            }
                            .onChange(of: password) { _ in
                                authManager.clearError()
                            }
                        
                        Text("Password must be at least 8 characters")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Confirm Password")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        SecureField("Confirm your password", text: $confirmPassword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.newPassword)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .confirmPassword)
                            .onSubmit {
                                Task {
                                    await handleRegister()
                                }
                            }
                            .onChange(of: confirmPassword) { _ in
                                authManager.clearError()
                            }
                        
                        if !confirmPassword.isEmpty && password != confirmPassword {
                            Text("Passwords don't match")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    
                    // Error Message
                    if let errorMessage = authManager.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .multilineTextAlignment(.center)
                    }
                    
                    // Register Button
                    Button(action: {
                        Task {
                            await handleRegister()
                        }
                    }) {
                        HStack {
                            if authManager.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text("Create Account")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!isFormValid || authManager.isLoading)
                    .opacity(isFormValid ? 1.0 : 0.6)
                }
                .padding(.horizontal, 32)
                
                Spacer()
                
                // Terms and Privacy (placeholder)
                Text("By creating an account, you agree to our Terms of Service and Privacy Policy")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
            }
            .navigationTitle("Sign Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        authManager.clearError()
                        dismiss()
                    }
                }
            }
            .onTapGesture {
                focusedField = nil
            }
        }
        .onAppear {
            authManager.clearError()
        }
        .onChange(of: authManager.isAuthenticated) { isAuthenticated in
            if isAuthenticated {
                dismiss()
            }
        }
    }
    
    private var isFormValid: Bool {
        !name.isEmpty &&
        !email.isEmpty &&
        email.contains("@") &&
        email.contains(".") &&
        !password.isEmpty &&
        password.count >= 8 &&
        password == confirmPassword
    }
    
    private func handleRegister() async {
        guard isFormValid else { return }
        
        focusedField = nil
        await authManager.register(email: email, password: password, name: name)
    }
}

#Preview {
    RegisterView()
        .environmentObject(AuthManager())
}
